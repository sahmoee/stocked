import Foundation
import Security

nonisolated enum KitchenConnectionKind: String, CaseIterable, Sendable { case grocy, caldav }
nonisolated struct KitchenConnectionCredentials: Codable, Sendable {
    var endpoint: String
    var username: String = ""
    var secret: String
    func validatedURL() throws -> URL {
        guard !secret.isEmpty, secret.utf8.count <= 4_096, username.utf8.count <= 500,
              !secret.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !username.contains(":"), !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw KitchenConnectionFailure.credentials
        }
        return try KitchenConnectionPolicy.endpoint(endpoint)
    }
}

/// This-device-only Keychain items are never part of household payloads or app backups.
nonisolated enum KitchenConnectionVault {
    private static let service = "com.sowens.Stocked.free-kitchen-connections.v1"
    private static func query(_ kind: KitchenConnectionKind) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: kind.rawValue, kSecAttrSynchronizable as String: false]
    }
    static func load(_ kind: KitchenConnectionKind) throws -> KitchenConnectionCredentials? {
        var q = query(kind); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var raw: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &raw)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = raw as? Data,
              let value = try? JSONDecoder().decode(KitchenConnectionCredentials.self, from: data) else { throw KitchenConnectionFailure.storage }
        return value
    }
    static func save(_ value: KitchenConnectionCredentials, kind: KitchenConnectionKind) throws {
        _ = try value.validatedURL()
        let data = try JSONEncoder().encode(value)
        let update = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
        let status = SecItemUpdate(query(kind) as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(kind); q.merge(update) { _, new in new }
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw KitchenConnectionFailure.storage }
        } else if status != errSecSuccess { throw KitchenConnectionFailure.storage }
    }
    static func remove(_ kind: KitchenConnectionKind) throws {
        let status = SecItemDelete(query(kind) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KitchenConnectionFailure.storage }
    }
}

nonisolated struct KitchenConnectionResponse: Sendable { let status: Int; let data: Data; let etag: String? }
nonisolated protocol KitchenConnectionTransport: Sendable {
    func send(_ request: URLRequest, origin: URL, maximumBytes: Int) async throws -> KitchenConnectionResponse
}

/// Revalidate before every request, not just before a multi-request operation.
/// Injected checks/transports let the revocation boundary be tested without Keychain access.
nonisolated struct KitchenGuardedConnectionTransport: KitchenConnectionTransport {
    let transport: any KitchenConnectionTransport
    let verifyCurrent: @Sendable () async throws -> Void

    @MainActor static func saved(_ credentials: KitchenConnectionCredentials, kind: KitchenConnectionKind) -> Self {
        let revision = KitchenConnectionReset.revision
        return Self(transport: KitchenHTTPSConnection(), verifyCurrent: {
            try await MainActor.run {
                guard revision == KitchenConnectionReset.revision,
                      let saved = try KitchenConnectionVault.load(kind),
                      saved.endpoint == credentials.endpoint, saved.username == credentials.username,
                      saved.secret == credentials.secret else { throw KitchenConnectionFailure.changed }
            }
        })
    }

    func send(_ request: URLRequest, origin: URL, maximumBytes: Int) async throws -> KitchenConnectionResponse {
        try Task.checkCancellation()
        try await verifyCurrent()
        try Task.checkCancellation()
        return try await transport.send(request, origin: origin, maximumBytes: maximumBytes)
    }
}

private nonisolated final class KitchenHTTPSConnection: KitchenConnectionTransport, @unchecked Sendable {
    private final class Delegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
        func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
                              ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
        }
    }
    func send(_ request: URLRequest, origin: URL, maximumBytes: Int) async throws -> KitchenConnectionResponse {
        guard let url = request.url, KitchenConnectionPolicy.sameOrigin(origin, url),
              maximumBytes > 0, maximumBytes <= KitchenConnectionPolicy.maximumResponseBytes else { throw KitchenConnectionFailure.endpoint }
        try Task.checkCancellation()
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.urlCredentialStorage = nil
        config.urlCache = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 25; config.timeoutIntervalForResource = 35
        let session = URLSession(configuration: config, delegate: Delegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, let final = response.url,
                  KitchenConnectionPolicy.sameOrigin(origin, final) else { throw KitchenConnectionFailure.endpoint }
            if response.statusCode == 401 || response.statusCode == 403 { throw KitchenConnectionFailure.credentials }
            if response.statusCode == 429 { throw KitchenConnectionFailure.rateLimited }
            if response.statusCode == 412 { throw KitchenConnectionFailure.conflict }
            guard response.statusCode == 404 || (200..<300).contains(response.statusCode) else { throw KitchenConnectionFailure.response }
            guard response.expectedContentLength <= maximumBytes else { throw KitchenConnectionFailure.tooLarge }
            var data = Data()
            for try await byte in bytes {
                try Task.checkCancellation()
                guard data.count < maximumBytes else { throw KitchenConnectionFailure.tooLarge }
                data.append(byte)
            }
            return KitchenConnectionResponse(status: response.statusCode, data: data, etag: response.value(forHTTPHeaderField: "ETag"))
        } catch is CancellationError { throw CancellationError() }
        catch let failure as KitchenConnectionFailure { throw failure }
        catch { if Task.isCancelled { throw CancellationError() }; throw KitchenConnectionFailure.network }
    }
}

