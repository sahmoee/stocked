// QAFloatingBubble.swift — the floating QA button, and the menu it opens.
// ─────────────────────────────────────────────────────────────────────────────
// WHAT THIS REPLACES
// The old `QAFloatingBubble` was a SwiftUI `VStack`/`Spacer` overlay meant for
// RootView with a `.sheet` hanging off it. It was also never mounted anywhere,
// which was merciful, because both halves of that design are broken for this
// job:
//
//  - An overlay in RootView is *inside* the app's view hierarchy, so it is
//    covered by every sheet, full-screen cover, popover and alert the app puts
//    up. A QA button you cannot reach from inside a sheet is a QA button that
//    is missing exactly when a tester wants it.
//  - `.sheet` becomes a UIKit modal presented from the root view controller,
//    and a controller cannot present while it is already presenting. So the
//    menu would silently fail to open in the same situations.
//
// Build 71 learned this the hard way with the press-and-hold reporter and
// solved it with windows. This file applies the same solution.
//
// THE WINDOW STACK, TOP TO BOTTOM
//   .alert + 1     the issue reporter          (QAReporterPresenter)
//   .alert + 0.5   this menu, while open       (QAFloatingMenuPresenter)
//   .alert + 0.5   this button                 (QAFloatingButtonWindow)
//   .alert         the QA HUD                  (QAHUDWindow)
//   .normal        the app
//
// `UIWindow.Level` wraps a `CGFloat`, so a level between `.alert` and
// `.alert + 1` is available and is not a hack. The ask was for the button to
// sit above every screen and menu *except* the report pop-up, and that is
// precisely what these numbers say.
//
// WHY THE BUTTON WINDOW IS TINY
// A full-screen window would have to pass through every touch that is not on
// the button, which means a passthrough `hitTest` and a hosting view that
// reliably reports "not mine" for empty space. SwiftUI hosting views are not
// dependable about that. A window that is only as big as the button cannot
// intercept anything else by construction — there is no window there to
// intercept with. Dragging moves the window's frame rather than an offset
// inside it.
//
// The button window is never made key. Key status is about first responder and
// keyboard routing; touch delivery goes to the topmost window that hit-tests to
// a view, key or not. Making it key would steal focus from a text field the
// tester is typing in, which is the opposite of unobtrusive.
//
// WHY IT IS NOT IN SCREENSHOTS
// `QAScreenshot.visibleWindows()` filters to `windowLevel <= .alert`. Both
// windows here sit above that line, so the QA furniture never photographs
// itself into a bug report.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import UIKit
import Combine   // NotificationCenter.publisher — SwiftUI re-exports UIKit, not Combine

// MARK: - Settings

