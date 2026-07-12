// SurpriseRecipeEngine.swift
// On-device recipe generation — no external API required.
// Uses Apple's NaturalLanguage framework for ingredient parsing and
// a curated recipe template system for generation.
// When Apple releases public Core ML LLM APIs (axolotl / on-device inference),
// the generateWithCoreML() stub below is the integration point.
import SwiftUI
import Combine
import NaturalLanguage

// MARK: - Engine
@Observable
@MainActor
final class SurpriseRecipeEngine {
    nonisolated init() {}
    var isGenerating = false
    var lastRecipe:   GeneratedRecipe?
    var error:        String?

    // MARK: - Public: Surprise Me
    @MainActor
    func generateSurpriseRecipe(from inventoryItems: [LocalInventoryItem],
                                 servings: Int = 2) async -> GeneratedRecipe? {
        isGenerating = true
        error        = nil
        defer { isGenerating = false }

        guard !inventoryItems.isEmpty else {
            error = "Add some items to your inventory first!"
            return nil
        }

        // Run generation on background thread — NL processing can be slow
        let names    = inventoryItems.map { $0.name }
        let recipe   = await Task(priority: .userInitiated) { [names, servings] in
            OnDeviceRecipeGenerator.generate(from: names, servings: servings)
        }.value

        lastRecipe = recipe
        return recipe
    }

    // MARK: - Public: Personalised (For You tab)
    func generatePersonalisedRecipe(inventory: [String],
                                    preferences: String,
                                    servings: Int) async -> GeneratedRecipe? {
        isGenerating = true
        error        = nil
        defer { isGenerating = false }

        let recipe = await Task(priority: .userInitiated) { [inventory, preferences, servings] in
            OnDeviceRecipeGenerator.generatePersonalised(
                inventory:   inventory,
                preferences: preferences,
                servings:    servings
            )
        }.value

        lastRecipe = recipe
        return recipe
    }

    // MARK: - Core ML stub (integration point for Apple axolotl / on-device LLM)
    // When Apple's on-device LLM APIs become publicly available, replace
    // OnDeviceRecipeGenerator calls above with this method.
    @available(*, unavailable, message: "Awaiting Apple public Core ML LLM API")
    private func generateWithCoreML(prompt: String) async -> String? {
        // Future: MLModel.load("RecipeGenerator") → run inference → return text
        return nil
    }

    // MARK: - Local fallback (called by other parts of the app)
    func localFallbackRecipe(inventory: [LocalInventoryItem], servings: Int) -> GeneratedRecipe {
        OnDeviceRecipeGenerator.generate(from: inventory.map(\.name), servings: servings)
    }

    // MARK: - Image placeholder helper
    // Returns an empty string — callers fall through to AsyncFoodImage's emoji placeholder.
    // (source.unsplash.com was deprecated by Unsplash in 2022 and requires attribution.)
    func unsplashURL(for title: String) -> String { "" }
}

// MARK: - On-Device Recipe Generator
// Pure Swift — no network, no API key, works fully offline.
// Uses NaturalLanguage lemmatisation to match ingredients to recipe categories.
struct OnDeviceRecipeGenerator {

    // MARK: Entry points
    // #9: CPU work on background thread — never blocks main
    nonisolated static func generate(from inventory: [String], servings: Int) -> GeneratedRecipe {
        let parsed    = parseIngredients(inventory)
        let template  = selectTemplate(for: parsed)
        return buildRecipe(template: template, parsed: parsed, servings: servings, preferences: nil)
    }

    nonisolated static func generatePersonalised(inventory: [String],
                                     preferences: String,
                                     servings: Int) -> GeneratedRecipe {
        let parsed    = parseIngredients(inventory)
        let template  = selectPersonalisedTemplate(for: parsed, preferences: preferences)
        return buildRecipe(template: template, parsed: parsed, servings: servings, preferences: preferences)
    }

