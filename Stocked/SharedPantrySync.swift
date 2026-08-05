// SharedPantrySync.swift
// ─────────────────────────────────────────────────────────────────────
// Lightweight shared pantry via NSUbiquitousKeyValueStore (iCloud KV).
// Two users on the same iCloud account see the same inventory in real time.
// Does NOT require CloudKit entitlements — uses the simpler KV store.
//
// SETUP (one-time in Xcode):
// Target → Signing & Capabilities → + Capability → iCloud
// Check "Key-value storage". That's it.
//
// HOW IT WORKS:
// - On every inventory/grocery change, the local GuestDataStore serialises
//   and pushes to NSUbiquitousKeyValueStore.
// - NSUbiquitousKeyValueStore.default.synchronize() flushes within ~30s.
// - On another device with the same iCloud account, the notification fires
//   and the local store merges the remote snapshot.
// - Conflict resolution: last-write-wins per item (by update timestamp).
// ─────────────────────────────────────────────────────────────────────
import Foundation
import Observation

@Observable
@MainActor
final class SharedPantrySync {

    static let shared = SharedPantrySync()
    private init() {
        // Restore the last-synced timestamp across launches for display.
        let t = UserDefaults.standard.double(forKey: "lastHouseholdSyncAt")
        if t > 0 { lastSyncedAt = Date(timeIntervalSince1970: t) }
    }

    // Observable status for the UI.
    private(set) var isSyncing: Bool = false
    private(set) var lastSyncedAt: Date? = nil

    // Re-entrancy guard (CRITICAL): while pull() applies remote data it mutates the store's
    // inventoryItems/groceryItems, whose didSet calls push() — which writes to the KV store,
    // which fires didChangeExternallyNotification, which calls pull() again… an infinite
    // loop that allocated unbounded memory (7GB+) until the OS killed the app. When this flag
    // is set, push() is suppressed so a pull-driven mutation can't echo back out.
    @ObservationIgnored private var isApplyingRemote = false

    @ObservationIgnored private let kv = NSUbiquitousKeyValueStore.default
    @ObservationIgnored private let enabledKey = "sharedPantryEnabled"
    @ObservationIgnored private let codeKey    = "householdCode_v1"

    var isEnabled: Bool {
        get { kv.bool(forKey: enabledKey) }
        set { kv.set(newValue, forKey: enabledKey); kv.synchronize() }
    }

    /// Whether the CURRENT account is allowed to use shared-pantry sync. Guests are not, so
    /// their data never goes to or comes from iCloud. AppSession sets this from accountType on
    /// launch and on any login/logout. Defaults to false so a guest can never sync before it is
    /// explicitly enabled for a registered account.
    @ObservationIgnored var accountAllowsSync = false

    /// Current household code (empty = not in a household). Data is keyed by this so two
    /// different households on the same iCloud account don't clobber each other.
    var householdCode: String { kv.string(forKey: codeKey) ?? "" }

    private func inventoryKey(_ code: String) -> String { "sharedInventory_\(code)" }
    private func groceryKey(_ code: String)   -> String { "sharedGrocery_\(code)" }

    private func markSynced() {
        lastSyncedAt = Date()
        UserDefaults.standard.set(lastSyncedAt!.timeIntervalSince1970, forKey: "lastHouseholdSyncAt")
    }

