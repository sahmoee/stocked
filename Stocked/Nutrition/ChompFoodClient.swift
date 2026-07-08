//
//  ChompFoodClient.swift
//  Stocked
//
//  Client for the Chomp Food Database API (branded foods, barcodes, ingredients,
//  diet labels). Natural home: barcode scanning and product nutrition lookups.
//  All responses are cached via APIResponseCache to avoid repeat network calls.
//
//  Docs: https://chompthis.com/api/
//  Endpoints use the v2 food routes with the api_key query parameter.
//  Confirm the exact route paths against your Chomp plan and adjust Route below if needed.
//

import Foundation

// MARK: - Public models

struct ChompFood: Codable, Identifiable, Hashable {
    var id: String { barcode ?? name }
    let name: String
    let barcode: String?
    let brand: String?
    let dietLabels: [String]
    let ingredients: [String]
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?

    var isVegan: Bool { dietLabels.contains { $0.lowercased().contains("vegan") } }
    var isVegetarian: Bool {
        isVegan || dietLabels.contains { $0.lowercased().contains("vegetarian") }
    }
}

// MARK: - Client

actor ChompFoodClient {

    static let shared = ChompFoodClient()

    private let session = NutritionAPISession.make()
    private let cache = APIResponseCache.shared
    private let ttl: TimeInterval = 60 * 60 * 24 * 7   // 7 days; product data is stable

    private enum Route {
        static let base = "https://chompthis.com/api/v2/food"
        static let barcode = base + "/branded/barcode.php"
        static let name = base + "/branded/name.php"
        static let ingredient = base + "/ingredient/search.php"
    }

    // MARK: Barcode lookup

    /// Looks up a single branded food by UPC/EAN barcode. Cached.
    func food(barcode: String) async throws -> ChompFood? {
        let cacheKey = "chomp.barcode.\(barcode)"
        if let hit = await cache.value(for: cacheKey, as: ChompFood?.self) { return hit }

        let items = try await request(url: Route.barcode, query: ["code": barcode])
        let result = items.first
        await cache.store(result, for: cacheKey, ttl: ttl)
        return result
    }

    // MARK: Name search

    /// Searches branded foods by name. Cached per query.
    func search(name query: String) async throws -> [ChompFood] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }

        let cacheKey = "chomp.name.\(key)"
        if let hit = await cache.value(for: cacheKey, as: [ChompFood].self) { return hit }

        let items = try await request(url: Route.name, query: ["name": query])
        await cache.store(items, for: cacheKey, ttl: ttl)
        return items
    }

    // MARK: Ingredient search

    /// Searches raw ingredients by name. Cached per query.
    func search(ingredient query: String) async throws -> [ChompFood] {
        let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [] }

        let cacheKey = "chomp.ingredient.\(key)"
        if let hit = await cache.value(for: cacheKey, as: [ChompFood].self) { return hit }

        let items = try await request(url: Route.ingredient, query: ["search": query])
        await cache.store(items, for: cacheKey, ttl: ttl)
        return items
    }

    // MARK: Networking

    private func request(url urlString: String, query: [String: String]) async throws -> [ChompFood] {
        guard let key = NutritionAPIConfig.chompAPIKey else {
            throw NutritionAPIError.missingKey("ChompAPIKey")
        }
        guard var components = URLComponents(string: urlString) else {
            throw NutritionAPIError.invalidRequest
        }

        var items = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        items.append(URLQueryItem(name: "api_key", value: key))
        components.queryItems = items

        guard let url = components.url else { throw NutritionAPIError.invalidRequest }

        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse else { throw NutritionAPIError.decoding }
        guard (200...299).contains(http.statusCode) else {
            throw NutritionAPIError.badResponse(http.statusCode)
        }

        return Self.parse(data)
    }

    // MARK: Parsing (lenient against Chomp payload variations)

    private static func parse(_ data: Data) -> [ChompFood] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // Chomp returns items under "items" (arrays) or "food" (single). Handle both.
        var rawItems: [[String: Any]] = []
        if let arr = root["items"] as? [[String: Any]] {
            rawItems = arr
        } else if let single = root["food"] as? [String: Any] {
            rawItems = [single]
        } else if let single = root["item"] as? [String: Any] {
            rawItems = [single]
        }

        return rawItems.compactMap { Self.map($0) }
    }

    private static func map(_ dict: [String: Any]) -> ChompFood? {
        let name = (dict["name"] as? String)
            ?? (dict["product_name"] as? String)
            ?? (dict["ingredient"] as? String)
        guard let name, !name.isEmpty else { return nil }

        let barcode = (dict["barcode"] as? String) ?? (dict["upc"] as? String)
        let brand = (dict["brand"] as? String) ?? (dict["manufacturer"] as? String)

        let dietLabels = (dict["diet_labels"] as? [String])
            ?? (dict["diet_flags"] as? [String])
            ?? []

        let ingredients = Self.ingredientList(from: dict)
        let nutrients = dict["nutrients"] as? [String: Any] ?? dict

        return ChompFood(
            name: name,
            barcode: barcode,
            brand: brand,
            dietLabels: dietLabels,
            ingredients: ingredients,
            calories: Self.number(nutrients["calories"] ?? nutrients["energy"]),
            protein: Self.number(nutrients["protein"] ?? nutrients["proteins"]),
            carbs: Self.number(nutrients["carbohydrate"] ?? nutrients["carbohydrates"]),
            fat: Self.number(nutrients["fat"] ?? nutrients["total_fat"])
        )
    }

    private static func ingredientList(from dict: [String: Any]) -> [String] {
        if let list = dict["ingredient_list"] as? [String] { return list }
        if let list = dict["ingredients"] as? [String] { return list }
        if let str = dict["ingredients"] as? String {
            return str.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        return []
    }

    private static func number(_ any: Any?) -> Double? {
        if let d = any as? Double { return d }
        if let i = any as? Int { return Double(i) }
        if let s = any as? String { return Double(s) }
        return nil
    }
}
