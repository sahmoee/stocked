// LocalDatabase.swift
// On-device persistence using a per-key JSON file store in the app's Documents directory,
// with a UserDefaults layer for lightweight key-value settings and same-session mirroring.
// When signed in with Apple, iCloud sync is wired in Anchor 6 (CloudKit).
//
// Architecture:
//   LocalDatabase (singleton) → typed per-key JSON files (+ one-generation .bak each)
//   GuestDataStore reads/writes through LocalDatabase (debounced/batched at the model layer)
//   Reads are corruption-tolerant (loadArray skips bad elements; falls back to .bak)
//
// NOTE on scaling (#7): this is a whole-value store — changing one element rewrites that
// key's entire file. That's fine for the current data sizes and keeps the format trivially
// inspectable/portable. If a growth-prone collection (e.g. priceHistory, consumptionLog)
// ever gets large enough that full-file rewrites cost noticeably, the migration path is to
// move ONLY those collections to SQLite (e.g. GRDB) for incremental row writes + indexed
// queries, leaving the small settings on this store. Logs are retention-pruned (see
// GuestDataStore.pruneRetainedData) so they stay bounded in the meantime.
//
// Performance:
//   - Reads are instant (UserDefaults mirror, else disk)
//   - Writes are coalesced at the model layer (debounced) AND here (0.15s batch)
//   - File I/O runs on a background queue — never blocks the main thread
import Foundation
import Combine
import os

// MARK: - File paths
nonisolated private enum DBFile {
    static let dir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let db   = docs.appendingPathComponent("StockedDB", isDirectory: true)
        try? FileManager.default.createDirectory(at: db, withIntermediateDirectories: true)
        return db
    }()

    static func url(for key: String) -> URL {
        dir.appendingPathComponent("\(key).json")
    }
    /// One-generation backup file, written just before the primary is overwritten (#7).
    static func backupURL(for key: String) -> URL {
        dir.appendingPathComponent("\(key).bak.json")
    }
}

// Wrapper marking a pending write as already-encoded Data (skips re-encode in flush).
nonisolated private struct PreEncoded: Sendable { let data: Data }

