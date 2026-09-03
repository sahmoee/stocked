// QAIssueReporter.swift
// ─────────────────────────────────────────────────────────────────────────────
// Short-press with two fingers while QA mode is on → describe what is wrong → a
// numbered, contextualised, synced ticket.
//
// HOW IT HOOKS IN
// Same trick as QATapTracker, and for the same reason: a transparent SwiftUI
// overlay cannot see touches it does not consume, because a view whose `hitTest`
// returns nil is not in the touch's responder chain at all. So the long-press
// recognizer goes on the UIWindow, where every touch in the app passes through
// on its way to whatever it actually lands on. `cancelsTouchesInView = false`
// and simultaneous recognition mean the app underneath behaves exactly as it
// always did — the report gesture is an observer, not an interceptor.
//
// GESTURE OWNERSHIP
// QA owns a two-finger short press. Home customization owns a one-finger long
// press, so reporting and wiggle mode cannot both fire.
//
// CAPTURE ORDER MATTERS
// The screenshot and the context are grabbed synchronously in the `.began`
// handler, before the sheet is even constructed. By the time a sheet has
// animated in, the screen underneath has often already changed — a spinner has
// stopped, a toast has faded, the thing you were reporting is gone. Capturing at
// gesture time means the evidence is of the moment the tester reacted, which is
// the whole point.
//
// WHY THE COMPOSER GETS ITS OWN WINDOW
// It used to be a plain SwiftUI `.sheet(item:)` hung off the zero-size view in
// RootView. That works only when nothing else is presented. The moment the
// tester was inside a sheet, a full-screen cover, a popover or an alert — which
// is to say, most of the moments worth reporting — the presentation was asked of
// a view controller that was already presenting something, and UIKit will not
// present twice from the same controller. The sheet came up underneath, or not
// at all.
//
// Chasing the top-most presented view controller would fix the common case and
// keep failing in the interesting ones: mid-transition controllers, alerts, and
// anything living in a window of its own. So the composer now gets a window of
// its own, above the alert level, torn down the moment it closes. It cannot be
// behind anything, because there is nothing in front of it to be behind.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import UIKit
// Build 73: the mockup attachment offers both sources deliberately. Designs
// arrive as files (exported from a tool, saved from a chat, dropped in iCloud)
// at least as often as they arrive in the photo library, and a picker that only
// understands one of those makes the tester screenshot their own mockup to get
// it in — losing a generation of quality to a missing menu item.
import PhotosUI
import UniformTypeIdentifiers

// MARK: - Mount point

/// Zero-size view mounted once in RootView. Installs the window recognizer while
/// QA mode is on. It no longer presents anything itself — see
/// `QAReporterPresenter` for why the composer lives in its own window.
struct QAIssueReporter: View {
    @State private var recorder = QARecorder.shared
    @AppStorage(QAIssueReporterSettings.enabledKey) private var reporterEnabled = true

    var body: some View {
        Group {
            if recorder.isEnabled && reporterEnabled {
                // Two fingers held briefly is deliberate enough not to collide
                // with scrolling, while still feeling like a short press.
                LongPressCatcher(fingerCount: 2) { screenshot, context in
                    QAReporterPresenter.shared.present(
                        QAReportDraft(screenshot: screenshot, context: context))
                }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
            }
        }
    }
}

/// Short-lived arbitration retained for any app surface that temporarily owns the
/// two-finger short press while QA recording is active.
@MainActor
final class QAReporterGestureArbiter {
    static let shared = QAReporterGestureArbiter()

    private var suppressedUntil = ContinuousClock.now

    private init() {}

    func suppress(for duration: Duration = .seconds(1)) {
        suppressedUntil = ContinuousClock.now.advanced(by: duration)
    }

    var isSuppressed: Bool { ContinuousClock.now < suppressedUntil }
}

// MARK: - Presentation

/// Owns the one window the composer is presented in.
///
/// The window sits at `.alert + 1`, which puts it above every modal the app can
/// present (they all live in the app's own window, whatever their style) and
/// above alerts, while staying below the remote keyboard window — so the text
/// fields in the composer still get a keyboard drawn over the top of them, which
/// is exactly what you want.
///
/// The window exists only while the composer is up. There is no permanently
/// installed extra window sitting in the app eating touches when QA is off, and
/// no state to get out of sync: `window == nil` is the single source of truth for
/// "is the composer showing", which is also what stops a double-fire of the
/// gesture from stacking two composers.
@MainActor
final class QAReporterPresenter {
    static let shared = QAReporterPresenter()
    private init() {}

    private var window: UIWindow?

    var isPresenting: Bool { window != nil }

