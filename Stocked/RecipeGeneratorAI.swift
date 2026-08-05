// RecipeGeneratorAI.swift
//
// Generates a full recipe from a free-text description (plus optional on-hand ingredients and
// dietary/time constraints) by calling the Stocked Worker with a `recipeIdea` payload. The Worker
// returns the same recipe JSON shape the recipe importer uses, which this parses into a
// GeneratedRecipe ready to save and cook.
//
// Server dependency: this needs the Worker's `recipeIdea` branch, which must be deployed
// (wrangler deploy) for this to return anything. Until then, isAvailable is still true if the
// Worker URL is configured, but calls will fail gracefully (nil).
//
// Reuses StockedWorkerClient (the shared, auth'd, offline-aware gateway). Parsing mirrors the
// importer's lenient approach so a stray code fence or trailing comma doesn't break a good recipe.

import Foundation
import os

nonisolated enum RecipeGeneratorAI {

    /// Whether the Worker endpoint is configured. (Does not guarantee the recipeIdea branch is
    /// deployed; a missing branch simply yields nil at call time.)
    nonisolated static var isAvailable: Bool { StockedWorkerClient.isConfigured }

    /// Constraints the user can attach to a request. All optional.
    nonisolated struct Options: Sendable {
        var haveItems: [String] = []      // ingredients the user already has
        var dietary: String? = nil        // e.g. "vegetarian", "gluten-free"
        var maxTime: String? = nil        // e.g. "30 minutes"
        var cuisinePreference: [String] = []
        var mustUse: [String] = []
        var avoidGeneric: Bool = true
        var minIngredients: Int = 4
        var minSteps: Int = 3
        /// SAFETY: the user's saved allergen/dislike profile. This was MISSING
        /// entirely — the generator only ever saw the free-text `dietary` chip,
        /// so it could compose a recipe around an ingredient the user had
        /// recorded an allergy to, while Cook Now refused that same recipe.
        /// Now sent to the Worker as an explicit constraint AND enforced on the
        /// response, so a model that ignores the instruction is still caught.
        var dietaryRules: DietaryGuard.Rules = .none
    }

    /// Generate a recipe from a description. Returns nil if offline, unconfigured, the Worker
    /// branch isn't deployed, or the response can't be parsed into a usable recipe.
    static func generate(idea rawIdea: String, options: Options = Options()) async -> GeneratedRecipe? {
        let idea = rawIdea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !idea.isEmpty else { return nil }
        guard StockedWorkerClient.isConfigured else {
            Log.app.error("RecipeGeneratorAI: skipped — Worker not configured.")
            return nil
        }

        var payload: [String: Any] = ["recipeIdea": idea]
        let cleanHave = options.haveItems
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Screen the "have" list before it is sent, so an allergen sitting in the
        // pantry is never offered to the model as a building block.
        let safeHave = DietaryGuard.safeIngredients(cleanHave, rules: options.dietaryRules)
        if !safeHave.isEmpty { payload["haveItems"] = safeHave }
        if let d = options.dietary?.trimmingCharacters(in: .whitespaces), !d.isEmpty { payload["dietary"] = d }
        if let constraint = DietaryGuard.promptConstraint(rules: options.dietaryRules) {
            payload["restrictions"] = constraint
            payload["allergens"] = options.dietaryRules.allergens
        }
        if let t = options.maxTime?.trimmingCharacters(in: .whitespaces), !t.isEmpty { payload["maxTime"] = t }
        let cuisinePreference = options.cuisinePreference
            .map { RecipeTaxonomy.canonicalCuisine($0) }
            .filter { $0 != "Other" }
        if !cuisinePreference.isEmpty { payload["cuisinePreference"] = Array(Set(cuisinePreference)).sorted() }
        let mustUse = DietaryGuard.safeIngredients(options.mustUse, rules: options.dietaryRules)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        if !mustUse.isEmpty { payload["mustUse"] = Array(mustUse.prefix(5)) }
        payload["avoidGeneric"] = options.avoidGeneric
        payload["minIngredients"] = max(1, options.minIngredients)
        payload["minSteps"] = max(1, options.minSteps)

        let responseText: String
        do {
            responseText = try await StockedWorkerClient.completionResponse(
                route: .recipeGeneration, payload: payload, timeout: 40
            ).text
        } catch {
            Log.app.error("RecipeGeneratorAI: worker failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard let recipe = parse(responseText) else {
            Log.app.error("RecipeGeneratorAI: worker text didn't parse into a recipe.")
            return nil
        }
        // SAFETY BACKSTOP: never hand back a generated recipe that hits a saved
        // allergen, even if the model ignored the prompt constraint. A model
        // instruction is a request; this is the enforcement.
        let hits = DietaryGuard.allergenHits(ingredientLines: recipe.ingredients.map(\.name),
                                             title: recipe.title,
                                             rules: options.dietaryRules)
        if !hits.isEmpty {
            Log.app.error("RecipeGeneratorAI: discarded a generated recipe that hit a saved allergen.")
            return nil
        }
        return recipe
    }

    // MARK: - Parsing (lenient, mirrors RecipeImportAI)

    /// Parse the Worker's JSON recipe text into a GeneratedRecipe. Tolerant of code fences and a
    /// single wrapping object with trailing commas.
    private static func parse(_ text: String) -> GeneratedRecipe? {
        guard let obj = lenientObject(text) else { return nil }

        func str(_ key: String) -> String {
            if let s = obj[key] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let n = obj[key] as? Int { return String(n) }
            if let d = obj[key] as? Double { return String(d) }
            return ""
        }

        let title = str("title")

        // Ingredients: array of {name, amount} or plain strings.
        var lines: [RecipeIngredientLine] = []
        if let arr = obj["ingredients"] as? [[String: Any]] {
            lines = arr.compactMap { o in
                let name = (o["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let amount = (o["amount"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return RecipeIngredientLine(amount: amount, name: name)
            }
        } else if let arr = obj["ingredients"] as? [String] {
            lines = arr.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { RecipeIngredientLine(amount: "", name: $0) }
        }

        // Steps: prefer "steps", accept "instructions" as a fallback in case the model used it.
        var steps: [String] = []
        if let s = obj["steps"] as? [String] {
            steps = s.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        } else if let s = obj["instructions"] as? [String] {
            steps = s.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }

        // Guard against an empty/garbage response.
        guard !title.isEmpty || !lines.isEmpty || !steps.isEmpty else { return nil }

        let servings = Int(str("servings")) ?? 4
        let difficulty: String = {
            let d = str("difficulty")
            return ["Easy", "Medium", "Hard"].contains(d) ? d : "Medium"
        }()
        let cookTime = str("cookTime").isEmpty ? str("totalTime") : str("cookTime")
        let tips = str("description")
        let recipeTitle = title.isEmpty ? "Untitled Recipe" : title
        let classification = RecipeClassifier.classify(
            title: recipeTitle,
            rawCuisine: str("cuisine"),
            rawCategory: str("category"),
            keywords: [],
            ingredients: lines.map { RecipeIngredient(name: $0.name, amount: $0.amount) },
            instructions: steps
        )

        return GeneratedRecipe(
            title: recipeTitle,
            cookTime: cookTime,
            servings: max(1, servings),
            difficulty: difficulty,
            ingredients: lines,
            steps: steps,
            tips: tips,
            mealCategory: classification.category,
            cuisine: classification.cuisine
        )
        // source defaults to .generated, which is correct for an AI-generated recipe.
    }

    /// Centralized, bounded JSON extraction handles fences, prose, and a trailing comma.
    private static func lenientObject(_ text: String) -> [String: Any]? {
        try? AIResponseDecoder.jsonObject(from: text)
    }

}
