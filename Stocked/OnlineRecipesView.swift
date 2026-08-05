// OnlineRecipesView.swift — Database-first recipe discovery with online fallback
import SwiftUI
import Combine

// MARK: - Model
nonisolated struct OnlineRecipe: Identifiable, Codable, Hashable, Sendable {
    let id:           String
    let title:        String
    let category:     String
    let area:         String
    let instructions: String
    let imageURL:     String
    let ingredients:  [String]
    let measures:     [String]
    var source:       String = "TheMealDB"

    var ingredientLines: [(measure: String, ingredient: String)] {
        zip(measures, ingredients)
            .filter { !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { ($0.0.trimmingCharacters(in: .whitespaces), $0.1.trimmingCharacters(in: .whitespaces)) }
    }
}

/// Decodes and encodes the Discover cache away from the main actor. Large recipe arrays
/// previously went through JSONDecoder synchronously when the tab appeared, which could
/// stall navigation even when every recipe was already cached.
private actor OnlineRecipesPersistentCache {
    static let shared = OnlineRecipesPersistentCache()

    nonisolated private struct Snapshot: Codable, Sendable {
        let recipes: [OnlineRecipe]
        let savedAt: Date
    }

    func load(cacheKey: String, timestampKey: String) -> (recipes: [OnlineRecipe], savedAt: Date?) {
        if let snapshot = LocalDatabase.shared.load(Snapshot.self, key: cacheKey) {
            return (snapshot.recipes, snapshot.savedAt)
        }

        // One-time migration from the old large UserDefaults payload. Keeping hundreds of
        // recipes in preferences caused expensive preference-domain reads and writes.
        let savedAt = UserDefaults.standard.object(forKey: timestampKey) as? Date
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let recipes = try? JSONDecoder().decode([OnlineRecipe].self, from: data) else {
            return ([], savedAt)
        }
        let snapshot = Snapshot(recipes: recipes, savedAt: savedAt ?? Date.distantPast)
        LocalDatabase.shared.save(snapshot, key: cacheKey)
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: timestampKey)
        return (recipes, savedAt)
    }

    func save(_ recipes: [OnlineRecipe], cacheKey: String, timestampKey: String, savedAt: Date) {
        LocalDatabase.shared.save(Snapshot(recipes: recipes, savedAt: savedAt), key: cacheKey)
        // Remove legacy values if an older build recreated them.
        UserDefaults.standard.removeObject(forKey: cacheKey)
        UserDefaults.standard.removeObject(forKey: timestampKey)
    }
}

// MARK: - Loader
@Observable
@MainActor
class OnlineRecipesLoader {
    static let shared = OnlineRecipesLoader()
    var recipes:   [OnlineRecipe] = []
    var isLoading  = false
    var error:     String?
    /// Changes whenever the published recipe content changes, even when the count does not.
    var revision   = 0

    private let cacheKey = "onlineRecipesCache_v3"
    private let cacheTimestampKey = "onlineRecipesCacheTimestamp_v3"
    private let cacheTTL: TimeInterval = 60 * 60 * 6
    private let countKey = "appOpenCount"
    private var loadTask: Task<Void, Never>?
    private var bootstrapTask: Task<Void, Never>?
    private var seedTask: Task<Void, Never>?
    private var fetchGeneration = 0
    private var didBootstrapCache = false
    private var cachedAt: Date?

    /// Top pantry ingredient names to seed ingredient-based fetches with, so Discover fills
    /// with recipes the user can actually make. Set by callers that have store access; empty
    /// is fine (the phase simply skips).
    private var pantrySeedNames: [String] = []

    // MealDB categories to pull a broad mix
    private let dbCategories = ["Beef","Chicken","Seafood","Vegetarian","Pasta",
                                "Dessert","Breakfast","Side","Lamb","Pork","Vegan"]

    func loadIfNeeded(profile: UserCookingProfile? = nil, pantry: [String] = []) {
        if !pantry.isEmpty { pantrySeedNames = pantry }

        if didBootstrapCache {
            if recipes.isEmpty { seedFromLocalDatabase(profile: profile) }
            let isFresh = cachedAt.map { Date().timeIntervalSince($0) < cacheTTL } ?? false
            if !isFresh { fetchInBackground(profile: profile) }
            return
        }
        guard bootstrapTask == nil else { return }

        // Stale-while-revalidate: decode the persisted cache on its own actor, publish it
        // immediately, and only start the bounded source funnel when that cache is stale.
        let cacheKey = self.cacheKey
        let timestampKey = self.cacheTimestampKey
        let preferredCuisines = profile?.cuisinePrefs ?? []
        bootstrapTask = Task { [weak self] in
            let cached = await OnlineRecipesPersistentCache.shared.load(
                cacheKey: cacheKey, timestampKey: timestampKey)
            guard let self, !Task.isCancelled else { return }
            self.cachedAt = cached.savedAt
            self.didBootstrapCache = true
            if self.recipes.isEmpty, !cached.recipes.isEmpty {
                let filtered = await Task.detached(priority: .utility) {
                    Self.filterByProfile(cached.recipes, preferredCuisines: preferredCuisines)
                }.value
                guard !Task.isCancelled else { return }
                self.publish(filtered)
            }
            if self.recipes.isEmpty { self.seedFromLocalDatabase(profile: profile) }
            let isFresh = cached.savedAt.map { Date().timeIntervalSince($0) < self.cacheTTL } ?? false
            if !isFresh { self.fetchInBackground(profile: profile) }
            self.bootstrapTask = nil
        }
    }

    /// Pull a batch from the on-device RecipeDatabase (Spoonacular/CocktailDB/MealDB already
    /// synced there) into `recipes` so the UI has content offline. No-ops if empty.
    private func seedFromLocalDatabase(profile: UserCookingProfile?) {
        guard seedTask == nil else { return }
        let preferredCuisines = profile?.cuisinePrefs ?? []
        seedTask = Task { [weak self] in
            guard let self else { return }
            defer { self.seedTask = nil }

            let entries = await RecipeDatabaseManager.shared.loadSnapshot()
            guard !Task.isCancelled else { return }
            let presentableCount = await Task.detached(priority: .utility) {
                entries.lazy.filter { !$0.imageURL.isEmpty && !$0.steps.isEmpty }.prefix(12).count
            }.value
            let corpus: [RecipeDatabaseEntry]
            if presentableCount < 12 {
                corpus = await RecipeDatabaseManager.shared.corpusPresentable(limit: 60)
            } else {
                corpus = []
            }

            let local = await Task.detached(priority: .utility) {
                var mapped = entries
                    .filter { !$0.imageURL.isEmpty && !$0.steps.isEmpty }
                    .prefix(60)
                    .map { Self.makeOnlineRecipe(from: $0) }
                if mapped.count < 12 {
                    mapped += corpus
                        .filter { !$0.steps.isEmpty }
                        .map { Self.makeOnlineRecipe(from: $0) }
                }
                return Self.filterByProfile(Array(mapped), preferredCuisines: preferredCuisines)
            }.value

            guard !Task.isCancelled, self.recipes.isEmpty, !local.isEmpty else { return }
            self.publish(local)
        }
    }

    /// Map a stored recipe entry to the Discover view model.
    nonisolated private static func makeOnlineRecipe(from entry: RecipeDatabaseEntry) -> OnlineRecipe {
        OnlineRecipe(
            id: entry.id.uuidString,
            title: entry.title,
            category: entry.category,
            area: entry.cuisine,
            instructions: entry.steps.joined(separator: "\n"),
            imageURL: entry.imageURL,
            ingredients: entry.ingredients,
            measures: Array(repeating: "", count: entry.ingredients.count),
            source: entry.sourceName.isEmpty ? "My Database" : entry.sourceName
        )
    }

    /// Map a live JSON-LD publisher recipe into the shared Discover model.
    nonisolated private static func makeOnlineRecipe(from web: WebRecipe) -> OnlineRecipe {
        OnlineRecipe(
            id: "web-\(web.id.uuidString)",
            title: web.title,
            category: web.category,
            area: web.cuisine,
            instructions: web.steps.map(\.text).joined(separator: "\n"),
            imageURL: web.imageURL,
            ingredients: web.ingredients,
            measures: Array(repeating: "", count: web.ingredients.count),
            source: web.sourceName
        )
    }

