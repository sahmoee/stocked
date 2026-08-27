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

    private init() {
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
        let directory = base.appendingPathComponent("Stocked", isDirectory: true)
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
}
