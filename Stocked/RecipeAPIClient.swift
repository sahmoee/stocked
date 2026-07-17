// RecipeAPIClient.swift — async/await network layer + 100-recipe offline cache
// Code Professional #1, #9  |  App Better #13
import Foundation
import os

struct MealDBResponse: Decodable { let meals: [MealDBMeal]? }
struct MealDBMeal: Decodable {
    let idMeal, strMeal, strCategory, strArea, strInstructions, strMealThumb: String?
    let strIngredient1,strIngredient2,strIngredient3,strIngredient4,strIngredient5: String?
    let strIngredient6,strIngredient7,strIngredient8,strIngredient9,strIngredient10: String?
    let strIngredient11,strIngredient12,strIngredient13,strIngredient14,strIngredient15: String?
    let strIngredient16,strIngredient17,strIngredient18,strIngredient19,strIngredient20: String?
    let strMeasure1,strMeasure2,strMeasure3,strMeasure4,strMeasure5: String?
    let strMeasure6,strMeasure7,strMeasure8,strMeasure9,strMeasure10: String?
    let strMeasure11,strMeasure12,strMeasure13,strMeasure14,strMeasure15: String?
    let strMeasure16,strMeasure17,strMeasure18,strMeasure19,strMeasure20: String?

    var parsedIngredients: [String] {
        let ing = [strIngredient1,strIngredient2,strIngredient3,strIngredient4,strIngredient5,
                   strIngredient6,strIngredient7,strIngredient8,strIngredient9,strIngredient10,
                   strIngredient11,strIngredient12,strIngredient13,strIngredient14,strIngredient15,
                   strIngredient16,strIngredient17,strIngredient18,strIngredient19,strIngredient20]
        let meas = [strMeasure1,strMeasure2,strMeasure3,strMeasure4,strMeasure5,
                    strMeasure6,strMeasure7,strMeasure8,strMeasure9,strMeasure10,
                    strMeasure11,strMeasure12,strMeasure13,strMeasure14,strMeasure15,
                    strMeasure16,strMeasure17,strMeasure18,strMeasure19,strMeasure20]
        return zip(ing, meas).compactMap { (i, m) -> String? in
            guard let name = i, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            let measure = m?.trimmingCharacters(in: .whitespaces) ?? ""
            return measure.isEmpty ? name : "\(measure) \(name)"
        }
    }
    var parsedSteps: [String] {
        (strInstructions ?? "")
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 15 }.prefix(10).map { $0 }
    }
}

struct CachedRecipe: Codable, Identifiable, Sendable {
    var id          = UUID()
    let mealID:     String
    let title:      String
    let imageURL:   String
    let category:   String
    let area:       String
    let ingredients: [String]
    let steps:      [String]
    let cachedAt:   Date
    var source:     String = "TheMealDB"

    // Rich metadata — populated from Schema.org JSON-LD on supported sites
    var prepTime:   String?    // e.g. "15 minutes"
    var cookTime:   String?    // e.g. "30 minutes"
    var totalTime:  String?    // e.g. "45 minutes"
    var servings:   String?    // e.g. "4 servings"
    var description: String?
    var cuisine:    String?
    var tags:       [String]  = []
    var sourceURL:  String?    // original URL when imported

    // Display helper
    var timeDisplay: String? {
        if let t = totalTime, !t.isEmpty { return t }
        if let c = cookTime, !c.isEmpty { return c }
        return nil
    }
}

// MARK: - Offline Cache (last 100, disk-backed, TTL refresh) (#7)
class OfflineRecipeCache {
    static let shared = OfflineRecipeCache()
    private let key   = StockedKeys.offlineRecipeCache
    private let limit = StockedUI.offlineCacheLimit
    /// Cached recipes older than this are considered stale and dropped on load,
    /// so the cache refreshes naturally instead of serving forever-old data.
    private let ttl: TimeInterval = 60 * 60 * 24 * 14   // 14 days
    private(set) var recipes: [CachedRecipe] = []
    init() { load() }

