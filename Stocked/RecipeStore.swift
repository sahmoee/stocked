// RecipeStore.swift
// ═══════════════════════════════════════════════════════════════════════════
// Read-only, on-demand store over the prebuilt bundled recipe corpus
// (stocked_recipes.sqlite — ~98k recipes from RecipeNLG).
//
// WHY THIS EXISTS (#4)
// --------------------
// The corpus used to ship as stocked_recipenlg_recipes.json (~98 MB). Every
// launch path that touched RecipeDatabaseManager kicked off an import that did
// `Data(contentsOf:)` + `JSONSerialization` over the whole file — measured at
// ~326 MB peak RSS and ~0.8–2.4 s just to deserialize 100k objects. On real
// devices that transient spike is exactly what triggers slow launches and
// jetsam (memory) terminations.
//
// Now the corpus is a prebuilt SQLite file with an FTS5 full-text index. This
// store opens it read-only (≈0.2 ms, near-zero memory) and answers each query
// by returning only the handful of rows it needs (a search for "chicken"
// returns 8 rows in ≈0.5 ms). The 98k recipes are never all resident in RAM.
//
// RELATIONSHIP TO RecipeDatabase
// ------------------------------
// RecipeDatabase remains the small (2000-cap) WRITABLE store for the user's own
// recipes, web-scraped/online results, and the curated seed. RecipeStore is the
// large READ-ONLY reference corpus. RecipeDatabaseManager queries the writable
// store first and falls through to RecipeStore, so callers are unchanged.
//
// The bundled .sqlite is read-only; we open it directly from the app bundle and
// never copy it to Documents (no write traffic, no disk bloat).
// ═══════════════════════════════════════════════════════════════════════════

import Foundation
import SQLite3   // system libsqlite3 (FTS5 enabled on iOS) — no third-party dependency
import os

// SQLite wants this when binding Swift strings that must outlive the bind call.
private nonisolated(unsafe) let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// One durable artwork repair for the immutable bundled corpus. Stable IDs are preferred;
/// normalized titles let server/title-only imports contribute without copying the SQLite bundle.
nonisolated struct RecipeArtworkRecord: Codable, Equatable, Sendable {
    let recipeID: UUID?
    let titleKey: String
    let imageURL: String
    let updatedAt: Date
}

/// Bounded batch input used by image resolvers and server-import bridges.
nonisolated struct RecipeArtworkUpdate: Sendable {
    let recipeID: UUID?
    let title: String
    let imageURL: String

    init(recipeID: UUID? = nil, title: String, imageURL: String) {
        self.recipeID = recipeID
        self.title = title
        self.imageURL = imageURL
    }
}