nonisolated enum GrocyConnectionClient {
    static func read(_ credentials: KitchenConnectionCredentials,
                     transport: any KitchenConnectionTransport) async throws -> [GrocyImportRow] {
        var base = try credentials.validatedURL()
        if base.lastPathComponent != "api" { base.appendPathComponent("api") }
        func get(_ path: String, limit: Int? = nil) async throws -> Data {
            let url = base.appendingPathComponent(path)
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            if let limit { parts.queryItems = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "order", value: "id")] }
            var request = URLRequest(url: parts.url!); request.setValue(credentials.secret, forHTTPHeaderField: "GROCY-API-KEY")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            let response = try await transport.send(request, origin: base, maximumBytes: KitchenConnectionPolicy.maximumResponseBytes)
            guard response.status == 200 else { throw KitchenConnectionFailure.response }
            return response.data
        }
        let stock = try await get("stock")
        let shopping = try await get("objects/shopping_list", limit: 501)
        let products = try await get("objects/products", limit: 2_001)
        let units = try await get("objects/quantity_units", limit: 1_001)
        try Task.checkCancellation()
        return try GrocyReadParser.parse(stock: stock, shopping: shopping, products: products, units: units)
    }
}

nonisolated struct CalDAVWriteReceipt: Codable, Sendable, Equatable {
    let uid: String
    let etag: String
    let bodyHash: String
    let contentKey: String
    let savedAt: Date
}
nonisolated struct CalDAVReviewRow: Identifiable, Sendable, Equatable {
    enum Action: String, Sendable { case create, update, unchanged, conflict }
    var id: String { meal.id }
    let meal: CalDAVMeal
    let url: URL
    let action: Action
    let etag: String?
    var mayPublish: Bool { action == .create || action == .update }
}

