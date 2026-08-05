// StockedKnowledgeBase.swift
// Single source of truth for all food, recipe, and ingredient knowledge in Stocked.
//
// Replaces direct calls to: IngredientDatabase, NutritionDatabase, RecipeDatabase,
// OfflineRecipeCache, RecipeDatabaseManager, DatabaseSyncBus.
//
// Architecture:
//   StockedKnowledgeBase (@Observable MainActor singleton)
//     ├── Ingredients  — seeded from IngredientDatabase + learns from user activity
//     ├── Recipes      — powered by RecipeDatabase actor + MealDB online sync
//     ├── Nutrition    — seeded from NutritionDatabase + enriched online
//     └── Search       — unified full-text across all sources
//
// Learning:
//   • Every inventory item added → ingredient registered if new
//   • Every recipe saved/cooked → recipe upserted into RecipeDatabase
//   • Every MealDB fetch → merged in via background sync
//   • Search queries tracked → frequency-ranked suggestions
//   • Background refresh every app launch pulls fresh MealDB categories

import Foundation
import SwiftUI
import Combine

// MARK: - KnowledgeIngredient
struct KnowledgeIngredient: Identifiable, Codable, Hashable {
    var id           = UUID()
    var name:        String
    var category:    String
    var emoji:       String
    var searchCount: Int      = 0      // lifetime search count
    var lastSearched: Date?   = nil    // #16: recency decay — recent beats frequent-but-stale
    var addedByUser: Bool     = false  // user-added vs seeded
    var aliases:     [String] = []     // #18: synonyms — "capsicum" = "bell pepper"

    var searchKey: String { name.lowercased() }

    // #16: Recency-weighted score (decays old searches, boosts recent ones)
    var rankScore: Double {
        let frequencyScore = Double(searchCount)
        guard let last = lastSearched else { return frequencyScore * 0.5 }
        let daysSince = Date().timeIntervalSince(last) / 86400
        let recencyBoost = max(0, 30 - daysSince) / 30   // 1.0 today → 0.0 after 30 days
        return frequencyScore + (recencyBoost * 10)
    }
}

// MARK: - StockedKnowledgeBase
@MainActor
@Observable
final class StockedKnowledgeBase {
    static let shared = StockedKnowledgeBase()

    // MARK: State
    var ingredients:  [KnowledgeIngredient] = []

    // #2/#3 — Cached normalized search index for ingredient autocomplete. Rebuilt lazily only
    // when the ingredient set's size changes (search-count updates mutate elements in place
    // and don't affect names). Avoids re-folding every name + alias on each keystroke.
    @ObservationIgnored private var _normNames: [String] = []
    @ObservationIgnored private var _normAliases: [[String]] = []
    @ObservationIgnored private var _normIndexCount: Int = -1
    private func ensureNormIndex() {
        guard _normIndexCount != ingredients.count else { return }
        _normNames   = ingredients.map { DBNormalize.key($0.name) }
        _normAliases = ingredients.map { $0.aliases.map { DBNormalize.key($0) } }
        _normIndexCount = ingredients.count
    }
    private(set) var isRefreshing  = false
    weak var guestStore: GuestDataStore?
    private(set) var lastSyncDate: Date?

    private let ingredientKey  = "kb_ingredients_v1"
    private let syncDateKey    = "kb_lastSync"
    private let recipeDB       = RecipeDatabase.shared

    // MARK: - Init
    private init() {
        loadIngredients()
        seedIfNeeded()
        // Low-priority so the recipe sync/dedupe pipeline can't pin a CPU core (the cause of
        // the CPU-limit termination). Delayed slightly so it never competes with first paint.
        Task(priority: .background) {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await backgroundSync()
        }
    }