    func forceRefresh(profile: UserCookingProfile? = nil, pantry: [String] = []) {
        if !pantry.isEmpty { pantrySeedNames = pantry }
        bootstrapTask?.cancel()
        bootstrapTask = nil
        seedTask?.cancel()
        seedTask = nil
        didBootstrapCache = true
        fetchGeneration &+= 1
        loadTask?.cancel()
        loadTask = nil
        isLoading = false
        fetchInBackground(profile: profile)
    }

    func cancel() {
        fetchGeneration &+= 1
        bootstrapTask?.cancel(); bootstrapTask = nil
        seedTask?.cancel(); seedTask = nil
        loadTask?.cancel(); loadTask = nil
        isLoading = false
    }

    private func publish(_ value: [OnlineRecipe]) {
        recipes = value
        revision &+= 1
    }

    /// Load the persisted Discover snapshot into memory WITHOUT any network work.
    ///
    /// The Cook tab classifies this pool, and a user can open Cook on a cold
    /// launch having never touched Recipes this session — in which case the
    /// loader is empty and Cook would fall back to starter meals only, which is
    /// exactly the bug this fixes. Cheap and idempotent: it returns immediately
    /// once recipes are in memory, and the decode happens on the cache actor, not
    /// the main thread.
    func warmFromCacheIfNeeded() async {
        guard recipes.isEmpty, !isLoading else { return }
        let cached = await OnlineRecipesPersistentCache.shared.load(
            cacheKey: cacheKey, timestampKey: cacheTimestampKey
        )
        // STK-69-0001 (Build 69, from the field) — "No recipe showing … needs a
        // full recipe as they appear anywhere else in the app", on Cook Now
        // results.
        //
        // This function published the persisted cache RAW. Every other path into
        // `recipes` goes through `filterByProfile`, which drops recipes with no
        // real instructions — empty, or one of the "see full recipe at source"
        // placeholders that feeds without step licences emit. This one did not,
        // and this is the path the Cook tab uses: both `CookHubView.bootstrap()`
        // and `CookNowResultsView`'s `.task` call it on a cold launch.
        //
        // So Cook Now could classify, rank and offer a recipe that the Recipes
        // tab would never have shown, and there was no method to render when the
        // tester opened it. Filtering here means the Cook tab and the Recipes tab
        // warm from the same cache and end up with the same pool, which is what
        // "one source of truth" was supposed to mean.
        let usable = cached.recipes.filter {
            OnlineRecipeFacts.hasRealInstructions($0.instructions)
        }
        guard !usable.isEmpty, recipes.isEmpty else { return }
        publish(usable)
    }

    private nonisolated static func filterByProfile(
        _ all: [OnlineRecipe],
        preferredCuisines: [String]
    ) -> [OnlineRecipe] {
        // Always drop recipes that have no real step-by-step instructions, or whose
        // "instructions" are just a link to the source (e.g. Edamam, which doesn't
        // license step text). These should never surface anywhere in Discover/search.
        let withSteps = all.filter { OnlineRecipeFacts.hasRealInstructions($0.instructions) }

        guard !preferredCuisines.isEmpty else { return withSteps }
        let preferred = preferredCuisines.map { $0.lowercased() }
        return withSteps.sorted { a, b in
            let sA = preferred.contains(where: { a.area.lowercased().contains($0) || a.category.lowercased().contains($0) }) ? 2 : 0
            let sB = preferred.contains(where: { b.area.lowercased().contains($0) || b.category.lowercased().contains($0) }) ? 2 : 0
            return sA > sB
        }
    }