nonisolated enum CalDAVConnectionClient {
    static func request(_ url: URL, method: String, credentials: KitchenConnectionCredentials) throws -> URLRequest {
        let origin = try credentials.validatedURL()
        guard KitchenConnectionPolicy.sameOrigin(origin, url), !credentials.username.isEmpty else { throw KitchenConnectionFailure.credentials }
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Basic " + Data("\(credentials.username):\(credentials.secret)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        return request
    }
    static func calendars(_ credentials: KitchenConnectionCredentials,
                          transport: any KitchenConnectionTransport) async throws -> [CalDAVCalendar] {
        let base = try credentials.validatedURL()
        var request = try request(base, method: "PROPFIND", credentials: credentials)
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:" xmlns:c="urn:ietf:params:xml:ns:caldav"><d:prop><d:displayname/><d:resourcetype/><c:supported-calendar-component-set/></d:prop></d:propfind>
        """.utf8)
        let response = try await transport.send(request, origin: base, maximumBytes: 512 * 1024)
        guard response.status == 207 else { throw KitchenConnectionFailure.response }
        let calendars = try CalDAVReadParser.calendars(response.data, base: base)
        guard !calendars.isEmpty else { throw KitchenConnectionFailure.noCalendars }
        return calendars
    }
    static func preflight(_ meal: CalDAVMeal, calendar: CalDAVCalendar, credentials: KitchenConnectionCredentials,
                          receipt: CalDAVWriteReceipt?, transport: any KitchenConnectionTransport) async throws -> CalDAVReviewRow {
        _ = try CalDAVMealExport.calendar(meal)
        let origin = try credentials.validatedURL(), url = calendar.url.appendingPathComponent(meal.filename)
        let response = try await transport.send(request(url, method: "GET", credentials: credentials), origin: origin, maximumBytes: 64 * 1024)
        return review(meal, url: url, response: response, receipt: receipt)
    }
    static func review(_ meal: CalDAVMeal, url: URL, response: KitchenConnectionResponse, receipt: CalDAVWriteReceipt?) -> CalDAVReviewRow {
        let etag = CalDAVMealExport.strongETag(response.etag)
        let action: CalDAVReviewRow.Action
        if response.status == 404 { action = .create }
        else if response.status == 200, let receipt, let etag, receipt.uid == meal.uid, receipt.etag == etag,
                receipt.bodyHash == KitchenConnectionPolicy.hash(response.data), CalDAVMealExport.isOwnEvent(response.data, uid: meal.uid) {
            action = receipt.contentKey == meal.contentKey ? .unchanged : .update
        } else { action = .conflict }
        return CalDAVReviewRow(meal: meal, url: url, action: action, etag: etag)
    }
    static func publish(_ row: CalDAVReviewRow, credentials: KitchenConnectionCredentials,
                        transport: any KitchenConnectionTransport) async throws -> CalDAVWriteReceipt {
        guard row.mayPublish else { throw KitchenConnectionFailure.conflict }
        let origin = try credentials.validatedURL()
        var request = try request(row.url, method: "PUT", credentials: credentials)
        if row.action == .create { request.setValue("*", forHTTPHeaderField: "If-None-Match") }
        else {
            guard let etag = CalDAVMealExport.strongETag(row.etag) else { throw KitchenConnectionFailure.conflict }
            request.setValue(etag, forHTTPHeaderField: "If-Match")
        }
        let body = try CalDAVMealExport.calendar(row.meal)
        request.httpBody = body; request.setValue("text/calendar; charset=utf-8", forHTTPHeaderField: "Content-Type")
        let response = try await transport.send(request, origin: origin, maximumBytes: 64 * 1024)
        guard [200, 201, 204].contains(response.status) else { throw KitchenConnectionFailure.response }
        if let etag = CalDAVMealExport.strongETag(response.etag) {
            return CalDAVWriteReceipt(uid: row.meal.uid, etag: etag, bodyHash: KitchenConnectionPolicy.hash(body), contentKey: row.meal.contentKey, savedAt: Date())
        }
        // Without a PUT ETag, only an exact byte match proves that no other writer
        // changed the event between PUT and GET. Server-normalized copies stay unowned.
        let fetched = try await transport.send(Self.request(row.url, method: "GET", credentials: credentials), origin: origin, maximumBytes: 64 * 1024)
        guard fetched.status == 200, fetched.data == body, let etag = CalDAVMealExport.strongETag(fetched.etag),
              CalDAVMealExport.isOwnEvent(fetched.data, uid: row.meal.uid) else { throw KitchenConnectionFailure.conflict }
        return CalDAVWriteReceipt(uid: row.meal.uid, etag: etag, bodyHash: KitchenConnectionPolicy.hash(fetched.data), contentKey: row.meal.contentKey, savedAt: Date())
    }
}

/// Local hashes/receipts only. No account secret, source document, or event body is persisted here.
@MainActor enum KitchenConnectionLedger {
    private static let grocyKey = "stocked.freeConnections.grocyImported.v1"
    private static let calendarKey = "stocked.freeConnections.calendarReceipts.v1"
    static func importKey(endpoint: String, row: GrocyImportRow) -> String {
        KitchenConnectionPolicy.hash(endpoint + "|" + row.id)
    }
    static func imported() -> [String: String] { UserDefaults.standard.dictionary(forKey: grocyKey) as? [String: String] ?? [:] }
    static func remember(endpoint: String, row: GrocyImportRow) throws {
        var entries = imported(), key = importKey(endpoint: endpoint, row: row)
        guard entries[key] != nil || entries.count < 5_000 else { throw KitchenConnectionFailure.tooLarge }
        entries[key] = row.fingerprint; UserDefaults.standard.set(entries, forKey: grocyKey)
    }
    static func receipts() -> [String: CalDAVWriteReceipt] {
        guard let data = UserDefaults.standard.data(forKey: calendarKey) else { return [:] }
        return (try? JSONDecoder().decode([String: CalDAVWriteReceipt].self, from: data)) ?? [:]
    }
    static func receipt(for url: URL) -> CalDAVWriteReceipt? { receipts()[KitchenConnectionPolicy.hash(url.absoluteString)] }
    static func remember(_ receipt: CalDAVWriteReceipt, url: URL) throws {
        var values = receipts(); values[KitchenConnectionPolicy.hash(url.absoluteString)] = receipt
        if values.count > 500 {
            let remove = values.sorted { $0.value.savedAt < $1.value.savedAt }.prefix(values.count - 500).map(\.key)
            for key in remove { values[key] = nil }
        }
        UserDefaults.standard.set(try JSONEncoder().encode(values), forKey: calendarKey)
    }
    static func clear() {
        UserDefaults.standard.removeObject(forKey: grocyKey)
        UserDefaults.standard.removeObject(forKey: calendarKey)
    }
}

@MainActor enum KitchenConnectionReset {
    private(set) static var revision: UInt64 = 0
    /// Attempt every local deletion and invalidate remaining batch work, even if the
    /// locked Keychain rejects one item. The caller must surface the sanitized failure.
    static func clearLocalState() throws {
        revision &+= 1
        var failed = false
        for kind in KitchenConnectionKind.allCases {
            do { try KitchenConnectionVault.remove(kind) } catch { failed = true }
        }
        KitchenConnectionLedger.clear()
        if failed { throw KitchenConnectionFailure.storage }
    }
}
