//
//  StockedDataStore.swift
//  Stocked.
//
//  CHECKPOINT 1 of the data-layer migration (DB #1, #2, #5, #10).
//
//  This introduces a real, queryable, row-based SwiftData store ALONGSIDE the existing
//  UserDefaults/disk JSON persistence. NOTHING here replaces or deletes the current
//  storage — AppSession continues to read/write UserDefaults exactly as before. This
//  file only:
//    • defines @Model row types (one per domain collection),
//    • opens a ModelContainer,
//    • and is populated once by DataMigration (a non-destructive COPY).
//
//  Design choice — "Codable envelope" models:
//  Each @Model stores the original Codable struct as encoded `payload: Data`, plus a
//  small number of *queryable* columns (id, name, dates, flags) lifted out for indexing
//  and predicates. This deliberately avoids re-declaring every field of the rich existing
//  structs (e.g. LocalInventoryItem has ~30 fields) in @Model form, which would be the
//  most error-prone part of the migration and risk silently dropping/corrupting fields.
//  The real read/write cutover (Checkpoint 2) can then map fields deliberately, with the
//  envelope guaranteeing no data is lost in the meantime.
//
//  Schema versioning (DB #5): every row carries `schemaVersion`. Bumps let future
//  migrations detect and upgrade old rows instead of corrupting them.
//

import Foundation
import SwiftData
import os.log

// MARK: - Schema version

enum StockedSchema {
    /// Bump when a @Model's stored shape changes in a way that needs migration.
    static let version = 1
}

private let dataStoreLog = Logger(subsystem: "com.sowens.Stocked", category: "DataStore")

// MARK: - Codable envelope helpers

/// Shared JSON coders. ISO-8601 dates so envelope payloads are portable to the export file.
enum StockedCoders {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }()
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}

// MARK: - @Model row types
//
// One model per AppSession collection. Each holds:
//   • `payload`  — the full original Codable struct, encoded (source of truth for the value)
//   • queryable columns — lifted out for indexing / predicates / sorting
//   • `schemaVersion` — for future migrations
//
// `recordID` is the stable string id (UUID string where the source had one) so a row can
// be matched back to its origin and deduplicated.

@Model
final class SDInventoryItem {
    // recordID is the dedup key. It is NOT declared @Attribute(.unique): CloudKit
    // mirroring rejects unique constraints (error 134060), which prevented the store from
    // loading at all. Uniqueness is enforced in code by the upsert-by-recordID helper.
    var recordID: String = ""
    var name: String = ""
    var zoneRaw: String = ""
    var expirationDate: Date?
    var updatedAt: Date = Date.now
    var schemaVersion: Int = StockedSchema.version
    var payload: Data = Data()

    init(recordID: String, name: String, zoneRaw: String, expirationDate: Date?, payload: Data) {
        self.recordID = recordID
        self.name = name
        self.zoneRaw = zoneRaw
        self.expirationDate = expirationDate
        self.payload = payload
        self.updatedAt = .now
        self.schemaVersion = StockedSchema.version
    }
}

@Model
final class SDGroceryItem {
    // recordID is the dedup key. It is NOT declared @Attribute(.unique): CloudKit
    // mirroring rejects unique constraints (error 134060), which prevented the store from
    // loading at all. Uniqueness is enforced in code by the upsert-by-recordID helper.
    var recordID: String = ""
    var name: String = ""
    var isPurchased: Bool = false
    var updatedAt: Date = Date.now
    var schemaVersion: Int = StockedSchema.version
    var payload: Data = Data()

    init(recordID: String, name: String, isPurchased: Bool, payload: Data) {
        self.recordID = recordID
        self.name = name
        self.isPurchased = isPurchased
        self.payload = payload
        self.updatedAt = .now
        self.schemaVersion = StockedSchema.version
    }
}

@Model
final class SDUserRecipe {
    // recordID is the dedup key. It is NOT declared @Attribute(.unique): CloudKit
    // mirroring rejects unique constraints (error 134060), which prevented the store from
    // loading at all. Uniqueness is enforced in code by the upsert-by-recordID helper.
    var recordID: String = ""
    var title: String = ""
    var normalizedTitle: String = ""   // dedup key (DB #9)
    var updatedAt: Date = Date.now
    var schemaVersion: Int = StockedSchema.version
    var payload: Data = Data()

