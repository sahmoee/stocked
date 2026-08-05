// QATriage.swift
// ─────────────────────────────────────────────────────────────────────────────
// The answer to "so what?"
//
// Every other QA surface produces a list: events, invariants, processes,
// tickets, hitches, memory samples. Six lists is not a report — after a
// forty-minute session it is roughly a thousand rows, and the one that matters
// is somewhere in the middle of them. The tester ends up scrolling, and the
// thing they were supposed to notice is exactly the thing that scrolls past.
//
// Triage reads all six and produces a short, ordered list of *findings*: things
// worth a person's attention, worst first, each with a plain sentence saying what
// it is and what to do about it. When it is empty, that is the signal — the
// session is clean and nobody has to prove it by reading a thousand rows.
//
// The ranking is deliberately opinionated:
//   1. critical invariant violations — the app is producing wrong answers
//   2. blocker tickets — a human said this stops the release
//   3. freezes — watchdog-range main-thread blocks
//   4. crashes and hangs from MetricKit
//   5. everything else, in descending order of how much it costs someone
//
// Nothing here computes anything new. It is a reading of state the other
// surfaces already hold, which means it can never disagree with them and never
// costs more than a pass over a few arrays.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import Observation

// MARK: - Finding

nonisolated struct QAFinding: Identifiable, Sendable {
    enum Level: Int, Sendable, Comparable {
        case blocker = 0, warning = 1, info = 2
        static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        var title: String {
            switch self {
            case .blocker: return "Blocker"
            case .warning: return "Warning"
            case .info:    return "Note"
            }
        }
        var symbol: String {
            switch self {
            case .blocker: return "octagon.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .info:    return "info.circle"
            }
        }
        var tint: Color {
            switch self {
            case .blocker: return .red
            case .warning: return .orange
            case .info:    return .secondary
            }
        }
    }

    var id = UUID()
    var level: Level
    var rank: Int
    var title: String
    /// One sentence. What it means and what to do — not a restatement of the title.
    var detail: String
    var symbol: String
    /// Where the evidence lives, so the UI can point at the right section.
    var source: String

    var line: String { "[\(level.title.uppercased())] \(title) — \(detail)" }
}

// MARK: - Triage

@MainActor
@Observable
final class QATriage {
    static let shared = QATriage()
    private init() {}

    // MARK: Caching
    //
    // `findings` used to be computed fresh on every read, on the theory that a
    // cache would go stale instantly. In practice the opposite was true: the HUD
    // reads it every two seconds and the QA hub reads it six times in a single
    // render pass — verdict, tint, symbol, blockers, warnings, and the list —
    // and every one of those passes re-read and re-split the whole MetricKit
    // log. It is memoised against a cheap signature of everything it depends on,
    // so one render pass computes it once and an unchanged QA state costs a
    // string comparison.
    //
    // @ObservationIgnored is load-bearing. Writing an observed property from
    // inside a getter publishes a change on every read, which puts SwiftUI in a
    // render loop. These four are storage, not state. The signature function
    // reads the real observable sources, so views still invalidate at exactly
    // the right moments.
    @ObservationIgnored private var cachedFindings: [QAFinding] = []
    @ObservationIgnored private var cacheSignature = ""
    @ObservationIgnored private var cachedCrashLines: [String] = []
    @ObservationIgnored private var crashLinesReadAt = Date.distantPast

    /// MetricKit's log is a read plus a full split of a file that changes at most
    /// once per launch. Ten-second floor.
    private var crashLines: [String] {
        if Date().timeIntervalSince(crashLinesReadAt) > 10 {
            crashLinesReadAt = Date()
            cachedCrashLines = DiagnosticsMonitor.shared.currentLog()
                .split(separator: "\n").map(String.init)
                .filter { $0.contains("CRASH") || $0.contains("HANG") }
        }
        return cachedCrashLines
    }

    /// Cheap fingerprint of every input `computeFindings()` reads. Counts only —
    /// it must cost far less than the thing it is guarding.
    private func signature() -> String {
        let r = QARecorder.shared
        let t = QATicketStore.shared
        let m = QARuntimeMonitor.shared
        let p = QAProcessTracker.shared
        let inv = r.invariantResults
        return [
            r.isEnabled ? "1" : "0",
            "e\(r.events.count)",
            "s\(r.visitedScreens.count)",
            "d\(r.deadScreens.count)",
            "u\(r.unresolvedAttempts.count)",
            "iv\(inv.filter { $0.status == .violation }.count)",
            "ib\(inv.filter { $0.status == .blocked }.count)",
            "ic\(inv.count)",
            "ps\(r.previousSessionReport == nil ? 0 : 1)",
            "to\(t.openCount)",
            "tb\(t.blockers.count)",
            "tu\(t.unsynced.count)",
            "tc\(t.tickets.count)",
            "hs\(m.severeHitchCount)",
            "hw\(Int(m.worstHitchMs))",
            "hc\(m.hitches.count)",
            "mg\(Int(m.memoryGrowthMB))",
            "th\(m.thermalName)",
            "on\(m.online ? 1 : 0)",
            "nf\(m.networkFailureCount)",
            "pr\(p.records.count)",
            "pt\(p.stalled.count)",
            "pf\(p.failed.count)",
            "cl\(crashLines.count)",
        ].joined(separator: ",")
    }

