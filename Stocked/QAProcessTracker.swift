// QAProcessTracker.swift
// ─────────────────────────────────────────────────────────────────────────────
// The process / flow manager for QA mode.
//
// WHAT IT ANSWERS
// "What is the app actually doing right now, what did it just do, how long did
// each thing take, and which of them never finished?" That last one is the whole
// point: a flow that begins and never ends is a spinner that never stops, and it
// is invisible in a plain event log because nothing is ever printed for it.
//
// HOW IT GETS ITS DATA
// Not by instrumenting 350 files. Three funnels cover almost everything:
//   • every network call goes through StockedWorkerClient.requestData
//   • every classification pass goes through CookNowCompute.run
//   • every screen appearance goes through .qaScreen(...)
// Anything else opts in with one line:
//
//      let p = QAProcessTracker.shared.begin("Import receipt")
//      defer { p.finish() }                       // or p.fail("no text found")
//
// It also feeds QARecorder: every begin is an `attempt`, every finish a
// `success`, every fail a `failure`. Before this existed those three counters
// read 0 in every session, because `QARecorder.attempt(...)` had almost no call
// sites — the counters were correct and the instrumentation was missing.
//
// Cost when QA mode is off: one Bool check and an empty struct. Nothing is
// allocated, nothing is retained.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import Observation

// MARK: - Record

nonisolated struct QAProcessRecord: Identifiable, Sendable {
    enum State: String, Sendable {
        case running, finished, failed, abandoned
    }

    let id = UUID()
    let name: String
    let detail: String
    let startedAt: Date
    var endedAt: Date?
    var state: State = .running
    var outcome: String = ""

    /// Seconds elapsed, live for a running process.
    var duration: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    var durationText: String {
        let ms = duration * 1000
        return ms < 1000 ? String(format: "%.0f ms", ms) : String(format: "%.2f s", duration)
    }

    var line: String {
        let t = QAProcessRecord.formatter.string(from: startedAt)
        var s = "\(t) [\(state.rawValue)] \(name) — \(durationText)"
        if !detail.isEmpty { s += " · \(detail)" }
        if !outcome.isEmpty { s += " · \(outcome)" }
        return s
    }

    fileprivate static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
}

// MARK: - Handle

/// Returned by `begin`. Finishing is idempotent — a `defer { p.finish() }` next
/// to an explicit `p.fail(...)` on the error path does the right thing rather
/// than logging the same process twice.
@MainActor
final class QAProcessHandle {
    private let id: UUID?
    private var resolved = false

    fileprivate init(id: UUID?) { self.id = id }

    /// A no-op handle, handed back when QA mode is off.
    static let inert = QAProcessHandle(id: nil)

    func finish(detail: String = "") {
        guard let id, !resolved else { return }
        resolved = true
        QAProcessTracker.shared.resolve(id, state: .finished, outcome: detail)
    }

    func fail(_ reason: String) {
        guard let id, !resolved else { return }
        resolved = true
        QAProcessTracker.shared.resolve(id, state: .failed, outcome: reason)
    }

    /// Note progress without ending the process (e.g. "page 3 of 9").
    func note(_ text: String) {
        guard let id, !resolved else { return }
        QAProcessTracker.shared.annotate(id, outcome: text)
    }
}

// MARK: - Tracker

@MainActor
@Observable
final class QAProcessTracker {
    static let shared = QAProcessTracker()
    private init() {}

    /// Newest first. Bounded, for the same reason QARecorder's log is: a QA
    /// session runs for hours and an unbounded list is a memory leak wearing a
    /// friendly name.
    private(set) var records: [QAProcessRecord] = []
    private let cap = 400

    /// A process still running after this long is almost certainly stuck, and is
    /// reported as such without waiting for it to resolve. Two seconds is well
    /// past anything that should be happening on the main actor and comfortably
    /// short of the iOS watchdog's own patience.
    private let stallThreshold: TimeInterval = 2.0

    private var isOn: Bool { QARecorder.shared.isEnabled }

    // MARK: Lifecycle

    @discardableResult
    func begin(_ name: String, detail: String = "") -> QAProcessHandle {
        guard isOn else { return .inert }
        let record = QAProcessRecord(name: name, detail: detail, startedAt: Date())
        records.insert(record, at: 0)
        if records.count > cap { records.removeLast(records.count - cap) }
        QARecorder.shared.record(.attempt, label: name, detail: detail)
        return QAProcessHandle(id: record.id)
    }

