// DrawerOrderStore.swift — persisted, user-rearrangeable order for the drawer's action rows.
//
// The drawer's "Kitchen Tools" and "Insights" sections used to be hard-coded button orders.
// This store gives each row a stable identifier and remembers a user-chosen order so a
// long-press drag can rearrange them. New rows shipped in a future build are appended in
// their declared order the first time they appear, so the saved order never hides a new tool.
import SwiftUI

/// Stable identifiers for every rearrangeable drawer row. Raw values are persisted, so they
/// must never change once shipped. Add new cases at the end.
enum DrawerRowID: String, Codable, CaseIterable {
    // Kitchen Tools
    case scanReceipt
    case addItems
    case quickUpdate
    case importRecipe
    case globalSearch
    case kitchenToolbox      // default home for the Toolbox (moved here from Insights)
    // Insights
    case stats
    case databases
    case usageInsights
}

@Observable
@MainActor
final class DrawerOrderStore {
    static let shared = DrawerOrderStore()

    /// Which section a row belongs to. Reordering is constrained within a section.
    enum Section: String, Codable, CaseIterable {
        case kitchenTools
        case insights
    }

    private static let key = "drawer_row_order_v1"

    /// The declared (default) membership and order of every row.
    private static let defaultLayout: [Section: [DrawerRowID]] = [
        .kitchenTools: [.scanReceipt, .addItems, .quickUpdate, .importRecipe, .globalSearch, .kitchenToolbox],
        .insights:     [.stats, .databases, .usageInsights],
    ]

    private(set) var order: [Section: [DrawerRowID]] = [:]

    private init() {
        load()
    }

    /// Rows for a section in the user's saved order, with any newly-shipped rows appended.
    func rows(in section: Section) -> [DrawerRowID] {
        let defaults = Self.defaultLayout[section] ?? []
        let saved = order[section] ?? []
        // Keep saved rows that still exist, in saved order; then append any new defaults.
        let validSaved = saved.filter { defaults.contains($0) }
        let missing = defaults.filter { !validSaved.contains($0) }
        return validSaved + missing
    }

    /// Apply a move within a section (from an onMove index set) and persist.
    func move(in section: Section, from source: IndexSet, to destination: Int) {
        var rows = self.rows(in: section)
        rows.move(fromOffsets: source, toOffset: destination)
        order[section] = rows
        HapticManager.light()
        persist()
    }

    /// Restore the shipped default order.
    func reset() {
        order = Self.defaultLayout
        persist()
        HapticManager.success()
    }

    // MARK: - Persistence
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([String: [DrawerRowID]].self, from: data) else {
            order = Self.defaultLayout
            return
        }
        var restored: [Section: [DrawerRowID]] = [:]
        for (raw, ids) in decoded {
            if let section = Section(rawValue: raw) { restored[section] = ids }
        }
        // Ensure every section has an entry so rows(in:) always has a base.
        for section in Section.allCases where restored[section] == nil {
            restored[section] = Self.defaultLayout[section]
        }
        order = restored
    }

    private func persist() {
        var raw: [String: [DrawerRowID]] = [:]
        for (section, ids) in order { raw[section.rawValue] = ids }
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