    private func fetchInBackground(profile: UserCookingProfile? = nil) {
        guard loadTask == nil else { return }
        fetchGeneration &+= 1
        let generation = fetchGeneration
        let preferredCuisines = profile?.cuisinePrefs ?? []
        loadTask = Task(priority: .background) { [weak self] in
            guard let self, !Task.isCancelled, self.fetchGeneration == generation else { return }
            self.isLoading = true
            self.error = nil

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config)

            var fetched: [OnlineRecipe] = []

            // Phase 0: Sowens curated content hosted on Namecheap cPanel (static JSON + images,
            // cached on-device with ETag). Cheap, offline-friendly, and returns [] until published.
            fetched += await RemoteContentClient.shared.onlineRecipes(limit: 40)

            let spoonacularRemainingPoints = await SpoonacularClient.shared.remainingPointsToday
            let sourcePlan = RecipeDiscoveryPlan.make(
                cacheCount: self.recipes.count,
                spoonacularRemainingPoints: spoonacularRemainingPoints,
                mealDBHealth: SourceHealth.shared.score("TheMealDB"),
                isForced: false
            )

            // Phase 1: pull from ALL DB categories (was 11 of 11 — now the full list every
            // refresh for maximum fill), bounded so we don't hammer MealDB.
            let catTasks: [RecipeDiscoveryCoordinator.RecipeTask] = Array(self.dbCategories.prefix(sourcePlan.mealDBCategories)).map { category in
                { await Self.fetchByCategory(category, session: session) }
            }
            fetched += await RecipeDiscoveryCoordinator.boundedGather(catTasks)

            // Phase 2: random MealDB recipes for freshness (24, up from 14), bounded.
            let randomTasks: [RecipeDiscoveryCoordinator.RecipeTask] = (0..<sourcePlan.randomMealDB).map { _ in
                { if let recipe = await Self.fetchOne(session: session) { return [recipe] } else { return [] } }
            }
            fetched += await RecipeDiscoveryCoordinator.boundedGather(randomTasks)

            // Phase 3: Pull from local RecipeDatabase (Spoonacular/CocktailDB already synced there)
            let dbEntries = await RecipeDatabaseManager.shared.loadSnapshot()
            let dbRecipes = await Task.detached(priority: .utility) {
                dbEntries
                    .filter { !$0.imageURL.isEmpty && !$0.steps.isEmpty }
                    .shuffled().prefix(60)
                    .map { Self.makeOnlineRecipe(from: $0) }
            }.value
            fetched.append(contentsOf: dbRecipes)

            // Phase 4: DummyJSON removed — fake placeholder data, not real recipes

            // Phase 5: MealDB by first letter — 6 letters per refresh (was 3), bounded.
            let letters = ["a","b","c","d","e","f","g","h","l","m","p","r","s","t"]
            let letterTasks: [RecipeDiscoveryCoordinator.RecipeTask] = Array(letters.shuffled().prefix(sourcePlan.firstLetters)).map { letter in
                { await Self.fetchByLetter(letter, session: session) }
            }
            fetched += await RecipeDiscoveryCoordinator.boundedGather(letterTasks)

            // Phase 6: Area-based MealDB — 7 cuisines per refresh (was 4), bounded.
            let areas = ["Italian","French","Japanese","Indian","Mexican","Thai","Greek","Moroccan","Chinese","Spanish","Vietnamese","Turkish","British","American"]
            let areaTasks: [RecipeDiscoveryCoordinator.RecipeTask] = Array(areas.shuffled().prefix(sourcePlan.areas)).map { area in
                { await Self.fetchByArea(area, session: session) }
            }
            fetched += await RecipeDiscoveryCoordinator.boundedGather(areaTasks)

            // Phase 7: Forkify removed — Heroku free tier endpoint, frequently down, no ingredients

            // Phase 8: Additional free sources — Edamam (if keyed) + Wikibooks Cookbook.
            // Seeded with a couple of the user's preferred cuisines (or sensible defaults)
            // so these aggregators return relevant dishes.
            let seedTerms: [String] = {
                if let p = profile, !p.cuisinePrefs.isEmpty { return Array(p.cuisinePrefs.prefix(2)) }
                return ["dinner", "chicken"]
            }()
            // Up to 4 pantry ingredients drive "cook from what I have" pulls.
            let pantrySeeds = Array(self.pantrySeedNames.prefix(4))
            var supplementalTasks: [RecipeDiscoveryCoordinator.RecipeTask] = []
            for term in seedTerms {
                supplementalTasks.append { await RecipeSourcesPlus.edamam(query: term, limit: 6) }
                supplementalTasks.append { await RecipeSourcesPlus.wikibooksCookbook(query: term, limit: 3) }
                supplementalTasks.append { await RecipeSourcesPlus.mealDBByIngredient(term, limit: 5) }
            }
            supplementalTasks.append { await CocktailDBClient.shared.discoverRecipes(limit: 8) }
            supplementalTasks.append { await RecipeSourcesPlus.dummyJSONRecipes(limit: 20) }
            for term in seedTerms {
                supplementalTasks.append { await RecipeSourcesPlus.dummyJSONSearch(term, limit: 6) }
            }
            for ingredient in pantrySeeds {
                supplementalTasks.append { await RecipeSourcesPlus.mealDBByIngredient(ingredient, limit: 5) }
            }
            if !BuildConfig.rapidAPIKey.isEmpty {
                for term in seedTerms {
                    supplementalTasks.append { await RecipeSourcesPlus.tasty(query: term, limit: 8) }
                }
            }
            if !BuildConfig.apiNinjasKey.isEmpty {
                for term in (seedTerms + pantrySeeds).prefix(4) {
                    supplementalTasks.append { await DrinkSourcesPlus.apiNinjasRecipes(title: term, limit: 8) }
                }
            }
            if !BuildConfig.suggesticToken.isEmpty {
                for term in seedTerms {
                    supplementalTasks.append { await SuggesticSource.recipes(query: term, limit: 12) }
                }
            }
            supplementalTasks.append { await RemoteRecipeFeed.fetch() }
            fetched += await RecipeDiscoveryCoordinator.boundedGather(
                supplementalTasks, maxConcurrent: 4)

            // Spoonacular is intentionally last: free/cached sources get first chance and the
            // local daily ledger prevents Discover from burning the 150-point provider budget.
            if sourcePlan.useSpoonacular, SpoonacularClient.shared.isConfigured {
                let spoonacular = await SpoonacularClient.shared.discoverRecipesBulk(
                    number: sourcePlan.spoonacularCount,
                    tags: seedTerms.first.map { [$0.lowercased()] } ?? []
                )
                fetched += spoonacular
            }

            // Publisher search previously issued a dozen one-recipe website requests on every
            // refresh. Those rows could never satisfy the 20-complete-recipe source rule and the
            // fan-out competed with image loading. Publisher recipes remain available after URL
            // import or from the on-device catalogue, without automatic network scraping.

            guard !Task.isCancelled, self.fetchGeneration == generation else {
                if self.fetchGeneration == generation {
                    self.isLoading = false
                    self.loadTask = nil
                }
                return
            }

            // Normalize, validate, and merge away from the MainActor. The old firstIndex loop
            // re-normalized every retained recipe for every candidate (quadratic work) and was a
            // major source of freezes once the combined source pool became large.
            let unique = await Task.detached(priority: .utility) {
                Self.deduplicateAndMerge(fetched)
            }.value

            guard !Task.isCancelled else { return }
            guard self.fetchGeneration == generation else { return }
            self.isLoading = false
            if !unique.isEmpty {
                let existingIds = Set(self.recipes.map(\.id))
                let newOnes = unique.filter { !existingIds.contains($0.id) }
                let combined = Array((newOnes + self.recipes).prefix(400))
                let filtered = await Task.detached(priority: .utility) {
                    Self.filterByProfile(combined, preferredCuisines: preferredCuisines)
                }.value
                guard !Task.isCancelled, self.fetchGeneration == generation else { return }
                self.publish(filtered)
                self.saveCacheAsync(self.recipes)
                // Cross-source sync: everything freshly fetched — from ANY feed — joins
                // the on-device RecipeDatabase, the one pool behind Discover's offline
                // seed, recipe search, the mood finder's database layer, and cook
                // ranking. Sources stop being silos; each fetch enriches the whole app.
                RecipeSourceHub.ingestIntoDatabase(newOnes)
            } else if self.recipes.isEmpty {
                self.error = "Couldn't load recipes. Check your connection."
            }
            self.loadTask = nil
        }
    }

    // Fetch 2 recipes from a specific category (DB-style)
    nonisolated private static func fetchByCategory(_ category: String, session: URLSession) async -> [OnlineRecipe] {
        let enc = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? category
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/filter.php?c=\(enc)") else { return [] }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]] else { return [] }

        // Pick 2 random meals from this category and fetch their full details
        let picked = meals.shuffled().prefix(2)
        var results: [OnlineRecipe] = []
        for m in picked {
            guard let id = m["idMeal"] as? String else { continue }
            if var recipe = await Self.fetchById(id, session: session) {
                recipe.source = "TheMealDB Database"
                results.append(recipe)
            }
        }
        return results
    }

    nonisolated private static func fetchById(_ id: String, session: URLSession) async -> OnlineRecipe? {
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/lookup.php?i=\(id)"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]],
              let meal = meals.first else { return nil }
        return Self.parseMeal(meal)
    }

    nonisolated private static func fetchOne(session: URLSession) async -> OnlineRecipe? {
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/random.php"),
              !Task.isCancelled else { return nil }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]],
              let meal = meals.first else { return nil }
        return Self.parseMeal(meal)
    }

    nonisolated func parseMealPublic(_ m: [String: Any]) -> OnlineRecipe? { Self.parseMeal(m) }

    nonisolated private static func parseMeal(_ m: [String: Any]) -> OnlineRecipe? {
        guard let id    = m["idMeal"]  as? String,
              let title = m["strMeal"] as? String else { return nil }
        var ingredients: [String] = []; var measures: [String] = []
        for i in 1...20 {
            let ing  = (m["strIngredient\(i)"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let meas = (m["strMeasure\(i)"]    as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !ing.isEmpty { ingredients.append(ing); measures.append(meas) }
        }
        return OnlineRecipe(
            id: id, title: title,
            category: m["strCategory"] as? String ?? "",
            area:     m["strArea"]     as? String ?? "",
            instructions: m["strInstructions"] as? String ?? "",
            imageURL: m["strMealThumb"] as? String ?? "",
            ingredients: ingredients, measures: measures,
            source: "TheMealDB"
        )
    }

    // MARK: - Source 3: Open Meals (free community recipe API)
    // https://www.themealdb.com/api/json/v1/1/search.php?f=X — fetch by first letter
    nonisolated private static func fetchByLetter(_ letter: String, session: URLSession) async -> [OnlineRecipe] {
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/search.php?f=\(letter)"),
              !Task.isCancelled else { return [] }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]] else { return [] }
        return meals.shuffled().prefix(5).compactMap { Self.parseMeal($0) }
                    .map { var r = $0; r.source = "MealDB Search"; return r }
    }

    // MARK: - Source 6: Wger Nutritional Plan (free workout/nutrition API — recipe section)
    // Uses TheMealDB area filter to pull country-specific recipes (more variety)
    nonisolated private static func fetchByArea(_ area: String, session: URLSession) async -> [OnlineRecipe] {
        let enc = area.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? area
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/filter.php?a=\(enc)"),
              !Task.isCancelled else { return [] }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]] else { return [] }
        let picked = meals.shuffled().prefix(3)
        var results: [OnlineRecipe] = []
        let config = URLSessionConfiguration.default; config.timeoutIntervalForRequest = 8
        let s = URLSession(configuration: config)
        for m in picked {
            guard let id = m["idMeal"] as? String else { continue }
            if var recipe = await Self.fetchById(id, session: s) {
                recipe.source = "\(area) Kitchen"
                results.append(recipe)
            }
        }
        return results
    }

    /// Near-linear recipe merge. Exact normalized titles merge immediately; fuzzy checks are
    /// limited to a small first-word bucket rather than comparing every recipe with every other.
    private nonisolated static func deduplicateAndMerge(_ input: [OnlineRecipe]) -> [OnlineRecipe] {
        var merged: [OnlineRecipe] = []
        var keys: [String] = []
        var ingredientNames: [Set<String>] = []
        var exactIndex: [String: Int] = [:]
        var leadBuckets: [String: [Int]] = [:]

        func mergedRecipe(_ existing: OnlineRecipe, _ candidate: OnlineRecipe) -> OnlineRecipe {
            OnlineRecipe(
                id: existing.id,
                title: existing.title,
                category: existing.category.isEmpty ? candidate.category : existing.category,
                area: existing.area.isEmpty ? candidate.area : existing.area,
                instructions: RecipeMerge.bestSteps(
                    existing.instructions.components(separatedBy: "\n"),
                    candidate.instructions.components(separatedBy: "\n")
                ).joined(separator: "\n"),
                imageURL: RecipeMerge.best(imageA: existing.imageURL, imageB: candidate.imageURL),
                ingredients: RecipeMerge.unionIngredients(existing.ingredients, candidate.ingredients),
                measures: existing.measures.count >= candidate.measures.count ? existing.measures : candidate.measures,
                source: RecipeSourceHub.canonicalSourceName(existing.source)
            )
        }

        for raw in input {
            guard RecipeSourceHub.isFullRecipe(raw) else { continue }
            if raw.imageURL.isEmpty && RecipeSourceHub.canonicalSourceName(raw.source) != "Wikibooks Cookbook" { continue }

            let recipe = OnlineRecipe(
                id: raw.id,
                title: raw.title,
                category: raw.category,
                area: raw.area,
                instructions: raw.instructions,
                imageURL: raw.imageURL,
                ingredients: raw.ingredients,
                measures: raw.measures,
                source: RecipeSourceHub.canonicalSourceName(raw.source)
            )
            let key = RecipeDedup.key(recipe.title)
            guard !key.isEmpty else { continue }
            let names = Set(RecipeIngredients.names(recipe.ingredients))

            var duplicateIndex = exactIndex[key]
            if duplicateIndex == nil {
                let lead = key.split(separator: " ").first.map(String.init) ?? key
                let candidates = leadBuckets[lead, default: []]
                duplicateIndex = candidates.first { index in
                    abs(keys[index].count - key.count) <= 18 &&
                    RecipeDedup.areSameKeyed(
                        keyA: keys[index], namesA: ingredientNames[index],
                        keyB: key, namesB: names
                    )
                }
            }

            if let index = duplicateIndex {
                merged[index] = mergedRecipe(merged[index], recipe)
                ingredientNames[index] = Set(RecipeIngredients.names(merged[index].ingredients))
                exactIndex[key] = index
            } else {
                let index = merged.count
                merged.append(recipe)
                keys.append(key)
                ingredientNames.append(names)
                exactIndex[key] = index
                let lead = key.split(separator: " ").first.map(String.init) ?? key
                leadBuckets[lead, default: []].append(index)
            }
        }
        return merged
    }

    private func saveCacheAsync(_ recipes: [OnlineRecipe]) {
        let savedAt = Date()
        cachedAt = savedAt
        let cacheKey = self.cacheKey
        let timestampKey = self.cacheTimestampKey
        Task(priority: .background) {
            await OnlineRecipesPersistentCache.shared.save(
                recipes, cacheKey: cacheKey, timestampKey: timestampKey, savedAt: savedAt)
        }
    }
}

