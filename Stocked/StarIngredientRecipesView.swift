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

    private nonisolated struct RankedRecipe: Identifiable, Sendable {
        let entry: RecipeDatabaseEntry
        let missing: Int
        var id: UUID { entry.id }
    }

    @State private var ranked: [RankedRecipe] = []
    @State private var isLoading = true
    @State private var loadingMessage = "Searching your recipe library…"
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
                            .scaledFont(24, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Text("Real recipes starring \(selection.lowercased()), sorted by what you already have.")
                            .scaledFont(12.5)
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        rollSeed += 1
                        Task { await load() }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "arrow.clockwise").scaledFont(11, weight: .bold)
                            Text("Refresh").scaledFont(12, weight: .semibold)
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
                        ProgressView(loadingMessage)
                            .scaledFont(12.5).tint(Color.stockedGold)
                        Spacer()
                    }
                    .padding(.top, 60)
                } else if ranked.isEmpty {
                    StockedEmptyState(icon: "fork.knife",
                                      title: "No matches yet",
                                      subtitle: "Couldn't find or build a complete recipe for \(selection.lowercased()). Check your connection and try Refresh.")
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
                            .scaledFont(24)
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
                        .scaledFont(14.5, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    Text([r.entry.sourceName, r.entry.cuisine,
                          r.entry.totalTime.isEmpty ? r.entry.cookTime : r.entry.totalTime]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .scaledFont(11.5)
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)

                if r.missing == 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill").scaledFont(10)
                        Text("Ready").scaledFont(10.5, weight: .bold)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Color.stockedGreen).clipShape(Capsule())
                } else {
                    Text(r.missing == 1 ? "1 missing" : "\(r.missing) missing")
                        .scaledFont(10.5, weight: .bold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(r.missing <= 2 ? Color.stockedGold : Color.stockedError.opacity(0.88))
                        .clipShape(Capsule())
                }
                Image(systemName: "chevron.right")
                    .scaledFont(11, weight: .semibold)
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
        loadingMessage = "Searching your recipe library…"
        let terms = searchTerms
        let items = session.guestStore.inventoryItems
        let seed = rollSeed

        var pool: [RecipeDatabaseEntry] = []
        var seen = Set<String>()
        for term in terms {
            let hits = await RecipeDatabase.shared.search(term, limit: 30)
            appendUnique(hits, to: &pool, seen: &seen)
            let corpusHits = await RecipeDatabaseManager.shared.corpusSearch(term, limit: 30)
            appendUnique(corpusHits, to: &pool, seen: &seen)
        }

        var results = await rank(pool: pool, terms: terms, items: items, seed: seed)
        if !results.isEmpty {
            // Surface real local matches immediately; publisher enrichment can continue without
            // making the user stare at a network spinner.
            ranked = results
            isLoading = false
        }

        // If the local pool is thin, query the ten newly wired recipe publishers and ingest
        // their complete JSON-LD recipes into the same database used everywhere else.
        if pool.count < 12, let query = terms.first {
            if results.isEmpty { loadingMessage = "Checking more recipe sources…" }
            let webRecipes = await WebRecipeFetcher.shared.fetchExpandedPublisherRecipes(
                query: query,
                limitPerSource: 2
            )
            let webEntries = webRecipes.map { databaseEntry(from: $0) }
            appendUnique(webEntries, to: &pool, seen: &seen)
            if !webEntries.isEmpty {
                await RecipeDatabaseManager.shared.ingestHarvested(webEntries)
                results = await rank(pool: pool, terms: terms, items: items, seed: seed)
            }
        }

        // Last resort: build a complete recipe through the deployed Worker. This prevents
        // Build Around Food from ending at a title-only placeholder or a dead empty state.
        if results.isEmpty, RecipeGeneratorAI.isAvailable {
            loadingMessage = "Building a recipe around \(selection.lowercased())…"
            let pantry = items.prefix(30).map(\.name)
            let dietary = session.guestStore.cookingProfile.dietaryStyle
            let idea = "Create a practical \(category.lowercased()) recipe starring \(selection). Use normal grocery-store ingredients and give complete measured ingredients and step-by-step instructions."
            let generated = await RecipeGeneratorAI.generate(
                idea: idea,
                options: .init(
                    haveItems: pantry,
                    dietary: dietary.isEmpty ? nil : dietary,
                    maxTime: nil
                )
            )
            if let generated {
                let entry = databaseEntry(from: generated)
                _ = await RecipeDatabase.shared.upsert(entry)
                results = await rank(pool: [entry], terms: terms, items: items, seed: seed)
            }
        }

        ranked = results
        isLoading = false
    }

    private func appendUnique(_ entries: [RecipeDatabaseEntry],
                              to pool: inout [RecipeDatabaseEntry],
                              seen: inout Set<String>) {
        for var entry in entries where RecipeDisplayPolicy.isPresentable(
            title: entry.title, imageURL: entry.imageURL,
            ingredients: entry.ingredients.count, steps: entry.steps.count,
            sourceURL: entry.sourceURL) {
            entry.title = RecipeDisplayPolicy.cleanedTitle(entry.title)
            let key = entry.title.lowercased()
            if seen.insert(key).inserted { pool.append(entry) }
        }
    }

    private func rank(pool: [RecipeDatabaseEntry],
                      terms: [String],
                      items: [LocalInventoryItem],
                      seed: Int) async -> [RankedRecipe] {
        // Filtering + pantry coverage stay off the main actor so recipe discovery cannot freeze
        // the drawer or tab transitions while a larger source batch is being evaluated.
        await Task.detached(priority: .userInitiated) { () -> [RankedRecipe] in
            let lowered = terms.map { $0.lowercased() }
            let starred = pool.filter { entry in
                let title = entry.title.lowercased()
                if lowered.contains(where: { title.contains($0) }) { return true }
                let leadIngredients = entry.ingredients.prefix(5).joined(separator: " ").lowercased()
                return lowered.contains(where: { leadIngredients.contains($0) })
            }
            let candidates = starred.isEmpty && pool.count == 1 ? pool : starred
            let pantryWords = IngredientStockMatch.pantryWordSets(items)
            var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: seed &+ 7))
            let shuffled = candidates.shuffled(using: &generator)
            let scored = shuffled.map { entry in
                RankedRecipe(
                    entry: entry,
                    missing: IngredientStockMatch.missingCount(entry.ingredients, pantryWords: pantryWords)
                )
            }
            let sorted = scored.sorted {
                if $0.missing != $1.missing { return $0.missing < $1.missing }
                return ($0.entry.imageURL.isEmpty ? 1 : 0) < ($1.entry.imageURL.isEmpty ? 1 : 0)
            }
            return Array(sorted.prefix(12))
        }.value
    }

    private func databaseEntry(from web: WebRecipe) -> RecipeDatabaseEntry {
        let steps = web.steps.map(\.text)
        let classification = RecipeClassifier.classify(
            title: web.title,
            rawCuisine: web.cuisine,
            rawCategory: web.category,
            keywords: web.tags,
            ingredients: web.ingredients.map { RecipeIngredient(name: $0, amount: "") },
            instructions: steps
        )
        return RecipeDatabaseEntry(
            title: web.title,
            description: web.description,
            sourceURL: web.sourceURL,
            sourceName: web.sourceName,
            prepTime: web.prepTime,
            cookTime: web.cookTime,
            totalTime: web.totalTime,
            servings: web.servings,
            category: classification.category,
            cuisine: classification.cuisine,
            tags: classification.tags + web.tags,
            ingredients: web.ingredients,
            steps: steps,
            imageURL: web.imageURL,
            calories: web.calories ?? "",
            rating: web.rating
        )
    }

    private func databaseEntry(from generated: GeneratedRecipe) -> RecipeDatabaseEntry {
        let ingredientLines = generated.ingredients.map { line in
            let amount = line.amount.trimmingCharacters(in: .whitespacesAndNewlines)
            return amount.isEmpty ? line.name : "\(amount) \(line.name)"
        }
        let rawTags = [category, selection] + searchTerms
        let classification = RecipeClassifier.classify(
            title: generated.title,
            rawCuisine: generated.cuisine,
            rawCategory: generated.mealCategory.isEmpty ? category : generated.mealCategory,
            keywords: rawTags,
            ingredients: generated.ingredients.map { RecipeIngredient(name: $0.name, amount: $0.amount) },
            instructions: generated.steps
        )
        return RecipeDatabaseEntry(
            title: generated.title,
            description: generated.tips,
            sourceURL: "",
            sourceName: "Stocked AI",
            prepTime: "",
            cookTime: generated.cookTime,
            totalTime: generated.cookTime,
            servings: String(generated.servings),
            category: classification.category,
            cuisine: classification.cuisine,
            tags: classification.tags + rawTags,
            ingredients: ingredientLines,
            steps: generated.steps,
            imageURL: generated.imageURL ?? ""
        )
    }
}

/// Deterministic shuffle source so Refresh re-rolls but a single render doesn't.
private nonisolated struct SeededGenerator: RandomNumberGenerator, Sendable {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 2862933555777941757 &+ 3037000493 }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}