    /// Manually push + pull immediately (the "Sync now" button). Shows the syncing state
    /// briefly so the user gets feedback even though KV propagation is eventual.
    func syncNow(store: GuestDataStore) {
        guard isEnabled, !householdCode.isEmpty else { return }
        isSyncing = true
        kv.synchronize()
        pull(into: store)
        push(store: store)
        kv.synchronize()
        markSynced()
        // Keep the indicator visible briefly so the tap registers visually.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            isSyncing = false
        }
    }

    // MARK: - Join / leave a household

    /// Join (or create) a household: store the code, enable sync, immediately pull any
    /// existing shared data into the local store, then push local data up so both sides
    /// converge. This is what makes "join with code" actually sync.
    func join(code: String, store: GuestDataStore) {
        kv.set(code, forKey: codeKey)
        isEnabled = true
        kv.synchronize()
        // Pull first so we adopt whatever the household already has, then contribute ours.
        pull(into: store)
        push(store: store)
        kv.synchronize()
        markSynced()
    }

    func leave() {
        isEnabled = false
        kv.removeObject(forKey: codeKey)
        kv.synchronize()
    }

    // MARK: - Push local state to iCloud (scoped to the household code)

    func push(store: GuestDataStore) {
        // Don't echo a pull-driven mutation back out to the KV store (breaks the loop).
        guard !isApplyingRemote else { return }
        let code = householdCode
        guard accountAllowsSync, isEnabled, !code.isEmpty else { return }
        if let data = try? JSONEncoder().encode(store.inventoryItems) {
            kv.set(data, forKey: inventoryKey(code))
        }
        if let data = try? JSONEncoder().encode(store.groceryItems) {
            kv.set(data, forKey: groceryKey(code))
        }
        kv.synchronize()
    }

    // MARK: - Pull remote state and merge

    func pull(into store: GuestDataStore) {
        let code = householdCode
        guard accountAllowsSync, isEnabled, !code.isEmpty else { return }
        // Suppress push() for the duration of the merge so applying remote data can't
        // echo back out to the KV store and re-trigger this pull (the 7GB loop).
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        if let data  = kv.data(forKey: inventoryKey(code)),
           let remote = try? JSONDecoder().decode([LocalInventoryItem].self, from: data) {
            mergeInventory(remote: remote, into: store)
        }
        if let data  = kv.data(forKey: groceryKey(code)),
           let remote = try? JSONDecoder().decode([LocalGroceryItem].self, from: data) {
            mergeGrocery(remote: remote, into: store)
        }
        markSynced()
    }

    // MARK: - Observe iCloud changes (call once on app launch)

    func startObserving(store: GuestDataStore) {
        // Guests never sync: don't observe iCloud changes or adopt remote data.
        guard accountAllowsSync else { return }
        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kv, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.pull(into: store)
            }
        }
        kv.synchronize()
        // Adopt any existing shared data on launch if we're already in a household.
        pull(into: store)
    }

    // MARK: - Merge helpers (last-write-wins by id)

    // TOMBSTONE-AWARE (July 2026) — this is the "swipe to delete one grocery item
    // and every item comes back" bug.
    //
    // The merge was remote-wins over a union of ids, and it had no idea which ids
    // had just been deleted. Deleting an item pushes a new snapshot; iCloud echoes
    // that push back through `didChangeExternallyNotification`; the echo (or a
    // slightly older snapshot from another device) still contained the deleted rows,
    // and remote-wins faithfully restored them. With a whole list added at once —
    // "add missing ingredients" — the pre-delete snapshot is the one in flight, so
    // deleting one row resurrected all of them.
    //
    // The store already keeps `pendingGroTombstones` / `pendingInvTombstones` for
    // exactly this. Honouring them here means a deleted id can never be re-added by
    // an incoming snapshot, no matter how stale that snapshot is.

    private func mergeInventory(remote: [LocalInventoryItem], into store: GuestDataStore) {
        let tombstones = store.pendingInvTombstones
        var byID = Dictionary(keepingLastValues: store.inventoryItems.map { ($0.id, $0) })
        for item in remote where !tombstones.contains(item.id.uuidString) {
            byID[item.id] = item   // remote wins on conflict, but never resurrects
        }
        let merged = Array(byID.values)
            .filter { !tombstones.contains($0.id.uuidString) }
            .sorted { $0.name < $1.name }
        // Avoid a no-op assignment that would re-trigger didSet → push loops.
        if merged != store.inventoryItems { store.inventoryItems = merged }
    }

    private func mergeGrocery(remote: [LocalGroceryItem], into store: GuestDataStore) {
        let tombstones = store.pendingGroTombstones
        var byID = Dictionary(keepingLastValues: store.groceryItems.map { ($0.id, $0) })
        for item in remote where !tombstones.contains(item.id.uuidString) {
            byID[item.id] = item
        }
        let merged = Array(byID.values).filter { !tombstones.contains($0.id.uuidString) }
        if merged != store.groceryItems { store.groceryItems = merged }
    }
}
