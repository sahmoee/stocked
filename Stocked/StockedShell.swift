// StockedShell.swift — Universal page wrapper (post-login).
// Header: centered "Stocked." + chevron.down, tappable → Daily Brief.
import SwiftUI

struct StockedShell<Content: View>: View {
    var showBack:       Bool
    var scrollDisabled: Bool
    var titleText:      String               // #246 — per-tab wordmark ("Cook", "Inventory", …)
    var onTitleTap:     (() -> Void)?
    var trailingIcon:   String?          // optional top-right action (e.g. search) (#7)
    var trailingLabel:  String           // VoiceOver label for the trailing action
    var onTrailing:     (() -> Void)?
    var leadingTitle:   Bool                 // #245 — Home: wordmark pinned left (mockup)
    var trailingIcon2:  String?              // #245 — optional second top-right action
    var trailingLabel2: String
    var onTrailing2:    (() -> Void)?
    var onRefresh:      (() async -> Void)?  // custom pull-to-refresh; nil = standard app refresh
    var content:        Content
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.stockedDismiss) private var stockedDismiss
    @Environment(\.stockedTitleTap) private var titleTap
    @Environment(\.stockedLayout) private var layoutMetrics

    init(
        showBack:       Bool = false,
        scrollDisabled: Bool = false,
        titleText:      String = "Stocked",
        leadingTitle:   Bool = false,
        onTitleTap:     (() -> Void)? = nil,
        trailingIcon:   String? = nil,
        trailingLabel:  String = "",
        onTrailing:     (() -> Void)? = nil,
        trailingIcon2:  String? = nil,
        trailingLabel2: String = "",
        onTrailing2:    (() -> Void)? = nil,
        onRefresh:      (() async -> Void)? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.showBack       = showBack
        self.scrollDisabled = scrollDisabled
        self.titleText      = titleText
        self.onTitleTap     = onTitleTap
        self.trailingIcon   = trailingIcon
        self.trailingLabel  = trailingLabel
        self.onTrailing     = onTrailing
        self.leadingTitle   = leadingTitle
        self.trailingIcon2  = trailingIcon2
        self.trailingLabel2 = trailingLabel2
        self.onTrailing2    = onTrailing2
        self.onRefresh      = onRefresh
        self.content        = content()
    }

    var body: some View {
        ZStack(alignment: .top) {
            session.themeBgColor.ignoresSafeArea()

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
                            content
                                .frame(maxWidth: layoutMetrics.readableContentWidth, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .padding(.bottom, StockedUI.scrollBottomPad)
                        }
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
                            withAnimation(.easeInOut(duration: 0.35)) {
                                scrollProxy.scrollTo(id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
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
                // "Cook.", "Inventory.") with no chevron. The trailing period now matches the
                // wordmark text color (black in light mode) rather than the gold accent.
                // Centered mode (sub-screens) keeps "Stocked." + chevron.
                // The header brand wordmark is ALWAYS "Stocked." on every screen — it
                // never switches to the section name (Cook / Inventory / Recipes / …).
                // `titleText` is kept only for the VoiceOver label so screen-reader users
                // still hear which screen they're on.
                let wordmark = Text("Stocked.").foregroundColor(session.themeTextColor)
                    .font(.stockedSerif(26, weight: .bold))

                let titleCore = Button { (titleTap ?? onTitleTap)?() } label: {
                    HStack(spacing: 5) {
                        wordmark
                        if !leadingTitle {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(titleTap == nil && onTitleTap == nil)
                .fixedSize()
                .accessibilityLabel(titleText == "Stocked" ? "Stocked" : "Stocked, \(titleText)")
                .coachmarkAnchor("shell.title")

                if leadingTitle {
                    // #4 — headers are centered app-wide (tab roots included). The
                    // wordmark sits centered; trailing icons remain pinned right via the
                    // separate overlay below.
                    titleCore
                } else {
                    titleCore
                }
            }

            // Back button pinned left — only the chevron is tappable; the Spacer is inert
            // so it never intercepts taps over the centered title.
            if showBack {
                HStack {
                    Button { (stockedDismiss ?? { dismiss() })() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
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
                                .font(.system(size: 19, weight: .semibold))
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
                                .font(.system(size: 19, weight: .semibold))
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
        .padding(.top, 8)
        .padding(.bottom, 14)
    }
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
