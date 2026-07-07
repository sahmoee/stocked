// DrinkSourcesPlus.swift — three additional drink recipe sources for the Drinks section.
//
//   #1 IBA Official (github: teijo/iba-cocktails) — the International Bartenders
//      Association's 77 standard cocktails as one static, immutable JSON file. Fetched
//      once and cached; zero rate limits, works forever.
//   #2 Open Drinks (github: alfg/opendrinks) — a community, open-source drink database of
//      individual JSON recipes (alcoholic and non-alcoholic). Listed via the GitHub
//      contents API (60 unauthenticated requests/hour — we make 1 listing call, cache the
//      index for a day, then fetch a small random batch of raw files per refresh).
//   #3 API Ninjas Cocktail API — keyed source (free tier, 10k requests/month). Reads
//      APINinjasKey from Info.plist / Secrets.xcconfig, exactly like the Edamam pattern;
//      absent key → the source simply no-ops.
//
// All three map into OnlineRecipe, so they flow through the same pipeline as every other
// source: the Drinks section, the Sources browser, and — via RecipeSourceHub ingestion —
// the shared on-device database behind search, the mood finder, and Discover.
import Foundation
import os

enum DrinkSourcesPlus {

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 18
        return cfg.copyWithUA()
    }()

    // MARK: - #1 IBA Official (static JSON, cached)

    private static let ibaURL = "https://raw.githubusercontent.com/teijo/iba-cocktails/master/recipes.json"
    private static let ibaCacheKey = "drinkSources_ibaCache_v1"

    /// The IBA's official cocktail list. Fetched at most once per install (the list is
    /// effectively immutable); afterwards served from the cache.
    static func ibaCocktails(limit: Int = 12) async -> [OnlineRecipe] {
        // Cache hit → serve a random slice without any network.
        if let data = UserDefaults.standard.data(forKey: ibaCacheKey),
           let cached = try? JSONDecoder().decode([CachedDrink].self, from: data), !cached.isEmpty {
            return cached.shuffled().prefix(limit).map { $0.asOnlineRecipe() }
        }
        guard let url = URL(string: ibaURL),
              let (data, http) = await NetworkRetry.data(from: url, session: session),
              (200..<300).contains(http.statusCode),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        var drinks: [CachedDrink] = []
        for r in raw {
            guard let name = r["name"] as? String,
                  let prep = r["preparation"] as? String else { continue }
            var ings: [String] = []
            for i in (r["ingredients"] as? [[String: Any]]) ?? [] {
                if let ing = i["ingredient"] as? String {
                    let amount = i["amount"].map { "\($0)" } ?? ""
                    let unit   = i["unit"] as? String ?? ""
                    let lead   = [amount, unit].filter { !$0.isEmpty }.joined(separator: " ")
                    ings.append(lead.isEmpty ? ing : "\(lead) \(ing)")
                } else if let special = i["special"] as? String {
                    ings.append(special)
                }
            }
            var steps = prep.components(separatedBy: ". ")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let garnish = r["garnish"] as? String, !garnish.isEmpty {
                steps.append("Garnish with \(garnish.lowercased()).")
            }
            drinks.append(CachedDrink(
                name: name,
                category: (r["category"] as? String) ?? "Cocktail",
                ingredients: ings,
                steps: steps,
                imageURL: "",
                source: "IBA Official"
            ))
        }
        guard !drinks.isEmpty else { return [] }
        if let data = try? JSONEncoder().encode(drinks) {
            UserDefaults.standard.set(data, forKey: ibaCacheKey)
        }
        Log.net.notice("IBA Official: cached \(drinks.count, privacy: .public) cocktails")
        return drinks.shuffled().prefix(limit).map { $0.asOnlineRecipe() }
    }

    // MARK: - #2 Open Drinks (GitHub community database)

    private static let openDrinksIndexURL = "https://api.github.com/repos/alfg/opendrinks/contents/src/recipes"
    private static let openDrinksIndexCacheKey = "drinkSources_openDrinksIndex_v1"
    private static let openDrinksIndexDateKey  = "drinkSources_openDrinksIndexDate_v1"

    /// A random batch from the Open Drinks community database. The file index is cached for
    /// a day so the rate-limited GitHub listing call happens at most once per day.
    static func openDrinks(limit: Int = 8) async -> [OnlineRecipe] {
        let names = await openDrinksIndex()
        guard !names.isEmpty else { return [] }
        var out: [OnlineRecipe] = []
        await withTaskGroup(of: OnlineRecipe?.self) { group in
            for file in names.shuffled().prefix(limit) {
                group.addTask { await fetchOpenDrink(file: file) }
            }
            for await r in group { if let r { out.append(r) } }
        }
        return out
    }

    private static func openDrinksIndex() async -> [String] {
        let ud = UserDefaults.standard
        // Fresh-enough cached index?
        if let last = ud.object(forKey: openDrinksIndexDateKey) as? Date,
           Date().timeIntervalSince(last) < 86_400,
           let cached = ud.stringArray(forKey: openDrinksIndexCacheKey), !cached.isEmpty {
            return cached
        }
        guard let url = URL(string: openDrinksIndexURL + "?per_page=100"),
              let (data, http) = await NetworkRetry.data(from: url, session: session),
              (200..<300).contains(http.statusCode),
              let listing = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // Rate-limited or offline: fall back to any stale cache.
            return ud.stringArray(forKey: openDrinksIndexCacheKey) ?? []
        }
        let names = listing.compactMap { $0["name"] as? String }.filter { $0.hasSuffix(".json") }
        guard !names.isEmpty else { return ud.stringArray(forKey: openDrinksIndexCacheKey) ?? [] }
        ud.set(names, forKey: openDrinksIndexCacheKey)
        ud.set(Date(), forKey: openDrinksIndexDateKey)
        return names
    }

    private static func fetchOpenDrink(file: String) async -> OnlineRecipe? {
        guard let url = URL(string: "https://raw.githubusercontent.com/alfg/opendrinks/master/src/recipes/\(file)"),
              let (data, http) = await NetworkRetry.data(from: url, session: session),
              (200..<300).contains(http.statusCode),
              let r = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = r["name"] as? String,
              let directions = r["directions"] as? [String], !directions.isEmpty else { return nil }
        var ings: [String] = []
        for i in (r["ingredients"] as? [[String: Any]]) ?? [] {
            guard let ing = i["ingredient"] as? String else { continue }
            let qty  = (i["quantity"] as? String) ?? ""
            let unit = (i["measure"] as? String) ?? ""
            let lead = [qty, unit].filter { !$0.isEmpty }.joined(separator: " ")
            ings.append(lead.isEmpty ? ing : "\(lead) \(ing)")
        }
        // Images live in the repo under src/assets/recipes/<image>.
        let imageURL: String = {
            guard let img = r["image"] as? String, !img.isEmpty else { return "" }
            return "https://raw.githubusercontent.com/alfg/opendrinks/master/src/assets/recipes/\(img)"
        }()
        let keywords = (r["keywords"] as? [String]) ?? []
        let category = keywords.contains(where: { $0.lowercased() == "shot" }) ? "Shot"
                     : keywords.contains(where: { $0.lowercased().contains("non-alcoholic") || $0.lowercased() == "mocktail" }) ? "Mocktail"
                     : "Cocktail"
        return OnlineRecipe(
            id: "opendrinks-\(file)",
            title: name,
            category: category,
            area: "",
            instructions: directions.joined(separator: "\n"),
            imageURL: imageURL,
            ingredients: ings,
            measures: Array(repeating: "", count: ings.count),
            source: "Open Drinks"
        )
    }

    // MARK: - #3 API Ninjas (keyed; no-ops without APINinjasKey)

    /// Cocktails by name fragment from API Ninjas. Requires APINinjasKey in Info.plist
    /// (via Secrets.xcconfig); absent → returns nothing, exactly like the Edamam pattern.
    static func apiNinjasCocktails(query: String, limit: Int = 6) async -> [OnlineRecipe] {
        let key = BuildConfig.apiNinjasKey
        guard !key.isEmpty,
              let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.api-ninjas.com/v1/cocktail?name=\(q)") else { return [] }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "X-Api-Key")
        guard let (data, resp) = try? await session.data(for: request),
              let http = resp as? HTTPURLResponse else { return [] }
        if http.statusCode == 401 || http.statusCode == 403 {
            Log.net.notice("API Ninjas auth failed — check APINinjasKey")
            return []
        }
        guard (200..<300).contains(http.statusCode),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return raw.prefix(limit).compactMap { r -> OnlineRecipe? in
            guard let name = r["name"] as? String,
                  let instructions = r["instructions"] as? String, !instructions.isEmpty else { return nil }
            let ings = (r["ingredients"] as? [String]) ?? []
            return OnlineRecipe(
                id: "apininjas-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                title: name.capitalized,
                category: "Cocktail",
                area: "",
                instructions: instructions,
                imageURL: "",
                ingredients: ings,
                measures: Array(repeating: "", count: ings.count),
                source: "API Ninjas"
            )
        }
    }

    // MARK: - Combined drinks pull (used by the Drinks section)

    /// One call that fans out to every drink source in parallel — TheCocktailDB, IBA
    /// Official, Open Drinks, and API Ninjas (if keyed) — and returns the merged batch.
    static func fetchAllDrinks() async -> [OnlineRecipe] {
        var out: [OnlineRecipe] = []
        await withTaskGroup(of: [OnlineRecipe].self) { group in
            group.addTask { await CocktailDBClient.shared.discoverRecipes(limit: 10) }
            group.addTask { await ibaCocktails(limit: 10) }
            group.addTask { await openDrinks(limit: 8) }
            group.addTask { await apiNinjasCocktails(query: "a", limit: 6) }
            for await batch in group { out += batch }
        }
        return out
    }

    // MARK: - Cache model

    private struct CachedDrink: Codable {
        let name: String
        let category: String
        let ingredients: [String]
        let steps: [String]
        let imageURL: String
        let source: String

        func asOnlineRecipe() -> OnlineRecipe {
            OnlineRecipe(
                id: "\(source.lowercased().replacingOccurrences(of: " ", with: ""))-\(name.lowercased().replacingOccurrences(of: " ", with: "-"))",
                title: name,
                category: category,
                area: "",
                instructions: steps.joined(separator: "\n"),
                imageURL: imageURL,
                ingredients: ingredients,
                measures: Array(repeating: "", count: ingredients.count),
                source: source
            )
        }
    }
}
