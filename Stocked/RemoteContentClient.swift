// RemoteContentClient.swift — the "Sowens" curated recipe feed.
//
// RETIRED — Build 89. This read a curated catalogue (originally static JSON on the
// Namecheap cPanel disk, latterly GET /content/recipes on the Stocked Worker) and stamped
// every row it returned with `id: "sowens-…"` and `source: "Sowens"`. Those recipes are
// no longer wanted in the app, so the fetch is gone: `onlineRecipes(limit:)` and
// `catalog()` return nothing, the on-disk cache is deleted the first time either is
// called, and no network request is made at all.
//
// The type, the wire structs and `parse(_:)` are kept rather than deleted. `RemoteRecipe`
// and `RemoteCatalog` describe a published file format, `OnlineRecipesView` still holds a
// call site, and leaving compiling-but-empty scaffolding here is a smaller change than
// unpicking both — a smaller change is a smaller chance of taking Discover down with it.
//
// If the feed is ever wanted again it needs a NEW source name, not this one. "Sowens" is
// on the blocklist in RecipeSourceBlocklist.swift, so anything still carrying that source
// is refused by RecipeDatabase before it can be stored, whatever fetches it.

import Foundation
import os

// Wire format published to the content origin: /content/recipes.json
nonisolated struct RemoteCatalog: Codable, Sendable {
    var version: Int? = nil
    var updated: String? = nil
    var recipes: [RemoteRecipe] = []
}

nonisolated struct RemoteRecipe: Codable, Sendable {
    var id: String
    var title: String
    var category: String? = nil
    var area: String? = nil
    var instructions: String? = nil
    var image: String? = nil            // relative ("img/recipes/x.jpg") or absolute URL
    var imageURL: String? = nil         // alternate key used by the Recipe Studio feed (absolute URL)
    var ingredients: [String]? = nil
    var measures: [String]? = nil
    var tags: [String]? = nil
    var source: String? = nil

    nonisolated func toOnlineRecipe(base: String) -> OnlineRecipe {
        let resolvedImage: String = {
            guard let im = (image ?? imageURL), !im.isEmpty else { return "" }
            if im.hasPrefix("http") { return im }
            let clean = im.hasPrefix("/") ? String(im.dropFirst()) : im
            return base + "/content/" + clean
        }()
        return OnlineRecipe(
            id: "sowens-\(id)",
            title: title,
            category: category ?? "",
            area: area ?? "",
            instructions: instructions ?? "",
            imageURL: resolvedImage,
            ingredients: ingredients ?? [],
            measures: measures ?? [],
            source: "Sowens"
        )
    }
}

actor RemoteContentClient {
    static let shared = RemoteContentClient()

    /// The cache written by every build up to 88. Cleared once per app run, the first time
    /// anything asks this client for recipes — deleting it is what stops a Mac or phone
    /// that already pulled the catalogue from showing it out of storage forever.
    private var didClearCache = false

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sowens_recipes.json")
    }
    private var etagURL: URL { cacheURL.appendingPathExtension("etag") }

    /// Retired. Returns nothing, fetches nothing, and clears what an earlier build left
    /// on disk. The `limit` parameter is kept so the call site in OnlineRecipesView still
    /// compiles unchanged.
    func onlineRecipes(limit: Int = 40) async -> [OnlineRecipe] {
        clearCacheOnce()
        return []
    }

    /// Retired, same as above. Was: the full catalogue for a "Sowens picks" section.
    func catalog() async -> [RemoteRecipe] {
        clearCacheOnce()
        return []
    }

    private func clearCacheOnce() {
        guard !didClearCache else { return }
        didClearCache = true
        let fm = FileManager.default
        var cleared = 0
        for url in [cacheURL, etagURL] where fm.fileExists(atPath: url.path) {
            if (try? fm.removeItem(at: url)) != nil { cleared += 1 }
        }
        if cleared > 0 {
            Log.data.notice("Curated feed retired; cleared \(cleared, privacy: .public) cached file(s)")
        }
    }

    /// Kept because it describes the published file format and costs nothing. Accepts
    /// either a wrapped catalogue {version, recipes:[…]} or a bare array [ … ].
    static func parse(_ data: Data) -> [RemoteRecipe] {
        let dec = JSONDecoder()
        if let cat = try? dec.decode(RemoteCatalog.self, from: data) { return cat.recipes }
        if let arr = try? dec.decode([RemoteRecipe].self, from: data) { return arr }
        return []
    }
}
