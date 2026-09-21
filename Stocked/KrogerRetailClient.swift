// KrogerRetailClient.swift — typed shopper data from the Unified Worker.
// Kroger credentials never ship in Stocked. The Worker exchanges and caches the
// OAuth token, validates upstream responses, and returns this provider-neutral shape.

import Foundation
import CoreLocation
import os

nonisolated struct KrogerRetailLocation: Codable, Identifiable, Hashable, Sendable {
    var id: String { locationId }
    let provider: String
    let locationId: String
    let name: String
    let chain: String?
    let phone: String?
    let address: Address
    let latitude: Double?
    let longitude: Double?
    let departments: [Department]

    nonisolated struct Address: Codable, Hashable, Sendable {
        let line1: String?
        let line2: String?
        let city: String?
        let state: String?
        let zipCode: String?
        let county: String?

        var display: String {
            [[line1, line2].compactMap { $0 }.joined(separator: " "),
             [city, state].compactMap { $0 }.joined(separator: ", "), zipCode]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
    }

    nonisolated struct Department: Codable, Hashable, Sendable {
        let id: String?
        let name: String?
        let phone: String?
    }
}

nonisolated struct KrogerRetailProduct: Codable, Identifiable, Hashable, Sendable {
    var id: String { productId }
    let provider: String
    let productId: String
    let upc: String?
    let name: String
    let brand: String?
    let categories: [String]
    let size: String?
    let soldBy: String?
    let regularPrice: Double?
    let promoPrice: Double?
    let inventoryLevel: String?
    let fulfillment: Fulfillment
    let aisleLocations: [AisleLocation]
    let locationId: String?
    let imageURL: String?
    let productURL: String?

    nonisolated struct Fulfillment: Codable, Hashable, Sendable {
        let inStore: Bool
        let curbside: Bool
        let delivery: Bool
        let shipToHome: Bool
    }

    nonisolated struct AisleLocation: Codable, Hashable, Sendable {
        let description: String?
        let number: String?
        let side: String?
        let shelfNumber: String?

        var display: String? {
            let parts = [number.map { "Aisle \($0)" }, description, side.map { "Side \($0)" },
                         shelfNumber.map { "Shelf \($0)" }].compactMap { $0 }
            return parts.isEmpty ? nil : parts.joined(separator: " · ")
        }
    }
}

actor KrogerRetailClient {
    static let shared = KrogerRetailClient()

    private struct LocationEnvelope: Decodable { let locations: [KrogerRetailLocation] }
    private struct ProductEnvelope: Decodable { let products: [KrogerRetailProduct] }
    private let cache = APIResponseCache.shared

    func locations(near coordinate: CLLocationCoordinate2D,
                   radiusMiles: Int = 20,
                   limit: Int = 30) async -> [KrogerRetailLocation] {
        let lat = String(format: "%.5f", coordinate.latitude)
        let lon = String(format: "%.5f", coordinate.longitude)
        let key = "kroger.locations.\(lat).\(lon).\(radiusMiles).\(limit)"
        if let cached = await cache.value(for: key, as: [KrogerRetailLocation].self) { return cached }
        let values: [KrogerRetailLocation] = await get(
            path: "/retail/kroger/locations",
            query: ["lat": lat, "lon": lon, "radius": "\(max(1, min(100, radiusMiles)))",
                    "limit": "\(max(1, min(200, limit)))"],
            as: LocationEnvelope.self)?.locations ?? []
        if !values.isEmpty { await cache.store(values, for: key, ttl: 6 * 3600) }
        return values
    }

    func locations(zipCode: String, radiusMiles: Int = 20, limit: Int = 30) async -> [KrogerRetailLocation] {
        let zip = zipCode.filter(\.isNumber)
        guard zip.count == 5 else { return [] }
        let key = "kroger.locations.zip.\(zip).\(radiusMiles).\(limit)"
        if let cached = await cache.value(for: key, as: [KrogerRetailLocation].self) { return cached }
        let values: [KrogerRetailLocation] = await get(
            path: "/retail/kroger/locations",
            query: ["zipCode": zip, "radius": "\(max(1, min(100, radiusMiles)))",
                    "limit": "\(max(1, min(200, limit)))"],
            as: LocationEnvelope.self)?.locations ?? []
        if !values.isEmpty { await cache.store(values, for: key, ttl: 6 * 3600) }
        return values
    }

    func products(matching term: String,
                  locationId: String? = nil,
                  limit: Int = 20) async -> [KrogerRetailProduct] {
        let clean = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return [] }
        var query = ["term": clean, "limit": "\(max(1, min(50, limit)))"]
        if let locationId, !locationId.isEmpty { query["locationId"] = locationId }
        let key = "kroger.products.\(locationId ?? "global").\(limit).\(clean.lowercased())"
        if let cached = await cache.value(for: key, as: [KrogerRetailProduct].self) { return cached }
        let values = await get(path: "/retail/kroger/products", query: query,
                               as: ProductEnvelope.self)?.products ?? []
        if !values.isEmpty { await cache.store(values, for: key, ttl: locationId == nil ? 24 * 3600 : 30 * 60) }
        return values
    }

    private func get<T: Decodable>(path: String, query: [String: String], as type: T.Type) async -> T? {
        guard let base = StockedWorkerClient.url() else { return nil }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        components?.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        BuildConfig.authorizeWorkerRequest(&request)
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { return nil }
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            Log.net.notice("Kroger retail request unavailable: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
