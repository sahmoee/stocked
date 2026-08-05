// QATouchTrail.swift — where the tester's fingers actually were.
// ─────────────────────────────────────────────────────────────────────────────
// THE PROBLEM
// A bug report screenshot shows the screen at the moment of the report. It does
// not show what was tapped to get there, and "I tapped the thing at the top" is
// ambiguous on a screen with four things at the top. `QARecorder.tapped()`
// already counts taps per screen, but a count cannot be pointed at.
//
// WHAT THIS ADDS
// Every touch-down in the app is recorded as a point and a timestamp, capped
// and pruned. Two things read that list:
//
//  1. A live overlay — rings that bloom and fade under the finger while QA is
//     on, so a screen recording or a demo shows what is being pressed.
//  2. The report screenshot — the last few seconds of touches are drawn into
//     the image, numbered in order, so the picture says "these five taps, in
//     this order, then this happened".
//
// WHY THE OVERLAY IS NOT WHAT LANDS IN THE PICTURE
// The obvious shortcut is to put the live overlay below `.alert` and let
// `QAScreenshot` composite it for free. That couples two things that want to
// differ: the overlay shows the last ~1s so it feels responsive, while the
// screenshot wants the last ~6s so it tells a story, and the overlay is off by
// default while the annotation should not be. So the overlay window sits at
// `.alert + 0.25` — above the `windowLevel <= .alert` cut that
// `QAScreenshot.visibleWindows()` makes — and the screenshot draws its own
// annotation. One drawing path, no double exposure, no accidental rings in a
// picture that was meant to be clean.
//
// WHY A UIGestureRecognizer SUBCLASS AND NOT A TAP RECOGNIZER
// A `UITapGestureRecognizer` fires on a *completed* tap, which misses the start
// of every scroll, drag and long press — exactly the gestures whose beginning
// is worth seeing. A bare `UIGestureRecognizer` subclass sees `touchesBegan`
// for everything, and by immediately failing itself it can never win, never
// delay, and never cancel anything. It is a listener wearing a recognizer's
// clothes.
//
// COORDINATES
// Points are stored in the window's coordinate space, which for a full-screen
// app window is the screen's space, which is the space `QAScreenshot` renders
// in. No conversion at draw time, and no stale conversion if the app's window
// moves under Stage Manager — the recognizer re-reports on every touch.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import UIKit
import Observation

// MARK: - Settings

nonisolated enum QATouchTrailSettings {
    /// Live rings under the finger. Off by default — it is a demo aid, not
    /// something to leave on through a whole session.
    static let overlayKey = "qa.touches.overlay"
    /// Draw touches into report screenshots. On by default: this is the half
    /// that makes a bug report readable, and it costs nothing until a report is
    /// filed.
    static let annotateKey = "qa.touches.annotate"

    static var overlayEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: overlayKey) }
        set { UserDefaults.standard.set(newValue, forKey: overlayKey) }
    }

    static var annotateShots: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: annotateKey) == nil { return true }
            return d.bool(forKey: annotateKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: annotateKey) }
    }
}

// MARK: - Model

nonisolated struct QATouchPoint: Identifiable, Sendable {
    let id = UUID()
    let location: CGPoint
    let at: Date
    /// True for the touch-down, false for the moves that follow it. Only downs
    /// are numbered in the annotation — numbering every move point would bury
    /// the picture under a hundred labels.
    let isDown: Bool

    func age(now: Date = Date()) -> TimeInterval { now.timeIntervalSince(at) }
}

@MainActor
@Observable
final class QATouchTrail {
    static let shared = QATouchTrail()
    private init() {}

    /// How far back the annotation reaches. Six seconds is about three
    /// deliberate taps plus the pause before realising something is wrong.
    static let annotationWindow: TimeInterval = 6
    /// How long a ring stays visible in the live overlay.
    static let overlayWindow: TimeInterval = 1.1
    /// Hard cap. A fast scroll produces move points at display rate, and an
    /// unbounded array here would be a leak with a stopwatch on it.
    private static let cap = 240

    private(set) var points: [QATouchPoint] = []

    /// Bumped on every record so the overlay's `@Observable` read has a scalar
    /// to depend on — an array append does invalidate, but the redraw timer
    /// also needs a reason to re-run when nothing was appended.
    private(set) var revision: Int = 0

    func record(_ location: CGPoint, isDown: Bool) {
        points.append(QATouchPoint(location: location, at: Date(), isDown: isDown))
        if points.count > Self.cap { points.removeFirst(points.count - Self.cap) }
        revision &+= 1
    }

    /// Drop anything older than the longest window either reader cares about.
    func prune(now: Date = Date()) {
        let horizon = max(Self.annotationWindow, Self.overlayWindow)
        let before = points.count
        points.removeAll { now.timeIntervalSince($0.at) > horizon }
        if points.count != before { revision &+= 1 }
    }

    func clear() {
        points.removeAll()
        revision &+= 1
    }

    /// Touch-downs inside the annotation window, oldest first, so numbering
    /// reads in the order they happened.
    func annotationPoints(now: Date = Date()) -> [QATouchPoint] {
        points.filter { $0.isDown && now.timeIntervalSince($0.at) <= Self.annotationWindow }
    }

