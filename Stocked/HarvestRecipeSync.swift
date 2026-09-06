// HarvestRecipeSync.swift — pulls the Mac-approved harvest recipe cache into this device.
//
// The Stocked for Mac app harvests recipes from the web, the user approves them locally, and
// `HarvestCloudSync.swift` (Mac) pushes the approved ones to the unified Worker:
//
//   POST /harvest/cache   — recipes → CROWD KV (harvest:recipe:<id> + harvest:index)
//   POST /harvest/image   — one image per recipe → R2 if bound, else KV base64
//
// The Worker exposes them back to every device:
//
//   GET  /harvest/recipes        — { version, updatedAt, count, recipes:[…] }, 10-min edge cache
//   GET  /harvest/img/<id>.jpg   — the cached image, 30-day edge cache
//
// Until now iOS never adopted those two GET routes — recipes the Mac approved reached the
// Worker and stopped there. This client closes that gap: it pulls /harvest/recipes on launch,
// on every foreground, and on a 15-minute timer (the Worker edge-caches for 10 minutes, so a
// tighter cadence would just re-read the same cache), then folds each recipe into the on-device
// `RecipeDatabase` — the single pool that powers Discover's offline seed, recipe search, the
// mood finder and cook ranking. Same `X-Stocked-Key` header as every other Worker call, so no
// new credential. The paginated route walks actual records, independently of the flat index.
//
// Everything here degrades silently. A harvest recipe that never arrives is a recipe the user
// simply doesn't see yet — never an error surfaced in the kitchen.

import Foundation
import os
import Observation

@Observable
@MainActor
final class HarvestRecipeSync {
    static let shared = HarvestRecipeSync()

    // MARK: Cadence

    /// Background poll interval. The Worker edge-caches /harvest/recipes for 10 minutes; 15
    /// keeps the device "frequently updated" without repeatedly pulling an identical body.
    private let refreshInterval: TimeInterval = 15 * 60
    /// Smallest gap between foreground-triggered pulls, so rapidly re-opening the app can't
    /// hammer the route. A launch/foreground within this window of the last sync is skipped.
    private let minForegroundGap: TimeInterval = 5 * 60

    private let lastSyncKey = "harvestRecipeSyncLastAt_v1"
    private let cursorKey = "harvestRecipeSyncCursor_v2"
    private let completedKey = "harvestRecipeCatalogueCompleted_v2"
    private let cachedCountKey = "harvestRecipeCatalogueCachedCount_v1"
    var catalogueCount: Int
    var refreshingCatalogue = false
    var catalogueError = false
    private var cataloguePaused = false
    var catalogueComplete: Bool
    private var fullCatalogueTask: Task<Void, Never>?
    private var lastPageSucceeded = false

    private var loopTask: Task<Void, Never>?
    private var inFlight: Task<Int, Never>?
    private var pendingPublications: [UUID: UserRecipe] = [:]
    private var publicationTask: Task<Void, Never>?

    private init() {
        let defaults = UserDefaults.standard
        catalogueCount = defaults.integer(forKey: cachedCountKey)
        catalogueComplete = defaults.double(forKey: completedKey) > 0
        // Show the persisted count on the first frame, then cheaply reconcile it with the
        // disk-backed catalogue without loading recipe payloads into memory.
        Task { [weak self] in
            guard let self else { return }
            let diskCount = await GrowthDatabase.shared.recipePageCount()
            self.catalogueCount = diskCount
            defaults.set(diskCount, forKey: self.cachedCountKey)
        }
    }

    private var lastSyncAt: Date? {
        get {
            let t = UserDefaults.standard.double(forKey: lastSyncKey)
            return t > 0 ? Date(timeIntervalSince1970: t) : nil
        }
        set { UserDefaults.standard.set(newValue?.timeIntervalSince1970 ?? 0, forKey: lastSyncKey) }
    }

    // MARK: Lifecycle

