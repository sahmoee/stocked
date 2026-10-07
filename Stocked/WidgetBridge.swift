// WidgetBridge.swift — MAIN APP TARGET ONLY (it references GuestDataStore).
// Builds a StockedWidgetSnapshot from the live store, writes it to the App Group, and
// asks WidgetKit to reload. Call WidgetBridge.refresh(store:) on launch, on background,
// and after meaningful data changes.
import Foundation
import WidgetKit

@MainActor
enum WidgetBridge {
    private(set) static var refreshRevision: UInt64 = 0
    private static var refreshTask: Task<Void, Never>?

    static func invalidateForErase() {
        refreshRevision &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        WidgetStore.save(.empty)
        WidgetCenter.shared.reloadAllTimelines()
    }

    @discardableResult
    static func commitPrepared(_ snapshot: StockedWidgetSnapshot, revision: UInt64) -> Bool {
        guard revision == refreshRevision else { return false }
        // The small App Group snapshot commits on its owning actor; no await can let erase
        // or a newer refresh interleave between the revision check and the write.
        WidgetStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
        return true
    }
    private nonisolated struct Input: Sendable {
        var inventory: [LocalInventoryItem]
        var groceries: [LocalGroceryItem]
        var meals: [PlannedMeal]
        var recipes: [UserRecipe]
        var stockPercent: Int
    }

    static func refresh(store: GuestDataStore) {
        refreshRevision &+= 1
        let revision = refreshRevision
        refreshTask?.cancel()
        let input = Input(
            inventory: store.inventoryItems,
            groceries: store.groceryItems,
            meals: store.plannedMeals,
            recipes: store.userRecipes,
            stockPercent: store.stockPercent
        )
        refreshTask = Task {
            let snap = await Task.detached(priority: .utility) { prepare(input) }.value
            guard !Task.isCancelled else { return }
            commitPrepared(snap, revision: revision)
        }
    }

    private nonisolated static func prepare(_ input: Input) -> StockedWidgetSnapshot {
        let now = Date()
        let cutoff = now.addingTimeInterval(86_400 * 3)

        let expiring = input.inventory.filter {
            guard $0.effectiveLevel > 0, let exp = $0.expirationDate else { return false }
            return exp > now && exp <= cutoff
        }
        let expiringNames = expiring
            .sorted { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }
            .prefix(3)
            .map { $0.name }

        let lowStock = input.inventory.filter { KitchenAvailability.isRunningLow($0) }.count
        let lowStockNames = input.inventory.filter { KitchenAvailability.isRunningLow($0) }
            .prefix(4).map(\.name)
        let meal = input.meals.first { $0.dayIndex == 0 && !$0.isCooked }
        let todayMeal = meal?.title
        let uncheckedGrocery = input.groceries.filter { !$0.isChecked }
        let grocery = uncheckedGrocery.count
        let favorite = input.recipes.first(where: \.isFavorited)?.title

        let snap = StockedWidgetSnapshot(
            stockPercent: input.stockPercent,
            expiringCount: expiring.count,
            expiringNames: Array(expiringNames),
            lowStockCount: lowStock,
            todayMeal: todayMeal,
            groceryCount: grocery,
            updatedAt: now,
            inventoryCount: input.inventory.filter { $0.effectiveLevel > 0 }.count,
            lowStockNames: Array(lowStockNames),
            groceryNames: Array(uncheckedGrocery.prefix(4).map(\.name)),
            todayMealType: meal?.mealType,
            recipeCount: input.recipes.count,
            favoriteRecipe: favorite)
        return snap
    }
}
