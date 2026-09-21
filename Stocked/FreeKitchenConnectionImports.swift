import Foundation

nonisolated struct GrocyReviewChoice: Identifiable, Equatable {
    var id: String { row.id }
    let row: GrocyImportRow
    var selected = false
    var containers: Int
    var countConfirmed: Bool
    var storage: StorageCategory = .pantry
    init(row: GrocyImportRow) {
        self.row = row; containers = row.suggestedContainers ?? 1
        countConfirmed = row.suggestedContainers != nil
    }
}

/// Grocy contributes reviewed additions to the existing owners. No Grocy request
/// changes its inventory, and existing Stocked rows are never adjusted automatically.
@MainActor enum GrocyKitchenImport {
    static var scope: String { HouseholdSync.shared.joinCode ?? "local-kitchen" }
    static func ledgerEndpoint(_ endpoint: String, scope: String) -> String { endpoint + "|" + scope }

    static func reasons(for rows: [GrocyImportRow], endpoint: String, store: GuestDataStore) -> [String: String] {
        let imported = KitchenConnectionLedger.imported()
        let inventoryNames = Dictionary(store.inventoryItems.map { (KitchenConnectionPolicy.nameKey($0.name), $0.quantity) }, uniquingKeysWith: { first, _ in first })
        let groceryNames = Dictionary(store.groceryItems.map { (KitchenConnectionPolicy.nameKey($0.name), $0.quantity) }, uniquingKeysWith: { first, _ in first })
        var result: [String: String] = [:]
        for row in rows {
            let key = KitchenConnectionLedger.importKey(endpoint: ledgerEndpoint(endpoint, scope: scope), row: row)
            if let prior = imported[key] {
                result[row.id] = prior == row.fingerprint ? "Already imported. No additional stock will be added."
                    : "Changed in Grocy since import. Check the existing item in Stocked and adjust it manually."
            } else if let count = (row.kind == .inventory ? inventoryNames : groceryNames)[KitchenConnectionPolicy.nameKey(row.name)] {
                result[row.id] = "Already in \(row.kind == .inventory ? "Inventory" : "Grocery List") with \(count) containers. Compare and edit the existing item there."
            }
        }
        return result
    }

    static func apply(_ choice: GrocyReviewChoice, endpoint: String, expectedScope: String, store: GuestDataStore) throws {
        guard scope == expectedScope else { throw KitchenConnectionFailure.changed }
        guard choice.selected, choice.countConfirmed, (1...999).contains(choice.containers) else { throw KitchenConnectionFailure.response }
        let permission: HouseholdPermission = choice.row.kind == .inventory ? .inventoryAdd : .groceryAdd
        guard HouseholdSync.shared.can(permission) else { throw KitchenConnectionFailure.permission }
        guard reasons(for: [choice.row], endpoint: endpoint, store: store)[choice.id] == nil else { throw KitchenConnectionFailure.changed }
        let ledgerEndpoint = ledgerEndpoint(endpoint, scope: expectedScope)
        let ledger = KitchenConnectionLedger.imported()
        guard ledger.count < 5_000 || ledger[KitchenConnectionLedger.importKey(endpoint: ledgerEndpoint, row: choice.row)] != nil else {
            throw KitchenConnectionFailure.tooLarge
        }
        if choice.row.kind == .inventory {
            let before = Set(store.inventoryItems.map(\.id))
            guard before.count == store.inventoryItems.count else { throw KitchenConnectionFailure.changed }
            let item = LocalInventoryItem(name: choice.row.name, zone: choice.storage.rawValue, quantity: choice.containers)
            let addition = InventoryProposalBatch.reviewableAdd(item: item, origin: .importService,
                                                               sourceID: "grocy-reviewed", badge: .userAdded,
                                                               reason: "Reviewed Grocy inventory copy")
            let batch = InventoryProposalBatch(origin: .importService, title: "Grocy inventory import",
                                                changes: [addition], mergePolicy: .storeCompatible)
            let prepared = batch.canonicalized(against: store.inventoryItems, brandPreferences: store.cookingProfile.brandPreferences)
            // The canonical owner can find a stronger duplicate than the initial name check.
            // Reject its proposed adjustment: this screen authorized a new row only.
            guard prepared.changes.count == 1, case .add = prepared.changes[0].action else { throw KitchenConnectionFailure.changed }
            let applied = store.applyProposalBatch(prepared, brandPreferences: store.cookingProfile.brandPreferences)
            guard applied.appliedCount > 0, Set(store.inventoryItems.map(\.id)).subtracting(before).count == 1 else {
                throw KitchenConnectionFailure.changed
            }
        } else {
            guard !GroceryDedup.isDuplicate(choice.row.name, in: store.groceryItems.map(\.name)) else { throw KitchenConnectionFailure.changed }
            var item = LocalGroceryItem(name: choice.row.name, isChecked: false, isRecommended: false)
            item.quantity = choice.containers
            store.groceryItems.append(item) // Existing didSet enforces role, stamps and queues sync.
            guard store.groceryItems.contains(where: { $0.id == item.id }) else { throw KitchenConnectionFailure.permission }
        }
        store.flushPendingSaves()
        try KitchenConnectionLedger.remember(endpoint: ledgerEndpoint, row: choice.row)
    }
}

@MainActor enum KitchenCalendarCandidates {
    static func active(_ meals: [PlannedMeal], firstDay: Date, timeZoneID: String) throws -> [CalDAVMeal] {
        guard meals.count <= 2_000, Set(meals.map(\.id)).count == meals.count else { throw KitchenConnectionFailure.changed }
        var calendar = Calendar(identifier: .gregorian)
        guard let zone = TimeZone(identifier: timeZoneID) else { throw KitchenConnectionFailure.response }
        calendar.timeZone = zone
        return try meals.filter { !$0.isBuilding && !$0.isCooked && (0..<7).contains($0.dayIndex) }.map { meal in
            guard let date = calendar.date(byAdding: .day, value: meal.dayIndex, to: firstDay) else { throw KitchenConnectionFailure.response }
            let key = try PlanAheadCore.dateKey(for: date, timeZoneID: timeZoneID)
            return CalDAVMeal(id: "active:\(meal.id.uuidString.lowercased()):\(key)", civilDate: key,
                              title: meal.title, mealType: meal.mealType, servings: meal.servings)
        }.sorted { $0.civilDate == $1.civilDate ? $0.title < $1.title : $0.civilDate < $1.civilDate }
    }
    static func dated(_ meals: [ScheduledMeal], firstDay: Date, days: Int, timeZoneID: String) throws -> [CalDAVMeal] {
        guard meals.count <= 2_000, Set(meals.map(\.id)).count == meals.count, (1...366).contains(days),
              let zone = TimeZone(identifier: timeZoneID) else { throw KitchenConnectionFailure.changed }
        let first = try PlanAheadCore.dateKey(for: firstDay, timeZoneID: timeZoneID)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        guard let date = calendar.date(byAdding: .day, value: days, to: firstDay) else { throw KitchenConnectionFailure.response }
        let last = try PlanAheadCore.dateKey(for: date, timeZoneID: timeZoneID)
        return meals.filter { !$0.isSkipped && !$0.movedToWeek && $0.civilDate >= first && $0.civilDate < last }.map { meal in
            CalDAVMeal(id: "dated:\(meal.id.uuidString.lowercased())", civilDate: meal.civilDate,
                       title: meal.title, mealType: meal.mealType, servings: meal.servings)
        }.sorted { $0.civilDate == $1.civilDate ? $0.title < $1.title : $0.civilDate < $1.civilDate }
    }
}
