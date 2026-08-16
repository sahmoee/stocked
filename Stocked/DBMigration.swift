// DBMigration.swift — Run-once schema migrations for persisted collections (#6, hardened #8).
//
// Before this, one-off data migrations (e.g. "Drinks zone → Fridge") were inline `.map`
// transforms that ran on EVERY launch forever. This registry stamps a per-collection
// schema version and only runs each migration step once.
//
// HARDENING (#8): the schema version is now persisted to the on-disk data store (via
// LocalDatabase) with UserDefaults kept only as a fast mirror. Previously the version
// lived solely in UserDefaults — which is NOT included in an iCloud restore or a
// "Transfer Kitchen" import. That meant a fresh install that restored its data files
// (but not UserDefaults) would read version 0 and re-run every migration over
// already-migrated data, risking double-transforms. Storing the version alongside the
// data keeps the two in lockstep wherever the data goes.
//
// Usage from the store's load():
//   inventoryItems = DBMigrations.migrateInventory(loadedItems)
// The migrate* functions read the stored version, apply only the steps newer than it,
// and write back the current version.

import Foundation

enum DBSchema {
    /// Bump when you add a migration step for a collection.
    static let inventoryVersion = 1
    static let groceryVersion   = 1
    static let recipeVersion    = 1
    static let pastMealVersion  = 1

    private static let ud = UserDefaults.standard
    private static func versionKey(_ collection: String) -> String { "schemaVersion_\(collection)" }
    private static func storeKey(_ collection: String) -> String { "schemaVersion_\(collection)" }

    // #7 Pre-migration backup: before a destructive migration runs, snapshot the current data to
    // its own on-disk key so a bad migration can be undone. Keeps the single most recent snapshot
    // per collection (migrations are rare and one-way). restore* reads it back.
    static func snapshotBeforeMigration<T: Codable>(_ collection: String, _ data: [T]) {
        LocalDatabase.shared.save(data, key: "premigration_backup_\(collection)")
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "premigration_backup_at_\(collection)")
    }
    static func migrationBackupDate(_ collection: String) -> Date? {
        let t = UserDefaults.standard.double(forKey: "premigration_backup_at_\(collection)")
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }
    static func restoreMigrationBackup<T: Codable>(_ collection: String, as type: T.Type) -> [T]? {
        LocalDatabase.shared.loadArray(T.self, key: "premigration_backup_\(collection)")
    }

    /// Reads the stored version, preferring the durable on-disk value (survives restore),
    /// then falling back to the UserDefaults mirror. Whichever is HIGHER wins, so a restore
    /// of already-migrated data files is never re-migrated even if the UD mirror is stale/empty.
    static func storedVersion(_ collection: String) -> Int {
        let udValue   = ud.integer(forKey: versionKey(collection))
        let diskValue = LocalDatabase.shared.load(Int.self, key: storeKey(collection)) ?? 0
        let effective = max(udValue, diskValue)
        // Heal a stale/empty mirror so subsequent reads are fast and consistent.
        if udValue != effective { ud.set(effective, forKey: versionKey(collection)) }
        if diskValue != effective { LocalDatabase.shared.save(effective, key: storeKey(collection)) }
        return effective
    }

    /// Writes the version to BOTH the durable store and the fast mirror.
    static func setVersion(_ v: Int, _ collection: String) {
        ud.set(v, forKey: versionKey(collection))
        LocalDatabase.shared.save(v, key: storeKey(collection))
    }
}

enum DBMigrations {
    /// Inventory migrations. v1: route the removed "Drinks" zone to Fridge.
    static func migrateInventory(_ items: [LocalInventoryItem]) -> [LocalInventoryItem] {
        let from = DBSchema.storedVersion("inventory")
        guard from < DBSchema.inventoryVersion else { return items }   // already current → no work
        DBSchema.snapshotBeforeMigration("inventory", items)          // #7 one-tap-restore backup

        var result = items
        // Step → v1
        if from < 1 {
            result = result.map { item in
                guard item.storageCategory.rawValue == "Drinks" else { return item }
                var migrated = item
                migrated.storageCategory = .fridge
                return migrated
            }
        }
        // (future steps: if from < 2 { … })

        DBSchema.setVersion(DBSchema.inventoryVersion, "inventory")
        return result
    }

    /// Grocery migrations. v1: no transform yet — just stamps the version so future steps
    /// have a baseline. Kept symmetric with inventory for consistency.
    static func migrateGrocery(_ items: [LocalGroceryItem]) -> [LocalGroceryItem] {
        let from = DBSchema.storedVersion("grocery")
        guard from < DBSchema.groceryVersion else { return items }
        DBSchema.setVersion(DBSchema.groceryVersion, "grocery")
        return items
    }

    /// Recipe migrations. v1: baseline stamp (#8 coverage extension). Add transforms as
    /// `if from < N { … }` steps when UserRecipe's shape changes.
    static func migrateRecipes(_ items: [UserRecipe]) -> [UserRecipe] {
        let imageComplete = items.filter { recipe in
            guard recipe.sourceURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return true
            }
            if let data = recipe.imageData, !data.isEmpty { return true }
            guard let raw = recipe.imageURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let url = URL(string: raw) else { return false }
            return url.scheme == "https" && url.host != nil
        }
        let from = DBSchema.storedVersion("recipes")
        guard from < DBSchema.recipeVersion else { return imageComplete }
        DBSchema.setVersion(DBSchema.recipeVersion, "recipes")
        return imageComplete
    }

    /// Past-meal migrations. v1: baseline stamp (#8 coverage extension).
    static func migratePastMeals(_ items: [LocalPastMeal]) -> [LocalPastMeal] {
        let from = DBSchema.storedVersion("pastMeals")
        guard from < DBSchema.pastMealVersion else { return items }
        DBSchema.setVersion(DBSchema.pastMealVersion, "pastMeals")
        return items
    }
}
