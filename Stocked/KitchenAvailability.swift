// KitchenAvailability.swift
// ─────────────────────────────────────────────────────────────────────────────
// THE single authority for "do I have this?" and "how much of this recipe can I
// make?".
//
// WHY THIS FILE EXISTS
// Before this file, the app answered "is this ingredient in stock?" six
// different ways:
//
//   1. CookNowEngine.looseMatch      — two-way substring, count > 2 guard
//   2. GuestDataStore.looseMatch     — byte-identical copy of #1
//   3. RecipeVaultViews.looseMatch   — byte-identical copy of #1
//   4. KitchenStock.isInStock        — two-way substring on a name Set
//   5. SurpriseRecipeEngine.inStock  — two-way substring, local closure
//   6. OnlineRecipeMatch.stockMatch  — FoodNameMatcher score >= 0.72
//
// Substring matching (#1–#5) is far LOOSER than token scoring (#6): "oil"
// satisfies "olive oil", "garlic" satisfies "garlic powder", and any three-char
// collision passes. So the Cook tab (which used #1) over-reported readiness
// while the Recipes tab (which used #6) under-reported it, and the same kitchen
// produced "100% — everything in stock" on one screen and "5 missing" on
// another for comparable recipes.
//
// On top of that the two paths disagreed about the DENOMINATOR: the Cook path
// dropped optional ingredients, the Recipes path counted them.
//
// Everything now routes here. The five substring matchers are kept as thin
// deprecated shims that forward to `nameMatches` so call sites did not have to
// change in one enormous diff, but they no longer carry any logic of their own.
//
// RULES THIS FILE OWNS — change them here and every surface follows:
//   • what counts as a name match           (confidenceThreshold)
//   • what counts as "in stock"             (availableFillFloor)
//   • whether optional ingredients count    (coverage excludes them)
//   • what a coverage fraction means        (Coverage)
//
// Pure, nonisolated, Sendable-safe: callers may run it off the main actor and
// cache the result against the store's revision counters, exactly as
// CookNowCompute and stockMatchCache already do. Nothing here touches the store.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

