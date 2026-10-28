#!/usr/bin/env python3
"""Compile production consumption and opened-history methods with in-memory dependencies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Stocked/GuestDataStore.swift').read_text()
methods = source[source.index('    struct InventoryConsumptionUndo {'):source.index('    func updateInventoryLevel(id: UUID, level: Double) {')]
grocery_method = source[source.index('    func addGroceryItem(name rawName: String) {'):source.index('    func renameInventoryItem')]
merge_method = source[source.index('    nonisolated static func mergingInventoryRows('):source.index('    /// Bounded, stable-order repair')]
opened = (root / 'Stocked/InventoryOpenedHistory.swift').read_text().replace('private init()', 'init()')
fixture = r'''
import Foundation
struct LocalInventoryItem: Equatable {
    var id = UUID(); var name = "Milk"; var quantity = 2; var level = 0.4
    var quantityUsed: Double? = 0.6; var lastConfirmedAt: Date?; var updatedAt = 0
    var sizeAmount: Double?; var sizeUnit: String?; var containerType = "item"
    var brand: String?; var price: Double?; var purchaseDate: Date?; var storePurchasedAt: String?
    var addedBy: String?; var barcode: String?; var imageData: Data?; var expirationDate: Date?
    var parQuantity: Int?; var sourceBadge: SourceBadge?; var fieldProvenance: [String: FieldProvenance]?
}
enum SourceBadge: Equatable { case estimated, userAdded
    var confidence: Double { self == .estimated ? 0.5 : 1 }
}
struct FieldProvenance: Equatable { var badge: SourceBadge; var observedAt = Date() }
struct LocalGroceryItem: Equatable {
    var quantity = 1; var id = UUID(); var name: String; var isChecked = false; var sizeText = ""
}
enum GroceryDedup { static func isDuplicate(_ name: String, in names: [String]) -> Bool {
    names.contains { $0.lowercased() == name.lowercased() }
} }
enum GroceryConsolidator { static func normalizeKey(_ s: String) -> String { s.lowercased() } }
extension String { var displayNormalized: String { self } }
@MainActor final class ToastCenter {
    static let shared = ToastCenter()
    func warning(_ text: String) {}; func success(_ text: String) {}
}
@MainActor final class AppAnalytics {
    enum Event { case groceryItemAdded }
    static let shared = AppAnalytics(); func log(_ event: Event) {}
}
struct ConsumptionRecord { var id = UUID() }
enum HouseholdPermission: Hashable { case inventoryAdd, inventoryRemove, inventoryEdit, groceryAdd, groceryEdit, groceryRemove }
@MainActor final class HouseholdSync {
    static let shared = HouseholdSync(); var myCanEdit = true
    var denied: Set<HouseholdPermission> = []
    func authorize(_ permission: HouseholdPermission) -> Bool { myCanEdit && !denied.contains(permission) }
}
@MainActor final class FixtureStore {
    var inventoryItems: [LocalInventoryItem] = [] {
        didSet { for index in inventoryItems.indices { inventoryItems[index].updatedAt += 1 } }
    }
    var canDeleteInventory = true
    var householdTombstoneRevision: UInt64 = 0
    var groceryItems: [LocalGroceryItem] = []
    var consumptionLog: [ConsumptionRecord] = []
    func inventoryIndex(of id: UUID) -> Int? { inventoryItems.firstIndex { $0.id == id } }
    static func mergeKey(_ name: String) -> String { name.lowercased() }
    func addToGroceryIfMissing(_ name: String, recommended: Bool) {
        if !GroceryDedup.isDuplicate(name, in: groceryItems.map(\.name)) {
            groceryItems.append(LocalGroceryItem(name: name))
        }
    }
    func handleDepleted(_ item: LocalInventoryItem) {
        consumptionLog.append(ConsumptionRecord())
        addToGroceryIfMissing(item.name, recommended: true)
    }
'''
stubs = r'''
@MainActor final class FeatureStore<Element: Codable & Sendable> {
    init(key: String) {}
    func load() -> [Element] { [] }
    func save(_ rows: [Element]) {}
    func flush() {}
    func clear() {}
}
enum FeatureStoreKeys { static let inventoryOpened = "fixture" }
'''
checks = r'''
import Foundation
@main struct Checks {
    @MainActor static func main() {
        let store = FixtureStore()
        let item = LocalInventoryItem()
        store.inventoryItems = [item]
        let original = store.inventoryItems[0]
        let one = store.consumeInventory(id: item.id, finishAll: false)!
        precondition(store.inventoryItems[0].quantity == 1 && store.inventoryItems[0].level == 1)
        precondition(store.inventoryItems[0].quantityUsed == nil)
        precondition(store.consumptionLog.isEmpty && store.groceryItems.isEmpty)
        precondition(store.undoInventoryConsumption(one))
        precondition(store.inventoryItems[0].quantity == original.quantity)
        let finished = store.consumeInventory(id: item.id, finishAll: true)!
        precondition(store.inventoryItems[0].quantity == 0 && store.inventoryItems[0].level == 0)
        precondition(store.consumptionLog.count == 1 && store.groceryItems.count == 1)
        precondition(store.consumeInventory(id: item.id, finishAll: true) == nil)
        precondition(store.undoInventoryConsumption(finished))
        precondition(store.consumptionLog.isEmpty && store.groceryItems.isEmpty)
        precondition(!store.undoInventoryConsumption(finished))
        let stale = store.consumeInventory(id: item.id, finishAll: false)!
        store.inventoryItems[0].name = "New household name"
        precondition(!store.undoInventoryConsumption(stale))
        precondition(store.inventoryItems[0].name == "New household name")
        store.inventoryItems = [item]
        let groceryConflict = store.consumeInventory(id: item.id, finishAll: true)!
        store.groceryItems.append(LocalGroceryItem(name: "Bread"))
        precondition(!store.undoInventoryConsumption(groceryConflict))
        precondition(store.groceryItems.last?.name == "Bread")
        HouseholdSync.shared.myCanEdit = false
        precondition(store.consumeInventory(id: item.id, finishAll: false) == nil)
        precondition(!store.undoInventoryConsumption(groceryConflict))
        HouseholdSync.shared.myCanEdit = true
        precondition(store.consumeInventory(id: UUID(), finishAll: false) == nil)
        var early = item
        early.expirationDate = Date(timeIntervalSince1970: 100)
        early.fieldProvenance = ["expiry": FieldProvenance(badge: .userAdded)]
        var later = item
        later.expirationDate = Date(timeIntervalSince1970: 200)
        later.fieldProvenance = ["expiry": FieldProvenance(badge: .estimated)]
        let merged = FixtureStore.mergingInventoryRows(early, later)
        precondition(merged.expirationDate == later.expirationDate)
        precondition(merged.fieldProvenance?["expiry"]?.badge == .estimated)
        let reverse = FixtureStore.mergingInventoryRows(later, early)
        precondition(reverse.expirationDate == later.expirationDate)
        precondition(reverse.fieldProvenance?["expiry"]?.badge == .estimated)
        later.fieldProvenance = nil
        precondition(FixtureStore.mergingInventoryRows(early, later).fieldProvenance?["expiry"] == nil)
        early.expirationDate = nil
        early.fieldProvenance = nil
        later.fieldProvenance = ["expiry": FieldProvenance(badge: .userAdded)]
        precondition(FixtureStore.mergingInventoryRows(early, later).fieldProvenance?["expiry"]?.badge == .userAdded)
        store.inventoryItems = [item]
        HouseholdSync.shared.denied = [.inventoryEdit]
        precondition(store.consumeInventory(id: item.id, finishAll: true) == nil)
        store.groceryItems = []
        HouseholdSync.shared.denied = [.groceryAdd]
        precondition(store.consumeInventory(id: item.id, finishAll: true) == nil)
        HouseholdSync.shared.denied = []
        let permissionUndo = store.consumeInventory(id: item.id, finishAll: true)!
        HouseholdSync.shared.denied = [.groceryRemove]
        precondition(!store.undoInventoryConsumption(permissionUndo))
        precondition(store.inventoryItems[0].quantity == 0)
        HouseholdSync.shared.denied = []
        precondition(store.undoInventoryConsumption(permissionUndo))
        store.inventoryItems = [item]
        store.groceryItems = [LocalGroceryItem(name: item.name)]
        HouseholdSync.shared.denied = [.groceryAdd]
        precondition(store.consumeInventory(id: item.id, finishAll: true) != nil)
        HouseholdSync.shared.denied = []
        var depleted = item; depleted.quantity = 0; depleted.level = 0
        precondition(FixtureStore.mergingInventoryRows(depleted, item).quantity == item.quantity)
        depleted.quantity = 4 // legacy depleted rows also do not count as purchased stock
        precondition(FixtureStore.mergingInventoryRows(depleted, item).quantity == item.quantity)
        var huge = item; huge.quantity = Int.max
        precondition(FixtureStore.mergingInventoryRows(huge, item).quantity == Int.max)
        let moving = FixtureStore(); moving.inventoryItems = [item]
        let displayed = moving.inventoryItems[0]
        HouseholdSync.shared.denied = [.groceryAdd]
        precondition(moving.moveInventoryToGrocery(expected: displayed) == nil)
        precondition(moving.inventoryItems.count == 1 && moving.groceryItems.isEmpty)
        HouseholdSync.shared.denied = [.inventoryRemove]
        precondition(moving.moveInventoryToGrocery(expected: displayed) == nil)
        HouseholdSync.shared.denied = []
        var staleDisplay = displayed; staleDisplay.quantity += 1
        precondition(moving.moveInventoryToGrocery(expected: staleDisplay) == nil)
        let moved = moving.moveInventoryToGrocery(expected: displayed)!
        precondition(moving.inventoryItems.isEmpty && moving.groceryItems.count == 1)
        HouseholdSync.shared.denied = [.inventoryAdd]
        precondition(!moving.undoInventoryMove(moved))
        HouseholdSync.shared.denied = [.groceryRemove]
        precondition(!moving.undoInventoryMove(moved))
        HouseholdSync.shared.denied = []
        precondition(moving.undoInventoryMove(moved))
        precondition(moving.inventoryItems.count == 1 && moving.groceryItems.isEmpty)
        let movedAgain = moving.moveInventoryToGrocery(expected: moving.inventoryItems[0])!
        moving.householdTombstoneRevision += 1
        precondition(!moving.undoInventoryMove(movedAgain))
        let preexisting = FixtureStore(); preexisting.inventoryItems = [item]
        preexisting.groceryItems = [LocalGroceryItem(name: item.name)]
        HouseholdSync.shared.denied = [.groceryAdd, .groceryRemove]
        let preexistingMove = preexisting.moveInventoryToGrocery(expected: preexisting.inventoryItems[0])!
        precondition(preexisting.undoInventoryMove(preexistingMove))
        precondition(preexisting.groceryItems.count == 1)
        HouseholdSync.shared.denied = []
        let openedStore = FixtureStore(); openedStore.inventoryItems = [item]
        let historyShared = InventoryOpenedHistory.shared
        historyShared.clear()
        let openedAt = Date(timeIntervalSince1970: 900)
        precondition(historyShared.markOpened(id: item.id, at: openedAt, activeIDs: [item.id]))
        let finishedOpened = openedStore.consumeInventory(id: item.id, finishAll: true)!
        precondition(historyShared.openedDate(for: item.id) == nil)
        precondition(openedStore.undoInventoryConsumption(finishedOpened))
        precondition(historyShared.openedDate(for: item.id) == openedAt)
        _ = openedStore.consumeInventory(id: item.id, finishAll: true)!
        let replenished = FixtureStore.mergingInventoryRows(openedStore.inventoryItems[0], item)
        openedStore.inventoryItems = [replenished]
        precondition(historyShared.markOpened(id: item.id, at: openedAt.addingTimeInterval(1), activeIDs: [item.id]))
        historyShared.clear()
        let parsed = QuantityParser.parse("2 cartons oat milk")
        precondition(parsed.count == 2 && parsed.container == "carton" && parsed.item == "oat milk")
        let groceries = FixtureStore()
        groceries.addGroceryItem(name: "2 cartons oat milk")
        precondition(groceries.groceryItems[0].name == "oat milk")
        precondition(groceries.groceryItems[0].quantity == 2 && groceries.groceryItems[0].sizeText == "carton")
        groceries.groceryItems[0].isChecked = true
        groceries.addGroceryItem(name: "3 cartons oat milk")
        precondition(groceries.groceryItems.count == 1 && groceries.groceryItems[0].quantity == 5)
        precondition(!groceries.groceryItems[0].isChecked)
        groceries.addGroceryItem(name: "500 g rice")
        groceries.addGroceryItem(name: "1 kg rice")
        precondition(groceries.groceryItems.count == 3)
        precondition(groceries.groceryItems[1].quantity == 1 && groceries.groceryItems[1].sizeText == "package 500 g")
        let size = QuantityParser.parse(groceries.groceryItems[1].sizeText + " rice")
        precondition(size.amountEach == 500 && size.unitEach == "g")
        groceries.addGroceryItem(name: "V8 Juice")
        precondition(groceries.groceryItems.last?.name == "V8 Juice")
        groceries.addGroceryItem(name: "2% Milk")
        precondition(groceries.groceryItems.last?.name == "2% Milk")
        let count = groceries.groceryItems.count
        groceries.addGroceryItem(name: "-1 apples")
        groceries.addGroceryItem(name: "nan apples")
        precondition(groceries.groceryItems.count == count)
        precondition(GroceryEntryPolicy.adding(1, to: Int.max) == nil)
        precondition(GroceryEntryPolicy.adding(1, to: 1_000_000_000) == nil)
        HouseholdSync.shared.denied = [.groceryEdit]
        groceries.addGroceryItem(name: "2 cartons oat milk")
        precondition(groceries.groceryItems[0].quantity == 5)
        HouseholdSync.shared.denied = [.groceryAdd]
        groceries.addGroceryItem(name: "4 oranges")
        precondition(groceries.groceryItems.count == count)
        HouseholdSync.shared.denied = []
        let history = InventoryOpenedHistory()
        let time = Date(timeIntervalSince1970: 100)
        precondition(!history.markOpened(id: item.id, at: time, activeIDs: []))
        precondition(history.markOpened(id: item.id, at: time, activeIDs: [item.id]))
        precondition(!history.markOpened(id: item.id, at: time.addingTimeInterval(1), activeIDs: [item.id]))
        history.undoOpened(id: item.id, expected: time.addingTimeInterval(1))
        precondition(history.openedDate(for: item.id) == time)
        history.undoOpened(id: item.id, expected: time)
        precondition(history.openedDate(for: item.id) == nil)
        for _ in 0..<1005 {
            let id = UUID()
            precondition(history.markOpened(id: id, at: time, activeIDs: Set(history.records.map(\.inventoryID) + [id])))
        }
        precondition(history.records.count == 1000)
        let replacement = UUID()
        precondition(history.markOpened(id: replacement, at: time, activeIDs: [replacement]))
        precondition(history.records.count == 1)
        history.clear()
        precondition(history.records.isEmpty)
        print("PASS: everyday inventory production consumption/undo and opened history checks")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='stocked-inventory-') as directory:
    path = Path(directory)
    (path/'Fixture.swift').write_text(fixture + grocery_method + merge_method + methods + '\n}\n' + stubs)
    (path/'Opened.swift').write_text(opened)
    (path/'Checks.swift').write_text(checks)
    subprocess.run(['swiftc', '-parse-as-library', str(root/'Stocked/InventoryFormPolicy.swift'), str(root/'Stocked/QuantityParser.swift'), str(root/'Stocked/GroceryEntryPolicy.swift'),
        str(path/'Fixture.swift'), str(path/'Opened.swift'), str(path/'Checks.swift'), '-o', str(path/'checks')], check=True)
    subprocess.run([str(path/'checks')], check=True)
