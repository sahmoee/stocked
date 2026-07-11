// CookHubView.swift — the Cook tab entry (Cook Hub) and Cook Now Home.
//
// Checkpoint 1 of the Cook experience translation. Cook Hub is the top of the Cook tab: choose
// Cook Now (dinner tonight) or Cook Later (plan the week). Cook Now Home offers Build Around Food,
// Match My Mood, Surprise Me, plus an inventory-insight stack. Built from CookComponents and the
// package's navigation map. Cook Later and the deeper screens arrive in later checkpoints; their
// destinations are wired to existing flows where they already exist.

import SwiftUI

// MARK: - Cook Hub (Cook tab entry)

/// #FB2 — the Cook hub's two choices are circles by default (the original design),
/// with Photo Cards and Compact Rows available in Preferences → Appearance.
enum CookHubStyle: String, CaseIterable, Identifiable {
    case circles, cards, rows
    var id: String { rawValue }
    var label: String {
        switch self {
        case .circles: return "Circles"
        case .cards:   return "Photo Cards"
        case .rows:    return "Compact Rows"
        }
    }
    static let storageKey = "stocked.cookHubStyle"
}

struct CookHubView: View {
    @Environment(AppSession.self) private var session
    private var dark: Bool { session.isDarkMode }

    @AppStorage(CookHubStyle.storageKey) private var hubStyleRaw = CookHubStyle.circles.rawValue
    // The Cook Buttons setting (Settings > Preferences) is the single source of truth:
    // shape picks the representation, size scales it — both live. (The old stored style
    // had no picker anywhere, so the setting takes over cleanly; @AppStorage retained
    // only so existing installs don't lose the key.)
    private var hubStyle: CookHubStyle {
        switch session.cookButtonShape {
        case .circle:      return .circles
        case .pill:        return .rows
        case .roundedRect: return .cards
        }
    }
    /// 280pt is the slider's baseline (matches the hub's design size).
    private var sizeScale: CGFloat {
        min(400, max(150, CGFloat(session.cookButtonSize))) / 280.0
    }

    @State private var goCookNow = false
    @State private var goCookLater = false

