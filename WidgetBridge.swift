// WidgetBridge.swift — MAIN APP TARGET ONLY (it references GuestDataStore).
// Builds a StockedWidgetSnapshot from the live store, writes it to the App Group, and
// asks WidgetKit to reload. Call WidgetBridge.refresh(store:) on launch, on background,
// and after meaningful data changes.
import Foundation
import WidgetKit

@MainActor
enum WidgetBridge {
    static func refresh(store: GuestDataStore) {
        let now = Date()
        let cutoff = now.addingTimeInterval(86_400 * 3)

        let expiring = store.inventoryItems.filter {
            guard $0.effectiveLevel > 0, let exp = $0.expirationDate else { return false }
            return exp > now && exp <= cutoff
        }
        let expiringNames = expiring
            .sorted { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }
            .prefix(3)
            .map { $0.name }

        let lowStock = store.inventoryItems.filter { $0.effectiveLevel > 0 && $0.effectiveLevel < 0.2 }.count
        let todayMeal = store.plannedMeals.first { $0.dayIndex == 0 && !$0.isCooked }?.title
        let grocery = store.groceryItems.filter { !$0.isChecked }.count

        let snap = StockedWidgetSnapshot(
            stockPercent: store.stockPercent,
            expiringCount: expiring.count,
            expiringNames: Array(expiringNames),
            lowStockCount: lowStock,
            todayMeal: todayMeal,
            groceryCount: grocery,
            updatedAt: now)

        WidgetStore.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