    func present(_ draft: QAReportDraft) {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert + 1
        w.backgroundColor = .clear

        // The root controller is a hole. Its view refuses every touch that lands
        // on it, so while the composer is animating in or out the app underneath
        // is still fully usable. The composer and its dimming view are siblings
        // of this view under the window, not children of it, so they still
        // receive touches normally.
        let root = QAPassthroughController()
        w.rootViewController = root
        w.isHidden = false
        w.makeKey()
        window = w

        let host = UIHostingController(rootView: QAReportComposer(
            draft: draft,
            onClose: { [weak self] in self?.dismiss() }))
        host.modalPresentationStyle = .pageSheet
        // Configured here rather than with `.presentationDetents` in the SwiftUI
        // body: those modifiers describe a sheet SwiftUI is presenting, and this
        // one is presented by UIKit.
        if let sheet = host.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
            sheet.prefersScrollingExpandsWhenScrolledToEdge = true
        }
        // If the tester swipes the composer away instead of using the buttons,
        // the window still has to go. UIKit tells the presentation controller,
        // not us, so the controller forwards it.
        host.presentationController?.delegate = root
        root.onInteractiveDismiss = { [weak self] in self?.teardown() }

        root.present(host, animated: true)
    }

    /// Programmatic close — the Cancel and Done buttons.
    func dismiss() {
        guard let w = window else { return }
        w.rootViewController?.dismiss(animated: true) { [weak self] in
            self?.teardown()
        }
    }

    /// Drop the window. Safe to call twice; the second call is a no-op.
    private func teardown() {
        guard let w = window else { return }
        window = nil
        w.isHidden = true
        w.windowScene = nil
        // Hand key status back so the app's own text fields keep working.
        QAScreenshot.appWindow()?.makeKey()
    }
}

/// Root of the reporter window: invisible, and transparent to touches.
private final class QAPassthroughController: UIViewController, UIAdaptivePresentationControllerDelegate {
    var onInteractiveDismiss: (() -> Void)?

    override func loadView() {
        view = QAPassthroughView()
        view.backgroundColor = .clear
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        onInteractiveDismiss?()
    }
}

private final class QAPassthroughView: UIView {
    /// Returning nil for hits on itself makes the whole window transparent to
    /// touches; `super.hitTest` still returns real subviews if any are ever
    /// added, so this is a hole rather than a wall.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// Identifiable box so `.sheet(item:)` can carry the captured evidence.
struct QAReportDraft: Identifiable {
    let id = UUID()
    let screenshot: UIImage?
    let context: QATicketContext
}

// MARK: - Window gesture

private struct LongPressCatcher: UIViewRepresentable {
    let fingerCount: Int
    let onFire: (UIImage?, QATicketContext) -> Void

    func makeUIView(context: Context) -> UIView {
        let v = WindowPressObserver()
        v.coordinator = context.coordinator
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onFire = onFire
        context.coordinator.refreshFingerCount(fingerCount)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(fingerCount: fingerCount, onFire: onFire)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onFire: (UIImage?, QATicketContext) -> Void
        private weak var window: UIWindow?
        private var recognizer: UILongPressGestureRecognizer?
        private var configuredFingerCount: Int

        init(fingerCount: Int, onFire: @escaping (UIImage?, QATicketContext) -> Void) {
            self.configuredFingerCount = Self.sanitized(fingerCount)
            self.onFire = onFire
        }

        func attach(to window: UIWindow) {
            guard self.window !== window else { return }
            detach()

            let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
            // QA is a two-finger short press; the one-finger fallback remains a
            // true long press for compatibility with isolated previews/tests.
            press.minimumPressDuration = configuredFingerCount == 2 ? 0.18 : 0.65
            press.numberOfTouchesRequired = configuredFingerCount
            // Allow a generous wobble — testers are usually holding the phone in
            // one hand and pointing at the bug with the other.
            press.allowableMovement = 24
            press.cancelsTouchesInView = false
            press.delaysTouchesBegan = false
            press.delaysTouchesEnded = false
            press.requiresExclusiveTouchType = false
            press.delegate = self
            window.addGestureRecognizer(press)

            self.window = window
            self.recognizer = press
        }

        func refreshFingerCount(_ value: Int) {
            configuredFingerCount = Self.sanitized(value)
            recognizer?.numberOfTouchesRequired = configuredFingerCount
            recognizer?.minimumPressDuration = configuredFingerCount == 2 ? 0.18 : 0.65
        }

        static func sanitized(_ value: Int) -> Int { value == 2 ? 2 : 1 }

        func detach() {
            if let r = recognizer { window?.removeGestureRecognizer(r) }
            recognizer = nil
            window = nil
        }

        @objc func pressed(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began else { return }
            MainActor.assumeIsolated {
                guard QARecorder.shared.isEnabled else { return }
                guard !QAReporterGestureArbiter.shared.isSuppressed else { return }
                // Already composing — a long press inside the composer is just a
                // long press. Bail before the haptic so it does not feel like the
                // gesture was swallowed.
                guard !QAReporterPresenter.shared.isPresenting else { return }

                // Confirm by feel before anything visual happens, so the tester
                // knows the gesture landed even if the sheet takes a beat.
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()

                // Order is deliberate: snapshot first (the screen is still exactly
                // what they were looking at), then context, then hand off.
                // No window argument: capture composites every visible window, so
                // an alert or a sheet over the app is in the picture too.
                let shot = QAScreenshot.capture()
                let context = QAContextCapture.current()
                QARecorder.shared.crumb("two-finger report on \(context.screen)")
                onFire(shot, context)
            }
        }

        // Coexist with everything. A context menu, a drag, a scroll and this can
        // all recognize from the same touch; none of them are blocked.
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldRequireFailureOf other: UIGestureRecognizer) -> Bool { false }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool { false }
        func gestureRecognizer(_ g: UIGestureRecognizer,
                               shouldReceive touch: UITouch) -> Bool { true }
    }
}

