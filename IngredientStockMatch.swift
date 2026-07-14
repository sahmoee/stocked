// IngredientStockMatch.swift
// Shared boundary-aware and quantity-aware recipe ↔ inventory matching.
import Foundation

nonisolated enum IngredientStockMatch {
    nonisolated enum Availability: Sendable, Equatable {
        case ready
        case low(required: Double, available: Double, unit: String)
        case missing
        case optionalMissing
    }

    nonisolated struct Evaluation: Sendable, Equatable {
        let ingredient: String
        let availability: Availability
        let matchedItemIDs: [UUID]
    }

    static func foodWords(_ raw: String) -> [String] {
        let parsed = RecipeIngredients.parse(raw)
        return FoodNameMatcher.tokens(parsed.name.isEmpty ? raw : parsed.name)
    }

    static func matches(ingredient: String, itemName: String) -> Bool {
        FoodNameMatcher.matches(RecipeIngredients.parse(ingredient).name, itemName).score >= 0.72
    }

    static func firstMatch(ingredient: String,
                           in items: [LocalInventoryItem],
                           minLevel: Double = 0.05) -> LocalInventoryItem? {
        items.filter { $0.effectiveLevel > minLevel }
            .compactMap { item -> (LocalInventoryItem, Double)? in
                let score = FoodNameMatcher.matches(RecipeIngredients.parse(ingredient).name, item.name).score
                return score >= 0.72 ? (item, score) : nil
            }
            .max(by: { $0.1 < $1.1 })?.0
    }

    static func evaluate(_ ingredient: String,
                         items: [LocalInventoryItem],
                         minLevel: Double = 0.05) -> Evaluation {
        let parsed = RecipeIngredients.parse(ingredient)
        let matches = items.filter {
            $0.effectiveLevel > minLevel &&
            FoodNameMatcher.matches(parsed.name.isEmpty ? ingredient : parsed.name, $0.name).score >= 0.72
        }
        let optional = isOptional(ingredient)
        guard !matches.isEmpty else {
            return Evaluation(ingredient: ingredient,
                              availability: optional ? .optionalMissing : .missing,
                              matchedItemIDs: [])
        }

        guard parsed.amount > 0, !parsed.unit.isEmpty else {
            return Evaluation(ingredient: ingredient, availability: .ready, matchedItemIDs: matches.map(\.id))
        }

        let available = matches.reduce(0.0) { total, item in
            guard let size = item.sizeAmount, let unit = item.sizeUnit,
                  let converted = UnitMath.convert(size * Double(max(1, item.quantity)) * item.effectiveLevel,
                                                   from: unit, to: parsed.unit) else { return total }
            return total + converted
        }
        // Structured size is optional. A name match remains ready when no comparable quantity
        // exists; we only show "low" when the app has enough data to make the claim honestly.
        guard available > 0 else {
            return Evaluation(ingredient: ingredient, availability: .ready, matchedItemIDs: matches.map(\.id))
        }
        let state: Availability = available + 0.0001 >= parsed.amount
            ? .ready
            : .low(required: parsed.amount, available: available, unit: parsed.unit)
        return Evaluation(ingredient: ingredient, availability: state, matchedItemIDs: matches.map(\.id))
    }

    static func inStock(_ ingredient: String,
                        items: [LocalInventoryItem],
                        minLevel: Double = 0.05) -> Bool {
        switch evaluate(ingredient, items: items, minLevel: minLevel).availability {
        case .ready: return true
        case .low, .missing, .optionalMissing: return false
        }
    }

    static func missing(_ ingredients: [String],
                        items: [LocalInventoryItem],
                        minLevel: Double = 0.05) -> [String] {
        ingredients.filter {
            switch evaluate($0, items: items, minLevel: minLevel).availability {
            case .missing, .low: return true
            case .ready, .optionalMissing: return false
            }
        }
    }

    static func pantryWordSets(_ items: [LocalInventoryItem],
                               minLevel: Double = 0.05) -> [[String]] {
        items.filter { $0.effectiveLevel > minLevel }.map { foodWords($0.name) }
    }

    static func missingCount(_ ingredients: [String], pantryWords: [[String]]) -> Int {
        ingredients.reduce(into: 0) { count, ingredient in
            guard !isOptional(ingredient) else { return }
            let ingredientName = RecipeIngredients.parse(ingredient).name
            let covered = pantryWords.contains { words in
                FoodNameMatcher.matches(ingredientName, words.joined(separator: " ")).score >= 0.72
            }
            if !covered { count += 1 }
        }
    }

    private static func isOptional(_ ingredient: String) -> Bool {
        FoodNameMatcher.anyPhrase(in: ingredient,
                                  phrases: ["optional", "for garnish", "to taste", "as needed"])
    }
}
