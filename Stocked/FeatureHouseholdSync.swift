// FeatureHouseholdSync.swift — Launch readiness 1.4: the new feature data syncs across the household.
//
// Before this, the eight feature collections (leftovers, family profiles, events, shared costs,
// store layouts, garden harvests, container labels, takeout log) were device-local while the app's
// core data synced. Shared Costs was the sharp edge: two roommates splitting a bill each saw a
// different ledger. A shared fridge's leftovers and labels have the same problem.
//
// Design: ONE generic layer instead of eight copies of the per-collection pattern.
//   • Every synced model gains `updatedAt`/`lastWriterID` (defaulted → decode-safe with old data).
//   • Entries are stamped at mutation time (in each store's add/update funcs), not in `didSet`,
//     which avoids the didSet-mutates-itself recursion the core store has to guard against.
//   • Removals record per-collection tombstones so a delete can't resurrect on the next pull.
//   • Push rides the EXISTING `/household/push` body — one extra key per collection — and pull
//     merges per-id LWW with the same `HouseholdMergePolicy` the core collections use.
//   • The Worker merges these with the same `mergeLWW` it already applies to inventory (see the
//     FEATURE_COLLECTIONS loop added in household-do.js).
//
// Deliberately NOT synced (personal to a device/person, not a household):
//   toolbox usage ranking, notification engagement, sync-conflict log, region preference.

import Foundation

// MARK: - Conformance

/// A feature model that can ride the household sync. All eight feature models conform.
nonisolated protocol HouseholdSyncable: Codable, Identifiable, Sendable where ID == UUID {
    var id: UUID { get }
    var updatedAt: Double { get set }      // epoch ms, same convention as LocalInventoryItem
    var lastWriterID: String { get set }
}

// MARK: - Core

@MainActor
@Observable
final class FeatureSync {
    static let shared = FeatureSync()
    private init() { loadTombstones() }

    /// True while a pull is being applied, so stores can skip re-stamping/re-tombstoning.
    private(set) var isApplyingRemote = false

    // ── Backup bridge ────────────────────────────────────────────────────

    /// The feature persistence owners expose one value snapshot to KitchenTransferManager;
    /// the transfer layer does not reach into or duplicate their on-disk stores.
    func backupSnapshot() -> KitchenFeatureSnapshot {
        KitchenFeatureSnapshot(
            leftovers: LeftoversStore.shared.entries,
            familyProfiles: FamilyProfileStore.shared.profiles,
            events: EventStore.shared.events,
            sharedExpenses: SplitStore.shared.expenses,
            splitPeople: SplitStore.shared.people,
            storeLayouts: StoreLayoutStore.shared.layouts,
            activeStore: StoreLayoutStore.shared.activeStore,
            gardenHarvests: HarvestStore.shared.entries,
            containerLabels: ContainerLabelStore.shared.labels,
            takeoutLog: TakeoutStore.shared.entries,
            scheduledMeals: PlanAheadStore.shared.scheduledMeals,
            mealPlanRules: PlanAheadStore.shared.rules,
            mealPlanTemplates: PlanAheadStore.shared.templates,
            smartCookbooks: SmartCookbookStore.shared.rules
        )
    }

    /// Apply a validated backup under the same side-effect suppression used by household pulls.
    /// This prevents a restore from creating tombstones or echoing an outbound sync operation.
    func restoreBackupSnapshot(_ snapshot: KitchenFeatureSnapshot, merge: Bool) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        PlanAheadStore.shared.clearUndo()

