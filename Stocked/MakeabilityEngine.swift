//
//  MakeabilityEngine.swift
//  Stocked
//
//  Computes membership for the catalog-level MakeabilityCategory browse buckets
//  (Makeable Entrées / Sides / Meals / Components / Sauces, Almost Makeable,
//  Ready With a Substitution, Use Soon, Planned for Later, Already Prepped,
//  Marinating, Cooked & Ready to Reheat).
//
//  Recipe-level readiness already comes from CookNowEngine (the 7-tier
//  CookNowReadiness). DishRole already classifies a recipe as entrée/side/
//  component/full-meal. This engine joins those two axes so MakeableNowView can
//  fill each category without every screen re-deriving the rules.
//
//  Pure & non-isolated: takes already-classified recipes in, returns groupings.
//

import Foundation

nonisolated enum MakeabilityEngine {

    /// The classified recipes for a category, plus a convenience count.
    struct Bucket: Sendable {
        let category: MakeabilityCategory
        let recipes: [ClassifiedRecipe]
        var count: Int { recipes.count }
        var isEmpty: Bool { recipes.isEmpty }
    }

    /// Compute every non-empty bucket from a classified recipe list.
    /// - Parameters:
    ///   - classified: output of `CookNowEngine.classifyAll(...)`.
    ///   - plannedCookAhead: optional cook-ahead statuses keyed by recipe title
    ///     (lowercased) so we can populate Marinating / Already Prepped /
    ///     Cooked & Ready to Reheat from the meal planner.
    static func buckets(from classified: [ClassifiedRecipe],
                       plannedCookAhead: [String: CookAheadStatus] = [:]) -> [Bucket] {
        MakeabilityCategory.allCases.compactMap { cat in
            let recipes = recipes(in: classified, category: cat, plannedCookAhead: plannedCookAhead)
            return recipes.isEmpty ? nil : Bucket(category: cat, recipes: recipes)
        }
    }

    /// Recipes that belong in a single category. Ordered by readiness so the
    /// most-makeable rise to the top of each row.
    static func recipes(in classified: [ClassifiedRecipe],
                       category: MakeabilityCategory,
                       plannedCookAhead: [String: CookAheadStatus] = [:]) -> [ClassifiedRecipe] {

        func readyNow(_ c: ClassifiedRecipe) -> Bool { c.readiness.isReadyNow }
        func role(_ c: ClassifiedRecipe) -> DishRole { c.recipe.dishRole }
        func status(_ c: ClassifiedRecipe) -> CookAheadStatus? {
            plannedCookAhead[c.recipe.title.lowercased()]
        }

        let result: [ClassifiedRecipe]
        switch category {

        // ── Role-scoped "makeable now" buckets ──────────────────────────
        case .entrees:
            result = classified.filter { readyNow($0) && role($0) == .entree }
        case .proteins:
            // Proteins are entrées whose anchor reads like a protein preparation.
            result = classified.filter { readyNow($0) && role($0) == .entree && looksLikeProtein($0.recipe.title) }
        case .sides:
            result = classified.filter { readyNow($0) && role($0) == .side }
        case .components:
            result = classified.filter { readyNow($0) && role($0) == .component }
        case .sauces:
            result = classified.filter { readyNow($0) && role($0) == .component && looksLikeSauce($0.recipe.title) }
        case .meals:
            result = classified.filter { readyNow($0) && role($0) == .fullMeal }

        // ── Readiness-scoped buckets (role-agnostic) ────────────────────
        case .almost:
            result = classified.filter { $0.readiness != .excluded && $0.unresolvedCount >= 6 }
        case .withSubstitution:
            result = classified.filter { $0.readiness == .readyWithSwap || $0.readiness == .swapNeedsReview }
        case .useSoon:
            // Recipes that use an in-stock ingredient the caller flagged urgent
            // are better surfaced via SideSuggestion/UseItUp; here we keep the
            // bucket honest by leaving it to planner-driven data. Empty unless
            // a future caller passes urgency in.
            result = []

        // ── Planner / cook-ahead-scoped buckets ─────────────────────────
        case .plannedLater:
            // On the plan but not yet cooked ahead (status is absent or .none).
            result = classified.filter {
                guard let s = plannedCookAhead[$0.recipe.title.lowercased()] else { return false }
                return s == .none
            }
        case .alreadyPrepped:
            result = classified.filter { status($0) == .prepped }
        case .marinating:
            result = classified.filter { status($0) == .marinating }
        case .cookedReadyToReheat:
            result = classified.filter {
                let s = status($0)
                return s == .readyToReheat || s == .stored || s == .cooked || s == .cooling
            }
        }

        return result.sorted {
            if $0.readiness != $1.readiness { return $0.readiness < $1.readiness }
            // RL-004 — among equally-ready recipes, ones that would consume
            // ingredients reserved for planned meals sink below truly free
            // ones: they are only "ready if plans change", never presented
            // ahead of a recipe with no strings attached.
            return !$0.usesReservedIngredients && $1.usesReservedIngredients
        }
    }

    // MARK: - Heuristics

    private static let proteinWords = ["chicken","beef","lamb","pork","salmon","shrimp","fish","turkey","steak","chop","tofu","egg","meatball"]
    private static let sauceWords   = ["sauce","gravy","dressing","marinade","glaze","dip","pesto","aioli","salsa","chutney"]

    private static func looksLikeProtein(_ title: String) -> Bool {
        let t = title.lowercased()
        return proteinWords.contains { t.contains($0) }
    }
    private static func looksLikeSauce(_ title: String) -> Bool {
        let t = title.lowercased()
        return sauceWords.contains { t.contains($0) }
    }
}
