//
//  SuggesticClient.swift
//  Stocked
//
//  Client for the Suggestic GraphQL API (recipes and meal plans).
//  Natural home: a recipe source that ingests into RecipeDatabase like the other
//  keyed feeds. Supports vegan/vegetarian filtering. All queries are cached.
//
//  Docs: https://docs.suggestic.com/graphql
//  Endpoint: POST https://production.suggestic.com/graphql
//  Server-side auth header: Authorization: Token <API-Token>
//

import Foundation

// MARK: - Public models

struct SuggesticRecipe: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let imageURL: String?
    let sourceURL: String?
    let calories: Double?
    let servings: Int?
    let ingredients: [String]
}

// MARK: - Client

actor SuggesticClient {

    static let shared = SuggesticClient()

    private let session = NutritionAPISession.make()
    private let cache = APIResponseCache.shared
    private let ttl: TimeInterval = 60 * 60 * 24   // 1 day
    private let endpoint = URL(string: "https://production.suggestic.com/graphql")!

    /// Diet filters supported by the search helper.
    enum Diet: String {
        case any
        case vegan
        case vegetarian
    }

    /// Searches recipes, optionally constrained to a diet. Cached per (query, diet).
    func searchRecipes(_ query: String, diet: Diet = .any, first: Int = 20) async throws -> [SuggesticRecipe] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let cacheKey = "suggestic.search.\(diet.rawValue).\(first).\(trimmed.lowercased())"
        if let hit = await cache.value(for: cacheKey, as: [SuggesticRecipe].self) { return hit }

        let recipes = try await performSearch(trimmed, diet: diet, first: first)
        await cache.store(recipes, for: cacheKey, ttl: ttl)
        return recipes
    }

    // MARK: GraphQL

    private func performSearch(_ query: String, diet: Diet, first: Int) async throws -> [SuggesticRecipe] {
        guard let token = NutritionAPIConfig.suggesticToken else {
            throw NutritionAPIError.missingKey("SuggesticAPIToken")
        }

        let dietFilter = diet == .any ? "" : ", diet: \(diet.rawValue.uppercased())"
        let gql = """
        query {
          searchRecipes(search: \"\(Self.escape(query))\", first: \(first)\(dietFilter)) {
            edges {
              node {
                id
                name
                mainImage
                sourceUrl
                calories
                numberOfServings
                ingredientLines
              }
            }
          }
        }
        """

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["query": gql])

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw NutritionAPIError.decoding }
        guard (200...299).contains(http.statusCode) else {
            throw NutritionAPIError.badResponse(http.statusCode)
        }

        return Self.parse(data)
    }

    // MARK: Parsing

    private static func parse(_ data: Data) -> [SuggesticRecipe] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataNode = root["data"] as? [String: Any],
              let search = dataNode["searchRecipes"] as? [String: Any],
              let edges = search["edges"] as? [[String: Any]] else {
            return []
        }

        return edges.compactMap { edge in
            guard let node = edge["node"] as? [String: Any],
                  let id = node["id"] as? String,
                  let name = node["name"] as? String else {
                return nil
            }

            let ingredients = (node["ingredientLines"] as? [String]) ?? []

            return SuggesticRecipe(
                id: id,
                name: name,
                imageURL: node["mainImage"] as? String,
                sourceURL: node["sourceUrl"] as? String,
                calories: Self.number(node["calories"]),
                servings: node["numberOfServings"] as? Int,
                ingredients: ingredients
            )
        }
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }

    /// Escapes characters that would break a GraphQL string literal.
    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
