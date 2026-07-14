// SuggesticSource.swift — Suggestic recipes as a first-class recipe source.
//
// Mirrors the DrinkSourcesPlus / RecipeSourcesPlus pattern: a keyed feed that returns
// [OnlineRecipe], so it flows through the same pipeline as every other source — the
// Sources browser, and (via RecipeSourceHub ingestion) the shared on-device database
// behind search, the mood finder, and Discover.
//
// Keyed: reads BuildConfig.suggesticToken (SuggesticAPIToken in Info.plist / Secrets.xcconfig).
// Absent key -> the source simply no-ops, exactly like Edamam / Tasty / API Ninjas.
//
// Cached: every query is cached via APIResponseCache for a day, so repeat refreshes and
// re-seeds don't re-hit the GraphQL endpoint.
import Foundation
import os

nonisolated enum SuggesticSource {

    /// Diet filter passed through to Suggestic.
    nonisolated enum Diet: String, Sendable {
        case any, vegan, vegetarian
    }

    private static let endpoint = URL(string: "https://production.suggestic.com/graphql")!
    private static let cacheTTL: TimeInterval = 60 * 60 * 24   // 1 day

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = BuildConfig.networkTimeout
        c.httpAdditionalHeaders = [
            "User-Agent": "Stocked/1.0 (iOS; recipe-source)",
            "Accept": "application/json"
        ]
        return URLSession(configuration: c)
    }()

    /// Fetches recipes for a search term, optionally constrained to a diet. Cached.
    static func recipes(query: String, diet: Diet = .any, limit: Int = 12) async -> [OnlineRecipe] {
        let token = BuildConfig.suggesticToken
        guard !token.isEmpty else { return [] }

        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }

        let cacheKey = "suggestic.\(diet.rawValue).\(limit).\(term.lowercased())"
        if let cached = await APIResponseCache.shared.value(for: cacheKey, as: [OnlineRecipe].self) {
            return cached
        }

        let dietFilter = diet == .any ? "" : ", diet: \(diet.rawValue.uppercased())"
        let gql = """
        query {
          searchRecipes(search: \"\(escape(term))\", first: \(limit)\(dietFilter)) {
            edges { node { id name mainImage sourceUrl ingredientLines } }
          }
        }
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["query": gql])

        guard let (data, resp) = try? await session.data(for: request),
              let http = resp as? HTTPURLResponse else { return [] }
        if http.statusCode == 401 || http.statusCode == 403 {
            Log.net.notice("Suggestic auth failed — check SuggesticAPIToken")
            return []
        }
        guard (200..<300).contains(http.statusCode) else { return [] }

        let recipes = parse(data)
        await APIResponseCache.shared.store(recipes, for: cacheKey, ttl: cacheTTL)
        return recipes
    }

    // MARK: - Parsing

    private static func parse(_ data: Data) -> [OnlineRecipe] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let search = dataNode["searchRecipes"] as? [String: Any],
              let edges = search["edges"] as? [[String: Any]] else {
            return []
        }

        return edges.compactMap { edge -> OnlineRecipe? in
            guard let node = edge["node"] as? [String: Any],
                  let title = node["name"] as? String, !title.isEmpty else { return nil }

            let ingredients = (node["ingredientLines"] as? [String]) ?? []
            let image = (node["mainImage"] as? String) ?? ""
            let sourceURL = (node["sourceUrl"] as? String) ?? ""
            let instructions = sourceURL.isEmpty ? "" : "Full recipe at \(sourceURL)"

            return OnlineRecipe(
                id: "suggestic-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))",
                title: title,
                category: "",
                area: "",
                instructions: instructions,
                imageURL: image,
                ingredients: ingredients,
                measures: Array(repeating: "", count: ingredients.count),
                source: "Suggestic"
            )
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