/// Actor-owned, memory-bounded derived index. Persistence stores only the record array so the
/// disk format stays compact, inspectable, and migration-friendly.
nonisolated struct RecipeArtworkOverlayIndex: Sendable {
    private let maximumRecordCount: Int
    private var recordsByKey: [String: RecipeArtworkRecord] = [:]
    private var storageKeyByTitle: [String: String] = [:]
    private var newestFirstKeys: [String] = []

    init(records: [RecipeArtworkRecord] = [], maximumRecordCount: Int) {
        self.maximumRecordCount = max(maximumRecordCount, 0)
        for record in records.sorted(by: { $0.updatedAt > $1.updatedAt }) {
            guard record.recipeID != nil || !record.titleKey.isEmpty else { continue }
            let key = Self.storageKey(recipeID: record.recipeID, titleKey: record.titleKey)
            guard recordsByKey[key] == nil else { continue }
            recordsByKey[key] = record
            newestFirstKeys.append(key)
        }
        pruneToBudget()
        rebuildTitleLookup()
    }

    var count: Int { recordsByKey.count }
    var persistedRecords: [RecipeArtworkRecord] {
        newestFirstKeys.compactMap { recordsByKey[$0] }
    }

    func imageURL(recipeID: UUID?, titleKey: String) -> String? {
        if let recipeID,
           let exact = recordsByKey[Self.storageKey(recipeID: recipeID, titleKey: titleKey)] {
            return exact.imageURL
        }
        guard !titleKey.isEmpty, let key = storageKeyByTitle[titleKey] else { return nil }
        return recordsByKey[key]?.imageURL
    }

    func recentRecords(limit: Int) -> [RecipeArtworkRecord] {
        guard limit > 0 else { return [] }
        return newestFirstKeys.prefix(limit).compactMap { recordsByKey[$0] }
    }

    @discardableResult
    mutating func record(_ record: RecipeArtworkRecord) -> Bool {
        guard maximumRecordCount > 0,
              record.recipeID != nil || !record.titleKey.isEmpty else { return false }
        let exactKey = Self.storageKey(recipeID: record.recipeID, titleKey: record.titleKey)
        let titleMappedKey = record.titleKey.isEmpty ? nil : storageKeyByTitle[record.titleKey]
        let destinationKey = record.recipeID == nil ? (titleMappedKey ?? exactKey) : exactKey
        let replacement = RecipeArtworkRecord(
            recipeID: record.recipeID ?? recordsByKey[destinationKey]?.recipeID,
            titleKey: record.titleKey,
            imageURL: record.imageURL,
            updatedAt: record.updatedAt
        )
        if let current = recordsByKey[destinationKey],
           current.recipeID == replacement.recipeID,
           current.titleKey == replacement.titleKey,
           current.imageURL == replacement.imageURL { return false }

        if record.recipeID != nil, let titleMappedKey, titleMappedKey != destinationKey,
           recordsByKey[titleMappedKey]?.recipeID == nil {
            recordsByKey.removeValue(forKey: titleMappedKey)
            newestFirstKeys.removeAll { $0 == titleMappedKey }
        }
        recordsByKey[destinationKey] = replacement
        newestFirstKeys.removeAll { $0 == destinationKey }
        newestFirstKeys.insert(destinationKey, at: 0)
        pruneToBudget()
        rebuildTitleLookup()
        return true
    }

    @discardableResult
    mutating func remove(recipeID: UUID?, titleKey: String) -> Bool {
        var keys = Set<String>()
        if let recipeID { keys.insert(Self.storageKey(recipeID: recipeID, titleKey: titleKey)) }
        if !titleKey.isEmpty, let titleMatch = storageKeyByTitle[titleKey] { keys.insert(titleMatch) }
        guard !keys.isEmpty else { return false }
        var removed = false
        for key in keys where recordsByKey.removeValue(forKey: key) != nil { removed = true }
        guard removed else { return false }
        newestFirstKeys.removeAll { keys.contains($0) }
        rebuildTitleLookup()
        return true
    }

    private static func storageKey(recipeID: UUID?, titleKey: String) -> String {
        recipeID.map { "id:\($0.uuidString.lowercased())" } ?? "title:\(titleKey)"
    }

    private mutating func pruneToBudget() {
        guard recordsByKey.count > maximumRecordCount else { return }
        for key in newestFirstKeys.dropFirst(maximumRecordCount) { recordsByKey.removeValue(forKey: key) }
        newestFirstKeys = Array(newestFirstKeys.prefix(maximumRecordCount))
    }

    private mutating func rebuildTitleLookup() {
        storageKeyByTitle.removeAll(keepingCapacity: true)
        for key in newestFirstKeys {
            guard let record = recordsByKey[key], !record.titleKey.isEmpty,
                  storageKeyByTitle[record.titleKey] == nil else { continue }
            storageKeyByTitle[record.titleKey] = key
        }
    }
}

