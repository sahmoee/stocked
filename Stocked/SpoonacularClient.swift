// SpoonacularClient.swift
// ─────────────────────────────────────────────────────────────────────────────
// Spoonacular API — feeds StockedKnowledgeBase (ingredients) and
// RecipeDatabase (recipes) silently on background sync.
// No UI. No new tabs. Data flows into predictive text and search automatically.
//
// FREE TIER: 150 points/day.
// Get your free key: https://spoonacular.com/food-api/console#Dashboard
// Add it to your xcconfig: SPOONACULAR_API_KEY = your_key_here
// ─────────────────────────────────────────────────────────────────────────────
import Foundation

// MARK: - Models (internal — only what we need for ingestion)

private struct SpoonacularSearchResult: Codable {
    let id:    Int
    let title: String
    let image: String
}

private struct SpoonacularIngredient: Codable {
    let name:     String
    let original: String
}

private struct SpoonacularStep: Codable {
    let step: String
}

private struct SpoonacularInstructionGroup: Codable {
    let steps: [SpoonacularStep]
}

private struct SpoonacularDetail: Codable {
    let id:                   Int
    let title:                String
    let image:                String
    let readyInMinutes:       Int
    let servings:             Int
    let cuisines:             [String]
    let diets:                [String]
    let dishTypes:            [String]
    let extendedIngredients:  [SpoonacularIngredient]
    let analyzedInstructions: [SpoonacularInstructionGroup]
    let sourceUrl:            String?
    let sourceName:           String?
    let summary:              String?
}

// MARK: - Client

@MainActor
final class SpoonacularClient {

    static let shared = SpoonacularClient()
    private init() {}

    var apiKey: String { BuildConfig.spoonacularAPIKey }
    var isConfigured: Bool { !apiKey.isEmpty && !apiKey.hasPrefix("YOUR_") }

    private let base = "https://api.spoonacular.com"
    private let syncKey = "spoonacularLastSync"

    // MARK: - Daily points budget (free tier = 150 pts/day)
    // We hold a conservative self-imposed cap well under the real limit so a busy day
    // of background syncs + on-demand lookups can't exhaust the quota and leave recipe
    // features dead. The ledger is keyed by UTC day and persists across launches; it
    // resets automatically when the day rolls over. Spend is approximate (Spoonacular's
    // per-endpoint cost varies), so the margin absorbs the slack.
    private let dailyPointBudget = 100
    private let budgetCountKey   = "spoonacularPointsSpent"
    private let budgetDayKey     = "spoonacularPointsDay"

    /// UTC day index (days since reference date), used to bucket spend per calendar day.
    private var currentDayIndex: Int {
        Int(Date().timeIntervalSinceReferenceDate / 86_400)
    }

    /// Points spent so far today (auto-resets when the day rolls over).
    private var pointsSpentToday: Int {
        let storedDay = UserDefaults.standard.integer(forKey: budgetDayKey)
        if storedDay != currentDayIndex {
            // New day → reset the ledger.
            UserDefaults.standard.set(currentDayIndex, forKey: budgetDayKey)
            UserDefaults.standard.set(0, forKey: budgetCountKey)
            return 0
        }
        return UserDefaults.standard.integer(forKey: budgetCountKey)
    }

    /// True if `cost` points can be spent without crossing the daily cap.
    private func canSpend(_ cost: Int) -> Bool {
        pointsSpentToday + cost <= dailyPointBudget
    }

    /// Records `cost` points against today's ledger.
    private func charge(_ cost: Int) {
        // Reading pointsSpentToday first guarantees the day bucket is current.
        let spent = pointsSpentToday
        UserDefaults.standard.set(spent + cost, forKey: budgetCountKey)
    }