    // ── Profile-aware generation ──────────────────────────────────────
    // Filters templates by skill level, cook time, and available equipment.
    // Called by the Surprise Me button when a completed profile is available.
    nonisolated static func generateWithProfile(inventory: [String],
                                                profile: UserCookingProfile,
                                                servings: Int) -> GeneratedRecipe {
        let parsed    = parseIngredients(inventory)
        var templates: [RecipeTemplate] = RecipeTemplate.allCases

        // Filter by skill level — map template cases to complexity
        let skillLimit: [String: Int] = ["Beginner": 1, "Home Cook": 2,
                                          "Confident Cook": 3, "Advanced": 4, "Chef Level": 5]
        let userSkill = skillLimit[profile.skillLevel] ?? 2
        // Template difficulty — use switch instead of Dictionary (no Hashable needed)
        func complexity(_ t: RecipeTemplate) -> Int {
            switch t {
            case .proteinGrainBowl, .pastaVeggie, .roastedVeggies: return 1
            case .stirFry, .simpleProtein, .cheesyBake: return 2
            case .chefSurprise: return 3
            }
        }
        templates = templates.filter { complexity($0) <= userSkill }

        // Filter by cook time — use switch instead of Set (no Hashable needed)
        if profile.weeklyMealCount >= 5 {
            templates = templates.filter { t in
                switch t {
                case .proteinGrainBowl, .stirFry, .pastaVeggie, .simpleProtein: return true
                default: return false
                }
            }
        }

        // Filter by equipment — use switch instead of Dictionary
        let hasEquipment = profile.cookingEquipment.map { $0.lowercased() }
        templates = templates.filter { t in
            switch t {
            case .stirFry: return hasEquipment.contains("wok")
            default: return true
            }
        }

        // Filter by dietary style — use switch instead of == comparison
        let diet = profile.dietaryStyle.lowercased()
        if diet.contains("vegan") || diet.contains("vegetarian") {
            templates = templates.filter { t in
                switch t {
                case .pastaVeggie, .roastedVeggies, .proteinGrainBowl: return true
                default: return false
                }
            }
        }

        // Pick best-matching template or fall back to unprofiled
        // Pick best template from filtered pool, fall back to default if pool is empty
        let template = templates.isEmpty
            ? selectPersonalisedTemplate(for: parsed, preferences: profile.dietaryStyle)
            : templates.randomElement() ?? selectPersonalisedTemplate(for: parsed, preferences: profile.dietaryStyle)
        return buildRecipe(template: template, parsed: parsed, servings: servings,
                           preferences: profile.dietaryStyle)
    }

    private nonisolated static func extractMins(_ s: String) -> Int? {
        let t = s.lowercased()
        var total = 0; var found = false
        if let m = t.range(of: #"(\d+)\s*h"#, options: .regularExpression) {
            if let n = Int(String(t[m]).filter(\.isNumber)) { total += n * 60; found = true }
        }
        if let m = t.range(of: #"(\d+)\s*m"#, options: .regularExpression) {
            if let n = Int(String(t[m]).filter(\.isNumber)) { total += n; found = true }
        }
        return found ? total : nil
    }

    // MARK: Ingredient parsing using NaturalLanguage
    nonisolated struct ParsedIngredients: Sendable {
        var proteins:  [String] = []
        var produce:   [String] = []
        var dairy:     [String] = []
        var grains:    [String] = []
        var pantry:    [String] = []
        var all:       [String] = []
    }

    nonisolated static func parseIngredients(_ items: [String]) -> ParsedIngredients {
        var result = ParsedIngredients()
        result.all = items

        let tagger = NLTagger(tagSchemes: [.lemma])

        for item in items {
            let lower = item.lowercased()

            // Proteins
            if containsAny(lower, ["chicken","beef","pork","fish","shrimp","salmon","tuna",
                                   "lamb","turkey","egg","tofu","tempeh","cod","tilapia",
                                   "scallop","crab","lobster","bacon","ham","sausage"]) {
                result.proteins.append(item)
                continue
            }
            // Produce
            if containsAny(lower, ["spinach","broccoli","carrot","pepper","onion","garlic",
                                   "mushroom","tomato","zucchini","potato","lettuce","kale",
                                   "celery","cucumber","corn","pea","bean","asparagus",
                                   "avocado","apple","lemon","lime","orange","berry",
                                   "banana","mango","ginger"]) {
                result.produce.append(item)
                continue
            }
            // Dairy
            if containsAny(lower, ["milk","cheese","butter","cream","yogurt","mozzarella",
                                   "cheddar","parmesan","ricotta","brie","feta"]) {
                result.dairy.append(item)
                continue
            }
            // Grains
            if containsAny(lower, ["rice","pasta","bread","flour","oat","quinoa","couscous",
                                   "noodle","tortilla","pita","bagel"]) {
                result.grains.append(item)
                continue
            }
            // Use NL lemmatiser for anything not caught by keywords
            tagger.string = item
            let lemma = tagger.tag(at: item.startIndex, unit: .word, scheme: .lemma).0?.rawValue ?? lower
            if containsAny(lemma, ["sauce","oil","vinegar","broth","stock","syrup","honey",
                                   "sugar","salt","spice","herb","pepper"]) {
                result.pantry.append(item)
            }
        }
        return result
    }

