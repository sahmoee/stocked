// WidgetShared.swift — shared between the MAIN APP target and the WIDGET target.
// ⚠️ Set TARGET MEMBERSHIP on BOTH "Stocked" and "StockedWidgets" (File Inspector → Target Membership).
// Foundation-only so it compiles cleanly in the widget extension.
import Foundation

/// A tiny, codable summary the main app writes to the shared App Group container and the
/// widget reads. Keep it small — widgets get a limited memory budget.
struct StockedWidgetSnapshot: Codable {
    var stockPercent: Int
    var expiringCount: Int
    var expiringNames: [String]     // up to 3, soonest first
    var lowStockCount: Int
    var todayMeal: String?          // today's planned, not-yet-cooked meal
    var groceryCount: Int           // unchecked grocery items
    var updatedAt: Date

    static let empty = StockedWidgetSnapshot(
        stockPercent: 0, expiringCount: 0, expiringNames: [],
        lowStockCount: 0, todayMeal: nil, groceryCount: 0, updatedAt: .distantPast)
}

/// Read/write the snapshot via the shared App Group. Same group the Share Extension uses.
enum WidgetStore {
    static let appGroupID = "group.com.sowens.Stocked"
    static let key = "stocked_widget_snapshot"

    static func save(_ snap: StockedWidgetSnapshot) {
        guard let d = UserDefaults(suiteName: appGroupID),
              let data = try? JSONEncoder().encode(snap) else { return }
        d.set(data, forKey: key)
    }

    static func load() -> StockedWidgetSnapshot {
        guard let d = UserDefaults(suiteName: appGroupID),
              let data = d.data(forKey: key),
              let snap = try? JSONDecoder().decode(StockedWidgetSnapshot.self, from: data)
        else { return .empty }
        return snap
    }
}
