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

    // ── Wipe (FR-01 fix, point 5) ─────────────────────────────────────────────

    /// Reset every in-memory feature store to empty and clear sync bookkeeping, WITHOUT enqueuing
    /// pushes or tombstones. `GuestDataStore.clearAll()` already deletes the on-disk files; this
    /// clears the live singletons so a later mutation or `flushAll()` can't re-persist stale data —
    /// the "partial resurrection" gap. Runs under `isApplyingRemote` so the stores' didSet is a
    /// plain (empty) save with no side effects.
    func wipeAll() {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        tombstones = [:]
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
                if cur.updatedAt == prev.updatedAt, !FeatureSync.semanticallyEqual(cur, prev) {
                    out[i] = FeatureSync.stamped(cur)
                    recordEdit(id: cur.id)
                }
            } else if cur.updatedAt == 0 {
                out[i] = FeatureSync.stamped(cur)
                recordEdit(id: cur.id)
            }
            // An id reappearing after a delete (undo) must not stay tombstoned.
            if tombstones[key]?.remove(cur.id.uuidString) != nil { saveTombstones() }
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

    func recordDelete(collection: String, id: UUID) {
        guard !isApplyingRemote else { return }
        tombstones[collection, default: []].insert(id.uuidString)
        saveTombstones()
        // Nudge the household push loop the same way core-collection edits do.
        HouseholdSync.shared.enqueue(entityID: id, entityType: .featureData, operation: .delete)
    }

    func recordEdit(id: UUID) {
        guard !isApplyingRemote else { return }
        HouseholdSync.shared.enqueue(entityID: id, entityType: .featureData, operation: .update)
    }

    private func loadTombstones() {
        if let data = UserDefaults.standard.data(forKey: tombstoneKey),
           let decoded = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            tombstones = decoded
        }
    }
    private func saveTombstones() {
        if let data = try? JSONEncoder().encode(tombstones) {
            UserDefaults.standard.set(data, forKey: tombstoneKey)
        }
    }

    /// Called after a successful push — the server has the deletes; stop carrying them.
    func acknowledgeTombstones(_ snapshot: [String: Set<String>]) {
        for (key, acked) in snapshot {
            tombstones[key]?.subtract(acked)
            if tombstones[key]?.isEmpty == true { tombstones[key] = nil }
        }
        saveTombstones()
    }
    func tombstoneSnapshot() -> [String: Set<String>] { tombstones }

    // ── Collection registry ──────────────────────────────────────────────────
    // Adding a collection = one line here + the same key in the Worker's FEATURE_COLLECTIONS.

    struct Keys {
        static let leftovers      = "leftovers"
        static let familyProfiles = "familyProfiles"
        static let events         = "events"
        static let sharedExpenses = "sharedExpenses"
        static let storeLayouts   = "storeLayouts"
        static let gardenHarvests = "gardenHarvests"
        static let containerLabels = "containerLabels"
        static let takeoutLog     = "takeoutLog"
    }

    // ── Push payload ─────────────────────────────────────────────────────────

    /// Extra keys for the `/household/push` body. Same shape the Worker's mergeLWW expects:
    /// arrays of dicts each carrying `id`, `updatedAt`, `lastWriterID`, plus `<key>Deleted`.
    func pushPayload() -> [String: Any] {
        var body: [String: Any] = [:]
        add(&body, Keys.leftovers,       LeftoversStore.shared.entries)
        add(&body, Keys.familyProfiles,  FamilyProfileStore.shared.profiles)
        add(&body, Keys.events,          EventStore.shared.events)
        add(&body, Keys.sharedExpenses,  SplitStore.shared.expenses)
        addPlain(&body, Keys.storeLayouts, StoreLayoutStore.shared.layouts)   // name-keyed, no UUID
        add(&body, Keys.gardenHarvests,  HarvestStore.shared.entries)
        add(&body, Keys.containerLabels, ContainerLabelStore.shared.labels)
        add(&body, Keys.takeoutLog,      TakeoutStore.shared.entries)
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
        saveTombstones()
        HouseholdSync.shared.enqueue(entityID: UUID(), entityType: .featureData, operation: .delete)
    }

    // ── Pull merge ───────────────────────────────────────────────────────────

    /// Merge the feature collections out of a pulled household document.
    /// Per-id last-write-wins via the same policy as inventory; tombstones honored both ways.
    func apply(_ hh: [String: Any]) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }

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
        let deleted = Set((hh["\(key)Deleted"] as? [String]) ?? [])
        let localTombstones = tombstones[key] ?? []

        var byID: [UUID: T] = [:]
        for item in local where !deleted.contains(item.id.uuidString) { byID[item.id] = item }
        for r in remote {
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
