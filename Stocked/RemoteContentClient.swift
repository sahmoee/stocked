// RemoteContentClient.swift — reads curated recipe content hosted as static files on the
// Namecheap cPanel disk (<contentBaseURL>/content/recipes.json + /content/img/recipes/*).
//
// Why cPanel: static JSON + images are exactly what cheap shared hosting is good at — no
// compute, just fast HTTPS file serving, cached hard on-device with ETag revalidation.
// Everything here is non-fatal: any failure returns cached data or an empty list, so the
// app is never blocked or broken if the files aren't up yet.

import Foundation

// Wire format published to cPanel: /content/recipes.json
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

    private var backoffUntil: Date? = nil   // after a 404/failure, don't re-hit the network until this passes

    // WORKER-ONLY: all curated content is served by the Stocked Worker (GET /content/recipes and
    // /content/img/* — edge-cached with ETag + stale-on-error). cPanel is no longer used; the
    // Worker fetches recipes from the GitHub site-repo and caches them at Cloudflare's edge.
    private var base: String { StockedWorkerClient.url()?.absoluteString ?? BuildConfig.receiptWorkerURL }
    private var catalogURL: URL? {
        guard let worker = StockedWorkerClient.url() ?? URL(string: BuildConfig.receiptWorkerURL) else { return nil }
        return worker.appendingPathComponent("content/recipes")
    }

    private var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sowens_recipes.json")
    }
    private var etagURL: URL { cacheURL.appendingPathExtension("etag") }

    /// Curated recipes for the Discover feed. Returns [] if content isn't published yet.
    func onlineRecipes(limit: Int = 40) async -> [OnlineRecipe] {
        guard BuildConfig.contentEnabled, !base.isEmpty, let url = catalogURL else { return [] }

        // During backoff, serve whatever we cached without touching the network.
        if let until = backoffUntil, until > Date() { return decodeCached(limit: limit) }

        var req = URLRequest(url: url, cachePolicy: .reloadRevalidatingCacheData, timeoutInterval: 8)
        if let tag = loadETag() { req.setValue(tag, forHTTPHeaderField: "If-None-Match") }
        BuildConfig.authorizeWorkerRequest(&req)   // Worker routes are key-gated

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else { return decodeCached(limit: limit) }
            switch http.statusCode {
            case 304:
                backoffUntil = nil
                return decodeCached(limit: limit)
            case 200:
                try? data.write(to: cacheURL)
                if let tag = http.value(forHTTPHeaderField: "ETag") { try? tag.write(to: etagURL, atomically: true, encoding: .utf8) }
                backoffUntil = nil
                return decode(data, limit: limit)
            default:
                // 404 (not published yet) / 5xx — back off an hour, serve cache meanwhile.
                backoffUntil = Date().addingTimeInterval(3600)
                return decodeCached(limit: limit)
            }
        } catch {
            backoffUntil = Date().addingTimeInterval(1800)
            return decodeCached(limit: limit)
        }
    }

    /// Full catalog (e.g. for a "Sowens picks" section). Non-fatal.
    func catalog() async -> [RemoteRecipe] {
        _ = await onlineRecipes(limit: .max)
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return Self.parse(data)
    }

    private func loadETag() -> String? { try? String(contentsOf: etagURL, encoding: .utf8) }

    private func decodeCached(limit: Int) -> [OnlineRecipe] {
        guard let data = try? Data(contentsOf: cacheURL) else { return [] }
        return decode(data, limit: limit)
    }
    private func decode(_ data: Data, limit: Int) -> [OnlineRecipe] {
        return Self.parse(data).prefix(limit).map { $0.toOnlineRecipe(base: base) }
    }
    /// Accept either a wrapped catalog {version, recipes:[…]} or a bare array [ … ] (what the
    /// Recipe Studio feed publishes), so both formats work.
    static func parse(_ data: Data) -> [RemoteRecipe] {
        let dec = JSONDecoder()
        if let cat = try? dec.decode(RemoteCatalog.self, from: data) { return cat.recipes }
        if let arr = try? dec.decode([RemoteRecipe].self, from: data) { return arr }
        return []
    }
}
