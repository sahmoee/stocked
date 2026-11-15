#!/usr/bin/env python3
"""Small real-model Swift backup compatibility checks; no app/SDK build or app storage.
"""
from pathlib import Path
import subprocess
import tempfile
import os

ROOT = Path(__file__).resolve().parents[1]
FIXTURES = ROOT / 'scripts/fixtures/backup'

def block(text, signature):
    a = text.index(signature); i = text.index('{', a) + 1; depth = 1
    while depth:
        depth += (text[i] == '{') - (text[i] == '}'); i += 1
    return text[a:i]

def read(path, baseline=False):
    if baseline:
        return subprocess.check_output(['git', 'show', '21be85da:' + path], cwd=ROOT, text=True)
    return (ROOT / path).read_text()

SUPPORT = r'''
import Foundation
import CoreFoundation
struct ProductIdentity {}
enum ProductCatalog { static func identity(for: String, brand: String?, barcode: String?) -> ProductIdentity { ProductIdentity() } }
enum KitchenThresholds { static let expiringSoonDays = 3; static let lowFillLevel = 0.25 }
enum SourceBadge: String, Codable, Sendable { case userAdded = "User added", needsReview = "Needs review"; var confidence: Double { 1 } }
struct FieldProvenance: Codable, Hashable, Sendable { var sourceID: String }
struct PortableRecipeSource: Codable, Equatable, Sendable { var format: String }
// Unused ancillary metadata types are stubs; all imported row model declarations,
// their Codable implementations, snapshot decoder, import path and apply are production.
struct KitchenPreferences: Codable, Sendable {}
struct KitchenFeatureSnapshot: Codable, Sendable {}
enum KitchenBackupError: Error { case invalidFormat, malformedPackage, decryptionFailed }
struct KitchenBackupManifest {}
struct Key {}
enum KitchenBackupKeyStore { static func key(matching: String) throws -> Key? { nil } }
extension KitchenBackupManifest { var keyID: String { "" } }
enum KitchenBackupCodec {
 static func isEncryptedPackage(_ data: Data) -> Bool { false }
 static func manifest(in data: Data) -> KitchenBackupManifest? { nil }
 static func open(_ data: Data, using: Key) throws -> (snapshot: KitchenSnapshot, manifest: KitchenBackupManifest) { fatalError() }
}
enum Log { static let transfer = Logger() }
struct Logger { func notice(_ message: String) {} }
enum Section: Hashable { case profile, inventory, grocery, mealHistory, recipes, mealPlans, preferences, features }
struct KitchenRestoreSelection { var sections: Set<Section> = [.inventory,.grocery,.recipes,.mealPlans]; var merge = false }
final class GuestDataStore {
 var displayName = "Existing"
 var inventoryItems = [LocalInventoryItem(name: "Keep inventory")]
 var groceryItems = [LocalGroceryItem(name: "Keep grocery")]
 var pastMeals: [LocalPastMeal] = []; var userRecipes: [UserRecipe] = []
 var savedGeneratedRecipes: [GeneratedRecipe] = []; var plannedMeals: [PlannedMeal] = []
 func flushPendingSaves() {}
}
final class InventoryOpenedHistory { static let shared = InventoryOpenedHistory(); var clears = 0; func clear() { clears += 1 } }
final class HouseholdSync { static let shared = HouseholdSync(); var activitySuppressed = false }
final class StockedPhoneWatchBridge { static let shared = StockedPhoneWatchBridge(); var invalidations = 0; func invalidateKitchen() throws { invalidations += 1 } }
final class Session { func applyPreferences(_ p: KitchenPreferences) {} }
final class FeatureSync { static let shared = FeatureSync(); func restoreBackupSnapshot(_ p: KitchenFeatureSnapshot, merge: Bool) {} }
final class KitchenTransferManager {
 var session: Session? = nil
 func normKey(_ s: String) -> String { s.lowercased() }
 static func legacyManifest(snapshot: KitchenSnapshot, data: Data) -> KitchenBackupManifest { KitchenBackupManifest() }
 __DECODE__
 __READABLE__
 __LENIENT__
 __APPLY__
 func restore(_ data: Data, into store: GuestDataStore, merge: Bool = false) throws { var selection = KitchenRestoreSelection(); selection.merge = merge; try apply(decodeBackup(data).snapshot, into: store, selection: selection) }
}
'''
CHECKS = r'''
@main struct Checks {
 static func main() throws {
  let args = CommandLine.arguments

  if args[1] == "expiration" {
   NSTimeZone.default = TimeZone(identifier: args[3])!
   let store = GuestDataStore()
   try KitchenTransferManager().restore(Data(contentsOf: URL(fileURLWithPath: args[2])), into: store)
   guard store.inventoryItems.count == 2 else { print("FAIL expiration row count"); exit(1) }
   for row in store.inventoryItems {
    guard let expiration = row.expirationDate else { print("FAIL expiration missing"); exit(1) }
    let day = Calendar.current.dateComponents([.year,.month,.day], from: expiration)
    guard day.year == 2026 && day.month == 10 && day.day == 22 && row.quantity == 2 && row.updatedAt == 1770000000123 else {
     print("FAIL expiration local day \(args[3]): \(day)"); exit(1)
    }
   }
   print("PASS fresh + edited backup expirations -> actual Swift local calendar \(args[3]): 2026-10-22; quantity/epoch metadata retained")
   return
  }
  if args[1] == "generate" {
   var inv = LocalInventoryItem(name: "Milk", level: 0.75, zone: "Fridge", quantity: 3, containerType: "carton", sizeAmount: 2, sizeUnit: "L")
   inv.id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
   inv.expirationDate = Date(timeIntervalSinceReferenceDate: 800000000.125)
   inv.updatedAt = 1770000000123; inv.isLeftover = true; inv.hasStash = true
   let grocery = LocalGroceryItem(quantity: 4, id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, name: "Rice", isChecked: true, isRecommended: true, recipeId: "recipe-source", updatedAt: 1770000000456)
   var ingredient = RecipeIngredient(name: "Milk", amount: "2 cups")
   ingredient.id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!; ingredient.isOptional = true; ingredient.quantity = 2; ingredient.unit = "cup"
   var recipe = UserRecipe(title: "Pudding")
   recipe.id = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
   recipe.ingredients = [ingredient]; recipe.isFavorited = true; recipe.cookCount = 2
   recipe.dateCreated = Date(timeIntervalSinceReferenceDate: 700000000.25)
   recipe.lastCooked = Date(timeIntervalSinceReferenceDate: 750000000.5)
   recipe.updatedAt = 1770000000789
   var plan = PlannedMeal(dayIndex: 2, title: "Pudding", servings: 3, ingredients: ["Milk"], mealType: "Dinner")
   plan.id = UUID(uuidString: "00000000-0000-0000-0000-000000000005")!; plan.isCooked = true; plan.cookAheadStatus = .stored
   let snap = KitchenSnapshot(displayName: "Fixture kitchen", inventoryItems: [inv], groceryItems: [grocery], pastMeals: [], userRecipes: [recipe], plannedMeals: [plan])
   let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
   try encoder.encode(snap).write(to: URL(fileURLWithPath: args[2])); return
  }
  var failed: [String] = []; var count = 0
  func check(_ name: String, _ ok: Bool) { count += 1; print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failed.append(name) } }
  let manager = KitchenTransferManager()
  let clears = InventoryOpenedHistory.shared.clears
  let freshStore = GuestDataStore()
  try manager.restore(Data(#"{"inventoryItems":[],"groceryItems":[]}"#.utf8), into: freshStore, merge: true)
  check("merge restore preserves device opened metadata", InventoryOpenedHistory.shared.clears == clears)
  try manager.restore(Data(#"{"inventoryItems":[],"groceryItems":[]}"#.utf8), into: freshStore)
  check("replace restore clears stale device opened metadata", InventoryOpenedHistory.shared.clears == clears + 1)
  for (name, text) in [
   ("unknown", "{\"unrelated\":[1]}"),
   ("metadata-only", "{\"schemaVersion\":3,\"displayName\":\"Unknown\"}"),
   ("legacy external backup", "{\"inventory\":[{\"name\":\"Milk\"}],\"grocery\":[],\"planned\":[],\"userRecipes\":[]}"),
   ("bad section", "{\"inventoryItems\":{\"name\":\"Milk\"}}"),
   ("null section", "{\"inventoryItems\":null}"),
   ("bad row", "{\"inventoryItems\":[{\"name\":\"Milk\",\"quantity\":\"broken\"}]}"),
   ("bad plan", "{\"inventoryItems\":[],\"plannedMeals\":[{\"title\":\"Missing fields\"}]}"),
   ("bad recipe", "{\"inventoryItems\":[],\"userRecipes\":[{\"title\":42}]}"),
   ("envelope", "{\"manifest\":{},\"inventoryItems\":[]}")
  ] {
   let store = GuestDataStore(); let inv = store.inventoryItems[0].id; let gro = store.groceryItems[0].id
   let before = StockedPhoneWatchBridge.shared.invalidations
   var refused = false
   do { try manager.restore(Data(text.utf8), into: store) } catch { refused = true }
   check(name + " rejected before mutation", refused && store.inventoryItems.first?.id == inv && store.groceryItems.first?.id == gro && StockedPhoneWatchBridge.shared.invalidations == before)
  }
  let empty = GuestDataStore()
  try manager.restore(Data(#"{"inventoryItems":[],"groceryItems":[],"plannedMeals":[],"userRecipes":[]}"#.utf8), into: empty)
  check("explicit empty canonical Replace", empty.inventoryItems.isEmpty && empty.groceryItems.isEmpty)
  let legacy = GuestDataStore()
  try manager.restore(Data(#"{"inventoryItems":[{"name":"Old milk","expirationDate":"2026-10-22T00:00:00Z"}],"groceryItems":[{"name":"Old rice"}]}"#.utf8), into: legacy)
  check("known legacy canonical ISO date", legacy.inventoryItems.count == 1 && legacy.inventoryItems[0].expirationDate != nil && legacy.groceryItems.count == 1)

  let v1 = GuestDataStore()
  let legacyBefore = Date()
  let v1Data = Data(#"{"schemaVersion":1,"inventoryItems":[],"groceryItems":[],"userRecipes":[{"id":"00000000-0000-0000-0000-000000000008","title":"Old recipe","ingredients":["2 cups rice","salt"]}],"plannedMeals":[{"id":"00000000-0000-0000-0000-000000000009","title":"Old plan","dayIndex":1,"servings":2,"ingredients":["Rice"],"mealType":"Dinner"}]}"#.utf8)
  do {
   try manager.restore(v1Data, into: v1)
   let recipe = v1.userRecipes.first; let plan = v1.plannedMeals.first
   check("legacy v1 recipe native defaults and string ingredients", recipe?.id.uuidString == "00000000-0000-0000-0000-000000000008" && recipe?.ingredients.map(\.name) == ["2 cups rice","salt"] && recipe?.ingredients.map(\.amount) == ["",""] && recipe?.ingredients.allSatisfy { !$0.isOptional } == true && recipe?.dishRole == .unspecified && recipe?.servings == 4)
   check("legacy v1 recipe local adoption time", recipe.map { $0.dateCreated >= legacyBefore && $0.dateCreated <= Date() } ?? false)
   check("legacy v1 plan additive defaults", plan?.id.uuidString == "00000000-0000-0000-0000-000000000009" && plan?.dayIndex == 1 && plan?.servings == 2 && plan?.ingredients == ["Rice"] && plan?.isBuilding == false && plan?.cookAheadStatus == CookAheadStatus.none && plan?.isCooked == false)
  } catch {
   check("legacy v1 recipe native defaults and string ingredients", false)
   check("legacy v1 recipe local adoption time", false)
   check("legacy v1 plan additive defaults", false)
  }
  let typedLegacy = GuestDataStore()
  let typedData = Data(#"{"userRecipes":[{"id":"00000000-0000-0000-0000-000000000008","title":"Typed old recipe","isFavorited":true,"dateCreated":700000000.25,"updatedAt":1770000000001,"ingredients":[{"id":"00000000-0000-0000-0000-000000000007","name":"Rice","amount":"2 cups","quantity":2,"unit":"cup","notes":"Keep this"}]}]}"#.utf8)
  do {
   try manager.restore(typedData, into: typedLegacy)
   let recipe = typedLegacy.userRecipes.first
   check("legacy typed ingredient preserves supplied metadata", recipe?.dateCreated == Date(timeIntervalSinceReferenceDate: 700000000.25) && recipe?.updatedAt == 1770000000001 && recipe?.isFavorited == true && recipe?.ingredients.first?.id.uuidString == "00000000-0000-0000-0000-000000000007" && recipe?.ingredients.first?.quantity == 2 && recipe?.ingredients.first?.notes == "Keep this" && recipe?.ingredients.first?.isOptional == false)
  } catch { check("legacy typed ingredient preserves supplied metadata", false) }
  for (label, text) in [
   ("missing required name", #"{"inventoryItems":[{}]}"#),
   ("bad supplied recipe ID", #"{"userRecipes":[{"id":"not-uuid","title":"Bad ID"}]}"#),
   ("bad supplied ingredient flag", #"{"userRecipes":[{"title":"Bad flag","ingredients":[{"name":"Rice","isOptional":"yes"}]}]}"#),
   ("bad supplied ingredient shape", #"{"userRecipes":[{"title":"Bad shape","ingredients":{"name":"Rice"}}]}"#),
   ("bad supplied plan flag", #"{"plannedMeals":[{"title":"Bad flag","dayIndex":1,"servings":2,"ingredients":[],"mealType":"Dinner","isBuilding":"yes"}]}"#)
  ] {
   let store = GuestDataStore(); let oldID = store.inventoryItems[0].id
   var refused = false
   do { try manager.restore(Data(text.utf8), into: store) } catch { refused = true }
   check(label + " rejected atomically", refused && store.inventoryItems.first?.id == oldID)
  }
  if args.count > 2 {
   let canonical = try JSONDecoder().decode(KitchenSnapshot.self, from: Data(contentsOf: URL(fileURLWithPath: args[2])))
   let store = GuestDataStore()
   try manager.restore(Data(contentsOf: URL(fileURLWithPath: args[3])), into: store)
   check("External export inventory actual model", store.inventoryItems == canonical.inventoryItems)
   check("External export grocery actual model", store.groceryItems == canonical.groceryItems)
   check("External export recipes actual model", store.userRecipes == canonical.userRecipes)
   check("External export plans actual model", store.plannedMeals == canonical.plannedMeals)

   let freshStore = GuestDataStore()
   let freshData = try Data(contentsOf: URL(fileURLWithPath: args[4]))
   let original = try JSONSerialization.jsonObject(with: freshData) as! [String: Any]
   let sourceRecipe = (original["userRecipes"] as! [[String: Any]])[0]
   check("fresh external recipe has no original creation date", sourceRecipe["dateCreated"] == nil)
   let beforeAdoption = Date()
   do {
    try manager.restore(freshData, into: freshStore)
    let afterAdoption = Date()
    check("fresh recipe Replace retains every section", freshStore.inventoryItems == canonical.inventoryItems && freshStore.groceryItems == canonical.groceryItems && freshStore.plannedMeals == canonical.plannedMeals && freshStore.userRecipes.count == 1)
    let adopted = freshStore.userRecipes.first
    check("fresh recipe local adoption bounded to import", adopted.map { $0.dateCreated >= beforeAdoption && $0.dateCreated <= afterAdoption } ?? false)
    check("fresh recipe core fields and IDs preserved", adopted?.id.uuidString == "00000000-0000-0000-0000-000000000006" && adopted?.title == "Fresh pudding" && adopted?.isFavorited == true && adopted?.ingredients.first?.id.uuidString == "00000000-0000-0000-0000-000000000007" && adopted?.ingredients.first?.name == "Milk" && adopted?.ingredients.first?.isOptional == false)
   } catch {
    check("fresh recipe Replace retains every section", false)
    check("fresh recipe local adoption bounded to import", false)
    check("fresh recipe core fields and IDs preserved", false)
   }
   // Change only metadata in an otherwise valid row. Missing is admissible;
   // malformed or explicitly null creation dates must still reject atomically.
   for (label, badDate) in [("malformed", "not-a-date" as Any), ("null", NSNull() as Any)] {
    var root = original
    var rows = root["userRecipes"] as! [[String: Any]]
    rows[0]["dateCreated"] = badDate; root["userRecipes"] = rows
    let current = GuestDataStore(); let id = current.inventoryItems[0].id
    var refused = false
    do { try manager.restore(JSONSerialization.data(withJSONObject: root), into: current) } catch { refused = true }
    check(label + " creation date rejected without mutation", refused && current.inventoryItems.first?.id == id)
   }
  }
  print("CHECKS=\(count) FAILED=" + failed.joined(separator: ","))
  if !failed.isEmpty { exit(1) }
 }
}
'''

