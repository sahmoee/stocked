// InventoryIndex.swift — Improvement #9: stop re-scanning the whole pantry on every render.
//
// Views compute things like `inventoryItems.filter { $0.storageCategory == .freezer }` inside
// `body`, so the scan re-runs on every SwiftUI render pass — which is many times per second while
// scrolling or typing. ThawPlanner, PreservationPlanner, EmergencyPantry and the search screen all
// do full-array work this way. It's imperceptible at 80 items and visibly janky at 800, and users
// who scan receipts get to 800.
//
// This computes the common derivations once per inventory mutation, keyed off the store's existing
// `inventoryRevision` counter (the same trick `ReservationLedger` uses). Views read a precomputed
// array instead of filtering.
//
// Additive on purpose: nothing is forced to adopt it, and `GuestDataStore` is untouched.

import SwiftUI

@MainActor
@Observable
final class InventoryIndex {
    static let shared = InventoryIndex()
    private init() {}

    /// The revision this index was built from. `-1` forces a build on first access.
    private var builtRevision = -1
    private var builtCount = -1

    private(set) var byZone: [StorageCategory: [LocalInventoryItem]] = [:]
    /// Items with a real expiry date, soonest first. The basis for every "expiring" view.
    private(set) var dated: [LocalInventoryItem] = []
    /// Lowercased name → items, for O(1) "do I have X" instead of a linear contains scan.
    private(set) var byNormalizedName: [String: [LocalInventoryItem]] = [:]
    private(set) var inStockNames: Set<String> = []

    // MARK: Refresh

    /// Call from `.onAppear` / `.task`. Cheap when nothing changed — one integer comparison.
    func refreshIfNeeded(_ store: GuestDataStore) {
        // The count check catches the case where a mutation didn't bump the revision counter,
        // so a stale index can't silently persist.
        guard store.inventoryRevision != builtRevision || store.inventoryItems.count != builtCount
        else { return }
        rebuild(store)
    }

    func rebuild(_ store: GuestDataStore) {
        let items = store.inventoryItems
        var zones: [StorageCategory: [LocalInventoryItem]] = [:]
        var names: [String: [LocalInventoryItem]] = [:]
        var stock: Set<String> = []
        var withDates: [LocalInventoryItem] = []

        // One pass, not five.
        for item in items {
            zones[item.storageCategory, default: []].append(item)
            let key = InventoryIndex.normalize(item.name)
            names[key, default: []].append(item)
            if item.level > 0 { stock.insert(key) }
            if item.expirationDate != nil { withDates.append(item) }
        }

        byZone = zones
        byNormalizedName = names
        inStockNames = stock
        dated = withDates.sorted { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }
        builtRevision = store.inventoryRevision
        builtCount = items.count
    }

    // MARK: Reads

    func items(in zone: StorageCategory) -> [LocalInventoryItem] { byZone[zone] ?? [] }

    /// Everything expiring within `days`, soonest first. `dated` is already sorted, so this is a
    /// prefix scan rather than a filter + sort of the whole pantry.
    func expiring(within days: Int, from now: Date = Date()) -> [LocalInventoryItem] {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: days, to: now) else { return [] }
        var out: [LocalInventoryItem] = []
        for item in dated {
            guard let exp = item.expirationDate else { continue }
            if exp > cutoff { break }   // sorted — everything after this is further out
            out.append(item)
        }
        return out
    }

    func alreadyExpired(asOf now: Date = Date()) -> [LocalInventoryItem] {
        dated.filter { ($0.expirationDate ?? .distantFuture) < now }
    }

    /// "Do I have chicken?" — substring-aware but index-backed, so the common exact hit is O(1).
    func has(_ name: String) -> Bool {
        let key = InventoryIndex.normalize(name)
        if inStockNames.contains(key) { return true }
        return inStockNames.contains { $0.contains(key) || key.contains($0) }
    }

    func matches(_ name: String) -> [LocalInventoryItem] {
        let key = InventoryIndex.normalize(name)
        if let exact = byNormalizedName[key] { return exact }
        return byNormalizedName
            .filter { $0.key.contains(key) || key.contains($0.key) }
            .flatMap(\.value)
    }

    nonisolated static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - View helper

extension View {
    /// Keep the shared inventory index fresh for the lifetime of a screen.
    /// One line at the call site; no-op when nothing has changed.
    func withInventoryIndex(_ store: GuestDataStore) -> some View {
        onAppear { InventoryIndex.shared.refreshIfNeeded(store) }
    }
}
