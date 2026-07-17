// RecipeSourcesPlus.swift
// Additional free recipe sources that produce OnlineRecipe values, plus untapped
// TheMealDB endpoints. All free; Edamam needs free credentials (no card) added to
// Info.plist as EdamamAppID / EdamamAppKey — if absent, that source simply no-ops.
//
//   #1 Edamam Recipe Search (free tier)              — large aggregator
//   #2 TheMealDB ingredient / category / area lists  — endpoints we weren't using
//   #3 Wikibooks Cookbook (CC-licensed via MediaWiki) — properly reusable recipes

import Foundation
import os

nonisolated enum RecipeSourcesPlus {

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 12
        cfg.timeoutIntervalForResource = 18
        return cfg.copyWithUA()
    }()

    // MARK: - #2 TheMealDB: filter by ingredient (free "what can I make" booster)
    // https://www.themealdb.com/api/json/v1/1/filter.php?i=<ingredient>
    static func mealDBByIngredient(_ ingredient: String, limit: Int = 6) async -> [OnlineRecipe] {
        let enc = ingredient.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ingredient
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/filter.php?i=\(enc)") else { return [] }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]] else { return [] }
        // filter.php returns only id/title/thumb — hydrate a bounded sample via lookup.
        var out: [OnlineRecipe] = []
        for m in meals.shuffled().prefix(limit) {
            guard let id = m["idMeal"] as? String else { continue }
            if let full = await mealDBLookup(id) { out.append(full) }
        }
        return out
    }

    // All categories / areas / ingredients TheMealDB knows (for dynamic filter menus).
    static func mealDBCategories() async -> [String] {
        await mealDBList(query: "c=list", key: "strCategory")
    }
    static func mealDBAreas() async -> [String] {
        await mealDBList(query: "a=list", key: "strArea")
    }
    static func mealDBIngredients() async -> [String] {
        await mealDBList(query: "i=list", key: "strIngredient")
    }

    /// All recipes for a given cuisine/area, with full step-by-step instructions.
    /// Used by the "Browse by Cuisine" screen. filter.php?a= returns the area's full
    /// meal list (id/title/thumb); we look up details (steps) for up to `limit` of
    /// them so the results pass the no-steps filter and open as complete recipes.
    static func mealDBByArea(_ area: String, limit: Int = 20) async -> [OnlineRecipe] {
        let enc = area.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? area
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/filter.php?a=\(enc)"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]] else { return [] }

        let ids = meals.compactMap { $0["idMeal"] as? String }.prefix(limit)
        var out: [OnlineRecipe] = []
        await withTaskGroup(of: OnlineRecipe?.self) { group in
            for id in ids {
                group.addTask { await mealDBLookup(id) }
            }
            for await r in group {
                if var r { r.source = "\(area) Kitchen"; out.append(r) }
            }
        }
        return out
    }

    private static func mealDBList(query: String, key: String) async -> [String] {
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/list.php?\(query)"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]] else { return [] }
        return meals.compactMap { $0[key] as? String }.filter { !$0.isEmpty }
    }

    private static func mealDBLookup(_ id: String) async -> OnlineRecipe? {
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/lookup.php?i=\(id)"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]],
              let m = meals.first else { return nil }
        return parseMeal(m)
    }

    private static func parseMeal(_ m: [String: Any]) -> OnlineRecipe? {
        guard let id = m["idMeal"] as? String, let title = m["strMeal"] as? String else { return nil }
        var ingredients: [String] = []; var measures: [String] = []
        for i in 1...20 {
            let ing  = (m["strIngredient\(i)"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let meas = (m["strMeasure\(i)"]    as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !ing.isEmpty { ingredients.append(ing); measures.append(meas) }
        }
        return OnlineRecipe(
            id: id, title: title,
            category: m["strCategory"] as? String ?? "",
            area: m["strArea"] as? String ?? "",
            instructions: m["strInstructions"] as? String ?? "",
            imageURL: m["strMealThumb"] as? String ?? "",
            ingredients: ingredients, measures: measures,
            source: "TheMealDB"
        )
    }

    // MARK: - #1 Edamam Recipe Search (free tier; needs free app id/key)
    static func edamam(query: String, limit: Int = 10) async -> [OnlineRecipe] {
        let appID  = BuildConfig.edamamAppID
        let appKey = BuildConfig.edamamAppKey
        guard !appID.isEmpty, !appKey.isEmpty,
              let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.edamam.com/api/recipes/v2?type=public&q=\(q)&app_id=\(appID)&app_key=\(appKey)")
        else { return [] }
        guard let (data, http) = await NetworkRetry.data(from: url, session: session) else { return [] }
        if http.statusCode == 401 || http.statusCode == 403 {
            Log.net.notice("Edamam auth failed — check EdamamAppID/EdamamAppKey")
            return []
        }
        guard (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hits = json["hits"] as? [[String: Any]] else { return [] }
        return hits.prefix(limit).compactMap { hit -> OnlineRecipe? in
            guard let r = hit["recipe"] as? [String: Any],
                  let label = r["label"] as? String else { return nil }
            let img  = r["image"] as? String ?? ""
            let url  = r["url"] as? String ?? ""
            let ings = (r["ingredientLines"] as? [String]) ?? []
            let cuisines = (r["cuisineType"] as? [String]) ?? []
            let dishes   = (r["dishType"] as? [String]) ?? []
            return OnlineRecipe(
                id: "edamam-\(abs(url.hashValue))",
                title: label,
                category: dishes.first?.capitalized ?? "",
                area: cuisines.first?.capitalized ?? "",
                // Edamam doesn't return cooking steps (licensing) — leave
                // instructions empty rather than stuffing the source URL here. The
                // detail view shows an honest "no steps from this source" message and
                // the source link is preserved via the source name + View source link.
                instructions: "",
                imageURL: img,
                ingredients: ings,
                measures: Array(repeating: "", count: ings.count),
                source: "Edamam"
            )
        }
    }

    // MARK: - #3 Wikibooks Cookbook (CC-licensed recipes via MediaWiki API)
    // Search the Cookbook namespace, then pull plain-text extracts. Attribution: the
    // page is CC BY-SA; we keep the source name + link so attribution is preserved.
    static func wikibooksCookbook(query: String, limit: Int = 6) async -> [OnlineRecipe] {
        guard let q = "Cookbook:\(query)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let searchURL = URL(string: "https://en.wikibooks.org/w/api.php?action=query&list=search&srsearch=\(q)&srnamespace=0&format=json&srlimit=\(limit)")
        else { return [] }
        guard let (data, _) = try? await session.data(from: searchURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let results = query["search"] as? [[String: Any]] else { return [] }

        var out: [OnlineRecipe] = []
        for r in results.prefix(limit) {
            guard let title = r["title"] as? String, title.hasPrefix("Cookbook:") else { continue }
            if let recipe = await wikibooksExtract(title: title) { out.append(recipe) }
        }
        return out
    }

    private static func wikibooksExtract(title: String) async -> OnlineRecipe? {
        guard let t = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://en.wikibooks.org/w/api.php?action=query&prop=extracts&explaintext=1&titles=\(t)&format=json")
        else { return nil }
        guard let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let query = json["query"] as? [String: Any],
              let pages = query["pages"] as? [String: Any],
              let page = pages.values.first as? [String: Any],
              let extract = page["extract"] as? String, !extract.isEmpty else { return nil }

        let display = title.replacingOccurrences(of: "Cookbook:", with: "")
        // Pull an Ingredients section if present; else leave empty and keep the prose.
        var ingredients: [String] = []
        if let range = extract.range(of: "Ingredients", options: .caseInsensitive) {
            let after = extract[range.upperBound...]
            let lines = after.split(separator: "\n").prefix(40)
            for line in lines {
                let s = line.trimmingCharacters(in: .whitespaces)
                if s.isEmpty { continue }
                if s.count < 3 { continue }
                // Stop at the next section heading.
                if s.lowercased().contains("procedure") || s.lowercased().contains("method")
                    || s.lowercased().contains("directions") { break }
                ingredients.append(s)
                if ingredients.count >= 25 { break }
            }
        }
        let link = "https://en.wikibooks.org/wiki/\(title.replacingOccurrences(of: " ", with: "_"))"
        return OnlineRecipe(
            id: "wikibooks-\(abs(title.hashValue))",
            title: display,
            category: "", area: "",
            instructions: extract.count > 4000 ? String(extract.prefix(4000)) + "…\n\nFull recipe: \(link)" : extract,
            imageURL: "",
            ingredients: ingredients,
            measures: Array(repeating: "", count: ingredients.count),
            source: "Wikibooks Cookbook"
        )
    }

    // MARK: - Spoonacular (metered: 150 points/day — call sparingly)
    // Adapter so Spoonacular's findByIngredients contributes to the recipe browse aggregation
    // like the other sources. Self-gates: returns [] when no key is configured, so it's a safe
    // no-op without a key and never throws. Keep `number` small — each call costs ~1 point.
    static func spoonacularByIngredient(_ ingredient: String, limit: Int = 4) async -> [OnlineRecipe] {
        guard SpoonacularClient.shared.isConfigured else { return [] }
        let hits = await SpoonacularClient.shared.findByIngredients([ingredient], number: limit)
        return hits.map { h in
            OnlineRecipe(
                id: "spoon-\(h.id)",
                title: h.title,
                category: "",
                area: "",
                instructions: "See full recipe at source.",
                imageURL: h.image,
                ingredients: [],
                measures: [],
                source: "Spoonacular"
            )
        }
    }

    // MARK: - Tasty (BuzzFeed) via RapidAPI (free tier; needs RAPIDAPI_KEY)
    /// Fetch Tasty recipes for a query. Returns real step-by-step instructions, so
    /// results pass the no-steps filter. No-ops automatically if no RapidAPI key is
    /// configured. Free tier is rate-limited, so callers should fire sparingly.
    static func tasty(query: String, limit: Int = 6) async -> [OnlineRecipe] {
        let key = BuildConfig.rapidAPIKey
        guard !key.isEmpty, !key.hasPrefix("YOUR_") else { return [] }
        let enc = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        guard let url = URL(string: "https://tasty.p.rapidapi.com/recipes/list?from=0&size=\(limit)&q=\(enc)") else { return [] }

        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "x-rapidapi-key")
        req.setValue("tasty.p.rapidapi.com", forHTTPHeaderField: "x-rapidapi-host")

        guard let (data, http) = try? await URLSession.shared.data(for: req),
              (http as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return [] }

        return results.compactMap { parseTasty($0) }
    }

    private static func parseTasty(_ r: [String: Any]) -> OnlineRecipe? {
        guard let name = r["name"] as? String, !name.isEmpty else { return nil }

        // Steps: instructions[].display_text
        let steps = (r["instructions"] as? [[String: Any]] ?? [])
            .compactMap { ($0["display_text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !steps.isEmpty else { return nil }   // no steps → skip (would be filtered anyway)

        // Ingredients: sections[].components[].raw_text
        var ingredients: [String] = []
        for section in (r["sections"] as? [[String: Any]] ?? []) {
            for comp in (section["components"] as? [[String: Any]] ?? []) {
                if let raw = (comp["raw_text"] as? String)?.trimmingCharacters(in: .whitespaces), !raw.isEmpty {
                    ingredients.append(raw)
                }
            }
        }

        let image = (r["thumbnail_url"] as? String) ?? ""
        let cuisine = ((r["cuisine"] as? [String: Any])?["name"] as? String) ?? ""
        let idNum = (r["id"] as? Int).map(String.init) ?? UUID().uuidString

        return OnlineRecipe(
            id: "tasty-\(idNum)",
            title: name,
            category: "",
            area: cuisine,
            instructions: steps.joined(separator: "\n"),
            imageURL: image,
            ingredients: ingredients,
            measures: Array(repeating: "", count: ingredients.count),
            source: "Tasty"
        )
    }

    // MARK: - DummyJSON Recipes (free, no key, real step-by-step instructions)
    // https://dummyjson.com/recipes — ~50 curated recipes with full instructions,
    // ingredients, cuisine, and images. A solid free source that passes the
    // real-instructions filter.
    static func dummyJSONRecipes(limit: Int = 12) async -> [OnlineRecipe] {
        // Pull a randomized page so Discover stays fresh across refreshes.
        let skip = Int.random(in: 0...30)
        guard let url = URL(string: "https://dummyjson.com/recipes?limit=\(limit)&skip=\(skip)") else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let arr  = json?["recipes"] as? [[String: Any]] ?? []
            return arr.compactMap { parseDummyJSON($0) }
        } catch { return [] }
    }

    /// Search DummyJSON recipes by query (name/cuisine/tag).
    static func dummyJSONSearch(_ query: String, limit: Int = 8) async -> [OnlineRecipe] {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard !q.isEmpty, let url = URL(string: "https://dummyjson.com/recipes/search?q=\(q)") else { return [] }
        do {
            let (data, _) = try await session.data(from: url)
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let arr  = (json?["recipes"] as? [[String: Any]] ?? []).prefix(limit)
            return arr.compactMap { parseDummyJSON($0) }
        } catch { return [] }
    }

    private static func parseDummyJSON(_ r: [String: Any]) -> OnlineRecipe? {
        guard let name = r["name"] as? String, !name.isEmpty else { return nil }
        let steps = (r["instructions"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .enumerated().map { "\($0.offset + 1). \($0.element)" }
        guard !steps.isEmpty else { return nil }
        let ingredients = (r["ingredients"] as? [String] ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let idNum = (r["id"] as? Int).map(String.init) ?? UUID().uuidString
        let cuisine = (r["cuisine"] as? String) ?? ""
        let meal = (r["mealType"] as? [String])?.first ?? ""
        return OnlineRecipe(
            id: "dummyjson-\(idNum)",
            title: name,
            category: meal,
            area: cuisine,
            instructions: steps.joined(separator: "\n"),
            imageURL: (r["image"] as? String) ?? "",
            ingredients: ingredients,
            measures: Array(repeating: "", count: ingredients.count),
            source: "DummyJSON"
        )
    }
}

// Shared: a browser-like User-Agent so community APIs don't reject the request.
nonisolated private extension URLSessionConfiguration {
    func copyWithUA() -> URLSession {
        httpAdditionalHeaders = [
            "User-Agent": "Stocked/1.0 (iOS; recipe app) URLSession",
            "Accept": "application/json"
        ]
        return URLSession(configuration: self)
    }
}
