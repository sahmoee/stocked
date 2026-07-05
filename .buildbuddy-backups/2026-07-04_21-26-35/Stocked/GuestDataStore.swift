// GuestDataStore.swift — extracted from AppSession.swift (#8/#9 split).
// The @Observable @MainActor data store (inventory, grocery, recipes, persistence, sync).
import SwiftUI
import Combine
import os
@preconcurrency import UserNotifications

// MARK: - GuestDataStore
@Observable
@MainActor
class GuestDataStore {
    private let ud = UserDefaults.standard

    @ObservationIgnored private var isSyncingLowStock = false   // re-entrancy guard (#1) — internal, not observed
    @ObservationIgnored private var widgetRefreshWork: DispatchWorkItem?   // #19 — debounce widget reloads

    /// #19 — Coalesce rapid mutations into a single widget reload ~0.5s after the last change,
    /// so a burst of edits (e.g. applying a scanned receipt) reloads widgets once, not N times.
    private func refreshWidgetsDebounced() {
        widgetRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            WidgetBridge.refresh(store: self)
        }
        widgetRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    // Debounced push to the shared HOUSEHOLD (worker-backed, cross-user). Separate from
    // SharedPantrySync (iCloud KV, same Apple ID only, gated off for guests). Without this, a
    // member adding an item never propagated to the household — it just sat locally. Debounced so
    // a burst of edits results in one push after it settles; only pushes when in a household.
    private var householdPushWork: DispatchWorkItem? = nil
    // Set true while HouseholdSync.applyHousehold writes remote data into the store, so the
    // resulting didSets don't echo back out as another push (an infinite sync loop).
    var isApplyingHouseholdRemote = false
    // True only during the in-place updatedAt stamping below, so the re-entrant didSet it causes
    // returns immediately instead of doing all the save/push work a second time.
    private var isStamping = false
    private func pushHouseholdDebounced() {
        guard !isApplyingHouseholdRemote else { return }
        householdPushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let hh = HouseholdSync.shared
            guard hh.state == .owner || hh.state == .member else { return }
            Task { await hh.syncNow(store: self) }
        }
        householdPushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // Deletion tombstones for household sync: ids removed locally, sent on the next push so the
    // delete propagates to other devices. Kept small; cleared as the server confirms. Not synced
    // via UserDefaults on purpose — they only need to survive until the next push.
    var pendingInvTombstones: Set<String> = []
    var pendingGroTombstones: Set<String> = []
    var pendingUserRecipeTombstones: Set<String> = []
    var pendingGenRecipeTombstones: Set<String> = []

    var inventoryItems: [LocalInventoryItem] = [] {
        didSet {
            if isStamping { return }   // re-entrant pass from stampChanged: nothing more to do
            // Stamp updatedAt on locally-changed items (skip while applying remote data, which
            // already carries authoritative timestamps). Record tombstones for removed ids.
            if !isApplyingHouseholdRemote {
                isStamping = true
                let changedIDs = stampChanged(&inventoryItems, against: oldValue)
                isStamping = false
                let oldIDs = Set(oldValue.map(\.id))
                let goneIDs = oldIDs.subtracting(inventoryItems.map(\.id))
                for id in goneIDs { pendingInvTombstones.insert(id.uuidString) }
                // Durable queue (sync plan Drop 1): record each mutation so offline edits
                // survive relaunch and retry until a push is confirmed. Batched: one persist.
                var ops: [(id: UUID, type: HouseholdEntityType, op: HouseholdOperationType)] = []
                for id in changedIDs { ops.append((id, .inventoryItem, oldIDs.contains(id) ? .update : .create)) }
                for id in goneIDs { ops.append((id, .inventoryItem, .delete)) }
                HouseholdSync.shared.enqueueBatch(ops)
            }
            saveDebounced(DBKey.inventoryItems.rawValue, inventoryItems)
            _pantrySet = nil
            _inventoryPositions = nil
            if !isSyncingLowStock && lowStockSignature(inventoryItems) != lowStockSignature(oldValue) {
                isSyncingLowStock = true
                syncLowStockToGrocery()
                isSyncingLowStock = false
            }
            SharedPantrySync.shared.push(store: self)
            pushHouseholdDebounced()    // propagate to shared household (worker-backed)
            refreshWidgetsDebounced()   // #19 — keep home/lock-screen widgets fresh on any change
        }
    }

    // Bump updatedAt (ms) on any item whose content changed vs the previous value, so
    // household last-write-wins can tell whose edit is newer. Compares by id; a brand-new item
    // (no prior) is stamped too. Mutates in place; called only for local edits.
    @discardableResult
    private func stampChanged(_ items: inout [LocalInventoryItem], against old: [LocalInventoryItem]) -> [UUID] {
        let now = Date().timeIntervalSince1970 * 1000
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        var changed: [UUID] = []
        for i in items.indices {
            if let prev = oldByID[items[i].id] {
                // Compare ignoring updatedAt itself so a re-stamp doesn't loop.
                var a = items[i]; a.updatedAt = 0
                var b = prev;      b.updatedAt = 0
                if a != b { items[i].updatedAt = now; changed.append(items[i].id) }
            } else {
                items[i].updatedAt = now   // new item
                changed.append(items[i].id)
            }
        }
        return changed
    }
    @discardableResult
    private func stampChanged(_ items: inout [LocalGroceryItem], against old: [LocalGroceryItem]) -> [UUID] {
        let now = Date().timeIntervalSince1970 * 1000
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        var changed: [UUID] = []
        for i in items.indices {
            if let prev = oldByID[items[i].id] {
                var a = items[i]; a.updatedAt = 0
                var b = prev;      b.updatedAt = 0
                if a != b { items[i].updatedAt = now; changed.append(items[i].id) }
            } else {
                items[i].updatedAt = now
                changed.append(items[i].id)
            }
        }
        return changed
    }

    // Recipe stamping. UserRecipe/GeneratedRecipe aren't Equatable, so we detect a real change
    // by encoding each (with updatedAt zeroed) and comparing the bytes. imageData is part of the
    // struct but is NOT sent to the household (see HouseholdSync recipe dicts); a local-only
    // image change still stamps, which is harmless.
    private func stampChanged(_ items: inout [UserRecipe], against old: [UserRecipe]) -> [UUID] {
        let now = Date().timeIntervalSince1970 * 1000
        let enc = JSONEncoder()
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        func bytes(_ r: UserRecipe) -> Data? { var x = r; x.updatedAt = 0; return try? enc.encode(x) }
        var changed: [UUID] = []
        for i in items.indices {
            if let prev = oldByID[items[i].id] {
                if bytes(items[i]) != bytes(prev) { items[i].updatedAt = now; changed.append(items[i].id) }
            } else {
                items[i].updatedAt = now
                changed.append(items[i].id)
            }
        }
        return changed
    }
    private func stampChanged(_ items: inout [GeneratedRecipe], against old: [GeneratedRecipe]) -> [UUID] {
        let now = Date().timeIntervalSince1970 * 1000
        let enc = JSONEncoder()
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        func bytes(_ r: GeneratedRecipe) -> Data? { var x = r; x.updatedAt = 0; return try? enc.encode(x) }
        var changed: [UUID] = []
        for i in items.indices {
            if let prev = oldByID[items[i].id] {
                if bytes(items[i]) != bytes(prev) { items[i].updatedAt = now; changed.append(items[i].id) }
            } else {
                items[i].updatedAt = now
                changed.append(items[i].id)
            }
        }
        return changed
    }
    // is in the low band. Changes only when stock state meaningfully changes.
    private func lowStockSignature(_ items: [LocalInventoryItem]) -> [String] {
        items.compactMap { item in
            let lvl = item.effectiveLevel
            return (lvl > 0 && lvl < 0.25) ? item.name.lowercased() : nil
        }.sorted()
    }

