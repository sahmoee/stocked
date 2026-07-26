// QATapTracker.swift — app-wide tap counting for QA mode.
//
// A transparent, hit-test-passthrough layer at the root (same proven pattern as
// StockedShell's KeyboardDismissView) with a UITapGestureRecognizer that never
// cancels or delays child touches and recognizes simultaneously with everything.
// Each tap bumps QARecorder's per-screen counter — aggregate counts, zero events,
// zero cost when QA mode is off (the view renders nothing at all).

import SwiftUI

struct QATapTracker: View {
    @State private var recorder = QARecorder.shared
    var body: some View {
        if recorder.isEnabled {
            TapCountingView()
                .allowsHitTesting(true)
                .ignoresSafeArea()
        }
    }
}

private struct TapCountingView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = PassthroughTapView()
        v.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false
        tap.delaysTouchesBegan = false
        tap.delaysTouchesEnded = false
        tap.delegate = context.coordinator
        v.addGestureRecognizer(tap)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        @objc func tapped() { QARecorder.shared.tapped() }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

/// Passes every touch through to whatever is underneath — this layer only observes.
private final class PassthroughTapView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit == self ? nil : hit
    }
}
