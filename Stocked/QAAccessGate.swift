// QAAccessGate.swift — one QA unlock, good for ten minutes, shared by everything.
// ─────────────────────────────────────────────────────────────────────────────
// WHAT WAS WRONG
// `StockedQAGateView` held its unlock in `@State`. `@State` dies with the view,
// and the QA screen is pushed and popped constantly during a session — into
// App Health, back out to fix something, back in to check it. So the code was
// being retyped every couple of minutes, on a phone, one-handed, usually while
// holding the thing you were about to report. That is a tax on exactly the
// behaviour QA is meant to encourage.
//
// WHAT THIS IS
// A single unlock timestamp in `UserDefaults`, and one rolling ten-minute
// window measured from it. Inside the window every QA surface opens straight
// through. Outside it the code is asked for once, and the window restarts.
//
// WHY A ROLLING WINDOW AND NOT A SLIDING ONE
// The window is *not* extended by activity. Ten minutes after the code is
// typed, it is asked for again, whether or not QA was used in the meantime.
// A sliding window that renews on every open would, in practice, never expire
// during a test session — which is the same as having no gate. Ten fixed
// minutes is long enough that a single session is uninterrupted and short
// enough that a phone left on a table is not an open door.
//
// WHY IT IS OBSERVABLE
// The floating QA button needs to know whether QA has ever been unlocked (that
// is its whole appearance condition), and the gate view needs to re-render the
// moment the window lapses. Both read this one object.
//
// CLOCK
// `Date()` and not `uptimeNanoseconds`, deliberately. A device that reboots
// mid-session should re-ask, and a user who winds the clock forward to skip the
// gate has already got the code. The failure mode of a wall clock here is
// "asks again sooner than expected", which is the safe direction.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import Observation

nonisolated enum QAAccessGateKeys {
    /// Instant the code was last accepted, as a `timeIntervalSinceReferenceDate`.
    static let unlockedAtKey = "qa.access.unlockedAt"
    /// Sticky: has the code *ever* been accepted on this install. Drives whether
    /// the floating button is offered at all, and is deliberately not cleared
    /// when the ten minutes lapse — the tester has proved who they are, they
    /// just have to prove it again to read anything.
    static let everUnlockedKey = "qa.access.everUnlocked"
}

@MainActor
@Observable
final class QAAccessGate {
    static let shared = QAAccessGate()

    /// The window. Changing this one number changes the whole policy.
    static let window: TimeInterval = 10 * 60

    /// Case-insensitive. Kept here rather than in the view so there is exactly
    /// one copy of it in the app.
    private static let code = "Joo"

    /// Backing store is `UserDefaults`, but reads go through these mirrored
    /// properties so `@Observable` can see them change. Writing both in the same
    /// statement keeps them from drifting.
    private(set) var unlockedAt: Date?
    private(set) var hasEverUnlocked: Bool

    private init() {
        let d = UserDefaults.standard
        let stamp = d.double(forKey: QAAccessGateKeys.unlockedAtKey)
        unlockedAt = stamp > 0 ? Date(timeIntervalSinceReferenceDate: stamp) : nil
        hasEverUnlocked = d.bool(forKey: QAAccessGateKeys.everUnlockedKey)
    }

    // MARK: State

    /// True while the ten minutes are still running.
    var isUnlocked: Bool {
        guard let at = unlockedAt else { return false }
        return Date().timeIntervalSince(at) < Self.window
    }

    /// Seconds left, clamped at zero. Used for the "expires in 7m" footer, and
    /// by the floating button to decide whether tapping it will re-prompt.
    var secondsRemaining: TimeInterval {
        guard let at = unlockedAt else { return 0 }
        return max(0, Self.window - Date().timeIntervalSince(at))
    }

    var remainingText: String {
        let s = Int(secondsRemaining.rounded())
        guard s > 0 else { return "expired" }
        if s < 60 { return "\(s)s left" }
        return "\(s / 60)m \(s % 60)s left"
    }

    // MARK: Transitions

    /// Returns true when the code matched. The caller shows the error; this
    /// type does not own any UI.
    @discardableResult
    func unlock(with entry: String) -> Bool {
        let typed = entry.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard typed == Self.code.lowercased() else { return false }
        stampUnlocked()
        return true
    }

    /// Extend without re-typing. Called from nowhere by default — it exists so
    /// that a future "keep me in" toggle has a correct implementation to call
    /// rather than reaching into defaults itself.
    func refresh() {
        guard isUnlocked else { return }
        stampUnlocked()
    }

    /// End the window now. The sticky `hasEverUnlocked` survives, so the
    /// floating button stays available and simply re-prompts on tap.
    func lock() {
        unlockedAt = nil
        UserDefaults.standard.removeObject(forKey: QAAccessGateKeys.unlockedAtKey)
    }

    private func stampUnlocked() {
        let now = Date()
        unlockedAt = now
        hasEverUnlocked = true
        let d = UserDefaults.standard
        d.set(now.timeIntervalSinceReferenceDate, forKey: QAAccessGateKeys.unlockedAtKey)
        d.set(true, forKey: QAAccessGateKeys.everUnlockedKey)
    }

    /// Called by the gate view's one-second tick. `@Observable` tracks property
    /// *reads*, and `isUnlocked` is computed from `Date()` — which is not a
    /// tracked property, so nothing would ever invalidate the view when the
    /// window lapses. Nudging `unlockedAt` to nil at expiry gives observation
    /// something real to see.
    func expireIfLapsed() {
        if unlockedAt != nil && !isUnlocked { lock() }
    }
}
