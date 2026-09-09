import Foundation

nonisolated struct GlobalSearchFood: Sendable {
    let id: UUID
    let name: String
    let category: String
    let emoji: String
    let aliases: [String]
    let searchCount: Int
    let lastSearched: Date?
}

/// Copies of the authoritative arrays retain Swift's copy-on-write storage. Expensive
/// matching, normalization, sorting, and NL classification happen only on the worker.
nonisolated struct GlobalSearchSnapshot: Sendable {
    let inventory: [LocalInventoryItem]
    let groceries: [LocalGroceryItem]
    let recipes: [UserRecipe]
    let history: [LocalPastMeal]
    let cached: [CachedRecipe]
    let foods: [GlobalSearchFood]
    let leftovers: [LeftoverEntry]
    let labels: [ContainerLabel]
    let meals: [PlannedMeal]
}

nonisolated enum GlobalSearchLocalMatch: Sendable {
    case inventory(LocalInventoryItem), grocery(LocalGroceryItem), recipe(UserRecipe)
    case history(LocalPastMeal), cached(CachedRecipe), food(GlobalSearchFood)
    case leftover(LeftoverEntry), label(ContainerLabel), meal(PlannedMeal), tool(ToolboxTool)
}

nonisolated struct GlobalSearchLocalOutput: Sendable {
    var matches: [GlobalSearchLocalMatch] = []
    var hasMore = false
    var hasStructuredQuery = false
    var suggestion: String?
}

