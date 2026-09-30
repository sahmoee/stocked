// SpotlightIndexer.swift — Overall improvement #17: make recipes and inventory findable in
// system-wide Spotlight search. Green-field (nothing was indexed before). On-device only;
// CoreSpotlight never leaves the phone. Indexing is best-effort and cheap — a debounced rebuild
// on launch and after big data changes keeps it fresh without touching the hot path.

import Foundation
@preconcurrency import CoreSpotlight
import UniformTypeIdentifiers

@MainActor
enum SpotlightIndexer {
    static let recipeDomain = "com.sowens.Stocked.recipe"
    static let inventoryDomain = "com.sowens.Stocked.inventory"

    /// Rebuild the index from the current store. Safe to call repeatedly.
    /// Fingerprint of what was last indexed. A launch with unchanged recipes/inventory skips the
    /// delete-then-reindex cycle entirely, which otherwise rewrites the system index every launch.
    private static let fingerprintKey = "spotlightIndexFingerprint_v1"
    private static func fingerprint(store: GuestDataStore) -> String {
        var parts: [String] = []
        parts.reserveCapacity(store.userRecipes.prefix(300).count * 2 + store.inventoryItems.prefix(400).count * 2)
        for r in store.userRecipes.prefix(300) { parts.append(r.id.uuidString); parts.append(r.title + "|" + r.cuisine) }
        for it in store.inventoryItems.prefix(400) { parts.append(it.id.uuidString); parts.append(it.name + "|" + it.zone + "|" + (it.brand ?? "")) }
        return ResponseCacheKey.make(parts)
    }

    static func reindex(store: GuestDataStore) {
        let currentFingerprint = fingerprint(store: store)
        if UserDefaults.standard.string(forKey: fingerprintKey) == currentFingerprint { return }
        var items: [CSSearchableItem] = []

        for r in store.userRecipes.prefix(300) {
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = r.title
            attrs.contentDescription = r.cuisine.isEmpty ? "Recipe in Stocked" : "\(r.cuisine) recipe"
            attrs.keywords = r.tags + r.ingredientNames.prefix(8)
            items.append(CSSearchableItem(uniqueIdentifier: "recipe:\(r.id.uuidString)",
                                          domainIdentifier: recipeDomain,
                                          attributeSet: attrs))
        }
        for it in store.inventoryItems.prefix(400) {
            let attrs = CSSearchableItemAttributeSet(contentType: .text)
            attrs.title = it.name
            attrs.contentDescription = "In your \(it.zone.lowercased())"
            attrs.keywords = [it.zone, it.brand ?? ""].filter { !$0.isEmpty }
            items.append(CSSearchableItem(uniqueIdentifier: "inventory:\(it.id.uuidString)",
                                          domainIdentifier: inventoryDomain,
                                          attributeSet: attrs))
        }

        let index = CSSearchableIndex.default()
        let indexedItems = items
        let defaultsKey = fingerprintKey
        // Replace whole domains so deletions drop out, then add the current set.
        index.deleteSearchableItems(withDomainIdentifiers: [recipeDomain, inventoryDomain]) { _ in
            guard !indexedItems.isEmpty else {
                UserDefaults.standard.set(currentFingerprint, forKey: defaultsKey)
                return
            }
            index.indexSearchableItems(indexedItems) { error in
                // Only a successful index is remembered, so a failure retries next launch.
                if error == nil { UserDefaults.standard.set(currentFingerprint, forKey: defaultsKey) }
            }
        }
    }

    /// Map a tapped Spotlight result to an in-app destination. Returns the tab to switch to.
    static func route(for uniqueID: String) -> StockedTab {
        uniqueID.hasPrefix("recipe:") ? .recipes : .inventory
    }
}