    /// The ranked list of everything QA currently knows to be wrong.
    var findings: [QAFinding] {
        let sig = signature()
        if sig != cacheSignature {
            cacheSignature = sig
            cachedFindings = computeFindings()
        }
        return cachedFindings
    }

    private func computeFindings() -> [QAFinding] {
        let recorder = QARecorder.shared
        let tracker = QAProcessTracker.shared
        let runtime = QARuntimeMonitor.shared
        let tickets = QATicketStore.shared

        var out: [QAFinding] = []

        // 1 — critical invariant violations: the app is telling the user
        // something untrue, which outranks anything about speed.
        let criticalViolations = recorder.invariantResults.filter { $0.status == .violation && $0.critical }
        for v in criticalViolations {
            out.append(QAFinding(level: .blocker, rank: 0,
                                 title: v.name,
                                 detail: v.detail.isEmpty
                                     ? "A critical invariant is violated — two surfaces disagree about something safety-related."
                                     : v.detail,
                                 symbol: "shield.lefthalf.filled.slash",
                                 source: "Invariants"))
        }

        // 2 — blocker tickets.
        //
        // WAS: `t.body.prefix(120)` of a multi-paragraph body, so the triage row
        // showed the first paragraph sawn off mid-word and nothing else — the
        // field export is full of "...did not produce a frame for 78661 ms w".
        // `summary()` flattens the body to one line and cuts on a word boundary.
        for t in tickets.blockers {
            let gist = t.summaryLine
            out.append(QAFinding(level: .blocker, rank: 1,
                                 title: "\(t.number) \(t.title)",
                                 detail: "Filed on \(t.context.screen) · \(t.originPhrase)\(gist.isEmpty ? "" : " — " + gist)",
                                 symbol: "octagon.fill",
                                 source: "Tickets"))
        }

        // 3 — freezes. Watchdog range: the app was one unlucky second from
        // being killed, whether or not it actually was.
        if runtime.severeHitchCount > 0 {
            let worst = runtime.hitches.filter(\.isSevere).max(by: { $0.milliseconds < $1.milliseconds })
            out.append(QAFinding(
                level: .blocker, rank: 2,
                title: "\(runtime.severeHitchCount) freeze\(runtime.severeHitchCount == 1 ? "" : "s") over one second",
                detail: String(format: "Worst was %.1fs on %@. Blocks this long are what iOS terminates apps for — find the synchronous work on that screen.",
                               (worst?.milliseconds ?? 0) / 1000, worst?.screen ?? "—"),
                symbol: "bolt.trianglebadge.exclamationmark.fill",
                source: "Runtime"))
        }

        // 4 — MetricKit crashes and hangs, including from previous launches.
        let crashLines = self.crashLines
        if !crashLines.isEmpty {
            out.append(QAFinding(
                level: .blocker, rank: 3,
                title: "\(crashLines.count) crash/hang report\(crashLines.count == 1 ? "" : "s") on this device",
                detail: "Reported by MetricKit, possibly from an earlier launch: \(crashLines.suffix(1).joined())",
                symbol: "exclamationmark.octagon.fill",
                source: "Crash log"))
        }

        // 5 — a session that ended without the app coming back cleanly.
        if recorder.previousSessionReport != nil {
            out.append(QAFinding(
                level: .warning, rank: 4,
                title: "A previous QA session did not end cleanly",
                detail: "A snapshot from before the last restart is saved. Open it to see what the app was doing when it stopped.",
                symbol: "clock.arrow.circlepath",
                source: "Session"))
        }

        // 6 — non-critical invariant violations.
        let softViolations = recorder.invariantResults.filter { $0.status == .violation && !$0.critical }
        if !softViolations.isEmpty {
            out.append(QAFinding(
                level: .warning, rank: 5,
                title: "\(softViolations.count) invariant\(softViolations.count == 1 ? "" : "s") violated",
                detail: softViolations.prefix(2).map(\.name).joined(separator: ", ")
                    + (softViolations.count > 2 ? ", and \(softViolations.count - 2) more" : "")
                    + " — two surfaces disagree, but not about anything safety-critical.",
                symbol: "arrow.triangle.branch",
                source: "Invariants"))
        }

        // 7 — hung operations. A spinner that never stopped is a bug the user
        // definitely saw and probably could not describe.
        let hung = recorder.danglingAttempts.filter(\.isHung)
        if !hung.isEmpty {
            out.append(QAFinding(
                level: .warning, rank: 6,
                title: "\(hung.count) operation\(hung.count == 1 ? "" : "s") never finished",
                detail: "Oldest: \(hung.first?.label ?? "—") on \(hung.first?.screen ?? "—"), still open after \(hung.first?.ageText ?? "—"). Something started and never reported success or failure.",
                symbol: "hourglass.badge.plus",
                source: "Session"))
        }

        // 8 — stalled processes from the flow tracker.
        let stalled = tracker.stalled
        if !stalled.isEmpty {
            out.append(QAFinding(
                level: .warning, rank: 7,
                title: "\(stalled.count) process\(stalled.count == 1 ? "" : "es") running long",
                detail: "Longest: \(stalled.first?.name ?? "—") at \(stalled.first?.durationText ?? "—"). Still running past the stall threshold.",
                symbol: "gauge.with.needle",
                source: "Processes"))
        }

        // 9 — failed processes.
        if !tracker.failed.isEmpty {
            out.append(QAFinding(
                level: .warning, rank: 8,
                title: "\(tracker.failed.count) process\(tracker.failed.count == 1 ? "" : "es") failed",
                detail: tracker.failed.prefix(2).map(\.name).joined(separator: ", ") + " reported failure during this session.",
                symbol: "xmark.diamond.fill",
                source: "Processes"))
        }

        // 10 — memory growth. Not a leak proof, but the shape of one.
        if runtime.isRunning && runtime.memoryGrowthMB > 250 {
            out.append(QAFinding(
                level: .warning, rank: 9,
                title: String(format: "Memory grew %.0f MB this session", runtime.memoryGrowthMB),
                detail: String(format: "Started at %.0f MB, now %.0f MB, peaked at %.0f MB. Worth checking whether it comes back down after leaving the heavy screens.",
                               runtime.startFootprintMB, runtime.currentFootprintMB, runtime.peakFootprintMB),
                symbol: "memorychip",
                source: "Runtime"))
        }

        // 11 — screens that received no interaction at all.
        let dead = recorder.deadScreens
        if !dead.isEmpty {
            out.append(QAFinding(
                level: .info, rank: 10,
                title: "\(dead.count) screen\(dead.count == 1 ? "" : "s") visited but never tapped",
                detail: dead.prefix(4).joined(separator: ", ")
                    + (dead.count > 4 ? ", and \(dead.count - 4) more" : "")
                    + " — either untested, or nothing on them responds.",
                symbol: "hand.tap",
                source: "Session"))
        }

        // 12 — ticket hotspots: repetition is the finding, not the reports.
        for h in tickets.hotspots.prefix(3) {
            out.append(QAFinding(
                level: .warning, rank: 11,
                title: "\(h.count) open tickets on \(h.screen)",
                detail: "One report is an incident; this many on one screen is a pattern worth looking at as a whole.",
                symbol: "scope",
                source: "Tickets"))
        }

        // 13 — non-severe hitches concentrated on one screen.
        if let worstScreen = runtime.hitchesByScreen.first, worstScreen.count >= 5 {
            out.append(QAFinding(
                level: .warning, rank: 12,
                title: "\(worstScreen.count) frame hitches on \(worstScreen.screen)",
                detail: "That screen stutters repeatedly, which usually means work on the main thread inside a view body or a scroll callback.",
                symbol: "waveform.path.ecg",
                source: "Runtime"))
        }

        // 14 — network failures.
        if runtime.networkFailureCount > 0 {
            out.append(QAFinding(
                level: .warning, rank: 13,
                title: "\(runtime.networkFailureCount) network call\(runtime.networkFailureCount == 1 ? "" : "s") failed",
                detail: runtime.networkStats.filter { $0.failures > 0 }.prefix(2).map(\.name).joined(separator: ", ")
                    + (runtime.online ? "" : " — the device is offline right now, which may explain it."),
                symbol: "antenna.radiowaves.left.and.right.slash",
                source: "Runtime"))
        }

        // 15 — environment caveats. Not bugs, but they invalidate timings, and a
        // performance finding measured on a throttled phone is worse than none.
        if runtime.isThrottled {
            out.append(QAFinding(
                level: .info, rank: 14,
                title: "Device is \(runtime.thermalName)\(runtime.lowPower ? " and in low power mode" : "")",
                detail: "The OS is throttling. Treat any timing measured now as a floor, not a fair reading.",
                symbol: "thermometer.high",
                source: "Runtime"))
        }
        if !runtime.online {
            out.append(QAFinding(
                level: .info, rank: 15,
                title: "Device is offline",
                detail: "Sync, publishing, and every remote recipe source will fail by design until it reconnects.",
                symbol: "wifi.slash",
                source: "Runtime"))
        }

        // 15b — frame-clock jumps. Build 71 counted these as freezes and filed
        // blockers for a 22.6s and a 78.7s "block" that were really the tester
        // locking the phone. They are discarded now, but discarding them
        // silently would just move the lie somewhere quieter: if this number is
        // large the session was mostly spent in the background, and the runtime
        // figures above cover less real use than their duration suggests.
        if runtime.discardedGaps > 0 {
            out.append(QAFinding(
                level: .info, rank: 15,
                title: "\(runtime.discardedGaps) frame gap\(runtime.discardedGaps == 1 ? "" : "s") discarded",
                detail: "The app was suspended or the screen was locked, so the time is not a main-thread block and was not counted as one. A high count means this session covered less foreground use than its length implies.",
                symbol: "moon.zzz.fill",
                source: "Runtime"))
        }

        // 16 — unsynced tickets.
        //
        // A ticket the bridge REFUSED is not a ticket "waiting to push", and
        // saying so cost a whole field session: the export read "they will push
        // on the next publish" underneath four tickets the worker had already
        // rejected four times. A rejection is a warning, not a note, because
        // nothing about waiting will fix it.
        if !tickets.unsynced.isEmpty {
            let rejected = tickets.unsynced.filter { !$0.syncError.isEmpty }
            if rejected.isEmpty {
                out.append(QAFinding(
                    level: .info, rank: 16,
                    title: "\(tickets.unsynced.count) ticket\(tickets.unsynced.count == 1 ? "" : "s") not yet synced",
                    detail: "They are saved on device and will push on the next publish.",
                    symbol: "arrow.up.circle",
                    source: "Tickets"))
            } else {
                let reason = rejected.first?.syncError ?? "the bridge refused it"
                out.append(QAFinding(
                    level: .warning, rank: 16,
                    title: "\(rejected.count) ticket\(rejected.count == 1 ? "" : "s") the bridge refused",
                    detail: "\(reason). Publishing again will not help — the ticket is saved on device, but nothing upstream has it.",
                    symbol: "xmark.icloud.fill",
                    source: "Tickets"))
            }
        }

        // 17 — invariants that could not run.
        let blocked = recorder.invariantResults.filter { $0.status == .blocked }
        if blocked.count >= 3 {
            out.append(QAFinding(
                level: .info, rank: 17,
                title: "\(blocked.count) invariants could not run",
                detail: "Blocked means not enough data to judge, not failure — add inventory or recipes and they will start reporting.",
                symbol: "questionmark.circle",
                source: "Invariants"))
        }

        return out.sorted {
            if $0.level != $1.level { return $0.level < $1.level }
            return $0.rank < $1.rank
        }
    }