nonisolated enum GlobalSearchEngine {
    static func normalizedQuery(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func search(_ raw: String, snapshot: GlobalSearchSnapshot) throws -> GlobalSearchLocalOutput {
        let query = normalizedQuery(raw)
        guard !query.isEmpty else { return GlobalSearchLocalOutput() }
        try Task.checkCancellation()
        let parsed = NLQueryParser.parse(query, knownIngredients: snapshot.foods.map { $0.name.lowercased() })
        var output = GlobalSearchLocalOutput(hasStructuredQuery: parsed.hasStructure)
        var window = GlobalSearchRanking<GlobalSearchLocalMatch>(limit: 12)
        func collect(_ result: GlobalSearchRanking<GlobalSearchLocalMatch>) {
            output.matches += result.candidates.map(\.value)
            output.hasMore = output.hasMore || result.hasMore
        }
        for item in snapshot.inventory {
            try Task.checkCancellation()
            let title = item.name.lowercased()
            if title.contains(query) { window.consider(id: item.id.uuidString, title: title, score: title == query ? 100 : 80, value: .inventory(item)) }
        }
        collect(window); window = .init(limit: 12)
        for item in snapshot.leftovers {
            try Task.checkCancellation()
            if item.title.lowercased().contains(query) {
                window.consider(id: item.id.uuidString, title: item.title, score: item.daysLeft <= 1 ? 90 : 68, value: .leftover(item))
            }
        }
        collect(window); window = .init(limit: 12)
        for item in snapshot.labels {
            try Task.checkCancellation()
            if item.contents.lowercased().contains(query) { window.consider(id: item.id.uuidString, title: item.contents, score: 66, value: .label(item)) }
        }
        collect(window); window = .init(limit: 12)
        for item in snapshot.groceries {
            try Task.checkCancellation()
            if item.name.lowercased().contains(query) { window.consider(id: item.id.uuidString, title: item.name, score: 70, value: .grocery(item)) }
        }
        collect(window); window = .init(limit: 12)
        for item in snapshot.meals {
            try Task.checkCancellation()
            if !item.isBuilding && item.title.lowercased().contains(query) { window.consider(id: item.id.uuidString, title: item.title, score: 72, value: .meal(item)) }
        }
        collect(window); window = .init(limit: 12)
        for item in snapshot.recipes {
            try Task.checkCancellation()
            guard !RecipeDisplayPolicy.isKnownPublisherPlaceholder(item.imageURL ?? "") else { continue }
            let title = item.title.lowercased()
            let score: Double = title == query ? 100 : title.contains(query) ? 75 :
                item.ingredients.contains(where: { $0.name.lowercased().contains(query) }) ? 60 : 0
            if score > 0 { window.consider(id: "recipe_\(item.id)", title: title, score: score, value: .recipe(item)) }
        }
        // Saved recipes and history share the existing Recipes group, with the original ladder.
        for item in snapshot.history {
            try Task.checkCancellation()
            if item.title.lowercased().contains(query) { window.consider(id: "history_\(item.id)", title: item.title, score: 65, value: .history(item)) }
        }
        var cachedWindow = GlobalSearchRanking<GlobalSearchLocalMatch>(limit: 8)
        for item in snapshot.cached {
            try Task.checkCancellation()
            guard !RecipeDisplayPolicy.isKnownPublisherPlaceholder(item.imageURL) else { continue }
            let rawMatch = [item.title, item.area, item.category].contains { $0.lowercased().contains(query) } ||
                item.ingredients.contains { $0.lowercased().contains(query) }
            guard rawMatch else { continue }
            if parsed.hasStructure {
                let classification = RecipeClassifier.classify(title: item.title, rawCuisine: item.area,
                    rawCategory: item.category, keywords: [],
                    ingredients: item.ingredients.map { RecipeIngredient(name: $0, amount: "") }, instructions: item.steps)
                let entry = RecipeDatabaseEntry(title: item.title, description: "", sourceURL: "", sourceName: item.source,
                    prepTime: item.prepTime ?? "", cookTime: item.cookTime ?? "", totalTime: item.totalTime ?? "", servings: "",
                    category: classification.category, cuisine: classification.cuisine, tags: classification.tags,
                    ingredients: item.ingredients, steps: item.steps, imageURL: item.imageURL, cachedAt: item.cachedAt)
                guard NLQueryParser.matches(entry, query: parsed) else { continue }
            }
            cachedWindow.consider(id: "cached_\(item.mealID)", title: item.title, score: 50, value: .cached(item))
        }
        // Cache matches retain their own bounded window so a large saved library cannot hide them.
        collect(window); collect(cachedWindow); window = .init(limit: 5)
        for item in ToolboxTool.allCases {
            try Task.checkCancellation()
            if FuzzyMatch.matches(query, item.title) || item.subtitle.lowercased().contains(query) {
                window.consider(id: item.rawValue, title: item.title, score: item.title.lowercased() == query ? 95 : 55, value: .tool(item))
            }
        }
        collect(window)
        var prefixFoods = GlobalSearchRanking<GlobalSearchFood>(limit: 6)
        var otherFoods = GlobalSearchRanking<GlobalSearchFood>(limit: 6)
        let normalized = DBNormalize.key(query)
        let now = Date()
        for food in snapshot.foods {
            try Task.checkCancellation()
            let name = DBNormalize.key(food.name)
            let starts = name.hasPrefix(normalized)
            if !normalized.isEmpty && (starts || name.contains(normalized) || food.aliases.contains(where: { DBNormalize.key($0).contains(normalized) })) {
                let age = food.lastSearched.map { now.timeIntervalSince($0) / 86400 }
                let rank = age.map { Double(food.searchCount) + max(0, 30 - $0) / 3 } ?? Double(food.searchCount) * 0.5
                if starts { prefixFoods.consider(id: food.id.uuidString, title: food.name, score: rank, value: food) }
                else { otherFoods.consider(id: food.id.uuidString, title: food.name, score: rank, value: food) }
            }
            if output.suggestion == nil, query.count >= 3 {
                let lower = food.name.lowercased()
                if abs(query.count - lower.count) <= 2 && Set(query).intersection(Set(lower)).count >= min(query.count, lower.count) - 1 {
                    output.suggestion = food.name.capitalized
                }
            }
        }
        let foods = prefixFoods.candidates + otherFoods.candidates
        output.matches += foods.prefix(6).map { .food($0.value) }
        output.hasMore = output.hasMore || prefixFoods.hasMore || otherFoods.hasMore || foods.count > 6
        try Task.checkCancellation()
        return output
    }
}

/// Query responses have a small disk budget. Each entry contains only the six displayed
/// recipes, and legacy preference data is migrated once away from the UI thread.
actor GlobalSearchResponseCache {
    static let shared = GlobalSearchResponseCache()
    private let key = "globalSearchResponses_v2"
    private let legacyKey = "globalSearchOfflineCache_v1"
    private let ttl: TimeInterval = 14 * 86400
    private var loaded = false
    private var entries: [Entry] = []
    nonisolated private struct Entry: Codable, Sendable {
        let query: String
        let savedAt: Date
        let recipes: [OnlineRecipe]
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let saved = LocalDatabase.shared.load([Entry].self, key: key) {
            entries = saved
        } else if let data = UserDefaults.standard.data(forKey: legacyKey), data.count <= 2_000_000,
                  let legacy = try? JSONDecoder().decode([String: [OnlineRecipe]].self, from: data) {
            // Old entries have no timestamp. Keep the bounded exact-query fallback only for
            // this migration session; do not manufacture a new date for unknown-age recipes.
            entries = legacy.keys.sorted().prefix(12).map { Entry(query: GlobalSearchEngine.normalizedQuery($0), savedAt: .distantPast, recipes: Array(legacy[$0, default: []].prefix(6))) }
        }
        entries = Array(entries.filter { $0.savedAt == .distantPast || Date().timeIntervalSince($0.savedAt) < ttl }.prefix(12))
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    func recipes(for query: String) -> [OnlineRecipe] {
        load()
        let now = Date()
        entries.removeAll { $0.savedAt != .distantPast && now.timeIntervalSince($0.savedAt) >= ttl }
        return entries.first { $0.query == GlobalSearchEngine.normalizedQuery(query) }?.recipes ?? []
    }

    func save(_ recipes: [OnlineRecipe], query: String) {
        load()
        let normalized = GlobalSearchEngine.normalizedQuery(query)
        entries.removeAll { $0.query == normalized || $0.savedAt == .distantPast || Date().timeIntervalSince($0.savedAt) >= ttl }
        entries.insert(Entry(query: normalized, savedAt: Date(), recipes: Array(recipes.prefix(6))), at: 0)
        entries = Array(entries.prefix(12))
        while let data = try? JSONEncoder().encode(entries), data.count > 512_000, !entries.isEmpty { entries.removeLast() }
        LocalDatabase.shared.save(entries, key: key)
    }
}
