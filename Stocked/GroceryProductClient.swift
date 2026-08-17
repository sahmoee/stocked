// GroceryProductClient.swift
// Product, BRAND, PRICE, and image lookups from the Unified Worker. The Worker
// owns the RapidAPI key and exposes only its allowlisted grocery adapter.
//
// This does NOT provide in-store AISLE data (no public API exposes per-store aisle maps);
// for aisle grouping, use Stocked's existing store-section logic on the grocery list.
//
// Keyed server-side: RAPIDAPI_KEY never ships in Stocked.
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
    private struct Envelope: Decodable { let products: [WorkerProduct] }
    private struct WorkerProduct: Decodable {
        let name: String
        let brand: String?
        let regularPrice: Double?
        let imageURL: String?
        let productURL: String?
        let store: String?
    }

    enum Store: String { case amazon, walmart }

    /// Search a store's grocery catalog for a query (e.g. "milk", "greek yogurt"). Cached.
    func search(_ query: String, store: Store = .walmart, page: Int = 1) async -> [GroceryProduct] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, let base = StockedWorkerClient.url() else { return [] }

        let cacheKey = "grocery.\(store.rawValue).\(page).\(term.lowercased())"
        if let hit = await cache.value(for: cacheKey, as: [GroceryProduct].self) { return hit }

        var components = URLComponents(url: base.appendingPathComponent("/retail/rapidapi/products"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "query", value: term),
                                  URLQueryItem(name: "store", value: store.rawValue),
                                  URLQueryItem(name: "page", value: String(max(1, page)))]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        BuildConfig.authorizeWorkerRequest(&request)

        guard let (data, resp) = try? await URLSession.shared.data(for: request),
              let http = resp as? HTTPURLResponse else { return [] }
        if http.statusCode == 501 {
            Log.net.notice("RapidAPI grocery provider is not configured on the Worker")
            return []
        }
        guard (200..<300).contains(http.statusCode) else { return [] }

        let products = (try? JSONDecoder().decode(Envelope.self, from: data).products.map {
            GroceryProduct(name: $0.name, brand: $0.brand,
                           price: $0.regularPrice.map { String(format: "$%.2f", $0) },
                           imageURL: $0.imageURL, productURL: $0.productURL,
                           store: $0.store ?? (store == .amazon ? "Amazon" : "Walmart"))
        }) ?? []
        await cache.store(products, for: cacheKey, ttl: ttl)
        return products
    }

    /// Best single match for an item name (first result). Handy for filling in brand/price.
    func bestMatch(for itemName: String, store: Store = .walmart) async -> GroceryProduct? {
        await search(itemName, store: store).first
    }

}
