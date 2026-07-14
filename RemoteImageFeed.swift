// RemoteImageFeed.swift — title → image URL lookup from the stocked-recipes repo.
//
// The Recipe Manager app publishes images.json (a { "normalized title": "https://…" } map)
// alongside recipes.json in github.com/sahmoee/stocked-recipes. This feed gives the image
// resolver a first, zero-API-quota source: if a recipe title has a curated image in the
// repo, use it before hitting any external image API. Cached in memory + UserDefaults for
// 12 hours; all failures degrade silently to the resolver's existing pipeline.
import Foundation

@MainActor
final class RemoteImageFeed {
    static let shared = RemoteImageFeed()
    private init() {}

    private static let feedURL = "https://raw.githubusercontent.com/sahmoee/stocked-recipes/main/images.json"
    private static let cacheKey = "remoteImageFeed_v1"
    private static let cacheStampKey = "remoteImageFeed_stamp_v1"
    private static let maxAge: TimeInterval = 12 * 3600

    private var map: [String: String] = [:]
    private var loaded = false
    private var fetchTask: Task<Void, Never>? = nil

    /// Curated image URL for a recipe title, or nil. Synchronous against the in-memory map;
    /// kicks off a background refresh the first time it's asked (and when the cache is stale),
    /// so early lookups may miss until the feed lands — the resolver's normal pipeline covers it.
    func lookup(title: String) -> String? {
        loadIfNeeded()
        let key = Self.normalize(title)
        guard !key.isEmpty else { return nil }
        if let hit = map[key], !hit.isEmpty { return hit }
        return nil
    }

    private func loadIfNeeded() {
        if !loaded {
            loaded = true
            if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
               let m = try? JSONDecoder().decode([String: String].self, from: data) {
                map = m
            }
        }
        let stamp = UserDefaults.standard.double(forKey: Self.cacheStampKey)
        let stale = Date().timeIntervalSince1970 - stamp > Self.maxAge
        guard stale, fetchTask == nil, let url = URL(string: Self.feedURL) else { return }
        fetchTask = Task { [weak self] in
            defer { Task { @MainActor in self?.fetchTask = nil } }
            guard let (data, resp) = try? await URLSession.shared.data(from: url),
                  let http = resp as? HTTPURLResponse, http.statusCode == 200,
                  let raw = try? JSONDecoder().decode([String: String].self, from: data) else { return }
            var normalized: [String: String] = [:]
            for (k, v) in raw where !v.isEmpty { normalized[Self.normalize(k)] = v }
            await MainActor.run { [weak self] in
                self?.map = normalized
                if let encoded = try? JSONEncoder().encode(normalized) {
                    UserDefaults.standard.set(encoded, forKey: Self.cacheKey)
                }
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.cacheStampKey)
            }
        }
    }

    nonisolated private static func normalize(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: .current)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