    var body: some View {
        // #FB — the two choices are centered and fit the page on every device:
        // scrolling is disabled and the options are balanced with spacers so nothing
        // hangs off-screen or huddles at the top.
        StockedShell(scrollDisabled: true, titleText: "Cook", leadingTitle: true) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(greeting)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                    Text("What's on the menu tonight?")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Cook now, or plan ahead for the week.")
                        .font(.system(size: 14))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
                .coachmarkAnchor("cook.header")

                Spacer(minLength: 12)

                Group {
                    switch hubStyle {
                    case .circles: circleOptions
                    case .cards:   cardOptions
                    case .rows:    rowOptions
                    }
                }
                .padding(.horizontal, CookStyle.screenHPad)
                .frame(maxWidth: .infinity)
                // Live, centered, in-place: the Settings sliders animate these directly.
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: session.cookButtonSize)
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: session.cookButtonShape)

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationDestination(isPresented: $goCookNow) { CookNowHomeView() }
        .navigationDestination(isPresented: $goCookLater) { CookLaterHomeView() }
        .coachmarks(page: .cook, steps: CookCoachmarks.steps)
    }

    // ── Style 1 (default): two big circles stacked and centered ─────────
    // ViewThatFits drops to smaller circles on short screens (SE, zoomed display)
    // so both options always fit without scrolling.
    private var circleOptions: some View {
        ViewThatFits(in: .vertical) {
            circleStack(diameter: scaledDiameter(176), spacing: 26, showSubtitles: true)
            circleStack(diameter: scaledDiameter(148), spacing: 18, showSubtitles: true)
            circleStack(diameter: scaledDiameter(128), spacing: 14, showSubtitles: false)
        }
        .frame(maxWidth: .infinity)
    }

    /// Cook Buttons size applied per tier; clamped so ViewThatFits can always land a fit.
    private func scaledDiameter(_ base: CGFloat) -> CGFloat {
        min(230, max(100, base * sizeScale))
    }

    private func circleStack(diameter: CGFloat, spacing: CGFloat, showSubtitles: Bool) -> some View {
        VStack(spacing: spacing) {
            hubCircle(title: "Cook Now",
                      subtitle: showSubtitles ? "Dinner is solved. Build around what you have." : "",
                      emoji: "🍳",
                      tint: Color.stockedCharcoal,
                      diameter: diameter) { goCookNow = true }
                .coachmarkAnchor("cook.now")
            hubCircle(title: "Cook Later",
                      subtitle: showSubtitles ? "The week is handled. Plan meals ahead." : "",
                      emoji: "📅",
                      tint: Color.stockedGold,
                      diameter: diameter) { goCookLater = true }
                .coachmarkAnchor("cook.later")
        }
        .frame(maxWidth: .infinity)
    }

    private func hubCircle(title: String, subtitle: String, emoji: String,
                           tint: Color, diameter: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 10) {
                ZStack {
                    Circle().fill(tint)
                    Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 1.5)
                        .padding(6)
                    VStack(spacing: 6) {
                        Text(emoji).font(.system(size: diameter * 0.19))
                        Text(title)
                            .font(.system(size: diameter * 0.115, weight: .bold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                    }
                }
                .frame(width: diameter, height: diameter)
                .shadow(color: tint.opacity(0.35), radius: 12, y: 6)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 230)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title). \(subtitle)")
    }

    // ── Style 2: the photo hero cards ────────────────────────────────────
    private var cardOptions: some View {
        VStack(spacing: CookStyle.sectionSpacing) {
            CookHeroCard(
                title: "Cook Now",
                subtitle: "Dinner is solved. Build around what you have.",
                emoji: "🍳",
                assetName: "cook_now_hero",
                tint: Color.stockedCharcoal,
                textOnDark: true,
                height: min(210, max(110, 150 * sizeScale))   // Cook Buttons size, live
            ) { goCookNow = true }
            .coachmarkAnchor("cook.now")

            CookHeroCard(
                title: "Cook Later",
                subtitle: "The week is handled. Plan meals ahead.",
                icon: "calendar",
                assetName: "cook_later_hero",
                tint: Color.stockedGold,
                textOnDark: true,
                height: min(210, max(110, 150 * sizeScale))   // Cook Buttons size, live
            ) { goCookLater = true }
            .coachmarkAnchor("cook.later")
        }
    }

    // ── Style 3: compact rows ─────────────────────────────────────────────
    private var rowOptions: some View {
        VStack(spacing: 14) {
            hubRow(title: "Cook Now", subtitle: "Dinner is solved. Build around what you have.",
                   emoji: "🍳", tint: Color.stockedCharcoal) { goCookNow = true }
                .coachmarkAnchor("cook.now")
            hubRow(title: "Cook Later", subtitle: "The week is handled. Plan meals ahead.",
                   emoji: "📅", tint: Color.stockedGold) { goCookLater = true }
                .coachmarkAnchor("cook.later")
        }
    }

    private func hubRow(title: String, subtitle: String, emoji: String,
                        tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.white.opacity(0.16))
                        .frame(width: min(60, max(36, 46 * sizeScale)), height: min(60, max(36, 46 * sizeScale)))
                    Text(emoji).font(.system(size: min(28, max(17, 22 * sizeScale))))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedWhite)
                    Text(subtitle)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.stockedWhite.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.stockedWhite.opacity(0.8))
            }
            .padding(min(26, max(12, 18 * sizeScale)))   // Cook Buttons size, live
            .frame(maxWidth: .infinity)
            .background(tint)
            .clipShape(RoundedRectangle(cornerRadius: CookStyle.cardCorner))
        }
        .buttonStyle(.plain)
    }

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        let part = h < 12 ? "Good morning" : (h < 18 ? "Good afternoon" : "Good evening")
        return "\(part), Chef 👋"
    }
}

