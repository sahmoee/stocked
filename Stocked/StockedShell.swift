// StockedShell.swift — Universal page wrapper (post-login).
// Header: centered "Stocked." + chevron.down, tappable → Daily Brief.
import SwiftUI

/// Shared hub greeting: live Preferences name and identical adaptive typography.
struct StockedGreeting: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        Text("\(StockedFormatters.timeOfDayGreeting), \(session.effectiveName)")
            .font(.stocked(.headline).weight(.semibold))
            .foregroundStyle(session.accentColor)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct StockedShell<Content: View>: View {
    var showBack:       Bool
    var scrollDisabled: Bool
    var titleText:      String               // #246 — per-tab wordmark ("Cook", "Inventory", …)
    var onTitleTap:     (() -> Void)?
    var trailingIcon:   String?          // optional top-right action (e.g. search) (#7)
    var trailingLabel:  String           // VoiceOver label for the trailing action
    var onTrailing:     (() -> Void)?
    var trailingIcon2:  String?              // #245 — optional second top-right action
    var trailingLabel2: String
    var onTrailing2:    (() -> Void)?
    var onRefresh:      (() async -> Void)?  // custom pull-to-refresh; nil = standard app refresh
    var content:        Content
    var canvasColor: Color?
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.stockedDismiss) private var stockedDismiss
    @Environment(\.stockedTitleTap) private var titleTap
    @Environment(\.stockedLayout) private var layoutMetrics
    @Environment(\.stockedMotion) private var motion
    @State private var scrollActivity = StockedScrollActivity.idle

    init(
        showBack:       Bool = false,
        scrollDisabled: Bool = false,
        titleText:      String = "Stocked",
        onTitleTap:     (() -> Void)? = nil,
        trailingIcon:   String? = nil,
        trailingLabel:  String = "",
        onTrailing:     (() -> Void)? = nil,
        trailingIcon2:  String? = nil,
        trailingLabel2: String = "",
        onTrailing2:    (() -> Void)? = nil,
        onRefresh:      (() async -> Void)? = nil,
        canvasColor: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.showBack       = showBack
        self.scrollDisabled = scrollDisabled
        self.titleText      = titleText
        self.onTitleTap     = onTitleTap
        self.trailingIcon   = trailingIcon
        self.trailingLabel  = trailingLabel
        self.onTrailing     = onTrailing
        self.trailingIcon2  = trailingIcon2
        self.trailingLabel2 = trailingLabel2
        self.onTrailing2    = onTrailing2
        self.onRefresh      = onRefresh
        self.content        = content()
        self.canvasColor    = canvasColor
    }

    var body: some View {
        ZStack(alignment: .top) {
            (canvasColor ?? session.themeBgColor).ignoresSafeArea()

            // Tap anywhere to dismiss keyboard — UIKit-backed, passes through child taps.
            KeyboardDismissView()

            VStack(spacing: 0) {
                headerBar
                // Slim offline strip — only visible when the device is offline.
                OfflineBanner()
                    .environment(session)
                if scrollDisabled {
                    content
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(.bottom, 8)   // small buffer for tab bar safeAreaInset
                } else {
                    // ScrollViewReader lets the coachmark engine scroll a spotlight target into
                    // view before highlighting it. Elements tagged with `.coachmarkAnchor(id)` also
                    // carry `.id(id)`, so scrollTo can find them; the engine posts .coachmarkScrollTo
                    // with the id. Purely additive — normal scrolling is unaffected.
                    ScrollViewReader { scrollProxy in
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 0) {
                                // A concrete first child is more reliable than using the generic
                                // content view itself as a scroll target, particularly when a tab
                                // root rebuild and the reselect notification happen together.
                                Color.clear
                                    .frame(height: 1)
                                    .id("stocked-shell-top")
                                    .accessibilityHidden(true)

                                content
                                    .frame(maxWidth: layoutMetrics.readableContentWidth, alignment: .leading)
                                    .frame(maxWidth: .infinity, alignment: .center)
                                    .padding(.bottom, StockedUI.scrollBottomPad)
                            }
                        }
                        // Short pages stay planted and long pages use native continuous
                        // deceleration. Section targets remain available to coach marks,
                        // but ordinary low-velocity scrolling is never forced to a card.
                        .stockedSectionSnapping(axes: .vertical, anchor: .top)
                        .stockedTrackScrollActivity($scrollActivity)
                        .defaultScrollAnchor(.top)
                        .scrollDismissesKeyboard(.interactively)
                        // App-wide pull-to-refresh. Screens with their own refresh needs pass
                        // onRefresh; everything else gets the standard refresh (household pull +
                        // cache rebuild + haptic) for free.
                        .refreshable {
                            if let onRefresh {
                                await onRefresh()
                            } else {
                                await StockedRefresh.standard(session: session)
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .coachmarkScrollTo)) { note in
                            guard let id = note.object as? String else { return }
                            motion.animate(.navigation, intent: .spatial) {
                                scrollProxy.scrollTo(id, anchor: .center)
                            }
                        }
                        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
                            motion.animate(.navigation, intent: .spatial) {
                                scrollProxy.scrollTo("stocked-shell-top", anchor: .top)
                            }
                        }
                    }
                }
            }
        }
        .environment(\.stockedScrollActivity, scrollActivity)
        .stockedAdaptiveInterface()
        .ignoresSafeArea(.keyboard)
        .toolbar(.hidden, for: .navigationBar)
    }

    // MARK: Header

    private var headerBar: some View {
        HStack(spacing: 10) {
            if showBack {
                Button { (stockedDismiss ?? { dismiss() })() } label: {
                    Image(systemName: "chevron.left")
                        .font(.stockedSystem(size: 19, weight: .medium))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .a11yButton("Back", hint: "Returns to the previous screen")
            }
            Button { (titleTap ?? onTitleTap)?() } label: {
                HStack(alignment: .center, spacing: 4) {
                    StockedWordmark(size: showBack ? 26 : StockedChrome.wordmarkSize,
                                   color: session.themeTextColor, dotColor: StockedPastel.honey)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    // Visible affordance: the wordmark opens the Daily Brief.
                    if titleTap != nil || onTitleTap != nil {
                        Image(systemName: "chevron.down")
                            .font(.stockedSystem(size: StockedChrome.wordmarkChevronSize, weight: .bold))
                            .foregroundStyle(session.themeSecondaryText)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(titleTap == nil && onTitleTap == nil)
            .accessibilityLabel(titleText == "Stocked" ? "Stocked" : "Stocked, \(titleText)")
            .accessibilityHint(titleTap != nil || onTitleTap != nil ? "Opens your Daily Brief" : "")
            .coachmarkAnchor("shell.title")
            Spacer(minLength: 0)
            if let trailingIcon, let onTrailing {
                headerAction(trailingIcon, label: trailingLabel, action: onTrailing)
            }
            if let trailingIcon2, let onTrailing2 {
                headerAction(trailingIcon2, label: trailingLabel2, action: onTrailing2)
            }
            // Consistent root header: app-wide search and Settings are always in the same place,
            // even on tabs that add their own action (Inventory previously lost the gear).
            if !showBack {
                if trailingIcon != "magnifyingglass" {
                    headerAction("magnifyingglass", label: "Search everything") {
                        NotificationCenter.default.post(name: .stockedOpenSearch, object: nil)
                    }
                }
                headerAction("gearshape", label: "Settings") {
                    NotificationCenter.default.post(name: .stockedOpenSettingsDrawer, object: nil)
                }
            }
        }
        .foregroundStyle(session.themeTextColor)
        .padding(.horizontal, layoutMetrics.horizontalPadding)
        .frame(minHeight: StockedChrome.headerHeight)
        .padding(.top, StockedChrome.headerTopPadding)
        .padding(.bottom, StockedChrome.headerBottomPadding)
    }

    private func headerAction(_ icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.stockedSystem(size: 20, weight: .regular))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yButton(label.isEmpty ? "Action" : label)
    }

}

/// Stable app chrome geometry. Page content may adapt, but the brand header must not.
enum StockedChrome {
    static let navigationCornerRadius: CGFloat = 0
    static let navigationInset: CGFloat = 0
    static let navigationBottomInset: CGFloat = 0
    static let wordmarkSize: CGFloat = 40
    static let wordmarkChevronSize: CGFloat = 10
    static let headerHeight: CGFloat = 56
    static let headerTopPadding: CGFloat = 0
    static let headerBottomPadding: CGFloat = 4
}



// MARK: - KeyboardDismissView (#3)
// UIViewRepresentable tap-dismissal doesn't intercept scroll or button taps,
// unlike .simultaneousGesture(TapGesture()) which breaks List and ScrollView.
private struct KeyboardDismissView: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        let v = PassthroughView()
        v.backgroundColor = .clear
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped))
        tap.cancelsTouchesInView = false      // does NOT block child view taps
        v.addGestureRecognizer(tap)
        return v
    }
    func updateUIView(_ uiView: UIView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator: NSObject {
        @objc func tapped() { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
    }
}

// Transparent view that passes all touch events through
private class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit == self ? nil : hit   // return nil for self — passes through
    }
}

#Preview {
    StockedShell(showBack: false, onTitleTap: {}) {
        VStack(spacing: 16) {
            ForEach(0..<4) { i in
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.stockedWhite.opacity(0.3))
                    .frame(height: 70)
                    .overlay(Text("Row \(i+1)").foregroundStyle(Color.primary))
            }
        }
        .padding(.horizontal, 24)
    }
}

extension Notification.Name {
    static let stockedOpenSettingsDrawer = Notification.Name("stockedOpenSettingsDrawer")
}
