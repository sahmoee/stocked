// FeatureStore.swift — Improvement #6: one persistence layer for feature data.
//
// Eight feature stores were each hand-rolling the same twelve lines: encode the whole array to
// JSON on every mutation and push it into UserDefaults. That's the wrong home for a growing
// collection — UserDefaults is loaded wholesale at launch, flushed on its own schedule, and has no
// migration story. Worse, every keystroke-level mutation re-encoded the entire array synchronously
// on the main thread.
//
// This routes all of them through `LocalDatabase` (atomic file writes on a background queue, with
// a UserDefaults mirror only for small payloads) and coalesces writes through the same 250 ms
// debouncer `GuestDataStore` already uses. It migrates existing UserDefaults data on first load,
// so nobody loses anything.
//
// `GuestDataStore`'s own `saveDebounced`/`loadDecodedArray` are private to that file; this is the
// same idea made reusable rather than a competing mechanism.

import Foundation

// MARK: - Store

@MainActor
final class FeatureStore<Element: Codable & Sendable> {

    /// Storage key. Also the LocalDatabase filename and the legacy UserDefaults key we migrate from.
    let key: String
    private let scheduler = StorePersistenceScheduler()
    private var didMigrate = false

    init(key: String) { self.key = key }

    // MARK: Load

    /// Reads from LocalDatabase, falling back once to the legacy UserDefaults blob and migrating it.
    func load() -> [Element] {
        if let rows = LocalDatabase.shared.loadArray(Element.self, key: key), !rows.isEmpty {
            return rows
        }
        // One-time migration from the old per-feature UserDefaults key.
        if !didMigrate, let data = UserDefaults.standard.data(forKey: key) {
            didMigrate = true
            if let decoded = try? JSONDecoder().decode([Element].self, from: data) {
                LocalDatabase.shared.save(decoded, key: key)
                // Leave the old key in place for one release — if a user downgrades, their data
                // is still there. It costs a few KB and removes the only irreversible step.
                return decoded
            }
        }
        return []
    }

    // MARK: Save

    /// Coalesced write. Repeated mutations inside 250 ms collapse into a single encode + file write.
    func save(_ rows: [Element]) {
        scheduler.schedule(key: key) {
            LocalDatabase.shared.save(rows, key: self.key)
        }
    }

    /// Force any pending write out now — call before backgrounding or on sign-out.
    func flush() { scheduler.flush() }

    func clear() {
        scheduler.cancel()
        LocalDatabase.shared.delete(key: key)
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Registry

/// Every feature-owned collection, in one place. Previously these keys were string literals
/// scattered across eight files, which is how `ocrDict_v1` ended up declared in Constants.swift
/// and then hardcoded again at its only two call sites.
///
/// `nonisolated` because App Intents (#17) read these files off the main actor while the app is
/// closed. They're immutable string constants, so there is nothing to isolate.
nonisolated enum FeatureStoreKeys {
    static let leftovers       = "leftovers_v1"
    static let familyProfiles  = "familyProfiles_v1"
    static let events          = "kitchenEvents_v1"
    static let sharedExpenses  = "sharedExpenses_v1"
    static let storeLayouts    = "storeLayouts_v1"
    static let takeoutLog      = "takeoutLog_v1"
    static let gardenHarvests  = "gardenHarvests_v1"
    static let containerLabels = "containerLabels_v1"
    static let toolboxUsage    = "toolboxUsage_v1"
    static let syncConflicts   = "syncConflictLog_v1"
    static let notifyEngagement = "notifyEngagement_v1"
    static let householdCookPresence = "householdCookPresence_v1"

    static let all: [String] = [
        leftovers, familyProfiles, events, sharedExpenses, storeLayouts,
        takeoutLog, gardenHarvests, containerLabels, toolboxUsage,
        syncConflicts, notifyEngagement, householdCookPresence,
    ]

    /// Total bytes on disk across all feature stores — surfaced in the health view.
    nonisolated static func diskBytes() -> Int64 {
        let dir = URL.documentsDirectory.appendingPathComponent("StockedDB")
        var total: Int64 = 0
        for k in all {
            let url = dir.appendingPathComponent("\(k).json")
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }
}

// MARK: - Lifecycle

/// One place to flush every feature store before the app loses foreground, mirroring what
/// `GuestDataStore.flushPendingSaves()` does for the main data layer. Without this, a debounced
/// write in flight when the user swipes away is lost.
@MainActor
enum StockedFeatureStores {
    static func flushAll() {
        LeftoversStore.shared.flush()
        FamilyProfileStore.shared.flush()
        EventStore.shared.flush()
        SplitStore.shared.flush()
        StoreLayoutStore.shared.flush()
        TakeoutStore.shared.flush()
        HarvestStore.shared.flush()
        ContainerLabelStore.shared.flush()
        ToolboxUsageStore.shared.flush()
        NotificationEngagement.shared.flush()
        SyncConflictLog.shared.flush()
        HouseholdCookStore.shared.flush()
    }
}