    // Pre-computed pantry set — rebuilt lazily on inventory change (#20).
    // @ObservationIgnored is REQUIRED: this cache is written inside the pantrySet getter
    // (a read), and AppSession/GuestDataStore is @Observable. Without this, writing the
    // cache during a view's body evaluation registers as a tracked mutation, so SwiftUI
    // schedules another body pass, which reads pantrySet again… an infinite render loop
    // that allocated unbounded memory (7GB+) on every screen that reads pantrySet. This
    // is the shared root cause behind the Home/Ready-to-Cook/Grocery crashes.
    @ObservationIgnored private var _pantrySet: Set<String>?
    var pantrySet: Set<String> {
        if let cached = _pantrySet { return cached }
        let built = IngredientMatcher.buildPantrySet(from: inventoryItems)
        _pantrySet = built
        return built
    }
    func refreshInventory() async {
        _pantrySet = nil
    }
    // #5 — O(1) by-id lookup cache for inventory, rebuilt lazily on change.
    // @ObservationIgnored REQUIRED — same reason as _pantrySet: inventoryIndex(of:) writes
    // this cache during a read, and a tracked write-on-read causes infinite SwiftUI renders.
    @ObservationIgnored private var _inventoryPositions: PositionIndex?
    /// Index of the inventory item with `id`, or nil. O(1) vs firstIndex's O(n).
    func inventoryIndex(of id: UUID) -> Int? {
        if _inventoryPositions == nil {
            _inventoryPositions = PositionIndex(inventoryItems.map(\.id))
        }
        // Validate the cached index still points at the right id (guards against a stale
        // cache after an external mutation that didn't reset it).
        if let i = _inventoryPositions?.index(of: id), inventoryItems.indices.contains(i),
           inventoryItems[i].id == id { return i }
        _inventoryPositions = PositionIndex(inventoryItems.map(\.id))
        return _inventoryPositions?.index(of: id)
    }
    var groceryItems:          [LocalGroceryItem]   = [] { didSet {
        if isStamping { return }
        if !isApplyingHouseholdRemote {
            isStamping = true
            let changedIDs = stampChanged(&groceryItems, against: oldValue)
            isStamping = false
            let oldIDs = Set(oldValue.map(\.id))
            let goneIDs = oldIDs.subtracting(groceryItems.map(\.id))
            for id in goneIDs { pendingGroTombstones.insert(id.uuidString) }
            var ops: [(id: UUID, type: HouseholdEntityType, op: HouseholdOperationType)] = []
            for id in changedIDs { ops.append((id, .groceryItem, oldIDs.contains(id) ? .update : .create)) }
            for id in goneIDs { ops.append((id, .groceryItem, .delete)) }
            HouseholdSync.shared.enqueueBatch(ops)
        }
        saveDebounced(DBKey.groceryItems.rawValue, groceryItems); SharedPantrySync.shared.push(store: self); pushHouseholdDebounced(); refreshWidgetsDebounced() } }
    var itemPreferences:       [String: ItemPreference] = [:] { didSet { saveDebounced("itemPrefs_v1", itemPreferences) } }
    var pastMeals:             [LocalPastMeal]      = [] { didSet { saveDebounced(DBKey.pastMeals.rawValue, pastMeals) } }
    var plannedMeals:          [PlannedMeal]        = [] { didSet { saveDebounced(DBKey.plannedMeals.rawValue, plannedMeals) } }
    var savedGeneratedRecipes: [GeneratedRecipe] = [] {
        didSet {
            if isStamping { return }
            if !isApplyingHouseholdRemote {
                isStamping = true
                let changedIDs = stampChanged(&savedGeneratedRecipes, against: oldValue)
                isStamping = false
                let oldIDs = Set(oldValue.map(\.id))
                let goneIDs = oldIDs.subtracting(savedGeneratedRecipes.map(\.id))
                for id in goneIDs { pendingGenRecipeTombstones.insert(id.uuidString) }
                var ops: [(id: UUID, type: HouseholdEntityType, op: HouseholdOperationType)] = []
                for id in changedIDs { ops.append((id, .generatedRecipe, oldIDs.contains(id) ? .update : .create)) }
                for id in goneIDs { ops.append((id, .generatedRecipe, .delete)) }
                HouseholdSync.shared.enqueueBatch(ops)
            }
            saveDebounced(DBKey.savedGeneratedRecipes.rawValue, savedGeneratedRecipes)
            pushHouseholdDebounced()
        }
    }
    var priceHistory:          [PriceRecord]        = [] { didSet { saveDebounced(DBKey.priceHistory.rawValue, priceHistory) } }
    var itemStoreHistory:      [String: String]     = [:] { didSet { saveDebounced("itemStoreHistory_v1", itemStoreHistory) } }
    var consumptionLog:        [ConsumptionRecord]  = [] { didSet { saveDebounced(DBKey.consumptionLog.rawValue, consumptionLog) } }   // close-the-loop #1
    var displayName: String = "" { didSet { ud.set(displayName, forKey: "guestName") } }
    var groceryDayOfWeek: Int = 6 { didSet { ud.set(groceryDayOfWeek, forKey: "groceryDay") } }
    var quizCompleted: Bool = false { didSet { ud.set(quizCompleted, forKey: "quizCompleted") } }
    // Kitchen Goals — the user's chosen staples drive a meaningful stock % (see stockPercent).
    var stockGoalsConfigured: Bool = false { didSet { ud.set(stockGoalsConfigured, forKey: "stockGoalsConfigured") } }
    var stockStaples: [String] = [] { didSet { saveDebounced("stockStaples_v1", stockStaples) } }

    init() { load() }

