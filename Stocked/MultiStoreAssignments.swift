// MultiStoreAssignments.swift — RL-010 per-item store assignment (organizational).
//
// A grocery item can be earmarked for a particular store ("mushrooms → Costco,
// everything else → H-E-B") WITHOUT duplicating the list — the assignment is a
// side-table keyed by the grocery item's UUID, so LocalGroceryItem/Models.swift
// stay untouched and household sync of the list itself is unaffected.
//
// Resolution order for "which store does this item belong to?":
//   1. explicit assignment (the user picked a store for this row)
//   2. learned history (GuestDataStore.itemStoreHistory — where this product was
//      last bought, taught by receipt imports and past assignments)
//   3. the session's preferred store (the default segment)
//
// Persisted via the LocalDatabase per-key JSON pattern. Assignments for rows that
// have left the list are pruned lazily on access, so the map never outgrows the list.

import Foundation

@Observable
final class MultiStoreAssignments {
    static let shared = MultiStoreAssignments()

    private(set) var byItemID: [UUID: String] = [:]
    private let dbKey = "multiStoreAssignments_v1"

    private init() {
        byItemID = LocalDatabase.shared.load([UUID: String].self, key: dbKey) ?? [:]
    }

    // MARK: Assign / read

    /// Set (or clear, with nil) the store for one grocery row. Moving an item to another
    /// store is just this — the row itself never gets recreated, so checked state,
    /// provenance, and household attribution all survive the move.
    func assign(_ storeName: String?, to itemID: UUID) {
        if let storeName, !storeName.isEmpty {
            byItemID[itemID] = storeName
        } else {
            byItemID.removeValue(forKey: itemID)
        }
        persist()
    }

    func explicitStore(for itemID: UUID) -> String? { byItemID[itemID] }

    /// The store an item resolves to, walking assignment → learned history → default.
    /// `learned` is GuestDataStore.itemStoreHistory (normalized name → store).
    func resolvedStore(for item: LocalGroceryItem,
                       learned: [String: String],
                       defaultStore: String) -> String {
        if let explicit = byItemID[item.id] { return explicit }
        if let taught = learned[PurchaseDedupEngine.normalizedName(item.name)], !taught.isEmpty {
            return taught
        }
        return defaultStore
    }

    // MARK: Housekeeping

    /// Drop assignments whose grocery rows no longer exist (item bought/removed).
    func prune(keeping liveIDs: Set<UUID>) {
        let before = byItemID.count
        byItemID = byItemID.filter { liveIDs.contains($0.key) }
        if byItemID.count != before { persist() }
    }

    private func persist() {
        LocalDatabase.shared.save(byItemID, key: dbKey)
    }
}
