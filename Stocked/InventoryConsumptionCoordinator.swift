// InventoryConsumptionCoordinator.swift
// -----------------------------------------------------------------
// Turns a completed cooking session into inventory changes at meaningful
// points, rather than blindly subtracting everything up front.
//
// The app already deducts at cook-finish via IngredientDeductSheet (All / Half /
// None per ingredient). This coordinator complements that for the workspace by:
//   - Recording what a session actually consumed (the user can adjust amounts).
//   - Creating records for produced outputs - leftovers and prepped components
//     - so cooked food and prepped ingredients are tracked, not lost.
//   - Applying the session's staged inventory changes exactly once.
//
// It never subtracts more than the user confirms, and it routes every write
// through the existing store APIs so household sync and logging are consistent.
// -----------------------------------------------------------------

import Foundation

@MainActor
enum InventoryConsumptionCoordinator {

    /// A produced output worth tracking after a cook.
    struct ProducedOutput {
        enum Kind { case leftover, preppedComponent, cookedAhead }
        let name: String
        let kind: Kind
    }

    /// Apply a finished session's consumption + outputs to inventory.
    /// - Parameters:
    ///   - session: the finished cooking session.
    ///   - store: the data store.
    ///   - consumed: per-ingredient portion actually used (0...1), from the deduct
    ///     UI or Kitchen Check. Names matched loosely to inventory.
    ///   - outputs: leftovers / prepped components / cooked-ahead food produced.
    static func finalize(session: CookNowSession,
                         store: GuestDataStore,
                         consumed: [(name: String, portion: Double)],
                         outputs: [ProducedOutput]) {
        // 1. Consumption - reduce matched inventory by the confirmed portion.
        for entry in consumed where entry.portion > 0 {
            guard let item = matchedItem(entry.name, in: store) else { continue }
            let remaining = max(0, item.level * (1 - entry.portion))
            store.updateInventoryLevel(id: item.id, level: remaining)
        }

        // 2. Produced outputs - create tracked records.
        for output in outputs {
            switch output.kind {
            case .leftover, .cookedAhead:
                // Track cooked food as a new inventory record (leftover zone via name).
                let name = output.kind == .leftover ? "Leftover \(output.name.displayNormalized)" : "Cooked \(output.name.displayNormalized)"
                if !inventoryHas(name, in: store) {
                    store.addInventoryItem(LocalInventoryItem(name: name))
                }
            case .preppedComponent:
                let name = "Prepped \(output.name.displayNormalized)"
                if !inventoryHas(name, in: store) {
                    store.addInventoryItem(LocalInventoryItem(name: name))
                }
            }
        }

        // 3. Apply any staged inventory changes exactly once.
        applyStaged(session: session, store: store)
    }

    /// Apply the session's still-pending staged inventory changes and mark them applied.
    static func applyStaged(session: CookNowSession, store: GuestDataStore) {
        let pending = session.pendingChanges
        guard !pending.isEmpty else { return }
        var appliedIDs: Set<UUID> = []
        for change in pending {
            performStaged(change, store: store)
            appliedIDs.insert(change.id)
        }
        session.markApplied(ids: appliedIDs)
    }

    // MARK: Helpers

    private static func matchedItem(_ name: String, in store: GuestDataStore) -> LocalInventoryItem? {
        let target = name.lowercased()
        return store.inventoryItems.first {
            let n = $0.name.lowercased()
            return $0.effectiveLevel > 0 && (n.contains(target) || target.contains(n))
        }
    }

    private static func inventoryHas(_ name: String, in store: GuestDataStore) -> Bool {
        let target = name.lowercased()
        return store.inventoryItems.contains { $0.name.lowercased() == target }
    }

    private static func performStaged(_ change: StagedInventoryChange, store: GuestDataStore) {
        func existing() -> LocalInventoryItem? {
            let t = change.ingredientName.lowercased()
            return store.inventoryItems.first { let n = $0.name.lowercased(); return n.contains(t) || t.contains(n) }
        }
        switch change.kind {
        case .markAvailable:
            if let item = existing() {
                if item.effectiveLevel <= 0 { store.updateInventoryLevel(id: item.id, level: 1.0) }
                store.confirmInventoryItem(id: item.id)
            } else {
                store.addInventoryItem(LocalInventoryItem(name: change.ingredientName))
            }
        case .addItem:
            if existing() == nil { store.addInventoryItem(LocalInventoryItem(name: change.ingredientName)) }
        case .markEmpty, .markDiscarded:
            if let item = existing() { store.updateInventoryLevel(id: item.id, level: 0) }
        case .reduceQuantity:
            if let item = existing() { store.updateInventoryLevel(id: item.id, level: max(0, item.level * 0.5)) }
        case .recordSubstitute:
            break
        }
    }
}
