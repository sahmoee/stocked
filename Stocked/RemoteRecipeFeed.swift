// RemoteRecipeFeed.swift
// A recipe "funnel" you control WITHOUT shipping an app update. Host a recipes.json file
// on GitHub (or any static host), point feedURLString at its RAW url, and the app pulls +
// merges those recipes into the shared database on each Discover refresh. Add recipes any
// time by editing that one file — the app picks them up within the cache window.
//
// The JSON is simply an array of the app's own OnlineRecipe shape, so it decodes directly:
// [
//   {
//     "id": "feed-margherita-pizza",
//     "title": "Classic Margherita Pizza",
//     "category": "Dinner",
//     "area": "Italian",
//     "instructions": "Step one\nStep two\nStep three",
//     "imageURL": "https://.../pizza.jpg",
//     "ingredients": ["Pizza dough", "Tomato sauce", "Mozzarella"],
//     "measures": ["1 ball", "1/2 cup", "8 oz"],
//     "source": "Community Recipes"
//   }
// ]
// Use the included build_recipes.py to generate a large recipes.json from free sources.

import Foundation

enum RemoteRecipeFeed {

    // ── SET THIS ────────────────────────────────────────────────────────────────
    // Paste the RAW GitHub url of your recipes.json, e.g.
    //   https://raw.githubusercontent.com/sahmoee/stocked-recipes/main/recipes.json
    // Leave empty to disable the feed (it simply no-ops).
    static let feedURLString = ""
    // ────────────────────────────────────────────────────────────────────────────

    private static let cacheKey = "remoteRecipeFeed_v1"
    private static let ttl: TimeInterval = 60 * 60 * 6   // refresh at most every 6 hours

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }()

    /// Fetches the hosted recipe feed and returns presentable recipes. Cached for a few hours,
    /// so repeated Discover refreshes don't re-download, and the last good copy survives offline.
    static func fetch() async -> [OnlineRecipe] {
        let trimmed = feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return [] }

        if let cached = await APIResponseCache.shared.value(for: cacheKey, as: [OnlineRecipe].self) {
            return cached
        }

        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            return []
        }
        guard let recipes = try? JSONDecoder().decode([OnlineRecipe].self, from: data) else {
            return []
        }

        // Keep only entries the app can actually present (a title and some steps).
        let cleaned = recipes.filter {
            !$0.title.trimmingCharacters(in: .whitespaces).isEmpty &&
            !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        await APIResponseCache.shared.store(cleaned, for: cacheKey, ttl: ttl)
        return cleaned
    }
}