        if merge {
            LeftoversStore.shared.entries = backupMerge(LeftoversStore.shared.entries, snapshot.leftovers)
            FamilyProfileStore.shared.profiles = backupMerge(FamilyProfileStore.shared.profiles, snapshot.familyProfiles)
            EventStore.shared.events = backupMerge(EventStore.shared.events, snapshot.events)
            SplitStore.shared.expenses = backupMerge(SplitStore.shared.expenses, snapshot.sharedExpenses)
            SplitStore.shared.people = stableStringUnion(SplitStore.shared.people, snapshot.splitPeople)
            StoreLayoutStore.shared.layouts = backupMergeLayouts(StoreLayoutStore.shared.layouts, snapshot.storeLayouts)
            if StoreLayoutStore.shared.activeStore.isEmpty {
                StoreLayoutStore.shared.activeStore = snapshot.activeStore
            }
            HarvestStore.shared.entries = backupMerge(HarvestStore.shared.entries, snapshot.gardenHarvests)
            ContainerLabelStore.shared.labels = backupMerge(ContainerLabelStore.shared.labels, snapshot.containerLabels)
            TakeoutStore.shared.entries = backupMerge(TakeoutStore.shared.entries, snapshot.takeoutLog)
        } else {
            LeftoversStore.shared.entries = snapshot.leftovers
            FamilyProfileStore.shared.profiles = snapshot.familyProfiles
            EventStore.shared.events = snapshot.events
            SplitStore.shared.expenses = snapshot.sharedExpenses
            SplitStore.shared.people = snapshot.splitPeople
            StoreLayoutStore.shared.layouts = snapshot.storeLayouts
            StoreLayoutStore.shared.activeStore = snapshot.activeStore
            HarvestStore.shared.entries = snapshot.gardenHarvests
            ContainerLabelStore.shared.labels = snapshot.containerLabels
            TakeoutStore.shared.entries = snapshot.takeoutLog
        }

        if let rows = snapshot.scheduledMeals {
            PlanAheadStore.shared.scheduledMeals = merge ? backupMerge(PlanAheadStore.shared.scheduledMeals, rows) : rows
        }
        if let rows = snapshot.mealPlanRules {
            PlanAheadStore.shared.rules = merge ? backupMerge(PlanAheadStore.shared.rules, rows) : rows
        }
        if let rows = snapshot.mealPlanTemplates {
            PlanAheadStore.shared.templates = merge ? backupMerge(PlanAheadStore.shared.templates, rows) : rows
        }
        if let rows = snapshot.smartCookbooks {
            SmartCookbookStore.shared.rules = merge ? backupMerge(SmartCookbookStore.shared.rules, rows) : rows
        }