    func overlayPoints(now: Date = Date()) -> [QATouchPoint] {
        points.filter { now.timeIntervalSince($0.at) <= Self.overlayWindow }
    }

    /// One line for the ticket body, so the trail survives even when the
    /// screenshot does not (screenshots live in Caches and iOS may reclaim
    /// them; the ticket text is in defaults and does not evaporate).
    func summaryLine(now: Date = Date()) -> String {
        let pts = annotationPoints(now: now)
        guard !pts.isEmpty else { return "Touches: none in the last \(Int(Self.annotationWindow))s" }
        let coords = pts.suffix(8).map { "(\(Int($0.location.x)),\(Int($0.location.y)))" }
        return "Touches (last \(Int(Self.annotationWindow))s, oldest first): " + coords.joined(separator: " → ")
    }
}

// MARK: - Drawing

/// Shared by the live overlay and the screenshot annotator so a ring means the
/// same thing in both places.
@MainActor
enum QATouchTrailRenderer {
    /// Draw numbered rings into the *current* graphics context. The caller owns
    /// the context; this only draws, which is what lets the same code run
    /// inside `UIGraphicsImageRenderer` for a screenshot and inside `draw(_:)`
    /// for a live view.
    static func drawAnnotation(_ points: [QATouchPoint], now: Date = Date()) {
        guard let ctx = UIGraphicsGetCurrentContext(), !points.isEmpty else { return }

        // Connect the dots first, underneath the rings, so the order is legible
        // even where two taps landed close together.
        if points.count > 1 {
            ctx.saveGState()
            ctx.setStrokeColor(UIColor.systemYellow.withAlphaComponent(0.55).cgColor)
            ctx.setLineWidth(2)
            ctx.setLineDash(phase: 0, lengths: [5, 4])
            ctx.move(to: points[0].location)
            for p in points.dropFirst() { ctx.addLine(to: p.location) }
            ctx.strokePath()
            ctx.restoreGState()
        }

        for (i, p) in points.enumerated() {
            // Oldest touches fade, newest is solid — so "what did I just press"
            // is answered at a glance.
            let age = p.age(now: now)
            let freshness = 1 - min(1, age / QATouchTrail.annotationWindow)
            let alpha = 0.35 + 0.55 * freshness
            let r: CGFloat = 21

            ctx.saveGState()
            ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(alpha * 0.28).cgColor)
            ctx.fillEllipse(in: CGRect(x: p.location.x - r, y: p.location.y - r,
                                       width: r * 2, height: r * 2))
            ctx.setStrokeColor(UIColor.systemYellow.withAlphaComponent(alpha).cgColor)
            ctx.setLineWidth(2.5)
            ctx.strokeEllipse(in: CGRect(x: p.location.x - r, y: p.location.y - r,
                                         width: r * 2, height: r * 2))
            ctx.restoreGState()

            let label = "\(i + 1)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 13, weight: .heavy),
                .foregroundColor: UIColor.black.withAlphaComponent(alpha),
            ]
            let size = label.size(withAttributes: attrs)
            label.draw(at: CGPoint(x: p.location.x - size.width / 2,
                                   y: p.location.y - size.height / 2),
                       withAttributes: attrs)
        }
    }
}

// MARK: - The observing recognizer

/// Sees every touch and wins nothing. `state = .failed` in `touchesBegan`
/// guarantees it can never claim a gesture, cancel a control's touch, or delay
/// delivery — the recognizer exists only for the side effect in its overrides.
@MainActor
private final class QATouchObserverRecognizer: UIGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        record(touches, isDown: true)
        // Fail immediately. A recognizer in .failed is out of the running for
        // this gesture and cannot affect any other recognizer's outcome.
        state = .failed
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        record(touches, isDown: false)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = .failed
    }

    private func record(_ touches: Set<UITouch>, isDown: Bool) {
        guard QARecorder.shared.isEnabled else { return }
        for t in touches {
            // `nil` means the window's own coordinate space, which is the space
            // `QAScreenshot` renders into.
            QATouchTrail.shared.record(t.location(in: nil), isDown: isDown)
        }
    }
}

// MARK: - Mount

/// Zero-size SwiftUI view that installs the observer on the window, the same
/// `didMoveToWindow` trick `QATapTracker` uses — a recognizer on a view that
/// never hit-tests receives nothing, so it has to go on the window.
struct QATouchTrailTracker: View {
    @State private var recorder = QARecorder.shared

    var body: some View {
        if recorder.isEnabled {
            TouchObservingView()
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
    }
}

private struct TouchObservingView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = WindowTouchObserver()
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

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private weak var window: UIWindow?
        private var recognizer: UIGestureRecognizer?

        func attach(to window: UIWindow) {
            // `didMoveToWindow` can fire more than once; two recognizers would
            // double every recorded point.
            guard self.window !== window else { return }
            detach()

            let r = QATouchObserverRecognizer()
            r.cancelsTouchesInView = false
            r.delaysTouchesBegan = false
            r.delaysTouchesEnded = false
            r.delegate = self
            window.addGestureRecognizer(r)

            self.window = window
            self.recognizer = r
        }

