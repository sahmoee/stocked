// QAMode.swift
// ─────────────────────────────────────────────────────────────────────────────
// QA mode: an opt-in runtime recorder plus an in-process invariant checker.
//
// WHAT THIS IS FOR
// The QA companion app tests Stocked from the outside and cannot see the
// engines. StockedTests sees the engines but not real user data. QA mode is the
// third position: real engines, real data, live device.
//
// It records what screens you visited and what actions you attempted, and it
// runs assertions that two surfaces agree with each other. Those assertions are
// the automatable part of the checkbook — every "these two numbers must match"
// item in it becomes a probe here that runs without a human reading two screens
// and comparing.
//
// WHAT IT IS NOT
// It does not intercept every tap in the app. Doing that means touching every
// button in 350 files, and a per-tap log is mostly noise anyway. Instead:
//   • screens report themselves via .qaScreen("name") at their root
//   • flows report themselves through QAProcessTracker, which sits on the two
//     funnels every action already passes through (network + classification)
//   • FAILURES are captured automatically, without instrumentation, by the
//     invariant probes and the runtime monitor
//
// OFF BY DEFAULT, and off in the App Store build unless explicitly enabled —
// see `isAvailable`. Recording costs nothing when disabled: every entry point
// early-returns on the flag before allocating anything.
//
// BUILD 71 ADDITIONS
//   • breadcrumbs — the last 40 things that happened, in order, so a ticket can
//     answer "what were you doing right before it broke" without the tester
//     having to remember
//   • attempt ages — an attempt that has been open for 10s is promoted to a
//     violation on its own, because that is a hung operation whether or not it
//     eventually resolves
//   • dead screens — visited but never tapped. A screen you opened and could not
//     interact with is a finding that no counter caught before
//   • crash-proof session snapshot — the session is written to disk on every
//     failure and on backgrounding, so a watchdog kill no longer erases the
//     evidence that explains it
//   • invariant run deltas — what got worse and what got fixed since last run
//   • auto-off timer — recording stops itself, so a TestFlight tester cannot
//     leave QA mode running for a week
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import Observation

// MARK: - Event model

nonisolated enum QAEventKind: String, Codable, Sendable, CaseIterable {
    case screen         // a screen appeared
    case attempt        // the user tried to do something
    case success        // that thing worked
    case failure        // that thing failed
    case violation      // an invariant probe found two surfaces disagreeing
    case note           // manual marker the tester dropped

    var title: String {
        switch self {
        case .screen: return "Screens"
        case .attempt: return "Attempts"
        case .success: return "Successes"
        case .failure: return "Failures"
        case .violation: return "Violations"
        case .note: return "Notes"
        }
    }

    var symbol: String {
        switch self {
        case .screen: return "rectangle.on.rectangle"
        case .attempt: return "hand.tap"
        case .success: return "checkmark"
        case .failure: return "exclamationmark.triangle.fill"
        case .violation: return "xmark.octagon.fill"
        case .note: return "text.bubble"
        }
    }
}

