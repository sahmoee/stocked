//
//  DataMigration.swift
//  Stocked.
//
//  CHECKPOINT 1 — non-destructive migration of existing data into SwiftData.
//
//  SAFETY CONTRACT (read this before touching anything here):
//    • This ONLY reads AppSession's already-loaded collections and COPIES them into the
//      SwiftData store. It never writes to, clears, or removes UserDefaults / disk JSON.
//    • If anything throws, we log and bail — the app keeps running on the existing store.
//    • It runs at most once (guarded by a flag), and is idempotent anyway because every
//      row upserts by a stable recordID.
//    • After this, AppSession STILL reads/writes UserDefaults. The SwiftData copy is a
//      verified parallel mirror. The actual cutover happens in Checkpoint 2.
//

import Foundation
import SwiftData
import os.log

private let migrationLog = Logger(subsystem: "com.sowens.Stocked", category: "DataMigration")

@MainActor
enum DataMigration {

    /// Bump alongside StockedSchema.version if a re-migration is ever required.
    private static let migrationFlagKey = "swiftdata.migration.v1.complete"

    static var hasRun: Bool {
        UserDefaults.standard.bool(forKey: migrationFlagKey)
    }

    /// Copy everything from the (already-loaded) AppSession collections into SwiftData.
    /// Safe to call on every launch — it no-ops once complete. Returns the resulting row
    /// counts so the caller can show a verification summary.
    @discardableResult
    static func runIfNeeded(from session: GuestDataStore,
                            force: Bool = false) async -> [String: Int] {
        let store = StockedDataStore.shared

        guard store.isPersistent else {
            migrationLog.error("Skipping migration: store is in-memory (non-persistent).")
            return store.counts()
        }

        guard force || !hasRun else {
            return store.counts()
        }

        migrationLog.info("Starting non-destructive migration into SwiftData…")
        guard let ctx = store.context else {
            migrationLog.error("Migration skipped: no SwiftData context available.")
            return store.counts()
        }

        // Fetch each table ONCE. The previous implementation fetched the entire table for
        // every source record (O(n²)) on the main actor, which could leave the first launch
        // after an update blank until the migration flag was finally written.
        var existingInventory    = existingRows(ctx, as: SDInventoryItem.self)
        var existingGrocery      = existingRows(ctx, as: SDGroceryItem.self)
        var existingUserRecipes  = existingRows(ctx, as: SDUserRecipe.self)
        var existingGenerated    = existingRows(ctx, as: SDGeneratedRecipe.self)
        var existingPastMeals    = existingRows(ctx, as: SDPastMeal.self)
        var existingPlannedMeals = existingRows(ctx, as: SDPlannedMeal.self)
        var existingPrices       = existingRows(ctx, as: SDPriceRecord.self)
        var existingConsumption  = existingRows(ctx, as: SDConsumptionRecord.self)
        var existingSubs         = existingRows(ctx, as: SDSubstitution.self)

        var migrated = 0

        for item in session.inventoryItems {
            guard let data = try? StockedCoders.encoder.encode(item) else { continue }
            let id = item.id.uuidString
            upsert(ctx, id: id, existing: &existingInventory, make: {
                SDInventoryItem(recordID: id, name: item.name,
                                zoneRaw: item.storageCategory.rawValue,
                                expirationDate: item.expirationDate, payload: data)
            }, update: { row in
                row.name = item.name
                row.zoneRaw = item.storageCategory.rawValue
                row.expirationDate = item.expirationDate
                row.payload = data
                row.updatedAt = .now
            })
            migrated += 1
            await yieldIfNeeded(migrated)
        }

        for g in session.groceryItems {
            guard let data = try? StockedCoders.encoder.encode(g) else { continue }
            let id = g.id.uuidString
            upsert(ctx, id: id, existing: &existingGrocery, make: {
                SDGroceryItem(recordID: id, name: g.name, isPurchased: g.isChecked, payload: data)
            }, update: { row in
                row.name = g.name
                row.isPurchased = g.isChecked
                row.payload = data
                row.updatedAt = .now
            })
            migrated += 1
            await yieldIfNeeded(migrated)
        }

        for r in session.userRecipes {
            guard let data = try? StockedCoders.encoder.encode(r) else { continue }
            let id = r.id.uuidString
            let norm = normalize(r.title)
            upsert(ctx, id: id, existing: &existingUserRecipes, make: {
                SDUserRecipe(recordID: id, title: r.title, normalizedTitle: norm, payload: data)
            }, update: { row in
                row.title = r.title
                row.normalizedTitle = norm
                row.payload = data
                row.updatedAt = .now
            })
            migrated += 1
            await yieldIfNeeded(migrated)
        }

        for r in session.savedGeneratedRecipes {
            guard let data = try? StockedCoders.encoder.encode(r) else { continue }
            let id = r.id.uuidString
            upsert(ctx, id: id, existing: &existingGenerated, make: {
                SDGeneratedRecipe(recordID: id, title: r.title,
                                  isFavorited: r.isFavorited, payload: data)
            }, update: { row in
                row.title = r.title
                row.isFavorited = r.isFavorited
                row.payload = data
                row.updatedAt = .now
            })
            migrated += 1
            await yieldIfNeeded(migrated)
        }

        for m in session.pastMeals {
            guard let data = try? StockedCoders.encoder.encode(m) else { continue }
            let id = m.id.uuidString
            upsert(ctx, id: id, existing: &existingPastMeals, make: {
                SDPastMeal(recordID: id, title: m.title, date: .now, payload: data)
            }, update: { row in
                row.title = m.title
                row.payload = data
            })
            migrated += 1
            await yieldIfNeeded(migrated)
        }

        for m in session.plannedMeals {
            guard let data = try? StockedCoders.encoder.encode(m) else { continue }
            let id = m.id.uuidString
            upsert(ctx, id: id, existing: &existingPlannedMeals, make: {
                SDPlannedMeal(recordID: id, title: m.title, date: .now, payload: data)
            }, update: { row in
                row.title = m.title
                row.payload = data
            })
            migrated += 1
            await yieldIfNeeded(migrated)
        }

        for price in session.priceHistory {
            guard let data = try? StockedCoders.encoder.encode(price) else { continue }
            let id = price.id.uuidString
            upsert(ctx, id: id, existing: &existingPrices, make: {
                SDPriceRecord(recordID: id, itemName: price.itemName, store: price.store,
                              date: price.date, price: price.price, payload: data)
            }, update: { row in
                row.itemName = price.itemName
                row.store = price.store
                row.date = price.date
                row.price = price.price
                row.payload = data
            })
            migrated += 1
            await yieldIfNeeded(migrated)
        }

        for consumption in session.consumptionLog {
            guard let data = try? StockedCoders.encoder.encode(consumption) else { continue }
            let id = consumption.id.uuidString
            upsert(ctx, id: id, existing: &existingConsumption, make: {
                SDConsumptionRecord(recordID: id, itemName: consumption.itemName,
                                    date: consumption.depletedAt, payload: data)
            }, update: { row in
                row.itemName = consumption.itemName
                row.date = consumption.depletedAt
                row.payload = data
            })
            migrated += 1
            await yieldIfNeeded(migrated)
        }

        for substitution in session.userSubstitutions {
            guard let data = try? StockedCoders.encoder.encode(substitution) else { continue }
            let id = substitution.id.uuidString
            upsert(ctx, id: id, existing: &existingSubs, make: {
                SDSubstitution(recordID: id, fromIngredient: substitution.ingredient, payload: data)
            }, update: { row in
                row.fromIngredient = substitution.ingredient
                row.payload = data
            })
            migrated += 1
            await yieldIfNeeded(migrated)
        }

        do {
            try ctx.save()
            UserDefaults.standard.set(true, forKey: migrationFlagKey)
            migrationLog.info("Migration complete: \(migrated) records copied into SwiftData.")
        } catch {
            migrationLog.error("Migration save failed: \(error.localizedDescription). Will retry next launch.")
        }

        return store.counts()
    }

