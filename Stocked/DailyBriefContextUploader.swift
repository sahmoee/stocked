// DailyBriefContextUploader.swift — feeds the Worker's scheduled daily-brief pipeline.
//
// The Worker already has the whole server side deployed (POST /daily-brief/generate,
// a 13:00 UTC cron, Queues consumer, and per-household brief storage) — but nothing
// ever uploaded the context snapshot it assembles briefs FROM. This closes that gap:
// once a day (throttled), household members upload a tiny scrubbed snapshot
// (names + expiry-day counts only — no quantities, notes, or history) to
// POST /daily-brief/context. The cron then generates a brief per household server-side.
// On-device brief assembly is untouched; this is purely additive and fail-silent.

import Foundation
import os

@MainActor
enum DailyBriefContextUploader {

    private static let lastUploadKey = "briefContextUploadedAt_v1"
    private static let minInterval: TimeInterval = 12 * 3600
    private static var uploadTask: Task<Void, Never>?

    static func cancelPendingUpload() {
        uploadTask?.cancel()
        uploadTask = nil
    }

    /// Fire-and-forget. Call from a deferred launch task. No-ops unless: in a household,
    /// online, worker configured, and >12h since the last upload.
    static func uploadIfNeeded(store: GuestDataStore) {
        let sync = HouseholdSync.shared
        guard sync.state == .owner || sync.state == .member, let code = sync.joinCode else { return }
        guard StockedWorkerClient.isConfigured, ConnectivityMonitor.isOnlineFlag,
              let base = StockedWorkerClient.url() else { return }
        let epoch = sync.scopeEpoch
        let sharing = [sync.syncInventory, sync.syncGrocery, sync.syncMealPlans]
        let uploadKey = lastUploadKey + "_" + code + "_" + sharing.map { $0 ? "1" : "0" }.joined()
        let last = UserDefaults.standard.double(forKey: uploadKey)
        guard Date().timeIntervalSince1970 - last > minInterval else { return }

        let now = Date()
        let inventory: [[String: Any]] = store.inventoryItems.prefix(300).map { item in
            var entry: [String: Any] = ["name": item.name]
            if let exp = item.expirationDate {
                entry["daysUntilExpiry"] = Int(exp.timeIntervalSince(now) / 86400)
            }
            if item.updatedAt > 0 { entry["addedAt"] = item.updatedAt }   // ms; recency proxy
            return entry
        }
        let grocery: [[String: Any]] = store.groceryItems.prefix(200).map {
            ["name": $0.name, "isChecked": $0.isChecked]
        }
        let payload = contextPayload(code: code, inventory: inventory, grocery: grocery,
                                     mealCount: store.plannedMeals.count, sharing: sharing)

        var request = URLRequest(url: base.appendingPathComponent("daily-brief/context"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&request)
        guard HouseholdSync.shared.authorizeHouseholdRequest(&request) else { return }
        request.timeoutInterval = 12
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        cancelPendingUpload()
        uploadTask = Task {
            guard !Task.isCancelled, sync.isCurrentScope(epoch, code: code),
                  sharing == [sync.syncInventory, sync.syncGrocery, sync.syncMealPlans] else { return }
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    guard !Task.isCancelled, sync.isCurrentScope(epoch, code: code),
                          sharing == [sync.syncInventory, sync.syncGrocery, sync.syncMealPlans] else { return }
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: uploadKey)
                }
            } catch {
                Log.net.debug("Brief context upload skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Disabled sections are omitted; the server replaces prior context instead of retaining it.
    static func contextPayload(code: String, inventory: [[String: Any]], grocery: [[String: Any]],
                               mealCount: Int, sharing: [Bool]) -> [String: Any] {
        guard sharing.count == 3 else { return ["code": code, "planHorizonDays": 7] }
        var payload: [String: Any] = ["code": code, "planHorizonDays": 7]
        if sharing[0] { payload["inventory"] = inventory }
        if sharing[1] { payload["grocery"] = grocery }
        if sharing[2] { payload["plannedMeals"] = (0..<min(max(0, mealCount), 300)).map { _ in ["planned": true] } }
        return payload
    }
}