// MARK: - Cook Now Home

struct CookNowHomeView: View {
    @Environment(AppSession.self) private var session
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var goBuildFood = false
    @State private var goMood = false
    @State private var goSurprise = false

    // Perf: these two scans score every recipe against the whole inventory — far too
    // heavy to recompute on every render. Computed once on appear and again only when
    // the inventory actually changes, into plain @State the body reads for free.
    @State private var wasteNothing: (recipe: UserRecipe, used: [String])? = nil
    @State private var readyCount = 0

    private func recomputeInsights() {
        if let top = store.cookableRankedByExpiry().first(where: { !$0.expiringUsed.isEmpty }) {
            wasteNothing = (top.recipe, top.expiringUsed)
        } else {
            wasteNothing = nil
        }
        readyCount = computedReadyCount
    }
    private var computedReadyCount: Int {
        store.cookCatalog.filter { r in
            let m = store.stockMatch(for: r)
            return m.total > 0 && m.have == m.total
        }.count
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Cook Now") {
            // Perf hook: recompute the heavy insights off the render path.
            Color.clear.frame(height: 0)
                .task { recomputeInsights() }
                .onChange(of: store.inventoryItems) { _, _ in recomputeInsights() }
                .onChange(of: store.userRecipes)    { _, _ in recomputeInsights() }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("How do you want to find dinner?")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Pick a path and we'll do the rest.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

                VStack(spacing: CookStyle.sectionSpacing) {
                    CookActionCard(
                        title: "Build Around Food",
                        subtitle: "Use what you have or what you love.",
                        emoji: "🥩",
                        assetName: "cook_now_card",
                        tint: Color.stockedCharcoal, textOnDark: true, cardHeight: 195
                    ) { goBuildFood = true }

                    CookActionCard(
                        title: "Match My Mood",
                        subtitle: "Find recipes that fit how you feel.",
                        emoji: "🙂",
                        assetName: "match_my_mood",
                        tint: Color.stockedGold, textOnDark: true, cardHeight: 195
                    ) { goMood = true }

                    CookActionCard(
                        title: "Surprise Me",
                        subtitle: "Let us pick the perfect recipe.",
                        icon: "gift",
                        assetName: "surprise_me",
                        tint: dark ? Color.darkSurface : Color.stockedWhite.opacity(0.7),
                        textOnDark: false, cardHeight: 195
                    ) { goSurprise = true }
                }
                .padding(.horizontal, CookStyle.screenHPad)

                // ── Inventory Insights (IntelligenceCard) ──
                VStack(alignment: .leading, spacing: 10) {
                    Text("Inventory Insights")
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .padding(.horizontal, CookStyle.screenHPad)

                    if let wn = wasteNothing {
                        CookIntelligenceCard(
                            title: "Cook now, waste nothing",
                            detail: "Make \(wn.recipe.title) — uses \(wn.used.prefix(2).joined(separator: ", "))",
                            icon: "leaf.fill",
                            accent: Color.stockedGreen
                        ) { goBuildFood = true }
                        .padding(.horizontal, CookStyle.screenHPad)
                    }

                    CookIntelligenceCard(
                        title: readyCount > 0 ? "Ready to cook" : "Stock up to unlock recipes",
                        detail: readyCount > 0
                            ? "\(readyCount) recipe\(readyCount == 1 ? "" : "s") you can make right now"
                            : "Add a few ingredients and meals will show up here",
                        icon: "checkmark.circle.fill",
                        accent: Color.stockedGold
                    ) { goBuildFood = true }
                    .padding(.horizontal, CookStyle.screenHPad)
                }

                Spacer(minLength: 20)
            }
        }
        .navigationDestination(isPresented: $goBuildFood) { BuildAroundFoodView(servings: 4) }
        .navigationDestination(isPresented: $goMood) { MatchMyMoodFlowView() }
        .navigationDestination(isPresented: $goSurprise) { ServingSizeView(isCookNow: true) }
    }
}
