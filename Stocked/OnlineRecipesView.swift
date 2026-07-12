// OnlineRecipesView.swift — Database-first recipe discovery with online fallback
import SwiftUI
import Combine

// MARK: - Model
struct OnlineRecipe: Identifiable, Codable, Hashable, Sendable {
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

// MARK: - Loader
@Observable
@MainActor
class OnlineRecipesLoader {
    static let shared = OnlineRecipesLoader()
    var recipes:   [OnlineRecipe] = []
    var isLoading  = false
    var error:     String?

    private let cacheKey = "onlineRecipesCache_v3"
    private let countKey = "appOpenCount"
    private var loadTask: Task<Void, Never>?

    /// Top pantry ingredient names to seed ingredient-based fetches with, so Discover fills
    /// with recipes the user can actually make. Set by callers that have store access; empty
    /// is fine (the phase simply skips).
    private var pantrySeedNames: [String] = []

    // MealDB categories to pull a broad mix
    private let dbCategories = ["Beef","Chicken","Seafood","Vegetarian","Pasta",
                                "Dessert","Breakfast","Side","Lamb","Pork","Vegan"]

    func loadIfNeeded(profile: UserCookingProfile? = nil, pantry: [String] = []) {
        if !pantry.isEmpty { pantrySeedNames = pantry }
        // Show cached results instantly while fresh ones load
        if let cached = loadCacheSync() { recipes = filterByProfile(cached, profile: profile) }
        // #251 — if we have nothing cached yet, seed from the synced local RecipeDatabase
        // so Discover shows real recipes even with no network (graceful offline).
        if recipes.isEmpty { seedFromLocalDatabase(profile: profile) }
        // Always fetch fresh results on every appear
        fetchInBackground(profile: profile)
    }

    /// Pull a batch from the on-device RecipeDatabase (Spoonacular/CocktailDB/MealDB already
    /// synced there) into `recipes` so the UI has content offline. No-ops if empty.
    private func seedFromLocalDatabase(profile: UserCookingProfile?) {
        Task { [weak self] in
            guard let self else { return }
            let entries = await RecipeDatabaseManager.shared.loadSnapshot()
            var local = entries
                .filter { !$0.imageURL.isEmpty && !$0.steps.isEmpty }
                .prefix(60)
                .map { Self.makeOnlineRecipe(from: $0) }
            // #4: the bulk corpus now lives in the read-only SQLite store, not the
            // writable RecipeDatabase. If the writable store has little with images,
            // pull a presentable batch from the corpus. RecipeNLG is text-only, so we
            // require steps (real content) rather than images — the card resolves an
            // image from title/category or shows a fallback emoji.
            if local.count < 12 {
                let corpus = await RecipeDatabaseManager.shared.corpusPresentable(limit: 60)
                local += corpus
                    .filter { !$0.steps.isEmpty }
                    .map { Self.makeOnlineRecipe(from: $0) }
            }
            await MainActor.run {
                guard self.recipes.isEmpty, !local.isEmpty else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    self.recipes = self.filterByProfile(Array(local), profile: profile)
                }
            }
        }
    }