    // #2: encode ONCE and reuse the same Data for both the disk write and the
    //     same-session UserDefaults mirror (was encoding the whole array twice).
    // #3: UserDefaults isn't meant for large blobs (degrades/refuses past ~1MB), so
    //     skip the UD mirror above a threshold — disk is the source of truth, and
    //     loadDecoded() falls back to disk when the mirror is absent.
    private static let udMirrorMaxBytes = 256 * 1024   // 256KB
    // #4 — Debounced batched save. didSet handlers mark a key dirty and schedule a flush
    // instead of re-encoding the whole array on every single mutation. A 30-item receipt
    // import now encodes+writes once after the batch settles, not 30×. Each scheduled
    // closure captures the value as of its mutation; the last write for a key wins.
    private var dirtyKeys: [String: () -> Void] = [:]
    private var saveFlushTask: Task<Void, Never>? = nil
    private func scheduleSave(_ key: String, _ persist: @escaping () -> Void) {
        dirtyKeys[key] = persist
        saveFlushTask?.cancel()
        saveFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)   // coalesce window
            guard let self, !Task.isCancelled else { return }
            self.flushPendingSaves()
        }
    }
    /// Force any pending debounced saves to disk immediately (called on background/terminate).
    func flushPendingSaves() {
        let work = dirtyKeys
        dirtyKeys.removeAll()
        for (_, persist) in work { persist() }
    }
    private func save<T: Encodable>(_ key: String, value: T) {
        guard let data = try? JSONEncoder().encode(value) else {
            LocalDatabase.shared.save(value, key: key)   // still attempt disk write
            return
        }
        LocalDatabase.shared.saveData(data, key: key)
        if data.count <= Self.udMirrorMaxBytes {
            ud.set(data, forKey: key)        // small → keep fast same-session mirror
        } else {
            ud.removeObject(forKey: key)     // large → drop stale mirror, read from disk
        }
    }
    /// Debounced variant of `save` for hot, frequently-mutated collections (#4).
    /// Takes the value directly (NOT an autoclosure): in a didSet the property is already in
    /// scope, so the value is evaluated at the call site and captured as a plain constant —
    /// the registration closure then only touches `self` via [weak self], which avoids the
    /// "reference to property … requires explicit 'self'" escaping-closure error.
    private func saveDebounced<T: Encodable>(_ key: String, _ value: T) {
        scheduleSave(key) { [weak self] in self?.save(key, value: value) }
    }
    private func loadDecoded<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        // Prefer the UD mirror (fast); fall back to the disk file for large values
        // that intentionally skip the mirror (#3).
        if let data = ud.data(forKey: key),
           let decoded = try? JSONDecoder().decode(type, from: data) {
            return decoded
        }
        return LocalDatabase.shared.load(type, key: key)
    }
    /// Corruption-tolerant array load (#6): decodes each element independently so a single
    /// malformed record is skipped instead of discarding the entire collection. Falls back
    /// to the disk file (also element-skipping) when the fast UD mirror is absent.
    private func loadDecodedArray<Element: Decodable>(_ key: String, of type: Element.Type) -> [Element] {
        if let data = ud.data(forKey: key), let arr = SafeDecode.array(Element.self, from: data) {
            return arr
        }
        return LocalDatabase.shared.loadArray(Element.self, key: key) ?? []
    }
    private func load() {
        displayName           = ud.string(forKey: "guestName") ?? ""
        quizCompleted         = ud.bool(forKey: "quizCompleted")
        cookingProfile        = (ud.data(forKey: DBKey.cookingProfile.rawValue).flatMap { try? JSONDecoder().decode(UserCookingProfile.self, from: $0) }) ?? UserCookingProfile()
        groceryDayOfWeek      = ud.integer(forKey: "groceryDay") == 0 ? 6 : ud.integer(forKey: "groceryDay")
        // #6 — Run-once versioned migration instead of an every-launch inline transform.
        let loadedInventory = loadDecodedArray(DBKey.inventoryItems.rawValue, of: LocalInventoryItem.self)
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        inventoryItems        = DBMigrations.migrateInventory(loadedInventory)
        groceryItems          = DBMigrations.migrateGrocery(
            loadDecodedArray(DBKey.groceryItems.rawValue, of: LocalGroceryItem.self)
                .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        )
        itemPreferences       = loadDecoded("itemPrefs_v1", as: [String: ItemPreference].self) ?? [:]
        pastMeals             = DBMigrations.migratePastMeals(
            loadDecodedArray(DBKey.pastMeals.rawValue, of: LocalPastMeal.self)
        )
        plannedMeals          = loadDecodedArray(DBKey.plannedMeals.rawValue, of: PlannedMeal.self)
        savedGeneratedRecipes = loadDecodedArray(DBKey.savedGeneratedRecipes.rawValue, of: GeneratedRecipe.self)
        userRecipes           = DBMigrations.migrateRecipes(
            loadDecodedArray(DBKey.userRecipes.rawValue, of: UserRecipe.self)
        )
        userSubstitutions     = loadDecodedArray("userSubstitutions_v1", of: UserSubstitutionEntry.self)
        priceHistory          = loadDecodedArray(DBKey.priceHistory.rawValue, of: PriceRecord.self)
        itemStoreHistory      = loadDecoded("itemStoreHistory_v1", as: [String: String].self) ?? [:]
        consumptionLog        = loadDecodedArray(DBKey.consumptionLog.rawValue, of: ConsumptionRecord.self)
        stockGoalsConfigured  = ud.bool(forKey: "stockGoalsConfigured")
        stockStaples          = loadDecodedArray("stockStaples_v1", of: String.self)
        // #8 — Retention pruning so unbounded logs can't grow forever (each is fully
        // rewritten on change, so size directly drives write cost).
        pruneRetainedData()
    }

    // MARK: - Retention (#8)
    // Keep storage and per-write cost bounded. consumptionLog was already capped to 1000;
    // this also trims price history to the most recent 365 days, and the per-item store
    // history map to its most recent entries.
    private func pruneRetainedData() {
        let now = Date()
        let yearAgo = now.addingTimeInterval(-365 * 86400)
        let trimmedPrices = priceHistory.filter { $0.date >= yearAgo }
        if trimmedPrices.count != priceHistory.count { priceHistory = trimmedPrices }
        if consumptionLog.count > 1000 { consumptionLog = Array(consumptionLog.suffix(1000)) }
    }

    // Auto-sync low inventory items to grocery list
    func syncLowStockToGrocery() {
        let low = inventoryItems.filter { $0.isLow }
        var addedCount = 0
        // Build the set of existing grocery names ONCE (normalized) instead of re-scanning +
        // re-lowercasing the whole grocery list for every low item (#2).
        var existing = Set(groceryItems.map { DBNormalize.key($0.name) })
        for item in low {
            let key = DBNormalize.key(item.name)
            if !existing.contains(key) {
                groceryItems.append(LocalGroceryItem(name: item.name, isChecked: false, isRecommended: true))
                existing.insert(key)
                addedCount += 1
            }
        }
        // #1 — also pull in items predicted to run out within 3 days from learned usage.
        for item in itemsRunningOutSoon(within: 3) {
            let key = DBNormalize.key(item.name)
            if !existing.contains(key) {
                groceryItems.append(LocalGroceryItem(name: item.name, isChecked: false, isRecommended: true))
                existing.insert(key)
                addedCount += 1
            }
        }
        // Confirm the silent action so it doesn't feel like unexplained magic (#13).
        if addedCount > 0 {
            let n = addedCount
            Task { @MainActor in
                ToastCenter.shared.info(n == 1 ? "Added a running-low item to your list"
                                                : "Added \(n) running-low items to your list")
            }
        }
        scheduleNotificationsIfNeeded()
    }

    // Push notifications for low/out-of-stock items.
    // #4: Debounced — bulk edits (e.g. a 30-item receipt import) would otherwise call
    // removeAllPendingNotificationRequests + reschedule once per item. Coalesce to one
    // pass ~0.6s after the last change.
    private var notifyDebounce: Task<Void, Never>? = nil
    func scheduleNotificationsIfNeeded() {
        notifyDebounce?.cancel()
        notifyDebounce = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            performNotificationScheduling()
        }
    }

    private func performNotificationScheduling() {
        let center   = UNUserNotificationCenter.current()
        let snapshot = inventoryItems   // capture on @MainActor before entering non-isolated closure
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            // Only clear THIS scheduler's own request. Using removeAllPendingNotificationRequests()
            // here wiped every reminder the DailyBriefNotificationManager had scheduled (expiry,
            // cook suggestion, staples, prep, daily brief) every time inventory changed — so those
            // reminders never survived to fire outside the app. Scope the removal to "lowStock".
            center.removePendingNotificationRequests(withIdentifiers: ["lowStock"])
            let outOfStock  = snapshot.filter { $0.effectiveLevel == 0 }
            let low         = snapshot.filter { $0.isLow }
            var messages: [String] = []
            if !outOfStock.isEmpty {
                messages.append("\(outOfStock.map(\.name).joined(separator: ", ")) – out of stock")
            }
            if !low.isEmpty {
                messages.append("\(low.map(\.name).joined(separator: ", ")) – running low")
            }
            guard !messages.isEmpty else { return }

            let content = UNMutableNotificationContent()
            content.title = "Stocked. Kitchen Alert"
            content.body  = messages.joined(separator: "\n")
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 2, repeats: false)
            let req = UNNotificationRequest(identifier: "lowStock", content: content, trigger: trigger)
            center.add(req, withCompletionHandler: nil)
        }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    // MARK: - Nuclear clear — wipes every byte of stored data
    func clearAll() {
        // ── 0. Stop any in-flight debounced save FIRST ───────────────
        // A save queued moments before this call (e.g. from a recent edit) would otherwise
        // fire its flush AFTER we wipe disk below and write the old data straight back — a
        // silent resurrection. Cancel the pending flush and drop the dirty queue so nothing we
        // are about to clear gets persisted again.
        saveFlushTask?.cancel()
        saveFlushTask = nil
        dirtyKeys.removeAll()

        // ── 1. In-memory state ───────────────────────────────────────
        inventoryItems        = []
        groceryItems          = []
        pastMeals             = []
        plannedMeals          = []
        savedGeneratedRecipes = []
        userRecipes           = []
        userSubstitutions     = []
        itemPreferences       = [:]
        priceHistory          = []
        itemStoreHistory      = [:]
        displayName           = ""
        groceryDayOfWeek      = 6
        cookingProfile        = UserCookingProfile()
        quizCompleted         = false

        // ── 2. Wipe entire UserDefaults domain — catches every key ───
        if let bundleID = Bundle.main.bundleIdentifier {
            ud.removePersistentDomain(forName: bundleID)
            ud.synchronize()
        }

        // ── 3. Recipe suggestion cache ───────────────────────────────
        UserDefaults.standard.removeObject(forKey: "onlineRecipesCache_v2")
        UserDefaults.standard.removeObject(forKey: "onlineRecipesOpenCount")

        // ── 4. Rating/preference weights (SurpriseRecipeEngine) ──────
        UserDefaults.standard.removeObject(forKey: "ratingWeights_v1")

        // ── 4b. On-disk JSON store (THE missing wipe) ────────────────
        // Large collections (inventory past the UserDefaults mirror cap) live ONLY as JSON
        // files in the app's Documents directory via LocalDatabase — the UserDefaults domain
        // wipe above never touches them. Without this, clearing empties the arrays in memory
        // but the next load() re-reads the on-disk blobs and everything comes back. Wiping the
        // file store here is what makes "Clear All Data" and "Erase and Exit" actually stick.
        LocalDatabase.shared.deleteAll()

        // ── 5. iCloud Key-Value Store ─────────────────────────────────
        let kvStore = NSUbiquitousKeyValueStore.default
        for key in kvStore.dictionaryRepresentation.keys {
            kvStore.removeObject(forKey: key)
        }
        kvStore.synchronize()

        // ── 6. iCloud Document backup ─────────────────────────────────
        let fm = FileManager.default
        if let iCloudURL = fm.url(forUbiquityContainerIdentifier: nil)?
            .appendingPathComponent("Documents/stocked_backup.json") {
            try? fm.removeItem(at: iCloudURL)
        }

        // ── 7. Temp files ─────────────────────────────────────────────
        let tmpDir = fm.temporaryDirectory
        if let tmpFiles = try? fm.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) {
            tmpFiles.filter { $0.lastPathComponent.hasPrefix("stocked") }
                    .forEach { try? fm.removeItem(at: $0) }
        }
    }

    func addGroceryItem(name: String) {
        // #17 — accent/case-insensitive dedup so "milk" / "Milk" / "Crème" don't double up.
        guard !GroceryDedup.isDuplicate(name, in: groceryItems.map { $0.name }) else { return }
        AppAnalytics.shared.log(.groceryItemAdded)
        withAnimation { groceryItems.append(LocalGroceryItem(name: name, isChecked: false)) }
    }
    func renameInventoryItem(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var l = inventoryItems
        if let i = l.firstIndex(where: { $0.id == id }) { l[i].name = trimmed }
        inventoryItems = l
        Task { @MainActor in DatabaseSyncBus.shared.publish(.inventoryItemUpdated(name: trimmed)) }
    }
    func renameGroceryItem(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var l = groceryItems
        if let i = l.firstIndex(where: { $0.id == id }) { l[i].name = trimmed }
        groceryItems = l
    }
    func updateGroceryQty(id: UUID, qty: Int) {
        var l = groceryItems
        if let i = l.firstIndex(where: { $0.id == id }) { l[i].quantity = max(1, qty) }
        groceryItems = l
    }
    func toggleGrocery(id: UUID) {
        if let i = groceryItems.firstIndex(where: { $0.id == id }) {
            withAnimation { groceryItems[i].isChecked.toggle() }
            if groceryItems[i].isChecked { AppAnalytics.shared.log(.groceryItemChecked) }
        }
    }
    func removeGrocery(id: UUID) {
        withAnimation { groceryItems.removeAll { $0.id == id } }
    }

    /// #4 — canonical set of lowercased names currently in stock (level > 0). One place
    /// for "do I already have this?" so callers don't rebuild it inconsistently.
    var inStockNameSet: Set<String> {
        Set(inventoryItems.filter { $0.level > 0 }.map { $0.name.lowercased() })
    }

    /// #5 — push a recipe's ingredients to the grocery list: skip anything already in
    /// stock, consolidate duplicates (bump quantity + append the recipe as a source),
    /// and tag new lines with the recipe. Skips ingredients marked optional. Returns the
    /// number of NEW lines added (0 = everything was already on the list or in stock).
    @discardableResult
    func addRecipeIngredientsToGrocery(_ ingredients: [RecipeIngredient], recipeName: String) -> Int {
        let recipe = recipeName.trimmingCharacters(in: .whitespaces)
        let rid = userRecipes.first(where: { $0.title == recipe })?.id.uuidString ?? ""   // #9
        let inStock = inStockNameSet
        var added = 0
        withAnimation {
            for ing in ingredients where !ing.isOptional {
                let n = ing.name.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { continue }
                let low = n.lowercased()
                if inStock.contains(where: { low.contains($0) || $0.contains(low) }) { continue }
                let key = GroceryConsolidator.normalizeKey(n)
                if let idx = groceryItems.firstIndex(where: { GroceryConsolidator.normalizeKey($0.name) == key }) {
                    groceryItems[idx].quantity += 1
                    if !recipe.isEmpty, !groceryItems[idx].recipeSource.contains(recipe) {
                        groceryItems[idx].recipeSource += groceryItems[idx].recipeSource.isEmpty ? recipe : ", \(recipe)"
                    }
                    if groceryItems[idx].recipeId.isEmpty { groceryItems[idx].recipeId = rid }   // #9
                } else {
                    groceryItems.append(LocalGroceryItem(name: n, isChecked: false, recipeSource: recipe, recipeId: rid))
                    added += 1
                }
            }
        }
        return added
    }
    /// Normalized titles of saved recipes — for de-duping online results (#4).
    var savedRecipeTitles: Set<String> {
        Set(userRecipes.map { OnlineRecipeFacts.normalizedTitle($0.title) })
    }

    /// Import an online recipe into My Collection with STRUCTURED ingredient fields (#5):
    /// each free-text measure ("1 cup, chopped") is parsed into amount/unit/name so scaling
    /// and grocery consolidation work on imported recipes just like hand-entered ones.
    /// Save an AI-generated recipe into the user's collection (the same list that powers Saved,
    /// Favorites, Cooked, and Collections). Converts the GeneratedRecipe into a UserRecipe so it
    /// shows up everywhere user recipes do, rather than living in a separate generated-only list.
    /// Returns the new recipe's id, or the existing one if a recipe with the same title is saved.
    @discardableResult
    func saveGeneratedRecipe(_ r: GeneratedRecipe) -> UUID {
        if let existing = userRecipes.first(where: {
            OnlineRecipeFacts.normalizedTitle($0.title) == OnlineRecipeFacts.normalizedTitle(r.title)
        }) { return existing.id }

        var saved = UserRecipe(title: r.title)
        saved.cookTime   = r.cookTime
        saved.servings   = r.servings
        saved.difficulty = r.difficulty
        saved.notes      = r.tips
        saved.ingredients = r.ingredients.map { line in
            let full = "\(line.amount) \(line.name)".trimmingCharacters(in: .whitespaces)
            let pq = ParsedQuantity.parse(full)
            let name = pq.baseName.isEmpty ? line.name.trimmingCharacters(in: .whitespaces) : pq.baseName
            return RecipeIngredient(
                name: name,
                amount: line.amount.trimmingCharacters(in: .whitespaces),
                quantity: pq.amount > 0 ? pq.amount : nil,
                unit: pq.canonicalUnit.isEmpty ? nil : pq.canonicalUnit
            )
        }
        saved.instructions = r.steps
        addUserRecipe(saved)
        return saved.id
    }

    /// Returns the new recipe's id (or the existing one if already saved by title).
    @discardableResult
    func importOnlineRecipe(_ recipe: OnlineRecipe) -> UUID {
        if let existing = userRecipes.first(where: {
            OnlineRecipeFacts.normalizedTitle($0.title) == OnlineRecipeFacts.normalizedTitle(recipe.title)
        }) { return existing.id }

        var saved = UserRecipe(title: recipe.title)
        saved.ingredients = recipe.ingredientLines.map { pair in
            let full = "\(pair.measure) \(pair.ingredient)".trimmingCharacters(in: .whitespaces)
            let pq = ParsedQuantity.parse(full)
            // baseName is the parsed name; fall back to the raw ingredient if parsing stripped it.
            let name = pq.baseName.isEmpty ? pair.ingredient.trimmingCharacters(in: .whitespaces) : pq.baseName
            return RecipeIngredient(
                name: name,
                amount: pair.measure.trimmingCharacters(in: .whitespaces),
                quantity: pq.amount > 0 ? pq.amount : nil,
                unit: pq.canonicalUnit.isEmpty ? nil : pq.canonicalUnit
            )
        }
        saved.instructions = recipe.instructions
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        saved.imageURL = recipe.imageURL
        saved.cuisine  = recipe.area
        saved.notes    = [recipe.area, recipe.category].filter { !$0.isEmpty }.joined(separator: " · ")
        addUserRecipe(saved)
        return saved.id
    }

    /// Seed a starter set of pantry/fridge staples (App #3 onboarding). Skips anything the
    /// user already has, so it's safe to call more than once. Returns how many were added.
    @discardableResult
    func seedStarterStaples() -> Int {
        var added = 0
        for seed in StarterStaples.all {
            let low = seed.name.lowercased()
            let exists = inventoryItems.contains { $0.name.lowercased() == low }
            if exists { continue }
            var item = LocalInventoryItem(name: seed.name, level: 1.0, zone: seed.zone)
            item.quantity = 1
            addInventoryItem(item)
            added += 1
        }
        return added
    }

    /// Re-insert exact deleted records for undo (#251) — no merge, no level reset, so the
    /// restored item is byte-for-byte what the user had. Skips any id already present.
    func restoreInventoryItems(_ items: [LocalInventoryItem]) {
        let existing = Set(inventoryItems.map(\.id))
        let toAdd = items.filter { !existing.contains($0.id) }
        guard !toAdd.isEmpty else { return }
        withAnimation { inventoryItems.append(contentsOf: toAdd) }
    }

    func addInventoryItem(_ item: LocalInventoryItem) {
        AppAnalytics.shared.log(.itemAdded)
        Task { @MainActor in
            DatabaseSyncBus.shared.publish(.inventoryItemAdded(name: item.name))
            StockedKnowledgeBase.shared.learnFromInventoryItem(name: item.name)
        }
        // #2/#18/#20 — Smart merge: if an equivalent item already exists (same
        // normalized name AND compatible unit), bump its quantity and refresh
        // metadata rather than creating a duplicate row.
        if let idx = inventoryItems.firstIndex(where: { Self.isSameItem($0, item) }) {
            withAnimation {
                inventoryItems[idx].quantity += max(1, item.quantity)
                inventoryItems[idx].level = 1.0            // restocked → full
                // Prefer newly-scanned details when present.
                if let p = item.price            { inventoryItems[idx].price = p }
                if let d = item.purchaseDate     { inventoryItems[idx].purchaseDate = d }
                if let s = item.storePurchasedAt { inventoryItems[idx].storePurchasedAt = s }
                if let b = item.brand            { inventoryItems[idx].brand = b }
                if let who = item.addedBy        { inventoryItems[idx].addedBy = who }
                // Extend expiry to the later of the two (fresher stock).
                if let newExp = item.expirationDate {
                    if let cur = inventoryItems[idx].expirationDate {
                        inventoryItems[idx].expirationDate = max(cur, newExp)
                    } else {
                        inventoryItems[idx].expirationDate = newExp
                    }
                }
            }
            return
        }
        withAnimation { inventoryItems.append(item) }
    }

    /// Two items are "the same" for merging if their names normalize equal and their
    /// units are compatible (both countable, or same size unit). #18 keeps us from
    /// merging "2 cans" into "3 lbs".
    static func isSameItem(_ a: LocalInventoryItem, _ b: LocalInventoryItem) -> Bool {
        let na = a.name.lowercased().trimmingCharacters(in: .whitespaces)
        let nb = b.name.lowercased().trimmingCharacters(in: .whitespaces)
        guard na == nb else { return false }
        let ua = a.sizeUnit?.lowercased() ?? ""
        let ub = b.sizeUnit?.lowercased() ?? ""
        return ua == ub
    }
    func updateInventoryLevel(id: UUID, level: Double) {
        if let i = inventoryIndex(of: id) {   // #5 — O(1) lookup instead of firstIndex scan
            let was = inventoryItems[i].level
            withAnimation { inventoryItems[i].level = level }
            // Close-the-loop #1/#2 — if it just hit empty, log consumption + restock grocery.
            if was > 0 && level <= 0 { handleDepleted(inventoryItems[i]) }
        }
    }

    /// Freeze an item from the Daily Brief: move it to the Freezer zone and push its expiry out,
    /// since freezing genuinely extends shelf life. Default +60 days; if the item has no expiry
    /// we set one 60 days out so it stops nagging as "expiring". This is a real inventory change,
    /// not a UI-only dismissal.
    func freezeItem(id: UUID, extendDays: Int = 60) {
        guard let i = inventoryIndex(of: id) else { return }
        withAnimation {
            inventoryItems[i].storageCategory = .freezer
            let base = inventoryItems[i].expirationDate ?? Date()
            inventoryItems[i].expirationDate = base.addingTimeInterval(Double(extendDays) * 86400)
        }
    }

    // MARK: - Daily Brief snooze
    // Lets the user quiet an expiring-soon item for a while without changing the item itself.
    // Stored as id → snooze-until timestamps in UserDefaults so it survives relaunch, and is
    // pruned lazily. The Brief filters items whose snooze is still in the future.
    private var snoozeKey: String { "expiringSnooze_v1" }
    private func snoozeMap() -> [String: Double] {
        (ud.dictionary(forKey: snoozeKey) as? [String: Double]) ?? [:]
    }
    /// Snooze an item from the expiring list for `days` (default 3).
    func snoozeExpiring(id: UUID, days: Int = 3) {
        var map = snoozeMap()
        map[id.uuidString] = Date().addingTimeInterval(Double(days) * 86400).timeIntervalSince1970
        ud.set(map, forKey: snoozeKey)
    }
    /// True while an item is still within its snooze window.
    func isSnoozed(_ id: UUID) -> Bool {
        guard let until = snoozeMap()[id.uuidString] else { return false }
        if until <= Date().timeIntervalSince1970 {
            // Expired snooze — clean it up so the map doesn't grow unbounded.
            var map = snoozeMap(); map[id.uuidString] = nil; ud.set(map, forKey: snoozeKey)
            return false
        }
        return true
    }

    func removeInventoryItem(id: UUID) {
        // thrown out, not used up. Log it as waste (with its known price) for the Stats view.
        if let item = inventoryItems.first(where: { $0.id == id }),
           item.level > 0, let exp = item.expirationDate, exp < Date() {
            consumptionLog.append(ConsumptionRecord(
                itemName: item.name.lowercased().trimmingCharacters(in: .whitespaces),
                purchasedAt: item.purchaseDate, depletedAt: Date(),
                wasted: true, estimatedValue: item.price))
            if consumptionLog.count > 1000 { consumptionLog = Array(consumptionLog.suffix(1000)) }
        }
        withAnimation { inventoryItems.removeAll { $0.id == id } }
    }
    func deductIngredients(_ ingredients: [String]) {
        for ingredient in ingredients {
            let lower = ingredient.lowercased()
            if let i = inventoryItems.firstIndex(where: {
                lower.contains($0.name.lowercased()) || $0.name.lowercased().contains(lower)
            }) {
                let was = inventoryItems[i].level
                withAnimation { inventoryItems[i].level = max(0, inventoryItems[i].level - 0.25) }
                if was > 0 && inventoryItems[i].level <= 0 { handleDepleted(inventoryItems[i]) }
            }
        }
    }

    // MARK: - Close-the-loop engine

    /// Called when an item reaches empty: records how long it lasted (#1) and, if
    /// auto-add is on, drops it onto the grocery list (#2).
    private func handleDepleted(_ item: LocalInventoryItem) {
        let name = item.name.lowercased().trimmingCharacters(in: .whitespaces)
        consumptionLog.append(ConsumptionRecord(itemName: name,
                                                purchasedAt: item.purchaseDate,
                                                depletedAt: Date()))
        if consumptionLog.count > 1000 { consumptionLog = Array(consumptionLog.suffix(1000)) }
        // #2 — auto-add to grocery when depleted (respects the autoAddMissing toggle).
        if ud.bool(forKey: DBKey.autoAddMissing.rawValue) {
            addToGroceryIfMissing(item.name, recommended: true)
        }
    }

    /// #1 — average days this item has historically lasted (nil if not enough data).
    func averageDaysToDeplete(for name: String) -> Double? {
        let key = name.lowercased().trimmingCharacters(in: .whitespaces)
        let spans = consumptionLog.filter { $0.itemName == key }.compactMap { $0.daysLasted }
        guard spans.count >= 1 else { return nil }
        return spans.reduce(0, +) / Double(spans.count)
    }

    /// #1 — predicted run-out date for an item currently in stock, from its purchase
    /// date + learned average lifespan. nil if we can't predict yet.
    func predictedRunOut(for item: LocalInventoryItem) -> Date? {
        guard let avg = averageDaysToDeplete(for: item.name) else { return nil }
        let start = item.purchaseDate ?? Date()
        // Scale remaining by current level so a half-used item runs out sooner.
        let remaining = max(0.0, item.level) * avg
        return Calendar.current.date(byAdding: .day, value: Int(remaining.rounded()), to: start)
    }

    /// Items predicted to run out within `days` (default 3) and not already on the list.
    func itemsRunningOutSoon(within days: Int = 3) -> [LocalInventoryItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: days, to: Date())!
        return inventoryItems.filter { item in
            guard item.level > 0, let ro = predictedRunOut(for: item) else { return false }
            let onList = groceryItems.contains { $0.name.lowercased() == item.name.lowercased() }
            return ro <= cutoff && !onList
        }
    }

    // MARK: - Stock matching + profile ranking (#1, #2, #6)
    /// Loose two-way name match: "chicken breast" ↔ "Chicken", "eggs" ↔ "Egg (dozen)".
    nonisolated private static func looseMatch(_ a: String, _ b: String) -> Bool {
        let na = a.lowercased().trimmingCharacters(in: .whitespaces)
        let nb = b.lowercased().trimmingCharacters(in: .whitespaces)
        guard na.count > 2, nb.count > 2 else { return na == nb }
        return na.contains(nb) || nb.contains(na)
    }

    /// Is this ingredient on hand (any in-stock inventory item that name-matches)?
    func ingredientInStock(_ ingredient: String) -> Bool {
        inventoryItems.contains { $0.effectiveLevel > 0 && Self.looseMatch(ingredient, $0.name) }
    }

    /// How much of a recipe you can make right now: (have, total) over non-optional ingredients.
    func stockMatch(for recipe: UserRecipe) -> (have: Int, total: Int) {
        let needed = recipe.ingredients.filter { !$0.isOptional }
        guard !needed.isEmpty else { return (0, 0) }
        let have = needed.filter { ingredientInStock($0.name) }.count
        return (have, needed.count)
    }

    /// What the Cook tab matches against: the user's saved recipes plus the built-in
    /// starter catalog (#247). Starters fill the rail/list before any recipes are saved;
    /// a saved recipe with the same title replaces its starter (saved always wins).
    var cookCatalog: [UserRecipe] {
        let savedTitles = Set(userRecipes.map { $0.title.lowercased().trimmingCharacters(in: .whitespaces) })
        let starters = StarterMeals.all.filter {
            !savedTitles.contains($0.title.lowercased().trimmingCharacters(in: .whitespaces))
        }
        return userRecipes + starters
    }

    /// Saved recipes that use at least one item expiring within `days` — "use it up" picks.
    /// Ranked by how many expiring items they consume, so the most wasteful-to-skip come first.
    func recipesUsingExpiringItems(within days: Int = 3, limit: Int = 3) -> [UserRecipe] {
        let cutoff = Date().addingTimeInterval(Double(days) * 86_400)
        let expiring = inventoryItems.filter {
            guard $0.effectiveLevel > 0, let exp = $0.expirationDate else { return false }
            return exp <= cutoff
        }
        guard !expiring.isEmpty else { return [] }
        let scored: [(UserRecipe, Int)] = userRecipes.compactMap { recipe in
            let uses = expiring.filter { item in
                recipe.ingredients.contains { Self.looseMatch($0.name, item.name) }
            }.count
            return uses > 0 ? (recipe, uses) : nil
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    /// #14 — Cook Right Now: every meal you can make *now* (fully stocked), ranked so the
    /// ones using the most soon-to-expire ingredients come first. Returns the recipe plus the
    /// names of expiring items it would use up, so the UI can show "uses: spinach, cream".
    func cookableRankedByExpiry(within days: Int = KitchenThresholds.expiringSoonDays)
        -> [(recipe: UserRecipe, expiringUsed: [String])] {
        let cutoff = Date().addingTimeInterval(Double(days) * 86_400)
        let expiring = inventoryItems.filter {
            guard $0.effectiveLevel > 0, let exp = $0.expirationDate else { return false }
            return exp <= cutoff
        }
        let makeable = cookCatalog.filter { r in
            let m = stockMatch(for: r)
            return m.total > 0 && m.have == m.total
        }
        let scored = makeable.map { recipe -> (UserRecipe, [String]) in
            let used = expiring
                .filter { item in recipe.ingredients.contains { Self.looseMatch($0.name, item.name) } }
                .map { $0.name.displayNormalized }
            return (recipe, used)
        }
        // Most expiring-items-used first; ties broken by most-cooked (familiar wins).
        return scored.sorted {
            $0.1.count == $1.1.count ? $0.0.cookCount > $1.0.cookCount : $0.1.count > $1.1.count
        }
    }

    /// Ingredients in this recipe that conflict with the user's saved allergens.
    /// Used to WARN on saved recipes (never hard-hide the user's own collection).
    func allergenConflicts(in recipe: UserRecipe) -> [String] {
        let allergens = cookingProfile.allergens.filter { !$0.isEmpty }
        guard !allergens.isEmpty else { return [] }
        var hits: Set<String> = []
        for ing in recipe.ingredients {
            for allergen in allergens where Self.looseMatch(ing.name, allergen) {
                hits.insert(allergen)
            }
        }
        return Array(hits).sorted()
    }

    /// Small additive score from the cooking profile: preferred-cuisine matches float up.
    func profileBoost(for recipe: UserRecipe) -> Int {
        var score = 0
        let prefs = cookingProfile.cuisinePrefs.map { $0.lowercased() }
        if !recipe.cuisine.isEmpty, prefs.contains(recipe.cuisine.lowercased()) { score += 2 }
        let title = recipe.title.lowercased()
        if prefs.contains(where: { !$0.isEmpty && title.contains($0) }) { score += 1 }
        return score
    }

    /// Cheapest recorded price for an item across stores (#7) — recent 6 months only,
    /// so a stale 2-year-old deal doesn't masquerade as today's best option.
    func bestPrice(for name: String) -> PriceRecord? {
        let cutoff = Date().addingTimeInterval(-86_400 * 182)
        return priceHistory
            .filter { $0.date > cutoff && Self.looseMatch($0.itemName, name) }
            .min { $0.price < $1.price }
    }

    // MARK: - Drift correction (Source 2)
    // Inventory data quietly goes stale: the app thinks you still have things you've
    // actually used. Surface the most-likely-stale items so the user can reconcile in two
    // taps. "Stale" = expired (past expiry) OR past its learned predicted run-out date.
    // We propose REMOVE (pre-checked) so the common case is one tap → apply.
    func driftProposals(limit: Int = 8) -> [ProposedChange] {
        let now = Date()
        var out: [ProposedChange] = []
        for item in inventoryItems where item.level > 0 {
            var reason: String?
            if let exp = item.expirationDate, exp < now {
                let days = Calendar.current.dateComponents([.day], from: exp, to: now).day ?? 0
                reason = days <= 1 ? "Expired" : "Expired \(days) days ago"
            } else if let ro = predictedRunOut(for: item), ro < now {
                reason = "Usually gone by now"
            }
            if let reason {
                out.append(ProposedChange(itemID: item.id, displayName: item.name,
                                          action: .remove, reason: reason,
                                          isConfirmed: false))   // not pre-checked: it's a guess
            }
            if out.count >= limit { break }
        }
        return out
    }

    func addToGroceryIfMissing(_ name: String, recommended: Bool) {
        // #17 — accent/case-insensitive dedup.
        let exists = GroceryDedup.isDuplicate(name, in: groceryItems.map { $0.name })
        guard !exists else { return }
        withAnimation {
            groceryItems.append(LocalGroceryItem(name: name, isChecked: false, isRecommended: recommended))
        }
    }
    /// Same as above but records which recipe the item came from. Used by the recipe and
    /// meal-plan screens so the "added from <recipe>" provenance is preserved while the dedup
    /// rule stays centralized here instead of being re-spelled at each call site.
    func addToGroceryIfMissing(_ name: String, recommended: Bool, recipeSource: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        guard !GroceryDedup.isDuplicate(trimmed, in: groceryItems.map { $0.name }) else { return }
        withAnimation {
            groceryItems.append(LocalGroceryItem(name: trimmed, isChecked: false,
                                                 isRecommended: recommended, recipeSource: recipeSource))
        }
    }

    /// #3 — build the grocery list from the week's planned meals: gather every planned
    /// ingredient, skip anything already in stock, add the rest (tagged by recipe).
    /// Returns the number of items added.
    @discardableResult
    func generateGroceryFromMealPlan() -> Int {
        let inStock = Set(inventoryItems.filter { $0.level > 0 }.map { $0.name.lowercased() })
        var added = 0
        for meal in plannedMeals where !meal.isCooked {
            for ing in meal.ingredients {
                let n = ing.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { continue }
                let low = n.lowercased()
                let haveInStock = inStock.contains(where: { low.contains($0) || $0.contains(low) })
                let onList = groceryItems.contains { $0.name.lowercased() == low }
                if !haveInStock && !onList {
                    withAnimation {
                        groceryItems.append(LocalGroceryItem(name: n, isChecked: false,
                                                             isRecommended: true,
                                                             recipeSource: meal.title))
                    }
                    added += 1
                }
            }
        }
        return added
    }

    /// #5 — move every checked grocery item into inventory (merging via addInventoryItem),
    /// then remove them from the list. Returns the number moved.
    @discardableResult
    func moveCheckedGroceryToInventory() -> Int {
        let checked = groceryItems.filter { $0.isChecked }
        guard !checked.isEmpty else { return 0 }
        let who = UserDefaults.standard.string(forKey: "householdMemberName_v1") ?? ""
        for g in checked {
            var inv = LocalInventoryItem(name: g.name, level: 1.0, zone: "Pantry",
                                         quantity: max(1, g.quantity))
            inv.purchaseDate = Date()
            inv.addedBy = who
            addInventoryItem(inv)             // merges if it already exists (#2/#18)
        }
        withAnimation { groceryItems.removeAll { $0.isChecked } }
        return checked.count
    }

    /// #9 — deduct (or finish) an item by a scanned/typed name. Lowers one container's
    /// worth; if it empties the last container, marks it depleted. Returns the matched name.
    @discardableResult
    func findAndDeductByName(_ scannedName: String, finish: Bool = false) -> String? {
        let q = scannedName.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty,
              let idx = inventoryItems.firstIndex(where: {
                  let n = $0.name.lowercased()
                  return n == q || n.contains(q) || q.contains(n)
              }) else { return nil }
        let id = inventoryItems[idx].id
        if finish {
            updateInventoryLevel(id: id, level: 0)        // triggers depletion logging + auto-grocery
        } else if inventoryItems[idx].quantity > 1 {
            withAnimation { inventoryItems[idx].quantity -= 1 }
        } else {
            updateInventoryLevel(id: id, level: 0)
        }
        return inventoryItems.first(where: { $0.id == id })?.name
    }

    /// #4 — toggle a saved generated recipe as a favorite.
    func toggleRecipeFavorite(id: UUID) {
        if let i = savedGeneratedRecipes.firstIndex(where: { $0.id == id }) {
            withAnimation { savedGeneratedRecipes[i].isFavorited.toggle() }
        }
    }
    var favoriteRecipes: [GeneratedRecipe] { savedGeneratedRecipes.filter { $0.isFavorited } }

    /// #9 — for a missing ingredient, return substitutes the user ACTUALLY has in stock.
    /// Combines the built-in substitution DB with the user's own substitution entries.
    func inStockSubstitutes(for ingredient: String) -> [String] {
        let inStock = inventoryItems.filter { $0.level > 0 }.map { $0.name }
        var subs: [String] = []
        if let entry = StockedDatabase.shared.substitutions(for: ingredient) {
            subs += entry.substitutions.map { $0.substitute }
        }
        subs += userSubstitutions
            .filter { $0.ingredient.lowercased() == ingredient.lowercased() }
            .map { $0.substitute }
        // Keep only substitutes that match something currently in stock.
        let matches = subs.filter { sub in
            inStock.contains(where: { $0.lowercased().contains(sub.lowercased()) || sub.lowercased().contains($0.lowercased()) })
        }
        // De-dupe, preserve order.
        var seen = Set<String>(); var out: [String] = []
        for m in matches where seen.insert(m.lowercased()).inserted { out.append(m) }
        return out
    }

    /// #20 — "Surprise me" tuned to preferences + what's in stock. Scores known recipes
    /// by how many ingredients you already have, lightly biased to preferred cuisines.
    func surpriseRecipeTuned() -> GeneratedRecipe? {
        let inStock = Set(inventoryItems.filter { $0.level > 0 }.map { $0.name.lowercased() })
        // Cuisine preferences live on the cooking profile (owned by AppSession); read them
        // straight from storage so this works from within GuestDataStore.
        let profileCuisines: [String] = {
            guard let data = ud.data(forKey: DBKey.cookingProfile.rawValue),
                  let p = try? JSONDecoder().decode(UserCookingProfile.self, from: data)
            else { return [] }
            return p.cuisinePrefs
        }()
        let prefs = Set(profileCuisines.map { $0.lowercased() })
        func score(_ r: GeneratedRecipe) -> Int {
            let have = r.ingredients.filter { line in
                inStock.contains(where: { line.name.lowercased().contains($0) || $0.contains(line.name.lowercased()) })
            }.count
            let cuisineBonus = prefs.contains(where: { r.mealCategory.lowercased().contains($0) }) ? 3 : 0
            return have + cuisineBonus
        }
        let pool = savedGeneratedRecipes.filter { !$0.isHidden }
        guard !pool.isEmpty else { return nil }
        let sorted = pool.sorted { score($0) > score($1) }
        let topCount = max(1, sorted.count / 3)
        return sorted.prefix(topCount).randomElement()
    }

    func inventoryCSV() -> String {
        var rows = ["Name,Quantity,Zone,SubZone,Category,Level%,Brand,Price,Expiry,PurchaseDate,AddedBy"]
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        func esc(_ s: String) -> String {
            (s.contains(",") || s.contains("\""))
                ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
                : s
        }
        for it in inventoryItems {
            let cols = [
                esc(it.name),
                String(it.quantity),
                esc(it.zone),
                esc(it.subZone ?? ""),
                esc(it.customCategory ?? ""),
                String(Int(it.level * 100)),
                esc(it.brand ?? ""),
                it.price.map { String(format: "%.2f", $0) } ?? "",
                it.expirationDate.map { df.string(from: $0) } ?? "",
                it.purchaseDate.map { df.string(from: $0) } ?? "",
                esc(it.addedBy ?? "")
            ]
            rows.append(cols.joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }
    func saveRecipe(_ r: GeneratedRecipe) {
        guard !savedGeneratedRecipes.contains(where: { $0.id == r.id }) else { return }
        AppAnalytics.shared.log(.recipeSaved)
        savedGeneratedRecipes.append(r)
        addMissingIngredientsToGrocery(from: r)
    }
    func addMissingIngredientsToGrocery(from r: GeneratedRecipe) {
        for name in r.missingIngredients {
            guard !groceryItems.contains(where: { $0.name.lowercased() == name.lowercased() }) else { continue }
            groceryItems.append(LocalGroceryItem(name: name, isChecked: false, isRecommended: true))
        }
    }

    // OCR translation dictionary
    var ocrDictionary: [OCRTranslation] {
        get {
            guard let data = ud.data(forKey: "ocrDict_v1") else { return [] }
            return (try? JSONDecoder().decode([OCRTranslation].self, from: data)) ?? []
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) { ud.set(data, forKey: "ocrDict_v1") }
        }
    }
    // Translate raw OCR text using learned dictionary, returns resolved name or nil if unknown
    func translateOCR(_ raw: String) -> String? {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespaces)
        return ocrDictionary.first { $0.rawText.lowercased() == lower }?.resolved
    }
    // Learn a new correction (raw → resolved)
    func learnOCRCorrection(raw: String, resolved: String) {
        guard raw.lowercased() != resolved.lowercased() else { return }
        var dict = ocrDictionary
        if let i = dict.firstIndex(where: { $0.rawText.lowercased() == raw.lowercased() }) {
            dict[i].resolved = resolved
            dict[i].useCount += 1
        } else {
            dict.append(OCRTranslation(rawText: raw, resolved: resolved))
        }
        ocrDictionary = dict
    }

    // Cooking profile — stored var so @Observable tracks it for RootView routing
    var cookingProfile: UserCookingProfile = UserCookingProfile() {
        didSet {
            if let data = try? JSONEncoder().encode(cookingProfile) {
                ud.set(data, forKey: DBKey.cookingProfile.rawValue)
            }
        }
    }

    // UserRecipes stored in UserDefaults
    var userRecipes: [UserRecipe] = [] {
        didSet {
            if isStamping { return }
            if !isApplyingHouseholdRemote {
                isStamping = true
                let changedIDs = stampChanged(&userRecipes, against: oldValue)
                isStamping = false
                let oldIDs = Set(oldValue.map(\.id))
                let goneIDs = oldIDs.subtracting(userRecipes.map(\.id))
                for id in goneIDs { pendingUserRecipeTombstones.insert(id.uuidString) }
                var ops: [(id: UUID, type: HouseholdEntityType, op: HouseholdOperationType)] = []
                for id in changedIDs { ops.append((id, .userRecipe, oldIDs.contains(id) ? .update : .create)) }
                for id in goneIDs { ops.append((id, .userRecipe, .delete)) }
                HouseholdSync.shared.enqueueBatch(ops)
            }
            saveDebounced(DBKey.userRecipes.rawValue, userRecipes)
            pushHouseholdDebounced()
        }
    }
    var userSubstitutions: [UserSubstitutionEntry] = [] {
        didSet { saveDebounced("userSubstitutions_v1", userSubstitutions) }
    }
    func addUserRecipe(_ r: UserRecipe) {
        AppAnalytics.shared.log(.recipeSaved)
        var l = userRecipes; l.append(r); userRecipes = l
        Task { @MainActor in
            StockedKnowledgeBase.shared.learnFromRecipe(r)
            DatabaseSyncBus.shared.publish(.userRecipeAdded(
                title: r.title,
                ingredients: r.ingredients.map { $0.name },
                steps: r.instructions
            ))
        }
    }
    func renameUserRecipe(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var l = userRecipes
        let oldName = l.first(where: { $0.id == id })?.title ?? ""
        if let i = l.firstIndex(where: { $0.id == id }) { l[i].title = trimmed }
        userRecipes = l
        // #9 — follow the rename into the grocery list: any item tagged to this recipe
        // (by stable id, or by the old name for legacy items) gets relabelled.
        if oldName != trimmed {
            let rid = id.uuidString
            var g = groceryItems
            var changed = false
            for idx in g.indices {
                let byId   = !g[idx].recipeId.isEmpty && g[idx].recipeId == rid
                let byName = !oldName.isEmpty && g[idx].recipeSource.contains(oldName)
                guard byId || byName else { continue }
                if !oldName.isEmpty {
                    g[idx].recipeSource = g[idx].recipeSource.replacingOccurrences(of: oldName, with: trimmed)
                }
                if g[idx].recipeId.isEmpty { g[idx].recipeId = rid }
                changed = true
            }
            if changed { groceryItems = g }
        }
        Task { @MainActor in DatabaseSyncBus.shared.publish(.userRecipeUpdated(title: trimmed)) }
    }
    func deleteUserRecipe(id: UUID)     { var l = userRecipes; l.removeAll { $0.id == id }; userRecipes = l }
    func updateUserRecipe(_ r: UserRecipe) {
        guard let idx = userRecipes.firstIndex(where: { $0.id == r.id }) else { return }
        var l = userRecipes; l[idx] = r; userRecipes = l
    }
    /// #5 — when a meal is logged, bump the matching saved recipe's cook count + last-cooked
    /// and hand back its id so the LocalPastMeal can be linked for per-recipe ratings.
    /// Matches on title (case/space-insensitive); returns nil for online/ad-hoc cooks.
    @discardableResult
    func markRecipeCooked(title: String) -> UUID? {
        let key = title.lowercased().trimmingCharacters(in: .whitespaces)
        guard let idx = userRecipes.firstIndex(where: {
            $0.title.lowercased().trimmingCharacters(in: .whitespaces) == key
        }) else { return nil }
        var l = userRecipes
        l[idx].cookCount += 1
        l[idx].lastCooked = Date()
        userRecipes = l
        return l[idx].id
    }
    /// Audit fix — when a meal is cooked, mark the soonest matching *uncooked* planned meal as
    /// cooked, so generateGroceryFromMealPlan() stops counting meals you've already made.
    func markPlannedMealCooked(title: String) {
        let key = title.lowercased().trimmingCharacters(in: .whitespaces)
        let matches = plannedMeals.enumerated().filter {
            !$0.element.isCooked &&
            $0.element.title.lowercased().trimmingCharacters(in: .whitespaces) == key
        }
        guard let target = matches.min(by: { $0.element.dayIndex < $1.element.dayIndex }) else { return }
        var l = plannedMeals
        l[target.offset].isCooked = true
        plannedMeals = l
    }

    // Stats (expiry-aware)
    var stockPercent: Int {
        // Kitchen Goals: once the user defines their staples, report the meaningful ratio of
        // staples-in-stock. Otherwise fall back to average fill level across all items.
        if stockGoalsConfigured && !stockStaples.isEmpty {
            return KitchenStock.percent(staples: stockStaples, inStock: inStockNameSet)
        }
        guard !inventoryItems.isEmpty else { return 0 }
        return Int(finite: safeDivide(inventoryItems.map(\.effectiveLevel).reduce(0,+), by: Double(inventoryItems.count)) * 100)
    }
    /// Staples the user tracks but isn't currently holding (Kitchen Goals) — the natural shop list.
    var stockStaplesLow: [String] {
        guard stockGoalsConfigured else { return [] }
        return KitchenStock.lowStaples(staples: stockStaples, inStock: inStockNameSet)
    }
    /// Per-category Kitchen Goals breakdown (only categories with selected staples).
    var stockByCategory: [KitchenStock.CategoryStatus] {
        KitchenStock.byCategory(staples: stockStaples, inStock: inStockNameSet)
    }
    var availableMeals: Int {
        // #247 — must agree with the Cook Now rail: fully-stocked catalog meals
        // (saved + starters) plus saved AI-generated recipes with nothing missing.
        let catalogReady = cookCatalog.filter { r in
            let m = stockMatch(for: r)
            return m.total > 0 && m.have == m.total
        }.count
        let generatedReady = savedGeneratedRecipes.filter { $0.missingIngredients.isEmpty }.count
        return catalogReady + generatedReady
    }
    var urgentItems: [LocalInventoryItem] {
        inventoryItems.filter {
            ($0.effectiveLevel < KitchenThresholds.lowFillLevel && ($0.zone == "Fridge" || $0.zone == "Freezer")) || $0.isExpiringSoon
        }
        .sorted { $0.effectiveLevel < $1.effectiveLevel }.prefix(5).map { $0 }
    }

    // MARK: - #3 Single source of truth for counts

    /// Canonical "expiring soon" list — every screen's expiring count/preview comes from here.
    var expiringSoonItems: [LocalInventoryItem] {
        inventoryItems
            .filter { $0.isExpiringSoon() }
            .sorted { ($0.daysUntilExpiry ?? 999) < ($1.daysUntilExpiry ?? 999) }
    }
    /// Canonical "running low" list (fill-level lows + below-par), deduped.
    var lowStockItems: [LocalInventoryItem] {
        inventoryItems.filter { $0.isLow }
            .sorted { $0.effectiveLevel < $1.effectiveLevel }
    }
    /// Canonical expired list.
    var expiredItems: [LocalInventoryItem] { inventoryItems.filter(\.isExpired) }

    /// The one metrics snapshot every screen reads. Building it is a few cheap passes.
    var metrics: KitchenMetrics {
        var m = KitchenMetrics()
        m.totalItems        = inventoryItems.count
        m.stockPercent      = stockPercent
        m.mealsReady        = availableMeals
        m.expiringSoonCount = expiringSoonItems.count
        m.expiredCount      = inventoryItems.reduce(0) { $0 + ($1.isExpired ? 1 : 0) }
        m.lowStockCount     = lowStockItems.count
        m.freshCount        = inventoryItems.reduce(0) { acc, it in
            if let d = it.daysUntilExpiry { return acc + (d > KitchenThresholds.expiringSoonDays ? 1 : 0) }
            return acc + (it.effectiveLevel > 0 ? 1 : 0)
        }
        m.groceryToBuy      = groceryItems.reduce(0) { $0 + ($1.isChecked ? 0 : 1) }
        m.groceryRunDays    = groceryRunDays
        return m
    }
    var groceryRunLabel: String {
        let cal = Calendar.current
        let todayWeekday = cal.component(.weekday, from: Date()) - 1
        var daysUntil = (groceryDayOfWeek - todayWeekday + 7) % 7
        if daysUntil == 0 { daysUntil = 7 }
        let daysOut: Int
        switch stockPercent {
        case ..<30: daysOut = 0
        case ..<50: daysOut = min(2, daysUntil)
        case ..<70: daysOut = min(4, daysUntil)
        default:    daysOut = daysUntil
        }
        if daysOut == 0 { return "Recommended Today" }
        guard let date = cal.date(byAdding: .day, value: daysOut, to: Date()) else { return "Recommended soon" }
        let f = StockedFormatters.weekday
        return daysOut == 1 ? "Recommended Tomorrow (\(f.string(from: date)))"
                            : "Recommended in \(daysOut) Days (\(f.string(from: date)))"
    }
    // #245 — split pieces for the brief's "Grocery run in N days / Saturday, May 24" row.
    var groceryRunDays: Int {
        let cal = Calendar.current
        let todayWeekday = cal.component(.weekday, from: Date()) - 1
        var daysUntil = (groceryDayOfWeek - todayWeekday + 7) % 7
        if daysUntil == 0 { daysUntil = 7 }
        switch stockPercent {
        case ..<30: return 0
        case ..<50: return min(2, daysUntil)
        case ..<70: return min(4, daysUntil)
        default:    return daysUntil
        }
    }
    var groceryRunDateText: String {
        guard let date = Calendar.current.date(byAdding: .day, value: groceryRunDays, to: Date()) else { return "Soon" }
        let f = DateFormatter(); f.dateFormat = "EEEE, MMM d"
        return f.string(from: date)
    }

    func readyToCoookRecipes(onlineRecipes: [String] = []) -> [String] {
        // Recipes where every ingredient is in stock (level > 0)
        let stockedNames = Set(inventoryItems.filter { $0.effectiveLevel > 0 }.map { $0.name.lowercased() })
        let fromSaved = savedGeneratedRecipes.filter { recipe in
            recipe.missingIngredients.isEmpty &&
            recipe.ingredients.allSatisfy { ing in stockedNames.contains(ing.name.lowercased()) }
        }.map(\.title)
        let all = Array(Set(fromSaved + onlineRecipes))
        return all.sorted()
    }

    // MARK: - Smart defaults helpers
    func preference(for name: String) -> ItemPreference? {
        itemPreferences[name.lowercased()]
    }
    func recordItemAdded(name: String, zone: String, unit: String, brand: String) {
        let key = name.lowercased()
        var pref = itemPreferences[key] ?? ItemPreference()
        pref.zone  = zone
        pref.unit  = unit.isEmpty ? pref.unit : unit
        pref.brand = brand.isEmpty ? pref.brand : brand
        pref.addCount += 1
        itemPreferences[key] = pref
    }
}