private final class WindowPressObserver: UIView {
    weak var coordinator: LongPressCatcher.Coordinator?
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window { coordinator?.attach(to: window) }
        else { coordinator?.detach() }
    }
}

// MARK: - Settings

nonisolated enum QAIssueReporterSettings {
    static let fingerKey = "qa.reporter.fingers"
    static let enabledKey = "qa.reporter.enabled"
}

// MARK: - Screenshot

@MainActor
enum QAScreenshot {
    /// `drawHierarchy(afterScreenUpdates: false)` is the fast path — it renders
    /// what is already on screen rather than forcing a layout pass, which is both
    /// quicker and more truthful for a bug report. `afterScreenUpdates: true`
    /// would give the tester a picture of the app *after* it recovered from the
    /// thing they are reporting.
    ///
    /// Every visible window in the scene is composited, back to front, not just
    /// the key one. Sheets and alerts live in the app's own window so one window
    /// would usually be enough — but not always, and a bug report with the alert
    /// missing from the picture is a bug report about nothing.
    ///
    /// TOUCH ANNOTATION (Build 73)
    /// The last few seconds of touch-downs are drawn on top, numbered in order
    /// and joined by a dashed line, so the picture says which controls were
    /// pressed to reach this state rather than only what the state looks like.
    /// The live ring overlay deliberately does *not* contribute here — it sits
    /// above the `windowLevel <= .alert` cut `visibleWindows()` makes, so a
    /// touch appears exactly once in the image whether or not the overlay is
    /// switched on. See QATouchTrail.swift.
    static func capture(window: UIWindow? = nil, annotateTouches: Bool? = nil) -> UIImage? {
        let targets: [UIWindow]
        if let window {
            targets = [window]
        } else {
            targets = visibleWindows()
        }
        guard let first = targets.first else { return nil }
        let bounds = first.bounds
        guard bounds.width > 0, bounds.height > 0 else { return nil }

        let annotate = annotateTouches ?? QATouchTrailSettings.annotateShots
        let touches = annotate ? QATouchTrail.shared.annotationPoints() : []

        // Build 84 (STK-77-0003/-0004/-0006) — render at 1×, not the screen's
        // native 3×. `drawHierarchy` rasterises every visible window, materials
        // and all, and at 3× on a Pro-sized screen that is a multi-second
        // main-thread stall: the long press that files a freeze report was
        // itself the freeze. The stored copy has always been downscaled to
        // ~900 px (QATicketStore.saveScreenshot), so the extra pixels bought
        // nothing but the stall. Touch annotation draws in points — unaffected.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        return renderer.image { _ in
            for w in targets {
                w.drawHierarchy(in: w.bounds, afterScreenUpdates: false)
            }
            // Drawn after the composite, so the rings sit over the UI rather
            // than under whichever window happens to be last.
            if !touches.isEmpty {
                QATouchTrailRenderer.drawAnnotation(touches)
            }
        }
    }

    /// Visible windows of the foreground scene, back to front, excluding the
    /// reporter's own window (which is never up at capture time anyway, but a
    /// screenshot of the thing you are typing into would be a poor souvenir).
    static func visibleWindows() -> [UIWindow] {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return [] }
        return scene.windows
            .filter { !$0.isHidden && $0.alpha > 0.01 && $0.windowLevel <= .alert }
            .sorted { $0.windowLevel < $1.windowLevel }
    }

    /// The app's own window — the one the recognizer is attached to and the one
    /// key status is handed back to when the reporter window goes away.
    static func appWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.windowLevel == .normal && !$0.isHidden }
    }

    static func activeWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?
            .windows.first { $0.isKeyWindow }
    }
}

// MARK: - Composer

/// The sheet. One text field, four severity buttons, and a preview of everything
/// that was attached for you. Deliberately short: a form long enough to be a
/// chore is a form people stop filling in by the third bug.
struct QAReportComposer: View {
    let draft: QAReportDraft
    /// Explicit rather than `@Environment(\.dismiss)`. This view is the root of a
    /// `UIHostingController` that UIKit presented, and the environment's dismiss
    /// action only reliably unwinds presentations SwiftUI itself made. The
    /// presenter owns the window, so the presenter closes it.
    let onClose: () -> Void