// MARK: - Online Recipes View
struct OnlineRecipesView: View {
    @Environment(AppSession.self) var session
    @State private var loader       = OnlineRecipesLoader.shared
    @State private var selected:    OnlineRecipe?
    @State private var searchText   = ""
    @State private var isFocused    = false
    @State private var selectedCuisine: String? = nil   // #20 cuisine filter
    @State private var hideAllergens = false             // #251 allergen filter toggle
    @State private var selectedDiet: String? = nil       // #261 diet filter chip
    // #C1 — filters now SEED from the saved dietary profile so protection is the
    // default, not an every-session opt-in. The buttons still toggle per session.
    @State private var seededFromProfile = false
    @State private var showProfileEditor = false   // #C1 — banner "Edit" sheet

    // Predictive suggestions from local RecipeDatabase
    @State private var dbSnapshot:    [RecipeDatabaseEntry] = []
    @State private var dbSuggestions: [RecipeDatabaseEntry] = []

    @State private var displayRecipes: [OnlineRecipe] = []
    @State private var suggestionTask: Task<Void, Never>?

    // Live TheMealDB search
    @State private var isSearching  = false
    @State private var liveResults: [OnlineRecipe] = []
    @State private var searchTask:  Task<Void, Never>? = nil

    let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    private struct RecipeFilterKey: Hashable {
        let loaderRevision: Int
        let liveResultIDs: [String]
        let searchText: String
        let cuisine: String?
        let hideAllergens: Bool
        let diet: String?
        let allergens: [String]
    }

    private var filterKey: RecipeFilterKey {
        RecipeFilterKey(
            loaderRevision: loader.revision,
            liveResultIDs: liveResults.map(\.id),
            searchText: searchText,
            cuisine: selectedCuisine,
            hideAllergens: hideAllergens,
            diet: selectedDiet,
            allergens: session.guestStore.cookingProfile.allergens
        )
    }

    private nonisolated static func filteredRecipes(
        loaderRecipes: [OnlineRecipe],
        liveResults: [OnlineRecipe],
        searchText: String,
        selectedCuisine: String?,
        hideAllergens: Bool,
        allergens: [String],
        selectedDiet: String?
    ) -> [OnlineRecipe] {
        func cuisineFiltered(_ list: [OnlineRecipe]) -> [OnlineRecipe] {
            guard let cuisine = selectedCuisine else { return list }
            let target = RecipeTaxonomy.canonicalCuisine(cuisine)
            return list.filter { RecipeTaxonomy.canonicalCuisine($0.area) == target }
        }

        let base: [OnlineRecipe]
        if !liveResults.isEmpty {
            base = cuisineFiltered(liveResults)
        } else if searchText.isEmpty {
            base = cuisineFiltered(loaderRecipes)
        } else {
            let query = searchText.lowercased()
            // nonisolated context: use the pure parser overload. This filter only reads
            // parsedQuery.exclude/.cuisine/.mealType/.hasStructure (all text-pattern derived),
            // not .ingredients — so the main-actor knowledge-base list isn't needed here.
            let parsedQuery = NLQueryParser.parse(searchText, knownIngredients: [])
            base = cuisineFiltered(loaderRecipes).filter { recipe in
                let basic = recipe.title.lowercased().contains(query) ||
                    recipe.area.lowercased().contains(query) ||
                    recipe.category.lowercased().contains(query) ||
                    recipe.ingredients.contains { $0.lowercased().contains(query) }
                if !parsedQuery.hasStructure { return basic }

                let allText = ([recipe.title, recipe.area, recipe.category] + recipe.ingredients)
                    .joined(separator: " ").lowercased()
                for excluded in parsedQuery.exclude where allText.contains(excluded) {
                    return false
                }
                if let cuisine = parsedQuery.cuisine, !allText.contains(cuisine) { return false }
                if let meal = parsedQuery.mealType, !allText.contains(meal) { return false }
                return basic
            }
        }

        var filtered = base.filter {
            OnlineRecipeFacts.hasRealInstructions($0.instructions)
        }
        if hideAllergens, !allergens.isEmpty {
            filtered = filtered.filter {
                OnlineRecipeFacts.allergenHits($0, allergens: allergens).isEmpty
            }
        }
        if let diet = selectedDiet {
            filtered = filtered.filter { recipe in
                let flags = DietaryClassifier.flags(
                    for: recipe.ingredients,
                    title: recipe.title
                )
                switch diet {
                case "Vegan":       return flags.vegan
                case "Vegetarian":  return flags.vegetarian || flags.vegan
                case "Gluten-Free": return flags.glutenFree
                default:            return true
                }
            }
        }
        return filtered
    }

    private var hasAllergens: Bool { !session.guestStore.cookingProfile.allergens.filter { !$0.isEmpty }.isEmpty }

    var body: some View {
        ScrollView(showsIndicators: false) {
        VStack(alignment: .leading, spacing: 0) {
            // ── Header ───────────────────────────────────────────────
            HStack {
                Text("Discover Recipes")
                    .font(.system(size: 14, weight: .bold)).foregroundStyle(session.themeTextColor)
                    .onAppear {
                        // #C1 — apply the saved dietary profile once per session: allergen
                        // hide defaults ON when allergens are saved; the diet chip seeds
                        // from the profile's dietary style when it maps to a chip.
                        guard !seededFromProfile else { return }
                        seededFromProfile = true
                        let profile = session.guestStore.cookingProfile
                        if !profile.allergens.filter({ !$0.isEmpty }).isEmpty { hideAllergens = true }
                        if selectedDiet == nil {
                            switch profile.dietaryStyle.lowercased() {
                            case "vegan":        selectedDiet = "Vegan"
                            case "vegetarian":   selectedDiet = "Vegetarian"
                            case "gluten-free":  selectedDiet = "Gluten-Free"
                            default: break
                            }
                        }
                    }
                Spacer()
                if loader.isLoading || isSearching {
                    ProgressView().scaleEffect(0.7).tint(Color.stockedGold)
                } else {
                    Button { loader.forceRefresh(profile: session.guestStore.cookingProfile) } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.system(size: 12)).foregroundStyle(Color.stockedGold)
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 8)

            // #C1 glue — when the saved profile is shaping results, say so and give a
            // one-tap path to edit it (discoverability for the Toolbox editor).
            if hideAllergens || selectedDiet != nil {
                Button { showProfileEditor = true } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "leaf.circle.fill").font(.system(size: 12))
                            .foregroundStyle(Color.stockedGreen)
                        Text("Filtered for your dietary profile")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.6))
                        Text("Edit")
                            .font(.system(size: 11.5, weight: .bold))
                            .foregroundStyle(Color.stockedGold)
                        Spacer()
                    }
                    .padding(.horizontal, 24).padding(.bottom, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .a11yButton("Filtered for your dietary profile. Edit profile")
                .sheet(isPresented: $showProfileEditor) {
                    NavigationStack { DietaryProfileView().environment(session) }
                }
            }