// MARK: - LocalDatabase
/// Thread-safe file persistence usable from actors and the default main actor. The class is
/// explicitly nonisolated; its only mutable state is protected by `stateLock`, and disk writes
/// are serialized on `queue`. This keeps large cache encode/decode work off the UI actor without
/// weakening Swift 6 checking at call sites.
nonisolated final class LocalDatabase: @unchecked Sendable {
    static let shared = LocalDatabase()

    private let queue = DispatchQueue(label: "com.stocked.db", qos: .utility)
    private let queueIdentity = DispatchSpecificKey<UInt8>()
    private let stateLock = NSLock()
    private var pendingWrites: [String: Any] = [:]
    private var writeWorkItem: DispatchWorkItem?
    private var writeGeneration: UInt64 = 0

    private init() { queue.setSpecific(key: queueIdentity, value: 1) }

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private func syncOnWriteQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueIdentity) == 1 { body() }
        else { queue.sync(execute: body) }
    }

    // MARK: Read
    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let url = DBFile.url(for: key)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(type, from: data) {
            return decoded
        }
        let bak = DBFile.backupURL(for: key)
        if let data = try? Data(contentsOf: bak),
           let decoded = try? JSONDecoder().decode(type, from: data) {
            Log.data.error("Primary store for \(key, privacy: .public) failed to decode; recovered from backup.")
            return decoded
        }
        return nil
    }

    /// Corruption-tolerant array read: one malformed row does not discard the collection.
    func loadArray<Element: Decodable>(_ type: Element.Type, key: String) -> [Element]? {
        let url = DBFile.url(for: key)
        if let data = try? Data(contentsOf: url), let arr = SafeDecode.array(Element.self, from: data) {
            return arr
        }
        let bak = DBFile.backupURL(for: key)
        if let data = try? Data(contentsOf: bak), let arr = SafeDecode.array(Element.self, from: data) {
            Log.data.error("Primary store for \(key, privacy: .public) unreadable; recovered array from backup.")
            return arr
        }
        return nil
    }

    // MARK: Write — one coalescing, serialized file queue
    func save<T: Encodable>(_ value: T, key: String) {
        withStateLock {
            pendingWrites[key] = value
            scheduleFlushLocked()
        }
    }

    func saveData(_ data: Data, key: String) {
        withStateLock {
            pendingWrites[key] = PreEncoded(data: data)
            scheduleFlushLocked()
        }
    }

    /// Must be called while `stateLock` is held.
    private func scheduleFlushLocked() {
        writeWorkItem?.cancel()
        writeGeneration &+= 1
        let generation = writeGeneration
        let item = DispatchWorkItem { [weak self] in self?.flushPendingWrites(generation: generation) }
        writeWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func flushPendingWrites(generation: UInt64) {
        let snapshot: [String: Any]? = withStateLock {
            guard generation == writeGeneration else { return nil }
            let snapshot = pendingWrites
            pendingWrites.removeAll()
            writeWorkItem = nil
            return snapshot
        }
        guard let snapshot, !snapshot.isEmpty else { return }
        for (key, value) in snapshot { write(value, key: key) }
    }

    private func write(_ value: Any, key: String) {
        let url = DBFile.url(for: key)
        if let existing = try? Data(contentsOf: url), !existing.isEmpty {
            do { try existing.write(to: DBFile.backupURL(for: key), options: .atomic) }
            catch { Log.data.error("Backup write failed for key \(key, privacy: .public): \(error.localizedDescription, privacy: .public)") }
        }
        do {
            if let pre = value as? PreEncoded {
                try pre.data.write(to: url, options: .atomic)
            } else if let encodable = value as? any Encodable {
                let data = try JSONEncoder().encode(encodable)
                try data.write(to: url, options: .atomic)
            }
        } catch {
            Log.data.error("Disk write failed for key \(key, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Delete
    func delete(key: String) {
        _ = withStateLock { pendingWrites.removeValue(forKey: key) }
        queue.async {
            try? FileManager.default.removeItem(at: DBFile.url(for: key))
            try? FileManager.default.removeItem(at: DBFile.backupURL(for: key))
        }
    }

    func deleteAll() {
        withStateLock {
            pendingWrites.removeAll()
            writeGeneration &+= 1
            writeWorkItem?.cancel()
            writeWorkItem = nil
        }
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: DBFile.dir, includingPropertiesForKeys: nil)) ?? []
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }
}

// MARK: - DBKey — compile-time safe storage keys #14
// Use DBKey.inventoryItems.rawValue everywhere — typos are compile errors, not silent data loss.
nonisolated enum DBKey: String, CaseIterable, Sendable {
    case inventoryItems        = "inventory_items"
    case groceryItems          = "grocery_items"
    case householdOpQueue      = "household_op_queue_v1"    // durable pending household operations
    case householdSyncStatus   = "household_sync_status_v1" // last push/pull, pending count, last error
    case householdTombstones   = "household_tombstones_v1"  // durable offline deletions
    case pastMeals             = "past_meals"
    case plannedMeals          = "planned_meals"
    case savedRecipes          = "saved_recipes"
    case savedGeneratedRecipes = "saved_generated_recipes"
    case userRecipes           = "user_recipes_v1"
    case displayName           = "display_name"
    case groceryDayOfWeek      = "grocery_day"
    case preferredCuisines     = "preferred_cuisines"
    case cookingGoal           = "cooking_goal"
    case preferredStore        = "preferred_store"
    case cookingProfile        = "cooking_profile_v1"
    case knowledgeBase         = "kb_ingredients_v2"      // #19: file-backed KB
    case webRecipeCache        = "web_recipe_cache_v1"
    case darkMode              = "darkMode"
    case cookButtonShape       = "cookButtonShape"
    case cookButtonSize        = "cookButtonSize"
    case menuTabHeight         = "menuTabHeight"
    case menuTabWidth          = "menuTabWidth"
    case menuFontOffset        = "menuFontOffset"
    case menuFontSize          = "menuFontSize"
    case fontVerticalOffset    = "fontVerticalOffset"
    case fontHorizontalOffset  = "fontHorizontalOffset"
    case appBackground         = "appBackground"
    case appleUserID           = "appleUserID"
    case appleFirstName        = "appleFirstName"   // persisted given name; Apple only sends fullName on first auth
    case autoAddMissing        = "autoAddMissingToGrocery"
    case notifications         = "notificationsEnabled"
    case homeLayout            = "homeLayout"
    case boltPosition          = "boltPosition"
    case hapticIntensity       = "hapticIntensity"
    case preferredRecipeTab    = "preferredRecipeTab"
    case backupFrequency       = "backupFrequency"
    case householdCode         = "householdCode"
    case cookStreak            = "cookStreak"
    case longestStreak         = "longestStreak"
    case lastCookDate          = "lastCookDate"
    case consumptionLog        = "consumption_log_v1"   // close-the-loop #1: depletion history
    case appTheme              = "appTheme"
    case appFont               = "appFont"
    case unitSystem            = "unitSystem"
    // Accent RGB
    case accentR = "accentR"; case accentG = "accentG"; case accentB = "accentB"
    // Background RGB
    case bgR     = "bgR";     case bgG     = "bgG";     case bgB     = "bgB"
    // Button RGB
    case btnR    = "btnR";    case btnG    = "btnG";    case btnB    = "btnB"
    // Text RGB
    case txtR    = "txtR";    case txtG    = "txtG";    case txtB    = "txtB"
    // Card RGB
    case cardR   = "cardR";   case cardG   = "cardG";   case cardB   = "cardB"
    // Tab RGB
    case tabR    = "tabR";    case tabG    = "tabG";    case tabB    = "tabB"
    // Misc settings
    case wasGuest              = "wasGuest"
    case newMilestone          = "newMilestone"

    // Centralized previously-stray keys (exact existing string values — do NOT change the strings,
    // or stored data would be orphaned). Added so call sites can use DBKey instead of raw strings.
    case activeCookSession     = "activeCookSession"
    case recentlyViewedRecipes = "recentlyViewedRecipes"
    case onlineRecipesOpenCount = "onlineRecipesOpenCount"
    case onlineRecipesCache    = "onlineRecipesCache_v2"
    case onlineSyncEnabled     = "onlineSyncEnabled"
    case ratingWeights         = "ratingWeights_v1"
    case receiptArchive        = "receiptArchive_v1"
    case lastICloudBackup      = "lastICloudBackup"
    case invSort               = "stocked.invSort"
    case homeBriefCollapsed    = "stocked.homeBriefCollapsed"

    case priceHistory          = "price_history_v1"
}


// MARK: - AppDataCache
// General-purpose cache for any fetched data (recipe lookups, ingredient info, etc).
// Persists to disk — only cleared manually. Never expires automatically.
nonisolated extension LocalDatabase {
    // Cache any Codable value with a string key (e.g. URL string, query string)
    func cacheData<T: Encodable>(_ value: T, forKey cacheKey: String) {
        // Use a sanitised filename derived from the key
        let safeKey = cacheKey.stableCacheKey
        save(value, key: "cache_\(safeKey)")
    }

    func cachedData<T: Decodable>(_ type: T.Type, forKey cacheKey: String) -> T? {
        let safeKey = cacheKey.stableCacheKey
        return load(type, key: "cache_\(safeKey)")
    }

    // Cache a generated recipe so the app learns from it
    func cacheRecipe(_ recipe: GeneratedRecipe) {
        var cached = load([GeneratedRecipe].self, key: DBKey.savedGeneratedRecipes.rawValue) ?? []
        // Avoid duplicates
        if !cached.contains(where: { $0.title == recipe.title }) {
            cached.append(recipe)
            // Keep last 100 cached recipes
            if cached.count > 100 { cached = Array(cached.suffix(100)) }
            save(cached, key: "learnedRecipes")
        }
    }

    func learnedRecipes() -> [GeneratedRecipe] {
        load([GeneratedRecipe].self, key: "learnedRecipes") ?? []
    }

    private var cacheFileNames: Set<String> {
        [
            "learnedRecipes.json", "learnedRecipes.bak.json",
            "onlineRecipesCache_v2.json", "onlineRecipesCache_v2.bak.json",
            "onlineRecipesCache_v3.json", "onlineRecipesCache_v3.bak.json",
            "web_recipe_cache_v1.json", "web_recipe_cache_v1.bak.json",
            "offlineRecipeCache_v1.json", "offlineRecipeCache_v1.bak.json",
            "spoonacular_result_cache_v1.json", "spoonacular_result_cache_v1.bak.json"
        ]
    }

    private func isCacheFile(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("cache_") || cacheFileNames.contains(url.lastPathComponent)
    }

    // Total fetched-data cache size (excluding pantry/user records and image/API caches).
    var dataCacheSizeBytes: Int {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: DBFile.dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        return files.filter(isCacheFile).reduce(0) { total, url in
            total + ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }

    var dataCacheSizeString: String {
        ByteCountFormatter.string(fromByteCount: Int64(dataCacheSizeBytes), countStyle: .file)
    }

    // Clear fetched data only. Pantry, grocery, saved recipes, settings, and backups remain.
    func clearDataCache() {
        // Cancel the current coalesced flush so cache entries queued moments before the
        // clear action cannot immediately recreate deleted files. All state mutation stays
        // under the same lock used by save/delete; remaining user-data writes are rescheduled.
        withStateLock {
            writeGeneration &+= 1
            writeWorkItem?.cancel()
            writeWorkItem = nil
            pendingWrites = pendingWrites.filter { key, _ in
                let filename = "\(key).json"
                return !filename.hasPrefix("cache_") && !cacheFileNames.contains(filename)
            }
            if !pendingWrites.isEmpty { scheduleFlushLocked() }
        }

        // Wait behind any write already executing, then remove only recognized cache files.
        syncOnWriteQueue {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: DBFile.dir, includingPropertiesForKeys: nil) else { return }
            files.filter(isCacheFile).forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }

}


nonisolated private extension String {
    var stableCacheKey: String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