    init(recordID: String, title: String, normalizedTitle: String, payload: Data) {
        self.recordID = recordID
        self.title = title
        self.normalizedTitle = normalizedTitle
        self.payload = payload
        self.updatedAt = .now
        self.schemaVersion = StockedSchema.version
    }
}

@Model
final class SDGeneratedRecipe {
    // recordID is the dedup key. It is NOT declared @Attribute(.unique): CloudKit
    // mirroring rejects unique constraints (error 134060), which prevented the store from
    // loading at all. Uniqueness is enforced in code by the upsert-by-recordID helper.
    var recordID: String = ""
    var title: String = ""
    var isFavorited: Bool = false
    var updatedAt: Date = Date.now
    var schemaVersion: Int = StockedSchema.version
    var payload: Data = Data()

    init(recordID: String, title: String, isFavorited: Bool, payload: Data) {
        self.recordID = recordID
        self.title = title
        self.isFavorited = isFavorited
        self.payload = payload
        self.updatedAt = .now
        self.schemaVersion = StockedSchema.version
    }
}

@Model
final class SDPastMeal {
    // recordID is the dedup key. It is NOT declared @Attribute(.unique): CloudKit
    // mirroring rejects unique constraints (error 134060), which prevented the store from
    // loading at all. Uniqueness is enforced in code by the upsert-by-recordID helper.
    var recordID: String = ""
    var title: String = ""
    var date: Date = Date.now
    var schemaVersion: Int = StockedSchema.version
    var payload: Data = Data()

    init(recordID: String, title: String, date: Date, payload: Data) {
        self.recordID = recordID
        self.title = title
        self.date = date
        self.payload = payload
        self.schemaVersion = StockedSchema.version
    }
}

@Model
final class SDPlannedMeal {
    // recordID is the dedup key. It is NOT declared @Attribute(.unique): CloudKit
    // mirroring rejects unique constraints (error 134060), which prevented the store from
    // loading at all. Uniqueness is enforced in code by the upsert-by-recordID helper.
    var recordID: String = ""
    var title: String = ""
    var date: Date = Date.now
    var schemaVersion: Int = StockedSchema.version
    var payload: Data = Data()

    init(recordID: String, title: String, date: Date, payload: Data) {
        self.recordID = recordID
        self.title = title
        self.date = date
        self.payload = payload
        self.schemaVersion = StockedSchema.version
    }
}

/// Price history — modeled as a proper time-series row (DB #13) so future
/// "price over time" queries are indexed by item/store/date.
@Model
final class SDPriceRecord {
    // recordID is the dedup key. It is NOT declared @Attribute(.unique): CloudKit
    // mirroring rejects unique constraints (error 134060), which prevented the store from
    // loading at all. Uniqueness is enforced in code by the upsert-by-recordID helper.
    var recordID: String = ""
    var itemName: String = ""
    var store: String = ""
    var date: Date = Date.now
    var price: Double = 0
    var schemaVersion: Int = StockedSchema.version
    var payload: Data = Data()

    init(recordID: String, itemName: String, store: String, date: Date, price: Double, payload: Data) {
        self.recordID = recordID
        self.itemName = itemName
        self.store = store
        self.date = date
        self.price = price
        self.payload = payload
        self.schemaVersion = StockedSchema.version
    }
}

@Model
final class SDConsumptionRecord {
    // recordID is the dedup key. It is NOT declared @Attribute(.unique): CloudKit
    // mirroring rejects unique constraints (error 134060), which prevented the store from
    // loading at all. Uniqueness is enforced in code by the upsert-by-recordID helper.
    var recordID: String = ""
    var itemName: String = ""
    var date: Date = Date.now
    var schemaVersion: Int = StockedSchema.version
    var payload: Data = Data()

    init(recordID: String, itemName: String, date: Date, payload: Data) {
        self.recordID = recordID
        self.itemName = itemName
        self.date = date
        self.payload = payload
        self.schemaVersion = StockedSchema.version
    }
}

@Model
final class SDSubstitution {
    // recordID is the dedup key. It is NOT declared @Attribute(.unique): CloudKit
    // mirroring rejects unique constraints (error 134060), which prevented the store from
    // loading at all. Uniqueness is enforced in code by the upsert-by-recordID helper.
    var recordID: String = ""
    var fromIngredient: String = ""
    var schemaVersion: Int = StockedSchema.version
    var payload: Data = Data()

