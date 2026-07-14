// CookNowCompute.swift
// ─────────────────────────────────────────────────────────────────
// The one place Cook Now surfaces go to turn the live store + session into a
// classified snapshot. Keeps the engine pure (it never sees the store) and
// keeps every screen's answer consistent because they all call this.
//
// Usage discipline (matches the app's existing derived-state rules):
//   • Call from .task / .onChange(of: store.inventoryRevision) /
//     .onChange(of: store.recipeRevision) / after a session override changes —
//     NEVER from inside a view body.
//   • Store the Output in @State and render from that.
//
// Substitute lookup is pre-resolved here into a plain dictionary before the
// engine runs, so the engine's resolver closure is a pure Sendable lookup and
// the substitution source of truth stays in GuestDataStore + StockedDatabase.
// ─────────────────────────────────────────────────────────────────

import Foundation

@MainActor
enum CookNowCompute {

    /// Everything a Cook Now surface needs to render, produced in one pass.
    struct Output {
        var classified: [ClassifiedRecipe] = []
        var metrics = CookNowMetrics()
        var emphasis: CookNowMetrics.Emphasis = .noMatches

        static let empty = Output()

        /// Recipes in the dashboard's Ready Now bucket (exact + confirmed swaps),
        /// exact matches first.
        var readyNow: [ClassifiedRecipe] {
            classified.filter { $0.readiness.isReadyNow }.sorted { $0.readiness < $1.readiness }
        }
        /// Recipes one review-tap away from ready.
        var needsReview: [ClassifiedRecipe] { classified.filter { $0.readiness == .swapNeedsReview } }
        /// Almost ready (missing 1–2), fewest missing first.
        var almostReady: [ClassifiedRecipe] {
            classified.filter { $0.readiness.isAlmostReady }.sorted { $0.missingCount < $1.missingCount }
        }
        /// More possibilities (missing 3+), closest first.
        var morePossibilities: [ClassifiedRecipe] { CookNowEngine.morePossibilities(in: classified) }
    }

    /// Classify the current catalog against the current inventory, profile, and
    /// (optionally) a Cook Now session's overrides + confirmed substitutions.
    static func run(store: GuestDataStore, session: CookNowSession?) -> Output {
        let recipes = store.cookCatalog

        // In-stock names: same availability rule the rest of the app uses.
        let inStock = store.inventoryItems.filter { $0.effectiveLevel > 0 }.map { $0.name }

        // Allergens come from the saved cooking profile — the same source the
        // vault's allergen warnings use. (Household member dislikes have no
        // central store accessor today; when one exists it plugs in here.)
        let allergens = store.cookingProfile.allergens.filter { !$0.isEmpty }

        // Pre-resolve in-stock substitutes for every ingredient the classifier
        // might ask about (anything not directly in stock). One store pass;
        // the engine then does pure dictionary lookups.
        var subMap: [String: [String]] = [:]
        for r in recipes {
            for ing in r.ingredients where !ing.isOptional {
                let key = ing.name.lowercased().trimmingCharacters(in: .whitespaces)
                if subMap[key] == nil && !store.ingredientInStock(ing.name) {
                    subMap[key] = store.inStockSubstitutes(for: ing.name)
                }
            }
        }
        let lookup = subMap  // immutable copy captured by the Sendable resolver

        let engine = CookNowEngine(
            recipes: recipes,
            inStockNames: inStock,
            allergens: allergens,
            dislikes: [],
            confirmedSubstitutions: session?.confirmedSubstitutionKeys ?? [],
            overrides: session.map { s in
                // Session stores lowercased keys already; pass through.
                var out: [String: IngredientOverride] = [:]
                for (k, v) in s.overridesSnapshotForEngine { out[k] = v }
                return out
            } ?? [:]
        )

        let classified = engine.classifyAll { name in
            lookup[name.lowercased().trimmingCharacters(in: .whitespaces), default: []]
        }

        var out = Output()
        out.classified = classified
        out.metrics = CookNowEngine.metrics(from: classified)
        out.emphasis = CookNowEngine.emphasis(for: out.metrics,
                                              inventoryEmpty: store.inventoryItems.isEmpty)
        return out
    }

    /// The classification for one specific recipe under the current snapshot.
    static func classify(recipe: UserRecipe, store: GuestDataStore, session: CookNowSession?) -> ClassifiedRecipe {
        // Small enough to just run the full pass and pick; keeps one code path.
        if let hit = run(store: store, session: session).classified.first(where: { $0.recipe.id == recipe.id }) {
            return hit
        }
        // Recipe not in the catalog (e.g. freshly generated): classify it alone.
        let inStock = store.inventoryItems.filter { $0.effectiveLevel > 0 }.map { $0.name }
        var subMap: [String: [String]] = [:]
        for ing in recipe.ingredients where !ing.isOptional {
            let key = ing.name.lowercased().trimmingCharacters(in: .whitespaces)
            if !store.ingredientInStock(ing.name) { subMap[key] = store.inStockSubstitutes(for: ing.name) }
        }
        let lookup = subMap
        let engine = CookNowEngine(
            recipes: [recipe],
            inStockNames: inStock,
            allergens: store.cookingProfile.allergens.filter { !$0.isEmpty },
            confirmedSubstitutions: session?.confirmedSubstitutionKeys ?? [],
            overrides: session?.overridesSnapshotForEngine ?? [:]
        )
        return engine.classify(recipe) { name in
            lookup[name.lowercased().trimmingCharacters(in: .whitespaces), default: []]
        }
    }
}

// MARK: - Session bridge

extension CookNowSession {
    /// The overrides dictionary in the exact shape the engine consumes.
    var overridesSnapshotForEngine: [String: IngredientOverride] { overrides }
}