def swift_fixture(baseline):
    models = read('Stocked/Models.swift')
    names = ['StorageCategory','LocalInventoryItem','InventoryConfidence','InventoryConfidenceAssessment','NutritionFacts','RecipeIngredient','UserRecipe','LocalPastMeal','LocalGroceryItem','LocalRecipe','GeneratedRecipe','RecipeIngredientLine','PlannedMeal','CookAheadStatus']
    declarations = []
    for name in names:
        kind = 'enum' if name in ['StorageCategory','InventoryConfidence','CookAheadStatus'] else 'struct'
        declarations.append(block(models, 'nonisolated ' + kind + ' ' + name + ':'))
    declarations.append(block(read('Stocked/CookingSessionModel.swift'), 'nonisolated enum DishRole:'))
    declarations.append(block(models, 'nonisolated extension Double'))
    transfer = read('Stocked/KitchenTransferManager.swift', baseline)
    snapshot = block(transfer, 'nonisolated struct KitchenSnapshot:')
    methods = {'__DECODE__': block(transfer, 'private func decodeBackup('), '__APPLY__': block(transfer, 'private func apply(')}
    methods['__READABLE__'] = '' if baseline else block(transfer, 'nonisolated static func decodeReadableSnapshot(')
    legacy = []
    for name in ['lenientSnapshot', 'lenientInventoryItem','lenientGroceryItem','lenientPastMeal','lenientUserRecipe']:
        signature = ('nonisolated static func ' if name == 'lenientSnapshot' else 'private nonisolated static func ') + name + '('
        legacy.append(block(transfer, signature))
    methods['__LENIENT__'] = '\n'.join(legacy)
    support = SUPPORT
    for key,value in methods.items(): support = support.replace(key,value)
    # Replace only the OSLog interpolation in one notice; no decoder/apply logic.
    return support + '\n' + '\n'.join(declarations) + '\n' + snapshot + '\n' + CHECKS


def main():
    with tempfile.TemporaryDirectory(prefix='stocked-backup-interop-') as directory:
        work = Path(directory)
        source = work / 'Checks.swift'
        source.write_text(swift_fixture(False))
        exe = work / 'checks'
        subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path',
                        str(work / 'swift-cache'), str(source), '-o', str(exe)], check=True)
        subprocess.run([str(exe), 'check', str(FIXTURES / 'ios-canonical.json'),
                        str(FIXTURES / 'external-canonical.json'),
                        str(FIXTURES / 'external-fresh-recipe.json')], check=True)
        for zone, name in [('America/Chicago', 'expiration-chicago.json'),
                           ('UTC', 'expiration-utc.json')]:
            subprocess.run([str(exe), 'expiration', str(FIXTURES / name), zone],
                           env={**os.environ, 'TZ': zone}, check=True)


if __name__ == '__main__':
    main()