    /// Idempotent. Pulls once now (if stale) and starts the periodic loop. Safe to call on
    /// every launch — a second call is a no-op while the loop is already running.
    func start() {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            guard let self else { return }
            await self.syncIfStale(minGap: 0)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.refreshInterval * 1_000_000_000))
                if Task.isCancelled { break }
                await self.syncIfStale(minGap: 0)
            }
        }
    }

    /// Returning to the foreground: pull again, but only if the last pull is older than the
    /// foreground gap. Mirrors HouseholdSync.syncOnForeground's "fresh on return" behaviour.
    func syncOnForeground() {
        Task { [weak self] in await self?.syncIfStale(minGap: self?.minForegroundGap ?? 0) }
    }

    /// Manual pull (pull-to-refresh / debug). Always fetches; returns how many recipes were
    /// ingested (0 on a 304, offline, or failure).
    @discardableResult
    func syncNow() async -> Int { await sync() }

    /// Completes the entire server walk without an index/page-count cap. Work and
    /// disk writes are still page bounded; a retry/relaunch resumes the last committed
    /// cursor. UI never waits for this to start showing already-cached matches.
    func refreshFullCatalogue(force: Bool = false) {
        guard fullCatalogueTask == nil, ConnectivityMonitor.isOnlineFlag else { return }
        guard force || (!cataloguePaused && !catalogueError) else { return }
        let completed = UserDefaults.standard.double(forKey: completedKey)
        guard force || completed == 0 || Date().timeIntervalSince1970 - completed > 3600 else { return }
        refreshingCatalogue = true; catalogueError = false; cataloguePaused = false
        fullCatalogueTask = Task { [weak self] in
            guard let self else { return }
            defer { refreshingCatalogue = false; fullCatalogueTask = nil }
            repeat {
                guard !Task.isCancelled, ConnectivityMonitor.isOnlineFlag else { return }
                _ = await sync()
                guard lastPageSucceeded else { catalogueError = true; return }
                if UserDefaults.standard.string(forKey: cursorKey) == nil { return }
                do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            } while !Task.isCancelled
        }
    }

    func stopCatalogueRefresh() { cataloguePaused = true; fullCatalogueTask?.cancel() }

    /// Source-attributed imports belong to the shared recipe database, independent of
    /// household membership. Personal/source-less recipes remain local/household data.
    func publishImported(_ recipe: UserRecipe) {
        guard isPublishable(recipe) else { return }
        pendingPublications[recipe.id] = recipe
        guard publicationTask == nil else { return }
        publicationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self else { return }
            defer { self.publicationTask = nil }
            // One worker, not one task/request per recipe during a bulk import.
            while !Task.isCancelled, !self.pendingPublications.isEmpty {
                let batch = Array(self.pendingPublications.values.prefix(20))
                for recipe in batch { self.pendingPublications[recipe.id] = nil }
                guard await self.performPublish(batch) else {
                    for recipe in batch where self.pendingPublications[recipe.id] == nil {
                        self.pendingPublications[recipe.id] = recipe
                    }
                    // Do not spin while offline; a later change retries this queue and
                    // the persisted local recipes remain the relaunch backfill source.
                    return
                }
                await Task.yield()
            }
        }
    }

    /// Idempotently repairs older installations. Batches keep hundreds of historical
    /// imports from becoming hundreds of requests or one oversized allocation.
    func backfillImported(_ recipes: [UserRecipe]) async {
        let imported = recipes.filter(isPublishable)
        var offset = 0
        while offset < imported.count {
            guard !Task.isCancelled else { return }
            guard await performPublish(Array(imported[offset..<min(offset + 20, imported.count)])) else { return }
            offset += 20
        }
    }

    private func performPublish(_ recipes: [UserRecipe]) async -> Bool {
        guard StockedUnifiedWorker.isConfigured,
              let url = StockedUnifiedWorker.url("harvest/cache") else { return false }
        let rows = recipes.compactMap(wireRecipe)
        guard !rows.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: ["schemaVersion": 2, "recipes": rows])
        else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&request)
        request.httpBody = body
        request.timeoutInterval = 20
        do {
            let (_, response) = try await URLSession.stocked.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else { return false }
            lastSyncAt = nil
            return true
        } catch { return false }
    }

    private func isPublishable(_ recipe: UserRecipe) -> Bool {
        func isHTTPS(_ value: String?) -> Bool {
            guard let value, let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return url.scheme?.lowercased() == "https" && url.host?.isEmpty == false
        }
        // Source-attributed imports from Stocked Mac/server/import caches contribute
        // automatically. Source-less personal recipes remain private because they fail
        // the provenance checks below and stay in My Collection only.
        return isHTTPS(recipe.sourceURL) && isHTTPS(recipe.imageURL)
            && recipe.ingredients.count >= 3 && !recipe.instructions.isEmpty
    }

    private func wireRecipe(_ recipe: UserRecipe) -> [String: Any]? {
        guard isPublishable(recipe) else { return nil }
        guard let sourceURL = recipe.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              sourceURL.lowercased().hasPrefix("https://"),
              let imageURL = recipe.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
              imageURL.lowercased().hasPrefix("https://"),
              !recipe.instructions.isEmpty else { return nil }
        let cleanSource = recipe.sourceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = cleanSource?.isEmpty == false
            ? cleanSource!
            : (URL(string: sourceURL)?.host ?? "Original publisher")
        return [
            "id": recipe.id.uuidString, "title": recipe.title,
            "description": recipe.description, "cuisine": recipe.cuisine,
            "tags": recipe.tags, "categories": recipe.categories ?? recipe.tags,
            "ingredients": recipe.ingredients.map { ["name": $0.name, "amount": $0.amount] },
            "instructions": recipe.instructions, "sourceURL": sourceURL,
            "attribution": source, "imageURL": imageURL,
            "author": recipe.author ?? "", "license": recipe.license ?? "",
            "imageAttribution": recipe.imageAttribution ?? "",
            "servings": max(1, recipe.servings), "prepTime": recipe.prepTime,
            "cookTime": recipe.cookTime, "importedBy": "stocked-ios",
            "importedAt": StockedFormatters.iso8601.string(from: recipe.dateCreated),
        ]
    }

    // MARK: Sync

    private func syncIfStale(minGap: TimeInterval) async {
        if minGap > 0, let last = lastSyncAt, Date().timeIntervalSince(last) < minGap { return }
        _ = await sync()
    }

    /// Coalesces concurrent callers onto one in-flight request.
    private func sync() async -> Int {
        if let inFlight { return await inFlight.value }
        let task = Task<Int, Never> { [weak self] in
            guard let self else { return 0 }
            return await self.performFetch()
        }
        inFlight = task
        let result = await task.value
        // Clear synchronously on this same main-actor turn. The earlier version deferred
        // the clear onto a separate Task, which left a window where a caller arriving after
        // the fetch finished but before that Task ran would coalesce onto a dead task and
        // skip a fresh pull. Because the class is @MainActor and we are past the await here,
        // no other sync() body can interleave between task completion and this line.
        inFlight = nil
        return result
    }

    private func performFetch() async -> Int {
        lastPageSucceeded = false
        guard StockedUnifiedWorker.isConfigured,
              !BuildConfig.stockedWorkerKey.isEmpty,
              ConnectivityMonitor.isOnlineFlag,
              let url = StockedUnifiedWorker.url("harvest/recipes") else { return 0 }

        var ingested = 0
        do {
          for _ in 0..<4 {
            try Task.checkCancellation()
            let cursor = UserDefaults.standard.string(forKey: cursorKey)
            var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            parts.queryItems = [URLQueryItem(name: "pageSize", value: "100")]
            if let cursor { parts.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
            var request = URLRequest(url: parts.url!)
            BuildConfig.authorizeWorkerRequest(&request)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.stocked.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }

            let base = StockedUnifiedWorker.baseURLString
            let (imports, next) = try await Task.detached(priority: .utility) {
                let decoded = try JSONDecoder().decode(HarvestWireResponse.self, from: data)
                let next = try RecipeCataloguePaging.next(current: cursor, complete: decoded.complete, next: decoded.nextCursor)
                let imports = decoded.recipes.compactMap { recipe -> HarvestImport? in
                    guard let entry = recipe.toDatabaseEntry(workerBase: base) else { return nil }
                    return HarvestImport(entry: entry, importedAt: recipe.importDate)
                }
                return (imports, next)
            }.value
            let entries = imports.map(\.entry)
            try Task.checkCancellation()
            // Commit EVERY public row to the durable catalogue before the small
            // in-memory discovery snapshot can evict it, and before checkpointing.
            try await RecipeDatabaseManager.shared.ingestCataloguePage(entries)

            if !entries.isEmpty, cursor == nil {
                // Keep a small warm first page for existing rails. Do not cycle the
                // complete corpus through the bounded snapshot, evict useful rows, or
                // repeatedly announce historical catalogue pages as household imports.
                let inserted = await RecipeDatabaseManager.shared.ingestHarvested(entries)
                let insertedIDs = Set(inserted.map(\.id))
                let activity = imports
                    .filter { insertedIDs.contains($0.entry.id) }
                    .map { (id: $0.entry.id, title: $0.entry.title, importedAt: $0.importedAt) }
                await HouseholdSync.shared.logStockedMacImports(activity)
            }
            if let next { UserDefaults.standard.set(next, forKey: cursorKey) }
            else {
                UserDefaults.standard.removeObject(forKey: cursorKey)
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: completedKey)
                catalogueComplete = true
            }
            ingested += entries.count
            catalogueCount = await GrowthDatabase.shared.recipePageCount()
            UserDefaults.standard.set(catalogueCount, forKey: cachedCountKey)
            lastSyncAt = Date()
            if next == nil { break }
          }
            lastPageSucceeded = true; catalogueError = false
            return ingested
        } catch is CancellationError {
            return 0
        } catch {
            Log.data.error("Harvest sync failed: \(error.localizedDescription, privacy: .public)")
            return 0
        }
    }
}

