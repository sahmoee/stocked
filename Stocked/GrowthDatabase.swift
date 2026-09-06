// GrowthDatabase.swift
//
// Incremental SQLite persistence for append-heavy collections. LocalDatabase remains the
// deliberately simple JSON store for settings and small snapshots; price and consumption
// histories no longer rewrite one growing JSON document after every row-level change.

import Foundation
import SQLite3
import os

private nonisolated(unsafe) let STOCKED_SQLITE_TRANSIENT = unsafeBitCast(
    -1, to: sqlite3_destructor_type.self
)

nonisolated final class GrowthDatabase: @unchecked Sendable {
    static let shared = GrowthDatabase()

    enum Collection: String, Sendable {
        case priceHistory = "price_history"
        case consumptionLog = "consumption_log"
    }

    private let queue = DispatchQueue(label: "com.stocked.growth-db", qos: .utility)
    private let queueKey = DispatchSpecificKey<UInt8>()
    private var db: OpaquePointer?
    private let storageDirectory: URL?

    init(directory: URL? = nil) {
        storageDirectory = directory
        queue.setSpecific(key: queueKey, value: 1)
        queue.sync { openIfNeeded() }
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func openIfNeeded() {
        guard db == nil else { return }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = storageDirectory ?? base.appendingPathComponent("Stocked", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("growth.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return
        }
        db = handle
        sqlite3_busy_timeout(handle, 2_000)
        sqlite3_exec(handle, "PRAGMA journal_mode=WAL;", nil, nil, nil)
        sqlite3_exec(handle, "PRAGMA synchronous=NORMAL;", nil, nil, nil)
        sqlite3_exec(handle, """
            CREATE TABLE IF NOT EXISTS growth_records (
                collection TEXT NOT NULL,
                id TEXT NOT NULL,
                payload BLOB NOT NULL,
                ordinal INTEGER NOT NULL,
                PRIMARY KEY (collection, id)
            );
            CREATE INDEX IF NOT EXISTS growth_order
            ON growth_records(collection, ordinal);
            CREATE TABLE IF NOT EXISTS public_recipe_catalogue (
                id INTEGER PRIMARY KEY, source TEXT NOT NULL UNIQUE,
                payload BLOB NOT NULL, search TEXT NOT NULL
            );
            """, nil, nil, nil)
    }

    func load<Element: Decodable & Sendable>(_ type: Element.Type,
                                             collection: Collection) -> [Element]? {
        syncOnQueue {
            guard let db else { return nil }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db,
                "SELECT payload FROM growth_records WHERE collection = ? ORDER BY ordinal;",
                -1, &statement, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, collection.rawValue, -1, STOCKED_SQLITE_TRANSIENT)
            var result: [Element] = []
            let decoder = JSONDecoder()
            while sqlite3_step(statement) == SQLITE_ROW {
                let length = Int(sqlite3_column_bytes(statement, 0))
                guard length > 0, let bytes = sqlite3_column_blob(statement, 0) else { continue }
                let data = Data(bytes: bytes, count: length)
                if let row = try? decoder.decode(Element.self, from: data) { result.append(row) }
            }
            return result
        }
    }

    /// Reconciles a value snapshot as individual rows on a serialized utility queue. SQLite's
    /// WAL and one transaction keep readers responsive; IDs not present in the new snapshot are
    /// removed, and rows are independently recoverable if a later payload is malformed.
    func reconcile<Element>(_ values: [Element], collection: Collection)
    where Element: Encodable & Identifiable & Sendable, Element.ID == UUID {
        queue.async { [weak self] in self?.reconcileOnQueue(values, collection: collection) }
    }

    /// Applies only the rows affected by a collection mutation. Append-heavy histories used to
    /// hand `reconcile` the complete array after every new purchase or depletion, making the
    /// background database work grow linearly with history size. The caller already has Swift's
    /// `oldValue`, so derive the small delta before entering SQLite and retain ordinal ordering.
    func applyDelta<Element>(current: [Element], previous: [Element], collection: Collection)
    where Element: Codable & Identifiable & Equatable & Sendable, Element.ID == UUID {
        let oldByID = Dictionary(uniqueKeysWithValues: previous.enumerated().map {
            ($0.element.id, (ordinal: $0.offset, value: $0.element))
        })
        let currentIDs = Set(current.map(\.id))
        let removed = previous.compactMap { currentIDs.contains($0.id) ? nil : $0.id }
        let changed = current.enumerated().compactMap { ordinal, value -> (Int, Element)? in
            guard let old = oldByID[value.id] else { return (ordinal, value) }
            return old.ordinal == ordinal && old.value == value ? nil : (ordinal, value)
        }
        guard !removed.isEmpty || !changed.isEmpty else { return }
        queue.async { [weak self] in
            self?.applyDeltaOnQueue(changed: changed, removed: removed, collection: collection)
        }
    }

    private func applyDeltaOnQueue<Element>(changed: [(Int, Element)], removed: [UUID],
                                            collection: Collection)
    where Element: Encodable & Identifiable, Element.ID == UUID {
        openIfNeeded()
        guard let db else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT;", nil, nil, nil) }

        if !removed.isEmpty {
            var statement: OpaquePointer?
            if sqlite3_prepare_v2(db,
                "DELETE FROM growth_records WHERE collection = ? AND id = ?;",
                -1, &statement, nil) == SQLITE_OK {
                for id in removed {
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                    sqlite3_bind_text(statement, 1, collection.rawValue, -1, STOCKED_SQLITE_TRANSIENT)
                    sqlite3_bind_text(statement, 2, id.uuidString.lowercased(), -1, STOCKED_SQLITE_TRANSIENT)
                    sqlite3_step(statement)
                }
            }
            sqlite3_finalize(statement)
        }

        guard !changed.isEmpty else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO growth_records(collection, id, payload, ordinal)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(collection, id) DO UPDATE SET
                payload = excluded.payload, ordinal = excluded.ordinal;
            """, -1, &statement, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(statement) }
        let encoder = JSONEncoder()
        for (ordinal, value) in changed {
            guard let data = try? encoder.encode(value) else { continue }
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_text(statement, 1, collection.rawValue, -1, STOCKED_SQLITE_TRANSIENT)
            sqlite3_bind_text(statement, 2, value.id.uuidString.lowercased(), -1, STOCKED_SQLITE_TRANSIENT)
            data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(data.count), STOCKED_SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(statement, 4, sqlite3_int64(ordinal))
            sqlite3_step(statement)
        }
    }

    private func reconcileOnQueue<Element>(_ values: [Element], collection: Collection)
    where Element: Encodable & Identifiable, Element.ID == UUID {
        openIfNeeded()
        guard let db else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil)
        defer { sqlite3_exec(db, "COMMIT;", nil, nil, nil) }

        var keep = Set(values.map { $0.id.uuidString.lowercased() })
        var existingStatement: OpaquePointer?
        if sqlite3_prepare_v2(db,
            "SELECT id FROM growth_records WHERE collection = ?;",
            -1, &existingStatement, nil) == SQLITE_OK {
            sqlite3_bind_text(existingStatement, 1, collection.rawValue, -1, STOCKED_SQLITE_TRANSIENT)
            var remove: [String] = []
            while sqlite3_step(existingStatement) == SQLITE_ROW,
                  let raw = sqlite3_column_text(existingStatement, 0) {
                let id = String(cString: raw)
                if keep.remove(id) == nil { remove.append(id) }
            }
            sqlite3_finalize(existingStatement)
            var deleteStatement: OpaquePointer?
            if sqlite3_prepare_v2(db,
                "DELETE FROM growth_records WHERE collection = ? AND id = ?;",
                -1, &deleteStatement, nil) == SQLITE_OK {
                for id in remove {
                    sqlite3_reset(deleteStatement)
                    sqlite3_bind_text(deleteStatement, 1, collection.rawValue, -1, STOCKED_SQLITE_TRANSIENT)
                    sqlite3_bind_text(deleteStatement, 2, id, -1, STOCKED_SQLITE_TRANSIENT)
                    sqlite3_step(deleteStatement)
                }
            }
            sqlite3_finalize(deleteStatement)
        }

        var upsert: OpaquePointer?
        guard sqlite3_prepare_v2(db, """
            INSERT INTO growth_records(collection, id, payload, ordinal)
            VALUES(?, ?, ?, ?)
            ON CONFLICT(collection, id) DO UPDATE SET
                payload = excluded.payload, ordinal = excluded.ordinal;
            """, -1, &upsert, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(upsert) }
        let encoder = JSONEncoder()
        for (ordinal, value) in values.enumerated() {
            guard let data = try? encoder.encode(value) else { continue }
            sqlite3_reset(upsert)
            sqlite3_clear_bindings(upsert)
            sqlite3_bind_text(upsert, 1, collection.rawValue, -1, STOCKED_SQLITE_TRANSIENT)
            sqlite3_bind_text(upsert, 2, value.id.uuidString.lowercased(), -1, STOCKED_SQLITE_TRANSIENT)
            data.withUnsafeBytes { bytes in
                sqlite3_bind_blob(upsert, 3, bytes.baseAddress, Int32(data.count), STOCKED_SQLITE_TRANSIENT)
            }
            sqlite3_bind_int64(upsert, 4, sqlite3_int64(ordinal))
            sqlite3_step(upsert)
        }
    }

    private func syncOnQueue<T>(_ operation: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) == 1 { return operation() }
        return queue.sync(execute: operation)
    }

    // RecipeDatabaseManager owns this disk-backed public catalogue tier. It is not
    // household/user data and is never reconciled/deleted with a bounded UI snapshot.
    // Page commits finish before the transport checkpoint advances.
    func storeRecipePage(_ entries: [RecipeDatabaseEntry]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    self.openIfNeeded()
                    guard let db = self.db, sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
                    var committed = false
                    defer { if !committed { sqlite3_exec(db, "ROLLBACK", nil, nil, nil) } }
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, "INSERT INTO public_recipe_catalogue(source,payload,search) VALUES(?,?,?) ON CONFLICT(source) DO UPDATE SET payload=excluded.payload,search=excluded.search", -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
                    defer { sqlite3_finalize(stmt) }
                    let encoder = JSONEncoder()
                    for entry in entries {
                        guard RecipeBrowserPolicy.url(entry.sourceURL) != nil else { continue }
                        let key = FinderWebPolicy.identity(entry.sourceURL), payload = try encoder.encode(entry)
                        sqlite3_reset(stmt); sqlite3_clear_bindings(stmt)
                        sqlite3_bind_text(stmt, 1, key, -1, STOCKED_SQLITE_TRANSIENT)
                        _ = payload.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(payload.count), STOCKED_SQLITE_TRANSIENT) }
                        sqlite3_bind_text(stmt, 3, FinderQuery.normalize(entry.searchIndex), -1, STOCKED_SQLITE_TRANSIENT)
                        guard sqlite3_step(stmt) == SQLITE_DONE else { throw CocoaError(.fileWriteUnknown) }
                    }
                    guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
                    committed = true; continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func recipePage(after cursor: Int64) async throws -> (entries: [RecipeDatabaseEntry], cursor: Int64, done: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    self.openIfNeeded()
                    guard let db = self.db else { throw CocoaError(.fileReadUnknown) }
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, "SELECT id,payload FROM public_recipe_catalogue WHERE id>? ORDER BY id LIMIT 256", -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_int64(stmt, 1, cursor)
                    var entries: [RecipeDatabaseEntry] = [], last = cursor, status = sqlite3_step(stmt)
                    while status == SQLITE_ROW {
                        last = sqlite3_column_int64(stmt, 0)
                        guard let bytes = sqlite3_column_blob(stmt, 1) else { throw CocoaError(.fileReadCorruptFile) }
                        let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 1)))
                        entries.append(try JSONDecoder().decode(RecipeDatabaseEntry.self, from: data))
                        status = sqlite3_step(stmt)
                    }
                    guard status == SQLITE_DONE else { throw CocoaError(.fileReadUnknown) }
                    continuation.resume(returning: (entries, last, entries.count < 256))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func searchRecipePages(_ query: String, limit: Int) async -> [RecipeDatabaseEntry] {
        await withCheckedContinuation { continuation in
            queue.async {
                let words = FinderQuery.normalize(query).split(whereSeparator: \.isWhitespace).prefix(12)
                guard let db = self.db, !words.isEmpty, limit > 0 else { continuation.resume(returning: []); return }
                var stmt: OpaquePointer?
                let conditions = words.map { _ in "instr(search, ?) > 0" }.joined(separator: " AND ")
                guard sqlite3_prepare_v2(db, "SELECT payload FROM public_recipe_catalogue WHERE \(conditions) ORDER BY id DESC LIMIT ?", -1, &stmt, nil) == SQLITE_OK else { continuation.resume(returning: []); return }
                defer { sqlite3_finalize(stmt) }
                for (index, word) in words.enumerated() { sqlite3_bind_text(stmt, Int32(index + 1), String(word), -1, STOCKED_SQLITE_TRANSIENT) }
                sqlite3_bind_int(stmt, Int32(words.count + 1), Int32(min(120, limit)))
                var results: [RecipeDatabaseEntry] = []
                while sqlite3_step(stmt) == SQLITE_ROW {
                    guard let bytes = sqlite3_column_blob(stmt, 0) else { continue }
                    let data = Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, 0)))
                    if let entry = try? JSONDecoder().decode(RecipeDatabaseEntry.self, from: data) { results.append(entry) }
                }
                continuation.resume(returning: results)
            }
        }
    }

    func recipePageCount() async -> Int {
        await withCheckedContinuation { continuation in
            queue.async {
                var stmt: OpaquePointer?
                defer { sqlite3_finalize(stmt) }
                guard let db = self.db, sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM public_recipe_catalogue", -1, &stmt, nil) == SQLITE_OK,
                      sqlite3_step(stmt) == SQLITE_ROW else { continuation.resume(returning: 0); return }
                continuation.resume(returning: Int(sqlite3_column_int64(stmt, 0)))
            }
        }
    }
}
