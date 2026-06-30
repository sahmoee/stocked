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
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

actor RecipeStore {
    static let shared = RecipeStore()

    private let log = Logger(subsystem: "com.stocked", category: "RecipeStore")

    private var db: OpaquePointer?
    private var didOpen = false
    private var available = false

    // Cached prepared statements (compiled once, reused).
    private var searchStmt: OpaquePointer?
    private var titleLookupStmt: OpaquePointer?
    private var cooccurrenceStmt: OpaquePointer?
    private var randomStmt: OpaquePointer?
    private var topQualityStmt: OpaquePointer?

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

        cooccurrenceStmt = prepare("""
            SELECT ingredient_b, count FROM cooccurrence
            WHERE ingredient_a = ? ORDER BY count DESC LIMIT ?;
        """)

        randomStmt = prepare("""
            SELECT id, title, description, sourceURL, sourceName,
                   prepTime, cookTime, totalTime, servings,
                   category, cuisine, tags, ingredients, steps, imageURL, quality
            FROM recipes
            WHERE steps <> '[]'
            ORDER BY RANDOM() LIMIT ?;
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
    func search(_ query: String, limit: Int = 8) -> [RecipeDatabaseEntry] {
        openIfNeeded()
        guard available, let stmt = searchStmt else { return [] }
        guard let match = Self.ftsMatchExpression(query) else { return [] }

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, match, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var out: [RecipeDatabaseEntry] = []
        out.reserveCapacity(limit)
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append(rowToEntry(stmt))
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

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var out: [(String, Int)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = String(cString: sqlite3_column_text(stmt, 0))
            let count = Int(sqlite3_column_int(stmt, 1))
            out.append((name, count))
        }
        return out
    }

    /// A random set of recipes that have cooking steps. Used to seed
    /// Discover/offline views without loading the whole corpus. Note the RecipeNLG
    /// corpus is text-only (no image URLs); the Discover card resolves an image
    /// from the title/category or shows a fallback, so images aren't required here.
    func randomPresentable(limit: Int = 30) -> [RecipeDatabaseEntry] {
        openIfNeeded()
        guard available, let stmt = randomStmt else { return [] }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [RecipeDatabaseEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(rowToEntry(stmt)) }
        return out
    }

    /// Highest-quality recipes first. Used by "best first" views.
    func topByQuality(limit: Int = 60) -> [RecipeDatabaseEntry] {
        openIfNeeded()
        guard available, let stmt = topQualityStmt else { return [] }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_int(stmt, 1, Int32(limit))
        var out: [RecipeDatabaseEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW { out.append(rowToEntry(stmt)) }
        return out
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
        return RecipeDatabaseEntry(
            id:          RecipeStore.stableID(forRowID: rowid),
            title:       text(1),
            description: text(2),
            sourceURL:   text(3),
            sourceName:  text(4),
            prepTime:    text(5),
            cookTime:    text(6),
            totalTime:   text(7),
            servings:    text(8),
            category:    text(9),
            cuisine:     text(10),
            tags:        RecipeStore.decodeJSONArray(text(11)),
            ingredients: RecipeStore.decodeJSONArray(text(12)),
            steps:       RecipeStore.decodeJSONArray(text(13)),
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
}