    fileprivate func resolve(_ id: UUID, state: QAProcessRecord.State, outcome: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].endedAt = Date()
        records[i].state = state
        if !outcome.isEmpty { records[i].outcome = outcome }
        let r = records[i]
        switch state {
        case .failed:
            QARecorder.shared.record(.failure, label: r.name,
                                     detail: outcome.isEmpty ? "failed" : outcome)
        default:
            var d = r.durationText
            if !outcome.isEmpty { d += " · " + outcome }
            QARecorder.shared.record(.success, label: r.name, detail: d)
            if r.duration >= stallThreshold {
                QARecorder.shared.record(.violation, screen: "Performance",
                                         label: "Slow process: \(r.name)",
                                         detail: "took \(r.durationText) — blocking risk")
            }
        }
    }

    fileprivate func annotate(_ id: UUID, outcome: String) {
        guard let i = records.firstIndex(where: { $0.id == id }) else { return }
        records[i].outcome = outcome
    }

    /// One-shot convenience for work that cannot fail or that you do not want to
    /// wrap in a handle.
    func mark(_ name: String, detail: String = "") {
        guard isOn else { return }
        var r = QAProcessRecord(name: name, detail: detail, startedAt: Date())
        r.endedAt = r.startedAt
        r.state = .finished
        records.insert(r, at: 0)
        if records.count > cap { records.removeLast(records.count - cap) }
    }

    /// Wrap a synchronous block. Returns whatever the block returns; a throw is
    /// recorded as a failure and rethrown.
    @discardableResult
    func track<T>(_ name: String, detail: String = "", _ body: () throws -> T) rethrows -> T {
        let p = begin(name, detail: detail)
        do {
            let value = try body()
            p.finish()
            return value
        } catch {
            p.fail(error.localizedDescription)
            throw error
        }
    }

    func clear() { records = [] }

    // MARK: Derived

    var running: [QAProcessRecord] { records.filter { $0.state == .running } }

    /// Running longer than the stall threshold — the spinners that never stop.
    var stalled: [QAProcessRecord] {
        running.filter { $0.duration >= stallThreshold }
    }

    var failed: [QAProcessRecord] { records.filter { $0.state == .failed } }

    /// Completed processes ranked slowest first — the bottleneck list.
    var slowest: [QAProcessRecord] {
        records.filter { $0.state != .running }
            .sorted { $0.duration > $1.duration }
            .prefix(15).map { $0 }
    }

    /// Per-name totals: count, total time, worst single run. This is the table
    /// that actually finds a bottleneck — one 300 ms call is fine, four hundred
    /// of them is the freeze.
    struct Rollup: Identifiable {
        var id: String { name }
        let name: String
        let count: Int
        let total: TimeInterval
        let worst: TimeInterval
        var averageMs: Double { count == 0 ? 0 : total / Double(count) * 1000 }
    }

    var rollups: [Rollup] {
        var byName: [String: (n: Int, total: TimeInterval, worst: TimeInterval)] = [:]
        for r in records where r.state != .running {
            var e = byName[r.name] ?? (0, 0, 0)
            e.n += 1
            e.total += r.duration
            e.worst = max(e.worst, r.duration)
            byName[r.name] = e
        }
        return byName.map { Rollup(name: $0.key, count: $0.value.n,
                                   total: $0.value.total, worst: $0.value.worst) }
            .sorted { $0.total > $1.total }
    }

    // MARK: Export

    var exportText: String {
        var out = ["PROCESS / FLOW TRACKER",
                   "\(records.count) tracked · \(running.count) running · \(failed.count) failed",
                   ""]

        if !stalled.isEmpty {
            out.append("STALLED (still running past \(Int(stallThreshold))s — likely hung)")
            for r in stalled { out.append("  \(r.name) — \(r.durationText)") }
            out.append("")
        }

        let roll = rollups
        if !roll.isEmpty {
            out.append("TIME BY PROCESS (slowest total first)")
            for r in roll.prefix(20) {
                out.append(String(format: "  %@ — %d× · total %.2fs · avg %.0fms · worst %.0fms",
                                  r.name, r.count, r.total, r.averageMs, r.worst * 1000))
            }
            out.append("")
        }

        if !failed.isEmpty {
            out.append("FAILED PROCESSES")
            for r in failed { out.append("  \(r.line)") }
            out.append("")
        }

        out.append("PROCESS LOG (newest first)")
        for r in records { out.append("  " + r.line) }
        return out.joined(separator: "\n")
    }
}
