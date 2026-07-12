// IngredientStockMatch.swift
// Shared, smarter ingredient ↔ inventory matching.
//
// Fixes the "2.6 lbs Chicken shows Need to buy while Chicken Breast sits in the
// fridge" class of bug: recipe ingredient strings carry quantities, units, and
// prep words ("5 thinly sliced Onion"), so naive two-way substring matching
// fails. This helper reduces both sides to their food words and matches on
// word overlap instead.
//
// Used by RecipeOverviewView (ingredient list + portions check), the portions
// edit sheet, and StarIngredientRecipesView's pantry-coverage ranking.

import Foundation

nonisolated enum IngredientStockMatch {

    /// Words that describe preparation or state, not the food itself.
    private static let prepWords: Set<String> = [
        "thinly", "finely", "roughly", "coarsely", "freshly", "sliced", "chopped",
        "diced", "minced", "grated", "shredded", "crushed", "peeled", "seeded",
        "trimmed", "cubed", "julienned", "halved", "quartered", "beaten", "melted",
        "softened", "cooked", "uncooked", "boneless", "skinless", "large", "small",
        "medium", "extra", "optional", "taste", "needed", "divided", "plus", "more",
        "about", "approx", "approximately", "packed", "heaping", "level", "ripe",
        "fresh", "frozen", "canned", "drained", "rinsed", "washed", "and", "or",
        "of", "the", "a", "an", "to", "into", "for", "with", "without", "warm",
        "cold", "hot", "room", "temperature",
    ]

    /// Measurement words that survive quantity parsing ("cloves", "cups", …).
    private static let unitWords: Set<String> = [
        "cup", "cups", "tablespoon", "tablespoons", "tbsp", "teaspoon", "teaspoons",
        "tsp", "ounce", "ounces", "oz", "pound", "pounds", "lb", "lbs", "gram",
        "grams", "g", "kg", "kilogram", "kilograms", "ml", "milliliter", "liter",
        "liters", "l", "pinch", "pinches", "dash", "clove", "cloves", "slice",
        "slices", "can", "cans", "piece", "pieces", "bunch", "sprig", "sprigs",
        "stalk", "stalks", "head", "heads", "stick", "sticks", "handful",
    ]

    /// Reduce any string (recipe ingredient line OR inventory item name) to its
    /// significant food words, lowercase. "2.6 lbs Chicken" → ["chicken"];
    /// "5 thinly sliced Onion" → ["onion"]; "Hill Country Fare Garlic" →
    /// ["hill","country","fare","garlic"].
    static func foodWords(_ raw: String) -> [String] {
        // Strip a leading quantity + unit with the app's existing parser first.
        let base = RecipeIngredients.parse(raw).name
        let source = base.isEmpty ? raw : base
        let words = source.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 }
            .filter { !prepWords.contains($0) && !unitWords.contains($0) }
            .filter { Double($0) == nil }
        return words
    }

    /// True when a recipe ingredient line matches an inventory item name.
    /// Matches when any food word of one side appears in the other side's words
    /// (so "chicken" ↔ "chicken breast", "onion" ↔ "sweet onions" both match,
    /// including simple plural/singular differences).
    static func matches(ingredient: String, itemName: String) -> Bool {
        let a = foodWords(ingredient)
        let b = foodWords(itemName)
        guard !a.isEmpty, !b.isEmpty else {
            // Nothing significant survived (e.g. "to taste") — fall back to loose contains.
            let na = ingredient.lowercased(), nb = itemName.lowercased()
            return na.contains(nb) || nb.contains(na)
        }
        func wordHit(_ x: String, _ y: String) -> Bool {
            if x == y { return true }
            // Plural/singular: chicken/chickens, tomato/tomatoes, berry/berries.
            if x + "s" == y || y + "s" == x { return true }
            if x + "es" == y || y + "es" == x { return true }
            if x.hasSuffix("ies") && x.dropLast(3) + "y" == y { return true }
            if y.hasSuffix("ies") && y.dropLast(3) + "y" == x { return true }
            return false
        }
        for wa in a {
            for wb in b where wordHit(wa, wb) { return true }
        }
        return false
    }

    /// First in-stock inventory item matching this ingredient, if any.
    static func firstMatch(ingredient: String,
                           in items: [LocalInventoryItem],
                           minLevel: Double = 0.05) -> LocalInventoryItem? {
        items.first { $0.effectiveLevel > minLevel && matches(ingredient: ingredient, itemName: $0.name) }
    }

    /// Is this ingredient covered by any in-stock item?
    static func inStock(_ ingredient: String,
                        items: [LocalInventoryItem],
                        minLevel: Double = 0.05) -> Bool {
        firstMatch(ingredient: ingredient, in: items, minLevel: minLevel) != nil
    }

    /// The subset of ingredient lines NOT covered by inventory.
    static func missing(_ ingredients: [String],
                        items: [LocalInventoryItem],
                        minLevel: Double = 0.05) -> [String] {
        ingredients.filter { !inStock($0, items: items, minLevel: minLevel) }
    }

    // MARK: - Fast batch path (#PERF)
    // Ranking dozens of recipes against the pantry re-parsed every inventory name
    // for every ingredient of every recipe. Precompute the pantry's word sets once
    // and reuse them for the whole batch; safe to call off the main thread.

    /// Word sets for all sufficiently-stocked inventory items, computed once per batch.
    static func pantryWordSets(_ items: [LocalInventoryItem],
                               minLevel: Double = 0.05) -> [[String]] {
        items.filter { $0.effectiveLevel > minLevel }.map { foodWords($0.name) }
    }

    /// Count of ingredients not covered by the precomputed pantry word sets.
    static func missingCount(_ ingredients: [String], pantryWords: [[String]]) -> Int {
        func wordHit(_ x: String, _ y: String) -> Bool {
            if x == y { return true }
            if x + "s" == y || y + "s" == x { return true }
            if x + "es" == y || y + "es" == x { return true }
            if x.hasSuffix("ies") && x.dropLast(3) + "y" == y { return true }
            if y.hasSuffix("ies") && y.dropLast(3) + "y" == x { return true }
            return false
        }
        var missing = 0
        for ing in ingredients {
            let a = foodWords(ing)
            if a.isEmpty { continue }   // "to taste" etc. — don't count against the cook
            var covered = false
            outer: for b in pantryWords {
                for wa in a {
                    for wb in b where wordHit(wa, wb) { covered = true; break outer }
                }
            }
            if !covered { missing += 1 }
        }
        return missing
    }
}