            // ── Search bar + predictive chips ────────────────────────
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                    TextField("Try \"quick chicken no dairy\" or \"Italian breakfast\"…", text: $searchText)
                                            .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
.font(.system(size: 14)).foregroundStyle(session.themeTextColor)
                        .autocorrectionDisabled()
                        .onSubmit { runLiveSearch() }
                        .onChange(of: searchText) { _, q in
                            updateSuggestions(q)
                            // Clear live results when user edits the query
                            if liveResults.isEmpty == false { liveResults = [] }
                        }
                    if isSearching {
                        ProgressView().scaleEffect(0.65).tint(Color.stockedGold)
                    } else if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            dbSuggestions = []
                            liveResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(session.themeTextColor.opacity(0.35))
                        }
                    }
                }
                .padding(10)

                // ── Predictive recipe chips ──────────────────────────
                if !dbSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 4) {
                            Image(systemName: "book.closed.fill")
                                .font(.system(size: 10)).foregroundStyle(Color.stockedGold.opacity(0.7))
                            Text("Matching Recipes")
                                .font(.system(size: 10, weight: .semibold, design: .serif))
                                .foregroundStyle(Color.stockedGold.opacity(0.7))
                        }
                        .padding(.horizontal, 10)

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(dbSuggestions) { entry in
                                    Button { selectDBEntry(entry) } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "fork.knife")
                                                .font(.system(size: 11))
                                                .foregroundStyle(Color.stockedGold)
                                            VStack(alignment: .leading, spacing: 1) {
                                                Text(entry.title)
                                                    .font(.system(size: 13, weight: .semibold, design: .serif))
                                                    .foregroundStyle(session.themeTextColor)
                                                    .lineLimit(1)
                                                HStack(spacing: 4) {
                                                    if !entry.cuisine.isEmpty {
                                                        Text(entry.cuisine)
                                                            .font(.system(size: 10))
                                                            .foregroundStyle(.secondary)
                                                    }
                                                    if !entry.sourceName.isEmpty && entry.sourceName != "My Recipes" {
                                                        Text(entry.cuisine.isEmpty ? entry.sourceName : "· \(entry.sourceName)")
                                                            .font(.system(size: 10))
                                                            .foregroundStyle(.secondary)
                                                            .lineLimit(1)
                                                    }
                                                }
                                            }
                                        }
                                        .padding(.horizontal, 11).padding(.vertical, 12)
                                        .background(Color.stockedGold.opacity(0.12))
                                        .overlay(Capsule().stroke(Color.stockedGold.opacity(0.45), lineWidth: 1))
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                }

                                // "Search online for more" pill
                                Button { runLiveSearch() } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: "arrow.up.right")
                                            .font(.system(size: 10, weight: .semibold))
                                        Text("More online")
                                            .font(.system(size: 12, weight: .semibold, design: .serif))
                                    }
                                    .foregroundStyle(session.themeTextColor)
                                    .padding(.horizontal, 12).padding(.vertical, 12)
                                    .background(Color.stockedCharcoal.opacity(0.08))
                                    .overlay(Capsule().stroke(Color.stockedCharcoal.opacity(0.2), lineWidth: 1))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                            .stockedScrollTargetLayout()
                            .padding(.horizontal, 10).padding(.bottom, 8)
                        }
                        .stockedHorizontalSnap()
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .padding(.horizontal, 24).padding(.bottom, 12)
            .animation(.easeInOut(duration: 0.15), value: dbSuggestions.map(\.id))

            // ── Cuisine browsing grid (#20) ─────────────────────────────
            let cuisines = RecipeTaxonomy.cuisines.map { "\(CuisineBrowseView.flag(for: $0)) \($0)" }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    // #251 — allergen hide toggle (only shown if the user set allergens).
                    if hasAllergens {
                        Button {
                            withAnimation(.spring(response: 0.2)) { hideAllergens.toggle() }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: hideAllergens ? "checkmark.shield.fill" : "shield")
                                    .font(.system(size: 11, weight: .bold))
                                Text("Hide allergens").font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(hideAllergens ? Color.stockedWhite : (session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(hideAllergens ? Color.stockedError.opacity(0.9) : Color.stockedCharcoal.opacity(0.08))
                            .clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                    // #261 — diet filter chips: keep only recipes whose inferred dietary
                    // flags include the chosen diet (DietaryClassifier, same as the badges).
                    ForEach(["Vegetarian", "Vegan", "Gluten-Free"], id: \.self) { diet in
                        Button {
                            withAnimation(.spring(response: 0.2)) {
                                selectedDiet = selectedDiet == diet ? nil : diet
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: "leaf").font(.system(size: 10, weight: .bold))
                                Text(diet).font(.system(size: 12, weight: .semibold))
                            }
                            .foregroundStyle(selectedDiet == diet ? Color.stockedWhite : (session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(selectedDiet == diet ? Color.stockedGreen : Color.stockedCharcoal.opacity(0.08))
                            .clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                    ForEach(cuisines, id: \.self) { cuisine in
                        let name = cuisine.components(separatedBy: " ").dropFirst().joined(separator: " ")
                        Button {
                            withAnimation(.spring(response: 0.2)) {
                                selectedCuisine = selectedCuisine == name ? nil : name
                            }
                        } label: {
                            Text(cuisine)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(selectedCuisine == name ? Color.stockedWhite : (session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(selectedCuisine == name ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.08))
                                .clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                    if selectedCuisine != nil {
                        Button { withAnimation { selectedCuisine = nil } } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(Color.stockedGold)
                                .font(.system(size: 16))
                        }.buttonStyle(.plain)
                    }
                }
                .stockedScrollTargetLayout().padding(.horizontal, 24).padding(.bottom, 10)
            }
            .stockedHorizontalSnap()

            // ── Live search label ─────────────────────────────────────
            if !liveResults.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "wifi").font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                    Text("Online results for \"\(searchText)\"  · \(liveResults.count) recipes")
                        .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    Spacer()
                    Button {
                        liveResults = []
                        searchText = ""
                        dbSuggestions = []
                    } label: {
                        Text("Clear").font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 24).padding(.bottom, 6)
            }

            // ── Recipe grid ───────────────────────────────────────────
            if let err = loader.error, loader.recipes.isEmpty, liveResults.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.slash").font(.system(size: 32))
                        .foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text(err).font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        .multilineTextAlignment(.center)
                    Button { loader.forceRefresh(profile: session.guestStore.cookingProfile) } label: {
                        Text("Try Again").font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.stockedWhite)
                            .padding(.horizontal, 24).padding(.vertical, 10)
                            .background(Color.stockedCharcoal).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }.frame(maxWidth: .infinity).padding(.top, 30)
            } else if loader.recipes.isEmpty && liveResults.isEmpty && (loader.isLoading || isSearching) {
                // Show shaped placeholders WHILE fetching so the layout doesn't jump (#14).
                SkeletonListView(count: 5).padding(.top, 10)
            } else if loader.recipes.isEmpty && liveResults.isEmpty {
                // Finished loading with nothing to show — friendly empty state (#3).
                StockedEmptyState(
                    icon: "🍳",
                    title: "No recipes yet",
                    subtitle: "Pull to refresh, or search for something you're in the mood for.",
                    tips: ["Try a cuisine like \"Italian\" or \"Thai\"", "Search a main ingredient you have on hand"]
                )
                .padding(.top, 10)
            } else {
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(displayRecipes) { recipe in
                        Button { selected = recipe } label: {
                            OnlineRecipeCard(recipe: recipe)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }
                }
                .padding(.horizontal, 20)
                .animation(.easeInOut(duration: 0.25), value: displayRecipes.count)
            }
        }
        } // end ScrollView
        .onAppear {
            loader.loadIfNeeded(profile: session.guestStore.cookingProfile)
            Task { dbSnapshot = await RecipeDatabaseManager.shared.loadSnapshot() }
        }
        .task(id: filterKey) {
            if !searchText.isEmpty {
                try? await Task.sleep(nanoseconds: 90_000_000)
            }
            guard !Task.isCancelled else { return }
            let loaderRecipes = loader.recipes
            let live = liveResults
            let query = searchText
            let cuisine = selectedCuisine
            let shouldHideAllergens = hideAllergens
            let allergens = session.guestStore.cookingProfile.allergens
            let diet = selectedDiet
            let filtered = await Task.detached(priority: .userInitiated) {
                Self.filteredRecipes(
                    loaderRecipes: loaderRecipes,
                    liveResults: live,
                    searchText: query,
                    selectedCuisine: cuisine,
                    hideAllergens: shouldHideAllergens,
                    allergens: allergens,
                    selectedDiet: diet
                )
            }.value
            guard !Task.isCancelled else { return }
            displayRecipes = filtered
            ImageCache.shared.prefetch(
                urls: filtered.prefix(40).map(\.imageURL).filter { !$0.isEmpty })
        }
        .onDisappear {
            suggestionTask?.cancel()
            searchTask?.cancel()
        }
        .sheet(item: $selected) { recipe in
            OnlineRecipeDetailView(recipe: recipe).environment(session)
        }
    }

    // MARK: - Predictive helpers
    private func updateSuggestions(_ query: String) {
        suggestionTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            dbSuggestions = []
            return
        }
        let snapshot = dbSnapshot
        suggestionTask = Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            let suggestions = await Task.detached(priority: .userInitiated) {
                let query = trimmed.lowercased()
                let byTitle = snapshot.filter {
                    $0.title.lowercased().hasPrefix(query)
                }
                let byAnywhere = snapshot.filter { entry in
                    let index = ([entry.title, entry.description, entry.category, entry.cuisine]
                        + entry.tags + entry.ingredients + [entry.sourceName])
                        .joined(separator: " ").lowercased()
                    return !entry.title.lowercased().hasPrefix(query) && index.contains(query)
                }
                return Array((byTitle + byAnywhere).prefix(6))
            }.value
            guard !Task.isCancelled else { return }
            dbSuggestions = suggestions
        }
    }

    // Convert a local RecipeDatabaseEntry → OnlineRecipe for the detail sheet
    private func selectDBEntry(_ entry: RecipeDatabaseEntry) {
        let recipe = OnlineRecipe(
            id:           entry.id.uuidString,
            title:        entry.title,
            category:     entry.category,
            area:         entry.cuisine,
            instructions: entry.steps.joined(separator: "\n\n"),
            imageURL:     entry.imageURL,
            ingredients:  entry.ingredients.map { line -> String in
                let parts = line.split(separator: " ", maxSplits: 1)
                return parts.count > 1 ? String(parts[1]) : line
            },
            measures:     entry.ingredients.map { line -> String in
                line.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            },
            source:       entry.sourceName
        )
        dbSuggestions = []
        selected = recipe
        // Snapshot keeps growing as user discovers more
        Task { dbSnapshot = await RecipeDatabaseManager.shared.loadSnapshot() }
    }

    // MARK: - Live TheMealDB search
    private func runLiveSearch() {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { return }
        searchTask?.cancel()
        isSearching = true
        dbSuggestions = []
        searchTask = Task {
            defer { Task { @MainActor in isSearching = false } }
            let enc = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
            guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/search.php?s=\(enc)"),
                  let (data, _) = try? await URLSession.shared.data(from: url),
                  !Task.isCancelled else { return }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let meals = json["meals"] as? [[String: Any]] else {
                // No results — clear
                await MainActor.run { isSearching = false }
                return
            }
            var parsed: [OnlineRecipe] = []
            for m in meals {
                if let r = loader.parseMealPublic(m) { parsed.append(r) }
            }
            await MainActor.run {
                liveResults = parsed
                isSearching = false
            }
            // Learn all results into RecipeDatabase for future predictive use
            for r in parsed { StockedKnowledgeBase.shared.learnFromOnlineRecipe(r) }
            // Refresh snapshot so chips reflect new entries next time
            let fresh = await RecipeDatabaseManager.shared.loadSnapshot()
            await MainActor.run { dbSnapshot = fresh }
        }
    }
}

