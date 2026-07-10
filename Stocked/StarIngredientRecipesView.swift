// StarIngredientRecipesView.swift
// Cook Now → Build Around Food now lands here instead of a one-size template.
//
// Given the user's selection ("Chicken", "Leafy Greens", "Reinvent It", …) this
// searches the on-device RecipeDatabase (thousands of real recipes ingested
// from every source) for dishes that STAR that selection, then ranks them by
// pantry coverage: everything-on-hand first, then 1 missing, 2 missing, and so
// on — with substitutions surfacing on the detail screen as before. A Refresh
// button re-rolls the batch for different picks.

import SwiftUI

struct StarIngredientRecipesView: View {
    @Environment(AppSession.self) var session
    let category: String     // "Protein", "Vegetables", "Expiring Soon", "Leftovers"
    let selection: String    // "Chicken", "Leafy Greens", …
    let servings: Int

    private struct RankedRecipe: Identifiable {
        let entry: RecipeDatabaseEntry
        let missing: Int
        var id: UUID { entry.id }
    }

    @State private var ranked: [RankedRecipe] = []
    @State private var isLoading = true
    @State private var rollSeed = 0        // bumps on Refresh to re-shuffle picks
    @State private var openEntry: RecipeDatabaseEntry? = nil

    /// Search terms per selection — sub-options like "Leafy Greens" fan out to the
    /// actual foods so the database search hits real recipes.
    private var searchTerms: [String] {
        switch selection.lowercased() {
        case "leafy greens":      return ["spinach", "kale", "greens", "chard"]
        case "root veggies":      return ["potato", "carrot", "beet", "parsnip"]
        case "the roasters":      return ["roasted", "cauliflower", "brussels", "squash"]
        case "soft and sautéed",
             "soft and sauteed":  return ["mushroom", "zucchini", "onion", "sauteed"]
        case "seafood":           return ["shrimp", "salmon", "fish", "seafood"]
        case "use what's left",
             "flexible":
            // Expiring Soon — search around what's actually expiring.
            let expiring = session.guestStore.expiringSoonItems.prefix(4)
                .map { IngredientStockMatch.foodWords($0.name).first ?? $0.name }
            return expiring.isEmpty ? ["quick", "easy"] : Array(expiring)
        case "reinvent it", "simple reheat":
            let leftovers = session.guestStore.inventoryItems.filter { $0.isLeftover }.prefix(3)
                .map { IngredientStockMatch.foodWords($0.name).first ?? $0.name }
            return leftovers.isEmpty ? ["leftover", "fried rice", "casserole"] : Array(leftovers)
        default:                  return [selection]
        }
    }

    var body: some View {
        StockedShell(showBack: true, titleText: selection) {
            VStack(alignment: .leading, spacing: 14) {
                // ── Header (stays put — content below scrolls with the shell) ──
                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(selection) recipes")
                            .font(.system(size: 24, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text("Real recipes starring \(selection.lowercased()), sorted by what you already have.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        rollSeed += 1
                        Task { await load() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .bold))
                            Text("Refresh").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Color.stockedGold)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.stockedGold.opacity(0.12))
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Refresh recipes")
                }
                .padding(.horizontal, 20).padding(.top, 4)

                if isLoading {
                    HStack {
                        Spacer()
                        ProgressView("Finding \(selection.lowercased()) recipes…")
                            .font(.system(size: 12.5)).tint(Color.stockedGold)
                        Spacer()
                    }
                    .padding(.top, 60)
                } else if ranked.isEmpty {
                    StockedEmptyState(icon: "fork.knife",
                                      title: "No matches yet",
                                      subtitle: "Couldn't find recipes starring \(selection.lowercased()) in your recipe database. Browse the Recipes tab to pull more in, then try again.")
                        .padding(.top, 40)
                        .padding(.horizontal, 20)
                } else {
                    VStack(spacing: 10) {
                        ForEach(ranked) { r in
                            recipeRow(r)
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 24)
                }
            }
        }
        .task { await load() }
        .navigationDestination(item: $openEntry) { entry in
            RecipeOverviewView(
                title:       entry.title,
                servings:    Int(entry.servings) ?? servings,
                ingredients: entry.ingredients,
                steps:       entry.steps,
                cookTime:    entry.cookTime,
                prepTime:    entry.prepTime
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            openEntry = nil
        }
    }

    @ViewBuilder
    private func recipeRow(_ r: RankedRecipe) -> some View {
        Button { openEntry = r.entry } label: {
            HStack(spacing: 12) {
                if r.entry.imageURL.isEmpty {
                    ZStack {
                        RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm)
                            .fill(Color.stockedGold.opacity(0.12))
                        Text(ImageFallbackService.emoji(for: r.entry.title))
                            .font(.system(size: 24))
                    }
                    .frame(width: 62, height: 62)
                } else {
                    CachedAsyncImage(url: r.entry.imageURL, imageData: nil,
                                     height: 62, resolveName: r.entry.title)
                        .frame(width: 62, height: 62)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(r.entry.title)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text([r.entry.cuisine, r.entry.totalTime.isEmpty ? r.entry.cookTime : r.entry.totalTime]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.system(size: 11.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .lineLimit(1)
                }
                Spacer(minLength: 6)

                if r.missing == 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 10))
                        Text("Ready").font(.system(size: 10.5, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.stockedGreen).clipShape(Capsule())
                } else {
                    Text(r.missing == 1 ? "1 missing" : "\(r.missing) missing")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(r.missing <= 2 ? Color.stockedGold : Color.stockedError.opacity(0.88))
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(10)
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.45))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        isLoading = true
        let terms = searchTerms
        let items = session.guestStore.inventoryItems

        var pool: [RecipeDatabaseEntry] = []
        var seen = Set<String>()
        for term in terms {
            let hits = await RecipeDatabase.shared.search(term, limit: 30)
            for e in hits where !e.steps.isEmpty && !e.ingredients.isEmpty {
                let key = e.title.lowercased()
                if seen.insert(key).inserted { pool.append(e) }
            }
        }

        // The selection should STAR the dish: keep recipes whose title or first few
        // ingredients actually feature one of the search terms.
        let lowered = terms.map { $0.lowercased() }
        pool = pool.filter { e in
            let title = e.title.lowercased()
            if lowered.contains(where: { title.contains($0) }) { return true }
            let leadIngredients = e.ingredients.prefix(4).joined(separator: " ").lowercased()
            return lowered.contains(where: { leadIngredients.contains($0) })
        }

        // Rank by pantry coverage (fewest missing first), then quality of the entry,
        // shuffled within ties so Refresh produces different picks.
        var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: rollSeed &+ 7))
        let shuffled = pool.shuffled(using: &generator)
        let scored: [RankedRecipe] = shuffled.map { e in
            let miss = IngredientStockMatch.missing(e.ingredients, items: items).count
            return RankedRecipe(entry: e, missing: miss)
        }
        let sorted = scored.sorted {
            if $0.missing != $1.missing { return $0.missing < $1.missing }
            return ($0.entry.imageURL.isEmpty ? 1 : 0) < ($1.entry.imageURL.isEmpty ? 1 : 0)
        }
        ranked = Array(sorted.prefix(12))
        isLoading = false
    }
}

/// Deterministic shuffle source so Refresh re-rolls but a single render doesn't.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 2862933555777941757 &+ 3037000493 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