    func save(_ recipe: CachedRecipe) {
        guard !recipes.contains(where: { $0.mealID == recipe.mealID }) else { return }
        recipes.insert(recipe, at: 0)
        if recipes.count > limit { recipes = Array(recipes.prefix(limit)) }
        persist()
    }
    func clear() {
        recipes.removeAll()
        LocalDatabase.shared.delete(key: key)
        UserDefaults.standard.removeObject(forKey: key)
    }

    func search(_ q: String) -> [CachedRecipe] {
        let low = q.lowercased()
        return recipes.filter {
            $0.title.lowercased().contains(low) || $0.category.lowercased().contains(low) ||
            $0.area.lowercased().contains(low) || $0.ingredients.contains { $0.lowercased().contains(low) }
        }
    }
    private func persist() {
        // Disk-backed via LocalDatabase (avoids bloating UserDefaults); also encode once.
        if let data = try? JSONEncoder().encode(recipes) {
            LocalDatabase.shared.saveData(data, key: key)
        }
    }
    private func load() {
        // Prefer disk; fall back to any legacy UserDefaults blob from older builds.
        let decoded: [CachedRecipe]?
        if let onDisk = LocalDatabase.shared.load([CachedRecipe].self, key: key) {
            decoded = onDisk
        } else if let data = UserDefaults.standard.data(forKey: key) {
            decoded = try? JSONDecoder().decode([CachedRecipe].self, from: data)
        } else {
            decoded = nil
        }
        guard let all = decoded else { return }
        // TTL: drop stale entries on load.
        let cutoff = Date().addingTimeInterval(-ttl)
        recipes = all.filter { $0.cachedAt >= cutoff }
        if recipes.count != all.count { persist() }   // rewrite pruned set
    }
}