        func detach() {
            if let r = recognizer { window?.removeGestureRecognizer(r) }
            recognizer = nil
            window = nil
        }

        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                           shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
        nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                           shouldReceive touch: UITouch) -> Bool { true }
    }
}

private final class WindowTouchObserver: UIView {
    weak var coordinator: TouchObservingView.Coordinator?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { coordinator?.attach(to: window) }
        else { coordinator?.detach() }
    }
}

// MARK: - Live overlay window

/// Rings under the finger, in a window of their own so they float over sheets
/// and alerts like the rest of the QA furniture. Never interactive, never key,
/// and above the screenshot cut so it cannot appear twice in a picture.
@MainActor
final class QATouchOverlayWindow {
    static let shared = QATouchOverlayWindow()
    private init() {}

    private var window: UIWindow?

    func sync(visible: Bool) { if visible { show() } else { hide() } }

    private func show() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        let view = QATouchRingView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false

        let vc = UIViewController()
        vc.view = view

        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 0.25)
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false
        w.rootViewController = vc
        w.isHidden = false          // never makeKeyAndVisible()
        window = w
        view.start()
    }

    private func hide() {
        guard let w = window else { return }
        (w.rootViewController?.view as? QATouchRingView)?.stop()
        window = nil
        w.isHidden = true
        w.windowScene = nil
    }
}

/// Plain `UIView.draw` driven by a display link. SwiftUI would redraw the whole
/// hosted tree for every touch move; this redraws one transparent layer and
/// stops entirely when there is nothing to show.
private final class QATouchRingView: UIView {
    private var link: CADisplayLink?

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        // The rings are decoration. 30fps is smooth enough for them and leaves
        // the other half of the frame budget to the app being tested.
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    // NO deinit CLEANUP, AND IT IS NOT AN OVERSIGHT.
    //
    // Swift 6 forbids it: `deinit` is nonisolated, `link` is a MainActor
    // property of a non-Sendable type, and reading it there is a data race the
    // compiler will not accept.
    //
    // Nothing leaks as a result. A CADisplayLink added to a run loop is retained
    // by that run loop and retains its target, so from `start()` until `stop()`
    // this view is kept alive by the link itself. `deinit` therefore cannot run
    // while a live link exists — by the time it does run, `stop()` has already
    // invalidated and cleared it, or `start()` was never called. The old
    // `link?.invalidate()` here was unreachable in every case that mattered.
    //
    // `hide()` is the one caller of `stop()`, and it is the only path by which
    // the window and this view go away.

    @objc private func tick() {
        MainActor.assumeIsolated {
            QATouchTrail.shared.prune()
            setNeedsDisplay()
        }
    }

    override func draw(_ rect: CGRect) {
        MainActor.assumeIsolated {
            guard let ctx = UIGraphicsGetCurrentContext() else { return }
            let now = Date()
            for p in QATouchTrail.shared.overlayPoints(now: now) {
                let age = p.age(now: now)
                let t = min(1, age / QATouchTrail.overlayWindow)
                // Bloom outward and fade: the ring grows from 16 to 40 points
                // while its alpha falls to zero, which reads as a ripple.
                let r = 16 + 24 * t
                let alpha = (1 - t) * (p.isDown ? 0.9 : 0.45)
                ctx.saveGState()
                ctx.setStrokeColor(UIColor.systemYellow.withAlphaComponent(alpha).cgColor)
                ctx.setLineWidth(p.isDown ? 3 : 1.5)
                ctx.strokeEllipse(in: CGRect(x: p.location.x - r, y: p.location.y - r,
                                             width: r * 2, height: r * 2))
                if p.isDown {
                    ctx.setFillColor(UIColor.systemYellow.withAlphaComponent(alpha * 0.22).cgColor)
                    ctx.fillEllipse(in: CGRect(x: p.location.x - r, y: p.location.y - r,
                                               width: r * 2, height: r * 2))
                }
                ctx.restoreGState()
            }
        }
    }
}

/// Zero-size mount that keeps the overlay window in step with the setting and
/// with QA mode itself.
struct QATouchOverlayMount: View {
    @State private var recorder = QARecorder.shared
    @State private var enabled = QATouchTrailSettings.overlayEnabled

    private var shouldShow: Bool { recorder.isEnabled && enabled }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear {
                enabled = QATouchTrailSettings.overlayEnabled
                QATouchOverlayWindow.shared.sync(visible: shouldShow)
            }
            .onDisappear { QATouchOverlayWindow.shared.sync(visible: false) }
            .onChange(of: shouldShow) { _, now in
                QATouchOverlayWindow.shared.sync(visible: now)
            }
            .task {
                // The setting can be flipped from the QA menu, which lives in a
                // different window and so cannot hand this view a binding.
                // Polling once a second is cheaper than the plumbing.
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    let now = QATouchTrailSettings.overlayEnabled
                    if now != enabled { enabled = now }
                }
            }
    }
}
