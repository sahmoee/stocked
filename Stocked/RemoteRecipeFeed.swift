// RemoteRecipeFeed.swift — DROP-IN replacement for the Stocked app.
//
// FIXES THE PHONE FREEZE: the hosted feed can now hold thousands of recipes, and ingesting
// them all overwhelmed Discover's de-dupe/ingest. This version:
//   • CAPS how many recipes are handed to the app (default 250; override with maxRecipes in
//     feed_config.json), preferring recipes that already have an image;
//   • DROPS junk (missing title/steps, or absurdly long instructions from bad imports);
//   • reads the refresh interval from feed_config.json (refreshHours) instead of a fixed 6h.
//
// Apply to the Stocked repo (replaces the existing RemoteRecipeFeed.swift).

import Foundation

nonisolated enum RemoteRecipeFeed {
    static let feedURLString = "https://raw.githubusercontent.com/sahmoee/stocked-recipes/refs/heads/main/recipes.json"
    private static let cacheKey = "remoteRecipeFeed_v2"   // bumped: capped payload
    private static let defaultHours: Double = 6
    private static let defaultMax = 250

    private static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15; c.timeoutIntervalForResource = 30
        return URLSession(configuration: c)
    }()

    /// Reads { refreshHours, maxRecipes } from feed_config.json next to recipes.json.
    private static func config() async -> (ttl: TimeInterval, max: Int) {
        let cfg = feedURLString.replacingOccurrences(of: "recipes.json", with: "feed_config.json")
        guard cfg != feedURLString, let url = URL(string: cfg),
              let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return (defaultHours * 3600, defaultMax)
        }
        let hours = (obj["refreshHours"] as? NSNumber)?.doubleValue ?? defaultHours
        let maxN  = (obj["maxRecipes"] as? NSNumber)?.intValue ?? defaultMax
        return (max(1, hours) * 3600, max(20, maxN))
    }

    static func fetch() async -> [OnlineRecipe] {
        let trimmed = feedURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else { return [] }

        if let cached = await APIResponseCache.shared.value(for: cacheKey, as: [OnlineRecipe].self) { return cached }

        guard let (data, resp) = try? await session.data(from: url),
              let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let recipes = try? JSONDecoder().decode([OnlineRecipe].self, from: data) else { return [] }

        let (ttl, maxN) = await config()

        // Keep only presentable, sanely-sized recipes — and nothing from a retired source.
        // This feed is published from a repo the app does not control, so the filter goes
        // here rather than trusting the file: a row that comes down tagged "Sowens" or
        // carrying a Kaggle link is dropped before Discover ever sees it, and would be
        // refused by RecipeDatabase afterwards even if it weren't.
        let cleaned = recipes.filter {
            !$0.title.trimmingCharacters(in: .whitespaces).isEmpty &&
            !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            $0.instructions.count < 6000 &&
            !RecipeSourceBlocklist.isBlocked(sourceName: $0.source, sourceURL: $0.imageURL, id: $0.id)
        }
        // Prefer recipes that already have an image, then cap — so Discover stays light and
        // the image resolver isn't asked to fill hundreds of blanks.
        let imaged = cleaned.filter { !$0.imageURL.trimmingCharacters(in: .whitespaces).isEmpty }
        let rest   = cleaned.filter { $0.imageURL.trimmingCharacters(in: .whitespaces).isEmpty }
        let capped = Array((imaged + rest).prefix(maxN))

        await APIResponseCache.shared.store(capped, for: cacheKey, ttl: ttl)
        return capped
    }
}