    // MARK: - Ingredient Suggestions
    // Primary entry point for FoodPredictiveTextField and GlobalSearchView
    // #16 #18: Sorted by recency-weighted rankScore; aliases matched
    func suggestIngredients(prefix query: String, limit: Int = 8) -> [KnowledgeIngredient] {
        let q = DBNormalize.key(query)
        guard !q.isEmpty else { return [] }
        ensureNormIndex()

        // Single pass over the precomputed normalized names/aliases (#2). Partition into
        // prefix matches (ranked first) and substring matches, then rank each by score.
        var starts: [KnowledgeIngredient] = []
        var contains: [KnowledgeIngredient] = []
        for i in ingredients.indices {
            let name = _normNames[i]
            if name.hasPrefix(q) {
                starts.append(ingredients[i])
            } else if name.contains(q) || _normAliases[i].contains(where: { $0.contains(q) }) {
                contains.append(ingredients[i])
            }
        }
        starts.sort { $0.rankScore > $1.rankScore }
        contains.sort { $0.rankScore > $1.rankScore }
        return Array((starts + contains).prefix(limit))
    }

    // MARK: - Recipe Suggestions
    func suggestRecipes(query: String, limit: Int = 8) async -> [RecipeDatabaseEntry] {
        await recipeDB.search(query, limit: limit)
    }

    func allRecipes(limit: Int = 200) async -> [RecipeDatabaseEntry] {
        await recipeDB.all().prefix(limit).map { $0 }
    }

    // MARK: - Unified Search
    // Returns mixed ingredient + recipe results, ranked by relevance
    func search(query: String) async -> (ingredients: [KnowledgeIngredient], recipes: [RecipeDatabaseEntry]) {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return ([], []) }

