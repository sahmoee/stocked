import Foundation
import Observation
@preconcurrency import UserNotifications

@MainActor @Observable final class CommunityPriceWatchStore {
    static let shared = CommunityPriceWatchStore()
    @ObservationIgnored private let file = FeatureStore<CommunityPriceWatch>(key: FeatureStoreKeys.communityPriceWatches)
    private(set) var watches: [CommunityPriceWatch] = []
    private(set) var refreshing: UUID?
    private(set) var status = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    var alertsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(alertsEnabled, forKey: "communityPriceAlerts_v1")
            if !alertsEnabled { removeAlerts(watches.map(\.id)) }
        }
    }
    private init() {
        alertsEnabled = UserDefaults.standard.bool(forKey: "communityPriceAlerts_v1")
        watches = file.load()
    }
    func flush() { file.flush() }
    private func persist() { file.save(watches); file.flush() }

    func save(_ draft: CommunityPriceWatch, baseline: CommunityPriceWatch?) throws {
        var value = try draft.validated()
        let old = watches.first { $0.id == value.id }
        // Network results may change while the editor is open; only configuration edits conflict.
        guard old?.editID == baseline?.editID else { throw CommunityPriceWatch.Failure.changed }
        guard old != nil || watches.count < 20 else { throw CommunityPriceWatch.Failure.limit }
        value.editID = UUID()
        value.lastAttempt = nil; value.lastSuccess = nil; value.failure = nil; value.match = nil
        value.excludedCount = 0; value.lastAlertKey = old?.lastAlertKey
        watches.removeAll { $0.id == value.id }; watches.append(value)
        removeAlerts([value.id]); persist()
    }
    func remove(_ value: CommunityPriceWatch) throws {
        guard watches.first(where: { $0.id == value.id })?.editID == value.editID else { throw CommunityPriceWatch.Failure.changed }
        watches.removeAll { $0.id == value.id }; removeAlerts([value.id]); persist()
    }
    func clear() {
        cancel(); removeAlerts(watches.map(\.id)); watches = []; alertsEnabled = false
        file.clear()
    }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; refreshing = nil }
    func refresh(_ id: UUID? = nil) {
        guard refreshing == nil else { return }
        let chosen = Array(watches.filter { !$0.paused && (id == nil || $0.id == id) }.prefix(20))
        guard !chosen.isEmpty else { status = "Add or resume a saved price check first."; return }
        generation = UUID(); let token = generation
        task = Task {
            defer { if generation == token { refreshing = nil; task = nil } }
            var successes = 0, failures = 0, cooled = 0
            for original in chosen {
                guard !Task.isCancelled, generation == token else { return }
                guard let index = watches.firstIndex(where: { $0.id == original.id && $0.editID == original.editID && !$0.paused }) else { continue }
                if let attempt = watches[index].lastAttempt, Date().timeIntervalSince(attempt) < 60 {
                    cooled += 1; continue
                }
                refreshing = original.id
                watches[index].lastAttempt = Date(); persist()
                do {
                    let response = try await CommunityPricesClient.shared.lookup(original.barcode)
                    try Task.checkCancellation()
                    guard generation == token, let current = watches.firstIndex(where: { $0.id == original.id && $0.editID == original.editID && !$0.paused }) else { continue }
                    let result = try CommunityPriceWatchEngine.evaluate(response.observations, watch: original)
                    watches[current].match = result.match; watches[current].excludedCount = result.excluded
                    watches[current].lastSuccess = Date(); watches[current].failure = nil
                    let accepted = watches[current]; persist(); successes += 1
                    await notifyIfNeeded(accepted)
                } catch is CancellationError { return }
                catch {
                    guard generation == token, let current = watches.firstIndex(where: { $0.id == original.id && $0.editID == original.editID }) else { continue }
                    let message = (error as? CommunityPricesClient.Failure)?.errorDescription ?? "Could not check right now. Your previous result is kept."
                    watches[current].failure = message; persist(); failures += 1
                    if let failure = error as? CommunityPricesClient.Failure, case .limited = failure {
                        status = "The service asked us to slow down. Previous results are kept. Try again later."; return
                    }
                }
            }
            if generation == token {
                status = "Checked \(successes). \(failures) could not finish.\(cooled > 0 ? " Wait a minute before rechecking \(cooled) recently checked items." : "")"
            }
        }
    }
    private func notifyIfNeeded(_ value: CommunityPriceWatch) async {
        guard !Task.isCancelled, alertsEnabled, let match = value.match else { return }
        let key = CommunityPriceWatchEngine.alertKey(match)
        guard value.lastAlertKey != key else { return }
        let center = UNUserNotificationCenter.current()
        let permission = await center.notificationSettings()
        guard !Task.isCancelled, permission.authorizationStatus == .authorized || permission.authorizationStatus == .provisional,
              alertsEnabled, watches.contains(where: { $0.id == value.id && $0.editID == value.editID && $0.match == match }) else { return }
        let content = UNMutableNotificationContent()
        content.title = "Community price match"
        content.body = "A saved price is at or below your target. Open Stocked to check the date, location and discount terms."
        content.sound = .default
        let request = UNNotificationRequest(identifier: notificationID(value.id), content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 5, repeats: false))
        do {
            try await center.add(request)
            guard !Task.isCancelled, alertsEnabled, let index = watches.firstIndex(where: { $0.id == value.id && $0.editID == value.editID && $0.match == match }) else {
                removeAlerts([value.id]); return
            }
            watches[index].lastAlertKey = key; persist()
        } catch { status = "Prices were checked, but the alert could not be scheduled. Your results are saved here." }
    }
    private func notificationID(_ id: UUID) -> String { "stocked.communityPrice.\(id.uuidString)" }
    private func removeAlerts(_ ids: [UUID]) {
        let values = ids.map(notificationID)
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: values)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: values)
    }
}