// MARK: - Recipe Card with cached images
struct OnlineRecipeCard: View {
    @Environment(AppSession.self) var session
    let recipe: OnlineRecipe

    // Deterministic emoji per category for recipes without images
    private var fallbackEmoji: String {
        let c = recipe.category.lowercased()
        if c.contains("chicken") || c.contains("poultry") { return "🍗" }
        if c.contains("beef") || c.contains("lamb") { return "🥩" }
        if c.contains("seafood") || c.contains("fish") { return "🐟" }
        if c.contains("pasta") || c.contains("noodle") { return "🍝" }
        if c.contains("dessert") || c.contains("cake") { return "🍰" }
        if c.contains("breakfast") { return "🥞" }
        if c.contains("vegan") || c.contains("vegetarian") { return "🥗" }
        if c.contains("soup") || c.contains("stew") { return "🍲" }
        if c.contains("drink") || c.contains("cocktail") { return "🍹" }
        if c.contains("side") { return "🥘" }
        if c.contains("pork") { return "🥓" }
        return "🍽️"
    }

    private var sourceTag: String {
        switch recipe.source {
        case "TheMealDB", "TheMealDB Database": return "MealDB"
        case "Spoonacular": return "Spoonacular"
        case "TheCocktailDB": return "Cocktails"
        case "DummyJSON": return "Community"
        case "RecipeNLG": return "RecipeNLG"
        default: return recipe.source.isEmpty ? "Online" : recipe.source
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if recipe.imageURL.isEmpty {
                    ZStack {
                        Rectangle().fill(Color.stockedGold.opacity(0.12)).frame(height: 120)
                        Text(fallbackEmoji).font(.system(size: 48))
                    }
                } else {
                    CachedAsyncImage(url: recipe.imageURL, imageData: nil, height: 120, resolveName: recipe.title, resolveCategory: recipe.category)
                }
                // #251 — live badges: can-I-make-this + already-saved.
                HStack(spacing: 4) {
                    cardStatusBadge
                    if OnlineRecipeFacts.isSaved(recipe, savedTitles: session.guestStore.savedRecipeTitles) {
                        badge(text: "Saved", system: "bookmark.fill", bg: Color.stockedGold.opacity(0.95))
                    }
                }
                .padding(6)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(recipe.title)
                    .font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(session.themeTextColor).lineLimit(2)

                // #251 — allergen flag (only when the user has allergens configured).
                let hits = OnlineRecipeFacts.allergenHits(recipe, allergens: session.guestStore.cookingProfile.allergens)
                if !hits.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 8.5, weight: .bold))
                        Text("Contains: \(hits.joined(separator: ", "))")
                            .font(.system(size: 9.5, weight: .semibold)).lineLimit(1)
                    }
                    .foregroundStyle(Color.stockedError)
                }

                HStack(spacing: 4) {
                    if !recipe.area.isEmpty {
                        Text(recipe.area)
                            .font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                    if !recipe.area.isEmpty && !recipe.category.isEmpty {
                        Text("·").font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.3))
                    }
                    if !recipe.category.isEmpty {
                        Text(recipe.category)
                            .font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                    Spacer()
                    Text(sourceTag)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(session.themeTextColor.opacity(0.08))
                        .clipShape(Capsule())
                }
            }
            .padding(10)
            .background(session.themeBgColor)
        }
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    }

    @ViewBuilder private var cardStatusBadge: some View {
        let inStock = session.guestStore.inStockNameSet
        let expiringNames = session.guestStore.expiringSoonItems.map { $0.name.lowercased() }
        let coverage = RecipeCoverageBuilder.make(
            for: recipe,
            inStock: inStock,
            expiringNames: expiringNames
        )
        if inStock.isEmpty || coverage.total == 0 {
            EmptyView()
        } else if coverage.isReady {
            badge(text: "Ready", system: "checkmark.circle.fill", bg: Color.stockedGreen)
        } else {
            // Coverage already performed the canonical stock match. Reusing it avoids
            // repeating the ingredient × pantry matcher for every visible card.
            let missing = coverage.missingCount
            HStack(spacing: 5) {
                MatchRing(coverage: coverage, size: 26)
                badge(
                    text: missing == 1 ? "1 missing" : "\(missing) missing",
                    system: nil,
                    bg: Color.stockedError.opacity(0.92)
                )
            }
        }
    }

    private func badge(text: String, system: String?, bg: Color) -> some View {
        HStack(spacing: 3) {
            if let system { Image(systemName: system).font(.system(size: 8, weight: .bold)) }
            Text(text).font(.system(size: 9.5, weight: .bold))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(bg).clipShape(Capsule())
        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
    }
}