nonisolated struct QAEvent: Identifiable, Codable, Sendable {
    var id = UUID()
    var at: Date = Date()
    var kind: QAEventKind
    var screen: String
    var label: String
    var detail: String = ""

    var line: String {
        let t = QAEvent.formatter.string(from: at)
        let d = detail.isEmpty ? "" : " — \(detail)"
        return "\(t) [\(kind.rawValue)] \(screen): \(label)\(d)"
    }

    /// Everything a text search should look at, lowercased once.
    var searchHaystack: String {
        (label + " " + screen + " " + detail).lowercased()
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// One screen and a count of something that happened on it.
///
/// This exists because `[(screen: String, count: Int)]` cannot be fed to a
/// SwiftUI `ForEach`: key paths cannot address tuple elements, so `id: \.screen`
/// does not compile, and a tuple is not `Hashable`, so `id: \.self` does not
/// either. A two-field struct costs nothing and makes both call sites ordinary.
nonisolated struct QAScreenCount: Identifiable, Sendable {
    var id: String { screen }
    let screen: String
    let count: Int
}

// MARK: - Recorder

@MainActor
@Observable
final class QARecorder {
    static let shared = QARecorder()

    /// Master switch. Persisted, off by default.
    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "qa.mode.enabled")
            if isEnabled {
                sessionStartedAt = Date()
                armAutoOff()
                record(.note, screen: "QA", label: "QA mode enabled")
                QARuntimeMonitor.shared.start()
                // Auto-publish a baseline 30 s after enabling when autoPublish is on.
                // The delay lets the invariant runner complete its first pass (which
                // starts immediately in QABackgroundRunner.start) so the baseline
                // report includes real data rather than empty counters.
                if QABackgroundRunner.shared.autoPublish {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(30))
                        guard QARecorder.shared.isEnabled else { return }
                        await QABackgroundRunner.shared.publish()
                    }
                }
            } else {
                // Stop everything and keep whatever was captured — including a
                // snapshot on disk, so turning QA off is not the same as losing
                // the session.
                QABackgroundRunner.shared.stop()
                QARuntimeMonitor.shared.stop()
                autoOffTask?.cancel()
                autoOffTask = nil
                persistSnapshot(reason: "QA mode disabled")
                // Archive the final session log so every disable produces a local record,
                // whether the tester published to the worker or not.
                let snap = fullExportText
                Task { await QASyncCoordinator.shared.mirrorLog(snap, name: "qa-session-archive.txt") }
            }
        }
    }

    /// QA mode is meant for dev and TestFlight. In a release App Store build it
    /// stays unavailable unless someone deliberately flips the override, so a
    /// shipped binary cannot sit there recording because a toggle was left on.
    static var isAvailable: Bool {
        #if DEBUG
        return true
        #else
        return UserDefaults.standard.bool(forKey: "qa.mode.allowInRelease")
        #endif
    }

    /// Ring buffer. Bounded hard, because a QA session can run for hours and an
    /// unbounded log is a memory leak with a friendly name.
    private(set) var events: [QAEvent] = []
    private let cap = 600

    /// Current screen, so `attempt` calls do not each have to name it.
    private(set) var currentScreen: String = "—"

    /// Every screen this session has entered, whether or not it was ever tapped.
    /// Paired with `tapCounts` this is what makes a dead screen visible.
    private(set) var visitedScreens: [String] = []

    /// Latest invariant results, newest run only, plus the run before it so the
    /// UI can say what changed rather than silently replacing the list.
    private(set) var invariantResults: [QAInvariantResult] = []
    private(set) var previousInvariantResults: [QAInvariantResult] = []
    private(set) var lastInvariantRun: Date?

    private(set) var sessionStartedAt = Date()

    private init() {
        // `didSet` DOES NOT FIRE DURING init. Every stored property below has an
        // observer whose side effects matter, so each one is replayed by hand at
        // the end of this initialiser. Forgetting this is how QA mode came back
        // from a relaunch "on" but with nothing actually running behind it.
        autoOffMinutes = UserDefaults.standard.integer(forKey: "qa.autoOffMinutes")
        isEnabled = UserDefaults.standard.bool(forKey: "qa.mode.enabled") && Self.isAvailable
        previousSessionReport = UserDefaults.standard.string(forKey: Self.snapshotKey)

        // Re-persist: if the stored value was `true` but `isAvailable` is false
        // (a release build without the override), the flag on disk is stale and
        // would keep claiming QA was on.
        UserDefaults.standard.set(isEnabled, forKey: "qa.mode.enabled")

        if isEnabled {
            sessionStartedAt = Date()
            armAutoOff()
            // The runtime monitor is what makes hitch detection, memory sampling
            // and automatic freeze tickets exist. Launching straight into an
            // already-enabled QA session has to start it, exactly as the toggle
            // would have.
            //
            // ┌─────────────────────────────────────────────────────────────┐
            // │ NOTHING REACHED FROM THIS INITIALISER MAY TOUCH             │
            // │ `QARecorder.shared` SYNCHRONOUSLY. Not here, not four calls │
            // │ deep. This `Task` is load-bearing — do not inline it back.  │
            // └─────────────────────────────────────────────────────────────┘
            //
            // `static let shared` is a `swift_once`. While this initialiser is
            // running the once-token is claimed and unfinished, so a *second*
            // read of `QARecorder.shared` on the same thread does not re-enter
            // and does not return the half-built instance — it parks in
            // `_dispatch_once_wait` waiting for a token only this thread can
            // release, and traps. Build 75 crashed at launch exactly that way:
            //
            //     QARecorder.shared (once begins)
            //       → QARecorder.init()
            //         → QARuntimeMonitor.start()
            //           → QAMemoryWatch.start()
            //             → QAMemoryWatch.take()
            //               → QARecorder.shared   ← EXC_BREAKPOINT
            //
            // `take()` only wanted `currentScreen` to label a memory sample.
            // Two other paths out of `start()` had the same reach and would
            // have fired later on a hot or nearly-full device:
            // `sampleEnvironment()` records a violation for a serious thermal
            // state, and another for under 250 MB free.
            //
            // Hopping to the next main-actor turn costs nothing measurable —
            // both singletons are `@MainActor`, so no isolation is crossed and
            // no ordering guarantee is lost. By the time the task body runs,
            // `shared` is fully assigned and every one of those reads is an
            // ordinary property access. Fixing it at the three call sites
            // instead would leave the trap armed for the fourth.
            //
            // The `isEnabled` re-check is not paranoia: the toggle can be flipped
            // off in the window before this runs, and its `didSet` calls
            // `QARuntimeMonitor.stop()`. Starting afterwards would leave the
            // monitor running under a switch that reads off.
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                QARuntimeMonitor.shared.start()
            }
        }
    }

    // MARK: Recording

    func record(_ kind: QAEventKind, screen: String? = nil, label: String, detail: String = "") {
        guard isEnabled else { return }
        let e = QAEvent(kind: kind, screen: screen ?? currentScreen, label: label, detail: detail)
        events.append(e)
        if events.count > cap { events.removeFirst(events.count - cap) }

        switch kind {
        case .failure, .violation:
            dropCrumb("\(kind == .failure ? "✗" : "!") \(e.screen): \(label)")
            // A failure is exactly the moment the session becomes worth keeping,
            // and exactly the moment the app is most likely to be killed next.
            persistSnapshot(reason: "after \(kind.rawValue)")
        case .note:
            dropCrumb("• \(label)")
        default:
            break
        }
    }

    func enteredScreen(_ name: String) {
        guard isEnabled else { return }
        guard name != currentScreen else { return }   // ignore re-appears
        currentScreen = name
        if !visitedScreens.contains(name) { visitedScreens.append(name) }
        dropCrumb("→ \(name)")
        record(.screen, screen: name, label: "appeared")
    }

    /// Log an attempt. Call `succeeded` or `failed` on the returned token so an
    /// attempt that never resolves is visible as a dangling attempt — which is
    /// itself a finding (a spinner that never ends).
    @discardableResult
    func attempt(_ label: String, detail: String = "") -> QAAttempt {
        record(.attempt, label: label, detail: detail)
        let key = "\(currentScreen)|\(label)"
        if openedAt[key] == nil { openedAt[key] = Date() }
        return QAAttempt(label: label, screen: currentScreen)
    }

    func succeeded(_ a: QAAttempt, detail: String = "") {
        openedAt["\(a.screen)|\(a.label)"] = nil
        record(.success, screen: a.screen, label: a.label, detail: detail)
    }

    func failed(_ a: QAAttempt, detail: String) {
        openedAt["\(a.screen)|\(a.label)"] = nil
        record(.failure, screen: a.screen, label: a.label, detail: detail)
    }

    /// Convenience for the many call sites that already have a thrown error.
    func failed(_ a: QAAttempt, error: Error) {
        failed(a, detail: error.localizedDescription)
    }

    func setInvariantResults(_ results: [QAInvariantResult]) {
        previousInvariantResults = invariantResults
        invariantResults = results
        lastInvariantRun = Date()
        // Only true violations enter the event feed. BLOCKED means "not enough data
        // to judge" — logging those as violations flooded the counters (a session
        // showed 7 "violations" that were all blocked probes) and buried real bugs.
        for r in results where r.status == .violation {
            record(.violation, screen: "Invariants", label: r.name, detail: r.detail)
        }
    }

    /// Probes that started violating since the previous run. This is the list
    /// worth looking at — a violation that has been there for an hour is noise
    /// by now, a violation that appeared after the last thing you did is a lead.
    var newViolations: [QAInvariantResult] {
        let before = Set(previousInvariantResults.filter { $0.status == .violation }.map(\.name))
        return invariantResults.filter { $0.status == .violation && !before.contains($0.name) }
    }

    /// Probes that were violating and now are not.
    var fixedSinceLastRun: [String] {
        let before = Set(previousInvariantResults.filter { $0.status == .violation }.map(\.name))
        let now = Set(invariantResults.filter { $0.status == .violation }.map(\.name))
        return before.subtracting(now).sorted()
    }

    // MARK: Breadcrumbs
    // The last 40 things that happened, in order. Every ticket carries a copy, so
    // "what were you doing right before it broke" is answered by the app instead
    // of by the tester's memory. Deliberately terser than the event log: this is
    // meant to be read at a glance, in a bug report, by someone who was not there.

    private(set) var breadcrumbs: [String] = []
    private let crumbCap = 40
    private var lastCrumb = ""
    private var crumbRepeat = 0

    private func dropCrumb(_ text: String) {
        // Coalesce runs of the same crumb ("×7 tapped Grocery") instead of
        // spending 40 slots on the same line.
        if text == lastCrumb {
            crumbRepeat += 1
            if !breadcrumbs.isEmpty {
                breadcrumbs[breadcrumbs.count - 1] = "\(text) ×\(crumbRepeat + 1)"
            }
            return
        }
        lastCrumb = text
        crumbRepeat = 0
        breadcrumbs.append(text)
        if breadcrumbs.count > crumbCap { breadcrumbs.removeFirst(breadcrumbs.count - crumbCap) }
    }

    /// Public entry so the tap tracker and process tracker can contribute.
    func crumb(_ text: String) {
        guard isEnabled else { return }
        dropCrumb(text)
    }

    var breadcrumbTrail: String { breadcrumbs.joined(separator: "\n") }

    // MARK: Tap tracking (aggregate)
    // Every tap anywhere in the app bumps a per-screen counter while QA mode is on.
    // Aggregate counts, not per-tap events: a 20-minute session is thousands of taps
    // and per-tap rows would flush the ring buffer instantly. The counts prove which
    // screens actually received interaction (pairs with the screens-visited list).
    private(set) var tapCounts: [String: Int] = [:]
    var tapTotal: Int { tapCounts.values.reduce(0, +) }

    func tapped() {
        guard isEnabled else { return }
        tapCounts[currentScreen, default: 0] += 1
        dropCrumb("tap \(currentScreen)")
    }

    /// Screens that appeared but never received a single tap. Either the tester
    /// never tried, or the screen does not accept touches — and the second one is
    /// a bug that nothing else in QA would have surfaced.
    var deadScreens: [String] {
        visitedScreens.filter { (tapCounts[$0] ?? 0) == 0 && $0 != "—" }
    }

    // MARK: Unresolved attempts

    /// When each still-open attempt started, so the UI can show an age instead of
    /// just a name. An attempt open for 400ms is in flight; one open for 40s is
    /// a hang, and they should not look the same in a report.
    private var openedAt: [String: Date] = [:]

    /// Attempts with no matching success or failure — dangling operations.
    var unresolvedAttempts: [String] {
        var pending: [String: Int] = [:]
        for e in events {
            let key = "\(e.screen)|\(e.label)"
            switch e.kind {
            case .attempt: pending[key, default: 0] += 1
            case .success, .failure: pending[key, default: 0] -= 1
            default: break
            }
        }
        return pending.filter { $0.value > 0 }.keys.sorted()
    }

    nonisolated struct DanglingAttempt: Identifiable, Sendable {
        var id: String { key }
        let key: String
        let age: TimeInterval
        var screen: String { key.split(separator: "|").first.map(String.init) ?? "—" }
        var label: String { key.split(separator: "|").dropFirst().joined(separator: "|") }
        var ageText: String {
            age < 1 ? String(format: "%.0f ms", age * 1000)
                    : (age < 60 ? String(format: "%.1f s", age) : String(format: "%.0f min", age / 60))
        }
        /// Past this, it is not "in flight", it is stuck.
        var isHung: Bool { age >= 10 }
    }

    /// Dangling attempts with ages, worst first.
    var danglingAttempts: [DanglingAttempt] {
        let now = Date()
        return unresolvedAttempts.map {
            DanglingAttempt(key: $0, age: now.timeIntervalSince(openedAt[$0] ?? now))
        }
        .sorted { $0.age > $1.age }
    }

    // MARK: Session control

    func clear() {
        events = []
        invariantResults = []
        previousInvariantResults = []
        lastInvariantRun = nil
        tapCounts = [:]
        visitedScreens = []
        breadcrumbs = []
        openedAt = [:]
        lastCrumb = ""
        crumbRepeat = 0
        sessionStartedAt = Date()
    }

    /// Stop recording automatically after this many minutes. 0 = never.
    /// A tester who forgets the toggle should not be recording on Thursday
    /// because they were testing on Monday.
    var autoOffMinutes: Int {
        didSet {
            UserDefaults.standard.set(autoOffMinutes, forKey: "qa.autoOffMinutes")
            armAutoOff()
        }
    }
    private var autoOffTask: Task<Void, Never>?
    private(set) var autoOffAt: Date?

    private func armAutoOff() {
        autoOffTask?.cancel()
        autoOffTask = nil
        autoOffAt = nil
        guard isEnabled, autoOffMinutes > 0 else { return }
        let deadline = Date().addingTimeInterval(TimeInterval(autoOffMinutes * 60))
        autoOffAt = deadline
        autoOffTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Double(self?.autoOffMinutes ?? 0) * 60))
            guard !Task.isCancelled, let self, self.isEnabled else { return }
            self.record(.note, screen: "QA", label: "QA mode auto-stopped",
                        detail: "after \(self.autoOffMinutes) min")
            self.isEnabled = false
        }
    }

    // MARK: Crash-proof snapshot
    // A watchdog kill takes the whole process with it, and with it every event
    // that would have explained the kill. The snapshot is the fix: a compact text
    // report written to defaults whenever something goes wrong and whenever the
    // app backgrounds, so the next launch can show what the last session was
    // doing when it died.

    private static let snapshotKey = "qa.lastSessionSnapshot.v1"
    private(set) var previousSessionReport: String?

    func persistSnapshot(reason: String) {
        // NOT gated on `isEnabled`. The two moments most worth snapshotting are
        // the tester switching QA off and the auto-off timer firing — and by the
        // time either of those runs, `isEnabled` is already false. Gating here
        // made the disable-time snapshot a silent no-op. Gate on having something
        // to say instead.
        guard !events.isEmpty || !breadcrumbs.isEmpty else { return }
        var out = ["Stocked QA — session snapshot (\(reason))",
                   "captured \(Date().formatted())",
                   "Build \(BuildConfig.version) (\(BuildConfig.buildNumber))",
                   headlineLine,
                   ""]
        if !breadcrumbs.isEmpty {
            out.append("LAST \(breadcrumbs.count) STEPS")
            out.append(contentsOf: breadcrumbs.map { "  " + $0 })
            out.append("")
        }
        let bad = events.filter { $0.kind == .failure || $0.kind == .violation }
        if !bad.isEmpty {
            out.append("FAILURES & VIOLATIONS")
            for e in bad.suffix(25) { out.append("  " + e.line) }
            out.append("")
        }
        out.append("LAST 60 EVENTS")
        for e in events.suffix(60) { out.append("  " + e.line) }
        UserDefaults.standard.set(out.joined(separator: "\n"), forKey: Self.snapshotKey)
    }

    func clearPreviousSessionReport() {
        previousSessionReport = nil
        UserDefaults.standard.removeObject(forKey: Self.snapshotKey)
    }

    // MARK: Derived

    var failureCount: Int { events.filter { $0.kind == .failure }.count }
    var violationCount: Int { events.filter { $0.kind == .violation }.count }
    var screenCount: Int { visitedScreens.count }
    var attemptCount: Int { events.filter { $0.kind == .attempt }.count }
    var successCount: Int { events.filter { $0.kind == .success }.count }

    var sessionDuration: TimeInterval { Date().timeIntervalSince(sessionStartedAt) }
    var sessionDurationText: String {
        let s = Int(sessionDuration)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }

    /// Successes as a share of resolved attempts. A session at 100% with zero
    /// attempts is not a passing session, it is an uninstrumented one, so the UI
    /// shows the raw counts next to it.
    var successRate: Double {
        let resolved = successCount + failureCount
        return resolved == 0 ? 1 : Double(successCount) / Double(resolved)
    }

    var headlineLine: String {
        "screens \(screenCount) · taps \(tapTotal) · attempts \(attemptCount) · failures \(failureCount) · violations \(violationCount) · \(sessionDurationText)"
    }

    func events(kind: QAEventKind?, search: String) -> [QAEvent] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return events.filter { e in
            (kind == nil || e.kind == kind!) && (q.isEmpty || e.searchHaystack.contains(q))
        }
    }

    func count(of kind: QAEventKind) -> Int { events.filter { $0.kind == kind }.count }

    var exportText: String {
        var out = ["Stocked QA session — \(Date().formatted())",
                   "Build \(BuildConfig.version) (\(BuildConfig.buildNumber))",
                   headlineLine,
                   ""]
        if !breadcrumbs.isEmpty {
            out.append("RECENT STEPS (newest last)")
            for c in breadcrumbs { out.append("  \(c)") }
            out.append("")
        }
        if !tapCounts.isEmpty {
            out.append("TAPS BY SCREEN")
            for (screen, n) in tapCounts.sorted(by: { $0.value > $1.value }) {
                out.append("  \(n)× \(screen)")
            }
            out.append("")
        }
        let dead = deadScreens
        if !dead.isEmpty {
            out.append("SCREENS VISITED BUT NEVER TAPPED")
            for s in dead { out.append("  \(s)") }
            out.append("")
        }
        let crashLog = DiagnosticsMonitor.shared.currentLog()
        let crashLines = crashLog.split(separator: "\n").filter { $0.contains("CRASH") || $0.contains("HANG") }
        if !crashLines.isEmpty {
            out.append("DEVICE CRASH/HANG LOG (MetricKit)")
            for l in crashLines.suffix(20) { out.append("  \(l)") }
            out.append("")
        }
        if !invariantResults.isEmpty {
            out.append("INVARIANTS")
            for r in invariantResults {
                out.append("  [\(r.status.rawValue.uppercased())] \(r.name) — \(r.detail)")
            }
            let fixed = fixedSinceLastRun
            if !fixed.isEmpty { out.append("  fixed since previous run: " + fixed.joined(separator: ", ")) }
            out.append("")
        }
        let dangling = danglingAttempts
        if !dangling.isEmpty {
            out.append("UNRESOLVED ATTEMPTS (started, never completed)")
            for u in dangling { out.append("  \(u.label) — \(u.screen) — open \(u.ageText)\(u.isHung ? "  ← HUNG" : "")") }
            out.append("")
        }
        out.append("EVENT LOG")
        for e in events { out.append("  " + e.line) }
        return out.joined(separator: "\n")
    }

    /// Everything, in one string — session, triage, runtime, processes, tickets,
    /// diagnostics and the device log. One share instead of six.
    var fullExportText: String {
        var out = ["════════ STOCKED QA — FULL EXPORT ════════",
                   Date().formatted(),
                   "Build \(BuildConfig.version) (\(BuildConfig.buildNumber)) · \(BuildConfig.buildTag)",
                   ""]
        out.append(QATriage.shared.exportText)
        out.append("")
        out.append(QARuntimeMonitor.shared.exportText)
        out.append("")
        let tickets = QATicketStore.shared.exportText
        if !tickets.isEmpty { out.append(tickets); out.append("") }
        let processes = QAProcessTracker.shared.exportText
        if !processes.isEmpty { out.append(processes); out.append("") }
        out.append(exportText)
        if let previous = previousSessionReport {
            out.append("")
            out.append("════════ PREVIOUS SESSION SNAPSHOT ════════")
            out.append(previous)
        }
        return out.joined(separator: "\n")
    }
}

nonisolated struct QAAttempt: Sendable {
    let label: String
    let screen: String
}

// MARK: - Screen tracking modifier

/// Apply at a screen root: `.qaScreen("Cook Now")`. No-op when QA mode is off.
struct QAScreenModifier: ViewModifier {
    let name: String
    func body(content: Content) -> some View {
        content.onAppear { QARecorder.shared.enteredScreen(name) }
    }
}

extension View {
    func qaScreen(_ name: String) -> some View {
        modifier(QAScreenModifier(name: name))
    }
}