        let matchedIngredients = suggestIngredients(prefix: q, limit: 6)
        let matchedRecipes = await recipeDB.search(q, limit: 10)
        return (matchedIngredients, matchedRecipes)
    }

    // MARK: - Learning: Track searches (#16 — recency + frequency)
    func recordSearch(_ term: String) {
        let lower = term.lowercased()
        // Also match aliases (#18)
        if let idx = ingredients.firstIndex(where: {
            $0.name.lowercased() == lower || $0.aliases.contains { $0.lowercased() == lower }
        }) {
            ingredients[idx].searchCount += 1
            ingredients[idx].lastSearched = Date()
            saveIngredients()
        }
    }

    // MARK: - Learning: Register new inventory item (#17 — auto-seeds on every add)
    func learnFromInventoryItem(name: String, category: String = "Other") {
        let lower = name.lowercased()
        // Update existing entry if found (refresh addedByUser flag)
        if let idx = ingredients.firstIndex(where: { $0.name.lowercased() == lower }) {
            if !ingredients[idx].addedByUser {
                ingredients[idx].addedByUser = true
                saveIngredients()
            }
            return
        }
        // #18: Auto-attach known synonyms from the synonym map
        let knownSynonyms = KnowledgeIngredient.synonymMap[lower] ?? []
        var entry = KnowledgeIngredient(
            name:        name,
            category:    category,
            emoji:       emojiFor(name: name, category: category),
            addedByUser: true
        )
        entry.aliases = knownSynonyms
        ingredients.insert(entry, at: 0)
        saveIngredients()
    }

    // MARK: - Learning: Register new recipe
    func learnFromRecipe(_ recipe: UserRecipe) {
        Task { @MainActor in
            let entry = RecipeDatabaseEntry(
                title:       recipe.title,
                description: recipe.description,
                sourceURL:   "",
                sourceName:  "My Recipes",
                prepTime:    recipe.prepTime,
                cookTime:    recipe.cookTime,
                totalTime:   "",
                servings:    "\(recipe.servings)",
                category:    recipe.cuisine,
                cuisine:     recipe.cuisine,
                tags:        recipe.tags,
                ingredients: recipe.ingredients.map { "\($0.amount) \($0.name)".trimmingCharacters(in: .whitespaces) },
                steps:       recipe.instructions,
                imageURL:    recipe.imageURL ?? ""
            )
            await recipeDB.upsert(entry)
        }
    }

    // MARK: - Learning: Register cooked/saved online recipe
    func learnFromOnlineRecipe(_ recipe: OnlineRecipe) {
        Task { @MainActor in
            let entry = RecipeDatabaseEntry(
                title:       recipe.title,
                description: "",
                sourceURL:   "",
                sourceName:  "TheMealDB",
                prepTime:    "", cookTime:    "", totalTime:   "",
                servings:    "4",
                category:    recipe.category,
                cuisine:     recipe.area,
                tags:        [recipe.category, recipe.area].filter { !$0.isEmpty },
                ingredients: recipe.ingredientLines.map { "\($0.measure) \($0.ingredient)".trimmingCharacters(in: .whitespaces) },
                steps:       recipe.instructions.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty },
                imageURL:    recipe.imageURL,
                cachedAt:    Date()
            )
            await recipeDB.upsert(entry)
        }
    }

    // MARK: - Background sync (runs on launch, refreshes recipe DB from MealDB)
    // ── DIAGNOSTIC KILL SWITCH (Build 134) ──────────────────────────────────────
    // All online recipe syncing (MealDB + CocktailDB + Spoonacular) is gated here.
    // Defaulted OFF to isolate the recurring CPU-resource termination: if the iPad stops
    // being terminated with this off, the sync pipeline is the cause. Flip via UserDefaults
    // key "onlineSyncEnabled" = true to re-enable without a rebuild. The app works fully
    // offline from its bundled seed + any recipes already cached — sync only ADDS more.
    static var onlineSyncEnabled: Bool {
        // Absent key → false (OFF by default for this diagnostic build).
        UserDefaults.standard.object(forKey: "onlineSyncEnabled") as? Bool ?? false
    }

    func backgroundSync() async {
        // Diagnostic kill switch: skip ALL online recipe sync unless explicitly enabled.
        guard Self.onlineSyncEnabled else { return }
        guard shouldSync(), !isRefreshing else { return }
        isRefreshing = true
        let categories = ["Beef","Chicken","Seafood","Vegetarian","Pasta",
                          "Dessert","Breakfast","Side","Lamb","Pork","Vegan",
                          "Goat","Miscellaneous"]
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 8
        let session = URLSession(configuration: config)

        await withTaskGroup(of: [RecipeDatabaseEntry].self) { group in
            for cat in categories.shuffled().prefix(6) {
                group.addTask { await self.fetchCategory(cat, session: session) }
            }
            for await entries in group {
                await recipeDB.upsertAll(entries)
            }
        }

        // Sync CocktailDB drinks → ingredients + recipes
        await CocktailDBClient.shared.syncIfNeeded()

        // Sync Spoonacular recipes + ingredients (only if API key configured)
        let diet = await MainActor.run { guestStore?.cookingProfile.dietaryStyle ?? "" }
        await SpoonacularClient.shared.syncIfNeeded(dietaryStyle: diet)

        isRefreshing = false
        lastSyncDate = Date()
        UserDefaults.standard.set(lastSyncDate, forKey: syncDateKey)
    }

    // MARK: - MealDB fetch helpers
    private func fetchCategory(_ category: String, session: URLSession) async -> [RecipeDatabaseEntry] {
        let enc = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? category
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/filter.php?c=\(enc)"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]] else { return [] }

        var results: [RecipeDatabaseEntry] = []
        for meal in meals.shuffled().prefix(3) {
            guard let id = meal["idMeal"] as? String else { continue }
            if let entry = await fetchMealById(id, session: session) {
                results.append(entry)
            }
        }
        return results
    }

    private func fetchMealById(_ id: String, session: URLSession) async -> RecipeDatabaseEntry? {
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/lookup.php?i=\(id)"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]],
              let m = meals.first else { return nil }

        guard let title = m["strMeal"] as? String else { return nil }

        var ingredients: [String] = []
        for i in 1...20 {
            let ing  = (m["strIngredient\(i)"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let meas = (m["strMeasure\(i)"]    as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !ing.isEmpty {
                ingredients.append(meas.isEmpty ? ing : "\(meas) \(ing)")
                // Also register ingredient in knowledge base
                learnFromInventoryItem(name: ing, category: categoryFromMealDBArea(m["strArea"] as? String ?? ""))
            }
        }
        let instructions = m["strInstructions"] as? String ?? ""
        let steps = instructions
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let tags = (m["strTags"] as? String ?? "").components(separatedBy: ",").filter { !$0.isEmpty }
        let classification = RecipeClassifier.classify(
            title: title,
            rawCuisine: m["strArea"] as? String ?? "",
            rawCategory: m["strCategory"] as? String ?? "",
            keywords: tags,
            ingredients: ingredients.map { RecipeIngredient(name: $0, amount: "") },
            instructions: steps
        )

        return RecipeDatabaseEntry(
            title:       title,
            description: "",
            sourceURL:   "",
            sourceName:  "TheMealDB",
            prepTime:    "", cookTime: "", totalTime: "",
            servings:    "4",
            category:    classification.category,
            cuisine:     classification.cuisine,
            tags:        classification.tags + tags,
            ingredients: ingredients,
            steps:       steps,
            imageURL:    m["strMealThumb"] as? String ?? "",
            cachedAt:    Date()
        )
    }

    // MARK: - Persistence (#19: file-backed via LocalDatabase, not UserDefaults)
    // Avoids storing 200KB+ in UserDefaults which Apple recommends against.
    func saveIngredients() {
        LocalDatabase.shared.save(ingredients, key: DBKey.knowledgeBase.rawValue)
    }

    private func loadIngredients() {
        ingredients = LocalDatabase.shared.load([KnowledgeIngredient].self,
                                                key: DBKey.knowledgeBase.rawValue) ?? []
    }

    // MARK: - Seed from static databases on first launch
    private func seedIfNeeded() {
        // Seed from static IngredientDatabase (deduped by lowercased name)
        if ingredients.isEmpty {
            var seen = Set<String>()
            ingredients = IngredientDatabase.all.compactMap { entry in
                let key = entry.name.lowercased()
                guard seen.insert(key).inserted else { return nil }
                return KnowledgeIngredient(name: entry.name, category: entry.category, emoji: entry.emoji)
            }
        }
        // Merge top_100_data.json items and recipes (seedTop100 guards internally)
        seedTop100()
        // Merge deepseek_json food items (seedDeepSeek guards internally)
        seedDeepSeek()
        // One-time dedup pass — removes any duplicates that crept in from past launches
        deduplicateIngredients()
    }

    // MARK: - Merge (import from backup) #20
    func mergeIngredients(_ incoming: [KnowledgeIngredient]) {
        for item in incoming {
            let lower = item.name.lowercased()
            if let idx = ingredients.firstIndex(where: { $0.name.lowercased() == lower }) {
                // Merge: keep higher searchCount, union aliases
                if item.searchCount > ingredients[idx].searchCount {
                    ingredients[idx].searchCount = item.searchCount
                }
                if let last = item.lastSearched, ingredients[idx].lastSearched == nil {
                    ingredients[idx].lastSearched = last
                }
                let newAliases = item.aliases.filter { !ingredients[idx].aliases.contains($0) }
                ingredients[idx].aliases += newAliases
            } else {
                ingredients.append(item)
            }
        }
        deduplicateIngredients()
        saveIngredients()
    }

    // MARK: - Deduplication
    // Keeps the first occurrence of each lowercased name; preserves user-added and search counts
    func deduplicateIngredients() {
        var seen = Set<String>()
        var deduped: [KnowledgeIngredient] = []
        for item in ingredients {
            let key = item.name.lowercased()
            if seen.insert(key).inserted {
                deduped.append(item)
            }
        }
        if deduped.count != ingredients.count {
            ingredients = deduped
            saveIngredients()
        }
    }

    // MARK: - Helpers
    private nonisolated func shouldSync() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: syncDateKey) as? Date else { return true }
        return Date().timeIntervalSince(last) > 3600 * 6  // sync every 6 hours
    }

    private nonisolated func emojiFor(category: String) -> String {
        switch category.lowercased() {
        case "meats", "proteins":   return "🥩"
        case "poultry":             return "🍗"
        case "seafood":             return "🐟"
        case "dairy":               return "🥛"
        case "produce", "vegetables": return "🥕"
        case "fruits":              return "🍎"
        case "grains":              return "🌾"
        case "pantry":              return "🫙"
        case "spices", "seasonings": return "🌶️"
        case "beverages":           return "🥤"
        case "snacks":              return "🍿"
        case "frozen":              return "❄️"
        default:                    return "🍽️"
        }
    }

    /// Emoji that prefers the item NAME over its (often imprecise) category, so e.g.
    /// "Chicken Stock" or "Chicken Legs" show poultry/meat instead of a wrong default.
    /// Falls back to the category mapping when no name keyword matches.
    nonisolated func emojiFor(name: String, category: String) -> String {
        let n = name.lowercased()
        // Poultry
        if n.contains("chicken") || n.contains("turkey") || n.contains("duck") || n.contains("poultry") { return "🍗" }
        // Red meat / pork / deli
        if ["beef","steak","pork","bacon","sausage","ham","lamb","veal","bison","venison",
            "ground meat","ribeye","sirloin","brisket","chorizo","salami","pepperoni","prosciutto",
            "hot dog","frank","bratwurst","meatball"].contains(where: { n.contains($0) }) { return "🥩" }
        // Seafood
        if ["fish","salmon","tuna","shrimp","crab","lobster","scallop","cod","tilapia","halibut",
            "trout","mackerel","catfish","sardine","anchovy","clam","mussel","oyster","squid",
            "octopus","calamari","seafood"].contains(where: { n.contains($0) }) { return "🐟" }
        // Egg
        if n.contains("egg") { return "🥚" }
        // Dairy / cheese
        if ["milk","cheese","yogurt","cream","butter","cheddar","mozzarella","parmesan","brie",
            "feta","ricotta"].contains(where: { n.contains($0) }) { return "🥛" }
        // Drinks
        if ["water","soda","cola","juice","coffee","tea","lemonade","seltzer","kombucha",
            "gatorade","energy drink"].contains(where: { n.contains($0) }) { return "🥤" }
        // Sweeteners
        if ["honey","syrup","sugar","molasses","agave"].contains(where: { n.contains($0) }) { return "🍯" }
        // No name match → use the category mapping.
        return emojiFor(category: category)
    }

    private nonisolated func categoryFromMealDBArea(_ area: String) -> String {
        switch area.lowercased() {
        case "british", "american", "canadian", "irish": return "Pantry"
        case "chinese", "japanese", "thai", "vietnamese", "korean": return "Produce"
        case "indian": return "Spices"
        case "italian", "french": return "Grains"
        default: return "Produce"
        }
    }
}

