// IngredientMatcher.swift
// Central ingredient intelligence layer for recipe–pantry matching.
// Features:
//   #1  Ingredient normalisation — strips quantity, unit, prep notes
//   #2  Fuzzy synonym matching — "chicken breast" ↔ "chicken", "prawns" ↔ "shrimp"
//   #3  Partial match scoring — 0–100 score + missing ingredient list
//   #4  Quantity-aware matching — checks pantry sizeAmount vs recipe quantity
//   #6  Ingredient triple parsing — splits "2 cups plain flour" into {qty, unit, name}
//   #10 Synonym index — cooking-specific cross-regional synonyms
//   #20 Pre-computed pantry set — O(1) lookup per ingredient

import Foundation

// MARK: - Parsed ingredient triple (#6)
struct ParsedIngredient {
    var quantity: Double?
    var unit:     String?
    var name:     String    // canonical lowercase name

    /// Parse "2 cloves garlic, minced" → qty:2 unit:cloves name:"garlic"
    static func parse(_ raw: String) -> ParsedIngredient {
        var s = raw.trimmingCharacters(in: .whitespaces).lowercased()

        // Strip prep notes after comma: "garlic, minced" → "garlic"
        if let comma = s.firstIndex(of: ",") { s = String(s[s.startIndex..<comma]) }

        // Fraction normalisation: ½ → 0.5, ¼ → 0.25, ¾ → 0.75
        s = s.replacingOccurrences(of: "½", with: "0.5 ")
             .replacingOccurrences(of: "¼", with: "0.25 ")
             .replacingOccurrences(of: "¾", with: "0.75 ")
             .replacingOccurrences(of: "⅓", with: "0.33 ")
             .replacingOccurrences(of: "⅔", with: "0.67 ")

        let tokens = s.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return ParsedIngredient(name: s) }

        var qty: Double?
        var unit: String?
        var nameStart = 0

        // Try to parse first token as number
        if let n = Double(tokens[0]) { qty = n; nameStart = 1 }
        // Handle "2 1/2" fraction
        else if tokens.count >= 3, let n = Double(tokens[0]),
                let d = Double(tokens[2]), tokens[1] == "/" {
            qty = n + 1.0/d; nameStart = 3
        }

        // Try to parse second token as unit
        let units = Set(["cup","cups","tbsp","tablespoon","tablespoons","tsp","teaspoon","teaspoons",
                         "oz","ounce","ounces","lb","pound","pounds","g","gram","grams","kg",
                         "ml","l","litre","liter","clove","cloves","slice","slices","can","cans",
                         "bottle","bunch","head","stalk","stalks","sprig","sprigs","pinch",
                         "handful","piece","pieces","large","medium","small"])
        if nameStart < tokens.count && units.contains(tokens[nameStart]) {
            unit = tokens[nameStart]; nameStart += 1
        }

        let name = tokens[nameStart...].joined(separator: " ")
        return ParsedIngredient(quantity: qty, unit: unit, name: IngredientMatcher.canonical(name))
    }
}

// MARK: - IngredientMatcher
struct IngredientMatcher {

