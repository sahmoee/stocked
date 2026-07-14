// SpoonacularCache.swift
//
// A lightweight, time-bounded cache for Spoonacular query results, so repeated identical
// searches (same ingredients, same tags) don't spend the daily quota twice. The Spoonacular
// client already guards a daily budget; this complements it by avoiding the spend entirely when
// we've already seen a query recently.
//
// Additive and opt-in: the client can wrap a network call with `cached(forKey:)` /
// `store(_:forKey:)`. Stored to UserDefaults so it survives app launches within the TTL.

import Foundation

/// Generic JSON-backed result cache keyed by a query signature, with a time-to-live.
@MainActor
final class SpoonacularCache {
    static let shared = SpoonacularCache()

    /// How long a cached result stays fresh. Spoonacular recipe data changes slowly; a day
    /// balances freshness against quota savings.
    private let ttl: TimeInterval = 60 * 60 * 24   // 24 hours
    private let legacyStoreKey = "spoonacular.resultCache.v1"
    private let storageKey = "spoonacular_result_cache_v1"
    private let maxEntries = 150

    private struct Entry: Codable {
        var json: Data
        var storedAt: Date
    }

    private var entries: [String: Entry] = [:]

    private init() { load() }

    // MARK: - Key building

    /// Build a stable cache key from the parts of a query. Order-independent for ingredient lists
    /// so ["egg","milk"] and ["milk","egg"] share a cache slot.
    static func key(endpoint: String, ingredients: [String] = [], tags: [String] = [],
                    extra: String = "") -> String {
        let ing = ingredients.map { IngredientMatcher.canonical($0) }.sorted().joined(separator: ",")
        let tg = tags.sorted().joined(separator: ",")
        return "\(endpoint)|\(ing)|\(tg)|\(extra)".lowercased()
    }

    // MARK: - Read / write

    /// Return cached JSON for a key if present and still within TTL, else nil.
    func cachedData(forKey key: String) -> Data? {
        guard let e = entries[key] else { return nil }
        if Date().timeIntervalSince(e.storedAt) > ttl {
            entries[key] = nil
            persist()
            return nil
        }
        return e.json
    }

    /// Decode a cached value of a Codable type for a key, or nil.
    func cached<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard let data = cachedData(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// Store raw JSON under a key.
    func store(_ json: Data, forKey key: String) {
        entries[key] = Entry(json: json, storedAt: Date())
        if entries.count > maxEntries {
            let overflow = entries.count - maxEntries
            for staleKey in entries.sorted(by: { $0.value.storedAt < $1.value.storedAt }).prefix(overflow).map(\.key) {
                entries[staleKey] = nil
            }
        }
        persist()
    }

    /// Encode and store a Codable value under a key.
    func store<T: Encodable>(_ value: T, forKey key: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        store(data, forKey: key)
    }

    /// True if a fresh entry exists for a key — a cheap check before deciding to call the API.
    func has(_ key: String) -> Bool { cachedData(forKey: key) != nil }

    var sizeBytes: Int {
        (try? JSONEncoder().encode(entries).count) ?? 0
    }

    /// Drop everything (e.g. a manual refresh).
    func clear() {
        entries.removeAll()
        LocalDatabase.shared.delete(key: storageKey)
        UserDefaults.standard.removeObject(forKey: legacyStoreKey)
    }

    // MARK: - Persistence

    private func load() {
        let decoded: [String: Entry]?
        if let onDisk = LocalDatabase.shared.load([String: Entry].self, key: storageKey) {
            decoded = onDisk
        } else if let data = UserDefaults.standard.data(forKey: legacyStoreKey) {
            decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        } else {
            decoded = nil
        }
        guard let decoded else { return }
        let now = Date()
        entries = decoded.filter { now.timeIntervalSince($0.value.storedAt) <= ttl }
        persist()
        UserDefaults.standard.removeObject(forKey: legacyStoreKey)
    }

    private func persist() {
        LocalDatabase.shared.save(entries, key: storageKey)
    }
}
