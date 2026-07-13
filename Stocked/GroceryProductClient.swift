// GroceryProductClient.swift
// Product, BRAND, and PRICE lookups from the RapidAPI "grocery-api2" endpoints
// (Amazon and Walmart grocery catalogs). Use this to enrich an item with its brand,
// a price estimate, and a product image — data MapKit and the store finder can't give.
//
// This does NOT provide in-store AISLE data (no public API exposes per-store aisle maps);
// for aisle grouping, use Stocked's existing store-section logic on the grocery list.
//
// Keyed: reads BuildConfig.rapidAPIKey (RAPIDAPI_KEY in Secrets.xcconfig). Absent -> no-ops.
// Cached: every query is cached for a day via APIResponseCache, so repeat lookups and
// re-renders never re-hit the (rate-limited) RapidAPI quota.

import Foundation
import os

nonisolated struct GroceryProduct: Codable, Identifiable, Hashable, Sendable {
    var id: String { "\(store)-\(name)-\(price ?? "")" }
    let name: String
    let brand: String?
    let price: String?        // kept as string; sources format differently ("$3.49", "3.49")
    let imageURL: String?
    let productURL: String?
    let store: String         // "Amazon" or "Walmart"
}

actor GroceryProductClient {
    static let shared = GroceryProductClient()

    private let cache = APIResponseCache.shared
    private let ttl: TimeInterval = 60 * 60 * 24   // 1 day
    private let host = "grocery-api2.p.rapidapi.com"

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        return URLSession(configuration: c)
    }()

    enum Store: String { case amazon, walmart }

    /// Search a store's grocery catalog for a query (e.g. "milk", "greek yogurt"). Cached.
    func search(_ query: String, store: Store = .walmart, page: Int = 1) async -> [GroceryProduct] {
        let key = BuildConfig.rapidAPIKey
        guard !key.isEmpty else { return [] }
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty,
              let q = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return [] }

        let cacheKey = "grocery.\(store.rawValue).\(page).\(term.lowercased())"
        if let hit = await cache.value(for: cacheKey, as: [GroceryProduct].self) { return hit }

        var urlString = "https://\(host)/\(store.rawValue)?query=\(q)&page=\(page)"
        if store == .amazon { urlString += "&country=us" }
        guard let url = URL(string: urlString) else { return [] }

        var request = URLRequest(url: url)
        request.setValue(host, forHTTPHeaderField: "x-rapidapi-host")
        request.setValue(key,  forHTTPHeaderField: "x-rapidapi-key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        guard let (data, resp) = try? await session.data(for: request),
              let http = resp as? HTTPURLResponse else { return [] }
        if http.statusCode == 401 || http.statusCode == 403 {
            Log.net.notice("Grocery API auth failed — check RAPIDAPI_KEY")
            return []
        }
        guard (200..<300).contains(http.statusCode) else { return [] }

        let products = Self.parse(data, store: store)
        await cache.store(products, for: cacheKey, ttl: ttl)
        return products
    }

    /// Best single match for an item name (first result). Handy for filling in brand/price.
    func bestMatch(for itemName: String, store: Store = .walmart) async -> GroceryProduct? {
        await search(itemName, store: store).first
    }

    // MARK: - Lenient parsing (response shape isn't documented; handle common variants)

    private static func parse(_ data: Data, store: Store) -> [GroceryProduct] {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return [] }

        // Find the product array under whatever key the endpoint used.
        var items: [[String: Any]] = []
        if let arr = root as? [[String: Any]] {
            items = arr
        } else if let obj = root as? [String: Any] {
            for k in ["results", "products", "data", "items", "grocery", "list"] {
                if let arr = obj[k] as? [[String: Any]] { items = arr; break }
                if let nested = obj[k] as? [String: Any],
                   let arr = (nested["products"] ?? nested["results"] ?? nested["items"]) as? [[String: Any]] {
                    items = arr; break
                }
            }
        }

        return items.compactMap { d -> GroceryProduct? in
            let name = (d["title"] as? String) ?? (d["name"] as? String)
                ?? (d["product_title"] as? String) ?? (d["productName"] as? String)
            guard let name, !name.isEmpty else { return nil }
            return GroceryProduct(
                name: name,
                brand: (d["brand"] as? String) ?? (d["brand_name"] as? String) ?? (d["manufacturer"] as? String),
                price: Self.priceString(d["price"] ?? d["current_price"] ?? d["salePrice"] ?? d["price_string"]),
                imageURL: (d["image"] as? String) ?? (d["thumbnail"] as? String)
                    ?? (d["image_url"] as? String) ?? (d["imageUrl"] as? String),
                productURL: (d["url"] as? String) ?? (d["link"] as? String) ?? (d["product_url"] as? String),
                store: store == .amazon ? "Amazon" : "Walmart"
            )
        }
    }

    private static func priceString(_ any: Any?) -> String? {
        if let s = any as? String, !s.isEmpty { return s }
        if let d = any as? Double { return String(format: "$%.2f", d) }
        if let i = any as? Int { return "$\(i)" }
        if let obj = any as? [String: Any] {
            return priceString(obj["amount"] ?? obj["value"] ?? obj["current"])
        }
        return nil
    }
}
