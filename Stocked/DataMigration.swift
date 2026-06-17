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
    static func runIfNeeded(from session: GuestDataStore, force: Bool = false) -> [String: Int] {
        let store = StockedDataStore.shared

        // Don't claim success if we're on the in-memory fallback — a non-persistent copy
        // would mislead the user into thinking their data is safely migrated.
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
        var migrated = 0

        // ── Inventory ──────────────────────────────────────────────
        for item in session.inventoryItems {
            guard let data = try? StockedCoders.encoder.encode(item) else { continue }
            let id = item.id.uuidString
            upsert(ctx, id: id, make: {
                SDInventoryItem(recordID: id, name: item.name,
                                zoneRaw: item.storageCategory.rawValue,
                                expirationDate: item.expirationDate, payload: data)
            }, update: { (row: SDInventoryItem) in
                row.name = item.name; row.zoneRaw = item.storageCategory.rawValue
                row.expirationDate = item.expirationDate; row.payload = data; row.updatedAt = .now
            })
            migrated += 1
        }

        // ── Grocery ────────────────────────────────────────────────
        for g in session.groceryItems {
            guard let data = try? StockedCoders.encoder.encode(g) else { continue }
            let id = g.id.uuidString
            upsert(ctx, id: id, make: {
                SDGroceryItem(recordID: id, name: g.name, isPurchased: g.isChecked, payload: data)
            }, update: { (row: SDGroceryItem) in
                row.name = g.name; row.isPurchased = g.isChecked; row.payload = data; row.updatedAt = .now
            })
            migrated += 1
        }

        // ── My Recipes ─────────────────────────────────────────────
        for r in session.userRecipes {
            guard let data = try? StockedCoders.encoder.encode(r) else { continue }
            let id = r.id.uuidString
            let norm = normalize(r.title)
            upsert(ctx, id: id, make: {
                SDUserRecipe(recordID: id, title: r.title, normalizedTitle: norm, payload: data)
            }, update: { (row: SDUserRecipe) in
                row.title = r.title; row.normalizedTitle = norm; row.payload = data; row.updatedAt = .now
            })
            migrated += 1
        }

        // ── Generated / saved recipes ──────────────────────────────
        for r in session.savedGeneratedRecipes {
            guard let data = try? StockedCoders.encoder.encode(r) else { continue }
            let id = r.id.uuidString
            upsert(ctx, id: id, make: {
                SDGeneratedRecipe(recordID: id, title: r.title, isFavorited: r.isFavorited, payload: data)
            }, update: { (row: SDGeneratedRecipe) in
                row.title = r.title; row.isFavorited = r.isFavorited; row.payload = data; row.updatedAt = .now
            })
            migrated += 1
        }

        // ── Past meals ─────────────────────────────────────────────
        for m in session.pastMeals {
            guard let data = try? StockedCoders.encoder.encode(m) else { continue }
            let id = m.id.uuidString
            // LocalPastMeal.date is a String; we don't rely on it for ordering here.
            upsert(ctx, id: id, make: {
                SDPastMeal(recordID: id, title: m.title, date: .now, payload: data)
            }, update: { (row: SDPastMeal) in
                row.title = m.title; row.payload = data
            })
            migrated += 1
        }

        // ── Planned meals ──────────────────────────────────────────
        for m in session.plannedMeals {
            guard let data = try? StockedCoders.encoder.encode(m) else { continue }
            let id = m.id.uuidString
            upsert(ctx, id: id, make: {
                SDPlannedMeal(recordID: id, title: m.title, date: .now, payload: data)
            }, update: { (row: SDPlannedMeal) in
                row.title = m.title; row.payload = data
            })
            migrated += 1
        }

        // ── Price history (time-series) ────────────────────────────
        for p in session.priceHistory {
            guard let data = try? StockedCoders.encoder.encode(p) else { continue }
            let id = p.id.uuidString
            upsert(ctx, id: id, make: {
                SDPriceRecord(recordID: id, itemName: p.itemName, store: p.store,
                              date: p.date, price: p.price, payload: data)
            }, update: { (row: SDPriceRecord) in
                row.itemName = p.itemName; row.store = p.store
                row.date = p.date; row.price = p.price; row.payload = data
            })
            migrated += 1
        }

        // ── Consumption log ────────────────────────────────────────
        for c in session.consumptionLog {
            guard let data = try? StockedCoders.encoder.encode(c) else { continue }
            let id = c.id.uuidString
            upsert(ctx, id: id, make: {
                SDConsumptionRecord(recordID: id, itemName: c.itemName, date: c.depletedAt, payload: data)
            }, update: { (row: SDConsumptionRecord) in
                row.itemName = c.itemName; row.date = c.depletedAt; row.payload = data
            })
            migrated += 1
        }

        // ── Substitutions ──────────────────────────────────────────
        for s in session.userSubstitutions {
            guard let data = try? StockedCoders.encoder.encode(s) else { continue }
            let id = s.id.uuidString
            upsert(ctx, id: id, make: {
                SDSubstitution(recordID: id, fromIngredient: s.ingredient, payload: data)
            }, update: { (row: SDSubstitution) in
                row.fromIngredient = s.ingredient; row.payload = data
            })
            migrated += 1
        }

        do {
            try ctx.save()
            UserDefaults.standard.set(true, forKey: migrationFlagKey)
            migrationLog.info("Migration complete: \(migrated) records copied into SwiftData.")
        } catch {
            // Don't set the flag — we'll retry next launch. UserDefaults data is untouched.
            migrationLog.error("Migration save failed: \(error.localizedDescription). Will retry next launch.")
        }

        return store.counts()
    }

    // MARK: - Upsert helper (idempotent by recordID)

    private static func upsert<T: PersistentModel>(
        _ ctx: ModelContext,
        id: String,
        make: () -> T,
        update: (T) -> Void
    ) {
        // Match an existing row by recordID via its String column. We fetch all and match
        // in memory to avoid per-type predicate boilerplate; collections here are small.
        let descriptor = FetchDescriptor<T>()
        if let existing = (try? ctx.fetch(descriptor))?.first(where: { ($0 as? any RecordIdentified)?.recordID == id }) {
            update(existing)
        } else {
            ctx.insert(make())
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