nonisolated enum QAFloatingButtonSettings {
    /// Tester can hide the button without locking QA.
    static let enabledKey  = "qa.floating.enabled"
    /// Last resting position, stored as the button's top-left in screen
    /// coordinates. Clamped on every show, so a screen-size change (rotation, a
    /// different device restoring the same defaults) cannot strand it.
    static let originXKey  = "qa.floating.x"
    static let originYKey  = "qa.floating.y"

    static var isEnabled: Bool {
        get {
            let d = UserDefaults.standard
            if d.object(forKey: enabledKey) == nil { return true }
            return d.bool(forKey: enabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
}

// MARK: - The button's window

@MainActor
final class QAFloatingButtonWindow {
    static let shared = QAFloatingButtonWindow()
    private init() {}

    /// Side of the square window. The visible circle is inset inside it, so the
    /// touch target is comfortably larger than the artwork.
    private static let side: CGFloat = 74
    private static let margin: CGFloat = 8

    private var window: UIWindow?
    private var host: UIHostingController<QAFloatingButtonFace>?
    private var panner: QAFloatingPanHandler?

    /// Handed in by the SwiftUI mount, because `AppSession` has no singleton and
    /// a window sits outside the environment that would otherwise supply it.
    private weak var session: AppSession?

    // MARK: Lifecycle

    func attach(session: AppSession) {
        self.session = session
        syncFromGate()
    }

    /// The single decision point: should the button be on screen right now.
    /// Called after an unlock, from the mount's `onAppear`, and whenever the
    /// tester toggles it.
    func syncFromGate() {
        let wanted = QAAccessGate.shared.hasEverUnlocked
            && QAFloatingButtonSettings.isEnabled
        if wanted { show() } else { hide() }
    }

    private func show() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        let face = QAFloatingButtonFace(
            onTap: { [weak self] in self?.openMenu() },
            onHide: {
                QAFloatingButtonSettings.isEnabled = false
                QAFloatingButtonWindow.shared.syncFromGate()
            })
        let host = UIHostingController(rootView: face)
        host.view.backgroundColor = .clear

        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 0.5)
        w.backgroundColor = .clear
        w.rootViewController = host
        w.frame = CGRect(origin: restoredOrigin(in: scene),
                         size: CGSize(width: Self.side, height: Self.side))
        w.isHidden = false          // deliberately NOT makeKeyAndVisible()

        let panner = QAFloatingPanHandler(window: w) { [weak self] in self?.persistOrigin() }
        panner.install(on: host.view)

        self.window = w
        self.host = host
        self.panner = panner
    }

    private func hide() {
        guard let w = window else { return }
        window = nil
        host = nil
        panner = nil
        w.isHidden = true
        w.windowScene = nil
    }

    /// Re-clamp after a rotation or a split-view resize. Cheap enough to call
    /// unconditionally.
    func reclamp() {
        guard let w = window, let scene = w.windowScene else { return }
        w.frame.origin = Self.clamp(w.frame.origin, in: scene, side: Self.side)
        persistOrigin()
    }

    // MARK: Position

    private func restoredOrigin(in scene: UIWindowScene) -> CGPoint {
        let d = UserDefaults.standard
        let bounds = scene.screen.bounds
        // First run: bottom-right, above where a tab bar would be.
        guard d.object(forKey: QAFloatingButtonSettings.originXKey) != nil else {
            return CGPoint(x: bounds.width - Self.side - Self.margin,
                           y: max(Self.margin, bounds.height - Self.side - 140))
        }
        let p = CGPoint(x: d.double(forKey: QAFloatingButtonSettings.originXKey),
                        y: d.double(forKey: QAFloatingButtonSettings.originYKey))
        return Self.clamp(p, in: scene, side: Self.side)
    }

    fileprivate static func clamp(_ p: CGPoint, in scene: UIWindowScene, side: CGFloat) -> CGPoint {
        let b = scene.screen.bounds
        let maxX = max(margin, b.width  - side - margin)
        let maxY = max(margin, b.height - side - margin)
        return CGPoint(x: min(max(margin, p.x), maxX),
                       y: min(max(margin, p.y), maxY))
    }

    private func persistOrigin() {
        guard let w = window else { return }
        let d = UserDefaults.standard
        d.set(Double(w.frame.origin.x), forKey: QAFloatingButtonSettings.originXKey)
        d.set(Double(w.frame.origin.y), forKey: QAFloatingButtonSettings.originYKey)
    }

    // MARK: Opening the menu

    private func openMenu() {
        guard let session else { return }
        QAFloatingMenuPresenter.shared.present(session: session)
    }
}

// MARK: - Dragging

/// Pan handling in UIKit rather than a SwiftUI `DragGesture`, because what is
/// being moved is the *window*, and a gesture inside the window would be
/// reporting translations in a coordinate space that is itself moving.
///
/// The recognizer coexists with SwiftUI's button: a pan needs movement to
/// recognize, a tap does not, so a still finger taps and a moving finger drags.
@MainActor
private final class QAFloatingPanHandler: NSObject, UIGestureRecognizerDelegate {
    private weak var window: UIWindow?
    private let onSettled: () -> Void
    private var startOrigin: CGPoint = .zero

    init(window: UIWindow, onSettled: @escaping () -> Void) {
        self.window = window
        self.onSettled = onSettled
        super.init()
    }

    func install(on view: UIView) {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.delegate = self
        pan.cancelsTouchesInView = false
        view.addGestureRecognizer(pan)
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let w = window, let scene = w.windowScene else { return }
        let b = scene.screen.bounds
        let side = w.frame.width
        let margin: CGFloat = 8

        switch g.state {
        case .began:
            startOrigin = w.frame.origin
        case .changed:
            // Translation is measured against the recognizer's own view, which
            // is moving with the window — so it is applied to the origin
            // captured at `.began` rather than accumulated frame by frame.
            let t = g.translation(in: nil)
            w.frame.origin = CGPoint(
                x: min(max(margin, startOrigin.x + t.x), max(margin, b.width  - side - margin)),
                y: min(max(margin, startOrigin.y + t.y), max(margin, b.height - side - margin)))
        case .ended, .cancelled:
            // Snap to whichever vertical edge is nearer, so the button never
            // rests in the middle of content it is meant to stay out of the way
            // of. Vertical position is left where the tester put it.
            let targetX = w.frame.midX < b.width / 2
                ? margin
                : max(margin, b.width - side - margin)
            UIView.animate(withDuration: 0.22,
                           delay: 0,
                           usingSpringWithDamping: 0.8,
                           initialSpringVelocity: 0.4,
                           options: [.allowUserInteraction]) {
                w.frame.origin.x = targetX
            } completion: { _ in
                self.onSettled()
            }
        default:
            break
        }
    }

    // Never block SwiftUI's own tap handling inside the hosted button.
    nonisolated func gestureRecognizer(_ g: UIGestureRecognizer,
                                       shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// MARK: - The button itself

/// Pure appearance plus two callbacks. It owns no window state, which keeps the
/// SwiftUI layer free to redraw as the recorder's counts change without any
/// risk of it trying to re-lay-out the window it lives in.
struct QAFloatingButtonFace: View {
    let onTap: () -> Void
    let onHide: () -> Void

    @State private var recorder = QARecorder.shared
    @State private var tickets = QATicketStore.shared
    @State private var gate = QAAccessGate.shared

    private var openBlockers: Int {
        tickets.tickets.filter { $0.severity == .blocker && !$0.status.isClosed }.count
    }

    /// Blockers first, because a blocker is the number worth interrupting for;
    /// otherwise the count of things QA has noticed this session.
    private var badge: Int {
        openBlockers > 0 ? openBlockers : recorder.violationCount + recorder.failureCount
    }

    private var isHot: Bool { openBlockers > 0 || recorder.violationCount > 0 }

    var body: some View {
        Button(action: onTap) {
            ZStack {
                Circle()
                    .fill(isHot ? Color.red.opacity(0.94) : Color.stockedGold.opacity(0.94))
                    .shadow(color: .black.opacity(0.28), radius: 5, y: 2)
                VStack(spacing: 1) {
                    Image(systemName: gate.isUnlocked ? "checkmark.seal.fill" : "lock.fill")
                        .font(.system(size: 17, weight: .semibold))
                    Text(badge > 0 ? "\(min(badge, 99))" : "QA")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                }
                .foregroundStyle(isHot ? Color.white : Color.stockedBlack)
            }
            .frame(width: 54, height: 54)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(badge > 0 ? "Open QA, \(badge) open issues" : "Open QA")
        .accessibilityHint("Double tap to open the QA menu. Drag to move.")
        .contextMenu {
            Button {
                onTap()
            } label: { Label("Open QA menu", systemImage: "checklist") }
            Button(role: .destructive) {
                onHide()
            } label: { Label("Hide this button", systemImage: "eye.slash") }
        }
        // Centred inside the larger touch window, so the finger has room either
        // side of the artwork without the circle looking oversized.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - The menu's window

/// Same shape as `QAReporterPresenter`, one level lower. A full-screen
/// passthrough window that becomes key only while a sheet is up, presents the
/// QA hub, and tears itself down — handing key status back to the app — the
/// moment that sheet goes away.
@MainActor
final class QAFloatingMenuPresenter {
    static let shared = QAFloatingMenuPresenter()
    private init() {}

    private var window: UIWindow?

    var isPresenting: Bool { window != nil }

    func present(session: AppSession) {
        // Re-tapping the button while the menu is up should not stack a second
        // copy of it. `window != nil` is the single source of truth, exactly as
        // it is in the reporter.
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        let root = QAMenuPassthroughController()
        let w = UIWindow(windowScene: scene)
        w.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.alert.rawValue + 0.5)
        w.backgroundColor = .clear
        w.rootViewController = root
        w.isHidden = false
        w.makeKey()                 // the sheet has text fields in it
        window = w

        let host = UIHostingController(
            rootView: QAFloatingMenuRoot(onClose: { [weak self] in self?.dismiss() })
                .environment(session))
        host.modalPresentationStyle = .pageSheet
        // Detents on the *presentation controller*, not `.presentationDetents`.
        // The latter is a no-op for a sheet presented from UIKit rather than
        // from a SwiftUI `.sheet` — the trap Build 71 fell into.
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        root.onInteractiveDismiss = { [weak self] in self?.teardown() }
        host.presentationController?.delegate = root

        root.present(host, animated: true)
    }

    func dismiss() {
        guard let root = window?.rootViewController else { teardown(); return }
        root.dismiss(animated: true) { [weak self] in self?.teardown() }
    }

    private func teardown() {
        guard let w = window else { return }
        window = nil
        w.isHidden = true
        w.windowScene = nil
        // Hand key status back explicitly. Without this the app's own window is
        // not key and the next text field the tester taps raises no keyboard.
        QAScreenshot.appWindow()?.makeKey()
    }
}

/// A hole rather than a wall: the root view reports "not mine" for touches that
/// land on itself, so anything not covered by the presented sheet still reaches
/// the app underneath.
@MainActor
private final class QAMenuPassthroughController: UIViewController,
                                                 UIAdaptivePresentationControllerDelegate {
    var onInteractiveDismiss: (() -> Void)?

    override func loadView() {
        let v = QAMenuPassthroughView()
        v.backgroundColor = .clear
        view = v
    }

    nonisolated func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated { onInteractiveDismiss?() }
    }
}

private final class QAMenuPassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

// MARK: - What the menu shows

/// Re-uses the existing gate rather than duplicating it, so the ten-minute
/// window is the same window everywhere. If it has lapsed the tester types the
/// code once here and the button and Settings → QA are both open again.
/// (App Health no longer has a QA section — Build 74 gave QA one door.)
struct QAFloatingMenuRoot: View {
    let onClose: () -> Void

    var body: some View {
        // Build 74: the gate is `QAUnlockGate` rather than a second copy of the
        // passcode pane. This view supplies its own `NavigationStack` so it can
        // hang Done in the toolbar, which is precisely why the gate does not
        // supply one — nesting the two gave the QA screens two navigation bars.
        NavigationStack {
            QAUnlockGate(lockedMessage: "Enter the QA code to open the QA hub.") {
                QAModeView()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onClose)
                }
            }
        }
    }
}

// MARK: - Mount

/// Zero-size view mounted once in RootView. Its only jobs are to hand the window
/// controller an `AppSession` and to keep the button's visibility in step with
/// the gate.
struct QAFloatingButtonMount: View {
    @Environment(AppSession.self) private var session
    @State private var gate = QAAccessGate.shared

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear { QAFloatingButtonWindow.shared.attach(session: session) }
            .onChange(of: gate.hasEverUnlocked) { _, _ in
                QAFloatingButtonWindow.shared.syncFromGate()
            }
            .onReceive(NotificationCenter.default.publisher(
                for: UIDevice.orientationDidChangeNotification)) { _ in
                QAFloatingButtonWindow.shared.reclamp()
            }
    }
}