    nonisolated static func containsAny(_ string: String, _ keywords: [String]) -> Bool {
        keywords.contains { string.contains($0) }
    }

    // MARK: Template selection
    nonisolated static func selectTemplate(for parsed: ParsedIngredients) -> RecipeTemplate {
        // Match to best template based on what's available
        let hasProtein = !parsed.proteins.isEmpty
        let hasProduce = !parsed.produce.isEmpty
        let hasGrains  = !parsed.grains.isEmpty
        let hasDairy   = !parsed.dairy.isEmpty

        if hasProtein && hasGrains  { return .proteinGrainBowl }
        if hasProtein && hasProduce { return .stirFry }
        if hasProtein               { return .simpleProtein }
        if hasProduce && hasGrains  { return .pastaVeggie }
        if hasDairy && hasGrains    { return .cheesyBake }
        if hasProduce               { return .roastedVeggies }
        return .chefSurprise
    }

    nonisolated static func selectPersonalisedTemplate(for parsed: ParsedIngredients,
                                                   preferences: String) -> RecipeTemplate {
        let prefs = preferences.lowercased()

        if prefs.contains("italian") || prefs.contains("pasta") { return .pastaVeggie }
        if prefs.contains("asian") || prefs.contains("quick")   { return .stirFry }
        if prefs.contains("comfort")                            { return .cheesyBake }
        if prefs.contains("healthy") || prefs.contains("light") { return .roastedVeggies }

        return selectTemplate(for: parsed)
    }

    // MARK: Recipe building
    nonisolated static func buildRecipe(template: RecipeTemplate,
                                    parsed: ParsedIngredients,
                                    servings: Int,
                                    preferences: String?) -> GeneratedRecipe {
        let protein = parsed.proteins.first ?? "chicken"
        let veggie  = parsed.produce.first  ?? "mixed vegetables"
        let grain   = parsed.grains.first   ?? "rice"
        let dairy   = parsed.dairy.first    ?? "cheese"

        let data = template.recipeData(
            protein:   protein,
            veggie:    veggie,
            grain:     grain,
            dairy:     dairy,
            servings:  servings,
            inventory: Set(parsed.all.map { $0.lowercased() })
        )

        return GeneratedRecipe(
            title:              data.title,
            cookTime:           data.cookTime,
            servings:           servings,
            difficulty:         data.difficulty,
            ingredients:        data.ingredients,
            steps:              data.steps,
            tips:               data.tip,
            mealCategory:       data.category,
            missingIngredients: data.ingredients.filter { !$0.inStock }.map { $0.name },
            imageURL:           "",  // no stored URL → AsyncFoodImage renders emoji placeholder
            source:             .surprise
        )
    }
}

// MARK: - Recipe Templates
enum RecipeTemplate: CaseIterable, Hashable, Sendable {
    case stirFry, proteinGrainBowl, simpleProtein, pastaVeggie,
         cheesyBake, roastedVeggies, chefSurprise

    struct RecipeData {
        var title:       String
        var cookTime:    String
        var difficulty:  String
        var category:    String
        var imageQuery:  String
        var tip:         String
        var ingredients: [RecipeIngredientLine]
        var steps:       [String]
    }

