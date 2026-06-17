// NLQueryParser.swift
// ─────────────────────────────────────────────────────────────────────
// Parses natural-language recipe queries into structured filters.
// "Something quick with chicken and no dairy" →
//   ingredients: ["chicken"], maxMinutes: 30, exclude: ["dairy","milk","cream"]
// Used by GlobalSearchView and OnlineRecipesView search.

import Foundation
import NaturalLanguage

struct ParsedQuery {
    var keywords:    [String] = []
    var ingredients: [String] = []
    var exclude:     [String] = []
    var maxMinutes:  Int?     = nil
    var cuisine:     String?  = nil
    var mealType:    String?  = nil   // breakfast, lunch, dinner, snack, dessert

    // Cleaned display string for the search bar
    var displayQuery: String {
        keywords.joined(separator: " ")
    }

    // Whether any filters were extracted beyond raw keywords
    var hasStructure: Bool {
        !ingredients.isEmpty || !exclude.isEmpty || maxMinutes != nil || cuisine != nil || mealType != nil
    }
}

struct NLQueryParser {

    static func parse(_ raw: String) -> ParsedQuery {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        var q    = ParsedQuery()

        // ── Time constraints ────────────────────────────────────────────
        let timePatterns: [(pattern: String, minutes: Int)] = [
            ("under 15 min", 15), ("less than 15 min", 15),
            ("under 20 min", 20), ("less than 20 min", 20),
            ("under 30 min", 30), ("less than 30 min", 30), ("quick", 30), ("fast", 30),
            ("under 45 min", 45), ("under an hour", 60), ("under 1 hour", 60),
        ]
        for (pattern, mins) in timePatterns {
            if text.contains(pattern) { q.maxMinutes = min(q.maxMinutes ?? 999, mins) }
        }

        // ── Exclusions ──────────────────────────────────────────────────
        let dairyWords  = ["dairy","milk","cream","butter","cheese","lactose"]
        let glutenWords = ["gluten","wheat","flour","bread"]
        let meatWords   = ["meat","chicken","beef","pork","fish","seafood","animal"]
        let nutWords    = ["nut","almond","peanut","walnut","cashew"]

        let exclusionMap: [(triggers: [String], excludes: [String])] = [
            (["no dairy","dairy free","dairy-free","lactose free"]+dairyWords.map{"no \($0)"}, dairyWords),
            (["no gluten","gluten free","gluten-free"]+glutenWords.map{"no \($0)"}, glutenWords),
            (["no meat","vegan","vegetarian","meatless","plant based","plant-based"], meatWords),
            (["no nuts","nut free","nut-free"], nutWords),
        ]
        for (triggers, excludes) in exclusionMap {
            if triggers.contains(where: { text.contains($0) }) {
                q.exclude.append(contentsOf: excludes)
            }
        }

        // ── Meal types ──────────────────────────────────────────────────
        let mealTypes = ["breakfast","lunch","dinner","dessert","snack","brunch","appetizer"]
        q.mealType = mealTypes.first { text.contains($0) }

        // ── Cuisines ────────────────────────────────────────────────────
        let cuisines = ["italian","mexican","chinese","japanese","indian","thai","greek",
                        "french","korean","vietnamese","american","mediterranean","middle eastern",
                        "spanish","turkish","moroccan","british","german","cajun","tex-mex"]
        q.cuisine = cuisines.first { text.contains($0) }

        // ── Ingredient extraction using NaturalLanguage ─────────────────
        let knownIngredients = StockedKnowledgeBase.shared.ingredients.map { $0.name.lowercased() }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .lexicalClass) { tag, range in
            if tag == .noun || tag == .adjective {
                let word = String(text[range])
                if knownIngredients.contains(where: { $0.contains(word) || word.contains($0) }), word.count > 2 {
                    if !q.ingredients.contains(word) { q.ingredients.append(word) }
                }
            }
            return true
        }

        // ── Fallback keywords (remove stop words) ───────────────────────
        let stopWords = Set(["something","anything","make","cook","with","and","or","for",
                             "the","a","an","some","any","what","can","i","want","need",
                             "quick","fast","easy","simple","no","not","without","free"])
        q.keywords = text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty && !stopWords.contains($0) && $0.count > 2 }

        return q
    }

    // Apply filters to a recipe entry
    static func matches(_ entry: RecipeDatabaseEntry, query: ParsedQuery) -> Bool {
        // Exclude filter
        let allText = ([entry.title, entry.category, entry.cuisine] + entry.ingredients)
            .joined(separator: " ").lowercased()
        for excl in query.exclude {
            if allText.contains(excl) { return false }
        }
        // Time filter
        if let maxMins = query.maxMinutes {
            let mins = extractMinutes(entry.cookTime) ?? extractMinutes(entry.totalTime) ?? 999
            if mins > maxMins { return false }
        }
        // Cuisine filter
        if let cuisine = query.cuisine {
            if !entry.cuisine.lowercased().contains(cuisine) &&
               !entry.category.lowercased().contains(cuisine) &&
               !entry.tags.contains(where: { $0.lowercased().contains(cuisine) }) { return false }
        }
        // Meal type
        if let meal = query.mealType {
            if !allText.contains(meal) { return false }
        }
        // Keyword match
        for kw in query.keywords {
            if !allText.contains(kw) { return false }
        }
        // Ingredient match
        let matched = query.ingredients.filter { ing in
            entry.ingredients.contains { $0.lowercased().contains(ing) }
        }
        if !query.ingredients.isEmpty && matched.isEmpty { return false }
        return true
    }

    private static func extractMinutes(_ s: String) -> Int? {
        let text = s.lowercased()
        var total = 0
        var found = false
        if let m = text.range(of: #"(\d+)\s*h"#, options: .regularExpression) {
            if let n = Int(text[m].filter(\.isNumber)) { total += n * 60; found = true }
        }
        if let m = text.range(of: #"(\d+)\s*m"#, options: .regularExpression) {
            if let n = Int(text[m].filter(\.isNumber)) { total += n; found = true }
        }
        return found ? total : nil
    }
}
