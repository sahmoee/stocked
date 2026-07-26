// QAFullDiagnostics.swift — the QA menu's "run everything" button.
//
// One tap sweeps every layer the app depends on and returns a sectioned report:
//   • Invariants — the full QAInvariants suite (forced, ignoring the change cache)
//   • Backend    — live GET /health on the Worker, remote-config freshness, session token
//   • Connectivity — both monitors, and whether they agree
//   • Sync       — household state, pending/stuck ops, offline queue, last successes
//   • Notifications — authorization + pending count vs the 64-slot iOS budget
//   • Data integrity — tombstone backlog, empty names, plan-day range, reservation conflicts
//   • Storage    — documents footprint, diagnostics log presence
//   • Session    — resumable cook record sanity
//
// Rows reuse QAInvariantResult so the QA screen renders them with the same styling
// and severity language. The report is exportable and can be uploaded to
// POST /support/diagnostics for an STK- reference. Factored from the retired QA
// Workbook's "full check" idea, rebuilt on the new invariant engine.

import Foundation
import UIKit
@preconcurrency import UserNotifications

nonisolated struct QADiagnosticsSection: Identifiable, Sendable {
    var id = UUID()
    let title: String
    let rows: [QAInvariantResult]
}

nonisolated struct QADiagnosticsReport: Sendable {
    let startedAt: Date
    let duration: TimeInterval
    let sections: [QADiagnosticsSection]

    var violationCount: Int { sections.flatMap(\.rows).filter { $0.status == .violation }.count }
    var blockedCount: Int   { sections.flatMap(\.rows).filter { $0.status == .blocked }.count }
    var verdict: String {
        violationCount == 0
            ? "PASS — no violations (\(blockedCount) check(s) lacked data)"
            : "\(violationCount) violation(s) — see red rows"
    }

    var exportText: String {
        var out = ["Stocked Full Diagnostics — \(startedAt.formatted()) (\(String(format: "%.1f", duration))s)",
                   "Build \(BuildConfig.buildNumber) · v\(BuildConfig.version)", "Verdict: \(verdict)", ""]
        for s in sections {
            out.append("== \(s.title) ==")
            for r in s.rows { out.append("[\(r.status.rawValue.uppercased())] \(r.name): \(r.detail)") }
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}

@MainActor
enum QAFullDiagnostics {

    static func run(store: GuestDataStore, session: CookNowSession?) async -> QADiagnosticsReport {
        let started = Date()
        var sections: [QADiagnosticsSection] = []

        // 1 — Invariants (forced full suite).
        sections.append(QADiagnosticsSection(title: "Invariants",
                                             rows: QAInvariants.runAll(store: store, session: session)))

        // 2 — Backend.
        var backend: [QAInvariantResult] = []
        backend.append(await workerHealth())
        if let last = StockedRemoteConfig.shared.lastFetched {
            let age = Int(Date().timeIntervalSince(last) / 60)
            let kills = StockedRemoteConfig.shared.config.killSwitches.filter { $0.value }.map(\.key)
            backend.append(QAInvariantResult(name: "Remote configuration", status: .ok,
                detail: "fetched \(age)m ago" + (kills.isEmpty ? ", nothing killed" : ", ACTIVE kill switches: \(kills.joined(separator: ", "))"),
                critical: false))
        } else {
            backend.append(QAInvariantResult(name: "Remote configuration", status: .blocked,
                detail: "never fetched this session — offline, or the Worker was unreachable", critical: false))
        }
        if StockedRemoteConfig.shared.updateRequired {
            backend.append(QAInvariantResult(name: "Minimum version", status: .violation,
                detail: "server says this build is below minSupportedVersion", critical: true))
        }
        let token = await StockedSession.shared.currentToken()
        backend.append(QAInvariantResult(name: "Session token", status: token == nil ? .blocked : .ok,
            detail: token == nil ? "no session token (requests still authorize via X-Stocked-Key)" : "short-lived session token present",
            critical: false))
        sections.append(QADiagnosticsSection(title: "Backend", rows: backend))

        // 3 — Connectivity.
        let nm = NetworkMonitor.shared
        let agree = !nm.hasEvaluated || (nm.isOnline == ConnectivityMonitor.isOnlineFlag)
        sections.append(QADiagnosticsSection(title: "Connectivity", rows: [
            QAInvariantResult(name: "Network path", status: nm.hasEvaluated ? .ok : .blocked,
                detail: nm.hasEvaluated ? "\(nm.isOnline ? "online" : "OFFLINE") via \(nm.connection.rawValue)" : "no path evaluation yet",
                critical: false),
            QAInvariantResult(name: "Monitors agree", status: agree ? .ok : .violation,
                detail: agree ? "NetworkMonitor and ConnectivityMonitor report the same state"
                              : "monitors disagree — offline gating may be inconsistent", critical: false),
        ]))

        // 4 — Sync.
        var sync: [QAInvariantResult] = []
        let hh = HouseholdSync.shared
        if hh.state == .owner || hh.state == .member {
            let s = hh.syncStatus
            let stuck = s.hasStuckOperations
            sync.append(QAInvariantResult(name: "Household sync", status: stuck ? .violation : .ok,
                detail: "\(hh.pendingOps.count) pending op(s)" + (stuck ? " — STUCK, needs attention" : "")
                        + ((s.lastError?.isEmpty == false) ? " · last error: \(s.lastError!)" : ""),
                critical: stuck))
        } else {
            sync.append(QAInvariantResult(name: "Household sync", status: .blocked,
                detail: "not in a household — nothing to probe", critical: false))
        }
        let oq = OfflineQueueCenter.shared
        sync.append(QAInvariantResult(name: "Offline queue", status: .ok,
            detail: oq.pendingCount == 0 ? "empty" : "\(oq.pendingCount) item(s) waiting\(oq.isOffline ? " (device offline — expected)" : "")",
            critical: false))
        sections.append(QADiagnosticsSection(title: "Sync", rows: sync))

        // 5 — Notifications.
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        let pending = await center.pendingNotificationRequests()
        var notif: [QAInvariantResult] = []
        notif.append(QAInvariantResult(name: "Authorization", status: .ok,
            detail: String(describing: settings.authorizationStatus).replacingOccurrences(of: "UNAuthorizationStatus.", with: ""),
            critical: false))
        notif.append(QAInvariantResult(name: "Pending budget", status: pending.count > 60 ? .violation : .ok,
            detail: "\(pending.count)/64 pending local notifications" + (pending.count > 60 ? " — at the iOS cap, new ones will drop silently" : ""),
            critical: false))
        sections.append(QADiagnosticsSection(title: "Notifications", rows: notif))

        // 6 — Data integrity.
        var integrity: [QAInvariantResult] = []
        let tombs = store.pendingInvTombstones.count + store.pendingGroTombstones.count
                  + store.pendingUserRecipeTombstones.count + store.pendingGenRecipeTombstones.count
                  + store.pendingMealTombstones.count
        integrity.append(QAInvariantResult(name: "Tombstone backlog", status: tombs > 200 ? .violation : .ok,
            detail: "\(tombs) deletion tombstone(s) awaiting a confirmed push", critical: false))
        let unnamed = store.inventoryItems.filter { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }.count
                    + store.groceryItems.filter { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }.count
        integrity.append(QAInvariantResult(name: "Nameless records", status: unnamed == 0 ? .ok : .violation,
            detail: unnamed == 0 ? "every inventory/grocery record has a name" : "\(unnamed) record(s) with empty names",
            critical: unnamed > 0))
        let badDays = store.plannedMeals.filter { $0.dayIndex < 0 || $0.dayIndex > 6 }.count
        integrity.append(QAInvariantResult(name: "Plan horizon", status: badDays == 0 ? .ok : .violation,
            detail: badDays == 0 ? "all planned meals inside the 7-day horizon" : "\(badDays) meal(s) outside dayIndex 0…6",
            critical: badDays > 0))
        let snap = ReservationLedger.shared.snapshot
        integrity.append(QAInvariantResult(name: "Plan conflicts", status: .ok,
            detail: "\(snap.conflicts.count) conflict(s), \(snap.shortages.count) shortage(s) currently projected",
            critical: false))
        sections.append(QADiagnosticsSection(title: "Data integrity", rows: integrity))

        // 7 — Storage.
        var storage: [QAInvariantResult] = []
        if let docs = try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            let bytes = folderSize(docs)
            storage.append(QAInvariantResult(name: "Documents footprint", status: .ok,
                detail: ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file), critical: false))
        }
        let diagLog = DiagnosticsMonitor.shared.currentLog()
        storage.append(QAInvariantResult(name: "Crash/hang log", status: .ok,
            detail: diagLog.isEmpty ? "no MetricKit diagnostics recorded (good)" : "\(diagLog.count) chars recorded — review in Sync Diagnostics",
            critical: false))
        sections.append(QADiagnosticsSection(title: "Storage", rows: storage))

        // 8 — Cook session record.
        let resumable = ActiveCookSessionStore.shared.resumable
        sections.append(QADiagnosticsSection(title: "Cook session", rows: [
            QAInvariantResult(name: "Active record", status: .ok,
                detail: resumable == nil ? "none (clean)" : "resumable session: \(resumable!.recipeTitle)",
                critical: false),
        ]))

        return QADiagnosticsReport(startedAt: started,
                                   duration: Date().timeIntervalSince(started),
                                   sections: sections)
    }

    // MARK: - Helpers

    private static func workerHealth() async -> QAInvariantResult {
        guard let base = StockedWorkerClient.url() else {
            return QAInvariantResult(name: "Worker /health", status: .blocked, detail: "worker URL not configured", critical: false)
        }
        guard ConnectivityMonitor.isOnlineFlag else {
            return QAInvariantResult(name: "Worker /health", status: .blocked, detail: "offline — skipped", critical: false)
        }
        var request = URLRequest(url: base.appendingPathComponent("health"))
        request.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return QAInvariantResult(name: "Worker /health", status: .violation,
                                         detail: "unexpected response from \(base.host ?? "worker")", critical: true)
            }
            let ok = (obj["ok"] as? Bool) == true
            let missing = ["hasAnthropicKey", "hasSharedKey", "hasSessionKey", "hasHouseholdDO"]
                .filter { (obj[$0] as? Bool) != true }
            let version = obj["version"] as? String ?? "?"
            if ok && missing.isEmpty {
                return QAInvariantResult(name: "Worker /health", status: .ok,
                                         detail: "healthy · \(version) · all bindings present", critical: false)
            }
            return QAInvariantResult(name: "Worker /health", status: .violation,
                                     detail: "version \(version), missing: \(missing.joined(separator: ", "))", critical: true)
        } catch {
            return QAInvariantResult(name: "Worker /health", status: .violation,
                                     detail: "unreachable: \(error.localizedDescription)", critical: true)
        }
    }

    private static nonisolated func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey],
                                                  options: [.skipsHiddenFiles]) {
            for case let f as URL in e {
                total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return total
    }
}
