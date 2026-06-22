// CookHubView.swift — the Cook tab entry (Cook Hub) and Cook Now Home.
//
// Checkpoint 1 of the Cook experience translation. Cook Hub is the top of the Cook tab: choose
// Cook Now (dinner tonight) or Cook Later (plan the week). Cook Now Home offers Build Around Food,
// Match My Mood, Surprise Me, plus an inventory-insight stack. Built from CookComponents and the
// package's navigation map. Cook Later and the deeper screens arrive in later checkpoints; their
// destinations are wired to existing flows where they already exist.

import SwiftUI

// MARK: - Cook Hub (Cook tab entry)

struct CookHubView: View {
    @Environment(AppSession.self) private var session
    private var dark: Bool { session.isDarkMode }

    @State private var goCookNow = false
    @State private var goCookLater = false

    var body: some View {
        StockedShell(titleText: "Cook", leadingTitle: true) {
            VStack(alignment: .leading, spacing: 16) {
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

                VStack(spacing: CookStyle.sectionSpacing) {
                    CookHeroCard(
                        title: "Cook Now",
                        subtitle: "Dinner is solved. Build around what you have.",
                        emoji: "🍳",
                        tint: Color.stockedCharcoal,
                        textOnDark: true
                    ) { goCookNow = true }

                    CookHeroCard(
                        title: "Cook Later",
                        subtitle: "The week is handled. Plan meals ahead.",
                        icon: "calendar",
                        tint: Color.stockedGold,
                        textOnDark: true
                    ) { goCookLater = true }
                }
                .padding(.horizontal, CookStyle.screenHPad)

                Spacer(minLength: 20)
            }
        }
        .navigationDestination(isPresented: $goCookNow) { CookNowHomeView() }
        .navigationDestination(isPresented: $goCookLater) { CookLaterHomeView() }
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

    // Inventory-aware insight: the recipe that best uses expiring items, if any.
    private var wasteNothing: (recipe: UserRecipe, used: [String])? {
        if let top = store.cookableRankedByExpiry().first(where: { !$0.expiringUsed.isEmpty }) {
            return (top.recipe, top.expiringUsed)
        }
        return nil
    }
    private var readyCount: Int {
        store.cookCatalog.filter { r in
            let m = store.stockMatch(for: r)
            return m.total > 0 && m.have == m.total
        }.count
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Cook Now") {
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
                        tint: Color.stockedCharcoal, textOnDark: true
                    ) { goBuildFood = true }

                    CookActionCard(
                        title: "Match My Mood",
                        subtitle: "Find recipes that fit how you feel.",
                        emoji: "🙂",
                        assetName: "match_my_mood",
                        tint: Color.stockedGold, textOnDark: true
                    ) { goMood = true }

                    CookActionCard(
                        title: "Surprise Me",
                        subtitle: "Let us pick the perfect recipe.",
                        icon: "gift",
                        assetName: "surprise_me",
                        tint: dark ? Color.darkSurface : Color.stockedWhite.opacity(0.7),
                        textOnDark: false
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