    init(recordID: String, fromIngredient: String, payload: Data) {
        self.recordID = recordID
        self.fromIngredient = fromIngredient
        self.payload = payload
        self.schemaVersion = StockedSchema.version
    }
}

// MARK: - Container

/// Owns the SwiftData ModelContainer for the app. Lives separately from the existing
/// stores so it can be introduced and verified without touching current persistence.
@MainActor
final class StockedDataStore {
    static let shared = StockedDataStore()

    /// The container, or nil if SwiftData failed to initialize entirely. When nil, the
    /// store is simply unavailable — the app keeps running on its existing persistence and
    /// the migration/verification safely no-op. NOTHING here ever crashes the app.
    let container: ModelContainer?
    /// True only if an on-disk store opened successfully.
    let isPersistent: Bool

    private init() {
        let schema = Schema([
            SDInventoryItem.self, SDGroceryItem.self, SDUserRecipe.self,
            SDGeneratedRecipe.self, SDPastMeal.self, SDPlannedMeal.self,
            SDPriceRecord.self, SDConsumptionRecord.self, SDSubstitution.self
        ])
        // Try on-disk, then in-memory, then give up gracefully — never crash.
        // CloudKit mirroring is explicitly DISABLED for this store. Stocked's cloud sync runs
        // through its own CloudKit + Worker path (household sync, iCloud backups), not through
        // SwiftData. Leaving mirroring on the default (automatic) made SwiftData try to mirror
        // this store, and CloudKit rejects the recordID unique constraints (error 134060) — so
        // the store failed to load entirely. Pinning cloudKitDatabase to .none keeps this a
        // purely local store and immune to that class of failure.
        let diskConfig = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false,
                                            cloudKitDatabase: .none)
        if let disk = try? ModelContainer(for: schema, configurations: [diskConfig]) {
            container = disk
            isPersistent = true
            dataStoreLog.info("SwiftData store opened on disk (schema v\(StockedSchema.version)).")
        } else if let disk2 = StockedDataStore.recoverByResettingStore(schema: schema, config: diskConfig) {
            // A prior crash can leave a corrupt store file. Delete it and retry once.
            container = disk2
            isPersistent = true
            dataStoreLog.info("SwiftData store reset after a load failure, reopened on disk.")
        } else if let mem = try? ModelContainer(for: schema,
                                                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true,
                                                                                     cloudKitDatabase: .none)]) {
            container = mem
            isPersistent = false
            dataStoreLog.error("SwiftData disk store failed; using in-memory fallback (data won't persist).")
        } else {
            container = nil
            isPersistent = false
            dataStoreLog.error("SwiftData unavailable — store failed to initialize. App continues on existing storage.")
        }
    }

    /// If the on-disk store is corrupt (e.g. left over from a crash), remove the default
    /// store files and try once more. Returns a fresh container or nil. Never throws.
    private static func recoverByResettingStore(schema: Schema, config: ModelConfiguration) -> ModelContainer? {
        let fm = FileManager.default
        guard let appSupport = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                           appropriateFor: nil, create: false) else { return nil }
        // SwiftData's default store is "default.store" (+ -wal/-shm) in Application Support.
        for name in ["default.store", "default.store-wal", "default.store-shm"] {
            let url = appSupport.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { try? fm.removeItem(at: url) }
        }
        return try? ModelContainer(for: schema, configurations: [config])
    }

    /// The main context, or nil if the store is unavailable.
    var context: ModelContext? { container?.mainContext }

    /// Row counts per model — returns -1 for everything if the store is unavailable.
    func counts() -> [String: Int] {
        guard let context else {
            return ["Inventory": -1, "Grocery": -1, "My Recipes": -1, "Generated": -1,
                    "Past Meals": -1, "Planned": -1, "Prices": -1, "Consumption": -1, "Subs": -1]
        }
        func count<T: PersistentModel>(_ type: T.Type) -> Int {
            (try? context.fetchCount(FetchDescriptor<T>())) ?? -1
        }
        return [
            "Inventory":   count(SDInventoryItem.self),
            "Grocery":     count(SDGroceryItem.self),
            "My Recipes":  count(SDUserRecipe.self),
            "Generated":   count(SDGeneratedRecipe.self),
            "Past Meals":  count(SDPastMeal.self),
            "Planned":     count(SDPlannedMeal.self),
            "Prices":      count(SDPriceRecord.self),
            "Consumption": count(SDConsumptionRecord.self),
            "Subs":        count(SDSubstitution.self)
        ]
    }
}