    // MARK: Derived

    var blockers: [QAFinding] { findings.filter { $0.level == .blocker } }
    var warnings: [QAFinding] { findings.filter { $0.level == .warning } }

    var isClean: Bool { findings.allSatisfy { $0.level == .info } }

    /// The single line the QA hub shows at the top. It should be readable in a
    /// glance from across a desk.
    var verdict: String {
        let b = blockers.count, w = warnings.count
        if b > 0 { return "\(b) blocker\(b == 1 ? "" : "s")\(w > 0 ? ", \(w) warning\(w == 1 ? "" : "s")" : "")" }
        if w > 0 { return "\(w) warning\(w == 1 ? "" : "s")" }
        if !QARecorder.shared.isEnabled { return "QA mode is off" }
        return "Nothing flagged"
    }

    var verdictTint: Color {
        if !blockers.isEmpty { return .red }
        if !warnings.isEmpty { return .orange }
        return .green
    }

    var verdictSymbol: String {
        if !blockers.isEmpty { return "octagon.fill" }
        if !warnings.isEmpty { return "exclamationmark.triangle.fill" }
        return "checkmark.seal.fill"
    }

    var exportText: String {
        let f = findings
        guard !f.isEmpty else { return "TRIAGE\n  nothing flagged" }
        var out = ["TRIAGE — \(verdict)"]
        for finding in f {
            out.append("  \(finding.line)")
        }
        return out.joined(separator: "\n")
    }
}
