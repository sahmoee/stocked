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
private enum DBFile {
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
private struct PreEncoded { let data: Data }

// MARK: - LocalDatabase
final class LocalDatabase {
    static let shared = LocalDatabase()
    private init() {}

    // #13: Single coalescing write queue — prevents N simultaneous disk writes
    private let queue         = DispatchQueue(label: "com.stocked.db", qos: .utility)
    private var pendingWrites: [String: Any]        = [:]
    private var writeWorkItem: DispatchWorkItem?    = nil

    // MARK: Read
    func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
        let url = DBFile.url(for: key)
        if let data = try? Data(contentsOf: url),
           let decoded = try? JSONDecoder().decode(type, from: data) {
            return decoded
        }
        // Primary file missing or corrupt — try the one-generation backup (#7).
        let bak = DBFile.backupURL(for: key)
        if let data = try? Data(contentsOf: bak),
           let decoded = try? JSONDecoder().decode(type, from: data) {
            Log.data.error("Primary store for \(key, privacy: .public) failed to decode; recovered from backup.")
            return decoded
        }
        return nil
    }

    /// Corruption-tolerant array read (#6/#7): decodes each element independently and falls
    /// back to the backup file if the primary is unreadable. One bad row costs one row.
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

    // MARK: Write — single coalescing flush #13
    // All pending writes are batched into one disk pass every 0.15s.
    // Prevents N simultaneous JSONEncoder + disk-write calls on bulk inventory changes.
    func save<T: Encodable>(_ value: T, key: String) {
        pendingWrites[key] = value
        scheduleFlush()
    }

    // Batch a value that is ALREADY encoded — avoids re-encoding in the flush (#2).
    // Stored under a distinct wrapper so the flush writes the raw Data directly.
    func saveData(_ data: Data, key: String) {
        pendingWrites[key] = PreEncoded(data: data)
        scheduleFlush()
    }

    private func scheduleFlush() {
        writeWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.pendingWrites
            self.pendingWrites.removeAll()
            for (k, v) in snapshot {
                let url = DBFile.url(for: k)
                // Keep a one-generation backup: copy the current good file aside before we
                // overwrite it, so a crash mid-write (or a future corrupt write) can recover (#7).
                if let existing = try? Data(contentsOf: url), !existing.isEmpty {
                    do { try existing.write(to: DBFile.backupURL(for: k), options: .atomic) }
                    catch { Log.data.error("Backup write failed for key \(k, privacy: .public): \(error.localizedDescription, privacy: .public)") }
                }
                do {
                    if let pre = v as? PreEncoded {
                        try pre.data.write(to: url, options: .atomic)
                    } else if let enc = v as? (any Encodable) {
                        let data = try JSONEncoder().encode(enc)
                        try data.write(to: url, options: .atomic)
                    }
                } catch {
                    Log.data.error("Disk write failed for key \(k, privacy: .public): \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        writeWorkItem = item
        queue.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    // MARK: Delete
    func delete(key: String) {
        pendingWrites.removeValue(forKey: key)
        queue.async {
            try? FileManager.default.removeItem(at: DBFile.url(for: key))
        }
    }

    // MARK: Nuke everything (sign-out with clear data)
    func deleteAll() {
        pendingWrites.removeAll()
        writeWorkItem?.cancel()
        queue.async {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: DBFile.dir, includingPropertiesForKeys: nil)) ?? []
            files.forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }
}

// MARK: - DBKey — compile-time safe storage keys #14
// Use DBKey.inventoryItems.rawValue everywhere — typos are compile errors, not silent data loss.
enum DBKey: String, CaseIterable {
    case inventoryItems        = "inventory_items"
    case groceryItems          = "grocery_items"
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
extension LocalDatabase {
    // Cache any Codable value with a string key (e.g. URL string, query string)
    func cacheData<T: Encodable>(_ value: T, forKey cacheKey: String) {
        // Use a sanitised filename derived from the key
        let safeKey = cacheKey
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "cache_\(abs(cacheKey.hashValue))"
        save(value, key: "cache_\(safeKey)")
    }

    func cachedData<T: Decodable>(_ type: T.Type, forKey cacheKey: String) -> T? {
        let safeKey = cacheKey
            .addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "cache_\(abs(cacheKey.hashValue))"
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

    // Total data cache size (excluding images — those are in ImageCache)
    var dataCacheSizeString: String {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: DBFile.dir, includingPropertiesForKeys: [.fileSizeKey]) else { return "0 KB" }
        let bytes = files.reduce(0) { acc, url in
            (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize.map { acc + $0 } ?? acc
        }
        let mb = Double(bytes) / 1_048_576
        return mb < 1 ? "\(bytes / 1024) KB" : String(format: "%.1f MB", mb)
    }

    // Clear all data cache (NOT user data — only fetched/generated content)
    func clearDataCache() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: DBFile.dir, includingPropertiesForKeys: nil) else { return }
        files.filter { $0.lastPathComponent.hasPrefix("cache_") || $0.lastPathComponent == "learnedRecipes.json" }
             .forEach { try? FileManager.default.removeItem(at: $0) }
    }
}
