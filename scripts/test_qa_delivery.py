#!/usr/bin/env python3
"""Run extracted production Swift delivery methods with in-memory destinations.

No app build, network, defaults, or ticket files. --baseline reads HEAD versions
and requires the known regression cases to fail. --candidate-baseline DIR reads a
pre-repair snapshot and requires the revision-race regressions to fail.
--merge-baseline DIR checks the pre-merge candidate for exactly two merge failures.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    cursor = opening + 1
    while depth:
        depth += (source[cursor] == '{') - (source[cursor] == '}')
        cursor += 1
    return source[start:cursor]


def source(path, baseline):
    if baseline:
        return subprocess.check_output(['git', 'show', 'HEAD:' + path], cwd=ROOT, text=True)
    return (ROOT / path).read_text()


STUBS = r'''
import Foundation

enum QACPanelSettings { static var isConfigured = false }
struct Context { var build = 1; var identity: String? }
struct QATicket {
    var id = UUID()
    var number: String
    var title = "local text"
    var mockupFile: String?
    var updatedAt = Date(timeIntervalSince1970: 1000)
    var syncError = ""
    var context = Context()
    var screenshotFile: String?
    var syncedAt: Date?
    var mirroredAt: Date?
    var shotSyncedAt: Date?
    var cpanelSyncedAt: Date?
    __FULLY_SYNCED__
}
struct QASyncBundle {
    var ticket: QATicket
    var shot: Data?
    var mockup: Data? = nil
    var number: String { ticket.number }
}
enum QASyncOutcome {
    case ok, failed(String)
    var succeeded: Bool { if case .ok = self { return true }; return false }
    var note: String { switch self { case .ok: return "ok"; case .failed(let r): return "failed — \(r)" } }
}
@MainActor enum Scenario {
    static var folderOK = true
    static var workerOK = true
    static var shotOK = true
    static var cpanelOK = true
    static var bytesAvailable = true
    static var imports: [QATicket] = []
    static var pullCount = 0
    static var publishHook: ((UUID) -> Void)?
    static var shotCalls = 0
    static var folderHook: ((UUID) -> Void)?
    static var shotHook: ((UUID) -> Void)?
    static var cpanelHook: ((UUID) -> Void)?
    static var transportThrows = false
    static var remoteRows: [[String: Any]] = []
    static var folderCalls = 0
    static var cpanelCalls = 0
}
enum BuildConfig { static let version = "test"; static let buildNumber = 1 }
@MainActor final class QAAccessGate {
    static let shared = QAAccessGate()
    var isUnlocked = true
}
@MainActor enum QAReportTransport {
    static func fetchDeviceTickets() async throws -> [[String: Any]] {
        Scenario.pullCount += 1
        let imported = Scenario.imports.map { ["number": $0.number, "title": $0.title,
            "updatedAt": ISO8601DateFormatter().string(from: $0.updatedAt)] as [String: Any] }
        Scenario.imports = []
        let rows = Scenario.remoteRows + imported
        Scenario.remoteRows = []
        return rows
    }
    static func post(_ payload: [String: Any]) async throws -> Bool {
        await Task.yield()
        let rows = payload["tickets"] as! [[String: Any]]
        for row in rows { Scenario.publishHook?(UUID(uuidString: row["id"] as! String)!) }
        if Scenario.transportThrows { throw NSError(domain: "fixture", code: 1) }
        return Scenario.workerOK
    }
}
@MainActor final class QASyncQueue {
    static let shared = QASyncQueue()
    var records: [String] = []
    func record(number: String, detail: [String]) { records += detail }
}
@MainActor final class QAFolderMirror {
    static let shared = QAFolderMirror()
    func write(_ bundle: QASyncBundle) async -> QASyncOutcome {
        await Task.yield()
        Scenario.folderCalls += 1
        Scenario.folderHook?(bundle.ticket.id)
        return Scenario.folderOK ? .ok : .failed("stub folder")
    }
    func rootDescription() async -> String { "memory" }
    func writeIndex(build: Int, lines: [String], summary: String) async -> Bool { true }
}
@MainActor enum QAShotUploader {
    static func upload(_ data: Data, number: String, kind: String) async -> QASyncOutcome {
        await Task.yield()
        if let ticket = QATicketStore.shared.tickets.first(where: { $0.number == number }) { Scenario.shotHook?(ticket.id) }
        Scenario.shotCalls += 1
        return Scenario.shotOK ? .ok : .failed("stub screenshot")
    }
}
@MainActor enum QACPanelClient {
    static func upload(_ bundle: QASyncBundle) async -> QASyncOutcome {
        await Task.yield()
        Scenario.cpanelCalls += 1
        Scenario.cpanelHook?(bundle.ticket.id)
        return Scenario.cpanelOK ? .ok : .failed("stub cPanel")
    }
}
@MainActor final class QATicketStore {
    static let shared = QATicketStore()
    var tickets: [QATicket] = []
    var unsynced: [QATicket] { tickets.filter { !$0.isFullySynced } }
    var lastSyncOutcome = ""
    func awaitScreenshotWrite(_ id: UUID) async {}
    func bundle(for id: UUID) async -> QASyncBundle? {
        guard let t = tickets.first(where: { $0.id == id }) else { return nil }
        return QASyncBundle(ticket: t, shot: t.screenshotFile != nil && Scenario.bytesAvailable ? Data([1]) : nil)
    }
    __STAMP_MIRRORED__
    __STAMP_SHOT__
    __STAMP_CPANEL__
    var isSyncing = false
    func save() {}
    func thumbnails(for batch: [QATicket]) async -> [UUID: String] { [:] }
    static func dictionary(for ticket: QATicket, thumbnail: String?) -> [String: Any] { ["id": ticket.id.uuidString] }
    func indexLines(forBuild: Int) -> (lines: [String], summary: String) { ([], "") }
    __PUBLISH__
    __PUSH__
    let cap = 1000
    func trim() {}
    __PULL__
    __REMOTE_DATE__
    // Remote wire decoding only is stubbed; merge, revision selection, evidence
    // preservation and refresh fan-out use the actual production methods.
    static func remoteTicket(_ row: [String: Any], number: String, title: String) -> QATicket {
        var t = QATicket(number: number)
        t.title = title
        t.updatedAt = remoteDate(row["updatedAt"])!
        t.syncedAt = Date()
        return t
    }
    __PUBLISH_UNSYNCED__
}
@MainActor final class QASyncCoordinator {
    static let shared = QASyncCoordinator()
    var isRunning = false
    var inFlight: Set<UUID> = []
    var lastOutcome = ""
    var lastDetail: [String] = []
    var folderLocation = ""
    __MIRROR_TICKET__
    __SYNC_EVERYWHERE__
    __SYNC_ALL__
}
@main struct Checks {
    @MainActor static func main() async {
        let store = QATicketStore.shared
        let sync = QASyncCoordinator.shared
        var failed: [String] = []
        func check(_ name: String, _ condition: Bool) {
            print("\(condition ? "PASS" : "FAIL") \(name)")
            if !condition { failed.append(name) }
        }
        func reset(_ tickets: [QATicket]) {
            store.tickets = tickets
            Scenario.folderOK = true; Scenario.workerOK = true
            Scenario.shotOK = true; Scenario.cpanelOK = true
            Scenario.bytesAvailable = true; Scenario.imports = []
            Scenario.publishHook = nil; Scenario.shotCalls = 0; Scenario.pullCount = 0
            Scenario.folderHook = nil; Scenario.shotHook = nil; Scenario.cpanelHook = nil
            Scenario.transportThrows = false
            Scenario.remoteRows = []; Scenario.folderCalls = 0; Scenario.cpanelCalls = 0
            QACPanelSettings.isConfigured = false
            QASyncQueue.shared.records = []
        }
        reset([QATicket(number: "success", screenshotFile: "fixture.jpg")])
        let success = await store.publishUnsynced()
        check("complete delivery", success && store.unsynced.isEmpty && Scenario.shotCalls == 1)

        reset([QATicket(number: "partial")]); Scenario.workerOK = false
        let any = await sync.syncEverywhere(store.tickets[0].id)
        check("any-landed semantics preserved", any && store.unsynced.count == 1)
        let partialCount = await sync.syncAllPending()
        check("partial count", partialCount == 0)
        let partialPublish = await store.publishUnsynced()
        check("partial publish", !partialPublish && store.unsynced.count == 1)

        reset([QATicket(number: "missing", screenshotFile: "retained.jpg")])
        Scenario.bytesAvailable = false
        let missingCount = await sync.syncAllPending()
        _ = await sync.syncAllPending()
        check("missing screenshot failure recorded", QASyncQueue.shared.records.filter { $0.hasPrefix("screenshot: failed") }.count == 2)
        check("missing screenshot stays pending", missingCount == 0 && store.unsynced.count == 1 && store.tickets[0].screenshotFile == "retained.jpg" && store.tickets[0].shotSyncedAt == nil && Scenario.shotCalls == 0)

        reset([QATicket(number: "shot-failed", screenshotFile: "fixture.jpg")]); Scenario.shotOK = false
        let shotFailure = await store.publishUnsynced()
        check("screenshot upload failure", !shotFailure && store.unsynced.count == 1)

        reset([QATicket(number: "cpanel")]); QACPanelSettings.isConfigured = true; Scenario.cpanelOK = false
        let cpFailure = await store.publishUnsynced()
        check("required cPanel failure", !cpFailure && store.unsynced.count == 1)

        reset([QATicket(number: "local")]); Scenario.imports = [QATicket(number: "import")]
        let importedSuccess = await store.publishUnsynced()
        check("pull imports complete", importedSuccess && store.tickets.count == 2 && store.unsynced.isEmpty)

        reset([]); Scenario.imports = [QATicket(number: "import")]; QACPanelSettings.isConfigured = true; Scenario.cpanelOK = false
        let emptyImport = await store.publishUnsynced()
        check("empty local queue pulls pending import", !emptyImport && Scenario.pullCount == 1 && store.unsynced.count == 1)

        reset([QATicket(number: "first"), QATicket(number: "second")])
        let firstID = store.tickets[0].id
        let secondID = store.tickets[1].id
        Scenario.publishHook = { id in
            if id == secondID, let i = store.tickets.firstIndex(where: { $0.id == firstID }) {
                // Deterministic interleaving: a previously completed ticket is edited
                // during a later destination await and its required stamps reset.
                store.tickets[i].syncedAt = nil
                store.tickets[i].mirroredAt = nil
            }
        }
        let editedCount = await sync.syncAllPending()
        check("final current-state count after edit", editedCount == 1 && store.unsynced.count == 1)

        reset([QATicket(number: "local")])
        Scenario.publishHook = { _ in
            if store.tickets.count == 1 { store.tickets.append(QATicket(number: "arrived-during-sync")) }
        }
        let arrived = await store.publishUnsynced()
        check("new pending ticket during sync", !arrived && store.unsynced.count == 1)

        reset([])
        let empty = await store.publishUnsynced()
        check("empty delivery", empty && store.unsynced.isEmpty)
        func edit(_ id: UUID, preserveNewState: Bool = false) {
            guard let i = store.tickets.firstIndex(where: { $0.id == id }) else { return }
            store.tickets[i].updatedAt = store.tickets[i].updatedAt.addingTimeInterval(1)
            store.tickets[i].mirroredAt = nil
            store.tickets[i].syncedAt = nil
            store.tickets[i].shotSyncedAt = nil
            store.tickets[i].cpanelSyncedAt = nil
            store.tickets[i].syncError = "new revision error"
            if preserveNewState { store.tickets[i].syncedAt = Date(timeIntervalSince1970: 2000) }
        }

        reset([QATicket(number: "folder-edit")])
        Scenario.folderHook = { edit($0) }
        let folderEdit = await store.publishUnsynced()
        check("current ticket folder edit", !folderEdit && store.unsynced.count == 1 && store.tickets[0].mirroredAt == nil)

        reset([QATicket(number: "mirror-edit")])
        Scenario.folderHook = { edit($0) }
        _ = await sync.mirrorTicket(store.tickets[0].id)
        check("mirrorTicket revision guard", store.tickets[0].mirroredAt == nil)

        reset([QATicket(number: "shot-edit", screenshotFile: "fixture.jpg")])
        Scenario.shotHook = { edit($0) }
        let shotEdit = await store.publishUnsynced()
        check("current ticket screenshot edit", !shotEdit && store.unsynced.count == 1 && store.tickets[0].shotSyncedAt == nil && store.tickets[0].screenshotFile == "fixture.jpg")

        reset([QATicket(number: "cpanel-edit")]); QACPanelSettings.isConfigured = true
        Scenario.cpanelHook = { edit($0) }
        let cpEdit = await store.publishUnsynced()
        check("current ticket cPanel edit", !cpEdit && store.unsynced.count == 1 && store.tickets[0].cpanelSyncedAt == nil)

        reset([QATicket(number: "worker-edit")])
        Scenario.publishHook = { edit($0) }
        let workerEdit = await store.publish(store.tickets[0].id)
        check("Worker revised batch returns false", !workerEdit && store.tickets[0].syncedAt == nil && store.tickets[0].syncError == "new revision error")

        reset([QATicket(number: "worker-newer-success")])
        Scenario.publishHook = { edit($0, preserveNewState: true) }
        let newerSuccess = await store.publish(store.tickets[0].id)
        check("stale Worker success preserves newer state", !newerSuccess && store.tickets[0].syncedAt == Date(timeIntervalSince1970: 2000) && store.tickets[0].syncError == "new revision error")

        for throwing in [false, true] {
            reset([QATicket(number: "worker-stale-failure")])
            Scenario.workerOK = false; Scenario.transportThrows = throwing
            Scenario.publishHook = { edit($0, preserveNewState: true) }
            let staleFailure = await store.publish(store.tickets[0].id)
            check(throwing ? "stale Worker throw preserves newer state" : "stale Worker rejection preserves newer state",
                  !staleFailure && store.tickets[0].syncError == "new revision error" && store.tickets[0].syncedAt == Date(timeIntervalSince1970: 2000))
        }

        reset([QATicket(number: "delivered-shot", screenshotFile: "retained.jpg")])
        store.tickets[0].shotSyncedAt = Date(timeIntervalSince1970: 1500)
        Scenario.bytesAvailable = false
        let deliveredShot = await store.publishUnsynced()
        check("delivered screenshot cache reclaimed", deliveredShot && store.unsynced.isEmpty && !QASyncQueue.shared.records.contains { $0.hasPrefix("screenshot: failed") } && store.tickets[0].screenshotFile == "retained.jpg")

        let mergeRevision = Date(timeIntervalSince1970: 1000)
        let mergeStamp = Date(timeIntervalSince1970: 900)
        for (label, delta) in [("older", -1.0), ("equal", 0.0), ("newer", 1.0)] {
            var local = QATicket(number: "merge-" + label)
            local.screenshotFile = "retained.jpg"; local.mockupFile = "retained-mockup.jpg"
            local.context.identity = "synthetic identity"
            local.updatedAt = mergeRevision
            local.syncedAt = mergeStamp; local.mirroredAt = mergeStamp
            local.cpanelSyncedAt = mergeStamp; local.shotSyncedAt = mergeStamp
            let row: [String: Any] = ["number": local.number, "title": delta == 0 ? local.title : "remote text",
                "updatedAt": ISO8601DateFormatter().string(from: mergeRevision.addingTimeInterval(delta))]
            reset([local]); QACPanelSettings.isConfigured = true
            Scenario.bytesAvailable = false
            Scenario.remoteRows = [row]
            _ = await store.pullDeviceTickets()
            let merged = store.tickets[0]
            check("merge " + label + " retained local evidence", merged.id == local.id && merged.screenshotFile == local.screenshotFile && merged.mockupFile == local.mockupFile && merged.context.identity == local.context.identity && merged.shotSyncedAt == mergeStamp)
            if delta > 0 {
                check("merge newer invalidates text stamps", merged.mirroredAt == nil && merged.cpanelSyncedAt == nil && merged.title == "remote text" && merged.updatedAt == mergeRevision.addingTimeInterval(1))
            } else {
                check("merge " + label + " preserves text stamps", merged.mirroredAt == mergeStamp && merged.cpanelSyncedAt == mergeStamp && merged.title == local.title && merged.updatedAt == mergeRevision)
                if delta < 0 { check("merge older preserves Worker stamp", merged.syncedAt == mergeStamp) }
            }
            // Repeat through production publishUnsynced -> syncAllPending -> pull,
            // starting fully delivered, to prove the merge actually refreshes copies.
            reset([local]); QACPanelSettings.isConfigured = true
            Scenario.bytesAvailable = false; Scenario.remoteRows = [row]
            let refreshed = await store.publishUnsynced()
            check("merge " + label + " publish refresh fanout", refreshed && store.unsynced.isEmpty && Scenario.pullCount == 1 && Scenario.folderCalls == (delta > 0 ? 1 : 0) && Scenario.cpanelCalls == (delta > 0 ? 1 : 0) && Scenario.shotCalls == 0 && store.tickets[0].id == local.id && store.tickets[0].shotSyncedAt == mergeStamp && store.tickets[0].screenshotFile == local.screenshotFile && store.tickets[0].mockupFile == local.mockupFile && store.tickets[0].context.identity == local.context.identity)
        }

        print("FAILED_CASES=" + failed.joined(separator: ","))
        if !failed.isEmpty { exit(1) }
    }
}
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--candidate-baseline', type=Path)
    parser.add_argument('--merge-baseline', type=Path)
    args = parser.parse_args()
    destinations = source('Stocked/QASyncDestinations.swift', args.baseline)
    store = source('Stocked/QATicketStore.swift', args.baseline)
    snapshot = args.merge_baseline or args.candidate_baseline
    if snapshot:
        destinations = (snapshot / 'QASyncDestinations.swift').read_text()
        store = (snapshot / 'QATicketStore.swift').read_text()
    replacements = {
        '__PULL__': method(store, 'func pullDeviceTickets()'),
        '__REMOTE_DATE__': method(store, 'private nonisolated static func remoteDate('),
        '__STAMP_MIRRORED__': method(store, 'func stampMirrored('),
        '__STAMP_SHOT__': method(store, 'func stampShotSynced('),
        '__STAMP_CPANEL__': method(store, 'func stampCPanelSynced('),
        '__PUBLISH__': method(store, 'func publish(_'),
        '__PUSH__': method(store, 'private func push('),
        '__MIRROR_TICKET__': method(destinations, 'func mirrorTicket('),
        '__FULLY_SYNCED__': method(store, 'var isFullySynced: Bool'),
        '__PUBLISH_UNSYNCED__': method(store, 'func publishUnsynced()'),
        '__SYNC_EVERYWHERE__': method(destinations, 'func syncEverywhere('),
        '__SYNC_ALL__': method(destinations, 'func syncAllPending()'),
    }
    swift = STUBS
    for token, body in replacements.items():
        swift = swift.replace(token, body)
    with tempfile.TemporaryDirectory(prefix='stocked-qa-delivery-') as temporary:
        directory = Path(temporary)
        script = directory / 'DeliveryChecks.swift'
        script.write_text(swift)
        subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(directory / 'module-cache'), str(script), '-o', str(directory / 'checks')], check=True)
        result = subprocess.run([str(directory / 'checks')], capture_output=True, text=True, check=False)
        print(result.stdout, end='')
        print(result.stderr, end='')
        if args.baseline or args.candidate_baseline or args.merge_baseline:
            revision_failures = {"current ticket folder edit", "mirrorTicket revision guard", "current ticket screenshot edit", "current ticket cPanel edit", "Worker revised batch returns false", "stale Worker success preserves newer state", "stale Worker throw preserves newer state", "stale Worker rejection preserves newer state"}
            expected = {'partial count', 'partial publish', 'missing screenshot failure recorded', 'missing screenshot stays pending', 'screenshot upload failure', 'required cPanel failure', 'pull imports complete', 'empty local queue pulls pending import', 'final current-state count after edit', 'new pending ticket during sync'}
            if args.candidate_baseline:
                expected = revision_failures | {'delivered screenshot cache reclaimed'}
            else:
                expected |= revision_failures
            merge_failures = {'merge newer invalidates text stamps', 'merge newer publish refresh fanout'}
            expected = merge_failures if args.merge_baseline else expected | merge_failures
            if args.baseline:
                # HEAD's early return skips the production pull when all local
                # tickets are already complete, including older/equal rows.
                expected |= {'merge older publish refresh fanout', 'merge equal publish refresh fanout'}
            actual = {line[5:] for line in result.stdout.splitlines() if line.startswith('FAIL ')}
            if result.returncode != 1 or actual != expected:
                raise SystemExit('Unexpected baseline results: ' + repr(actual))
            print('Baseline regression set reproduced exactly.')
        elif result.returncode:
            raise SystemExit(result.returncode)


if __name__ == '__main__':
    main()
