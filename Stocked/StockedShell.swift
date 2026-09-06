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
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        ZStack {
            // Centered title button — tap area limited to the text (.fixedSize) so it
            // doesn't swallow taps meant for the back button.
            Group {
                // #246 — mockup headers: each tab pins its OWN wordmark left ("Stocked.",
                // "Cook.", "Inventory.") with no chevron. The brand period remains the single
                // gold accent while the word continues to use the active theme text color.
                // Centered mode (sub-screens) keeps "Stocked." + chevron.
                // The header brand wordmark is ALWAYS "Stocked." on every screen — it
                // never switches to the section name (Cook / Inventory / Recipes / …).
                // `titleText` is kept only for the VoiceOver label so screen-reader users
                // still hear which screen they're on.
                let wordmark = StockedWordmark(
                    size: StockedChrome.wordmarkSize,
                    color: session.themeTextColor,
                    dotColor: .stockedGold
                )

                let titleCore = Button { (titleTap ?? onTitleTap)?() } label: {
                    HStack(spacing: 5) {
                        wordmark
                        Image(systemName: "chevron.down")
                            .font(.stockedSystem(size: StockedChrome.wordmarkChevronSize, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(titleTap == nil && onTitleTap == nil)
                .fixedSize()
                .accessibilityLabel(titleText == "Stocked" ? "Stocked" : "Stocked, \(titleText)")
                .coachmarkAnchor("shell.title")

                titleCore
            }

            // Back button pinned left — only the chevron is tappable; the Spacer is inert
            // so it never intercepts taps over the centered title.
            if showBack {
                HStack {
                    Button { (stockedDismiss ?? { dismiss() })() } label: {
                        Image(systemName: "chevron.left")
                            .scaledFont(20, weight: .semibold)
                            .foregroundStyle(session.themeTextColor)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .a11yButton("Back", hint: "Returns to the previous screen")
                    Spacer().allowsHitTesting(false)
                }
                // #FB2 — nudged right, clear of the 28pt drawer edge catcher, so taps
                // on the chevron never open the drawer.
                .padding(.leading, 30)
            }

            // Trailing action pinned right (e.g. search) (#7).
            if trailingIcon != nil || trailingIcon2 != nil {
                HStack(spacing: 0) {
                    Spacer().allowsHitTesting(false)
                    if let trailingIcon, let onTrailing {
                        Button { onTrailing() } label: {
                            Image(systemName: trailingIcon)
                                .scaledFont(19, weight: .semibold)
                                .foregroundStyle(session.themeTextColor)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .a11yButton(trailingLabel.isEmpty ? "Action" : trailingLabel)
                    }
                    if let trailingIcon2, let onTrailing2 {
                        Button { onTrailing2() } label: {
                            Image(systemName: trailingIcon2)
                                .scaledFont(19, weight: .semibold)
                                .foregroundStyle(session.themeTextColor)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .a11yButton(trailingLabel2.isEmpty ? "Action" : trailingLabel2)
                    }
                }
                .padding(.trailing, 12)
            }
        }
        // The VStack already respects the top safe area (only the background ignores
        // it), so we just need a small gap below the status bar — NOT another full
        // safeTopInset, which double-counted the inset and left a large empty band
        // above the wordmark on every screen.
        .frame(height: StockedChrome.headerHeight)
        .padding(.top, StockedChrome.headerTopPadding)
        .padding(.bottom, StockedChrome.headerBottomPadding)
    }
}

/// Stable app chrome geometry. Page content may adapt, but the brand header must not.
enum StockedChrome {
    static let wordmarkSize: CGFloat = 20
    static let wordmarkChevronSize: CGFloat = 10
    static let headerHeight: CGFloat = 32
    static let headerTopPadding: CGFloat = 8
    static let headerBottomPadding: CGFloat = 14
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