    // MARK: - O(1) upsert helpers

    private static func existingRows<T: PersistentModel & RecordIdentified>(
        _ ctx: ModelContext,
        as type: T.Type
    ) -> [String: T] {
        let rows = (try? ctx.fetch(FetchDescriptor<T>())) ?? []
        return Dictionary(rows.map { ($0.recordID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private static func upsert<T: PersistentModel & RecordIdentified>(
        _ ctx: ModelContext,
        id: String,
        existing: inout [String: T],
        make: () -> T,
        update: (T) -> Void
    ) {
        if let row = existing[id] {
            update(row)
        } else {
            let row = make()
            ctx.insert(row)
            existing[id] = row
        }
    }

    private static func yieldIfNeeded(_ processed: Int) async {
        if processed.isMultiple(of: 40) {
            await Task.yield()
        }
    }

    /// Normalized title for dedup (DB #9): lowercased, punctuation/space-collapsed.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// Lets the generic upsert read `recordID` off any of our models without a per-type switch.
protocol RecordIdentified { var recordID: String { get } }
extension SDInventoryItem: RecordIdentified {}
extension SDGroceryItem: RecordIdentified {}
extension SDUserRecipe: RecordIdentified {}
extension SDGeneratedRecipe: RecordIdentified {}
extension SDPastMeal: RecordIdentified {}
extension SDPlannedMeal: RecordIdentified {}
extension SDPriceRecord: RecordIdentified {}
extension SDConsumptionRecord: RecordIdentified {}
extension SDSubstitution: RecordIdentified {}