nonisolated enum KitchenAvailability {

    // MARK: - The rules

    /// Minimum `FoodNameMatcher` score for two food names to be considered the
    /// same thing. 0.72 is the value `FoodMatch.isConfident` already used and
    /// the value the Discover badges shipped with, so adopting it app-wide
    /// tightens the loose paths rather than loosening the strict one.
    static let confidenceThreshold: Double = 0.72

    /// Fill level strictly above which an item is considered available at all.
    /// `IngredientStockMatch` used 0.05, `CookNowCompute` used 0.0, and
    /// `inStockNameSet` used 0.0 on the raw (not effective) level. 0.05 is the
    /// honest one: an item scraped down to a smear is not an ingredient.
    static let availableFillFloor: Double = 0.05

    // MARK: - Name matching

    /// Are these two food names the same thing? Boundary- and synonym-aware.
    ///
    /// This replaces every `looseMatch`/`inStock` substring helper in the app.
    /// It is deliberately stricter than they were: substring containment is
    /// still a strong signal inside `FoodNameMatcher` (it scores 0.88+), but a
    /// bare three-character overlap no longer passes.
    static func nameMatches(_ lhs: String, _ rhs: String) -> Bool {
        FoodNameMatcher.matches(lhs, rhs).score >= confidenceThreshold
    }

    /// Score for callers that want to rank rather than threshold.
    static func matchScore(_ lhs: String, _ rhs: String) -> Double {
        FoodNameMatcher.matches(lhs, rhs).score
    }

    // MARK: - "Do I have this?" against name collections

    /// Is `ingredient` present in a collection of inventory item names?
    /// `names` is expected to already be filtered to available items (see
    /// `availableNames(in:)`).
    static func isPresent(_ ingredient: String, inNames names: some Sequence<String>) -> Bool {
        let parsed = parsedName(ingredient)
        guard !parsed.isEmpty else { return false }
        return names.contains { nameMatches(parsed, $0) }
    }

    /// Is `ingredient` present in the inventory?
    static func isPresent(_ ingredient: String, in items: [LocalInventoryItem]) -> Bool {
        let parsed = parsedName(ingredient)
        guard !parsed.isEmpty else { return false }
        return items.contains { $0.effectiveLevel > availableFillFloor && nameMatches(parsed, $0.name) }
    }

    /// The canonical available-item filter. Every "in stock" list in the app
    /// should start here so they all agree on the fill floor AND on reading
    /// `effectiveLevel` rather than the raw `level` (raw ignores the
    /// expiry-decay adjustment, which is why the Daily Brief used to disagree
    /// with Inventory about what was running low).
    static func availableItems(in items: [LocalInventoryItem]) -> [LocalInventoryItem] {
        items.filter { $0.effectiveLevel > availableFillFloor }
    }

    /// Lowercased names of everything available — the shape `inStockNameSet`,
    /// `KitchenStock`, and the Discover rails all want.
    static func availableNames(in items: [LocalInventoryItem]) -> Set<String> {
        Set(availableItems(in: items).map { $0.name.lowercased() })
    }

    /// Strip quantity/unit/prep noise off a recipe ingredient line so matching
    /// compares food to food. "1 cup all-purpose flour, sifted" → "flour".
    /// Falls back to the raw string when parsing yields nothing.
    static func parsedName(_ ingredientLine: String) -> String {
        let parsed = RecipeIngredients.parse(ingredientLine).name
        let trimmed = parsed.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
            ? ingredientLine.trimmingCharacters(in: .whitespacesAndNewlines)
            : trimmed
    }

    // MARK: - Coverage

    /// How much of a recipe the kitchen covers. One shape, used by the Cook
    /// tab, the Recipes tab, the match ring, Home's meal count, and the
    /// planner — so the number, the ring, and the prose can never disagree.
    ///
    /// `total` counts REQUIRED ingredients only. Optional ingredients are
    /// excluded from both numerator and denominator; a recipe is not "missing"
    /// its garnish.
    nonisolated struct Coverage: Sendable, Equatable {
        let have: Int
        let total: Int
        /// Required ingredient display names still unaccounted for, computed by
        /// the SAME rule that produced `have` — so `missingNames.count` is
        /// always exactly `total - have`. (The previous `RecipeCoverage`
        /// computed these two by different rules and they could disagree.)
        let missingNames: [String]

        var fraction: Double { total > 0 ? Double(have) / Double(total) : 0 }
        var isComplete: Bool { total > 0 && have >= total }
        var missingCount: Int { max(0, total - have) }

        static let empty = Coverage(have: 0, total: 0, missingNames: [])
    }

    /// Coverage for a list of ingredient lines against available item names.
    ///
    /// - Parameters:
    ///   - lines: raw ingredient strings (quantities and prep notes are fine).
    ///   - optionalFlags: parallel array marking optional ingredients. Pass an
    ///     empty array when the caller has no optional information, in which
    ///     case `isOptionalLine` is consulted for the "(optional)" convention.
    ///   - availableNames: lowercased names of available inventory items.
    static func coverage(lines: [String],
                         optionalFlags: [Bool] = [],
                         availableNames: Set<String>) -> Coverage {
        var required: [String] = []
        required.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            let isOptional = index < optionalFlags.count
                ? optionalFlags[index]
                : isOptionalLine(line)
            guard !isOptional else { continue }
            let name = parsedName(line)
            guard !name.isEmpty else { continue }
            required.append(name)
        }

        guard !required.isEmpty else { return .empty }

        var have = 0
        var missing: [String] = []
        for name in required {
            if availableNames.contains(where: { nameMatches(name, $0) }) {
                have += 1
            } else {
                missing.append(name)
            }
        }
        return Coverage(have: have, total: required.count, missingNames: missing)
    }

    /// Does this ingredient line mark itself optional? Mirrors the convention
    /// `IngredientStockMatch.isOptional` already recognises so imported
    /// recipes without a structured flag still behave correctly.
    static func isOptionalLine(_ line: String) -> Bool {
        FoodNameMatcher.anyPhrase(in: line, phrases: optionalPhrases)
    }

    /// Kept in one place so `IngredientStockMatch` and this type cannot drift.
    static let optionalPhrases = ["optional", "for garnish", "to taste", "as needed", "if desired"]

    // MARK: - Thresholds bridge

    /// Is this item running low? One rule, replacing the 0.2 / 0.25 / 0.33
    /// constants that were scattered across the widget, the Daily Brief, the
    /// grocery list, and the inventory sheets.
    ///
    /// Deliberately delegates to `LocalInventoryItem.isLow`, which already
    /// existed and already read `KitchenThresholds.lowFillLevel` — AND folds in
    /// the below-par check. Defining a second rule here, even a correct one,
    /// would recreate exactly the problem this file exists to remove. The value
    /// of this wrapper is discoverability: call sites reaching for an
    /// availability answer find it in one type.
    static func isRunningLow(_ item: LocalInventoryItem) -> Bool {
        item.isLow
    }

    /// Is this item critically low — near-empty rather than merely low? Used by
    /// the widget and notification copy, which want a tighter bar than the
    /// grocery suggestions do.
    static func isCriticallyLow(_ item: LocalInventoryItem) -> Bool {
        item.effectiveLevel > 0 && item.effectiveLevel < KitchenThresholds.criticalFillLevel
    }
}