        LeftoversStore.shared.flush()
        FamilyProfileStore.shared.flush()
        EventStore.shared.flush()
        SplitStore.shared.flush()
        StoreLayoutStore.shared.flush()
        HarvestStore.shared.flush()
        ContainerLabelStore.shared.flush()
        TakeoutStore.shared.flush()
        PlanAheadStore.shared.flush()
        SmartCookbookStore.shared.flush()
    }

    private func backupMerge<T: HouseholdSyncable>(_ local: [T], _ incoming: [T]) -> [T] {
        var known = Set(local.map(\.id))
        var merged = local
        for value in incoming where known.insert(value.id).inserted { merged.append(value) }
        return merged
    }

    private func backupMergeLayouts(_ local: [StoreLayout], _ incoming: [StoreLayout]) -> [StoreLayout] {
        var known = Set(local.map { $0.store.lowercased() })
        var merged = local
        for value in incoming where known.insert(value.store.lowercased()).inserted { merged.append(value) }
        return merged
    }

    private func stableStringUnion(_ local: [String], _ incoming: [String]) -> [String] {
        var known = Set(local.map { $0.lowercased() })
        var merged = local
        for value in incoming where known.insert(value.lowercased()).inserted { merged.append(value) }
        return merged
    }

    // ── Wipe (FR-01 fix, point 5) ─────────────────────────────────────────────

    /// Reset every in-memory feature store to empty and clear sync bookkeeping, WITHOUT enqueuing
    /// pushes or tombstones. `GuestDataStore.clearAll()` already deletes the on-disk files; this
    /// clears the live singletons so a later mutation or `flushAll()` can't re-persist stale data —
    /// the "partial resurrection" gap. Runs under `isApplyingRemote` so the stores' didSet is a
    /// plain (empty) save with no side effects.
    func wipeAll() {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        PlanAheadStore.shared.clearUndo()
        tombstones = [:]
        tombstoneRevisions = [:]
        tombstoneDeletedAt = [:]
        saveTombstones()
        LeftoversStore.shared.entries      = []
        FamilyProfileStore.shared.profiles = []
        EventStore.shared.events           = []
        SplitStore.shared.expenses         = []
        SplitStore.shared.people           = []
        StoreLayoutStore.shared.layouts    = []
        StoreLayoutStore.shared.activeStore = ""
        HarvestStore.shared.entries        = []
        ContainerLabelStore.shared.labels  = []
        TakeoutStore.shared.entries        = []
        HouseholdCookStore.shared.entries  = []
        PlanAheadStore.shared.scheduledMeals = []
        PlanAheadStore.shared.rules = []
        PlanAheadStore.shared.templates = []
        SmartCookbookStore.shared.rules = []
    }

    // ── Stamping ─────────────────────────────────────────────────────────────

    /// Stamp an entry as edited-here-now. Call at every mutation site before writing it back.
    nonisolated static func stamped<T: HouseholdSyncable>(_ entry: T) -> T {
        var e = entry
        e.updatedAt = Date().timeIntervalSince1970 * 1000
        e.lastWriterID = UserDefaults.standard.string(forKey: "hh_member_id") ?? ""
        return e
    }

    // ── Mutation observation ─────────────────────────────────────────────────

    /// Given a store's previous and current arrays, return the array with new/edited entries
    /// stamped, and record tombstones for removals + nudge the push loop as a side effect.
    ///
    /// CRASH FIX (build 65): this used to take `new: inout [T]` and was passed `&entries` from
    /// inside `entries.didSet`. Taking an @Observable property as `inout` re-enters its `modify`
    /// accessor, which fires `didSet` again *unconditionally* on resume — regardless of whether
    /// anything changed — so `didSet -> &entries -> didSet` recursed until the stack overflowed.
    /// It only bit on UPGRADE, because a fresh install starts with empty feature stores (nothing
    /// to stamp) while an upgrade loads old rows with `updatedAt == 0` that all needed stamping.
    ///
    /// The fix: NO inout. This returns a fresh array; the caller assigns it once, under its own
    /// `_stamping` re-entrancy guard, so the follow-up `didSet` is a cheap no-op.
    func stampMutation<T: HouseholdSyncable & Equatable>(_ key: String, old: [T], current: [T]) -> [T] {
        guard !isApplyingRemote else { return current }
        var out = current
        let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        for i in out.indices {
            let cur = out[i]
            if let prev = oldByID[cur.id] {
                if cur.updatedAt == prev.updatedAt || Self.entityType(for: key) != .featureData,
                   !FeatureSync.semanticallyEqual(cur, prev) {
                    out[i] = FeatureSync.stamped(cur)
                    recordEdit(collection: key, id: cur.id)
                }
            } else if cur.updatedAt == 0 || Self.entityType(for: key) != .featureData {
                out[i] = FeatureSync.stamped(cur)
                // A restored plan/cookbook ID must clear an already-acknowledged server tombstone.
                // Restore is also safe for a brand new ID; both need the same domain capability.
                recordEdit(collection: key, id: cur.id,
                    operation: Self.entityType(for: key) == .featureData ? .update : .restore)
            }
            // An id reappearing after a delete (undo) must not stay tombstoned.
            if tombstones[key]?.remove(cur.id.uuidString) != nil {
                tombstoneDeletedAt[key]?[cur.id.uuidString] = nil
                saveTombstones()
            }
        }

        let newIDs = Set(out.map(\.id))
        for prev in old where !newIDs.contains(prev.id) {
            recordDelete(collection: key, id: prev.id)
        }
        return out
    }

    /// Equality that ignores the sync bookkeeping fields.
    nonisolated private static func semanticallyEqual<T: HouseholdSyncable & Equatable>(_ a: T, _ b: T) -> Bool {
        var x = a; var y = b
        x.updatedAt = 0; y.updatedAt = 0
        x.lastWriterID = ""; y.lastWriterID = ""
        return x == y
    }

    // ── Tombstones ───────────────────────────────────────────────────────────
    // One set per collection, persisted so a delete survives relaunch until acknowledged.

    private var tombstones: [String: Set<String>] = [:]
    private let tombstoneKey = "featureSyncTombstones_v1"
    private var tombstoneRevisions: [String: UInt64] = [:]
    private var tombstoneDeletedAt: [String: [String: Date]] = [:]

    private struct TombstoneLedger: Codable {
        var schemaVersion = 2
        var tombstones: [String: Set<String>]
        var revisions: [String: UInt64]
        var deletedAt: [String: [String: Date]]
    }

    func recordDelete(collection: String, id: UUID) {
        guard !isApplyingRemote else { return }
        tombstones[collection, default: []].insert(id.uuidString)
        tombstoneRevisions[collection, default: 0] &+= 1
        tombstoneDeletedAt[collection, default: [:]][id.uuidString] = Date()
        saveTombstones()
        // Nudge the household push loop the same way core-collection edits do.
        HouseholdSync.shared.enqueue(entityID: id, entityType: Self.entityType(for: collection), operation: .delete)
    }

    func recordEdit(id: UUID) {
        guard !isApplyingRemote else { return }
        HouseholdSync.shared.enqueue(entityID: id, entityType: .featureData, operation: .update)
    }

    func recordEdit(collection: String, id: UUID, operation: HouseholdOperationType = .update) {
        guard !isApplyingRemote else { return }
        HouseholdSync.shared.enqueue(entityID: id, entityType: Self.entityType(for: collection), operation: operation)
    }

    private func loadTombstones() {
        guard let data = UserDefaults.standard.data(forKey: tombstoneKey) else { return }
        if let ledger = try? JSONDecoder().decode(TombstoneLedger.self, from: data) {
            tombstones = ledger.tombstones
            tombstoneRevisions = ledger.revisions
            tombstoneDeletedAt = ledger.deletedAt
        } else if let legacy = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            tombstones = legacy
            tombstoneRevisions = legacy.mapValues { UInt64($0.count) }
        }
    }
    private func saveTombstones() {
        let ledger = TombstoneLedger(tombstones: tombstones,
                                     revisions: tombstoneRevisions,
                                     deletedAt: tombstoneDeletedAt)
        if let data = try? JSONEncoder().encode(ledger) {
            UserDefaults.standard.set(data, forKey: tombstoneKey)
        }
    }

    /// Called after a successful push — the server has the deletes; stop carrying them.
    func acknowledgeTombstones(_ snapshot: [String: Set<String>], capturedDates: [String: [String: Date]]? = nil) {
        for (key, captured) in snapshot {
            let acked = capturedDates.map { dates in
                Set(captured.filter { dates[key]?[$0] == tombstoneDeletedAt[key]?[$0] })
            } ?? captured
            tombstones[key]?.subtract(acked)
            if tombstones[key]?.isEmpty == true { tombstones[key] = nil }
            let pending = tombstones[key] ?? []
            tombstoneDeletedAt[key] = tombstoneDeletedAt[key]?.filter { pending.contains($0.key) }
            if tombstoneDeletedAt[key]?.isEmpty == true { tombstoneDeletedAt[key] = nil }
        }
        saveTombstones()
    }
    func tombstoneSnapshot(included: Set<String>? = nil) -> [String: Set<String>] {
        guard let included else { return tombstones }
        return tombstones.filter { included.contains($0.key) }
    }
    func tombstoneDateSnapshot(included: Set<String>) -> [String: [String: Date]] {
        tombstoneDeletedAt.filter { included.contains($0.key) }
    }

    // ── Collection registry ──────────────────────────────────────────────────
    // Adding a collection = one line here + the same key in the Worker's FEATURE_COLLECTIONS.

    nonisolated struct Keys {
        static let leftovers      = "leftovers"
        static let familyProfiles = "familyProfiles"
        static let events         = "events"
        static let sharedExpenses = "sharedExpenses"
        static let storeLayouts   = "storeLayouts"
        static let gardenHarvests = "gardenHarvests"
        static let containerLabels = "containerLabels"
        static let takeoutLog     = "takeoutLog"
        static let activeCookSessions = "activeCookSessions"
        static let scheduledMeals = "scheduledMeals"
        static let mealPlanRules = "mealPlanRules"
        static let mealPlanTemplates = "mealPlanTemplates"
        static let smartCookbooks = "smartCookbooks"
    }

    nonisolated static func entityType(for collection: String) -> HouseholdEntityType {
        switch collection {
        case Keys.scheduledMeals: return .scheduledMeal
        case Keys.mealPlanRules: return .mealPlanRule
        case Keys.mealPlanTemplates: return .mealPlanTemplate
        case Keys.smartCookbooks: return .smartCookbook
        default: return .featureData
        }
    }

    nonisolated static func collections(inventory: Bool, mealPlans: Bool, recipes: Bool) -> Set<String> {
        var keys: Set<String> = []
        if inventory { keys.formUnion([Keys.leftovers, Keys.familyProfiles, Keys.events, Keys.sharedExpenses,
            Keys.storeLayouts, Keys.gardenHarvests, Keys.containerLabels, Keys.takeoutLog, Keys.activeCookSessions]) }
        if mealPlans { keys.formUnion([Keys.scheduledMeals, Keys.mealPlanRules, Keys.mealPlanTemplates]) }
        if recipes { keys.insert(Keys.smartCookbooks) }
        return keys
    }

    // ── Push payload ─────────────────────────────────────────────────────────

    /// Extra keys for the `/household/push` body. Same shape the Worker's mergeLWW expects:
    /// arrays of dicts each carrying `id`, `updatedAt`, `lastWriterID`, plus `<key>Deleted`.
    func pushPayload(included: Set<String>? = nil) -> [String: Any] {
        var body: [String: Any] = [:]
        add(&body, Keys.leftovers,       LeftoversStore.shared.entries)
        add(&body, Keys.familyProfiles,  FamilyProfileStore.shared.profiles)
        add(&body, Keys.events,          EventStore.shared.events)
        add(&body, Keys.sharedExpenses,  SplitStore.shared.expenses)
        addPlain(&body, Keys.storeLayouts, StoreLayoutStore.shared.layouts)   // name-keyed, no UUID
        add(&body, Keys.gardenHarvests,  HarvestStore.shared.entries)
        add(&body, Keys.containerLabels, ContainerLabelStore.shared.labels)
        add(&body, Keys.takeoutLog,      TakeoutStore.shared.entries)
        add(&body, Keys.activeCookSessions, HouseholdCookStore.shared.entries.filter(\.isFresh))
        add(&body, Keys.scheduledMeals, PlanAheadStore.shared.scheduledMeals)
        add(&body, Keys.mealPlanRules, PlanAheadStore.shared.rules)
        add(&body, Keys.mealPlanTemplates, PlanAheadStore.shared.templates)
        add(&body, Keys.smartCookbooks, SmartCookbookStore.shared.rules)
        let included = included ?? Self.collections(inventory: true, mealPlans: true, recipes: true)
        body = body.filter { entry in included.contains(entry.key) || included.contains(String(entry.key.dropLast("Deleted".count))) && entry.key.hasSuffix("Deleted") }
        body["featureSyncCheckpoint"] = [
            "protocolVersion": 2,
            "tombstoneRevisions": tombstoneRevisions.filter { included.contains($0.key) },
            "tombstoneDeletedAt": tombstoneDeletedAt.filter { included.contains($0.key) }.mapValues {
                $0.mapValues { $0.timeIntervalSince1970 * 1_000 }
            },
        ]
        return body
    }

    private func add<T: HouseholdSyncable>(_ body: inout [String: Any], _ key: String, _ entries: [T]) {
        // Codable → JSON dict via a round-trip, the same technique the recipe serializers use.
        // Hand-listing fields for eight models would drift the moment any model changed.
        guard let data = try? JSONEncoder().encode(entries),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        body[key] = array
        body["\(key)Deleted"] = Array(tombstones[key] ?? [])
    }

    /// For collections without a UUID id (StoreLayout is keyed by store name). Tombstones for
    /// these carry lowercased names rather than uuid strings.
    private func addPlain<T: Codable>(_ body: inout [String: Any], _ key: String, _ entries: [T]) {
        guard let data = try? JSONEncoder().encode(entries),
              let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
        body[key] = array
        body["\(key)Deleted"] = Array(tombstones[key] ?? [])
    }

    /// Delete tombstone for name-keyed collections (store layouts).
    func recordDeleteName(collection: String, name: String) {
        guard !isApplyingRemote else { return }
        tombstones[collection, default: []].insert(name.lowercased())
        tombstoneRevisions[collection, default: 0] &+= 1
        tombstoneDeletedAt[collection, default: [:]][name.lowercased()] = Date()
        saveTombstones()
        HouseholdSync.shared.enqueue(entityID: UUID(), entityType: .featureData, operation: .delete)
    }

    // ── Pull merge ───────────────────────────────────────────────────────────

    /// Merge the feature collections out of a pulled household document.
    /// Per-id last-write-wins via the same policy as inventory; tombstones honored both ways.
    func apply(_ household: [String: Any], included: Set<String>? = nil) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        let hh: [String: Any]
        if let included {
            hh = household.filter { entry in included.contains(entry.key) || included.contains(String(entry.key.dropLast("Deleted".count))) && entry.key.hasSuffix("Deleted") }
        } else { hh = household }

        LeftoversStore.shared.entries = merge(hh, Keys.leftovers, LeftoversStore.shared.entries,
            entityType: "Leftover") { $0.title }
        FamilyProfileStore.shared.profiles = merge(hh, Keys.familyProfiles, FamilyProfileStore.shared.profiles,
            entityType: "Family profile") { $0.name }
        EventStore.shared.events = merge(hh, Keys.events, EventStore.shared.events,
            entityType: "Event") { $0.name }
        SplitStore.shared.expenses = merge(hh, Keys.sharedExpenses, SplitStore.shared.expenses,
            entityType: "Shared expense") { $0.label }
        StoreLayoutStore.shared.layouts = mergeStoreLayouts(hh)
        HarvestStore.shared.entries = merge(hh, Keys.gardenHarvests, HarvestStore.shared.entries,
            entityType: "Harvest") { $0.crop }
        ContainerLabelStore.shared.labels = merge(hh, Keys.containerLabels, ContainerLabelStore.shared.labels,
            entityType: "Container label") { $0.contents }
        TakeoutStore.shared.entries = merge(hh, Keys.takeoutLog, TakeoutStore.shared.entries,
            entityType: "Takeout") { $0.place }
        HouseholdCookStore.shared.entries = merge(
            hh, Keys.activeCookSessions, HouseholdCookStore.shared.entries.filter(\.isFresh),
            entityType: "Cooking session") { $0.recipeTitle }
        if hh[Keys.scheduledMeals] != nil {
            PlanAheadStore.shared.scheduledMeals = merge(hh, Keys.scheduledMeals, PlanAheadStore.shared.scheduledMeals,
                entityType: "Dated meal") { $0.title }
        }
        if hh[Keys.mealPlanRules] != nil {
            PlanAheadStore.shared.rules = merge(hh, Keys.mealPlanRules, PlanAheadStore.shared.rules,
                entityType: "Meal repeat") { $0.name }
        }
        if hh[Keys.mealPlanTemplates] != nil {
            PlanAheadStore.shared.templates = merge(hh, Keys.mealPlanTemplates, PlanAheadStore.shared.templates,
                entityType: "Meal template") { $0.name }
        }
        if hh[Keys.smartCookbooks] != nil {
            SmartCookbookStore.shared.rules = merge(hh, Keys.smartCookbooks, SmartCookbookStore.shared.rules,
                entityType: "Smart cookbook") { $0.name }
        }
    }

    /// G7 (QA gap): every feature collection now routes a last-write-wins overwrite through
    /// `SyncConflictLog` so a household member's edit never vanishes without a trace. `name`
    /// yields a human label; SyncConflictLog.record self-guards when the two sides are equal,
    /// so identical values produce no noise.
    private func merge<T: HouseholdSyncable>(_ hh: [String: Any], _ key: String, _ local: [T],
                                             entityType: String,
                                             name: (T) -> String) -> [T] {
        guard let rawArray = hh[key] as? [[String: Any]] else { return local }
        // Dict → Codable via the reverse round-trip. One bad entry is skipped, never the batch.
        let remote: [T] = rawArray.compactMap { dict in
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? JSONDecoder().decode(T.self, from: data)
        }
        let domainType = Self.entityType(for: key)
        let pending = domainType == .featureData ? Set<UUID>() : Set(HouseholdSync.shared.pendingOps
            .filter { $0.entityType == domainType && $0.operationType != .delete }.map(\.entityID))
        let deleted = Set((hh["\(key)Deleted"] as? [String]) ?? [])
        let localTombstones = tombstones[key] ?? []

        var byID: [UUID: T] = [:]
        for item in local where !deleted.contains(item.id.uuidString) || pending.contains(item.id) { byID[item.id] = item }
        for r in remote {
            // A later batch still owns this local edit/restore. Its full value must survive
            // earlier receipts and polls, including a server tombstone awaiting restore.
            if pending.contains(r.id), byID[r.id] != nil { continue }
            guard !deleted.contains(r.id.uuidString),
                  !localTombstones.contains(r.id.uuidString) else { continue }
            if let mine = byID[r.id] {
                if HouseholdMergePolicy.remoteWins(remoteUpdatedAt: r.updatedAt,
                                                   remoteWriterID: r.lastWriterID,
                                                   localUpdatedAt: mine.updatedAt,
                                                   localWriterID: mine.lastWriterID) {
                    SyncConflictLog.shared.record(entityType: entityType,
                                                  entityName: name(mine),
                                                  replaced: name(mine),
                                                  winning: name(r),
                                                  writer: r.lastWriterID)
                    byID[r.id] = r
                }
            } else {
                byID[r.id] = r
            }
        }
        // Stable order: newest edit first would reshuffle lists on every sync; keep local order,
        // then append genuinely-new remote entries.
        var out: [T] = local.compactMap { byID.removeValue(forKey: $0.id) }
        out.append(contentsOf: byID.values.sorted { $0.updatedAt < $1.updatedAt })
        return out
    }

    /// StoreLayout is keyed by store name, not UUID — it gets its own tiny merge.
    /// Layouts are learned data, so the one with MORE trips wins a tie: losing trips hurts more
    /// than losing recency.
    private func mergeStoreLayouts(_ hh: [String: Any]) -> [StoreLayout] {
        let local = StoreLayoutStore.shared.layouts
        guard let rawArray = hh[Keys.storeLayouts] as? [[String: Any]] else { return local }
        let remote: [StoreLayout] = rawArray.compactMap { dict in
            guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
            return try? JSONDecoder().decode(StoreLayout.self, from: data)
        }
        let deleted = Set((hh["\(Keys.storeLayouts)Deleted"] as? [String]) ?? [])
            .union(tombstones[Keys.storeLayouts] ?? [])
        var byName: [String: StoreLayout] = [:]
        for l in local where !deleted.contains(l.store.lowercased()) { byName[l.store.lowercased()] = l }
        for r in remote {
            let key = r.store.lowercased()
            guard !deleted.contains(key) else { continue }
            if let mine = byName[key] {
                if r.trips > mine.trips
                    || (r.trips == mine.trips
                        && HouseholdMergePolicy.remoteWins(remoteUpdatedAt: r.updatedAt,
                                                           remoteWriterID: r.lastWriterID,
                                                           localUpdatedAt: mine.updatedAt,
                                                           localWriterID: mine.lastWriterID)) {
                    byName[key] = r
                }
            } else {
                byName[key] = r
            }
        }
        return Array(byName.values).sorted { $0.store < $1.store }
    }
}
