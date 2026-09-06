import Foundation
import Observation
import Security
import UIKit
@preconcurrency import UserNotifications

nonisolated struct HouseholdDeliveryStatus: Decodable, Sendable {
    let realtime: String
    let apns: String
    let encryption: String
    let ownerVerified: Bool
    let secureShare: Bool
    let webhookEnabled: Bool
    let endpoint: String?
    let deviceEnabled: Bool
    let pending: Int
    let lastResult: String?
    let lastAttempt: String?
    let coalesced: Int
}

/// Device-only capabilities are deliberately excluded from defaults, household snapshots and backups.
@MainActor enum HouseholdDeliveryKeychain {
    private static let service = "com.sowens.Stocked.household.delivery"
    static func read(_ account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }
    @discardableResult static func write(_ value: String, account: String) -> Bool {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return true }
        guard updated == errSecItemNotFound else { return false }
        return SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess
    }
    static func remove(_ account: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                       kSecAttrAccount as String: account] as CFDictionary)
    }
    static func clearAll() throws {
        let result = SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service] as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw HouseholdDeliveryService.DeliveryFailure.unavailable }
    }
}

@MainActor @Observable final class HouseholdDeliveryService {
    static let shared = HouseholdDeliveryService()
    private(set) var status: HouseholdDeliveryStatus?
    private(set) var connection = "Polling is available"
    private(set) var problem = ""
    private(set) var permission = "Not checked"
    private(set) var registeredWithApple = false
    private(set) var isConnected = false
    @ObservationIgnored private weak var store: GuestDataStore?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var transportTask: Task<Void, Never>?
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var preferenceTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var latestRevision: Int = 0
    @ObservationIgnored private var connectedCode: String?
    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?
    @ObservationIgnored private var lastRegistration = ""
    @ObservationIgnored private var erased = false
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    }
    @ObservationIgnored private lazy var network: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        return URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
    }()
    private init() {
        registeredWithApple = HouseholdDeliveryKeychain.read("apple-token") != nil
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in HouseholdDeliveryService.shared.preferencesChanged() }
        }
    }
    private var deviceID: String {
        if let value = HouseholdDeliveryKeychain.read("device-id") { return value }
        let value = UUID().uuidString.lowercased()
        return HouseholdDeliveryKeychain.write(value, account: "device-id") ? value : ""
    }
    private var deviceCapability: String {
        if let value = HouseholdDeliveryKeychain.read("device-capability") { return value }
        var data = Data(count: 32)
        let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard result == errSecSuccess else { return "" }
        let value = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        guard HouseholdDeliveryKeychain.write(value, account: "device-capability") else { return "" }
        return value
    }
    var deviceOptIn: Bool {
        guard let code = HouseholdSync.shared.joinCode else { return false }
        return UserDefaults.standard.bool(forKey: "delivery.apple.\(code)")
    }
    var masterNotificationsEnabled: Bool { UserDefaults.standard.bool(forKey: "notificationsEnabled") }
    var hasAppleToken: Bool { HouseholdDeliveryKeychain.read("apple-token") != nil }
    private var sharesAnything: Bool {
        let hh = HouseholdSync.shared
        return hh.syncInventory || hh.syncGrocery || hh.syncRecipes || hh.syncMealPlans
    }
    func rememberOwnerCapability(_ value: String, code: String) {
        erased = false
        guard value.count >= 32, value.count <= 100 else { return }
        if !HouseholdDeliveryKeychain.write(value, account: "owner.\(code)") {
            problem = "This device couldn't securely save the share-owner key. Household syncing still works; webhook setup is locked."
        }
    }
    private func payload(code: String) -> [String: Any] {
        var body: [String: Any] = ["code": code, "actorId": HouseholdSync.shared.memberId, "deviceID": deviceID]
        if let value = HouseholdDeliveryKeychain.read("owner.\(code)") { body["ownerCapability"] = value }
        return body
    }
    private func post(_ action: String, code: String, extra: [String: Any] = [:]) async throws -> Data {
        guard let base = StockedWorkerClient.url(), base.scheme == "https" else { throw DeliveryFailure.unavailable }
        var request = URLRequest(url: base.appendingPathComponent("household/delivery/\(action)"), timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&request)
        request.httpBody = try JSONSerialization.data(withJSONObject: payload(code: code).merging(extra) { _, new in new })
        let (bytes, response) = try await network.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeliveryFailure.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 16 * 1024 else { throw DeliveryFailure.unavailable }
            data.append(byte)
        }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["code"] as? String
            if code == "setupRequired" { throw DeliveryFailure.setupRequired }
            if code == "ownerVerificationRequired" { throw DeliveryFailure.ownerRequired }
            if code == "unsafeEndpoint" { throw DeliveryFailure.receiver }
            throw DeliveryFailure.unavailable
        }
        return data
    }
    func refreshStatus() async {
        guard let code = HouseholdSync.shared.joinCode else { status = nil; return }
        do {
            let data = try await post("status", code: code)
            let result = try JSONDecoder().decode(HouseholdDeliveryStatus.self, from: data)
            guard code == HouseholdSync.shared.joinCode else { return }
            status = result; problem = ""
        } catch { problem = (error as? DeliveryFailure)?.localizedDescription ?? "Delivery status couldn't be checked. Household polling still works." }
        await refreshPermission()
    }
    func configureWebhook(endpoint: String, enabled: Bool) async throws -> String? {
        guard let code = HouseholdSync.shared.joinCode else { throw DeliveryFailure.unavailable }
        let data = try await post("webhook", code: code, extra: ["enabled": enabled, "endpoint": endpoint.trimmingCharacters(in: .whitespacesAndNewlines)])
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard code == HouseholdSync.shared.joinCode else { throw DeliveryFailure.unavailable }
        await refreshStatus()
        return result?["signingSecret"] as? String
    }
    func receiveAppleToken(_ data: Data) {
        guard !erased else { return }
        guard (32...100).contains(data.count) else { return }
        let value = data.map { String(format: "%02x", $0) }.joined()
        registeredWithApple = HouseholdDeliveryKeychain.write(value, account: "apple-token")
        lastRegistration = ""
        preferencesChanged()
    }
    func appleRegistrationFailed() {
        guard !erased else { return }
        registeredWithApple = false; problem = "Apple hasn't registered this device for push. Polling still works."
    }
    func refreshPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: permission = "Allowed"
        case .denied: permission = "Off in iOS Settings"
        case .notDetermined: permission = "Not requested"
        @unknown default: permission = "Unavailable"
        }
    }
    func setDeviceOptIn(_ value: Bool) async {
        guard let code = HouseholdSync.shared.joinCode else { return }
        UserDefaults.standard.set(value, forKey: "delivery.apple.\(code)")
        lastRegistration = ""
        await reconcileDevice()
    }
    private func preferencesChanged() {
        guard !erased else { return }
        preferenceTask?.cancel()
        preferenceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            self.updateConnection()
            await self.reconcileDevice()
        }
    }
    private func reconcileDevice() async {
        guard !erased else { return }
        guard let code = HouseholdSync.shared.joinCode else { return }
        await refreshPermission()
        let enabled = deviceOptIn && masterNotificationsEnabled && permission == "Allowed" && sharesAnything
        let token = HouseholdDeliveryKeychain.read("apple-token") ?? ""
        let fingerprint = "\(code)|\(enabled)|\(token)|\(Int(Date().timeIntervalSince1970 / 86400))"
        guard fingerprint != lastRegistration else { return }
        // No device token leaves this device until both explicit opt-in and existing master permission allow it.
        if enabled && token.isEmpty { UIApplication.shared.registerForRemoteNotifications(); return }
        // Avoid enrolling/disabling a device that has never opted in on this household.
        let registeredKey = "delivery.registered.\(code)"
        guard enabled || UserDefaults.standard.bool(forKey: registeredKey) else { return }
        do {
            let data = try await post("device", code: code, extra: ["enabled": enabled, "deviceCapability": deviceCapability,
                "token": enabled ? token : "", "environment": Self.appleEnvironment])
            guard code == HouseholdSync.shared.joinCode else { return }
            status = try JSONDecoder().decode(HouseholdDeliveryStatus.self, from: data)
            UserDefaults.standard.set(enabled, forKey: registeredKey)
            lastRegistration = fingerprint; problem = ""
        } catch { problem = (error as? DeliveryFailure)?.localizedDescription ?? "The device preference is saved here; server delivery will retry when the app reconnects." }
    }
    func start(store: GuestDataStore) {
        erased = false
        self.store = store
        preferencesChanged()
        updateConnection()
    }
    private func updateConnection() {
        guard !erased, UIApplication.shared.applicationState == .active,
              store != nil, let code = HouseholdSync.shared.joinCode, sharesAnything else { stop(); return }
        if connectedCode == code, transportTask != nil { return }
        stop(); connectedCode = code; latestRevision = 0
        let current = generation
        transportTask = Task { @MainActor [weak self] in
            var delay = 2
            while !Task.isCancelled {
                guard let self, current == self.generation, code == HouseholdSync.shared.joinCode,
                      UIApplication.shared.applicationState == .active, let base = StockedWorkerClient.url(),
                      var components = URLComponents(url: base.appendingPathComponent("household/realtime"), resolvingAgainstBaseURL: false), components.scheme == "https" else { return }
                components.scheme = "wss"
                guard let url = components.url else { return }
                var request = URLRequest(url: url, timeoutInterval: 15)
                BuildConfig.authorizeWorkerRequest(&request)
                request.setValue(code, forHTTPHeaderField: "X-Household-Code")
                request.setValue(HouseholdSync.shared.memberId, forHTTPHeaderField: "X-Household-Member")
                let socket = self.network.webSocketTask(with: request)
                socket.maximumMessageSize = 2048
                self.socket = socket; socket.resume()
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        guard current == self.generation else { return }
                        guard self.sharesAnything, !self.erased else { self.stop(); return }
                        let data: Data
                        switch message { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: continue }
                        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String, ["household.connected", "household.changed"].contains(type),
                              let revision = event["revision"] as? Int, revision >= 0 else { continue }
                        self.isConnected = true; self.connection = "Live updates connected"; delay = 2
                        if revision > self.latestRevision { self.latestRevision = revision; self.queuePull() }
                    }
                } catch { }
                socket.cancel(with: .goingAway, reason: nil)
                guard !Task.isCancelled, current == self.generation else { return }
                self.isConnected = false; self.connection = "Reconnecting; polling still works"
                try? await Task.sleep(for: .seconds(delay)); delay = min(delay * 2, 60)
            }
        }
    }
    private func queuePull() {
        guard !erased, sharesAnything else { return }
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self else { return }
            self.refreshTask = nil
            guard !self.erased, self.sharesAnything else { return }
            guard let store = self.store else { return }
            await HouseholdSync.shared.pullNow(into: store)
        }
    }
    func stop() {
        generation = UUID(); transportTask?.cancel(); transportTask = nil
        refreshTask?.cancel(); refreshTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        isConnected = false; connectedCode = nil; connection = "Polling is available"
    }
    func leaving(code: String) async {
        if UserDefaults.standard.bool(forKey: "delivery.registered.\(code)") {
            _ = try? await post("device", code: code, extra: ["enabled": false, "deviceCapability": deviceCapability])
        }
        UserDefaults.standard.removeObject(forKey: "delivery.apple.\(code)")
        UserDefaults.standard.removeObject(forKey: "delivery.registered.\(code)")
        HouseholdDeliveryKeychain.remove("owner.\(code)")
        if HouseholdSync.shared.joinCode == nil || HouseholdSync.shared.joinCode == code {
            status = nil; lastRegistration = ""; stop()
        }
    }
    /// Clear local delivery state only. A separately enabled receiver remains a server setting;
    /// the owner must turn it off explicitly before erasing their owner key.
    func clearLocalState() throws {
        erased = true
        preferenceTask?.cancel(); preferenceTask = nil
        stop(); network.invalidateAndCancel()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        network = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        HouseholdSync.shared.resetForLocalErase()
        status = nil; lastRegistration = ""; registeredWithApple = false
        for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("delivery.apple.") || key.hasPrefix("delivery.registered.") {
            UserDefaults.standard.removeObject(forKey: key)
        }
        try HouseholdDeliveryKeychain.clearAll()
    }
    func receiveBackgroundInvalidation() async -> Bool {
        await refreshPermission()
        guard permission == "Allowed" else { return false }
        guard deviceOptIn, masterNotificationsEnabled, sharesAnything, let store = HouseholdShareBridge.shared.store else { return false }
        await HouseholdSync.shared.pullNow(into: store)
        return true
    }
    /// Development/ad-hoc builds embed a signed provisioning profile. App Store builds omit it
    /// and use production APNs. This follows the signing profile rather than the DEBUG flag.
    private static var appleEnvironment: String {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url), data.count <= 2 * 1024 * 1024,
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"), let end = text.range(of: "</plist>", range: start.lowerBound..<text.endIndex),
              let xml = String(text[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
              let object = try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any],
              let entitlements = object["Entitlements"] as? [String: Any],
              entitlements["aps-environment"] as? String == "development" else { return "production" }
        return "development"
    }
    nonisolated enum DeliveryFailure: LocalizedError {
        case unavailable, setupRequired, ownerRequired, receiver
        var errorDescription: String? {
            switch self {
            case .unavailable: "Delivery couldn't be updated. Check your connection and try again."
            case .setupRequired: "Apple push or server encryption needs server setup first. Polling still works."
            case .ownerRequired: "Webhook setup requires the device that created this secure share. Existing household data stays unchanged."
            case .receiver: "Enter an HTTPS worker.account.workers.dev receiver without a query, port or fragment."
            }
        }
    }
}