actor RecipeStore {
    static let shared = RecipeStore()

    private let log = Logger(subsystem: "com.stocked", category: "RecipeStore")

    private var db: OpaquePointer?
    private var didOpen = false
    private var available = false

    // Cached prepared statements (compiled once, reused).
    private var searchStmt: OpaquePointer?
    private var titleLookupStmt: OpaquePointer?
    private var rowLookupStmt: OpaquePointer?
    private var cooccurrenceStmt: OpaquePointer?
    private var sampleRangeStmt: OpaquePointer?
    private var topQualityStmt: OpaquePointer?
    private var minimumRecipeID: Int64 = 0
    private var maximumRecipeID: Int64 = -1
    private var sampleCursor: Int64?

    // The bundled corpus is immutable, so image repairs live in a small writable
    // companion snapshot. Derived dictionaries are actor-owned and capped to keep
    // a server backfill from turning into another unbounded in-memory catalogue.
    private static let artworkOverlayKey = "recipe_artwork_overlay_v1"
    nonisolated static let maximumArtworkRecords = 4_096
    nonisolated static let maximumArtworkBatchSize = 2_000
    private var artworkIndex = RecipeArtworkOverlayIndex(
        maximumRecordCount: RecipeStore.maximumArtworkRecords
    )
    private var artworkOverlayLoaded = false
    private var artworkLoadTask: Task<[RecipeArtworkRecord]?, Never>?
    private var artworkSampleCursor = 0

    private init() {}

    // MARK: - Lifecycle

    /// The bundled database filename (without extension). Built by build_recipe_db.py.
    private static let resourceName = "stocked_recipes"

    private func openIfNeeded() {
        guard !didOpen else { return }
        didOpen = true

        guard let url = Bundle.main.url(forResource: Self.resourceName, withExtension: "sqlite") else {
            log.error("stocked_recipes.sqlite not found in bundle — RecipeStore disabled")
            return
        }

        var handle: OpaquePointer?
        // Read-only + no mutex (actor already serializes access) + URI off.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(url.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            log.error("sqlite3_open_v2 failed: \(rc)")
            if let handle { sqlite3_close(handle) }
            return
        }
        db = handle

        // Read-tuning pragmas (safe on a read-only connection).
        exec("PRAGMA query_only = ON;")
        exec("PRAGMA cache_size = -2000;")   // ~2 MB page cache, plenty for our queries
        exec("PRAGMA mmap_size = 67108864;") // up to 64 MB memory-mapped I/O for fast reads

        prepareStatements()
        loadRecipeIDBounds()
        available = true
        if let n = countSync() {
            log.info("RecipeStore opened: \(n) recipes")
        }
    }

    private func exec(_ sql: String) {
        guard let db else { return }
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            return stmt
        }
        log.error("prepare failed for SQL: \(sql, privacy: .public)")
        return nil
    }

    private func prepareStatements() {
        // FTS5 search → join back to the content table, ranked by bm25 then quality.
        searchStmt = prepare("""
            SELECT r.id, r.title, r.description, r.sourceURL, r.sourceName,
                   r.prepTime, r.cookTime, r.totalTime, r.servings,
                   r.category, r.cuisine, r.tags, r.ingredients, r.steps,
                   r.imageURL, r.quality
            FROM recipes_fts
            JOIN recipes r ON r.id = recipes_fts.rowid
            WHERE recipes_fts MATCH ?
            ORDER BY bm25(recipes_fts), r.quality DESC
            LIMIT ?;
        """)

        titleLookupStmt = prepare("""
            SELECT id, title, description, sourceURL, sourceName,
                   prepTime, cookTime, totalTime, servings,
                   category, cuisine, tags, ingredients, steps, imageURL, quality
            FROM recipes WHERE title_key = ? LIMIT 1;
        """)

        rowLookupStmt = prepare("""
            SELECT id, title, description, sourceURL, sourceName,
                   prepTime, cookTime, totalTime, servings,
                   category, cuisine, tags, ingredients, steps, imageURL, quality
            FROM recipes WHERE id = ? LIMIT 1;
        """)

        cooccurrenceStmt = prepare("""
            SELECT ingredient_b, count FROM cooccurrence
            WHERE ingredient_a = ? ORDER BY count DESC LIMIT ?;
        """)

        // Range sampling uses the INTEGER PRIMARY KEY index. `ORDER BY RANDOM()` scanned and
        // sorted all ~98k corpus rows for every request. This statement reads a bounded ID window
        // at a rotating cursor and rejects rows without artwork before they can be surfaced.
        sampleRangeStmt = prepare("""
            SELECT id, title, description, sourceURL, sourceName,
                   prepTime, cookTime, totalTime, servings,
                   category, cuisine, tags, ingredients, steps, imageURL, quality
            FROM recipes
            WHERE id >= ? AND id <= ? AND steps <> '[]'
            ORDER BY id LIMIT ?;
        """)

        topQualityStmt = prepare("""
            SELECT id, title, description, sourceURL, sourceName,
                   prepTime, cookTime, totalTime, servings,
                   category, cuisine, tags, ingredients, steps, imageURL, quality
            FROM recipes ORDER BY quality DESC LIMIT ?;
        """)
    }

    // MARK: - Public API

    /// Whether the bundled corpus is present and queryable.
    func isAvailable() -> Bool {
        openIfNeeded()
        return available
    }

    func count() -> Int {
        openIfNeeded()
        return countSync() ?? 0
    }

    /// Full-text search over the corpus. Returns up to `limit` ranked entries.
    /// `query` is sanitized into a safe FTS5 prefix expression, so partial words
    /// while typing ("chick") still match ("chicken").
    func search(_ query: String, limit: Int = 8) async -> [RecipeDatabaseEntry] {
        await loadArtworkOverlayIfNeeded()
        openIfNeeded()
        guard available, let stmt = searchStmt else { return [] }
        guard let match = Self.ftsMatchExpression(query) else { return [] }
        let requested = Self.boundedResultLimit(limit, maximum: 100)
        guard requested > 0 else { return [] }
        let candidateBudget = Self.expandedCandidateBudget(
            for: requested,
            multiplier: 16,
            minimum: 64,
            maximum: 512
        )

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(candidateBudget))

        var out: [RecipeDatabaseEntry] = []
        out.reserveCapacity(requested)
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let entry = presentableEntry(from: stmt) else { continue }
            out.append(entry)
            if out.count == requested { break }
        }
        return out
    }

    /// Exact (normalized) title lookup — used to check whether the corpus already
    /// contains a dish before adding/merging, mirroring title-keyed dedup.
    func entry(forTitle title: String) -> RecipeDatabaseEntry? {
        openIfNeeded()
        guard available, let stmt = titleLookupStmt else { return nil }
        let key = RecipeStore.titleKey(title)
        guard !key.isEmpty else { return nil }

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        return sqlite3_step(stmt) == SQLITE_ROW ? rowToEntry(stmt) : nil
    }

    /// Top co-occurring ingredients for a normalized ingredient name.
    /// Returns (name, count) pairs already sorted by count desc.
    func pairings(forIngredient ingredient: String, limit: Int = 10) -> [(name: String, count: Int)] {
        openIfNeeded()
        guard available, let stmt = cooccurrenceStmt else { return [] }
        let key = RecipeStore.ingredientKey(ingredient)
        guard !key.isEmpty else { return [] }
        let requested = Self.boundedResultLimit(limit, maximum: 100)
        guard requested > 0 else { return [] }

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(requested))

        var out: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            out.append((name, count))
        }
        return out
    }

    // MARK: - Artwork overlay

    /// Records or repairs genuine artwork for an immutable corpus recipe without rewriting the
    /// bundled SQLite database. Callers that already know it should provide the stable corpus
    /// ID; title-only server imports remain useful through the normalized fallback.
    @discardableResult
    func recordArtwork(
        imageURL: String,
        recipeID: UUID? = nil,
        title: String
    ) async -> Bool {
        await loadArtworkOverlayIfNeeded()
        let normalizedURL = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedTitle = Self.titleKey(title)
        guard Self.isValidRemoteImageURL(normalizedURL),
              recipeID != nil || !normalizedTitle.isEmpty else { return false }

        let changed = artworkIndex.record(RecipeArtworkRecord(
            recipeID: recipeID,
            titleKey: normalizedTitle,
            imageURL: normalizedURL,
            updatedAt: Date()
        ))
        if changed { persistArtworkOverlay() }
        return changed
    }

    /// Bounded batch entry point for the Server Mac/import bridge. A single call cannot grow
    /// actor occupancy or encoding work beyond `maximumArtworkBatchSize`; callers can submit
    /// subsequent pages after this one completes.
    @discardableResult
    func recordArtwork(_ updates: [RecipeArtworkUpdate]) async -> Int {
        await loadArtworkOverlayIfNeeded()
        guard !updates.isEmpty else { return 0 }

        let now = Date()
        var changedCount = 0
        for update in updates.prefix(Self.maximumArtworkBatchSize) {
            let normalizedURL = update.imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalizedTitle = Self.titleKey(update.title)
            guard Self.isValidRemoteImageURL(normalizedURL),
                  update.recipeID != nil || !normalizedTitle.isEmpty else { continue }
            if artworkIndex.record(RecipeArtworkRecord(
                recipeID: update.recipeID,
                titleKey: normalizedTitle,
                imageURL: normalizedURL,
                updatedAt: now
            )) {
                changedCount += 1
            }
        }
        if changedCount > 0 { persistArtworkOverlay() }
        return changedCount
    }

    /// Removes an obsolete/dead overlay URL. The underlying corpus row is untouched.
    @discardableResult
    func removeArtwork(recipeID: UUID? = nil, title: String) async -> Bool {
        await loadArtworkOverlayIfNeeded()
        let changed = artworkIndex.remove(recipeID: recipeID, titleKey: Self.titleKey(title))
        if changed { persistArtworkOverlay() }
        return changed
    }

    func artworkURL(recipeID: UUID? = nil, title: String) async -> URL? {
        await loadArtworkOverlayIfNeeded()
        guard let raw = artworkIndex.imageURL(recipeID: recipeID, titleKey: Self.titleKey(title)),
              Self.isValidRemoteImageURL(raw) else { return nil }
        return URL(string: raw)
    }

    func artworkRecordCount() async -> Int {
        await loadArtworkOverlayIfNeeded()
        return artworkIndex.count
    }

    /// Lifecycle/tests can request an explicit durability boundary. Normal repairs remain
    /// coalesced by LocalDatabase so a resolver run does not produce one write per image.
    func flushArtworkOverlay() async {
        await loadArtworkOverlayIfNeeded()
        await LocalDatabase.shared.flush()
    }

    /// A varied set of complete recipes used to seed Discover/offline views without loading the
    /// whole corpus. Every returned row has cooking steps and a validated remote image URL; a
    /// text-only corpus therefore contributes no cards instead of silently substituting artwork.
    func randomPresentable(limit: Int = 30) async -> [RecipeDatabaseEntry] {
        await loadArtworkOverlayIfNeeded()
        openIfNeeded()
        guard available,
              let sampleRangeStmt,
              let startID = nextSampleStartID()
        else { return [] }
        let requested = Self.boundedResultLimit(limit, maximum: 200)
        guard requested > 0 else { return [] }

        var out: [RecipeDatabaseEntry] = []
        out.reserveCapacity(requested)
        var seenIDs = Set<UUID>()

        // Seed from known overlay identities first. This makes newly resolved server/image
        // repairs visible immediately even when their row lies outside this call's PK window.
        let overlayBudget = Self.expandedCandidateBudget(
            for: requested,
            multiplier: 4,
            minimum: 64,
            maximum: 256
        )
        for record in rotatingArtworkRecords(limit: overlayBudget) {
            guard let entry = corpusEntry(for: record), seenIDs.insert(entry.id).inserted else { continue }
            out.append(entry)
            if out.count == requested { return out }
        }

        var cursor = startID
        let windowSpan = Self.sampleWindowSpan(for: requested)
        var windowsRead = 0
        repeat {
            let remainingIDs = maximumRecipeID - cursor
            let upperID = cursor + min(remainingIDs, Int64(windowSpan - 1))
            appendSampleRows(
                from: sampleRangeStmt,
                lowerID: cursor,
                upperID: upperID,
                limit: requested - out.count,
                seenIDs: &seenIDs,
                into: &out
            )
            windowsRead += 1
            cursor = upperID == maximumRecipeID ? minimumRecipeID : upperID + 1
        } while out.count < requested
            && windowsRead < Self.maximumSampleWindows
            && cursor != startID
        return out
    }

    /// Highest-quality recipes first. Used by "best first" views.
    func topByQuality(limit: Int = 60) async -> [RecipeDatabaseEntry] {
        await loadArtworkOverlayIfNeeded()
        openIfNeeded()
        guard available, let stmt = topQualityStmt else { return [] }
        let requested = Self.boundedResultLimit(limit, maximum: 200)
        guard requested > 0 else { return [] }
        let candidateBudget = Self.expandedCandidateBudget(
            for: requested,
            multiplier: 32,
            minimum: 512,
            maximum: 4_096
        )
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_int(stmt, 1, Int32(candidateBudget))

        var ranked: [(entry: RecipeDatabaseEntry, quality: Double)] = []
        ranked.reserveCapacity(requested + 256)
        var seenIDs = Set<UUID>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let entry = presentableEntry(from: stmt), seenIDs.insert(entry.id).inserted else { continue }
            ranked.append((entry, sqlite3_column_double(stmt, 15)))
            // The SQL is quality-descending. Once enough valid rows are found, every later
            // corpus row is lower ranked, so no additional scan is useful.
            if ranked.count == requested { break }
        }

        // Overlay rows outside the bounded top-quality window remain eligible. Exact ID/title
        // lookups are indexed and the candidate pool is capped.
        if ranked.count < requested {
            for record in artworkIndex.recentRecords(limit: 256) {
                guard let candidate = corpusEntryAndQuality(for: record),
                      seenIDs.insert(candidate.entry.id).inserted else { continue }
                ranked.append(candidate)
            }
            ranked.sort {
                if $0.quality != $1.quality { return $0.quality > $1.quality }
                return $0.entry.title.localizedCaseInsensitiveCompare($1.entry.title) == .orderedAscending
            }
        }
        return Array(ranked.prefix(requested).map(\.entry))
    }

    // MARK: - Artwork persistence and indexed lookups

    private func loadArtworkOverlayIfNeeded() async {
        guard !artworkOverlayLoaded else { return }

        let task: Task<[RecipeArtworkRecord]?, Never>
        if let existing = artworkLoadTask {
            task = existing
        } else {
            let created = Task(priority: .utility) {
                await LocalDatabase.shared.loadAsync(
                    [RecipeArtworkRecord].self,
                    key: Self.artworkOverlayKey
                )
            }
            artworkLoadTask = created
            task = created
        }

        let loadedRecords = await task.value ?? []
        guard !artworkOverlayLoaded else { return }
        artworkLoadTask = nil

        // Old/dead cache rows are discarded at the boundary so every derived lookup inherits
        // the same image contract. The index constructor also deduplicates and prunes on load.
        let validRecords = loadedRecords.filter {
            Self.isValidRemoteImageURL($0.imageURL)
                && ($0.recipeID != nil || !$0.titleKey.isEmpty)
        }
        artworkIndex = RecipeArtworkOverlayIndex(
            records: validRecords,
            maximumRecordCount: Self.maximumArtworkRecords
        )
        artworkOverlayLoaded = true

        // Compact an older/unbounded snapshot once; subsequent writes are already bounded.
        if artworkIndex.persistedRecords != loadedRecords {
            persistArtworkOverlay()
        }
    }

    private func persistArtworkOverlay() {
        LocalDatabase.shared.save(artworkIndex.persistedRecords, key: Self.artworkOverlayKey)
    }

    /// Rotates through the bounded overlay pool instead of random-sorting it. A prime stride
    /// avoids returning the same prefix on successive Discover refreshes.
    private func rotatingArtworkRecords(limit: Int) -> [RecipeArtworkRecord] {
        let all = artworkIndex.recentRecords(limit: Self.maximumArtworkRecords)
        guard !all.isEmpty, limit > 0 else { return [] }
        let requested = min(limit, all.count)
        let start = artworkSampleCursor % all.count
        var output: [RecipeArtworkRecord] = []
        output.reserveCapacity(requested)
        for offset in 0..<requested { output.append(all[(start + offset) % all.count]) }
        artworkSampleCursor = (start + 257) % all.count
        return output
    }

    private func corpusEntry(for record: RecipeArtworkRecord) -> RecipeDatabaseEntry? {
        corpusEntryAndQuality(for: record)?.entry
    }

    /// Uses the INTEGER PRIMARY KEY or indexed `title_key`; it never scans the corpus.
    private func corpusEntryAndQuality(
        for record: RecipeArtworkRecord
    ) -> (entry: RecipeDatabaseEntry, quality: Double)? {
        if let recipeID = record.recipeID,
           let rowID = Self.rowID(forStableID: recipeID),
           let stmt = rowLookupStmt {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            sqlite3_bind_int64(stmt, 1, rowID)
            if sqlite3_step(stmt) == SQLITE_ROW,
               let entry = presentableEntry(from: stmt, preferredURL: record.imageURL) {
                return (entry, sqlite3_column_double(stmt, 15))
            }
        }

        guard !record.titleKey.isEmpty, let stmt = titleLookupStmt else { return nil }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, record.titleKey, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let entry = presentableEntry(from: stmt, preferredURL: record.imageURL) else { return nil }
        return (entry, sqlite3_column_double(stmt, 15))
    }

    /// Rejects text-only rows before decoding JSON arrays and running classification. Overlay
    /// repairs win over the bundled URL because the bundled corpus is intentionally immutable.
    private func presentableEntry(
        from stmt: OpaquePointer,
        preferredURL: String? = nil
    ) -> RecipeDatabaseEntry? {
        let rowID = sqlite3_column_int64(stmt, 0)
        let recipeID = Self.stableID(forRowID: rowID)
        let title = columnText(stmt, 1)
        let titleKey = Self.titleKey(title)
        let overlayURL = artworkIndex.imageURL(recipeID: recipeID, titleKey: titleKey)
        let bundledURL = columnText(stmt, 14)
        let selectedURL = [preferredURL, overlayURL, bundledURL]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: Self.isValidRemoteImageURL)
        guard let selectedURL else { return nil }

        var entry = rowToEntry(stmt)
        guard !entry.steps.isEmpty else { return nil }
        entry.imageURL = selectedURL
        return entry
    }

    private func columnText(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(stmt, index) else { return "" }
        return String(cString: value)
    }

    // MARK: - Row mapping

    private func countSync() -> Int? {
        guard let db else { return nil }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM recipes;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private func loadRecipeIDBounds() {
        guard let db else { return }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(
            db,
            "SELECT MIN(id), MAX(id) FROM recipes;",
            -1,
            &stmt,
            nil
        ) == SQLITE_OK,
        sqlite3_step(stmt) == SQLITE_ROW,
        sqlite3_column_type(stmt, 0) != SQLITE_NULL,
        sqlite3_column_type(stmt, 1) != SQLITE_NULL
        else { return }
        minimumRecipeID = sqlite3_column_int64(stmt, 0)
        maximumRecipeID = sqlite3_column_int64(stmt, 1)
    }

    /// Advances through the primary-key range by a prime stride. The first cursor is randomized
    /// per process, while subsequent calls avoid repeatedly returning the same nearby rows.
    private func nextSampleStartID() -> Int64? {
        guard maximumRecipeID >= minimumRecipeID else { return nil }
        let span = maximumRecipeID - minimumRecipeID + 1
        let start = sampleCursor ?? Int64.random(in: minimumRecipeID...maximumRecipeID)
        let stride: Int64 = 104_729
        sampleCursor = minimumRecipeID + ((start - minimumRecipeID + stride) % span)
        return start
    }

    private func appendSampleRows(
        from stmt: OpaquePointer,
        lowerID: Int64,
        upperID: Int64,
        limit: Int,
        seenIDs: inout Set<UUID>,
        into output: inout [RecipeDatabaseEntry]
    ) {
        guard limit > 0, upperID >= lowerID else { return }
        let candidateBudget = Self.expandedCandidateBudget(
            for: limit,
            multiplier: 16,
            minimum: 64,
            maximum: 4_096
        )
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_int64(stmt, 1, lowerID)
        sqlite3_bind_int64(stmt, 2, upperID)
        sqlite3_bind_int(stmt, 3, Int32(candidateBudget))
        var added = 0
        while added < limit, sqlite3_step(stmt) == SQLITE_ROW {
            guard let entry = presentableEntry(from: stmt), seenIDs.insert(entry.id).inserted else { continue }
            output.append(entry)
            added += 1
        }
    }

    /// Column order MUST match the SELECTs above:
    /// 0 id, 1 title, 2 description, 3 sourceURL, 4 sourceName, 5 prepTime,
    /// 6 cookTime, 7 totalTime, 8 servings, 9 category, 10 cuisine, 11 tags,
    /// 12 ingredients, 13 steps, 14 imageURL, 15 quality
    private func rowToEntry(_ stmt: OpaquePointer) -> RecipeDatabaseEntry {
        func text(_ i: Int32) -> String {
            guard let c = sqlite3_column_text(stmt, i) else { return "" }
            return String(cString: c)
        }
        let rowid = sqlite3_column_int64(stmt, 0)
        let title = text(1)
        let tags = RecipeStore.decodeJSONArray(text(11))
        let ingredients = RecipeStore.decodeJSONArray(text(12))
        let steps = RecipeStore.decodeJSONArray(text(13))
        let classification = RecipeClassifier.classify(
            title: title,
            rawCuisine: text(10),
            rawCategory: text(9),
            keywords: tags,
            ingredients: ingredients.map { RecipeIngredient(name: $0, amount: "") },
            instructions: steps
        )
        return RecipeDatabaseEntry(
            id:          RecipeStore.stableID(forRowID: rowid),
            title:       title,
            description: text(2),
            sourceURL:   text(3),
            sourceName:  text(4),
            prepTime:    text(5),
            cookTime:    text(6),
            totalTime:   text(7),
            servings:    text(8),
            category:    classification.category,
            cuisine:     classification.cuisine,
            tags:        classification.tags + tags,
            ingredients: ingredients,
            steps:       steps,
            imageURL:    text(14)
        )
    }

    // MARK: - Helpers (nonisolated: pure functions, safe to call anywhere)

    /// Decode a JSON text array column to [String]. Empty/invalid → [].
    nonisolated static func decodeJSONArray(_ json: String) -> [String] {
        guard !json.isEmpty, json != "[]",
              let data = json.data(using: .utf8),
              let arr = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return arr
    }

    /// Converts caller-provided SQL limits into a finite, non-negative result budget. SQLite
    /// interprets a negative LIMIT as unlimited, so every externally supplied limit passes here.
    nonisolated static func boundedResultLimit(_ requested: Int, maximum: Int) -> Int {
        min(max(requested, 0), max(maximum, 0))
    }

    /// Expands a small result target into a finite candidate budget without integer overflow.
    /// Sparse overlays may need several candidates per surfaced row, but no query is ever handed
    /// SQLite a negative (`unlimited`) or unbounded limit.
    nonisolated static func expandedCandidateBudget(
        for requested: Int,
        multiplier: Int,
        minimum: Int,
        maximum: Int
    ) -> Int {
        let ceiling = max(maximum, 0)
        guard ceiling > 0 else { return 0 }
        let bounded = boundedResultLimit(requested, maximum: ceiling)
        guard bounded > 0 else { return 0 }
        let safeMultiplier = max(multiplier, 1)
        let multiplied = bounded > ceiling / safeMultiplier ? ceiling : bounded * safeMultiplier
        return min(max(multiplied, min(max(minimum, 0), ceiling), bounded), ceiling)
    }

    /// Caps each discovery read to a small primary-key window. The image predicate is not a
    /// standalone index in the shipped read-only database, so this bound prevents a sparse or
    /// empty image corpus from turning a sample request into a full-table scan.
    private nonisolated static let maximumSampleWindows = 4

    nonisolated static func sampleWindowSpan(for requested: Int) -> Int {
        let cappedRequest = boundedResultLimit(requested, maximum: 256)
        return min(max(max(cappedRequest, 1) * 16, 512), 4_096)
    }

    /// Only network-backed artwork counts as a genuine recipe image for corpus discovery.
    /// Relative paths, file/data URLs, and malformed values must not pass as presentable cards.
    nonisolated static func isValidRemoteImageURL(_ rawValue: String) -> Bool {
        guard let components = URLComponents(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = components.host,
              !host.isEmpty
        else { return false }
        return true
    }

    /// Normalized title key — mirrors RecipeDedup.key and the builder's
    /// normalize_title: lowercase, alphanumerics only, collapsed whitespace.
    nonisolated static func titleKey(_ title: String) -> String {
        title.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Normalized ingredient key — mirrors IngredientCooccurrence.normalize and
    /// the builder's normalize_ingredient: lowercase, letters only, collapsed.
    nonisolated static func ingredientKey(_ s: String) -> String {
        s.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Build a safe FTS5 MATCH expression from free user text. Each token is
    /// wrapped in double quotes (so punctuation can't break the query) and the
    /// last token gets a trailing `*` for prefix matching while typing. Returns
    /// nil if there's nothing searchable.
    nonisolated static func ftsMatchExpression(_ query: String) -> String? {
        let cleaned = query
            .folding(options: .diacriticInsensitive, locale: nil)
            .lowercased()
        let tokens = cleaned
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 1 }
        guard !tokens.isEmpty else { return nil }

        var parts: [String] = []
        for (idx, token) in tokens.enumerated() {
            let quoted = "\"\(token)\""
            // Prefix-match the final token so "chick" matches "chicken".
            if idx == tokens.count - 1 {
                parts.append("\(quoted)*")
            } else {
                parts.append(quoted)
            }
        }
        // AND semantics: all tokens must be present.
        return parts.joined(separator: " ")
    }

    /// Derive a stable UUID from the SQLite rowid so the same recipe always maps
    /// to the same RecipeDatabaseEntry.id across launches (keeps dedup, favorites,
    /// and open-count tracking consistent even though the corpus is read-only).
    nonisolated static func stableID(forRowID rowid: Int64) -> UUID {
        // Deterministic namespaced UUID: fixed namespace bytes + rowid in the tail.
        var bytes = [UInt8](repeating: 0, count: 16)
        // Static namespace marker ("STKD" + version) in the first 8 bytes.
        bytes[0] = 0x53; bytes[1] = 0x54; bytes[2] = 0x4B; bytes[3] = 0x44
        bytes[4] = 0x52; bytes[5] = 0x43; bytes[6] = 0x50; bytes[7] = 0x01
        var v = UInt64(bitPattern: rowid)
        for i in (8..<16).reversed() {
            bytes[i] = UInt8(v & 0xFF)
            v >>= 8
        }
        // Set version (5) and variant bits so it's a well-formed UUID.
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// Inverse of `stableID(forRowID:)`, used only for an indexed exact corpus lookup. Returns
    /// nil for arbitrary/writable-recipe UUIDs, which then use the indexed normalized-title path.
    nonisolated static func rowID(forStableID id: UUID) -> Int64? {
        let u = id.uuid
        let bytes: [UInt8] = [
            u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7,
            u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15,
        ]
        guard bytes[0] == 0x53, bytes[1] == 0x54, bytes[2] == 0x4B, bytes[3] == 0x44,
              bytes[4] == 0x52, bytes[5] == 0x43,
              (bytes[6] & 0xF0) == 0x50, bytes[7] == 0x01,
              (bytes[8] & 0xC0) == 0x80 else { return nil }

        var value = UInt64(bytes[8] & 0x3F)
        for byte in bytes[9...15] { value = (value << 8) | UInt64(byte) }
        guard value <= UInt64(Int64.max) else { return nil }
        return Int64(value)
    }
}