    @State private var title = ""
    @State private var body_ = ""
    @State private var severity: QATicketSeverity = .major
    @State private var requiresManualReview = false
    @State private var attachScreenshot = true
    @State private var created: QATicket?
    @State private var identity = QAIdentityStore.shared
    private var reportContext: QATicketContext {
        var context = draft.context
        context.identity = (context.identity ?? identity.capture()).assigning(identity.tester)
        return context
    }
    @FocusState private var titleFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let created {
                    filedView(created)
                } else {
                    form
                }
            }
            .navigationTitle(created == nil ? "Report an issue" : "Filed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(created == nil ? "Cancel" : "Done") { onClose() }
                }
                if created == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("File") { file() }
                            .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                            .fontWeight(.semibold)
                    }
                }
            }
        }
        // Detents and the grabber are set on the UIKit sheet presentation
        // controller in QAReporterPresenter — the SwiftUI modifiers only apply to
        // sheets SwiftUI presented, and this one is presented by UIKit.
    }

    // MARK: Form

    private var form: some View {
        Form {
            Section("Tester") {
                Picker("Reported by", selection: $identity.tester) {
                    ForEach(QATester.allCases) { tester in Text(tester.name).tag(tester) }
                }
                Text(reportContext.identity?.deviceLabel ?? "Unknown device").font(.stocked(.caption))
            }
            Section {
                TextField("What went wrong?", text: $title, axis: .vertical)
                    .fixedSize(horizontal: false, vertical: true)
                    .focused($titleFocused)
                    .submitLabel(.next)
                TextField("More detail — what you expected, what happened (optional)",
                          text: $body_, axis: .vertical)
                    .lineLimit(3...)
            } header: {
                Text("Describe it")
            } footer: {
                Text("One sentence is enough. Everything technical is attached below automatically.")
            }

            Section("How bad") {
                Picker("Severity", selection: $severity) {
                    ForEach(QATicketSeverity.allCases) { s in
                        Label(s.title, systemImage: s.symbol).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                Text(severityHint)
                    .font(.stocked(.caption))
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Requires manual review", isOn: $requiresManualReview)
            } header: {
                Text("Review")
            } footer: {
                Text("Use this when the wording, visual intent, or expected behavior needs a person to interpret it. AI agents must ask for specifics instead of guessing.")
            }

            if let shot = draft.screenshot {
                Section("Screenshot") {
                    Toggle("Attach screenshot", isOn: $attachScreenshot)
                    if attachScreenshot {
                        Image(uiImage: shot)
                            .resizable()
                            .scaledToFit()
                            .frame(maxHeight: 220)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(RoundedRectangle(cornerRadius: 10)
                                .stroke(.quaternary))
                            .padding(.vertical, 4)
                    }
                }
            }

            Section {
                ForEach(reportContext.summaryLines, id: \.self) { line in
                    Text(line)
                        .font(.stocked(.caption).monospaced())
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Captured automatically")
            } footer: {
                Text("Attached with the ticket: the last \(draft.context.breadcrumbs.count) steps you took, \(draft.context.runningProcesses.count) process\(draft.context.runningProcesses.count == 1 ? "" : "es") in flight, \(draft.context.recentFailures.count) recent failure\(draft.context.recentFailures.count == 1 ? "" : "s"), and \(draft.context.openViolations.count) violated invariant\(draft.context.openViolations.count == 1 ? "" : "s").")
            }

            if !draft.context.breadcrumbs.isEmpty {
                Section("Steps before this") {
                    ForEach(draft.context.breadcrumbs.suffix(12).reversed(), id: \.self) { c in
                        Text(c).font(.stocked(.caption).monospaced())
                    }
                }
            }
        }
    }

    private var severityHint: String {
        switch severity {
        case .blocker: return "Stops the release. Data loss, a crash, a freeze, or a wrong answer about allergens."
        case .major:   return "A feature does not work, but there is a way around it."
        case .minor:   return "Wrong, but small — layout, wording, a cosmetic mismatch."
        case .note:    return "Not a bug. An observation worth keeping with the session."
        }
    }

    // MARK: Filed confirmation

    private func filedView(_ ticket: QATicket) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .scaledFont(48)
                    .foregroundStyle(.green)
                    .padding(.top, 24)

                Text(ticket.number)
                    .font(.stocked(.title2).monospaced().bold())
                    .textSelection(.enabled)

                Text(ticket.title)
                    .font(.stocked(.headline))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                VStack(spacing: 6) {
                    Label(ticket.severity.title, systemImage: ticket.severity.symbol)
                    Text("on \(ticket.context.screen)")
                    Text(QATicketStore.shared.lastSyncOutcome)
                        .foregroundStyle(.secondary)
                }
                .font(.stocked(.subheadline))
                .foregroundStyle(.secondary)

                Button {
                    UIPasteboard.general.string = ticket.exportText
                } label: {
                    Label("Copy the whole ticket", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)

                Text("It is in the event log, the process log, and the QA report. It will sync with the next publish if it has not already.")
                    .font(.stocked(.caption))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 28)
                    .padding(.bottom, 24)
            }
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: Filing

    private func file() {
        let ticket = QATicketStore.shared.open(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            body: body_.trimmingCharacters(in: .whitespacesAndNewlines),
            severity: severity,
            requiresManualReview: requiresManualReview,
            context: reportContext,
            origin: .tester,
            screenshot: attachScreenshot ? draft.screenshot : nil)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { created = ticket }
    }
}

// MARK: - Ticket list

struct QATicketListView: View {
    @State private var store = QATicketStore.shared
    @State private var search = ""
    @State private var statusFilter: QATicketStatus?
    @State private var severityFilter: QATicketSeverity?
    @State private var showClearConfirm = false
    @State private var showCompleted = false
    @State private var testerFilter = "all"
    @State private var familyFilter = "all"

    private var visible: [QATicket] {
        store.sorted(status: statusFilter, severity: severityFilter, search: search).filter {
            (showCompleted || $0.needsAttention)
                && (testerFilter == "all" || ($0.context.identity?.testerID ?? "unassigned") == testerFilter)
                && (familyFilter == "all" || ($0.context.identity?.deviceFamily ?? QADeviceModels.family(identifier: $0.context.device, fallback: "Unknown")) == familyFilter)
        }
    }

    var body: some View {
        List {
            Section {
                Toggle("Include completed tickets", isOn: $showCompleted)
                Picker("Tester", selection: $testerFilter) {
                    Text("All testers").tag("all")
                    ForEach(QATester.allCases) { Text($0.name).tag($0.rawValue) }
                }
                Picker("Device type", selection: $familyFilter) {
                    Text("All devices").tag("all")
                    Text("iPhone").tag("iPhone"); Text("iPad").tag("iPad"); Text("Unknown / legacy").tag("Unknown")
                }
            }
            if store.tickets.isEmpty {
                ContentUnavailableView {
                    Label("No tickets yet", systemImage: "ticket")
                } description: {
                    Text("Short-press with two fingers anywhere, or shake the device, while QA mode is on to file one. The screen, your last steps, what was running, and a screenshot are attached for you.")
                }
            } else {
                if !store.hotspots.isEmpty {
                    Section("Hotspots") {
                        ForEach(store.hotspots) { h in
                            Label("\(h.count) open on \(h.screen)", systemImage: "scope")
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section {
                    if visible.isEmpty {
                        Text("No active tickets match. Turn on Include completed tickets to see resolved history.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(visible) { t in
                        NavigationLink { QATicketDetailView(ticketID: t.id) } label: {
                            row(t)
                        }
                    }
                    .onDelete { idx in
                        for i in idx { store.delete(visible[i].id) }
                    }
                } header: {
                    Text("\(visible.count) of \(store.tickets.count)")
                } footer: {
                    Text(store.lastSyncOutcome)
                }

                Section {
                    Button {
                        Task { await store.publishUnsynced() }
                    } label: {
                        Label("Sync \(store.unsynced.count) unsynced", systemImage: "arrow.up.circle")
                    }
                    .disabled(store.unsynced.isEmpty || store.isSyncing)

                    Button {
                        UIPasteboard.general.string = store.exportText
                    } label: {
                        Label("Copy all tickets", systemImage: "doc.on.doc")
                    }

                    Button(role: .destructive) { showClearConfirm = true } label: {
                        Label("Delete all tickets", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Tickets")
        .searchable(text: $search, prompt: "Ticket, tester, model, or screen")
        .onChange(of: statusFilter) { _, status in
            if status?.isClosed == true { showCompleted = true }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Status", selection: $statusFilter) {
                        Text("Any status").tag(QATicketStatus?.none)
                        ForEach(QATicketStatus.allCases) { s in
                            Label(s.title, systemImage: s.symbol).tag(QATicketStatus?.some(s))
                        }
                    }
                    Picker("Severity", selection: $severityFilter) {
                        Text("Any severity").tag(QATicketSeverity?.none)
                        ForEach(QATicketSeverity.allCases) { s in
                            Label(s.title, systemImage: s.symbol).tag(QATicketSeverity?.some(s))
                        }
                    }
                } label: {
                    Image(systemName: statusFilter == nil && severityFilter == nil
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
            }
        }
        .confirmationDialog("Delete every ticket?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Delete \(store.tickets.count) tickets", role: .destructive) { store.clear() }
        } message: {
            Text("Screenshots go too. Anything already synced stays on the bridge.")
        }
    }

    private func row(_ t: QATicket) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: t.severity.symbol)
                    .foregroundStyle(tint(t.severity))
                Text(t.number)
                    .font(.stocked(.caption).monospaced().bold())
                    .foregroundStyle(.secondary)
                Spacer()
                if !t.isSynced {
                    // `arrow.up.circle.badge.clock` was a guess and does not
                    // exist. An unknown SF Symbol does not fail the build — it
                    // renders as nothing — so this row silently lost its
                    // "not pushed yet" marker. Build 72 replaced the same guess
                    // in QATriage and AppChangelog and missed this one.
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(.secondary)
                        .font(.stocked(.caption))
                }
                Image(systemName: t.status.symbol)
                    .foregroundStyle(!t.needsAttention ? .green : .secondary)
                    .font(.stocked(.caption))
            }
            Text(t.title)
                .font(.stocked(.subheadline))
                .fixedSize(horizontal: false, vertical: true)
                .strikethrough(!t.needsAttention)
            Text(t.context.identity?.label ?? "Unassigned tester · \(t.context.device)")
                .font(.stocked(.caption)).foregroundStyle(.secondary)
            Text(t.statusLabel).font(.stocked(.caption))
            if t.requiresManualReview == true {
                Label("Requires manual review", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.stocked(.caption2))
                    .foregroundStyle(.orange)
            }
            Text("\(t.context.screen) · \(t.createdAt.formatted(date: .omitted, time: .shortened))")
                .font(.stocked(.caption2))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    private func tint(_ s: QATicketSeverity) -> Color {
        switch s {
        case .blocker: return .red
        case .major:   return .orange
        case .minor:   return .yellow
        case .note:    return .secondary
        }
    }
}

// MARK: - Ticket detail

struct QATicketDetailView: View {
    let ticketID: UUID
    @State private var store = QATicketStore.shared
    @State private var sync = QASyncCoordinator.shared

    // Build 73
    @State private var editing = false
    @State private var photoItem: PhotosPickerItem?
    @State private var showingPhotos = false
    @State private var importingFile = false
    @State private var mockupNote = ""
    @State private var copied: String?
    @State private var resolutionDraft = ""

    private var ticket: QATicket? { store.tickets.first { $0.id == ticketID } }

    var body: some View {
        Group {
            if let t = ticket {
                List {
                    Section {
                        Text(t.title).font(.stocked(.headline))
                        if !t.body.isEmpty { Text(t.body).font(.stocked(.subheadline)) }
                        if t.wasEdited {
                            Label("Edited \(t.editCount ?? 1)× · last \(t.editedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")",
                                  systemImage: "pencil.line")
                                .font(.stocked(.caption))
                                .foregroundStyle(.secondary)
                        }
                    } header: {
                        Text(t.number).font(.stocked(.caption).monospaced())
                    }

                    Section("Triage") {
                        Picker("Tester", selection: Binding(
                            get: { QATester(rawValue: t.context.identity?.testerID ?? "") ?? .unassigned },
                            set: { store.assignTester(t.id, tester: $0) })) {
                            ForEach(QATester.allCases) { Text($0.name).tag($0) }
                        }
                        Text(t.context.identity?.deviceLabel ?? "\(t.context.device) · exact model not recorded")
                            .font(.stocked(.caption))
                        Toggle("Requires manual review", isOn: Binding(
                            get: { t.requiresManualReview ?? false },
                            set: { new in store.update(t.id) { $0.requiresManualReview = new } }))
                        Picker("Status", selection: Binding(
                            get: { t.status },
                            set: { store.setStatus(t.id, $0) })) {
                            ForEach(QATicketStatus.allCases) { s in
                                Label(s.title, systemImage: s.symbol).tag(s)
                            }
                        }
                        Picker("Severity", selection: Binding(
                            get: { t.severity },
                            set: { new in store.update(t.id) { $0.severity = new } })) {
                            ForEach(QATicketSeverity.allCases) { s in
                                Label(s.title, systemImage: s.symbol).tag(s)
                            }
                        }
                    }

                    Section("Fix verification") {
                        if let resolution = t.resolution, !resolution.isEmpty {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("What was fixed").font(.stocked(.caption).weight(.semibold)).foregroundStyle(.secondary)
                                Text(resolution)
                            }
                        }
                        if t.status == .fixed {
                            Button("Verify Fix") { store.verifyFix(t.id) }
                            Button("Refile — still broken", role: .destructive) { store.refile(t.id) }
                        } else if t.status != .verified {
                            TextField("What was fixed", text: $resolutionDraft, axis: .vertical)
                                .lineLimit(2...)
                            Button(t.requiresManualReview == true ? "Mark Fixed — review needed" : "Mark Fixed — complete ticket") {
                                store.markFixed(t.id, resolution: resolutionDraft)
                                resolutionDraft = ""
                            }
                            .disabled(resolutionDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        if let verifiedAt = t.verifiedAt {
                            Label("Verified \(verifiedAt.formatted(date: .abbreviated, time: .shortened))",
                                  systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                        }
                    }

                    if let shot = store.screenshot(for: t) {
                        Section {
                            Image(uiImage: shot)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } header: {
                            Text("Screenshot")
                        } footer: {
                            if t.context.touchTrail != nil {
                                Text("Numbered rings mark where the tester tapped in the seconds before the report.")
                            }
                        }
                    }

                    mockupSection(t)
                    handoffSection(t)

                    Section("Environment") {
                        ForEach(t.context.summaryLines, id: \.self) { l in
                            Text(l).font(.stocked(.caption).monospaced())
                        }
                    }

                    if !t.context.breadcrumbs.isEmpty {
                        Section("Steps before the report") {
                            ForEach(t.context.breadcrumbs.reversed(), id: \.self) { c in
                                Text(c).font(.stocked(.caption).monospaced())
                            }
                        }
                    }
                    if !t.context.stalledProcesses.isEmpty {
                        Section("Stalled at the time") {
                            ForEach(t.context.stalledProcesses, id: \.self) { p in
                                Text(p).font(.stocked(.caption).monospaced()).foregroundStyle(.orange)
                            }
                        }
                    }
                    if !t.context.runningProcesses.isEmpty {
                        Section("In flight at the time") {
                            ForEach(t.context.runningProcesses, id: \.self) { p in
                                Text(p).font(.stocked(.caption).monospaced())
                            }
                        }
                    }
                    if !t.context.recentFailures.isEmpty {
                        Section("Recent failures") {
                            ForEach(t.context.recentFailures, id: \.self) { f in
                                Text(f).font(.stocked(.caption).monospaced()).foregroundStyle(.red)
                            }
                        }
                    }
                    if !t.context.openViolations.isEmpty {
                        Section("Invariants violating") {
                            ForEach(t.context.openViolations, id: \.self) { v in
                                Text(v).font(.stocked(.caption).monospaced()).foregroundStyle(.red)
                            }
                        }
                    }

                    Section {
                        Button {
                            UIPasteboard.general.string = t.exportText
                            flash("Ticket copied")
                        } label: {
                            Label("Copy ticket", systemImage: "doc.on.doc")
                        }
                        Button {
                            Task { await sync.syncEverywhere(t.id) }
                        } label: {
                            Label(t.isSynced ? "Re-send everywhere" : "Send everywhere",
                                  systemImage: "arrow.up.circle")
                        }
                        .disabled(sync.isRunning || store.isSyncing)

                        if sync.isRunning {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Sending…").font(.stocked(.caption)).foregroundStyle(.secondary)
                            }
                        }
                        ForEach(sync.lastDetail, id: \.self) { line in
                            Text(line).font(.stocked(.caption).monospaced()).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Sync")
                    } footer: {
                        // `destinationLine` rather than a single "synced" flag:
                        // three destinations fail independently, and a tester
                        // who can see *which* one is missing knows whether to
                        // find signal, sign in to iCloud, or ignore it.
                        VStack(alignment: .leading, spacing: 4) {
                            Text(t.destinationLine)
                            if !t.syncError.isEmpty, !t.isSynced {
                                Text("Worker: \(t.syncError)").foregroundStyle(.red)
                            }
                            if !sync.folderLocation.isEmpty {
                                Text("Folder: \(sync.folderLocation)")
                            }
                        }
                    }
                }
                .navigationTitle(t.number)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { editing = true } label: {
                            Label("Edit", systemImage: "square.and.pencil")
                        }
                    }
                }
                .sheet(isPresented: $editing) {
                    QATicketEditSheet(ticketID: t.id)
                }
                .photosPicker(isPresented: $showingPhotos,
                              selection: $photoItem,
                              matching: .images)
                .fileImporter(isPresented: $importingFile,
                              allowedContentTypes: [.image],
                              allowsMultipleSelection: false) { result in
                    handleFileImport(result, for: t.id)
                }
                .onChange(of: photoItem) { _, item in
                    guard let item else { return }
                    Task { await handlePhotoPick(item, for: t.id) }
                }
                .overlay(alignment: .bottom) {
                    if let copied {
                        Text(copied)
                            .font(.stocked(.caption).bold())
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 24)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: copied)
                .task { await sync.refreshFolderLocation() }
            } else {
                ContentUnavailableView("Ticket deleted", systemImage: "trash")
            }
        }
    }

    // MARK: - Mockup

    @ViewBuilder
    private func mockupSection(_ t: QATicket) -> some View {
        Section {
            if let m = store.mockup(for: t) {
                Image(uiImage: m)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                Button(role: .destructive) {
                    store.removeMockup(from: t.id)
                    mockupNote = ""
                } label: {
                    Label("Remove mockup", systemImage: "trash")
                }
            }
            Button {
                importingFile = true
            } label: {
                Label(t.hasMockup ? "Replace from Files" : "Add mockup from Files",
                      systemImage: "folder")
            }
            Button {
                showingPhotos = true
            } label: {
                Label(t.hasMockup ? "Replace from Photos" : "Add mockup from Photos",
                      systemImage: "photo.on.rectangle")
            }
            if !mockupNote.isEmpty {
                Text(mockupNote).font(.stocked(.caption)).foregroundStyle(.secondary)
            }
        } header: {
            Text("Mockup — what it should look like")
        } footer: {
            Text(t.hasMockup
                 ? "Attaching a mockup clears the sync stamps, so the next send carries the picture to every destination."
                 : "A picture of the intended design. Adding one turns the two blocks below into a ready-to-paste handoff.")
        }
    }

    private func handlePhotoPick(_ item: PhotosPickerItem, for id: UUID) async {
        defer { photoItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            mockupNote = "That photo could not be read."
            return
        }
        mockupNote = store.attachMockup(image, to: id)
            ? "Mockup attached."
            : "The mockup could not be saved."
    }

    private func handleFileImport(_ result: Result<[URL], Error>, for id: UUID) {
        switch result {
        case .failure(let error):
            mockupNote = error.localizedDescription
        case .success(let urls):
            guard let url = urls.first else { return }
            // A file chosen from the Files app lives outside the sandbox and is
            // only readable inside a security scope. Without this pair the read
            // fails silently on iCloud Drive and works on local files, which is
            // the worst kind of bug to have in a bug reporter.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            guard let data = try? Data(contentsOf: url), let image = UIImage(data: data) else {
                mockupNote = "That file could not be read as an image."
                return
            }
            mockupNote = store.attachMockup(image, to: id)
                ? "Mockup attached from \(url.lastPathComponent)."
                : "The mockup could not be saved."
        }
    }

    // MARK: - Handoff blocks

    @ViewBuilder
    private func handoffSection(_ t: QATicket) -> some View {
        Section {
            Button {
                UIPasteboard.general.string = store.chatGPTPrompt(for: t)
                flash("Prompt copied")
            } label: {
                Label("Copy ChatGPT mockup prompt", systemImage: "wand.and.stars")
            }
            ShareLink(item: store.chatGPTPrompt(for: t)) {
                Label("Share prompt", systemImage: "square.and.arrow.up")
            }
            Button {
                UIPasteboard.general.string = store.claudeHandback(for: t)
                flash("Handback copied")
            } label: {
                Label("Copy build brief for Claude", systemImage: "hammer")
            }
            ShareLink(item: store.claudeHandback(for: t)) {
                Label("Share build brief", systemImage: "square.and.arrow.up")
            }
        } header: {
            Text("Handoff")
        } footer: {
            Text("Both blocks are also written into the ticket's folder as Markdown on every send, so they arrive on the Mac beside the screenshot without anyone copying anything.")
        }
    }

    private func flash(_ message: String) {
        copied = message
        Task {
            try? await Task.sleep(for: .seconds(1.6))
            if copied == message { copied = nil }
        }
    }
}

// MARK: - Edit sheet

/// Rewrite a filed ticket.
///
/// Severity is editable here as well as in Triage on purpose: the moment a
/// tester understands the bug well enough to rewrite the description is usually
/// the same moment they realise it is worse (or far less bad) than they first
/// typed, and making them close the sheet to act on that is how severities stay
/// wrong.
struct QATicketEditSheet: View {
    let ticketID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var store = QATicketStore.shared

    @State private var title = ""
    @State private var body_ = ""
    @State private var severity: QATicketSeverity = .major
    @State private var requiresManualReview = false
    @State private var keepHistory = true
    @State private var loaded = false

    private var ticket: QATicket? { store.tickets.first { $0.id == ticketID } }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("What is wrong", text: $title, axis: .vertical)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Section("Details") {
                    TextField("Steps, what you expected, what happened",
                              text: $body_, axis: .vertical)
                        .lineLimit(4...)
                }
                Section {
                    Picker("Severity", selection: $severity) {
                        ForEach(QATicketSeverity.allCases) { s in
                            Label(s.title, systemImage: s.symbol).tag(s)
                        }
                    }
                    Toggle("Requires manual review", isOn: $requiresManualReview)
                    Toggle("Keep the original wording", isOn: $keepHistory)
                } footer: {
                    Text(keepHistory
                         ? "The previous text is appended to the bottom of the report. What you first thought is often the part that says where to look."
                         : "The previous text is discarded. Only turn this off for a typo.")
                }
                Section {
                    Text("Saving clears every sync stamp, so this ticket re-sends to the worker, the folder and cPanel with the new wording.")
                        .font(.stocked(.caption))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle(ticket?.number ?? "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task {
                // Guarded: `.task` re-runs on some navigation transitions, and
                // reloading would throw away whatever the tester had typed.
                guard !loaded, let t = ticket else { return }
                loaded = true
                title = t.title
                body_ = t.body
                severity = t.severity
                requiresManualReview = t.requiresManualReview ?? false
            }
        }
    }

    private func save() {
        store.edit(ticketID, title: title, body: body_,
                   severity: severity, requiresManualReview: requiresManualReview,
                   keepHistory: keepHistory)
        let id = ticketID
        Task { await QASyncCoordinator.shared.syncEverywhere(id) }
        dismiss()
    }
}