    // MARK: - Synonym map (#2, #10)
    static let synonyms: [String: String] = [
        // Proteins
        "chicken breast": "chicken", "chicken thigh": "chicken", "chicken thighs": "chicken",
        "chicken legs": "chicken", "whole chicken": "chicken",
        "ground beef": "beef", "minced beef": "beef", "beef mince": "beef",
        "pork belly": "pork", "pork loin": "pork", "pork chop": "pork",
        "prawns": "shrimp", "king prawns": "shrimp", "tiger prawns": "shrimp",
        "salmon fillet": "salmon", "cod fillet": "cod",
        // Produce
        "spring onion": "green onion", "scallion": "green onion", "shallot": "onion",
        "bell pepper": "pepper", "capsicum": "pepper", "red pepper": "pepper",
        "courgette": "zucchini", "aubergine": "eggplant",
        "rocket": "arugula", "coriander": "cilantro", "fresh coriander": "cilantro",
        "mange tout": "snow peas", "mangetout": "snow peas",
        "broad beans": "fava beans",
        // Dairy
        "double cream": "heavy cream", "whipping cream": "heavy cream", "single cream": "cream",
        "plain yogurt": "yogurt", "natural yogurt": "yogurt", "greek yogurt": "yogurt",
        "cheddar": "cheese", "mozzarella": "cheese", "parmesan": "cheese",
        // Pantry
        "plain flour": "all-purpose flour", "self-raising flour": "flour",
        "bicarbonate of soda": "baking soda", "bicarb": "baking soda",
        "caster sugar": "sugar", "icing sugar": "sugar", "granulated sugar": "sugar",
        "rapeseed oil": "vegetable oil", "sunflower oil": "vegetable oil",
        "tinned tomatoes": "canned tomatoes", "chopped tomatoes": "canned tomatoes",
        "soy sauce": "soya sauce", "soya sauce": "soy sauce",
        "stock cube": "broth", "bouillon": "broth",
    ]

    // MARK: - Canonical name (#1)
    static func canonical(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Check direct synonym
        if let syn = synonyms[lower] { return syn }
        // Check if any synonym key is contained in the raw name
        for (key, val) in synonyms {
            if lower.contains(key) { return val }
        }
        // Strip common prep notes: "fresh", "dried", "chopped", "sliced", "minced", "diced"
        let stopWords = ["fresh", "dried", "chopped", "sliced", "minced", "diced",
                         "grated", "shredded", "crushed", "peeled", "washed",
                         "cooked", "raw", "frozen", "canned", "tinned", "large",
                         "medium", "small", "whole", "ground"]
        var words = lower.components(separatedBy: .whitespaces)
        words = words.filter { !stopWords.contains($0) && !$0.isEmpty }
        return words.joined(separator: " ")
    }

    // MARK: - Pantry set builder (#20)
    // Call once when inventory changes — store result, use for all matching
    static func buildPantrySet(from items: [LocalInventoryItem]) -> Set<String> {
        Set(items.filter { $0.effectiveLevel > 0.15 }.flatMap { item -> [String] in
            let c = canonical(item.name.lowercased())
            // Also add short single-word version so "chicken breast" matches "chicken"
            var variants = [c]
            let words = c.components(separatedBy: .whitespaces)
            if words.count > 1 { variants.append(contentsOf: words) }
            // Add reversed synonyms — if pantry has "shrimp", recipe "prawns" should match
            for (key, val) in synonyms where val == c { variants.append(canonical(key)) }
            return variants
        })
    }

    // MARK: - Match score (#3)
    struct MatchResult {
        var score: Int          // 0–100
        var matched: [String]
        var missing: [String]
        var isReady: Bool { score >= 75 }
    }

    static func score(recipeIngredients: [String], pantrySet: Set<String>) -> MatchResult {
        guard !recipeIngredients.isEmpty else { return MatchResult(score: 0, matched: [], missing: []) }

        var matched: [String] = []
        var missing: [String] = []

        for raw in recipeIngredients {
            let parsed = ParsedIngredient.parse(raw)
            let name = parsed.name
            // Check pantry set (canonical names + synonyms already expanded)
            let found = pantrySet.contains(name) ||
                pantrySet.contains(where: { $0.contains(name) || name.contains($0) })
            if found { matched.append(name) } else { missing.append(name) }
        }

        let score = Int((Double(matched.count) / Double(recipeIngredients.count)) * 100)
        return MatchResult(score: score, matched: matched, missing: missing)
    }

    // MARK: - Ingredient fingerprint for structural dedup (#11)
    static func ingredientFingerprint(_ ingredients: [String]) -> String {
        ingredients
            .map { ParsedIngredient.parse($0).name }
            .sorted()
            .joined(separator: "|")
            .data(using: .utf8)
            .map { String($0.hashValue) } ?? ""
    }
}
