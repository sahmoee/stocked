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

    /// Fire-and-forget. Call from a deferred launch task. No-ops unless: in a household,
    /// online, worker configured, and >12h since the last upload.
    static func uploadIfNeeded(store: GuestDataStore) {
        let sync = HouseholdSync.shared
        guard sync.state == .owner || sync.state == .member, let code = sync.joinCode else { return }
        guard StockedWorkerClient.isConfigured, ConnectivityMonitor.isOnlineFlag,
              let base = StockedWorkerClient.url() else { return }
        let last = UserDefaults.standard.double(forKey: lastUploadKey)
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
        let payload: [String: Any] = [
            "code": code,
            "inventory": inventory,
            "grocery": grocery,
            "plannedMeals": store.plannedMeals.map { _ in ["planned": true] },
            "planHorizonDays": 7,
        ]

        var request = URLRequest(url: base.appendingPathComponent("daily-brief/context"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&request)
        request.timeoutInterval = 12
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        Task {
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) {
                    await MainActor.run {
                        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastUploadKey)
                    }
                }
            } catch {
                Log.net.debug("Brief context upload skipped: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
