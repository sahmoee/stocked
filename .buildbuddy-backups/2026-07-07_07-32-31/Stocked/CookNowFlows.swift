// CookNowFlows.swift — Cook Now branch screens (Checkpoint 2).
//
// Build Around Food (category cards → existing sub-option flow), Match My Mood (3-question flow
// → recipe finder), and Recipe Results (inventory-aware recommendations). Built from
// CookComponents. Reuses existing destinations (FoodsSubOptionView, MoodRecipeFinderView,
// UserRecipeDetailView) rather than duplicating recipe logic.

import SwiftUI

// MARK: - Build Around Food

struct BuildAroundFoodView: View {
    @Environment(AppSession.self) private var session
    var servings: Int = 4

    private struct Cat: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let emoji: String
        let key: String      // category key passed to FoodsSubOptionView
        let icon: String     // icon passed to FoodsSubOptionView
        let asset: String    // bundled image name (graceful fallback if absent)
    }

    private var categories: [Cat] {
        [
            Cat(title: "Proteins", subtitle: "Chicken, beef, fish and more", emoji: "🥩", key: "Protein", icon: "🍗", asset: "protein"),
            Cat(title: "Vegetables", subtitle: "Fresh produce on hand", emoji: "🥦", key: "Vegetables", icon: "🥕", asset: "vegetables"),
            Cat(title: "Expiring Soon", subtitle: "Use these before they go", emoji: "⏰", key: "Expiring Soon", icon: "📅", asset: "expiring_soon"),
            Cat(title: "Leftovers", subtitle: "Reinvent or reheat", emoji: "🍱", key: "Leftovers", icon: "🥡", asset: "leftovers"),
        ]
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Build Around Food") {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("What do you want to start with?")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Pick a category and we'll show you what's in your kitchen.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

                VStack(spacing: 10) {
                    ForEach(categories) { cat in
                        NavigationLink {
                            FoodsSubOptionView(category: cat.key, icon: cat.icon, servings: servings)
                        } label: {
                            CookCategoryCard(title: cat.title, subtitle: cat.subtitle, emoji: cat.emoji, assetName: cat.asset, cardHeight: 140)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, CookStyle.screenHPad)

                CookIntelligenceCard(
                    title: "Tip",
                    detail: "Expiring-soon items are shown first to help reduce waste.",
                    icon: "lightbulb.fill",
                    accent: Color.stockedGold
                )
                .padding(.horizontal, CookStyle.screenHPad)

                Spacer(minLength: 20)
            }
        }
    }
}

// MARK: - Match My Mood (3-question flow)

struct MatchMyMoodFlowView: View {
    @Environment(AppSession.self) private var session

    @State private var energy: String? = nil
    @State private var moodPick: String? = nil
    @State private var time: String? = nil
    @State private var goResults = false

    private var canShow: Bool { moodPick != nil }

    // Map the chosen mood to a (category, subcategory) the existing finder understands.
    private func mapping(for mood: String) -> (category: String, sub: String, emoji: String) {
        switch mood {
        case "Comforting":   return ("Current Mood", "Craving Comfort", "🥰")
        case "Bold & Spicy": return ("Passport Plates", "Indian", "🔥")
        case "Light & Fresh":return ("Current Mood", "Keep it Light", "🥗")
        case "Adventurous":  return ("Passport Plates", "Thai", "🌎")
        case "Indulgent":    return ("Current Mood", "Treat Yourself", "🍰")
        case "Challenge Me": return ("Today's Energy", "Feeling Chef-y", "🧑‍🍳")
        default:             return ("Current Mood", "Craving Comfort", "🥰")
        }
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Match My Mood") {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let's get a feel for tonight.")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Your answers help us find the perfect recipes for you.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 4)

                CookChipSelector(label: "1. How much energy do you have?",
                                 options: ["Low", "Medium", "High"], selection: $energy)
                CookChipSelector(label: "2. What sounds best right now?",
                                 options: ["Comforting", "Bold & Spicy", "Light & Fresh",
                                           "Adventurous", "Indulgent", "Challenge Me"],
                                 selection: $moodPick)
                CookChipSelector(label: "3. How much time do you have?",
                                 options: ["15 min", "30 min", "60+ min"], selection: $time)

                Button { goResults = true } label: {
                    HStack {
                        Image(systemName: "sparkles")
                        Text("Show My Recipes").font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(canShow ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 16))
                }
                .disabled(!canShow)
                .padding(.top, 4).padding(.bottom, 24)
            }
            .padding(.horizontal, CookStyle.screenHPad)
        }
        .navigationDestination(isPresented: $goResults) {
            let m = mapping(for: moodPick ?? "Comforting")
            MoodRecipeFinderView(category: m.category, subcategory: m.sub, emoji: m.emoji, servings: 4)
        }
    }
}

// MARK: - Recipe Results (inventory-aware list)

struct RecipeResultsView: View {
    @Environment(AppSession.self) private var session
    private var store: GuestDataStore { session.guestStore }

    @State private var openRecipe: UserRecipe? = nil
    @State private var goRecipe = false

    // Recipes ranked by inventory coverage (have/total), best first.
    private var ranked: [(recipe: UserRecipe, have: Int, total: Int)] {
        store.cookCatalog.compactMap { r in
            let m = store.stockMatch(for: r)
            guard m.total > 0 else { return nil }
            return (r, m.have, m.total)
        }
        .sorted { a, b in
            let pa = Double(a.have) / Double(max(1, a.total))
            let pb = Double(b.have) / Double(max(1, b.total))
            return pa > pb
        }
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Recipe Results") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Based on what you have")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

                if ranked.isEmpty {
                    CookEmptyState(
                        icon: "fork.knife",
                        title: "No recipes yet",
                        message: "Save some recipes and add ingredients, and your best matches will show up here.",
                        ctaTitle: nil, ctaAction: nil
                    )
                } else {
                    VStack(spacing: 10) {
                        ForEach(ranked.prefix(15), id: \.recipe.id) { entry in
                            let pct = Int((Double(entry.have) / Double(max(1, entry.total))) * 100)
                            CookRecipeCard(
                                title: entry.recipe.title,
                                subtitle: "\(entry.have)/\(entry.total) ingredients · \(entry.recipe.cookTime)",
                                matchPercent: pct,
                                imageURL: entry.recipe.imageURL
                            ) { openRecipe = entry.recipe; goRecipe = true }
                        }
                    }
                    .padding(.horizontal, CookStyle.screenHPad)
                }

                Spacer(minLength: 20)
            }
        }
        .navigationDestination(isPresented: $goRecipe) {
            if let r = openRecipe { UserRecipeDetailView(recipe: r) }
        }
    }
}
