#!/usr/bin/env python3
"""Run the actual AddItemSheet save-draft calculations and local defaults against isolated fixtures."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
sheet = (root/'Stocked/InventoryItemSheets.swift').read_text().split('struct AddItemSheet: View', 1)[1]
entry = sheet.split('    private func saveItem() {', 1)[1].split('        // Derive the fill level', 1)[0]
helpers = sheet.split('    private func entryDefaultsKey', 1)[1].split('    private func saveItem()', 1)[0]
helpers = '    func entryDefaultsKey' + helpers.replace('private func', 'func')
lookup = sheet.split('            .task(id: itemName) {', 1)[1].split('\n\n            // Container type', 1)[0].rsplit('}', 1)[0]
expiry = sheet.split('        if hasExpiry {', 1)[1].split('        item.subZone', 1)[0]
seed = sheet.split('                        // Seed the picker before interaction;', 1)[1].split('                    }\n            }.padding', 1)[0]
seed = seed.split('\n', 1)[1]
picker = sheet.split('DatePicker("", selection: Binding(get: { expiryDate }, set: { date in', 1)[1].split('                }), in:', 1)[0]
# DTO decodes legacy optional fields without writing any real user defaults.
usuals = (root/'Stocked/GroceryUsuals.swift').read_text()
dto = usuals.split('    struct InventoryDefaults: Codable {', 1)[1].split('    private let inventoryDefaultsKey', 1)[0]
fixture = '''import Foundation
@MainActor final class ToastCenter { static let shared = ToastCenter(); func warning(_ s: String) {} }
@MainActor final class EntryFixture {
    var itemName = "", quantity = 1, containerType = "", sizeAmount = "", sizeUnit = ""
    var quantityManuallySelected = false, containerManuallySelected = false, measurementManuallySelected = false
    var zoneManuallySelected = false, zone = "Fridge"
    var rememberedSubZone: String?, automaticDefaultsName = "", automaticDefaultsZone: String?
    var session = Session()
    var result: (name: String, quantity: Int, container: String, amount: Double?, unit: String?, zone: String, shelf: String?)?
''' + helpers + '''
    func loadDefaults() async {
''' + lookup + '''
    }
    func save() {
''' + entry + '''
        result = (name, savedQuantity, savedContainer, savedAmount, savedUnit, zone, savedSubZone)
    }
}
struct InventoryDefaults: Codable {''' + dto + '''
enum Zone: String { case fridge = "Fridge", pantry = "Pantry" }
enum ZoneClassifier { static func classify(_ name: String) -> Zone {
    name.lowercased().contains("rice") ? .pantry : .fridge
} }
struct ExistingItem {
    var name: String, zone: String, quantity: Int, containerType: String
    var sizeAmount: Double?, sizeUnit: String?, subZone: String?, updatedAt: Double
}
@MainActor final class Store { var inventoryItems: [ExistingItem] = [] }
@MainActor final class Session { var guestStore = Store() }
@MainActor final class GroceryUsuals {
    static let shared = GroceryUsuals()
    var rows: [String: InventoryDefaults] = [:]
    func inventoryDefaults(for name: String) -> InventoryDefaults? { rows[name.lowercased()] }
}
struct CrowdSuggestion { var count: Int; var avgQuantity: Double?; var topContainer: String? }
@MainActor enum CrowdDB {
    static var delayNanoseconds: UInt64 = 0
    static var suggestion: CrowdSuggestion?
    static func suggest(name: String) async -> CrowdSuggestion? {
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return suggestion
    }
}
enum SourceBadge { case estimated, userAdded }
struct FieldProvenance { var sourceID: String; var sourceName: String; var badge: SourceBadge }
struct ExpiryItem { var fieldProvenance: [String: FieldProvenance]? }
@MainActor final class ExpiryFixture {
    var hasExpiry = false
    var expiryDate = Date(timeIntervalSince1970: 50)
    var seededExpiry: Date?
    var estimatedExpiry: Date? = Date(timeIntervalSince1970: 100)
    var zone = "Fridge"
    var item = ExpiryItem()
    func seed() {
''' + seed + '''
    }
    func pick(_ date: Date) {
''' + picker + '''
    }
    func save() {
        if hasExpiry {
''' + expiry + '''
    }
}
'''
checks = r'''
@main struct Checks {
    @MainActor static func main() async throws {
        let sheet = EntryFixture()
        sheet.itemName = "2 cartons oat milk"
        sheet.save()
        precondition(sheet.result?.name == "oat milk" && sheet.result?.quantity == 2)
        precondition(sheet.result?.container == "carton")
        sheet.itemName = "500 g rice"
        sheet.save()
        precondition(sheet.result?.name == "rice" && sheet.result?.quantity == 1)
        precondition(sheet.result?.amount == 500 && sheet.result?.unit == "g")
        sheet.quantity = 4; sheet.quantityManuallySelected = true
        sheet.containerType = "bag"; sheet.containerManuallySelected = true
        sheet.sizeAmount = "750"; sheet.sizeUnit = "g"; sheet.measurementManuallySelected = true
        sheet.save()
        precondition(sheet.result?.quantity == 4 && sheet.result?.container == "bag")
        precondition(sheet.result?.amount == 750 && sheet.result?.unit == "g")
        sheet.itemName = "V8 Juice"; sheet.save()
        precondition(sheet.result?.name == "V8 Juice")
        sheet.result = nil; sheet.itemName = "-1 apples"; sheet.save()
        precondition(sheet.result == nil)
        let legacy = Data(#"{"name":"rice","container":"bag","zone":"Pantry","recordedAt":0}"#.utf8)
        let decoded = try JSONDecoder().decode(InventoryDefaults.self, from: legacy)
        precondition(decoded.sizeAmount == nil && decoded.sizeUnit == nil && decoded.subZone == nil)
        let measured = InventoryDefaults(name: "rice", container: "bag", zone: "Pantry", recordedAt: Date(),
            sizeAmount: 500, sizeUnit: "g", subZone: "Top shelf")
        let roundtrip = try JSONDecoder().decode(InventoryDefaults.self, from: JSONEncoder().encode(measured))
        precondition(roundtrip.sizeAmount == 500 && roundtrip.sizeUnit == "g" && roundtrip.subZone == "Top shelf")
        let switching = EntryFixture()
        switching.session.guestStore.inventoryItems = [ExistingItem(name: "Milk", zone: "Fridge", quantity: 3,
            containerType: "carton", sizeAmount: 500, sizeUnit: "ml", subZone: "Door", updatedAt: 1)]
        switching.itemName = "Milk"
        await switching.loadDefaults()
        switching.save()
        precondition(switching.result?.shelf == "Door" && switching.result?.amount == 500)
        switching.itemName = "Rice" // save before SwiftUI name-change/debounce handlers can run
        switching.save()
        precondition(switching.result?.zone == "Pantry" && switching.result?.shelf == nil)
        precondition(switching.result?.quantity == 1 && switching.result?.container == "")
        precondition(switching.result?.amount == nil && switching.result?.unit == nil)
        await switching.loadDefaults()
        switching.save()
        precondition(switching.result?.shelf == nil && switching.result?.amount == nil)
        switching.itemName = "Milk"
        await switching.loadDefaults()
        switching.quantityManuallySelected = true; switching.quantity = 7
        switching.containerManuallySelected = true; switching.containerType = "bag"
        switching.measurementManuallySelected = true; switching.sizeAmount = "750"; switching.sizeUnit = "g"
        switching.zoneManuallySelected = true; switching.zone = "Pantry"
        switching.itemName = "Rice"; switching.save()
        precondition(switching.result?.quantity == 7 && switching.result?.container == "bag")
        precondition(switching.result?.amount == 750 && switching.result?.unit == "g")
        precondition(switching.result?.zone == "Pantry" && switching.result?.shelf == nil)
        let remembered = EntryFixture()
        GroceryUsuals.shared.rows["rice"] = measured
        remembered.itemName = "Milk"
        remembered.session.guestStore.inventoryItems = switching.session.guestStore.inventoryItems
        await remembered.loadDefaults()
        remembered.itemName = "Rice"
        await remembered.loadDefaults()
        remembered.save()
        precondition(remembered.result?.shelf == "Top shelf" && remembered.result?.amount == 500)
        precondition(remembered.result?.unit == "g" && remembered.result?.container == "bag")
        GroceryUsuals.shared.rows = [:]
        let delayed = EntryFixture()
        delayed.itemName = "Milk"
        CrowdDB.delayNanoseconds = 300_000_000
        CrowdDB.suggestion = CrowdSuggestion(count: 3, avgQuantity: 9, topContainer: "carton")
        let pending = Task { @MainActor in await delayed.loadDefaults() }
        try await Task.sleep(nanoseconds: 700_000_000) // first-name crowd lookup is in flight
        delayed.itemName = "Rice"
        delayed.save()
        await pending.value
        delayed.save()
        precondition(delayed.result?.quantity == 1 && delayed.result?.container == "")
        precondition(delayed.result?.amount == nil && delayed.result?.shelf == nil)
        let dates = ExpiryFixture()
        dates.seed()
        precondition(!dates.hasExpiry && dates.expiryDate == dates.seededExpiry)
        dates.pick(dates.expiryDate)
        dates.save()
        precondition(dates.item.fieldProvenance?["expiry"]?.badge == .estimated)
        dates.pick(Date(timeIntervalSince1970: 200))
        dates.seed() // revisiting the step never overwrites a user-entered date
        dates.save()
        precondition(dates.expiryDate == Date(timeIntervalSince1970: 200))
        precondition(dates.item.fieldProvenance?["expiry"]?.badge == .userAdded)
        let unknown = ExpiryFixture()
        unknown.save()
        precondition(unknown.item.fieldProvenance == nil)
        print("PASS: AddItemSheet natural save, manual overrides and backward-compatible measurement defaults")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='stocked-entry-') as temp:
    path=Path(temp)
    (path/'Fixture.swift').write_text(fixture)
    (path/'Checks.swift').write_text('import Foundation\n'+checks)
    subprocess.run(['swiftc','-parse-as-library',str(root/'Stocked/QuantityParser.swift'),str(root/'Stocked/GroceryEntryPolicy.swift'),str(path/'Fixture.swift'),str(path/'Checks.swift'),'-o',str(path/'checks')],check=True)
    subprocess.run([str(path/'checks')],check=True)