    nonisolated func recipeData(protein: String, veggie: String, grain: String,
                    dairy: String, servings: Int, inventory: Set<String>) -> RecipeData {

        func inStock(_ name: String) -> Bool {
            inventory.contains(where: { $0.contains(name.lowercased()) || name.lowercased().contains($0) })
        }
        func ing(_ amount: String, _ name: String) -> RecipeIngredientLine {
            RecipeIngredientLine(amount: amount, name: name, inStock: inStock(name))
        }

        switch self {
        case .stirFry:
            return RecipeData(
                title:      "\(protein.capitalized) Stir Fry",
                cookTime:   "20 min", difficulty: "Easy", category: "Asian",
                imageQuery: "stir+fry,asian+food",
                tip:        "High heat is the secret — get the pan very hot before adding anything.",
                ingredients: [
                    ing("\(servings * 150)g", protein),
                    ing("2 cups", veggie),
                    ing("3 cloves", "garlic"),
                    ing("2 tbsp", "soy sauce"),
                    ing("1 tbsp", "sesame oil"),
                    ing("1 tsp", "ginger"),
                    ing("2 tbsp", "vegetable oil"),
                ],
                steps: [
                    "Slice \(protein) into thin strips and season lightly with salt and pepper.",
                    "Heat vegetable oil in a wok or large skillet over high heat until smoking.",
                    "Add \(protein) and cook 3–4 minutes without stirring to get colour. Remove and set aside.",
                    "Add garlic and ginger to the same pan, stir 30 seconds.",
                    "Add \(veggie) and stir-fry 3 minutes until just tender.",
                    "Return \(protein), add soy sauce and sesame oil, toss everything together.",
                    "Serve immediately over \(grain) or noodles."
                ]
            )

        case .proteinGrainBowl:
            return RecipeData(
                title:      "\(protein.capitalized) & \(grain.capitalized) Bowl",
                cookTime:   "30 min", difficulty: "Easy", category: "Bowl",
                imageQuery: "grain+bowl,healthy+food",
                tip:        "Season your grain with a pinch of salt in the cooking water for better flavour.",
                ingredients: [
                    ing("\(servings * 150)g", protein),
                    ing("1 cup", grain),
                    ing("1 cup", veggie),
                    ing("2 tbsp", "olive oil"),
                    ing("1 tsp", "garlic powder"),
                    ing("Salt and pepper", "to taste"),
                ],
                steps: [
                    "Cook \(grain) according to package directions. Season with salt.",
                    "Season \(protein) with garlic powder, salt, and pepper.",
                    "Heat olive oil in a skillet over medium-high heat.",
                    "Cook \(protein) \(proteinCookTime(protein)) until cooked through.",
                    "In the same pan, sauté \(veggie) 3–4 minutes.",
                    "Assemble bowls: grain base, \(veggie), then \(protein) on top.",
                    "Drizzle with olive oil and any desired sauce."
                ]
            )

        case .simpleProtein:
            return RecipeData(
                title:      "Pan-Seared \(protein.capitalized)",
                cookTime:   "25 min", difficulty: "Easy", category: "Main",
                imageQuery: "pan+seared,protein+dish",
                tip:        "Pat protein dry before cooking — moisture is the enemy of a good sear.",
                ingredients: [
                    ing("\(servings * 200)g", protein),
                    ing("2 tbsp", "olive oil"),
                    ing("2 cloves", "garlic"),
                    ing("1 tbsp", "butter"),
                    ing("Fresh herbs", "to taste"),
                    ing("Salt and pepper", "to taste"),
                ],
                steps: [
                    "Pat \(protein) dry with paper towels. Season generously with salt and pepper.",
                    "Heat olive oil in a heavy skillet over medium-high heat.",
                    "Add \(protein) and cook undisturbed \(proteinCookTime(protein)).",
                    "Flip, add butter and garlic, baste with the butter for 2 minutes.",
                    "Rest 5 minutes before slicing.",
                    "Serve with your choice of sides."
                ]
            )

        case .pastaVeggie:
            return RecipeData(
                title:      "\(veggie.capitalized) Pasta",
                cookTime:   "25 min", difficulty: "Easy", category: "Italian",
                imageQuery: "pasta,italian+food",
                tip:        "Reserve a cup of pasta water — the starchy water helps sauce cling to pasta.",
                ingredients: [
                    ing("300g", "pasta"),
                    ing("2 cups", veggie),
                    ing("3 cloves", "garlic"),
                    ing("¼ cup", "olive oil"),
                    ing("½ cup", "parmesan"),
                    ing("Salt and pepper", "to taste"),
                    ing("Red pepper flakes", "to taste"),
                ],
                steps: [
                    "Cook pasta in heavily salted boiling water until al dente. Reserve 1 cup pasta water.",
                    "While pasta cooks, heat olive oil in a large skillet over medium heat.",
                    "Add garlic and red pepper flakes, cook 1 minute.",
                    "Add \(veggie) and cook 4–5 minutes until tender.",
                    "Add drained pasta to the skillet with a splash of pasta water.",
                    "Toss everything together, adding more pasta water to reach desired consistency.",
                    "Finish with parmesan, adjust seasoning, and serve."
                ]
            )

        case .cheesyBake:
            return RecipeData(
                title:      "Baked \(protein.capitalized) with \(dairy.capitalized)",
                cookTime:   "40 min", difficulty: "Medium", category: "Comfort",
                imageQuery: "cheesy+bake,comfort+food",
                tip:        "Let the dish rest 5 minutes after baking — it continues cooking and sets up better.",
                ingredients: [
                    ing("\(servings * 150)g", protein),
                    ing("1 cup", dairy),
                    ing("1 cup", veggie),
                    ing("2 tbsp", "butter"),
                    ing("1 tsp", "garlic powder"),
                    ing("Salt and pepper", "to taste"),
                ],
                steps: [
                    "Preheat oven to 200°C / 400°F.",
                    "Season \(protein) with garlic powder, salt, and pepper.",
                    "Place in a baking dish with \(veggie) scattered around.",
                    "Dot with butter and top generously with \(dairy).",
                    "Bake 25–30 minutes until golden and cooked through.",
                    "Rest 5 minutes and serve hot."
                ]
            )

        case .roastedVeggies:
            let extraVeg = "mixed herbs"
            return RecipeData(
                title:      "Roasted \(veggie.capitalized) Platter",
                cookTime:   "35 min", difficulty: "Easy", category: "Vegetarian",
                imageQuery: "roasted+vegetables,vegetarian",
                tip:        "Don't crowd the pan — vegetables need space to roast, not steam.",
                ingredients: [
                    ing("3 cups", veggie),
                    ing("3 tbsp", "olive oil"),
                    ing("4 cloves", "garlic"),
                    ing("1 tsp", extraVeg),
                    ing("Salt and pepper", "to taste"),
                ],
                steps: [
                    "Preheat oven to 220°C / 425°F. Line a large baking sheet.",
                    "Cut \(veggie) into even pieces so they cook at the same rate.",
                    "Toss with olive oil, garlic, herbs, salt, and pepper.",
                    "Spread in a single layer — do not overlap.",
                    "Roast 25–30 minutes, flipping halfway, until golden and caramelised.",
                    "Serve as a side or over grain for a complete meal."
                ]
            )

        case .chefSurprise:
            return RecipeData(
                title:      "Chef's Kitchen Surprise",
                cookTime:   "30 min", difficulty: "Medium", category: "Fusion",
                imageQuery: "creative+cooking,fusion+food",
                tip:        "Trust your instincts — cooking is about tasting and adjusting as you go.",
                ingredients: [
                    ing("As needed", protein.isEmpty ? "pantry staples" : protein),
                    ing("2 cups", veggie.isEmpty ? "mixed vegetables" : veggie),
                    ing("2 tbsp", "olive oil"),
                    ing("3 cloves", "garlic"),
                    ing("Salt and pepper", "to taste"),
                ],
                steps: [
                    "Gather everything you have and lay it out — inspiration comes from looking at your ingredients.",
                    "Heat olive oil in a large pan over medium heat.",
                    "Start with aromatics: garlic, onion, or ginger if you have them.",
                    "Add heartier ingredients first (proteins, root vegetables), then delicate ones last.",
                    "Season as you go — taste frequently.",
                    "Finish with a squeeze of citrus or a drizzle of good oil to brighten the dish."
                ]
            )
        }
    }

    nonisolated private func proteinCookTime(_ protein: String) -> String {
        let lower = protein.lowercased()
        if lower.contains("shrimp") || lower.contains("scallop") { return "2 minutes per side" }
        if lower.contains("fish") || lower.contains("salmon")    { return "3–4 minutes per side" }
        if lower.contains("egg")                                  { return "3 minutes" }
        return "4–5 minutes per side"
    }
}

// Free function for use outside enum
nonisolated private func proteinCookTime(_ protein: String) -> String {
    let lower = protein.lowercased()
    if lower.contains("shrimp") || lower.contains("scallop") { return "2 minutes per side" }
    if lower.contains("fish") || lower.contains("salmon")    { return "3–4 minutes per side" }
    if lower.contains("egg")                                  { return "3 minutes" }
    return "4–5 minutes per side"
}

#Preview("Recipe Engine") {
    ZStack {
        Color.stockedBg.ignoresSafeArea()
        VStack(spacing: 20) {
            Text("On-Device Recipe Engine")
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(.primary)
            Text("Generates recipes locally.\nNo network required.")
                .font(.system(size: 14))
                .foregroundStyle(Color.primary.opacity(0.5))
                .multilineTextAlignment(.center)
        }
        .padding(40)
    }
}
