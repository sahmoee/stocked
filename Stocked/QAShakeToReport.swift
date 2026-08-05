// QAShakeToReport.swift
// ─────────────────────────────────────────────────────────────────────────────
// IMPROVEMENT 6 (Build 74) — shake the phone to file a bug.
//
// The long-press reporter works everywhere except the two places bugs are most
// worth catching: inside a gesture, and inside a control that has already claimed
// the touch. Press and hold on a scroll view and you scroll. Press and hold on a
// text field and you get the magnifier and the system edit menu. Press and hold
// during a drag and the drag wins. Those are exactly the interactions people file
// bugs about, and they were the interactions where the reporter could not be
// opened without first letting go — by which time the screen showed the app's
// recovered state, not the broken one.
//
// A shake has no such conflict. Nothing in the app consumes one.
//
// WHY NOT `motionEnded(_:with:)`
// The obvious implementation is overriding `motionEnded` on a UIResponder. Two
// problems, both bad enough on their own. Overriding it on `UIWindow` from an
// extension is overriding a method in a class this app does not own — undefined
// at best, and unverifiable here without a compiler. Putting a real
// `UIResponder` subclass in the chain means making it first responder, which
// takes focus away from whatever text field the tester is typing in, closing the
// keyboard every time QA mode is switched on.
//
// So: read the accelerometer directly. Core Motion's raw accelerometer needs no
// usage-description string and no permission prompt (unlike motion *activity*,
// which is a different API and does), it costs one 50 Hz callback while QA mode
// is on, and it stops dead the moment QA mode is off.
//
// The detector wants two spikes rather than one. A single hard jolt is a phone
// being put down on a table; two inside half a second is a person shaking it.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import CoreMotion

nonisolated enum QAShakeSettings {
    static let enabledKey = "qa.shake.enabled"
    /// On by default once QA mode is on — a reporting shortcut nobody knows
    /// about is not a reporting shortcut. `object(forKey:)` rather than `bool`
    /// so "never set" is distinguishable from "deliberately off".
    static var isEnabled: Bool {
        guard UserDefaults.standard.object(forKey: enabledKey) != nil else { return true }
        return UserDefaults.standard.bool(forKey: enabledKey)
    }
}

@MainActor
@Observable
final class QAShakeDetector {
    static let shared = QAShakeDetector()

    /// Magnitude in g above which a sample counts as a jolt. 1.0g is gravity at
    /// rest, so this is 1.7g of movement on top of it — comfortably above a brisk
    /// walk with the phone in hand, comfortably below what it takes to shake one.
    private let threshold: Double = 2.7
    /// Two jolts must land inside this window to count as a shake.
    private let pairWindow: TimeInterval = 0.6
    /// And no second shake may fire for this long afterwards, so one enthusiastic
    /// shake does not open three composers.
    private let cooldown: TimeInterval = 2.5

    private let motion = CMMotionManager()
    private var firstJoltAt: Date?
    private var lastFireAt = Date.distantPast
    private(set) var isRunning = false
    /// Diagnostic only — shown in QA so a tester who says "shake does nothing"
    /// can see whether the hardware is reporting at all.
    private(set) var lastMagnitude: Double = 0
    private(set) var shakeCount = 0

    private init() {}

    func start() {
        guard !isRunning else { return }
        guard QARecorder.isAvailable, QAShakeSettings.isEnabled else { return }
        guard motion.isAccelerometerAvailable else { return }
        motion.accelerometerUpdateInterval = 1.0 / 50.0
        // The handler captures nothing but a `Double`. Capturing `self` here
        // would be capturing a non-Sendable MainActor class inside a `@Sendable`
        // closure, which Swift 6 rejects outright — and `assumeIsolated` cannot
        // rescue it, because the capture itself is the error, not the call. All
        // the maths that can be done off the actor is done off it, and only the
        // one scalar crosses.
        motion.startAccelerometerUpdates(to: .main) { data, _ in
            guard let data else { return }
            let a = data.acceleration
            let magnitude = (a.x * a.x + a.y * a.y + a.z * a.z).squareRoot()
            Task { @MainActor in QAShakeDetector.shared.consume(magnitude) }
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        motion.stopAccelerometerUpdates()
        isRunning = false
        firstJoltAt = nil
    }

    /// Follows QA mode and the toggle together. Called from the mount below on
    /// every change of either, and safe to call when nothing has changed.
    func sync() {
        if QARecorder.shared.isEnabled && QAShakeSettings.isEnabled { start() } else { stop() }
    }

    fileprivate func consume(_ magnitude: Double) {
        lastMagnitude = magnitude
        guard magnitude >= threshold else { return }
        let now = Date()
        guard now.timeIntervalSince(lastFireAt) > cooldown else { return }

        if let first = firstJoltAt, now.timeIntervalSince(first) <= pairWindow {
            firstJoltAt = nil
            lastFireAt = now
            shakeCount += 1
            fire()
        } else {
            firstJoltAt = now
        }
    }

    private func fire() {
        // Already composing? A shake mid-composition is the tester's hand, not a
        // second report.
        guard !QAReporterPresenter.shared.isPresenting else { return }

        QARecorder.shared.record(.note, label: "Shake to report",
                                 detail: String(format: "%.1fg", lastMagnitude))
        let shot = QAScreenshot.capture()
        var context = QAContextCapture.current()
        context.breadcrumbs.append("opened by shake")
        QAReporterPresenter.shared.present(
            QAReportDraft(screenshot: shot, context: context))
    }
}

// MARK: - Mount

/// Zero-size view mounted alongside the other QA surfaces in RootView. Exists to
/// give the detector a lifetime tied to the app's, and to restart it when either
/// QA mode or the toggle changes.
struct QAShakeMount: View {
    @State private var recorder = QARecorder.shared
    @AppStorage(QAShakeSettings.enabledKey) private var enabled = true

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear { QAShakeDetector.shared.sync() }
            .onChange(of: recorder.isEnabled) { QAShakeDetector.shared.sync() }
            .onChange(of: enabled) { QAShakeDetector.shared.sync() }
    }
}