    /// Map a stored recipe entry to the Discover view model.
    private static func makeOnlineRecipe(from entry: RecipeDatabaseEntry) -> OnlineRecipe {
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
    private static func makeOnlineRecipe(from web: WebRecipe) -> OnlineRecipe {
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
        fetchInBackground(profile: profile)
    }
    func cancel() { loadTask?.cancel(); loadTask = nil }

    private func filterByProfile(_ all: [OnlineRecipe], profile: UserCookingProfile?) -> [OnlineRecipe] {
        // Always drop recipes that have no real step-by-step instructions, or whose
        // "instructions" are just a link to the source (e.g. Edamam, which doesn't
        // license step text). These should never surface anywhere in Discover/search.
        let withSteps = all.filter { OnlineRecipeFacts.hasRealInstructions($0.instructions) }

        guard let p = profile, !p.cuisinePrefs.isEmpty else { return withSteps }
        let preferred = p.cuisinePrefs.map { $0.lowercased() }
        return withSteps.sorted { a, b in
            let sA = preferred.contains(where: { a.area.lowercased().contains($0) || a.category.lowercased().contains($0) }) ? 2 : 0
            let sB = preferred.contains(where: { b.area.lowercased().contains($0) || b.category.lowercased().contains($0) }) ? 2 : 0
            return sA > sB
        }
    }

    private func fetchInBackground(profile: UserCookingProfile? = nil) {
        loadTask?.cancel()
        loadTask = Task(priority: .background) { [weak self] in
            guard let self, !Task.isCancelled else { return }
            await MainActor.run { self.isLoading = true; self.error = nil }

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 10
            let session = URLSession(configuration: config)

            var fetched: [OnlineRecipe] = []

            // All MealDB phases share ONE bounded runner. Firing every phase's requests at
            // once was what triggered the 429 rate-limiting seen in logs. This caps how many
            // MealDB calls are in flight simultaneously while still pulling a large volume.
            func boundedGather(_ tasks: [() async -> [OnlineRecipe]], maxConcurrent: Int = 4) async -> [OnlineRecipe] {
                var results: [OnlineRecipe] = []
                var index = 0
                while index < tasks.count {
                    let slice = tasks[index..<min(index + maxConcurrent, tasks.count)]
                    await withTaskGroup(of: [OnlineRecipe].self) { group in
                        for t in slice { group.addTask { await t() } }
                        for await r in group { results += r }
                    }
                    index += maxConcurrent
                }
                return results
            }

            // Phase 1: pull from ALL DB categories (was 11 of 11 — now the full list every
            // refresh for maximum fill), bounded so we don't hammer MealDB.
            let catTasks: [() async -> [OnlineRecipe]] = self.dbCategories.map { cat in
                { await self.fetchByCategory(cat, session: session) }
            }
            fetched += await boundedGather(catTasks)

            // Phase 2: random MealDB recipes for freshness (24, up from 14), bounded.
            let randomTasks: [() async -> [OnlineRecipe]] = (0..<24).map { _ in
                { if let r = await self.fetchOne(session: session) { return [r] } else { return [] } }
            }
            fetched += await boundedGather(randomTasks)

            // Phase 3: Pull from local RecipeDatabase (Spoonacular/CocktailDB already synced there)
            let dbEntries = await RecipeDatabaseManager.shared.loadSnapshot()
            let dbRecipes = dbEntries
                .filter { !$0.imageURL.isEmpty && !$0.steps.isEmpty }
                .shuffled().prefix(60)
                .map { entry -> OnlineRecipe in
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
            fetched.append(contentsOf: dbRecipes)

            // Phase 4: DummyJSON removed — fake placeholder data, not real recipes

            // Phase 5: MealDB by first letter — 6 letters per refresh (was 3), bounded.
            let letters = ["a","b","c","d","e","f","g","h","l","m","p","r","s","t"]
            let letterTasks: [() async -> [OnlineRecipe]] = Array(letters.shuffled().prefix(6)).map { l in
                { await self.fetchByLetter(l, session: session) }
            }
            fetched += await boundedGather(letterTasks)

            // Phase 6: Area-based MealDB — 7 cuisines per refresh (was 4), bounded.
            let areas = ["Italian","French","Japanese","Indian","Mexican","Thai","Greek","Moroccan","Chinese","Spanish","Vietnamese","Turkish","British","American"]
            let areaTasks: [() async -> [OnlineRecipe]] = Array(areas.shuffled().prefix(7)).map { a in
                { await self.fetchByArea(a, session: session) }
            }
            fetched += await boundedGather(areaTasks)

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
            await withTaskGroup(of: [OnlineRecipe].self) { group in
                for term in seedTerms {
                    // Free sources — fire per seed term for broad coverage.
                    group.addTask { await RecipeSourcesPlus.edamam(query: term, limit: 6) }
                    group.addTask { await RecipeSourcesPlus.wikibooksCookbook(query: term, limit: 3) }
                    group.addTask { await RecipeSourcesPlus.mealDBByIngredient(term, limit: 5) }
                }
                // TheCocktailDB — free, no key. Cocktails carry real instructions, so
                // they surface as proper recipes and add variety beyond food dishes.
                group.addTask { await CocktailDBClient.shared.discoverRecipes(limit: 8) }
                // DummyJSON — free, no key, curated recipes with real step-by-step
                // instructions. A batch per refresh, plus per-seed searches for relevance.
                group.addTask { await RecipeSourcesPlus.dummyJSONRecipes(limit: 20) }
                for term in seedTerms {
                    group.addTask { await RecipeSourcesPlus.dummyJSONSearch(term, limit: 6) }
                }
                // Pantry-seeded MealDB: pull recipes built around what the user actually has,
                // so the "cook from what I have" surfaces and Discover stay full even for
                // users with narrow cuisine prefs. Bounded to the top few pantry ingredients.
                for ingredient in pantrySeeds {
                    group.addTask { await RecipeSourcesPlus.mealDBByIngredient(ingredient, limit: 5) }
                }
                // Spoonacular: use the BULK random call (one request returns ~20 full recipes
                // with steps), plus a cuisine-seeded bulk call — far more variety per quota
                // point than the old detail-per-recipe path.
                if SpoonacularClient.shared.isConfigured {
                    group.addTask { await SpoonacularClient.shared.discoverRecipesBulk(number: 20) }
                    if let firstTerm = seedTerms.first {
                        group.addTask { await SpoonacularClient.shared.discoverRecipesBulk(number: 10, tags: [firstTerm.lowercased()]) }
                    }
                }
                // Tasty (RapidAPI) — fires per seed term for broad coverage. No-ops until
                // a RAPIDAPI_KEY is added to Secrets.xcconfig; activates automatically once it is.
                if !BuildConfig.rapidAPIKey.isEmpty {
                    for term in seedTerms {
                        group.addTask { await RecipeSourcesPlus.tasty(query: term, limit: 8) }
                    }
                }
                // API Ninjas v3 recipes — general recipes by title, seeded by cuisine terms and
                // top pantry items. No-ops until APINinjasKey is set in Secrets.xcconfig.
                if !BuildConfig.apiNinjasKey.isEmpty {
                    for term in (seedTerms + pantrySeeds).prefix(4) {
                        group.addTask { await DrinkSourcesPlus.apiNinjasRecipes(title: term, limit: 8) }
                    }
                }
                // Suggestic — keyed recipe feed with vegan/vegetarian support. No-ops until
                // SuggesticAPIToken is set in Secrets.xcconfig.
                if !BuildConfig.suggesticToken.isEmpty {
                    for term in seedTerms {
                        group.addTask { await SuggesticSource.recipes(query: term, limit: 12) }
                    }
                }
                // Community recipe feed — pulled from a GitHub-hosted JSON you control, so
                // recipes can be added without shipping an app update. No-ops until
                // RemoteRecipeFeed.feedURLString is set.
                group.addTask { await RemoteRecipeFeed.fetch() }
                for await results in group { fetched += results }
            }

            // Phase 9: ten additional publisher websites. Their public search pages funnel
            // real JSON-LD recipes into Discover and then into the shared on-device database.
            // One relevance seed per refresh keeps the request volume bounded.
            let publisherSeed = pantrySeeds.first ?? seedTerms.first ?? "dinner"
            let publisherBatch = await WebRecipeFetcher.shared.fetchExpandedPublisherRecipes(
                query: publisherSeed,
                limitPerSource: 1
            )
            fetched += publisherBatch.map { Self.makeOnlineRecipe(from: $0) }

            guard !Task.isCancelled else { return }

            // #11: fuzzy de-duplicate AND merge — when the same dish appears from two
            // sources, keep the richer record (best image, longer steps, union ingredients)
            // rather than just dropping the later one.
            var merged: [OnlineRecipe] = []
            for r in fetched.shuffled() {
                // Drop empties up front.
                if r.imageURL.isEmpty && r.source != "Wikibooks Cookbook" { continue }
                if r.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
                if r.instructions == "See full recipe at source." { continue }
                // Precompute this recipe's key + name set ONCE (not per comparison) — the old
                // code re-parsed ingredient strings inside the firstIndex closure for every
                // existing item, a big contributor to the runaway-memory allocations.
                let rKey = RecipeDedup.key(r.title)
                let rNames = Set(RecipeIngredients.names(r.ingredients))
                if let idx = merged.firstIndex(where: {
                    RecipeDedup.areSameKeyed(keyA: RecipeDedup.key($0.title),
                                             namesA: Set(RecipeIngredients.names($0.ingredients)),
                                             keyB: rKey, namesB: rNames)
                }) {
                    let existing = merged[idx]
                    merged[idx] = OnlineRecipe(
                        id: existing.id,
                        title: existing.title,
                        category: existing.category.isEmpty ? r.category : existing.category,
                        area: existing.area.isEmpty ? r.area : existing.area,
                        instructions: RecipeMerge.bestSteps(
                            existing.instructions.components(separatedBy: "\n"),
                            r.instructions.components(separatedBy: "\n")).joined(separator: "\n"),
                        imageURL: RecipeMerge.best(imageA: existing.imageURL, imageB: r.imageURL),
                        ingredients: RecipeMerge.unionIngredients(existing.ingredients, r.ingredients),
                        measures: existing.measures.count >= r.measures.count ? existing.measures : r.measures,
                        source: existing.source
                    )
                } else {
                    merged.append(r)
                }
            }
            let unique = merged

            await MainActor.run { [weak self] in
                guard let self else { return }
                self.isLoading = false
                if !unique.isEmpty {
                    let existingIds = Set(self.recipes.map(\.id))
                    let newOnes = unique.filter { !existingIds.contains($0.id) }
                    withAnimation(.easeInOut(duration: 0.3)) {
                        let combined = Array((newOnes + self.recipes).prefix(400))
                        self.recipes = self.filterByProfile(combined, profile: profile)
                    }
                    self.saveCacheAsync(self.recipes)
                    // Cross-source sync: everything freshly fetched — from ANY feed — joins
                    // the on-device RecipeDatabase, the one pool behind Discover's offline
                    // seed, recipe search, the mood finder's database layer, and cook
                    // ranking. Sources stop being silos; each fetch enriches the whole app.
                    RecipeSourceHub.ingestIntoDatabase(newOnes)
                } else if self.recipes.isEmpty {
                    self.error = "Couldn't load recipes. Check your connection."
                }
            }
        }
    }

    // Fetch 2 recipes from a specific category (DB-style)
    private func fetchByCategory(_ category: String, session: URLSession) async -> [OnlineRecipe] {
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
            if var recipe = await fetchById(id, session: session) {
                recipe.source = "TheMealDB Database"
                results.append(recipe)
            }
        }
        return results
    }

    private func fetchById(_ id: String, session: URLSession) async -> OnlineRecipe? {
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/lookup.php?i=\(id)"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]],
              let meal = meals.first else { return nil }
        return parseMealPublic(meal)
    }

    private func fetchOne(session: URLSession) async -> OnlineRecipe? {
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/random.php"),
              !Task.isCancelled else { return nil }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]],
              let meal = meals.first else { return nil }
        return parseMealPublic(meal)
    }

    func parseMealPublic(_ m: [String: Any]) -> OnlineRecipe? {
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
    private func fetchByLetter(_ letter: String, session: URLSession) async -> [OnlineRecipe] {
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/search.php?f=\(letter)"),
              !Task.isCancelled else { return [] }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]] else { return [] }
        return meals.shuffled().prefix(5).compactMap { parseMealPublic($0) }
                    .map { var r = $0; r.source = "MealDB Search"; return r }
    }

    // MARK: - Source 6: Wger Nutritional Plan (free workout/nutrition API — recipe section)
    // Uses TheMealDB area filter to pull country-specific recipes (more variety)
    private func fetchByArea(_ area: String, session: URLSession) async -> [OnlineRecipe] {
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
            if var recipe = await fetchById(id, session: s) {
                recipe.source = "\(area) Kitchen"
                results.append(recipe)
            }
        }
        return results
    }

    private func loadCacheSync() -> [OnlineRecipe]? {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return nil }
        return try? JSONDecoder().decode([OnlineRecipe].self, from: data)
    }
    private func saveCacheAsync(_ recipes: [OnlineRecipe]) {
        Task(priority: .background) {
            if let data = try? JSONEncoder().encode(recipes) {
                UserDefaults.standard.set(data, forKey: self.cacheKey)
            }
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

    // Live TheMealDB search
    @State private var isSearching  = false
    @State private var liveResults: [OnlineRecipe] = []
    @State private var searchTask:  Task<Void, Never>? = nil

    let cols = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    // Grid shows live results while searching, otherwise loader.recipes filtered locally
    private var displayRecipes: [OnlineRecipe] {
        // Apply cuisine filter (#20)
        func cuisineFiltered(_ list: [OnlineRecipe]) -> [OnlineRecipe] {
            guard let cuisine = selectedCuisine else { return list }
            let q = cuisine.lowercased()
            return list.filter { $0.area.lowercased().contains(q) || $0.category.lowercased().contains(q) }
        }
        // #251 — optional allergen hide: drop recipes that hit the user's allergens.
        func allergenFiltered(_ list: [OnlineRecipe]) -> [OnlineRecipe] {
            guard hideAllergens else { return list }
            let allergens = session.guestStore.cookingProfile.allergens
            guard !allergens.isEmpty else { return list }
            return list.filter { OnlineRecipeFacts.allergenHits($0, allergens: allergens).isEmpty }
        }
        let base: [OnlineRecipe]
        if !liveResults.isEmpty { base = cuisineFiltered(liveResults) }
        else if searchText.isEmpty { base = cuisineFiltered(loader.recipes) }
        else {
            let q  = searchText.lowercased()
            let pq = NLQueryParser.parse(searchText)
            base = loader.recipes.filter { r in
                let basic = r.title.lowercased().contains(q) ||
                            r.area.lowercased().contains(q) ||
                            r.category.lowercased().contains(q) ||
                            r.ingredients.contains { $0.lowercased().contains(q) }
                if !pq.hasStructure { return basic }
                let allText = ([r.title, r.area, r.category] + r.ingredients).joined(separator: " ").lowercased()
                for excl in pq.exclude { if allText.contains(excl) { return false } }
                if let cuisine = pq.cuisine { if !allText.contains(cuisine) { return false } }
                if let meal = pq.mealType { if !allText.contains(meal) { return false } }
                return basic
            }
        }
        // Final guard: never display a recipe without real step-by-step instructions,
        // regardless of which source it came from (live search, cache, corpus).
        // #261 — diet chip: keep recipes whose inferred labels include the selected diet.
        var out = allergenFiltered(base).filter { OnlineRecipeFacts.hasRealInstructions($0.instructions) }
        if let diet = selectedDiet {
            out = out.filter { r in
                let f = DietaryClassifier.flags(for: r.ingredients, title: r.title)
                switch diet {
                case "Vegan":       return f.vegan
                case "Vegetarian":  return f.vegetarian || f.vegan
                case "Gluten-Free": return f.glutenFree
                default:            return true
                }
            }
        }
        return out
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
                            .padding(.horizontal, 10).padding(.bottom, 8)
                        }
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .padding(.horizontal, 24).padding(.bottom, 12)
            .animation(.easeInOut(duration: 0.15), value: dbSuggestions.map(\.id))

            // ── Cuisine browsing grid (#20) ─────────────────────────────
            let cuisines = ["🇮🇹 Italian","🇲🇽 Mexican","🇨🇳 Chinese","🇯🇵 Japanese",
                            "🇮🇳 Indian","🇹🇭 Thai","🇬🇷 Greek","🇫🇷 French",
                            "🇰🇷 Korean","🇻🇳 Vietnamese","🇺🇸 American","🇲🇦 Moroccan"]
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
                        let name = String(cuisine.dropFirst(3)) // strip emoji flag
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
                }.padding(.horizontal, 24).padding(.bottom, 10)
            }

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
        .onChange(of: loader.recipes.count) { _, _ in
            let urls = displayRecipes.prefix(40).map { $0.imageURL }
            ImageCache.shared.prefetch(urls: Array(urls))
        }
        .sheet(item: $selected) { recipe in
            OnlineRecipeDetailView(recipe: recipe).environment(session)
        }
    }

    // MARK: - Predictive helpers
    private func updateSuggestions(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else { dbSuggestions = []; return }
        dbSuggestions = RecipeDatabaseManager.shared.suggestions(for: q, in: dbSnapshot, limit: 6)
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
        let coverage = RecipeCoverageBuilder.make(for: recipe, store: session.guestStore)
        switch OnlineRecipeMatch.status(recipe, inStock: session.guestStore.inStockNameSet) {
        case .ready:       badge(text: "Ready", system: "checkmark.circle.fill", bg: Color.stockedGreen)
        case .missing(let n):
            // Ring makes coverage scannable at a glance; keep the text badge for the exact count.
            HStack(spacing: 5) {
                MatchRing(coverage: coverage, size: 26)
                badge(text: n == 1 ? "1 missing" : "\(n) missing", system: nil, bg: Color.stockedError.opacity(0.92))
            }
        case .unknown:     EmptyView()
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
    @State private var savedRecipeID: UUID? = nil   // set when saved to My Collection (heart)
    // #9 live cooking — per-recipe step timers (notification + Live Activity backed).
    @State private var timerEngine = StepTimerEngine()

    // #9 — instructions blob split into numbered steps for the timer rows.
    private var instructionSteps: [String] { RecipeStepSplitter.split(recipe.instructions) }

    // #251 — live "can I make this?" badge for the detail header.
    @ViewBuilder private var detailStockBadge: some View {
        let coverage = RecipeCoverageBuilder.make(for: recipe, store: session.guestStore)
        HStack(spacing: 10) {
            if coverage.total > 0 {
                MatchRing(coverage: coverage, size: 44)
            }
            VStack(alignment: .leading, spacing: 3) {
                switch OnlineRecipeMatch.status(recipe, inStock: session.guestStore.inStockNameSet) {
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
                            let diet = DietaryClassifier.flags(for: recipe.ingredients, title: recipe.title)
                            if !diet.labels.isEmpty {
                                HStack(spacing: 6) {
                                    ForEach(diet.labels, id: \.self) { label in
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
                            let allergenHits = OnlineRecipeFacts.allergenHits(recipe, allergens: session.guestStore.cookingProfile.allergens)
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

                            Button { saveToCalendar() } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: addedToCalendar ? "checkmark.circle.fill" : "calendar.badge.plus")
                                    Text(addedToCalendar ? "Added to meal planner!" : "Add to Cook Later Calendar")
                                        .font(.system(size: 14, weight: .semibold))
                                }
                                .foregroundStyle(addedToCalendar ? Color.stockedGold : Color.stockedCharcoal)
                                .frame(maxWidth: .infinity).padding(.vertical, 14)
                                .background(Color.stockedGold.opacity(addedToCalendar ? 0.18 : 0.10))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                                .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL).stroke(Color.stockedGold.opacity(0.4), lineWidth: 1))
                            }.disabled(addedToCalendar)
                        }.padding(.horizontal, 24)

                        VStack(alignment: .leading, spacing: 10) {
                            Text("Ingredients")
                                .font(.system(size: 16, weight: .bold, design: .serif)).foregroundStyle(session.themeTextColor)
                            ForEach(recipe.ingredientLines, id: \.ingredient) { pair in
                                HStack(spacing: 10) {
                                    Circle().fill(Color.stockedGold).frame(width: 6, height: 6)
                                    Text("\(pair.measure) \(pair.ingredient)")
                                        .font(.system(size: RecipeTextPrefs.shared.scaled(14))).foregroundStyle(session.themeTextColor)
                                }
                            }
                        }
                        .padding(16).background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.15)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .padding(.horizontal, 24)

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Instructions")
                                .font(.system(size: 16, weight: .bold, design: .serif)).foregroundStyle(session.themeTextColor)
                            if OnlineRecipeFacts.hasRealInstructions(recipe.instructions) {
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
        }
    }

    private func saveToCalendar() {
        StockedKnowledgeBase.shared.learnFromOnlineRecipe(recipe)
        let ings = recipe.ingredientLines.map { "\($0.measure) \($0.ingredient)".trimmingCharacters(in: .whitespaces) }
        let meal = PlannedMeal(dayIndex: 1, title: recipe.title, servings: 2, ingredients: ings, mealType: "Dinner")
        _ = meal
        session.guestStore.pastMeals.append(LocalPastMeal(title: "Planned: \(recipe.title)", date: "Pending"))
        withAnimation(.spring(response: 0.3)) { addedToCalendar = true }
    }

    // Heart toggle — save this online recipe to My Collection, or remove it if already saved.
    private func toggleSaveToCollection() {
        HapticManager.select()
        if let id = savedRecipeID {
            session.guestStore.deleteUserRecipe(id: id)
            withAnimation(.spring(response: 0.3)) { savedRecipeID = nil }
            return
        }
        // #251 — import with structured ParsedQuantity fields so scaling + grocery
        // consolidation work on this imported recipe like a hand-entered one.
        let id = session.guestStore.importOnlineRecipe(recipe)
        UsageMetrics.shared.record(.recipeImportedOnline)
        withAnimation(.spring(response: 0.3)) { savedRecipeID = id }
    }

    private func autoFillIngredients() {
        StockedKnowledgeBase.shared.learnFromOnlineRecipe(recipe)
        let stockedLower = Set(session.guestStore.inventoryItems.map { $0.name.lowercased() })
        for pair in recipe.ingredientLines {
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