    /// Points remaining in today's self-imposed budget (exposed for diagnostics/UI).
    var remainingPointsToday: Int { max(0, dailyPointBudget - pointsSpentToday) }

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 10
        return URLSession(configuration: c)
    }()

    // MARK: - Background sync (called from StockedKnowledgeBase.backgroundSync)
    // Fetches random recipes filtered by user dietary preferences.
    // Max once per 24h to stay within free tier (150 pts/day).
    func syncIfNeeded(dietaryStyle: String = "") async {
        guard isConfigured, shouldSync() else { return }
        await sync(dietaryStyle: dietaryStyle)
        UserDefaults.standard.set(Date(), forKey: syncKey)
    }

    func sync(dietaryStyle: String = "") async {
        guard isConfigured else { return }

        // Build tags from dietary style
        let tagMap: [String: String] = [
            "Vegan": "vegan", "Vegetarian": "vegetarian",
            "Gluten-Free": "gluten+free", "Keto": "ketogenic",
            "Paleo": "paleo", "Dairy-Free": "dairy+free"
        ]
        let tag = tagMap[dietaryStyle] ?? ""

        // Fetch 20 random recipes (20 pts) — well within 150/day
        let results = await fetchRandom(tags: tag.isEmpty ? [] : [tag], number: 20)
        for result in results {
            if let detail = await fetchDetail(id: result.id) {
                ingest(detail)
            }
            // Small delay to avoid hammering the API
            try? await Task.sleep(nanoseconds: 100_000_000)
        }

        // Also pull ingredient autocomplete for common pantry items
        // to enrich predictive text — 5 pts total
        let seedTerms = ["chick", "beef", "pasta", "tomat", "onion"]
        for term in seedTerms {
            let names = await autocomplete(term, number: 8)
            for name in names {
                StockedKnowledgeBase.shared.learnFromInventoryItem(name: name, category: "Pantry")
            }
        }
    }

    // MARK: - Substitution lookup (called from cook flow on demand)
    /// Returns substitute suggestions for a given ingredient.
    func substitutes(for ingredient: String) async -> [String] {
        guard isConfigured, canSpend(1) else { return [] }
        let enc = ingredient.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ingredient
        guard let url = URL(string: "\(base)/food/ingredients/substitutes?ingredientName=\(enc)&apiKey=\(apiKey)"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let subs = json["substitutes"] as? [String] else { return [] }
        charge(1)
        return subs
    }

    // MARK: - Pantry-match search (called from ReadyToCookNow)
    /// Returns recipe IDs ranked by how many pantry ingredients they use.
    func findByIngredients(_ ingredients: [String], number: Int = 10) async -> [(id: Int, title: String, image: String, usedCount: Int, missedCount: Int)] {
        guard isConfigured, !ingredients.isEmpty, canSpend(1) else { return [] }
        let ing = ingredients.prefix(15).joined(separator: ",+")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let url = URL(string: "\(base)/recipes/findByIngredients?ingredients=\(ing)&number=\(number)&ranking=1&ignorePantry=true&apiKey=\(apiKey)"),
              let (data, _) = try? await session.data(from: url),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        charge(1)

        return items.compactMap { item in
            guard let id    = item["id"]    as? Int,
                  let title = item["title"] as? String else { return nil }
            let image = item["image"] as? String ?? ""
            let used  = item["usedIngredientCount"]   as? Int ?? 0
            let miss  = item["missedIngredientCount"] as? Int ?? 0
            return (id: id, title: title, image: image, usedCount: used, missedCount: miss)
        }
    }

    // MARK: - Private helpers

    private func fetchRandom(tags: [String], number: Int) async -> [SpoonacularSearchResult] {
        // /recipes/random ≈ 1 base point + ~0.01 per recipe returned. Round up.
        let cost = 1 + Int(ceil(Double(number) * 0.01))
        guard canSpend(cost) else { return [] }
        var urlStr = "\(base)/recipes/random?number=\(number)&apiKey=\(apiKey)"
        if !tags.isEmpty { urlStr += "&tags=\(tags.joined(separator: ","))" }
        guard let url = URL(string: urlStr),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recipes = json["recipes"] as? [[String: Any]] else { return [] }
        charge(cost)

        return recipes.compactMap { r in
            guard let id = r["id"] as? Int, let title = r["title"] as? String else { return nil }
            return SpoonacularSearchResult(id: id, title: title, image: r["image"] as? String ?? "")
        }
    }

    private func fetchDetail(id: Int) async -> SpoonacularDetail? {
        guard canSpend(1) else { return nil }
        guard let url = URL(string: "\(base)/recipes/\(id)/information?includeNutrition=false&apiKey=\(apiKey)"),
              let (data, _) = try? await session.data(from: url) else { return nil }
        charge(1)
        return try? JSONDecoder().decode(SpoonacularDetail.self, from: data)
    }

    // MARK: - Discover feed
    /// Fetch random Spoonacular recipes WITH full step-by-step instructions, mapped
    /// to OnlineRecipe for the Discover feed. (The cheaper findByIngredients path
    /// omits steps, so those results get filtered out — this one fetches details so
    /// the recipes actually appear.) No-ops if unconfigured. One detail call per
    /// recipe, so keep `number` small to respect the 150-points/day free tier.
    func discoverRecipes(number: Int = 3) async -> [OnlineRecipe] {
        guard isConfigured else { return [] }
        let stubs = await fetchRandom(tags: [], number: number)
        var out: [OnlineRecipe] = []
        for stub in stubs {
            guard let d = await fetchDetail(id: stub.id) else { continue }
            let steps = d.analyzedInstructions.flatMap { $0.steps }.map { $0.step }.filter { !$0.isEmpty }
            guard !steps.isEmpty else { continue }
            out.append(OnlineRecipe(
                id: "spoon-\(d.id)",
                title: d.title,
                category: d.dishTypes.first?.capitalized ?? "",
                area: d.cuisines.first ?? "",
                instructions: steps.joined(separator: "\n"),
                imageURL: d.image,
                ingredients: d.extendedIngredients.map { $0.original },
                measures: Array(repeating: "", count: d.extendedIngredients.count),
                source: "Spoonacular"
            ))
        }
        return out
    }

    /// Pull MANY Spoonacular recipes in a SINGLE /recipes/random call. The random
    /// endpoint already returns full objects (analyzedInstructions + extendedIngredients),
    /// so we parse them directly instead of making a detail call per recipe — that's
    /// ~`number`× cheaper on quota, letting us surface a lot more variety per refresh.
    /// One request ≈ 1 point + small per-recipe cost, vs the old number+1 requests.
    func discoverRecipesBulk(number: Int = 20, tags: [String] = []) async -> [OnlineRecipe] {
        guard isConfigured else { return [] }
        let cost = 1 + Int(ceil(Double(number) * 0.01))
        guard canSpend(cost) else { return [] }
        var urlStr = "\(base)/recipes/random?number=\(number)&apiKey=\(apiKey)"
        if !tags.isEmpty { urlStr += "&tags=\(tags.joined(separator: ","))" }
        guard let url = URL(string: urlStr),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recipes = json["recipes"] as? [[String: Any]] else { return [] }
        charge(cost)

        var out: [OnlineRecipe] = []
        for r in recipes {
            guard let id = r["id"] as? Int, let title = r["title"] as? String else { continue }
            // analyzedInstructions: [ { steps: [ { step: "…" } ] } ]
            let groups = r["analyzedInstructions"] as? [[String: Any]] ?? []
            let steps = groups.flatMap { ($0["steps"] as? [[String: Any]] ?? []) }
                .compactMap { ($0["step"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !steps.isEmpty else { continue }   // no steps → would be filtered out anyway
            let ingredients = (r["extendedIngredients"] as? [[String: Any]] ?? [])
                .compactMap { ($0["original"] as? String)?.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let cuisine = (r["cuisines"] as? [String])?.first ?? ""
            let dish = (r["dishTypes"] as? [String])?.first?.capitalized ?? ""
            out.append(OnlineRecipe(
                id: "spoon-\(id)",
                title: title,
                category: dish,
                area: cuisine,
                instructions: steps.joined(separator: "\n"),
                imageURL: r["image"] as? String ?? "",
                ingredients: ingredients,
                measures: Array(repeating: "", count: ingredients.count),
                source: "Spoonacular"
            ))
        }
        return out
    }

    func autocomplete(_ query: String, number: Int) async -> [String] {
        guard canSpend(1) else { return [] }
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "\(base)/food/ingredients/autocomplete?query=\(enc)&number=\(number)&apiKey=\(apiKey)"),
              let (data, _) = try? await session.data(from: url),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        charge(1)
        return items.compactMap { $0["name"] as? String }
    }

    // Feed one Spoonacular recipe into KB + RecipeDatabase
    private func ingest(_ r: SpoonacularDetail) {
        let kb = StockedKnowledgeBase.shared

        // Register ingredients → powers FoodPredictiveTextField
        for ing in r.extendedIngredients {
            kb.learnFromInventoryItem(name: ing.name, category: "Pantry")
        }

        let steps = r.analyzedInstructions.flatMap { $0.steps }.map { $0.step }
        let tags  = (r.cuisines + r.diets + r.dishTypes).map { $0.lowercased() }

        let entry = RecipeDatabaseEntry(
            title:       r.title,
            description: r.summary.map { stripHTML($0) } ?? "",
            sourceURL:   r.sourceUrl ?? "",
            sourceName:  r.sourceName ?? "Spoonacular",
            prepTime:    "", cookTime: "\(r.readyInMinutes) min", totalTime: "\(r.readyInMinutes) min",
            servings:    "\(r.servings)",
            category:    r.dishTypes.first?.capitalized ?? "",
            cuisine:     r.cuisines.first ?? "",
            tags:        tags,
            ingredients: r.extendedIngredients.map { $0.original },
            steps:       steps,
            imageURL:    r.image,
            cachedAt:    Date()
        )

        Task { await RecipeDatabase.shared.upsert(entry) }
    }

    private func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shouldSync() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: syncKey) as? Date else { return true }
        return Date().timeIntervalSince(last) > 3600 * 24
    }
}
