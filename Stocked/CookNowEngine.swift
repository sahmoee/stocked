// CookNowEngine.swift
// ─────────────────────────────────────────────────────────────────
// The single readiness-classification and recommendation brain for Cook Now.
//
// Every Cook Now entry point (dashboard metrics, Build Around Food, Match My
// Mood, Surprise Me, See All) routes through this one engine so their answers
// always agree. It is intentionally a pure value-producing service:
//
//   • It never mutates the store or inventory.
//   • It reads a snapshot of recipes + inventory + profile + session overrides
//     and returns a fully classified result.
//   • It is cheap and safe to call off the main actor, and callers cache its
//     output keyed on the store's revision counters × servings × override hash
//     (the same discipline the app already uses for stockMatchCache and the
//     Cook hub insights), so it is NOT recomputed inside SwiftUI view bodies.
//
// Readiness is classified into the seven-tier model from the Cook Now spec.
// Substitutions are considered BEFORE counting missing ingredients: a recipe
// that needs buttermilk but for which the user owns a valid in-stock swap does
// not count that ingredient as missing.
// ─────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Readiness tiers

/// The seven-tier readiness classification. Order matters: `rawValue` ascends
/// from most-ready to least-ready, so tiers sort naturally.
nonisolated enum CookNowReadiness: Int, Sendable, Comparable, CaseIterable {
    /// All required ingredients are on hand in the inventory.
    case exact = 0
    /// Every gap is covered by a substitute the user already has AND has
    /// confirmed for this session (or that needs no review).
    case readyWithSwap = 1
    /// A valid in-stock substitute exists but the user must review/approve it
    /// before the recipe can be treated as ready.
    case swapNeedsReview = 2
    /// Exactly one required ingredient is unresolved after substitutions.
    case missingOne = 3
    /// Exactly two required ingredients are unresolved after substitutions.
    case missingTwo = 4
    /// Three or more required ingredients are unresolved — "More Possibilities".
    case missingMany = 5
    /// Excluded by an active safety/preference rule (allergen, etc.).
    case excluded = 6

    static func < (lhs: CookNowReadiness, rhs: CookNowReadiness) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Whether this tier belongs in the dashboard's primary "Ready now" metric.
    /// Swaps-needing-review are surfaced but are deliberately NOT counted as
    /// exact-ready; callers decide whether to fold them into "ready with swaps".
    var isReadyNow: Bool { self == .exact || self == .readyWithSwap }

    /// Whether this tier belongs in the dashboard's "Almost ready" metric
    /// (missing only one or two unresolved items).
    var isAlmostReady: Bool { self == .missingOne || self == .missingTwo }

    /// Whether this tier belongs in "More possibilities" (missing three or more).
    var isMorePossibilities: Bool { self == .missingMany }

    /// Short, non-color status label for chips and VoiceOver.
    var statusLabel: String {
        switch self {
        case .exact:           return "Ready now"
        case .readyWithSwap:   return "Ready with a swap"
        case .swapNeedsReview: return "Review substitutions"
        case .missingOne:      return "Missing 1 item"
        case .missingTwo:      return "Missing 2 items"
        case .missingMany:     return "Needs a few more items"
        case .excluded:        return "Not a fit"
        }
    }
}

// MARK: - Per-ingredient resolution detail

/// How a single required ingredient was resolved during classification. Drives
/// the grouped readiness summary ("9 exact · 1 substitution · 1 missing") and
/// the Kitchen Check / Recipe Detail ingredient rows.
nonisolated struct IngredientResolution: Identifiable, Sendable, Equatable {
    enum Status: Sendable, Equatable {
        /// Found in inventory by name.
        case inStock
        /// Not in stock directly, but a valid substitute is in stock and
        /// confirmed for the session (or needs no review).
        case substituted(with: String)
        /// A valid substitute is in stock but the user must review it first.
        case substituteNeedsReview(suggestion: String)
        /// Not resolvable — no stock, no in-stock substitute.
        case missing
        /// Optional ingredient (or a pantry item the recipe marks optional).
        case optional
    }

    var id: String { name.lowercased() }
    let name: String
    let amount: String          // human-readable display amount (already source-of-truth)
    let status: Status

    var isUnresolvedRequired: Bool {
        switch status {
        case .missing:                    return true
        case .substituteNeedsReview:      return false // resolvable, just needs a tap
        case .inStock, .substituted, .optional: return false
        }
    }
}

