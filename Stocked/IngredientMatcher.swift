// IngredientMatcher.swift
// Compatibility facade over FoodNameMatcher for recipe ↔ pantry matching.
import Foundation

nonisolated struct ParsedIngredient: Sendable, Equatable {
    var quantity: Double?
    var unit: String?
    var name: String

    static func parse(_ raw: String) -> ParsedIngredient {
        let parsed = RecipeIngredients.parse(raw)
        let amount = parsed.amount > 0 ? parsed.amount : nil
        let unit = parsed.unit.isEmpty ? nil : parsed.unit
        return ParsedIngredient(quantity: amount, unit: unit,
                                name: IngredientMatcher.canonical(parsed.name.isEmpty ? raw : parsed.name))
    }
}

nonisolated enum IngredientMatcher {
    // Kept public for compatibility with existing reverse-synonym call sites.
    static let synonyms: [String: String] = [
        "chicken breast": "chicken", "chicken thigh": "chicken", "chicken thighs": "chicken",
        "chicken legs": "chicken", "whole chicken": "chicken",
        "ground beef": "beef", "minced beef": "beef", "beef mince": "beef",
        "pork belly": "pork", "pork loin": "pork", "pork chop": "pork",
        "prawns": "shrimp", "king prawns": "shrimp", "tiger prawns": "shrimp",
        "salmon fillet": "salmon", "cod fillet": "cod",
        "spring onion": "green onion", "scallion": "green onion", "shallot": "onion",
        "bell pepper": "pepper", "capsicum": "pepper", "red pepper": "pepper",
        "courgette": "zucchini", "aubergine": "eggplant",
        "rocket": "arugula", "coriander": "cilantro", "fresh coriander": "cilantro",
        "mange tout": "snow peas", "mangetout": "snow peas", "broad beans": "fava beans",
        "double cream": "heavy cream", "whipping cream": "heavy cream", "single cream": "cream",
        "plain yogurt": "yogurt", "natural yogurt": "yogurt", "greek yogurt": "yogurt",
        "cheddar": "cheese", "mozzarella": "cheese", "parmesan": "cheese",
        "plain flour": "all-purpose flour", "self-raising flour": "flour",
        "bicarbonate of soda": "baking soda", "bicarb": "baking soda",
        "caster sugar": "sugar", "icing sugar": "sugar", "granulated sugar": "sugar",
        "rapeseed oil": "vegetable oil", "sunflower oil": "vegetable oil",
        "tinned tomatoes": "canned tomatoes", "chopped tomatoes": "canned tomatoes",
        "stock cube": "broth", "bouillon": "broth"
    ]

    static func canonical(_ raw: String) -> String {
        var normalized = FoodNameMatcher.normalized(raw)
        for (from, to) in synonyms.sorted(by: { $0.key.count > $1.key.count }) {
            if KitchenAvailability.nameMatches(normalized, from) || FoodNameMatcher.containsPhrase(from, in: normalized) {
                normalized = FoodNameMatcher.normalized(to)
                break
            }
        }
        let prepWords: Set<String> = [
            "fresh", "dried", "chopped", "sliced", "minced", "diced", "grated", "shredded",
            "crushed", "peeled", "washed", "cooked", "raw", "frozen", "large", "medium", "small"
        ]
        return FoodNameMatcher.tokens(normalized, droppingStopWords: true)
            .filter { !prepWords.contains($0) }
            .joined(separator: " ")
    }

    static func buildPantrySet(from items: [LocalInventoryItem]) -> Set<String> {
        Set(items.filter { $0.effectiveLevel > 0.15 }.flatMap { item -> [String] in
            let canonicalName = canonical(item.name)
            var values = [canonicalName]
            values.append(contentsOf: FoodNameMatcher.tokens(canonicalName))
            for (source, target) in synonyms where canonical(target) == canonicalName {
                values.append(canonical(source))
            }
            return values.filter { !$0.isEmpty }
        })
    }

    nonisolated struct MatchResult: Sendable, Equatable {
        var score: Int
        var matched: [String]
        var missing: [String]
        var isReady: Bool { score >= 75 }
    }

    static func score(recipeIngredients: [String], pantrySet: Set<String>) -> MatchResult {
        guard !recipeIngredients.isEmpty else { return MatchResult(score: 0, matched: [], missing: []) }
        var matched: [String] = []
        var missing: [String] = []
        for raw in recipeIngredients {
            let name = ParsedIngredient.parse(raw).name
            let found = pantrySet.contains { KitchenAvailability.nameMatches(name, $0) }
            if found { matched.append(name) } else { missing.append(name) }
        }
        let score = Int((Double(matched.count) / Double(recipeIngredients.count)) * 100)
        return MatchResult(score: score, matched: matched, missing: missing)
    }

    static func ingredientFingerprint(_ ingredients: [String]) -> String {
        let value = ingredients.map { ParsedIngredient.parse($0).name }.sorted().joined(separator: "|")
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 { hash ^= UInt64(byte); hash &*= 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}
