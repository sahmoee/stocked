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
    static func reindex(store: GuestDataStore) {
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
        // Replace whole domains so deletions drop out, then add the current set.
        index.deleteSearchableItems(withDomainIdentifiers: [recipeDomain, inventoryDomain]) { _ in
            guard !items.isEmpty else { return }
            index.indexSearchableItems(items) { _ in }
        }
    }

    /// Map a tapped Spotlight result to an in-app destination. Returns the tab to switch to.
    static func route(for uniqueID: String) -> StockedTab {
        uniqueID.hasPrefix("recipe:") ? .recipes : .inventory
    }
}