// MARK: - Classified recipe

/// A recipe plus its full Cook Now classification. Value type, Sendable, so it
/// can be produced off-main and handed to the UI.
nonisolated struct ClassifiedRecipe: Identifiable, Sendable, Equatable {
    let recipe: UserRecipe
    let readiness: CookNowReadiness
    let resolutions: [IngredientResolution]

    var id: UUID { recipe.id }

    /// Count of required ingredients found directly in stock.
    var exactCount: Int { resolutions.filter { if case .inStock = $0.status { return true }; return false }.count }
    /// Count of required ingredients satisfied by a confirmed/needed-no-review substitute.
    var substitutionCount: Int {
        resolutions.filter { if case .substituted = $0.status { return true }; return false }.count
    }
    /// Count of substitutes still awaiting user review.
    var reviewCount: Int {
        resolutions.filter { if case .substituteNeedsReview = $0.status { return true }; return false }.count
    }
    /// Count of unresolved required ingredients (the "missing" number).
    var missingCount: Int { resolutions.filter { if case .missing = $0.status { return true }; return false }.count }

    /// The unresolved required ingredient names, for grocery + missing-item UI.
    var missingNames: [String] {
        resolutions.compactMap { if case .missing = $0.status { return $0.name }; return nil }
    }

    /// Grouped one-line readiness summary, e.g. "9 exact · 1 substitution · 1 missing".
    /// Only non-zero groups are shown, so it stays honest and compact.
    var groupedSummary: String {
        var parts: [String] = []
        if exactCount > 0 { parts.append("\(exactCount) exact") }
        if substitutionCount > 0 { parts.append("\(substitutionCount) substitution\(substitutionCount == 1 ? "" : "s")") }
        if reviewCount > 0 { parts.append("\(reviewCount) to review") }
        if missingCount > 0 { parts.append("\(missingCount) missing") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Dashboard metrics

/// The aggregate numbers the Direction B dashboard renders. All derived from
/// real classification — never hardcoded.
nonisolated struct CookNowMetrics: Sendable, Equatable {
    var exactReady: Int = 0            // recipes at .exact
    var readyWithSwaps: Int = 0        // recipes at .readyWithSwap
    var almostReady: Int = 0           // recipes at .missingOne or .missingTwo
    var morePossibilities: Int = 0     // recipes at .missingMany

    /// Total shown in the big "meals ready" number: exact + confirmed swaps.
    var readyNowTotal: Int { exactReady + readyWithSwaps }

    /// Breakdown line, e.g. "8 exact · 4 with substitutions". Empty when there
    /// is nothing to break down.
    var readyBreakdown: String {
        guard readyNowTotal > 0 else { return "" }
        if readyWithSwaps == 0 { return "\(exactReady) exact" }
        if exactReady == 0 { return "\(readyWithSwaps) with substitutions" }
        return "\(exactReady) exact · \(readyWithSwaps) with substitutions"
    }

    /// Which adaptive dashboard state to render. The dashboard changes emphasis
    /// rather than showing the same layout with zeros.
    enum Emphasis: Sendable, Equatable {
        case emptyInventory       // nothing logged at all
        case readyAndAlmost       // normal two-metric dashboard
        case almostOnly           // Ready now is zero; lead with Almost ready
        case morePossibilitiesOnly// both primary categories zero; build-toward
        case noMatches            // nothing at all after all filters
    }
}

// MARK: - Engine

/// Stateless classifier. Construct once per computation with the current
/// snapshot; it holds only precomputed lookup tables for that snapshot.
nonisolated struct CookNowEngine: Sendable {

    // Snapshot inputs
    private let recipes: [UserRecipe]
    private let inventoryNames: [String]           // in-stock item names (effectiveLevel > 0)
    private let allergens: [String]                // active, non-empty
    private let dislikes: [String]                 // household member dislikes/allergies, non-empty
    private let confirmedSubs: Set<String>         // session-confirmed "ingredient→substitute" keys

    /// A precomputed lowercased in-stock set for fast membership.
    private let inStockLower: [String]

    /// - Parameters:
    ///   - recipes: the catalog to classify (typically store.cookCatalog).
    ///   - inStockNames: names of inventory items considered available.
    ///   - allergens: active allergen words to exclude on (empty disables).
    ///   - dislikes: household dislike/allergy words to exclude on (empty disables).
    ///   - confirmedSubstitutions: set of "ingredient::substitute" keys the user
    ///     approved for this session (see `substitutionKey`).
    init(recipes: [UserRecipe],
         inStockNames: [String],
         allergens: [String] = [],
         dislikes: [String] = [],
         confirmedSubstitutions: Set<String> = []) {
        self.recipes = recipes
        self.inventoryNames = inStockNames
        self.inStockLower = inStockNames.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        self.allergens = allergens.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 }
        self.dislikes = dislikes.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 }
        self.confirmedSubs = confirmedSubstitutions
    }

    // MARK: Name matching (local copy of the store's loose match, kept private
    // here so the engine is self-contained and the store's private helper is
    // not widened — mirrors the codebase's pattern of local matching helpers).

    private static func looseMatch(_ a: String, _ b: String) -> Bool {
        let na = a.lowercased().trimmingCharacters(in: .whitespaces)
        let nb = b.lowercased().trimmingCharacters(in: .whitespaces)
        guard na.count > 2, nb.count > 2 else { return na == nb }
        return na.contains(nb) || nb.contains(na)
    }

    private func nameInStock(_ ingredient: String) -> Bool {
        inStockLower.contains { Self.looseMatch(ingredient, $0) }
    }

    /// Stable key for a confirmed substitution decision.
    static func substitutionKey(ingredient: String, substitute: String) -> String {
        "\(ingredient.lowercased().trimmingCharacters(in: .whitespaces))::\(substitute.lowercased().trimmingCharacters(in: .whitespaces))"
    }

    // MARK: Substitute resolution

    /// The engine cannot reach the store's `inStockSubstitutes`, so it accepts a
    /// resolver closure that returns in-stock substitute names for an ingredient.
    /// Callers pass `store.inStockSubstitutes(for:)`. This keeps the substitution
    /// source of truth in the store/database and avoids duplication.
    typealias SubstituteResolver = @Sendable (String) -> [String]

    // MARK: Exclusion

    private func isExcluded(_ recipe: UserRecipe) -> Bool {
        if !allergens.isEmpty {
            for ing in recipe.ingredients {
                for a in allergens where Self.looseMatch(ing.name, a) { return true }
            }
        }
        if !dislikes.isEmpty {
            for ing in recipe.ingredients {
                for d in dislikes where Self.looseMatch(ing.name, d) { return true }
            }
        }
        return false
    }

    // MARK: Classify one recipe

    /// Classify a single recipe against the snapshot. `resolveSubstitutes`
    /// supplies in-stock substitutes for an ingredient name.
    func classify(_ recipe: UserRecipe, resolveSubstitutes: SubstituteResolver) -> ClassifiedRecipe {
        // Excluded recipes short-circuit — they never appear in readiness metrics.
        if isExcluded(recipe) {
            let res = recipe.ingredients.map { ing in
                IngredientResolution(name: ing.name, amount: ing.amount,
                                     status: ing.isOptional ? .optional : .missing)
            }
            return ClassifiedRecipe(recipe: recipe, readiness: .excluded, resolutions: res)
        }

        var resolutions: [IngredientResolution] = []
        resolutions.reserveCapacity(recipe.ingredients.count)

        for ing in recipe.ingredients {
            if ing.isOptional {
                resolutions.append(.init(name: ing.name, amount: ing.amount, status: .optional))
                continue
            }
            if nameInStock(ing.name) {
                resolutions.append(.init(name: ing.name, amount: ing.amount, status: .inStock))
                continue
            }
            // Not directly in stock — look for an in-stock substitute.
            let subs = resolveSubstitutes(ing.name)
            if let sub = subs.first {
                let key = Self.substitutionKey(ingredient: ing.name, substitute: sub)
                if confirmedSubs.contains(key) {
                    resolutions.append(.init(name: ing.name, amount: ing.amount, status: .substituted(with: sub)))
                } else {
                    resolutions.append(.init(name: ing.name, amount: ing.amount, status: .substituteNeedsReview(suggestion: sub)))
                }
                continue
            }
            resolutions.append(.init(name: ing.name, amount: ing.amount, status: .missing))
        }

        let readiness = tier(for: resolutions)
        return ClassifiedRecipe(recipe: recipe, readiness: readiness, resolutions: resolutions)
    }

    private func tier(for resolutions: [IngredientResolution]) -> CookNowReadiness {
        var missing = 0
        var review = 0
        var substituted = 0
        for r in resolutions {
            switch r.status {
            case .missing:                missing += 1
            case .substituteNeedsReview:  review += 1
            case .substituted:            substituted += 1
            case .inStock, .optional:     break
            }
        }
        if missing == 0 {
            if review > 0 { return .swapNeedsReview }
            if substituted > 0 { return .readyWithSwap }
            return .exact
        }
        if missing == 1 { return .missingOne }
        if missing == 2 { return .missingTwo }
        return .missingMany
    }

    // MARK: Classify the whole catalog

    /// Classify every recipe in the snapshot. Excluded recipes are included in
    /// the returned array (tier `.excluded`) so callers can filter as needed;
    /// they never contribute to metrics.
    func classifyAll(resolveSubstitutes: SubstituteResolver) -> [ClassifiedRecipe] {
        recipes.map { classify($0, resolveSubstitutes: resolveSubstitutes) }
    }

    // MARK: Metrics

    /// Aggregate dashboard metrics from a classified set.
    static func metrics(from classified: [ClassifiedRecipe]) -> CookNowMetrics {
        var m = CookNowMetrics()
        for c in classified {
            switch c.readiness {
            case .exact:            m.exactReady += 1
            case .readyWithSwap:    m.readyWithSwaps += 1
            case .missingOne, .missingTwo: m.almostReady += 1
            case .missingMany:      m.morePossibilities += 1
            case .swapNeedsReview, .excluded: break
            }
        }
        return m
    }

    /// Pick the adaptive dashboard emphasis from metrics + whether inventory is empty.
    static func emphasis(for metrics: CookNowMetrics, inventoryEmpty: Bool) -> CookNowMetrics.Emphasis {
        if inventoryEmpty { return .emptyInventory }
        if metrics.readyNowTotal > 0 { return .readyAndAlmost }
        if metrics.almostReady > 0 { return .almostOnly }
        if metrics.morePossibilities > 0 { return .morePossibilitiesOnly }
        return .noMatches
    }

    // MARK: Ranked lists

    /// All recipes in a tier, in the given order. Excludes `.excluded`.
    static func recipes(in classified: [ClassifiedRecipe], tier: CookNowReadiness) -> [ClassifiedRecipe] {
        classified.filter { $0.readiness == tier }
    }

    /// The recipes to surface under "More possibilities": missing three or more,
    /// sorted by fewest unresolved ingredients first.
    static func morePossibilities(in classified: [ClassifiedRecipe]) -> [ClassifiedRecipe] {
        classified.filter { $0.readiness == .missingMany }
            .sorted { $0.missingCount < $1.missingCount }
    }
}
