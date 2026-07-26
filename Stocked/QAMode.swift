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
//   • actions report themselves via QARecorder.attempt(...) at the handful of
//     places where something can actually fail (saves, imports, network calls)
//   • FAILURES are captured automatically, without instrumentation, by the
//     invariant probes
// Coverage of taps therefore grows as .qaScreen and .attempt are added, and the
// value does not depend on that: the probes catch the wrong-state bugs whether
// or not the tap that caused them was logged.
//
// OFF BY DEFAULT, and off in the App Store build unless explicitly enabled —
// see `isAvailable`. Recording costs nothing when disabled: every entry point
// early-returns on the flag before allocating anything.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import Observation

// MARK: - Event model

nonisolated enum QAEventKind: String, Codable, Sendable {
    case screen         // a screen appeared
    case attempt        // the user tried to do something
    case success        // that thing worked
    case failure        // that thing failed
    case violation      // an invariant probe found two surfaces disagreeing
    case note           // manual marker the tester dropped
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

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
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
                record(.note, screen: "QA", label: "QA mode enabled")
            } else {
                // Stop the background loop and keep whatever was captured.
                QABackgroundRunner.shared.stop()
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

    /// Latest invariant results, newest run only.
    private(set) var invariantResults: [QAInvariantResult] = []
    private(set) var lastInvariantRun: Date?

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "qa.mode.enabled") && Self.isAvailable
    }

    // MARK: Recording

    func record(_ kind: QAEventKind, screen: String? = nil, label: String, detail: String = "") {
        guard isEnabled else { return }
        let e = QAEvent(kind: kind, screen: screen ?? currentScreen, label: label, detail: detail)
        events.append(e)
        if events.count > cap { events.removeFirst(events.count - cap) }
    }

    func enteredScreen(_ name: String) {
        guard isEnabled else { return }
        guard name != currentScreen else { return }   // ignore re-appears
        currentScreen = name
        record(.screen, screen: name, label: "appeared")
    }

    /// Log an attempt. Call `succeeded` or `failed` on the returned token so an
    /// attempt that never resolves is visible as a dangling attempt — which is
    /// itself a finding (a spinner that never ends).
    @discardableResult
    func attempt(_ label: String, detail: String = "") -> QAAttempt {
        record(.attempt, label: label, detail: detail)
        return QAAttempt(label: label, screen: currentScreen)
    }

    func succeeded(_ a: QAAttempt, detail: String = "") {
        record(.success, screen: a.screen, label: a.label, detail: detail)
    }

    func failed(_ a: QAAttempt, detail: String) {
        record(.failure, screen: a.screen, label: a.label, detail: detail)
    }

    /// Convenience for the many call sites that already have a thrown error.
    func failed(_ a: QAAttempt, error: Error) {
        failed(a, detail: error.localizedDescription)
    }

    func setInvariantResults(_ results: [QAInvariantResult]) {
        invariantResults = results
        lastInvariantRun = Date()
        for r in results where r.status != .ok {
            record(.violation, screen: "Invariants", label: r.name, detail: r.detail)
        }
    }

    func clear() {
        events = []
        invariantResults = []
        lastInvariantRun = nil
    }

    // MARK: Derived

    var failureCount: Int { events.filter { $0.kind == .failure }.count }
    var violationCount: Int { events.filter { $0.kind == .violation }.count }
    var screenCount: Int { Set(events.filter { $0.kind == .screen }.map(\.screen)).count }
    var attemptCount: Int { events.filter { $0.kind == .attempt }.count }

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

    var exportText: String {
        var out = ["Stocked QA session — \(Date().formatted())",
                   "Build \(BuildConfig.version) (\(BuildConfig.buildNumber))",
                   "screens \(screenCount) · attempts \(attemptCount) · failures \(failureCount) · violations \(violationCount)",
                   ""]
        if !invariantResults.isEmpty {
            out.append("INVARIANTS")
            for r in invariantResults {
                out.append("  [\(r.status.rawValue.uppercased())] \(r.name) — \(r.detail)")
            }
            out.append("")
        }
        let unresolved = unresolvedAttempts
        if !unresolved.isEmpty {
            out.append("UNRESOLVED ATTEMPTS (started, never completed)")
            for u in unresolved { out.append("  \(u)") }
            out.append("")
        }
        out.append("EVENT LOG")
        for e in events { out.append("  " + e.line) }
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
