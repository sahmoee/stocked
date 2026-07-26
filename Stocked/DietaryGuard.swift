// DietaryGuard.swift
// ─────────────────────────────────────────────────────────────────────────────
// THE single authority for "is this recipe unsafe or unwanted for this user?".
//
// WHY THIS FILE EXISTS
// Allergen handling was implemented three times, with three different matching
// rules, and one surface had none at all:
//
//   • CookNowEngine.isExcluded      — two-way substring on ingredient names;
//                                     excludes the recipe outright.
//   • OnlineRecipeFacts.allergenHits— FoodNameMatcher.containsPhrase; only
//                                     WARNS, and the Discover filter that acts
//                                     on it is a user-flippable toggle.
//   • SurpriseRecipeEngine          — its own substring closure plus a
//                                     hardcoded dairy/gluten category list.
//   • RecipeGeneratorAI             — nothing. The AI generator accepted a free
//                                     text "dietary" string and never saw the
//                                     saved allergen profile at all, so it
//                                     could invent a recipe built on an
//                                     ingredient the user is allergic to.
//
// Three rules meant a recipe could be excluded from Cook Now and simultaneously
// recommended by Surprise Me. This type gives every surface one answer.
//
// A note on severity: this is the one consolidation in this delta that is a
// safety matter rather than a consistency matter. The rule here is deliberately
// the MOST CAUTIOUS of the three it replaces — it matches on the parsed food
// name AND the raw line AND the title, because a false positive costs the user
// one hidden recipe while a false negative costs them an allergic reaction.
//
// Pure, nonisolated, Sendable-safe.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

nonisolated enum DietaryGuard {

    // MARK: - Normalised rule set

    /// The user's active restrictions, normalised once so callers in hot loops
    /// (Discover rails, classification passes) do not re-clean strings per row.
    nonisolated struct Rules: Sendable, Equatable {
        /// Allergens — hard exclusions. Never merely a warning.
        let allergens: [String]
        /// Household dislikes / preferences — soft exclusions.
        let dislikes: [String]

        var isEmpty: Bool { allergens.isEmpty && dislikes.isEmpty }
        var hasAllergens: Bool { !allergens.isEmpty }

        static let none = Rules(allergens: [], dislikes: [])

        init(allergens: [String], dislikes: [String] = []) {
            self.allergens = DietaryGuard.clean(allergens)
            self.dislikes  = DietaryGuard.clean(dislikes)
        }
    }

    /// Trim, lowercase, and drop entries too short to match safely. A one-letter
    /// allergen would match nearly everything.
    static func clean(_ words: [String]) -> [String] {
        words
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 1 }
    }

    // MARK: - The rule

    /// Does this single ingredient line hit a restriction word?
    ///
    /// Checks three haystacks because each catches something the others miss:
    /// the parsed food name ("flour" out of "2 cups flour, sifted"), the raw
    /// line (catches restriction words living in the prep note, e.g. "brush
    /// with butter"), and — via `containsPhrase` — whole-word boundaries so
    /// "corn" does not fire on "cornstarch"-free text like "peppercorn".
    static func lineHits(_ line: String, restriction: String) -> Bool {
        if FoodNameMatcher.containsPhrase(restriction, in: line) { return true }
        let name = KitchenAvailability.parsedName(line)
        if !name.isEmpty, FoodNameMatcher.containsPhrase(restriction, in: name) { return true }
        return KitchenAvailability.nameMatches(name.isEmpty ? line : name, restriction)
    }

    /// Every allergen this ingredient list or title hits. Empty means clear.
    static func allergenHits(ingredientLines: [String],
                             title: String = "",
                             rules: Rules) -> [String] {
        guard rules.hasAllergens else { return [] }
        var hits: Set<String> = []
        let haystack = title.isEmpty ? ingredientLines : ingredientLines + [title]
        for allergen in rules.allergens
        where haystack.contains(where: { lineHits($0, restriction: allergen) }) {
            hits.insert(allergen)
        }
        return hits.sorted()
    }

    /// Dislike/preference hits. Same rule, softer consequence.
    static func dislikeHits(ingredientLines: [String],
                            title: String = "",
                            rules: Rules) -> [String] {
        guard !rules.dislikes.isEmpty else { return [] }
        var hits: Set<String> = []
        let haystack = title.isEmpty ? ingredientLines : ingredientLines + [title]
        for dislike in rules.dislikes
        where haystack.contains(where: { lineHits($0, restriction: dislike) }) {
            hits.insert(dislike)
        }
        return hits.sorted()
    }

    /// Should this recipe be excluded entirely? True when it hits an allergen
    /// OR a dislike — matching what `CookNowEngine.isExcluded` already did, now
    /// with one rule instead of three.
    static func isExcluded(ingredientLines: [String],
                           title: String = "",
                           rules: Rules) -> Bool {
        guard !rules.isEmpty else { return false }
        if !allergenHits(ingredientLines: ingredientLines, title: title, rules: rules).isEmpty { return true }
        if !dislikeHits(ingredientLines: ingredientLines, title: title, rules: rules).isEmpty { return true }
        return false
    }

    // MARK: - Ingredient-level screening

    /// Filter a candidate ingredient pool down to what is safe to build with —
    /// what Surprise Me and the AI generator need before they compose anything.
    static func safeIngredients(_ names: some Sequence<String>, rules: Rules) -> [String] {
        guard rules.hasAllergens else { return Array(names) }
        return names.filter { name in
            !rules.allergens.contains { lineHits(name, restriction: $0) }
        }
    }

    /// A human-readable instruction for AI prompts, so the Worker's model is
    /// told about restrictions rather than the app filtering after the fact.
    /// Returns nil when there is nothing to say.
    static func promptConstraint(rules: Rules) -> String? {
        guard !rules.isEmpty else { return nil }
        var parts: [String] = []
        if rules.hasAllergens {
            parts.append("must not contain or use as a substitute: " + rules.allergens.joined(separator: ", "))
        }
        if !rules.dislikes.isEmpty {
            parts.append("avoid if possible: " + rules.dislikes.joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
