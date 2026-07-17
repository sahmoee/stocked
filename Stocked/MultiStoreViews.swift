// MultiStoreViews.swift — RL-010 supporting UI for multi-store grocery organization.
//
// Small pieces GroceryListView composes so its own additions stay surgical:
//   • MultiStoreCatalog       — the shared store roster (mirrors the picker/URL list).
//   • MultiStorePickerMenu    — the "Store ▸" submenu on a grocery row.
//   • MultiStoreSegmentFooter — per-store "move purchased → pantry" button shown at the
//     bottom of a store section when grouping by store.
//
// None of these mutate data directly; they surface callbacks the list view routes
// through the RL-007 dedupe-aware transfer path.

import SwiftUI

// MARK: - Store roster

enum MultiStoreCatalog {
    /// Same roster as the grocery store picker / Find-in-Store URL map, kept in one
    /// place so the row menu and the quick picker never drift apart.
    static let stores = ["Walmart", "Target", "H-E-B", "Kroger", "Whole Foods", "Aldi",
                         "Publix", "Safeway", "Costco", "Trader Joe's", "Sprouts",
                         "Meijer", "Wegmans", "Food Lion", "Amazon Fresh"]

    /// Roster with any learned/assigned strays appended (a store name that arrived via a
    /// receipt scan but isn't in the built-in list still needs to be pickable).
    static func stores(including extras: [String]) -> [String] {
        var out = stores
        for e in extras where !e.isEmpty && !out.contains(e) { out.append(e) }
        return out
    }
}

// MARK: - Row store submenu

/// Menu content for assigning a grocery row to a store. Rendered inside a `Menu` label
/// by the caller (works both as a row submenu and inside a context menu).
struct MultiStorePickerMenu: View {
    var currentStore: String            // the resolved store shown with a checkmark
    var isExplicit: Bool                // whether the current store is a manual assignment
    var extras: [String] = []           // learned store names beyond the built-in roster
    var onSelect: (String?) -> Void     // nil = clear back to the default store

    var body: some View {
        ForEach(MultiStoreCatalog.stores(including: extras), id: \.self) { name in
            Button {
                onSelect(name)
            } label: {
                Label(name, systemImage: currentStore == name ? "checkmark" : "storefront")
            }
        }
        if isExplicit {
            Divider()
            Button(role: .destructive) {
                onSelect(nil)
            } label: {
                Label("Use default store", systemImage: "arrow.uturn.backward")
            }
        }
    }
}

// MARK: - Per-store segment transfer footer

/// Shown at the bottom of a store section (Bought segment, grouped by store): moves that
/// store's purchased items into inventory as one trip segment. The section is "complete"
/// when everything in it is checked — the label celebrates that so per-store progress is
/// legible at a glance.
struct MultiStoreSegmentFooter: View {
    @Environment(AppSession.self) var session
    var storeName: String
    var itemCount: Int
    var isComplete: Bool                // all of this store's items are checked off
    var onTransfer: () -> Void

    var body: some View {
        Button(action: onTransfer) {
            HStack(spacing: 7) {
                Image(systemName: isComplete ? "checkmark.seal.fill" : "shippingbox")
                    .font(.system(size: 12, weight: .semibold))
                Text(isComplete
                     ? "\(storeName) done — move \(itemCount) to Pantry"
                     : "Move \(itemCount) from \(storeName) to Pantry")
                    .font(.system(size: 12.5, weight: .semibold, design: .serif))
            }
            .foregroundStyle(isComplete ? Color.stockedGreen : Color.stockedGold)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yButton("Move \(itemCount) purchased item\(itemCount == 1 ? "" : "s") from \(storeName) into your pantry")
    }
}
