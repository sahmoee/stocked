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

enum RecipeGeneratorAI {

    /// Whether the Worker endpoint is configured. (Does not guarantee the recipeIdea branch is
    /// deployed; a missing branch simply yields nil at call time.)
    static var isAvailable: Bool { StockedWorkerClient.isConfigured }

    /// Constraints the user can attach to a request. All optional.
    struct Options {
        var haveItems: [String] = []      // ingredients the user already has
        var dietary: String? = nil        // e.g. "vegetarian", "gluten-free"
        var maxTime: String? = nil        // e.g. "30 minutes"
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
        if !cleanHave.isEmpty { payload["haveItems"] = cleanHave }
        if let d = options.dietary?.trimmingCharacters(in: .whitespaces), !d.isEmpty { payload["dietary"] = d }
        if let t = options.maxTime?.trimmingCharacters(in: .whitespaces), !t.isEmpty { payload["maxTime"] = t }

        guard let responseText = await StockedWorkerClient.completionText(payload: payload, timeout: 40) else {
            Log.app.error("RecipeGeneratorAI: worker returned nothing.")
            return nil
        }
        guard let recipe = parse(responseText) else {
            Log.app.error("RecipeGeneratorAI: worker text didn't parse into a recipe.")
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

        return GeneratedRecipe(
            title: title.isEmpty ? "Untitled Recipe" : title,
            cookTime: cookTime,
            servings: max(1, servings),
            difficulty: difficulty,
            ingredients: lines,
            steps: steps,
            tips: tips
        )
        // source defaults to .generated, which is correct for an AI-generated recipe.
    }

    /// Tolerant JSON object parse: strip code fences, then isolate the outermost {…} and drop
    /// trailing commas before a repair attempt.
    private static func lenientObject(_ text: String) -> [String: Any]? {
        let stripped = text.replacingOccurrences(of: "```json", with: "")
                           .replacingOccurrences(of: "```", with: "")
                           .trimmingCharacters(in: .whitespacesAndNewlines)
        if let o = try? JSONSerialization.jsonObject(with: Data(stripped.utf8)) as? [String: Any] { return o }
        guard let start = stripped.firstIndex(of: "{"),
              let end = stripped.lastIndex(of: "}"), start < end else { return nil }
        var slice = String(stripped[start...end])
        // Drop trailing commas before } or ]
        slice = slice.replacingOccurrences(of: ",\\s*([}\\]])", with: "$1", options: .regularExpression)
        return try? JSONSerialization.jsonObject(with: Data(slice.utf8)) as? [String: Any]
    }
}
