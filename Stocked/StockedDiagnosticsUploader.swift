// StockedDiagnosticsUploader.swift — app adoption of the Worker's POST /support/diagnostics.
//
// Builds a SCRUBBED diagnostic snapshot (no inventory names, no recipes, no personal data —
// only counts, versions, device class, and the MetricKit/sync health signals that already
// exist on-device), uploads it, and returns the Worker's reference number (e.g.
// "STK-XXXXXXXXXX") that the user can quote in a support email. See FUTURE_IDEAS.md.

import Foundation
import UIKit
import os

@MainActor
enum StockedDiagnosticsUploader {

    enum UploadError: Error, LocalizedError {
        case notConfigured, offline, failed(String)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Support diagnostics aren't available in this build."
            case .offline:       return "You're offline — try again when connected."
            case .failed(let m): return m
            }
        }
    }

    /// Assemble the privacy-scrubbed payload. Deliberately contains NO item/recipe names.
    static func buildPayload(session: AppSession) -> [String: Any] {
        let store = session.guestStore
        let sync = HouseholdSync.shared.syncStatus
        var payload: [String: Any] = [
            "appVersion": BuildConfig.version,
            "build": BuildConfig.buildNumber,
            "ios": UIDevice.current.systemVersion,
            "device": UIDevice.current.model,
            "locale": Locale.current.identifier,
            "counts": [
                "inventory": store.inventoryItems.count,
                "grocery": store.groceryItems.count,
                "plannedMeals": store.plannedMeals.count,
                "userRecipes": store.userRecipes.count,
                "savedRecipes": store.savedGeneratedRecipes.count,
                "pastMeals": store.pastMeals.count,
            ],
            "household": [
                "inHousehold": HouseholdSync.shared.state == .owner || HouseholdSync.shared.state == .member,
                "pendingOps": HouseholdSync.shared.pendingOps.count,
                "stuck": sync.hasStuckOperations,
                "lastError": sync.lastError ?? "",
            ],
            "metricLog": DiagnosticsMonitor.shared.currentLog().suffix(4000).description,
        ]
        payload["timestamp"] = ISO8601DateFormatter().string(from: Date())
        return payload
    }

    /// Upload and return the support reference number.
    static func upload(session: AppSession) async throws -> String {
        guard let base = StockedWorkerClient.url() else { throw UploadError.notConfigured }
        guard ConnectivityMonitor.isOnlineFlag else { throw UploadError.offline }

        var request = URLRequest(url: base.appendingPathComponent("support/diagnostics"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&request)
        request.timeoutInterval = 15
        request.httpBody = try? JSONSerialization.data(withJSONObject: buildPayload(session: session))

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let ref = obj["reference"] as? String, !ref.isEmpty else {
                throw UploadError.failed("The diagnostics service didn't accept the report.")
            }
            return ref
        } catch let e as UploadError { throw e }
        catch { throw UploadError.failed(error.localizedDescription) }
    }
}