// MARK: - Detail View
struct OnlineRecipeDetailView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let recipe: OnlineRecipe
    @State private var addedIngredients = false
    @State private var addedToCalendar  = false
    @State private var planningContext: CookLaterContext? = nil
    @State private var savedRecipeID: UUID? = nil   // set when saved to My Collection (heart)
    // #9 live cooking — per-recipe step timers (notification + Live Activity backed).
    @State private var timerEngine = StepTimerEngine()
    @State private var repairedIngredients: [AIRecipe.Ingredient] = []
    @State private var aiFixingIngredients = false
    @State private var detailSnapshot = OnlineRecipeDetailSnapshot.empty

    private var ingredientRepairKey: String { "online:\(recipe.id):\(recipe.title)" }

    /// The repaired list becomes the single source of truth for display, grocery actions,
    /// calendar planning, and saving to My Collection. The original feed remains untouched.
    private var displayedRecipe: OnlineRecipe {
        guard !repairedIngredients.isEmpty else { return recipe }
        return OnlineRecipe(
            id: recipe.id, title: recipe.title, category: recipe.category, area: recipe.area,
            instructions: recipe.instructions, imageURL: recipe.imageURL,
            ingredients: repairedIngredients.map {
                [$0.name, ($0.prep ?? "").trimmingCharacters(in: .whitespacesAndNewlines)]
                    .filter { !$0.isEmpty }.joined(separator: ", ")
            },
            measures: repairedIngredients.map { $0.amount }, source: recipe.source
        )
    }

    private var displayedIngredientLines: [(measure: String, ingredient: String)] {
        displayedRecipe.ingredientLines
    }

    private var instructionSteps: [String] { detailSnapshot.steps }

    // #251 — live "can I make this?" badge for the detail header.
    @ViewBuilder private var detailStockBadge: some View {
        let coverage = detailSnapshot.coverage
        HStack(spacing: 10) {
            if coverage.total > 0 {
                MatchRing(coverage: coverage, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                switch detailSnapshot.stockStatus {
                case .ready:
                    HStack(spacing: 5) {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 11, weight: .bold))
                        Text("You can make this now").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.stockedGreen).clipShape(Capsule())
                case .missing(let n):
                    HStack(spacing: 5) {
                        Image(systemName: "cart.badge.plus").font(.system(size: 11, weight: .bold))
                        Text(n == 1 ? "1 ingredient missing" : "\(n) ingredients missing").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.stockedError.opacity(0.92)).clipShape(Capsule())
                case .unknown:
                    EmptyView()
                }
                // Plain-language explanation ("Missing only sour cream", "Uses chicken expiring soon").
                if let line = MatchExplanation.line(for: coverage) {
                    Text(line)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
            }
        }
    }

    // #251 — best-effort link to the original. TheMealDB recipes have public pages by id;
    // anything else falls back to a web search for the title + source.
    private var sourceURL: URL? {
        let src = recipe.source.lowercased()
        if src.contains("mealdb"), Int(recipe.id) != nil {
            return URL(string: "https://www.themealdb.com/meal/\(recipe.id)")
        }
        let q = "\(recipe.title) \(recipe.source) recipe"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return URL(string: "https://www.google.com/search?q=\(q)")
    }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        CachedAsyncImage(url: recipe.imageURL, imageData: nil, height: 240, resolveName: recipe.title, resolveCategory: recipe.category)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)).padding(.horizontal, 20)

                        VStack(alignment: .leading, spacing: 10) {
                            Text(recipe.title)
                                .font(.system(size: RecipeTextPrefs.shared.scaled(24), weight: .bold, design: .serif)).dynamicTypeSize(.xSmall ... .accessibility2)
                                .foregroundStyle(session.themeTextColor)
                            Text([recipe.area, recipe.category].filter { !$0.isEmpty }.joined(separator: " · "))
                                .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))

                            // #251 — "Can I make this?" computed live against the pantry.
                            detailStockBadge

                            // #12 auto-inferred dietary tags from the ingredient list (+ title
                            // so meat dishes like "Lamb Chops" aren't mislabeled when the
                            // ingredient list is sparse).
                            if !detailSnapshot.dietLabels.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(detailSnapshot.dietLabels, id: \.self) { label in
                                        Text(label)
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.stockedGreen)
                                            .padding(.horizontal, 9).padding(.vertical, 4)
                                            .background(Color.stockedGreen.opacity(0.12))
                                            .clipShape(Capsule())
                                    }
                                }
                            }

                            // #251 — allergen warning (only when the user has allergens set).
                            let allergenHits = detailSnapshot.allergenHits
                            if !allergenHits.isEmpty {
                                HStack(spacing: 6) {
                                    Image(systemName: "exclamationmark.triangle.fill")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Color.stockedError)
                                    Text("Contains: \(allergenHits.joined(separator: ", "))")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.stockedError)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.stockedError.opacity(0.10))
                                .clipShape(Capsule())
                            }
                        }.padding(.horizontal, 24)

                        VStack(spacing: 10) {
                            Button {
                                autoFillIngredients()
                                RecipeInterest.shared.record(category: recipe.category, area: recipe.area,
                                                             ingredients: displayedIngredientLines.map(\.ingredient),
                                                             event: .groceryAdded)
                                withAnimation(.spring(response: 0.3)) { addedIngredients = true }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: addedIngredients ? "checkmark.circle.fill" : "cart.badge.plus")
                                    Text(addedIngredients ? "Added to grocery list!" : "Add missing ingredients to list")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(addedIngredients ? Color.stockedGreen : Color.stockedWhite)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(addedIngredients ? Color.stockedGreen.opacity(0.12) : Color.stockedCharcoal)
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                            }.disabled(addedIngredients)

                            Button {
                                StockedKnowledgeBase.shared.learnFromOnlineRecipe(displayedRecipe)
                                let ingredients = displayedRecipe.ingredientLines.map {
                                    [ $0.measure, $0.ingredient ].filter { !$0.isEmpty }.joined(separator: " ")
                                }
                                planningContext = .recipe(
                                    title: recipe.title,
                                    ingredients: ingredients,
                                    servings: max(1, session.guestStore.cookingProfile.householdSize),
                                    imageURL: recipe.imageURL,
                                    suggestedDay: 1
                                )
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: addedToCalendar ? "checkmark.circle.fill" : "calendar.badge.plus")
                                    Text(addedToCalendar ? "Planned in Cook Later" : "Plan in Cook Later")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(addedToCalendar ? Color.stockedGold : Color.stockedCharcoal)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Color.stockedGold.opacity(addedToCalendar ? 0.18 : 0.10))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                                .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL).stroke(Color.stockedGold.opacity(0.4), lineWidth: 1))
                            }
                        }.padding(.horizontal, 24)

                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text("Ingredients")
                                    .font(.system(size: 16, weight: .bold, design: .serif))
                                    .foregroundStyle(session.themeTextColor)
                                Spacer()
                                if RecipeImportAI.isAvailable {
                                    Button { Task { await fixIngredientsWithAI() } } label: {
                                        HStack(spacing: 4) {
                                            if aiFixingIngredients { ProgressView().controlSize(.mini) }
                                            else { Image(systemName: "wand.and.stars").font(.system(size: 11)) }
                                            Text(aiFixingIngredients ? "Fixing…" : "Fix ingredients")
                                                .font(.system(size: 11.5, weight: .semibold))
                                        }
                                        .foregroundStyle(Color.stockedGold)
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .background(Color.stockedGold.opacity(0.12)).clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(aiFixingIngredients)
                                    .a11yButton("Fix ingredients with AI")
                                }
                            }
                            ForEach(Array(displayedIngredientLines.enumerated()), id: \.offset) { _, pair in
                                HStack(spacing: 10) {
                                    Circle().fill(Color.stockedGold).frame(width: 6, height: 6)
                                    Text([pair.measure, pair.ingredient].filter { !$0.isEmpty }.joined(separator: " "))
                                        .font(.system(size: RecipeTextPrefs.shared.scaled(14))).foregroundStyle(session.themeTextColor)
                                    Spacer(minLength: 0)
                                    // Subtle, predictive: tap to convert units / see substitutions (no typing).
                                    IngredientActionsButton(measure: pair.measure, name: pair.ingredient)
                                }
                                .ingredientQuickActions(measure: pair.measure, name: pair.ingredient)
                            }
                        }
                        .padding(16).background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .padding(.horizontal, 24)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Instructions")
                                .font(.system(size: 16, weight: .bold, design: .serif)).foregroundStyle(session.themeTextColor)
                            if detailSnapshot.hasRealInstructions {
                                // #9 live cooking — numbered steps; any step that mentions a
                                // duration gets a tappable timer (notification + Live Activity).
                                let steps = instructionSteps
                                if steps.isEmpty {
                                    Text(recipe.instructions)
                                        .font(.system(size: RecipeTextPrefs.shared.scaled(14))).foregroundStyle(session.themeTextColor.opacity(0.8))
                                        .fixedSize(horizontal: false, vertical: true)
                                } else {
                                    VStack(alignment: .leading, spacing: 14) {
                                        ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                                            TimedStepRow(stepNumber: i + 1, stepText: step, timerEngine: timerEngine)
                                        }
                                    }
                                }
                            } else {
                                // This source (e.g. Edamam) doesn't provide step-by-step
                                // instructions. Show an honest message instead of a raw
                                // link; the full method is one tap away via View source.
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: "doc.text.magnifyingglass")
                                        .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.45))
                                    Text(sourceURL != nil
                                         ? "This source doesn't include step-by-step instructions here. Tap View source below for the full method."
                                         : "This source doesn't include step-by-step instructions.")
                                        .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.6))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                        .padding(16).background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .padding(.horizontal, 24)

                        // #251 — source attribution + link out to the original.
                        if !recipe.source.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "link").font(.system(size: 11))
                                Text("Recipe from \(recipe.source)")
                                    .font(.system(size: 12))
                                if sourceURL != nil {
                                    Spacer()
                                    Text("View source")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.stockedGold)
                                }
                            }
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                            .padding(.horizontal, 24)
                            .contentShape(Rectangle())
                            .onTapGesture { if let url = sourceURL { UIApplication.shared.open(url) } }
                        }

                        Color.clear.frame(height: 18)
                    }
                }
            }
            .navigationTitle(recipe.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(session.themeBgColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarBackground(session.themeBgColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(session.isDarkMode ? .dark : .light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { toggleSaveToCollection() } label: {
                        Image(systemName: savedRecipeID != nil ? "heart.fill" : "heart")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(savedRecipeID != nil ? Color.stockedGold : session.themeTextColor.opacity(0.6))
                    }
                    .accessibilityLabel(savedRecipeID != nil ? "Remove from My Collection" : "Save to My Collection")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.stockedGold)
                }
            }
            .onAppear {
                // Reflect existing save state: match by title against My Collection.
                if let existing = session.guestStore.userRecipes.first(where: {
                    $0.title.caseInsensitiveCompare(recipe.title) == .orderedSame
                }) {
                    savedRecipeID = existing.id
                }
                // #251 — opening a recipe is a strong interest signal.
                RecipeInterest.shared.record(category: recipe.category, area: recipe.area)
                UsageMetrics.shared.record(.onlineRecipeOpened)
                // #9 — context for step timers surfaced on the Lock Screen / Dynamic Island.
                timerEngine.recipeTitle = recipe.title
                timerEngine.totalSteps  = instructionSteps.count
            }
            .task { await prepareDetail() }
        }
        .sheet(item: $planningContext) { context in
            NavigationStack {
                CookLaterWorkspaceView(context: context) {
                    withAnimation(.spring(response: 0.3)) { addedToCalendar = true }
                }
                .environment(session)
            }
        }
    }

    private func prepareDetail() async {
        if repairedIngredients.isEmpty,
           let cached = await RecipeIngredientRepairCache.shared.load(for: ingredientRepairKey) {
            repairedIngredients = cached
        }
        let current = displayedRecipe
        let inStock = session.guestStore.inStockNameSet
        let expiring = session.guestStore.expiringSoonItems.map { $0.name.lowercased() }
        let allergens = session.guestStore.cookingProfile.allergens
        let prepared = await RecipeDetailSnapshotCache.shared.onlineSnapshot(
            recipe: current, inStock: inStock, expiringNames: expiring, allergens: allergens)
        guard !Task.isCancelled else { return }
        detailSnapshot = prepared
        timerEngine.totalSteps = prepared.steps.count
    }

    private func fixIngredientsWithAI() async {
        guard !aiFixingIngredients else { return }
        aiFixingIngredients = true
        defer { aiFixingIngredients = false }
        let raw = RecipeImportAI.composeRawText(
            title: recipe.title,
            description: "Repair and fully reconstruct this ingredient list. Preserve quantities, units, and preparation notes. Remove fragments such as punctuation-only ingredients.",
            ingredients: displayedIngredientLines.map {
                [$0.measure, $0.ingredient].filter { !$0.isEmpty }.joined(separator: " ")
            },
            steps: detailSnapshot.steps.isEmpty ? [recipe.instructions] : detailSnapshot.steps)
        guard let ai = await RecipeImportAI.structure(rawText: raw), !ai.ingredients.isEmpty else {
            ToastCenter.shared.warning("Couldn't repair ingredients — try again later")
            return
        }
        let cleaned = ai.ingredients.filter {
            let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.count > 1 && name.rangeOfCharacter(from: .letters) != nil
        }
        guard !cleaned.isEmpty else {
            ToastCenter.shared.warning("No usable ingredient fixes were returned")
            return
        }
        repairedIngredients = cleaned
        await RecipeIngredientRepairCache.shared.store(cleaned, for: ingredientRepairKey)
        await prepareDetail()
        HapticManager.success()
        ToastCenter.shared.success("Ingredients repaired and cached")
    }

    // Heart toggle — save this online recipe to My Collection, or remove it if already saved.
    private func toggleSaveToCollection() {
        HapticManager.select()
        if let id = savedRecipeID {
            session.guestStore.deleteUserRecipe(id: id)
            RecipeInterest.shared.record(category: recipe.category, area: recipe.area,
                                         ingredients: displayedIngredientLines.map(\.ingredient), event: .dismissed)
            withAnimation(.spring(response: 0.3)) { savedRecipeID = nil }
            return
        }
        // #251 — import with structured ParsedQuantity fields so scaling + grocery
        // consolidation work on this imported recipe like a hand-entered one.
        let id = session.guestStore.importOnlineRecipe(displayedRecipe)
        UsageMetrics.shared.record(.recipeImportedOnline)
        withAnimation(.spring(response: 0.3)) { savedRecipeID = id }
    }

    private func autoFillIngredients() {
        StockedKnowledgeBase.shared.learnFromOnlineRecipe(displayedRecipe)
        let stockedLower = Set(session.guestStore.inventoryItems.map { $0.name.lowercased() })
        for pair in displayedRecipe.ingredientLines {
            let ing = pair.ingredient
            let inStock = stockedLower.contains { $0.contains(ing.lowercased()) || ing.lowercased().contains($0) }
            if !inStock {
                let key = ing.lowercased()
                let alreadyInGrocery = session.guestStore.groceryItems.contains { $0.name.lowercased().contains(key) }
                if !alreadyInGrocery {
                    let label = pair.measure.isEmpty ? ing : "\(pair.measure) \(ing)"
                    session.guestStore.addToGroceryIfMissing(label, recommended: true, recipeSource: recipe.title)
                }
            }
        }
    }
}

#Preview { OnlineRecipesView().environment(AppSession()) }