// MARK: - KnowledgeIngredient helpers
extension KnowledgeIngredient {
    var asIngredientEntry: IngredientEntry {
        IngredientEntry(name: name, category: category, emoji: emoji)
    }

    // #18: Known synonym map — regional and common alternative names
    static let synonymMap: [String: [String]] = [
        "bell pepper":      ["capsicum", "sweet pepper"],
        "capsicum":         ["bell pepper", "sweet pepper"],
        "eggplant":         ["aubergine", "brinjal"],
        "aubergine":        ["eggplant", "brinjal"],
        "zucchini":         ["courgette"],
        "courgette":        ["zucchini"],
        "cilantro":         ["coriander", "chinese parsley"],
        "coriander":        ["cilantro"],
        "arugula":          ["rocket", "rucola"],
        "rocket":           ["arugula"],
        "beet":             ["beetroot"],
        "beetroot":         ["beet"],
        "scallion":         ["green onion", "spring onion"],
        "spring onion":     ["scallion", "green onion"],
        "chickpeas":        ["garbanzo beans", "ceci beans"],
        "garbanzo beans":   ["chickpeas", "ceci"],
        "ground beef":      ["mince", "minced beef", "hamburger meat"],
        "mince":            ["ground beef", "minced beef"],
        "shrimp":           ["prawns"],
        "prawns":           ["shrimp"],
        "cornstarch":       ["cornflour", "corn starch"],
        "cornflour":        ["cornstarch"],
        "jalapeño":         ["jalapeno"],
        "jalapeno":         ["jalapeño"],
        "habanero":         ["habanero pepper"],
        "heavy cream":      ["double cream", "whipping cream"],
        "double cream":     ["heavy cream", "whipping cream"],
        "half-and-half":    ["half and half", "single cream"],
        "sour cream":       ["crème fraîche", "creme fraiche"],
        "skim milk":        ["skimmed milk", "fat free milk"],
        "all-purpose flour":["plain flour", "ap flour"],
        "plain flour":      ["all-purpose flour"],
        "superfine sugar":  ["caster sugar", "baker's sugar"],
        "caster sugar":     ["superfine sugar"],
        "powdered sugar":   ["icing sugar", "confectioners sugar"],
        "icing sugar":      ["powdered sugar", "confectioners sugar"],
        "broil":            ["grill"],
        "cookie":           ["biscuit"],
        "chips":            ["crisps"],
        "candy":            ["sweets", "lollies"],
    ]
}
