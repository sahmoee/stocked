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
    @ObservationIgnored private let mutationScheduler = StoreMutationScheduler()
    @ObservationIgnored private let persistenceScheduler = StorePersistenceScheduler()

    /// Coalesce rapid mutations into one widget reload without escaping actor-isolated store
    /// state into a DispatchWorkItem closure.
    private func refreshWidgetsDebounced() {
        mutationScheduler.schedule(.widgetRefresh, delay: .milliseconds(500)) { [weak self] in
            guard let self else { return }
            WidgetBridge.refresh(store: self)
        }
    }

    // Debounced push to the shared HOUSEHOLD (worker-backed, cross-user). Separate from
    // SharedPantrySync (iCloud KV, same Apple ID only, gated off for guests). Without this, a
    // member adding an item never propagated to the household — it just sat locally. Debounced so
    // a burst of edits results in one push after it settles; only pushes when in a household.
    // Set true while HouseholdSync.applyHousehold writes remote data into the store, so the
    // resulting didSets don't echo back out as another push (an infinite sync loop).
    var isApplyingHouseholdRemote = false
    // True only during the in-place updatedAt stamping below, so the re-entrant didSet it causes
    // returns immediately instead of doing all the save/push work a second time.
    private var isStamping = false
    private func pushHouseholdDebounced() {
        guard !isApplyingHouseholdRemote else { return }
        mutationScheduler.schedule(.householdPush, delay: .milliseconds(1_200)) { [weak self] in
            guard let self else { return }
            let household = HouseholdSync.shared
            guard household.state == .owner || household.state == .member else { return }
            await household.syncNow(store: self)
        }
    }

    // Deletion tombstones for household sync: ids removed locally, sent on the next push so the
    // delete propagates to other devices. Persisted locally so an offline delete survives relaunch;
    // only the exact tombstones captured by a confirmed push are removed.
    var pendingInvTombstones: Set<String> = []
    var pendingGroTombstones: Set<String> = []
    var pendingUserRecipeTombstones: Set<String> = []
    var pendingGenRecipeTombstones: Set<String> = []
    var pendingMealTombstones: Set<String> = []

    // Scalar revisions are safe SwiftUI dependencies even though several model arrays contain Data.
    // They advance for local edits and remote household merges, preventing derived UI/cache staleness.
    private(set) var inventoryRevision: Int = 0
    private(set) var groceryRevision: Int = 0
    private(set) var recipeRevision: Int = 0
    private(set) var planRevision: Int = 0

    func householdTombstoneSnapshot() -> HouseholdTombstoneState {
        HouseholdTombstoneState(inventory: pendingInvTombstones,
                                grocery: pendingGroTombstones,
                                userRecipes: pendingUserRecipeTombstones,
                                generatedRecipes: pendingGenRecipeTombstones,
                                plannedMeals: pendingMealTombstones)
    }

    func acknowledgeHouseholdTombstones(_ captured: HouseholdTombstoneState) {
        pendingInvTombstones.subtract(captured.inventory)
        pendingGroTombstones.subtract(captured.grocery)
        pendingUserRecipeTombstones.subtract(captured.userRecipes)
        pendingGenRecipeTombstones.subtract(captured.generatedRecipes)
        pendingMealTombstones.subtract(captured.plannedMeals)
        persistHouseholdTombstones()
    }

    private func persistHouseholdTombstones() {
        LocalDatabase.shared.save(householdTombstoneSnapshot(), key: DBKey.householdTombstones.rawValue)
    }

    var inventoryItems: [LocalInventoryItem] = [] {
        didSet {
            invalidateStockMatches()   // perf: recipe-match cache follows the inventory
            if isStamping { return }   // re-entrant pass from stampChanged: nothing more to do
            inventoryRevision &+= 1
            // Stamp updatedAt on locally-changed items (skip while applying remote data, which
            // already carries authoritative timestamps). Record tombstones for removed ids.
            if !isApplyingHouseholdRemote {
                isStamping = true
                let changedIDs = stampChanged(&inventoryItems, against: oldValue)
                isStamping = false
                let mutation = StoreMutationRecorder.delta(
                    oldIDs: Set(oldValue.map(\.id)), currentIDs: Set(inventoryItems.map(\.id)),
                    changedIDs: changedIDs, entityType: .inventoryItem)
                let oldIDs = mutation.oldIDs
                let goneIDs = mutation.removedIDs
                for id in goneIDs { pendingInvTombstones.insert(id.uuidString) }
                if !goneIDs.isEmpty { persistHouseholdTombstones() }
                HouseholdSync.shared.enqueueBatch(mutation.operations)
                // #3 Household activity feed: announce item changes to the household.
                let newByID = Dictionary(uniqueKeysWithValues: inventoryItems.map { ($0.id, $0) })
                let oldByID = Dictionary(uniqueKeysWithValues: oldValue.map { ($0.id, $0) })
                for id in changedIDs {
                    if let it = newByID[id] {
                        HouseholdSync.shared.emitActivity(oldIDs.contains(id) ? .inventoryUpdated : .inventoryAdded, itemName: it.name)
                    }
                }
                for id in goneIDs { if let it = oldByID[id] { HouseholdSync.shared.emitActivity(.inventoryRemoved, itemName: it.name) } }
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
        let writerID = HouseholdSync.shared.memberId
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        var changed: [UUID] = []
        for i in items.indices {
            if let prev = oldByID[items[i].id] {
                // Compare ignoring updatedAt itself so a re-stamp doesn't loop.
                var a = items[i]; a.updatedAt = 0; a.lastWriterID = ""
                var b = prev;      b.updatedAt = 0; b.lastWriterID = ""
                if a != b { items[i].updatedAt = now; items[i].lastWriterID = writerID; changed.append(items[i].id) }
            } else {
                items[i].updatedAt = now; items[i].lastWriterID = writerID   // new item
                changed.append(items[i].id)
            }
        }
        return changed
    }
    @discardableResult
    private func stampChanged(_ items: inout [LocalGroceryItem], against old: [LocalGroceryItem]) -> [UUID] {
        let now = Date().timeIntervalSince1970 * 1000
        let writerID = HouseholdSync.shared.memberId
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        var changed: [UUID] = []
        for i in items.indices {
            if let prev = oldByID[items[i].id] {
                var a = items[i]; a.updatedAt = 0; a.lastWriterID = ""
                var b = prev;      b.updatedAt = 0; b.lastWriterID = ""
                if a != b { items[i].updatedAt = now; items[i].lastWriterID = writerID; changed.append(items[i].id) }
            } else {
                items[i].updatedAt = now; items[i].lastWriterID = writerID
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
        let writerID = HouseholdSync.shared.memberId
        let enc = JSONEncoder()
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        func bytes(_ r: UserRecipe) -> Data? { var x = r; x.updatedAt = 0; x.lastWriterID = ""; return try? enc.encode(x) }
        var changed: [UUID] = []
        for i in items.indices {
            if let prev = oldByID[items[i].id] {
                if bytes(items[i]) != bytes(prev) { items[i].updatedAt = now; items[i].lastWriterID = writerID; changed.append(items[i].id) }
            } else {
                items[i].updatedAt = now; items[i].lastWriterID = writerID
                changed.append(items[i].id)
            }
        }
        return changed
    }
    private func stampChanged(_ items: inout [GeneratedRecipe], against old: [GeneratedRecipe]) -> [UUID] {
        let now = Date().timeIntervalSince1970 * 1000
        let writerID = HouseholdSync.shared.memberId
        let enc = JSONEncoder()
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        func bytes(_ r: GeneratedRecipe) -> Data? { var x = r; x.updatedAt = 0; x.lastWriterID = ""; return try? enc.encode(x) }
        var changed: [UUID] = []
        for i in items.indices {
            if let prev = oldByID[items[i].id] {
                if bytes(items[i]) != bytes(prev) { items[i].updatedAt = now; items[i].lastWriterID = writerID; changed.append(items[i].id) }
            } else {
                items[i].updatedAt = now; items[i].lastWriterID = writerID
                changed.append(items[i].id)
            }
        }
        return changed
    }
    private func stampChanged(_ items: inout [PlannedMeal], against old: [PlannedMeal]) -> [UUID] {
        let now = Date().timeIntervalSince1970 * 1000
        let writerID = HouseholdSync.shared.memberId
        let oldByID = Dictionary(uniqueKeysWithValues: old.map { ($0.id, $0) })
        var changed: [UUID] = []
        for i in items.indices {
            if let prev = oldByID[items[i].id] {
                var a = items[i]; a.updatedAt = 0; a.lastWriterID = ""
                var b = prev;      b.updatedAt = 0; b.lastWriterID = ""
                if a != b { items[i].updatedAt = now; items[i].lastWriterID = writerID; changed.append(items[i].id) }
            } else {
                items[i].updatedAt = now; items[i].lastWriterID = writerID
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
        groceryRevision &+= 1
        if !isApplyingHouseholdRemote {
            isStamping = true
            let changedIDs = stampChanged(&groceryItems, against: oldValue)
            isStamping = false
            let mutation = StoreMutationRecorder.delta(
                oldIDs: Set(oldValue.map(\.id)), currentIDs: Set(groceryItems.map(\.id)),
                changedIDs: changedIDs, entityType: .groceryItem)
            let oldIDs = mutation.oldIDs
            let goneIDs = mutation.removedIDs
            for id in goneIDs { pendingGroTombstones.insert(id.uuidString) }
            if !goneIDs.isEmpty { persistHouseholdTombstones() }
            HouseholdSync.shared.enqueueBatch(mutation.operations)
            let gNew = Dictionary(uniqueKeysWithValues: groceryItems.map { ($0.id, $0) })
            let gOld = Dictionary(uniqueKeysWithValues: oldValue.map { ($0.id, $0) })
            for id in changedIDs { if let it = gNew[id] { HouseholdSync.shared.emitActivity(oldIDs.contains(id) ? .groceryChecked : .groceryAdded, itemName: it.name) } }
            for id in goneIDs { if let it = gOld[id] { HouseholdSync.shared.emitActivity(.groceryRemoved, itemName: it.name) } }
        }
        saveDebounced(DBKey.groceryItems.rawValue, groceryItems); SharedPantrySync.shared.push(store: self); pushHouseholdDebounced(); refreshWidgetsDebounced() } }
    var itemPreferences:       [String: ItemPreference] = [:] { didSet { saveDebounced("itemPrefs_v1", itemPreferences) } }
    var pastMeals:             [LocalPastMeal]      = [] { didSet { saveDebounced(DBKey.pastMeals.rawValue, pastMeals) } }
    var plannedMeals: [PlannedMeal] = [] {
        didSet {
            invalidateReservedKeys()   // perf: reserved-ingredient cache follows the planner
            if isStamping { return }
            planRevision &+= 1
            if !isApplyingHouseholdRemote {
                isStamping = true
                let changedIDs = stampChanged(&plannedMeals, against: oldValue)
                isStamping = false
                let mutation = StoreMutationRecorder.delta(
                    oldIDs: Set(oldValue.map(\.id)), currentIDs: Set(plannedMeals.map(\.id)),
                    changedIDs: changedIDs, entityType: .plannedMeal)
                let goneIDs = mutation.removedIDs
                for id in goneIDs { pendingMealTombstones.insert(id.uuidString) }
                if !goneIDs.isEmpty { persistHouseholdTombstones() }
                HouseholdSync.shared.enqueueBatch(mutation.operations)
            }
            saveDebounced(DBKey.plannedMeals.rawValue, plannedMeals)
            pushHouseholdDebounced()
        }
    }
    var savedGeneratedRecipes: [GeneratedRecipe] = [] {
        didSet {
            if isStamping { return }
            recipeRevision &+= 1
            if !isApplyingHouseholdRemote {
                isStamping = true
                let changedIDs = stampChanged(&savedGeneratedRecipes, against: oldValue)
                isStamping = false
                let mutation = StoreMutationRecorder.delta(
                    oldIDs: Set(oldValue.map(\.id)), currentIDs: Set(savedGeneratedRecipes.map(\.id)),
                    changedIDs: changedIDs, entityType: .generatedRecipe)
                let oldIDs = mutation.oldIDs
                let goneIDs = mutation.removedIDs
                for id in goneIDs { pendingGenRecipeTombstones.insert(id.uuidString) }
                if !goneIDs.isEmpty { persistHouseholdTombstones() }
                HouseholdSync.shared.enqueueBatch(mutation.operations)
                let rNew = Dictionary(uniqueKeysWithValues: savedGeneratedRecipes.map { ($0.id, $0) })
                for id in changedIDs { if let it = rNew[id] { HouseholdSync.shared.emitActivity(oldIDs.contains(id) ? .recipeUpdated : .recipeAdded, itemName: it.title) } }
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

    init() {
        if let tombstones = LocalDatabase.shared.load(HouseholdTombstoneState.self,
                                                       key: DBKey.householdTombstones.rawValue) {
            pendingInvTombstones = tombstones.inventory
            pendingGroTombstones = tombstones.grocery
            pendingUserRecipeTombstones = tombstones.userRecipes
            pendingGenRecipeTombstones = tombstones.generatedRecipes
            pendingMealTombstones = tombstones.plannedMeals
        }
        load()
    }

    // #2: encode ONCE and reuse the same Data for both the disk write and the
    //     same-session UserDefaults mirror (was encoding the whole array twice).
    // #3: UserDefaults isn't meant for large blobs (degrades/refuses past ~1MB), so
    //     skip the UD mirror above a threshold — disk is the source of truth, and
    //     loadDecoded() falls back to disk when the mirror is absent.
    private static let udMirrorMaxBytes = 256 * 1024   // 256KB
    // #4 — Debounced batched save. didSet handlers mark a key dirty and schedule a flush
    // instead of re-encoding the whole array on every single mutation. A 30-item receipt
    // Collection writes are coalesced by a dedicated collaborator so GuestDataStore owns
    // business state, not debounce-task bookkeeping. The final value for each key wins.
    /// Force any pending debounced saves to disk immediately (called on background/terminate).
    func flushPendingSaves() { persistenceScheduler.flush() }
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
        persistenceScheduler.schedule(key: key) { [weak self] in self?.save(key, value: value) }
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
        persistenceScheduler.cancel()

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

        // Resetting the observable collections above intentionally fires their didSet hooks.
        // Cancel those newly queued empty-state writes before deleting the backing stores so
        // Clear All leaves no delayed persistence work behind.
        persistenceScheduler.cancel()

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
        // #GQ — manual adds of an existing item bump its quantity instead of being
        // silently dropped: recipe 4 + recipe 3 + manual 1 = one row showing 8.
        if GroceryDedup.isDuplicate(name, in: groceryItems.map { $0.name }) {
            let key = GroceryConsolidator.normalizeKey(name)
            if let idx = groceryItems.firstIndex(where: { GroceryConsolidator.normalizeKey($0.name) == key }) {
                withAnimation { groceryItems[idx].quantity += 1 }
            }
            return
        }
        // #D2 duplicate-purchase guard — if it's already stocked, say so (still adds:
        // buying more can be intentional, but "you have 2 already" prevents the classic
        // three-cans-of-chickpeas mistake).
        let key = Self.mergeKey(name)
        if !key.isEmpty,
           let have = inventoryItems.first(where: { Self.mergeKey($0.name) == key && $0.level > 0.15 }) {
            let count = have.quantity
            ToastCenter.shared.success(count > 1
                ? "Heads up — you already have \(count) \(have.name.displayNormalized) in stock"
                : "Heads up — \(have.name.displayNormalized) is already in stock")
        }
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
        // Memoized: rebuilt only after the inventory changes (see invalidateStockMatches).
        // The Discover rails and recipe badges read this repeatedly per render.
        if let hit = inStockNamesCache { return hit }
        let set = Set(inventoryItems.filter { $0.level > 0 }.map { $0.name.lowercased() })
        inStockNamesCache = set
        return set
    }

    /// #5 — push a recipe's ingredients to the grocery list: skip anything already in
    /// stock, consolidate duplicates (bump quantity + append the recipe as a source),
    /// and tag new lines with the recipe. Skips ingredients marked optional. Returns the
    /// number of NEW lines added (0 = everything was already on the list or in stock).
    @discardableResult
    /// #C4/#GQ — scale-aware AND quantity-aware: each ingredient contributes its own count
    /// ("4 onions" adds 4, not 1), multiplied by the serving scale. Measured ingredients
    /// ("2 cups flour", "14 oz sauce") add as ONE unit to buy but carry their size for
    /// display. Merging into an existing row sums counts, so Recipe A's 4 onions plus
    /// Recipe B's 3 plus a manual 1 shows 8.
    func addRecipeIngredientsToGrocery(_ ingredients: [RecipeIngredient], recipeName: String, scale: Double = 1) -> Int {
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
                var contribution = Self.groceryContribution(for: ing, scale: scale)
                // Amounts baked into the ingredient NAME ("6 corn tortillas", "14 oz jar
                // Enchilada sauce") split apart here so the stored name is clean and the
                // count/size land in their proper fields.
                var cleanName = n
                let parsed = GroceryNameParser.parse(n)
                if parsed.name != n {
                    cleanName = parsed.name
                    if let c = parsed.count, contribution.count <= Int(scale.rounded(.up)) {
                        contribution.count = max(1, Int((Double(c) * scale).rounded(.up)))
                    }
                    if contribution.sizeText.isEmpty { contribution.sizeText = parsed.sizeText }
                }
                let key = GroceryConsolidator.normalizeKey(cleanName)
                if let idx = groceryItems.firstIndex(where: { GroceryConsolidator.normalizeKey($0.name) == key }) {
                    groceryItems[idx].quantity += contribution.count
                    if groceryItems[idx].sizeText.isEmpty, !contribution.sizeText.isEmpty {
                        groceryItems[idx].sizeText = contribution.sizeText
                    }
                    if !recipe.isEmpty, !groceryItems[idx].recipeSource.contains(recipe) {
                        groceryItems[idx].recipeSource += groceryItems[idx].recipeSource.isEmpty ? recipe : ", \(recipe)"
                    }
                    if groceryItems[idx].recipeId.isEmpty { groceryItems[idx].recipeId = rid }   // #9
                } else {
                    var item = LocalGroceryItem(name: cleanName, isChecked: false, recipeSource: recipe, recipeId: rid)
                    item.quantity = contribution.count
                    item.sizeText = contribution.sizeText
                    groceryItems.append(item)
                    added += 1
                }
            }
        }
        return added
    }

    /// How an ingredient lands on the grocery list: a whole-unit count plus an optional
    /// measured size string. "4 onions" → (4, ""). "2 large eggs" → (2, ""). "14 oz
    /// enchilada sauce" → (1, "14 oz"): you buy one can, sized 14 oz. Counts multiply by
    /// the serving scale and round up; everything defaults to (1, "").
    nonisolated static func groceryContribution(for ing: RecipeIngredient, scale: Double)
        -> (count: Int, sizeText: String) {
        let measuredUnits: Set<String> = ["g","kg","oz","lb","lbs","ml","l","cup","cups","tbsp","tsp",
                                          "quart","quarts","pint","pints","gallon","gallons","fl oz",
                                          "gram","grams","ounce","ounces","pound","pounds","liter","liters"]
        let unit = (ing.unit ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        // Numeric amount: structured quantity first, else leading number in the amount string.
        var qty = ing.quantity
        if qty == nil {
            let amt = ing.amount.trimmingCharacters(in: .whitespaces)
            if let match = amt.split(separator: " ").first, let d = Double(match) { qty = d }
        }
        if !unit.isEmpty, measuredUnits.contains(unit) {
            // Measured → one unit to buy; the size travels for display.
            let size = ing.amount.trimmingCharacters(in: .whitespaces)
            return (max(1, Int(scale.rounded(.up))), size)
        }
        if let q = qty, q > 0, q <= 50 {   // sanity cap: "500 g" mis-parsed as count stays 1
            return (max(1, Int((q * scale).rounded(.up))), "")
        }
        return (max(1, Int(scale.rounded(.up))), "")
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
        RecipeInterest.shared.record(category: "generated", area: saved.cuisine,
                                     ingredients: saved.ingredients.map(\.name), event: .saved)
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
        RecipeInterest.shared.record(category: recipe.category, area: recipe.area,
                                     ingredients: saved.ingredients.map(\.name), event: .saved)
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
                inventoryItems[idx].lastConfirmedAt = Date()   // restock confirms it's here
                // #B2 unit-aware math: when both rows carry a size and the units are
                // convertible ("500 g" + "1 lb"), keep the existing row's unit and sum.
                if let curAmt = inventoryItems[idx].sizeAmount,
                   let curUnit = inventoryItems[idx].sizeUnit,
                   let newAmt = item.sizeAmount, let newUnit = item.sizeUnit,
                   let converted = UnitMath.convert(newAmt, from: newUnit, to: curUnit) {
                    inventoryItems[idx].sizeAmount = curAmt + converted
                }
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
        var stamped = item
        stamped.lastConfirmedAt = Date()   // freshly added = freshly confirmed
        withAnimation { inventoryItems.append(stamped) }
        // #B4 crowd shelf-life defaults — when the item arrives with no expiry, ask the
        // anonymized crowd DB how long this item typically lasts and fill a sensible
        // default. Applies only if the user still hasn't set a date by the time the
        // suggestion returns; any failure is silent.
        if stamped.expirationDate == nil {
            let newID = stamped.id
            Task { @MainActor [weak self] in
                guard let self,
                      let i = self.inventoryIndex(of: newID),
                      self.inventoryItems[i].expirationDate == nil else { return }
                let suggestion = await CrowdDB.suggest(name: stamped.name)
                let estimate = ShelfLifeEstimator.estimate(
                    name: stamped.name,
                    zone: stamped.storageCategory,
                    from: stamped.purchaseDate ?? Date(),
                    crowdDays: suggestion?.avgShelfLifeDays
                )
                if let date = estimate.date,
                   let currentIndex = self.inventoryIndex(of: newID),
                   self.inventoryItems[currentIndex].expirationDate == nil {
                    self.inventoryItems[currentIndex].expirationDate = date
                }
            }
        } else if let exp = stamped.expirationDate {
            // Contribute this item's real shelf window back to the crowd (opt-out honored
            // inside reportShelfLife). Purchase date defaults to today for a fresh add.
            let bought = stamped.purchaseDate ?? Date()
            let days = exp.timeIntervalSince(bought) / 86400
            let name = stamped.name
            Task { await CrowdDB.reportShelfLife(name: name, days: days) }
        }
    }

    /// #B1 — conservative canonical merge key: case/whitespace/punctuation-insensitive
    /// with a trailing-plural fold, so "Chicken Breasts" merges with "chicken breast".
    /// Deliberately NOT IngredientMatcher.canonical (that maps cheddar→cheese, which is
    /// right for recipe matching but would wrongly merge distinct products in inventory).
    nonisolated static func mergeKey(_ raw: String) -> String {
        var s = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Plural fold: drop "es" only after sibilant endings (boxes, dishes, tomatoes
        // stay linguistically wrong but symmetric); otherwise drop a single trailing
        // "s" (pancakes→pancake) while leaving "ss" words (glass) alone.
        if s.count > 4, ["ses", "xes", "zes", "ches", "shes", "oes"].contains(where: { s.hasSuffix($0) }) {
            s = String(s.dropLast(2))
        } else if s.hasSuffix("s"), !s.hasSuffix("ss"), s.count > 3 {
            s = String(s.dropLast(1))
        }
        return s
    }

    /// Two items are "the same" for merging if their names share a merge key and their
    /// units are compatible: identical, both absent, or convertible within the same
    /// measurement family (mass/volume via UnitMath). #18 still keeps "2 cans" from
    /// merging into "3 lbs".
    static func isSameItem(_ a: LocalInventoryItem, _ b: LocalInventoryItem) -> Bool {
        guard mergeKey(a.name) == mergeKey(b.name), !mergeKey(a.name).isEmpty else { return false }
        let ua = a.sizeUnit?.lowercased() ?? ""
        let ub = b.sizeUnit?.lowercased() ?? ""
        if ua == ub { return true }
        if ua.isEmpty || ub.isEmpty { return false }   // one measured, one not → keep separate
        return UnitMath.convertible(ua, ub)
    }
    func updateInventoryLevel(id: UUID, level: Double) {
        if let i = inventoryIndex(of: id) {   // #5 — O(1) lookup instead of firstIndex scan
            let was = inventoryItems[i].level
            withAnimation { inventoryItems[i].level = level }
            inventoryItems[i].lastConfirmedAt = Date()   // #A3 — touching the level confirms it's real
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

    // MARK: - Reserved for planned meals (#B3)

    /// Merge keys of ingredients committed to uncooked planned meals, so surfaces can
    /// show "planned" on items that look free but are spoken for.
    /// Merge keys of ingredients committed to uncooked planned meals. CACHED: the set is
    /// rebuilt lazily after any plannedMeals change instead of per call — inventory rows
    /// ask about it once per row per render, which made the computed version O(rows ×
    /// meals × ingredients) every frame.
    private var reservedKeysCache: Set<String>? = nil
    var reservedIngredientKeys: Set<String> {
        if let cached = reservedKeysCache { return cached }
        var keys = Set<String>()
        for meal in plannedMeals where !meal.isCooked {
            for ing in meal.ingredients {
                let k = Self.mergeKey(ing)
                if !k.isEmpty { keys.insert(k) }
            }
        }
        reservedKeysCache = keys
        return keys
    }
    /// Call whenever plannedMeals changes (didSet) so the next read rebuilds.
    func invalidateReservedKeys() { reservedKeysCache = nil }

    /// Whether this inventory item is an ingredient of an upcoming planned meal.
    func isReservedForMeal(_ item: LocalInventoryItem) -> Bool {
        let key = Self.mergeKey(item.name)
        guard !key.isEmpty else { return false }
        // Loose containment both ways so "chicken" reserves "chicken breast" and vice versa.
        return reservedIngredientKeys.contains(where: { $0.contains(key) || key.contains($0) })
    }

    // MARK: - Waste post-mortem (#D3)

    /// Most recent wasted item this week with no reason recorded — the Daily Brief asks
    /// one short "what happened?" so par levels and coaching can learn from the answer.
    var unexplainedWaste: ConsumptionRecord? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return consumptionLog.last(where: { $0.wasted && $0.wasteReason == nil && $0.depletedAt > cutoff })
    }

    func setWasteReason(recordID: UUID, reason: String) {
        if let i = consumptionLog.firstIndex(where: { $0.id == recordID }) {
            consumptionLog[i].wasteReason = reason
        }
    }

    // MARK: - Household role gating (#E3)

    /// Kids can use up and add, but not delete inventory — deletion asks an adult.
    /// Returns true when the current member may remove items.
    private var canDeleteInventory: Bool {
        let role = HouseholdSync.shared.myAccessRole
        return role != .kid
    }

    // MARK: - Siri "I used X" handoff (#drift)

    /// Names queued by the MarkItemUsedIntent (which runs outside the app's data layer).
    /// Drained on foreground: matching items are marked used (level 0, consumption logged).
    static let pendingUsedKey = "stocked.pendingUsedItems"
    static let pendingAddKey  = "stocked.pendingAddItems"

    func drainPendingUsedItems() {
        let ud = UserDefaults.standard
        // Adds first, then depletions — "add milk, used the old milk" resolves sanely.
        if let adds = ud.stringArray(forKey: Self.pendingAddKey), !adds.isEmpty {
            ud.removeObject(forKey: Self.pendingAddKey)
            var addedNames: [String] = []
            for raw in adds {
                let name = raw.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { continue }
                addInventoryItem(LocalInventoryItem(name: name.displayNormalized))
                addedNames.append(name.displayNormalized)
            }
            if !addedNames.isEmpty {
                ToastCenter.shared.success(addedNames.count == 1
                    ? "Added \(addedNames[0]) (from Siri)"
                    : "Added \(addedNames.count) items (from Siri)")
            }
        }
        guard let names = ud.stringArray(forKey: Self.pendingUsedKey), !names.isEmpty else { return }
        ud.removeObject(forKey: Self.pendingUsedKey)
        var marked: [String] = []
        for raw in names {
            let key = Self.mergeKey(raw)
            guard !key.isEmpty,
                  let item = inventoryItems.first(where: { Self.mergeKey($0.name) == key && $0.level > 0 })
            else { continue }
            updateInventoryLevel(id: item.id, level: 0)
            marked.append(item.name.displayNormalized)
        }
        if !marked.isEmpty {
            ToastCenter.shared.success(marked.count == 1
                ? "Marked \(marked[0]) as used (from Siri)"
                : "Marked \(marked.count) items as used (from Siri)")
        }
    }

    // MARK: - Staleness / Pantry Check (#A2/#A3 drift-proofing)

    /// Days after which an unconfirmed item is considered stale (the app is no longer
    /// sure it's really in the kitchen). Perishables go stale faster than pantry goods.
    nonisolated static func staleWindowDays(for item: LocalInventoryItem) -> Int {
        switch item.storageCategory {
        case .fridge:  return 10
        case .freezer: return 45
        default:       return 30
        }
    }

    /// The reference date for staleness: last explicit confirmation, else purchase date.
    /// Items with neither are treated as fresh (legacy data shouldn't all flag at once).
    nonisolated static func staleness(of item: LocalInventoryItem) -> Int? {
        guard let anchor = item.lastConfirmedAt ?? item.purchaseDate else { return nil }
        return Calendar.current.dateComponents([.day], from: anchor, to: Date()).day
    }

    /// Whether the app should ask about this item ("Still have this?").
    nonisolated static func isStale(_ item: LocalInventoryItem) -> Bool {
        guard item.level > 0, let days = staleness(of: item) else { return false }
        return days >= staleWindowDays(for: item)
    }

    /// Up to `limit` stale items, most-overdue first — feeds the Daily Brief Pantry Check.
    func staleItems(limit: Int = 3) -> [LocalInventoryItem] {
        inventoryItems
            .filter { Self.isStale($0) && !isSnoozed($0.id) }
            .sorted { (Self.staleness(of: $0) ?? 0) > (Self.staleness(of: $1) ?? 0) }
            .prefix(limit).map { $0 }
    }

    /// Pantry Check "Yes, still have it" — refreshes the confirmation stamp.
    func confirmInventoryItem(id: UUID) {
        if let i = inventoryIndex(of: id) {
            withAnimation { inventoryItems[i].lastConfirmedAt = Date() }
        }
    }

    func removeInventoryItem(id: UUID) {
        // #E3 — kid household members can't delete inventory; they can still mark items
        // used or add to the grocery list. Silent data loss is worse than a nudge.
        guard canDeleteInventory else {
            ToastCenter.shared.warning("Ask a household adult to delete items")
            return
        }
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
    /// #16 Remove several inventory items with an Undo toast. Captures the removed items and
    /// restores them (with their original ids) if the user taps Undo before the toast expires.
    func removeInventoryItems(ids: [UUID], label: String? = nil) {
        // #E3 — same kid-role guard as single deletion.
        guard canDeleteInventory else {
            ToastCenter.shared.warning("Ask a household adult to delete items")
            return
        }
        let removed = inventoryItems.filter { ids.contains($0.id) }
        guard !removed.isEmpty else { return }
        withAnimation { inventoryItems.removeAll { ids.contains($0.id) } }
        let msg = label ?? "Removed \(removed.count) item\(removed.count == 1 ? "" : "s")"
        ToastCenter.shared.undo(msg) { [weak self] in
            guard let self else { return }
            withAnimation { self.inventoryItems.append(contentsOf: removed) }
        }
    }
    /// #12 Score a set of recipe ingredient names by how many are currently in inventory (0…1).
    /// Uses canonical matching so "roma tomatoes" counts against "tomato". Returns the fraction of
    /// the recipe's ingredients you already have, so callers can rank "cook from what I have".
    func inventoryMatchScore(ingredientNames: [String]) -> Double {
        guard !ingredientNames.isEmpty else { return 0 }
        let have = Set(inventoryItems.filter { $0.level > 0 }.map { IngredientMatcher.canonical($0.name) })
        let haveWords = Set(inventoryItems.filter { $0.level > 0 }
            .flatMap { $0.name.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init) })
        var matched = 0
        for raw in ingredientNames {
            let canon = IngredientMatcher.canonical(raw)
            let words = Set(raw.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init))
            if have.contains(canon) || !words.isDisjoint(with: haveWords) { matched += 1 }
        }
        return Double(matched) / Double(ingredientNames.count)
    }
    /// Convenience: user recipes ranked best-match first, with their score.
    func userRecipesByAvailability() -> [(recipe: UserRecipe, score: Double)] {
        userRecipes.map { ($0, inventoryMatchScore(ingredientNames: $0.ingredients.map(\.name))) }
            .sorted { $0.1 > $1.1 }
    }

    /// #10 Predict which staples are due to run out soon, from consumption history. For each item
    /// name, estimate the average days between depletions; if it's been longer than that since the
    /// last depletion and it isn't currently stocked, it's a candidate to pre-add to grocery.
    /// Returns item names sorted by how overdue they are. Read-only; callers decide what to add.
    /// #9 Estimate a use-by date for an item that was added without one, from a shelf-life table
    /// keyed by name keyword then storage zone. Returns nil for shelf-stable staples so we don't
    /// invent expiry where none applies. Callers apply it only when the user left the field empty.
    func estimatedUseBy(forName name: String, zone: String, from date: Date = Date()) -> Date? {
        let canonical = IngredientMatcher.canonical(name)
        let learned = consumptionLog.compactMap { record -> Double? in
            guard !record.wasted,
                  FoodNameMatcher.matches(canonical, record.itemName).score >= 0.78 else { return nil }
            return record.daysLasted
        }
        let learnedDays: Double? = {
            guard learned.count >= 2 else { return nil }
            let sorted = learned.sorted()
            return sorted[sorted.count / 2]   // median resists one unusually short/long cycle
        }()
        return ShelfLifeEstimator.estimate(
            name: name,
            zone: StorageCategory(rawValue: zone) ?? .pantry,
            from: date,
            learnedDays: learnedDays
        ).date
    }

    /// #14 Turn a cooked recipe's output into a tracked leftover in the Fridge, with a short
    /// use-by so it shows up in expiring-soon. Call after cooking to close the Cook→Inventory loop.
    func addLeftover(named title: String, servings: Int = 1) {
        var item = LocalInventoryItem(name: "Leftover: \(title)", level: 1.0, zone: "Fridge",
                                      quantity: max(1, servings))
        item.storageCategory = .fridge
        item.expirationDate = Calendar.current.date(byAdding: .day, value: 4, to: Date())
        item.purchaseDate = Date()
        addInventoryItem(item)
        ToastCenter.shared.success("Saved leftovers to your Fridge")
    }

    func predictedRunningLow(limit: Int = 10) -> [String] {
        // Group depletion dates by item.
        var byItem: [String: [Date]] = [:]
        for rec in consumptionLog where !rec.wasted {
            byItem[rec.itemName, default: []].append(rec.depletedAt)
        }
        let stockedNames = Set(inventoryItems.filter { $0.level > 0 }.map { IngredientMatcher.canonical($0.name) })
        let now = Date()
        var scored: [(name: String, overdueDays: Double)] = []
        for (name, datesRaw) in byItem {
            let dates = datesRaw.sorted()
            guard dates.count >= 2 else { continue }              // need a couple of cycles
            if stockedNames.contains(IngredientMatcher.canonical(name)) { continue }  // already have it
            // Average interval between depletions.
            var gaps: [Double] = []
            for i in 1..<dates.count { gaps.append(dates[i].timeIntervalSince(dates[i-1]) / 86400) }
            let avg = gaps.reduce(0, +) / Double(gaps.count)
            guard avg > 0, let last = dates.last else { continue }
            let sinceLast = now.timeIntervalSince(last) / 86400
            if sinceLast >= avg * 0.9 {                           // due (within 10%) or overdue
                scored.append((name, sinceLast - avg))
            }
        }
        return scored.sorted { $0.overdueDays > $1.overdueDays }.prefix(limit).map { $0.name }
    }

    func deductIngredients(_ ingredients: [String]) {        for ingredient in ingredients {
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

    /// How much of a recipe you can make right now: (have, total) over non-optional
    /// ingredients. MEMOIZED: this is ingredients x inventory string matching, and it
    /// gets called from sort comparators and per-row in the recipe grids — uncached it
    /// was the app's single biggest scroll/freeze cost. The cache clears whenever the
    /// inventory or the recipes change.
    private var stockMatchCache: [UUID: (have: Int, total: Int)] = [:]
    private var inStockNamesCache: Set<String>? = nil
    func invalidateStockMatches() {
        stockMatchCache.removeAll(keepingCapacity: true)
        inStockNamesCache = nil
    }

    func stockMatch(for recipe: UserRecipe) -> (have: Int, total: Int) {
        if let hit = stockMatchCache[recipe.id] { return hit }
        let needed = recipe.ingredients.filter { !$0.isOptional }
        guard !needed.isEmpty else { stockMatchCache[recipe.id] = (0, 0); return (0, 0) }
        let have = needed.filter { ingredientInStock($0.name) }.count
        let result = (have, needed.count)
        stockMatchCache[recipe.id] = result
        return result
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
            invalidateStockMatches()   // perf: recipe edits change their own match
            if isStamping { return }
            recipeRevision &+= 1
            if !isApplyingHouseholdRemote {
                isStamping = true
                let changedIDs = stampChanged(&userRecipes, against: oldValue)
                isStamping = false
                let mutation = StoreMutationRecorder.delta(
                    oldIDs: Set(oldValue.map(\.id)), currentIDs: Set(userRecipes.map(\.id)),
                    changedIDs: changedIDs, entityType: .userRecipe)
                let oldIDs = mutation.oldIDs
                let goneIDs = mutation.removedIDs
                for id in goneIDs { pendingUserRecipeTombstones.insert(id.uuidString) }
                if !goneIDs.isEmpty { persistHouseholdTombstones() }
                HouseholdSync.shared.enqueueBatch(mutation.operations)
                let urNew = Dictionary(uniqueKeysWithValues: userRecipes.map { ($0.id, $0) })
                for id in changedIDs { if let it = urNew[id] { HouseholdSync.shared.emitActivity(oldIDs.contains(id) ? .recipeUpdated : .recipeAdded, itemName: it.title) } }
            }
            saveDebounced(DBKey.userRecipes.rawValue, userRecipes)
            pushHouseholdDebounced()
        }
    }
    var userSubstitutions: [UserSubstitutionEntry] = [] {
        didSet { saveDebounced("userSubstitutions_v1", userSubstitutions) }
    }
    func addUserRecipe(_ recipeIn: UserRecipe) {
        // Every save funnel (create form, web import, share extension, AI generator)
        // passes through here, so blank/whitespace steps are dropped once, centrally —
        // no recipe can render an empty numbered instruction row.
        var r = recipeIn
        r.instructions = r.instructions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        // #C2 — auto-route broken imports through the AI cleanup pipeline. Heuristic:
        // no usable steps despite real content, or one giant unsplit blob. Runs in the
        // background and only applies if the recipe still exists and the fix is usable —
        // the user sees the raw version instantly and it quietly improves moments later.
        let looksBroken = (r.instructions.isEmpty && !r.description.isEmpty)
            || (r.instructions.count == 1 && (r.instructions.first?.count ?? 0) > 350)
        if looksBroken, RecipeImportAI.isAvailable {
            let recipeID = r.id
            let raw = RecipeImportAI.composeRawText(
                title: r.title, description: r.description,
                ingredients: r.ingredients.map { $0.amount.isEmpty ? $0.name : "\($0.amount) \($0.name)" },
                steps: r.instructions)
            Task { @MainActor [weak self] in
                guard let ai = await RecipeImportAI.structure(rawText: raw), ai.isUsable else { return }
                let cleaned = ai.steps
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                guard cleaned.count >= 2, let self,
                      var current = self.userRecipes.first(where: { $0.id == recipeID }) else { return }
                current.instructions = cleaned
                self.updateUserRecipe(current)
            }
        }
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
    func updateUserRecipe(_ recipeIn: UserRecipe) {
        var r = recipeIn
        r.instructions = r.instructions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
        RecipeInterest.shared.record(category: "saved", area: l[idx].cuisine,
                                     ingredients: l[idx].ingredients.map(\.name), event: .completed)
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
