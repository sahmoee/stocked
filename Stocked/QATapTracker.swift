// QATapTracker.swift — app-wide tap counting for QA mode.
//
// WHY THE OLD VERSION ALWAYS REPORTED 0 TAPS
// It mounted a transparent overlay whose `hitTest` returned `nil` for itself, so
// touches would pass through to the UI underneath. That part worked. The problem
// is that returning `nil` from `hitTest` does not mean "let me watch this touch
// go by" — it means "I am not in this touch's responder chain at all". A gesture
// recognizer attached to a view that is never the hit-test result never receives
// a single touch, so it never fires. The counter was correct; it was simply
// never called.
//
// THE FIX
// Attach the recognizer to the UIWindow instead. Every touch in the app passes
// through the window on its way to whatever it lands on, so a non-cancelling,
// non-delaying recognizer there sees all of them without changing where a single
// touch is delivered. This is the same technique keyboard-dismiss-on-tap uses.
//
// The window is not available at `makeUIView` time (the view is not in a
// hierarchy yet), so installation happens in `didMoveToWindow`, and the
// recognizer is removed again when QA mode turns off or the view goes away.

import SwiftUI
import UIKit

struct QATapTracker: View {
    @State private var recorder = QARecorder.shared
    var body: some View {
        if recorder.isEnabled {
            TapCountingView()
                .frame(width: 0, height: 0)   // observes only; occupies nothing
                .allowsHitTesting(false)
        }
    }
}

private struct TapCountingView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = WindowTapObserver()
        v.coordinator = context.coordinator
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private var recognizer: UITapGestureRecognizer?

        func attach(to window: UIWindow) {
            // Idempotent: `didMoveToWindow` can fire more than once, and two
            // recognizers would double every count.
            guard self.window !== window else { return }
            detach()

            let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
            // Observe without interfering: never swallow the touch, never delay
            // it, and always coexist with the real recognizer that will handle it.
            tap.cancelsTouchesInView = false
            tap.delaysTouchesBegan = false
            tap.delaysTouchesEnded = false
            tap.requiresExclusiveTouchType = false
            tap.delegate = self
            window.addGestureRecognizer(tap)

            self.window = window
            self.recognizer = tap
        }

        func detach() {
            if let r = recognizer { window?.removeGestureRecognizer(r) }
            recognizer = nil
            window = nil
        }

        @objc func tapped() {
            MainActor.assumeIsolated { QARecorder.shared.tapped() }
        }

        // Recognize alongside every button, list row, scroll view and sheet
        // dismissal in the app, and never block any of them from recognizing.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }

        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }

        // A tap on any control still counts — the point is "did this screen
        // receive interaction", and buttons are exactly where it matters.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool { true }
    }
}

/// A zero-size, non-interactive view whose only job is to find the window and
/// hand it to the coordinator.
private final class WindowTapObserver: UIView {
    weak var coordinator: TapCountingView.Coordinator?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { coordinator?.attach(to: window) }
        else { coordinator?.detach() }
    }
}