// MARK: - Async/await API client (Code Professional #1, #9)
@MainActor
final class RecipeAPIClient {
    static let shared = RecipeAPIClient()
    private let cache = OfflineRecipeCache.shared
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg)
    }()

    func search(_ query: String) async throws -> [CachedRecipe] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { throw StockedError.noResults(query) }
        let encoded = q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? q
        guard let url = URL(string: StockedAPI.mealSearch + encoded) else {
            throw StockedError.invalidURL(StockedAPI.mealSearch + encoded)
        }
        return try await fetchMeals(from: url, source: "TheMealDB")
    }

    func random() async throws -> CachedRecipe {
        guard let url = URL(string: StockedAPI.mealRandom) else {
            throw StockedError.invalidURL(StockedAPI.mealRandom)
        }
        let results = try await fetchMeals(from: url, source: "TheMealDB Random")
        guard let first = results.first else { throw StockedError.noResults("random") }
        return first
    }

    // App Better #2 — URL import
    func importFromURL(_ urlString: String) async throws -> CachedRecipe {
        guard let url = URL(string: urlString) else { throw StockedError.invalidURL(urlString) }
        let (data, _) = try await session.data(from: url)
        guard let html = String(data: data, encoding: .utf8) else { throw StockedError.decodingFailed("HTML") }
        if let r = parseJSONLD(html: html, sourceURL: urlString) { cache.save(r); return r }
        // Fallback: extract title from <title> tag or og:title meta
        let titlePattern = #"<title[^>]*>([^<]+)</title>"#
        let ogPattern    = #"og:title[^>]*content="([^"]+)""#
        let title: String = {
            if let r = html.range(of: titlePattern, options: .regularExpression),
               let inner = html[r].range(of: ">") {
                let raw = String(html[inner.upperBound...].prefix(100)).components(separatedBy: "<").first ?? ""
                return raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if let r = html.range(of: ogPattern, options: .regularExpression) {
                let match = String(html[r])
                if let c = match.range(of: "content=\"") {
                    return String(match[c.upperBound...].prefix(100)).components(separatedBy: "\"").first ?? "Imported Recipe"
                }
            }
            return "Imported Recipe"
        }()
        let results = try await search(title)
        guard let first = results.first else { throw StockedError.noResults(title) }
        return first
    }

    private func fetchMeals(from url: URL, source: String) async throws -> [CachedRecipe] {
        let data = try await fetchDataWithRetry(from: url)
        let decoded = try JSONDecoder().decode(MealDBResponse.self, from: data)
        return (decoded.meals ?? []).map { m in
            let r = CachedRecipe(mealID: m.idMeal ?? UUID().uuidString, title: m.strMeal ?? "Unknown",
                imageURL: m.strMealThumb ?? "", category: m.strCategory ?? "",
                area: m.strArea ?? "", ingredients: m.parsedIngredients,
                steps: m.parsedSteps, cachedAt: Date(), source: source)
            cache.save(r); return r
        }
    }

    // #6: one automatic retry with backoff; #3: surface quota/server errors clearly.
    private func fetchDataWithRetry(from url: URL, attempts: Int = 2) async throws -> Data {
        var lastError: Error = StockedError.networkUnavailable
        for attempt in 0..<attempts {
            do {
                let (data, response) = try await session.data(from: url)
                if let http = response as? HTTPURLResponse {
                    switch http.statusCode {
                    case 200..<300: return data
                    case 429:
                        Log.net.error("Recipe API rate limited (429) at \(url.host ?? "?", privacy: .public)")
                        throw StockedError.networkUnavailable
                    case 500..<600:
                        Log.net.notice("Recipe API server error \(http.statusCode, privacy: .public); retrying")
                        lastError = StockedError.networkUnavailable
                    default:
                        throw StockedError.networkUnavailable
                    }
                } else {
                    return data
                }
            } catch {
                lastError = error
                Log.net.notice("Recipe fetch attempt \(attempt + 1, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
            // backoff before retrying (0.4s, then give up)
            if attempt < attempts - 1 {
                try? await Task.sleep(nanoseconds: 400_000_000)
            }
        }
        throw lastError
    }

    // MARK: - Comprehensive JSON-LD Recipe Parser
    // Supports Schema.org Recipe markup used by all 20 catalogued sites.
    // Handles: nested @graph, multiple ld+json blocks, array/string image formats,
    // ISO 8601 durations, HowToStep/HowToSection instruction formats.
    private func parseJSONLD(html: String, sourceURL: String) -> CachedRecipe? {
        // Extract ALL <script type="application/ld+json"> blocks (some sites have multiple)
        var jsonBlocks: [[String: Any]] = []
        var searchRange = html.startIndex..<html.endIndex

        let openTag  = "<script type=\"application/ld+json\">"
        let closeTag = "</script>"

        while let openRange = html.range(of: openTag, options: .caseInsensitive, range: searchRange),
              let closeRange = html.range(of: closeTag, range: openRange.upperBound..<html.endIndex) {
            let jsonString = String(html[openRange.upperBound..<closeRange.lowerBound])
            if let data = jsonString.data(using: .utf8) {
                if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    jsonBlocks.append(dict)
                } else if let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
                    jsonBlocks.append(contentsOf: arr)
                }
            }
            searchRange = closeRange.upperBound..<html.endIndex
        }

        // Flatten @graph arrays (used by Epicurious, Bon Appétit, etc.)
        var candidates: [[String: Any]] = []
        for block in jsonBlocks {
            if let graph = block["@graph"] as? [[String: Any]] {
                candidates.append(contentsOf: graph)
            } else {
                candidates.append(block)
            }
        }

        // Find the Recipe object
        guard let recipe = candidates.first(where: {
            let type = $0["@type"]
            if let s = type as? String { return s == "Recipe" }
            if let arr = type as? [String] { return arr.contains("Recipe") }
            return false
        }) else { return nil }

        // ── Extract fields ────────────────────────────────────────────
        let name = recipe["name"] as? String ?? "Imported Recipe"

        // Image: string | [string] | ImageObject | [ImageObject]
        let imageURL: String = {
            if let s = recipe["image"] as? String { return s }
            if let arr = recipe["image"] as? [String] { return arr.first ?? "" }
            if let obj = recipe["image"] as? [String: Any] { return obj["url"] as? String ?? "" }
            if let arr = recipe["image"] as? [[String: Any]] { return arr.first?["url"] as? String ?? "" }
            return ""
        }()

        // Times: ISO 8601 PT##H##M → human string
        func parseDuration(_ key: String) -> String? {
            guard let iso = recipe[key] as? String else { return nil }
            return isoToHuman(iso)
        }

        // Ingredients
        let ingredients = recipe["recipeIngredient"] as? [String] ?? []

        // Instructions: string | [HowToStep] | [HowToSection]
        let steps: [String] = {
            if let plain = recipe["recipeInstructions"] as? String {
                return plain.components(separatedBy: "\n").filter { !$0.isEmpty }
            }
            if let arr = recipe["recipeInstructions"] as? [[String: Any]] {
                return arr.flatMap { step -> [String] in
                    if let text = step["text"] as? String { return [text] }
                    // HowToSection has itemListElement
                    if let items = step["itemListElement"] as? [[String: Any]] {
                        return items.compactMap { $0["text"] as? String }
                    }
                    return []
                }
            }
            return []
        }()

        // Servings
        let servings: String? = {
            if let s = recipe["recipeYield"] as? String { return s }
            if let a = recipe["recipeYield"] as? [String] { return a.first }
            return nil
        }()

        // Cuisine
        let cuisine: String? = {
            if let s = recipe["recipeCuisine"] as? String { return s }
            if let a = recipe["recipeCuisine"] as? [String] { return a.first }
            return nil
        }()

        // Tags / keywords
        let tags: [String] = {
            if let s = recipe["keywords"] as? String {
                return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            }
            return []
        }()

        // Source name from catalogued sites
        let sourceName: String = {
            let host = URL(string: sourceURL)?.host?.replacingOccurrences(of: "www.", with: "") ?? ""
            if let src = RecipeSourceRegistry.source(for: host) {
                return src.displayName
            }
            return host.isEmpty ? sourceURL : host
        }()

        return CachedRecipe(
            mealID:      UUID().uuidString,
            title:       name,
            imageURL:    imageURL,
            category:    recipe["recipeCategory"] as? String ?? "Imported",
            area:        cuisine ?? "",
            ingredients: ingredients,
            steps:       steps,
            cachedAt:    Date(),
            source:      sourceName,
            prepTime:    parseDuration("prepTime"),
            cookTime:    parseDuration("cookTime"),
            totalTime:   parseDuration("totalTime"),
            servings:    servings,
            description: recipe["description"] as? String,
            cuisine:     cuisine,
            tags:        tags,
            sourceURL:   sourceURL
        )
    }

    // ISO 8601 duration → "X hr Y min"
    private func isoToHuman(_ iso: String) -> String? {
        guard iso.hasPrefix("PT") || iso.hasPrefix("P") else { return nil }
        var s = iso.dropFirst(iso.hasPrefix("PT") ? 2 : 1)
        var hours = 0; var minutes = 0
        if let hRange = s.range(of: "H") {
            hours = Int(s[s.startIndex..<hRange.lowerBound]) ?? 0
            s = s[hRange.upperBound...]
        }
        if let mRange = s.range(of: "M") {
            minutes = Int(s[s.startIndex..<mRange.lowerBound]) ?? 0
        }
        if hours == 0 && minutes == 0 { return nil }
        if hours > 0 && minutes > 0 { return "\(hours) hr \(minutes) min" }
        if hours > 0 { return "\(hours) hr" }
        return "\(minutes) min"
    }
}