// MARK: - Wire format (matches Stocked Mac's HarvestCloudSync payload)

nonisolated private struct HarvestWireResponse: Decodable, Sendable {
    var version: Int?
    var updatedAt: String?
    var count: Int = 0
    var recipes: [HarvestWireRecipe] = []
    var complete: Bool?
    var nextCursor: String?
}

nonisolated private struct HarvestWireIngredient: Decodable, Sendable {
    var name: String = ""
    var amount: String = ""
}

nonisolated private struct HarvestImport: Sendable {
    var entry: RecipeDatabaseEntry
    var importedAt: Date
}

nonisolated private struct HarvestWireRecipe: Decodable, Sendable {
    var id: String = ""
    var title: String = ""
    var description: String?
    var cuisine: String?
    var tags: [String]?
    var categories: [String]?
    var ingredients: [HarvestWireIngredient]?
    var instructions: [String]?
    var sourceURL: String?
    var importedBy: String?
    var importedAt: String?
    var storedAt: String?
    var attribution: String?
    var author: String?
    var license: String?
    var imageAttribution: String?
    var confidence: Double?
    var image: String?        // relative Worker path, e.g. "/harvest/img/<id>.jpg"
    var imageURL: String?     // absolute original image URL, when the Mac had one
    var servings: Int?
    var prepTime: String?
    var cookTime: String?

    var importDate: Date {
        for value in [importedAt, storedAt].compactMap({ $0 }) {
            if let date = StockedFormatters.iso8601Fractional.date(from: value)
                ?? StockedFormatters.iso8601.date(from: value) {
                return date
            }
        }
        return Date()
    }

    /// Convert one harvested recipe into the flat record every iOS ingestion path stores.
    /// Returns nil for a recipe with no title or no usable instructions — the same bar
    /// RecipeSourceHub.isFullRecipe holds other feeds to.
    func toDatabaseEntry(workerBase: String) -> RecipeDatabaseEntry? {
        let cleanTitle = RecipeDisplayPolicy.cleanedTitle(title)
        guard !cleanTitle.isEmpty else { return nil }

        let steps = (instructions ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !steps.isEmpty else { return nil }

        let ingredientLines: [String] = (ingredients ?? []).compactMap { item in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let amount = item.amount.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            return amount.isEmpty ? name : "\(amount) \(name)"
        }

        // Prefer the absolute original image; otherwise resolve the Worker's cached-image path
        // against the Worker base so <id>.jpg becomes a full https URL the resolver can load.
        let resolvedImage: String = {
            if let abs = imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
               RecipeDisplayPolicy.isLikelyRecipeImageURL(abs, sourceURL: sourceURL) {
                return abs
            }
            guard let rel = image?.trimmingCharacters(in: .whitespacesAndNewlines), !rel.isEmpty else { return "" }
            if rel.hasPrefix("http") {
                return RecipeDisplayPolicy.isLikelyRecipeImageURL(rel, sourceURL: sourceURL) ? rel : ""
            }
            let base = workerBase.hasSuffix("/") ? String(workerBase.dropLast()) : workerBase
            return rel.hasPrefix("/") ? base + rel : base + "/" + rel
        }()
        guard !resolvedImage.isEmpty,
              RecipeDisplayPolicy.isLikelyRecipeImageURL(resolvedImage, sourceURL: sourceURL) else { return nil }

        // Attribution is the Mac's display source (host/author). Fall back to a neutral,
        // non-blocklisted label so the recipe still counts under a source in the browser.
        let source = (attribution?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? URL(string: sourceURL ?? "")?.host
            ?? "Personal recipe"

        let cuisineValue = cuisine?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var tagList = tags ?? []
        if !cuisineValue.isEmpty { tagList.append(cuisineValue) }
        tagList = Array(Set(tagList.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }))

        return RecipeDatabaseEntry(
            // Stable across re-syncs. When the Mac id is already a UUID we keep it; when it
            // is a slug/hash (harvested-from-web recipes often key on a URL hash, not a UUID)
            // we DERIVE a UUID deterministically from that id string rather than minting a
            // fresh random one every sync — a random id would churn the stored entry's id on
            // each pull and break anything referencing it (favourites, open-count tracking),
            // even though title-dedup keeps the row itself from duplicating.
            id:          UUID(uuidString: id) ?? HarvestWireRecipe.stableUUID(from: id.isEmpty ? cleanTitle : id),
            title:       cleanTitle,
            description: description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            sourceURL:   sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            sourceName:  source,
            prepTime:    prepTime ?? "",
            cookTime:    cookTime ?? "",
            totalTime:   "",
            servings:    servings.map(String.init) ?? "",
            category:    categories?.first ?? tagList.first ?? "",
            cuisine:     cuisineValue,
            tags:        tagList,
            ingredients: ingredientLines,
            steps:       steps,
            imageURL:    resolvedImage,
            author: author, license: license, imageAttribution: imageAttribution
        )
    }

    /// Derive a deterministic UUID from an arbitrary id string, so the same Mac-side id
    /// always maps to the same recipe id on this device. Uses the app's FNV-1a scheme
    /// (Swift's `Hasher` is per-launch seeded and unusable for anything that must persist).
    /// Two salted 64-bit passes fill the 16 UUID bytes.
    static func stableUUID(from s: String) -> UUID {
        func fnv1a(_ input: String) -> UInt64 {
            var hash: UInt64 = 0xcbf29ce484222325
            for byte in input.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x100000001b3
            }
            return hash
        }
        let hi = fnv1a(s)
        let lo = fnv1a("harvest-salt::" + s)
        var bytes = [UInt8](repeating: 0, count: 16)
        for i in 0..<8 { bytes[i]     = UInt8((hi >> (8 * UInt64(7 - i))) & 0xff) }
        for i in 0..<8 { bytes[8 + i] = UInt8((lo >> (8 * UInt64(7 - i))) & 0xff) }
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
