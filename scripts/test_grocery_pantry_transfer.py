#!/usr/bin/env python3
"""Execute exact production purchase-review/commit methods against in-memory boundaries.

No SwiftUI or persistence runtime is faked as a success claim: this checks the transfer
orchestration's selection, stale-review, authorization and undo contracts. The proposal
store, duplicate classifier and persistence dependencies are explicit in-memory doubles.
Quantity parsing, transfer value types, and the merge helper are production code.
"""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
view = (root/'Stocked/GroceryListView.swift').read_text()
methods = view[view.index('    private func beginPantryTransfer('):view.index('    var body: some View { editorialPresentation }')]
methods = methods.replace('private func ', 'func ')
review = (root/'Stocked/GroceryPantryReviewView.swift').read_text()
selection = review[review.index('struct GroceryPantrySelection:'):review.index('/// Reviewing a purchase')]
engine = (root/'Stocked/PurchaseDedupEngine.swift').read_text()
dtos = engine[engine.index('nonisolated enum PurchaseImportSource:'):engine.index('// MARK: - Engine')]
merge_source = (root/'Stocked/PurchaseDedupReviewView.swift').read_text()
merge_helper = '@MainActor ' + merge_source[merge_source.index('enum PurchaseImportMerge {'):]
fixture = r'''
import Foundation
enum StorageCategory: String { case pantry = "Pantry", fridge = "Fridge", freezer = "Freezer" }
struct LocalGroceryItem: Equatable {
 var id = UUID(); var name: String; var quantity = 1; var sizeText = ""; var isChecked = true
}
struct LocalInventoryItem: Equatable {
 var id = UUID(); var name: String; var level: Double; var zone: String; var quantity: Int
 var updatedAt = 0; var storageCategory: StorageCategory = .pantry; var subZone: String?
 var sizeAmount: Double?; var sizeUnit: String?; var containerType = "item"
 var purchaseDate: Date?; var addedBy: String?; var storePurchasedAt: String?; var lastConfirmedAt: Date?
}
struct CookingProfile { var brandPreferences: [String] = [] }
enum InventoryProposalOrigin: String { case groceryTransfer
 var defaultBadge: SourceBadge { .userAdded }
}
typealias Origin = InventoryProposalOrigin
enum SourceBadge { case userAdded }
struct FieldProvenance { var sourceID: String; var sourceName: String; var badge: SourceBadge }
enum InventoryProposalField: Hashable { case price, store, brand, size, expiry }
struct InventoryMetadataRefresh {
 var price: Double?; var storeName: String?; var brand: String?; var expiry: Date?
 var sizeAmount: Double?; var sizeUnit: String?
}
enum ProposalAction { case add(LocalInventoryItem), refreshMetadata(InventoryMetadataRefresh) }
enum MergePolicy { case storeCompatible }
struct ProposedChange {
 var itemID: UUID; var displayName: String; var action: ProposalAction
 var reason: String; var sourceBadge: SourceBadge; var fieldProvenance: [InventoryProposalField: FieldProvenance]
}
struct InventoryProposalBatch {
 var origin: Origin; var title: String; var changes: [ProposedChange]; var mergePolicy: MergePolicy
 static func reviewableAdd(item: LocalInventoryItem, origin: Origin, sourceID: String, reason: String) -> ProposedChange {
  ProposedChange(itemID: item.id, displayName: item.name, action: .add(item), reason: reason,
    sourceBadge: origin.defaultBadge, fieldProvenance: [:])
 }
}
struct ProposalResult { var changedItemIDs: Set<UUID> = [] }
typealias GuestDataStore = FixtureStore
@MainActor final class FixtureStore {
 var inventoryWrites = 0
 var inventoryItems: [LocalInventoryItem] = [] { didSet { inventoryWrites += 1 } }
 var groceryItems: [LocalGroceryItem] = []
 var cookingProfile = CookingProfile(); var failRefresh = false; var registeredUndo: [Bool] = []
 @discardableResult
 func applyProposalBatch(_ batch: InventoryProposalBatch, brandPreferences: [String], retailerID: String?, registerUndo: Bool) -> ProposalResult {
  registeredUndo.append(registerUndo)
  var result = ProposalResult()
  for change in batch.changes {
   switch change.action {
   case .add(let item): inventoryItems.append(item); result.changedItemIDs.insert(item.id)
   case .refreshMetadata(let fields):
    guard !failRefresh, let index = inventoryItems.firstIndex(where: { $0.id == change.itemID }) else { continue }
    if let value = fields.storeName { inventoryItems[index].storePurchasedAt = value }
    if let value = fields.sizeAmount { inventoryItems[index].sizeAmount = value }
    if let value = fields.sizeUnit { inventoryItems[index].sizeUnit = value }
    inventoryItems[index].lastConfirmedAt = Date()
    result.changedItemIDs.insert(change.itemID)
   }
  }
  return result
 }
}
@MainActor final class HouseholdSync {
 static let shared = HouseholdSync()
 enum Right: Hashable { case inventoryAdd, inventoryEdit, inventoryRemove, groceryAdd, groceryRemove }
 var denied: Set<Right> = []
 func authorize(_ right: Right) -> Bool { !denied.contains(right) }
}
@MainActor final class ReceiptDatabase {
 static let shared = ReceiptDatabase()
 func guessZone(for name: String) -> String { "Pantry" }
}
@MainActor final class PurchaseImportLog {
 static let shared = PurchaseImportLog(); var records: [PurchaseImportRecord] = []
 func currentTripID() -> String { "fixture-trip" }
 func record(_ rows: [PurchaseImportRecord]) { records += rows }
 func removeRecords(ids: Set<UUID>) { records.removeAll { ids.contains($0.id) } }
 func storeSegments(forTrip: String) -> [String] { [] }
}
@MainActor enum PurchaseDedupEngine {
 static func normalizedName(_ raw: String) -> String { raw.lowercased() }
 static func evaluate(candidates: [PurchaseImportCandidate], history: [PurchaseImportRecord]) -> [UUID: Bool] {
  // Always defer commit behind a duplicate-review fixture, so tests can simulate
  // household edits and explicit choices while the real production sheet is open.
  Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, true) })
 }
}
struct PurchaseDupReviewContext {
 var title: String; var candidates: [PurchaseImportCandidate]; var flags: [UUID: Bool]
}
enum Sheet { case pantryReview(GroceryPantryReviewContext), purchaseReview(PurchaseDupReviewContext) }
struct Session { var preferredStore = "Fixture shop" }
enum GroceryKnowledgeBase { static func retailer(matching: String) -> Retailer? { nil } }
struct Retailer { var id: String }
@MainActor final class ToastCenter {
 static let shared = ToastCenter(); var action: (() -> Void)?; var warnings: [String] = []
 func undo(_ title: String, action: @escaping () -> Void) { self.action = action }
 func warning(_ message: String) { warnings.append(message) }
}
enum HapticManager { static func success() {} }
func withAnimation(_ action: () -> Void) { action() }
@MainActor final class ReviewState {
 var grocerySheet: Sheet?; var pantrySelections: [UUID: GroceryPantrySelection] = [:]
 var pantryReviewHistory: [PurchaseImportRecord] = []; var pantryMergeTargets: [UUID: LocalInventoryItem] = [:]; var loopMessage: String?
}
// Match SwiftUI View's value semantics and nonmutating @State setters. The store
// is a reference as in the application; this wrapper does not alter method bodies.
@MainActor struct FixtureTransfer {
 let store = FixtureStore(); var session = Session(); private let state = ReviewState()
 var grocerySheet: Sheet? { get { state.grocerySheet } nonmutating set { state.grocerySheet = newValue } }
 var pantrySelections: [UUID: GroceryPantrySelection] {
  get { state.pantrySelections } nonmutating set { state.pantrySelections = newValue }
 }
 var pantryReviewHistory: [PurchaseImportRecord] {
  get { state.pantryReviewHistory } nonmutating set { state.pantryReviewHistory = newValue }
 }
 var pantryMergeTargets: [UUID: LocalInventoryItem] {
  get { state.pantryMergeTargets } nonmutating set { state.pantryMergeTargets = newValue }
 }
 var loopMessage: String? { get { state.loopMessage } nonmutating set { state.loopMessage = newValue } }
 func resolvedStore(for item: LocalGroceryItem) -> String { "Fixture shop" }
'''
checks = r'''
import Foundation
@main struct Checks {
 @MainActor static func main() {
  var count = 0
  var failures: [String] = []
  func check(_ value: @autoclosure () -> Bool, _ message: String) {
   if !value() { failures.append(message) }
   count += 1
  }
  func reset() {
   PurchaseImportLog.shared.records = []; HouseholdSync.shared.denied = []
   ToastCenter.shared.action = nil; ToastCenter.shared.warnings = []
  }
  func reviewed(_ transfer: FixtureTransfer, rows: [LocalGroceryItem], quantity: Int? = nil,
                storage: StorageCategory? = nil, include: Set<UUID>? = nil) -> [PurchaseImportCandidate] {
   transfer.beginPantryTransfer(rows)
   guard case .pantryReview(let context) = transfer.grocerySheet else { fatalError("Expected initial review") }
   var drafts = context.selections
   for index in drafts.indices {
    if let quantity { drafts[index].quantity = quantity }
    if let storage { drafts[index].storage = storage }
    drafts[index].included = include?.contains(drafts[index].id) ?? true
   }
   transfer.reviewPantryDuplicates(drafts.filter(\.included))
   guard case .purchaseReview(let review) = transfer.grocerySheet else { fatalError("Expected duplicate review") }
   return review.candidates
  }
  let milk = LocalGroceryItem(name: "Milk", quantity: 2, sizeText: "14 oz")
  let bread = LocalGroceryItem(name: "Bread", quantity: 1)
  reset()
  let transfer = FixtureTransfer(); transfer.store.groceryItems = [milk, bread]
  var oldMilk = LocalInventoryItem(name: "Milk", level: 0.2, zone: "Fridge", quantity: 1)
  oldMilk.storageCategory = .fridge; oldMilk.subZone = "Door"
  transfer.store.inventoryItems = [oldMilk]
  let candidates = reviewed(transfer, rows: [milk, bread], quantity: 3, include: [milk.id])
  check(transfer.store.inventoryItems == [oldMilk] && transfer.store.groceryItems == [milk, bread], "Review alone must not mutate records")
  transfer.commitPantryTransfer(candidates: candidates, resolutions: [:])
  check(transfer.store.groceryItems == [bread], "Unselected bought items must stay on the grocery list")
  let added = transfer.store.inventoryItems.last!
  check(added.quantity == 3, "Explicit review quantity must win over original grocery count")
  check(added.storageCategory == .fridge && added.subZone == "Door", "Existing storage/shelf must carry across")
  check(added.sizeAmount == 14 && added.sizeUnit == "oz", "Package size must remain separate from container count")
  check(PurchaseImportLog.shared.records.count == 1 && PurchaseImportLog.shared.records[0].quantity == 3, "History must reflect accepted quantity")
  ToastCenter.shared.action?()
  check(transfer.store.inventoryItems == [oldMilk] && transfer.store.groceryItems == [milk,bread], "Undo must restore both complete lists")
  check(PurchaseImportLog.shared.records.isEmpty, "Undo must remove its own import evidence")

  reset()
  let relocated = FixtureTransfer(); relocated.store.groceryItems = [milk]; relocated.store.inventoryItems = [oldMilk]
  let relocatedCandidates = reviewed(relocated, rows: [milk], storage: .freezer)
  relocated.commitPantryTransfer(candidates: relocatedCandidates, resolutions: [:])
  check(relocated.store.inventoryItems.last?.storageCategory == .freezer, "Explicit storage must win")
  check(relocated.store.inventoryItems.last?.subZone == nil, "Old-zone shelf must not follow a changed zone")

  for deleted in [false, true] {
   reset(); let stale = FixtureTransfer(); stale.store.groceryItems = [milk,bread]
   let cs = reviewed(stale, rows: [milk,bread])
   if deleted { stale.store.groceryItems.removeFirst() } else { stale.store.groceryItems[0].quantity = 8 }
   let before = stale.store.groceryItems
   stale.commitPantryTransfer(candidates: cs, resolutions: [:])
   check(stale.store.groceryItems == before && stale.store.inventoryItems.isEmpty && PurchaseImportLog.shared.records.isEmpty,
         "A stale changed/deleted source must prevent every mutation, including other candidates")
  }
  reset(); let staleHistory = FixtureTransfer(); staleHistory.store.groceryItems = [milk]
  let staleCandidates = reviewed(staleHistory, rows: [milk])
  let otherRecord = PurchaseImportRecord(normalizedName: "milk", displayName: "Milk")
  PurchaseImportLog.shared.records = [otherRecord]
  staleHistory.commitPantryTransfer(candidates: staleCandidates, resolutions: [:])
  check(staleHistory.store.inventoryItems.isEmpty && staleHistory.store.groceryItems == [milk] && PurchaseImportLog.shared.records == [otherRecord],
        "Import after review must force fresh duplicate review, preventing replay")

  for denied: HouseholdSync.Right in [.inventoryAdd,.groceryRemove] {
   reset(); let deniedTransfer = FixtureTransfer(); deniedTransfer.store.groceryItems = [milk]
   let cs = reviewed(deniedTransfer, rows: [milk]); HouseholdSync.shared.denied = [denied]
   deniedTransfer.commitPantryTransfer(candidates: cs, resolutions: [:])
   check(deniedTransfer.store.groceryItems == [milk] && deniedTransfer.store.inventoryItems.isEmpty && PurchaseImportLog.shared.records.isEmpty,
         "Unauthorized additions/removals must never delete source rows")
  }
  reset(); let merge = FixtureTransfer(); merge.store.inventoryItems = [oldMilk]; merge.store.groceryItems = [milk,bread]
  let mergeCandidates = reviewed(merge, rows: [milk,bread])
  merge.commitPantryTransfer(candidates: mergeCandidates, resolutions: [milk.id:.merge,bread.id:.skip])
  check(merge.store.groceryItems.isEmpty && merge.store.inventoryItems.count == 1, "Skip/merge handle bought rows without adding duplicates")
  check(merge.store.inventoryItems[0].quantity == oldMilk.quantity && merge.store.inventoryItems[0].level == oldMilk.level && merge.store.inventoryItems[0].lastConfirmedAt != nil, "Merge confirms stock without resetting its count or fill level")
  check(PurchaseImportLog.shared.records.isEmpty, "Skip/merge must not claim a new imported purchase")
  ToastCenter.shared.action?()
  check(merge.store.inventoryItems == [oldMilk] && merge.store.groceryItems == [milk,bread], "Undo must include merge changes and skipped source rows")

  reset(); let mergeDenied = FixtureTransfer(); mergeDenied.store.inventoryItems = [oldMilk]; mergeDenied.store.groceryItems = [milk]
  let md = reviewed(mergeDenied, rows: [milk]); HouseholdSync.shared.denied = [.inventoryEdit]
  mergeDenied.commitPantryTransfer(candidates: md, resolutions: [milk.id:.merge])
  check(mergeDenied.store.inventoryItems == [oldMilk] && mergeDenied.store.groceryItems == [milk], "Unauthorized merge cannot remove source")

  for targetState in 0..<3 {
   reset(); let staleMerge = FixtureTransfer(); staleMerge.store.groceryItems = [milk,bread]
   if targetState != 0 { staleMerge.store.inventoryItems = [oldMilk] }
   let cs = reviewed(staleMerge, rows: [milk,bread])
   if targetState == 1 { staleMerge.store.inventoryItems = [] }
   if targetState == 2 { staleMerge.store.inventoryItems[0].subZone = "New shelf" }
   let invBefore = staleMerge.store.inventoryItems
   staleMerge.commitPantryTransfer(candidates: cs, resolutions: [milk.id:.merge,bread.id:.keepBoth])
   check(staleMerge.store.inventoryItems == invBefore && staleMerge.store.groceryItems == [milk,bread] && PurchaseImportLog.shared.records.isEmpty,
         "Missing/deleted/edited merge target blocks the entire batch before additions or deletion")
  }
  reset(); let locatedMerge = FixtureTransfer(); locatedMerge.store.groceryItems = [milk]
  locatedMerge.store.inventoryItems = [oldMilk]
  let locatedCandidates = reviewed(locatedMerge, rows: [milk], quantity: 9, storage: .freezer)
  locatedMerge.commitPantryTransfer(candidates: locatedCandidates, resolutions: [milk.id:.merge])
  check(locatedMerge.store.groceryItems.isEmpty && locatedMerge.store.inventoryItems[0].storageCategory == .freezer,
        "Successful merge applies explicitly reviewed storage")
  check(locatedMerge.store.inventoryItems[0].subZone == nil && locatedMerge.store.inventoryItems[0].quantity == oldMilk.quantity,
        "Merge clears old-zone shelf without increasing stock count")
  check(locatedMerge.store.registeredUndo == [false], "Transfer merge disables nested proposal undo")
  ToastCenter.shared.action?()
  check(locatedMerge.store.inventoryItems == [oldMilk] && locatedMerge.store.groceryItems == [milk],
        "Transfer undo restores reviewed merge location and source row")

  reset(); let rejectedMerge = FixtureTransfer(); rejectedMerge.store.groceryItems = [milk]
  rejectedMerge.store.inventoryItems = [oldMilk]; rejectedMerge.store.failRefresh = true
  let rejectedCandidates = reviewed(rejectedMerge, rows: [milk], storage: .freezer)
  rejectedMerge.commitPantryTransfer(candidates: rejectedCandidates, resolutions: [milk.id:.merge])
  check(rejectedMerge.store.groceryItems == [milk] && rejectedMerge.store.inventoryItems == [oldMilk],
        "A merge rejected by the proposal store retains its grocery row and original location")
  check(PurchaseImportLog.shared.records.isEmpty, "Failed merge does not fabricate import history")

  // The real production helper runs below; only proposal application/persistence is
  // doubled. These checks fail if it returns success without the requested target,
  // ignores an application rejection, updates another same-name row, or bypasses rights.
  reset(); let helperStore = FixtureStore()
  var anotherMilk = oldMilk; anotherMilk.id = UUID(); anotherMilk.subZone = "Top shelf"
  helperStore.inventoryItems = [oldMilk,anotherMilk]
  check(PurchaseImportMerge.refreshExisting(in: helperStore, name: "Milk", storeName: "Other shop",
        targetID: anotherMilk.id, storage: .freezer, subZone: "Drawer", registerUndo: false),
        "Helper accepts a successful exact-target refresh")
  check(helperStore.inventoryItems[0] == oldMilk && helperStore.inventoryItems[1].storageCategory == .freezer && helperStore.inventoryItems[1].subZone == "Drawer",
        "Helper edits only exact target among duplicate names")
  check(helperStore.inventoryItems[1].quantity == anotherMilk.quantity && helperStore.inventoryItems[1].level == anotherMilk.level && helperStore.inventoryItems[1].lastConfirmedAt != nil && helperStore.inventoryItems[1].storePurchasedAt == "Other shop",
        "Helper refreshes metadata without counting purchase twice")
  check(helperStore.registeredUndo == [false] && helperStore.inventoryWrites > 1,
        "Helper forwards undo choice and writes location through observed store array")
  let helperBaseline = helperStore.inventoryItems
  check(!PurchaseImportMerge.refreshExisting(in: helperStore, name: "Milk", targetID: UUID()), "Helper fails for deleted target")
  check(!PurchaseImportMerge.refreshExisting(in: helperStore, name: "Bread", targetID: anotherMilk.id), "Helper fails for renamed/mismatched target")
  check(helperStore.inventoryItems == helperBaseline, "Unavailable target causes no mutation")
  helperStore.failRefresh = true
  check(!PurchaseImportMerge.refreshExisting(in: helperStore, name: "Milk", targetID: anotherMilk.id, storage: .pantry),
        "Helper reports rejected proposal instead of success")
  check(helperStore.inventoryItems == helperBaseline, "Rejected refresh must not apply reviewed location")
  helperStore.failRefresh = false; HouseholdSync.shared.denied = [.inventoryEdit]
  let proposalsBeforeDenial = helperStore.registeredUndo.count
  check(!PurchaseImportMerge.refreshExisting(in: helperStore, name: "Milk", targetID: anotherMilk.id, storage: .pantry),
        "Helper itself enforces edit permission for all callers")
  check(helperStore.inventoryItems == helperBaseline && helperStore.registeredUndo.count == proposalsBeforeDenial,
        "Unauthorized helper returns before proposal application")
  HouseholdSync.shared.denied = []
  check(PurchaseImportMerge.refreshExisting(in: helperStore, name: "Milk", storeName: "Default caller"),
        "Existing callers retain default matching behavior")
  check(helperStore.inventoryItems[0].storageCategory == oldMilk.storageCategory && helperStore.inventoryItems[0].subZone == oldMilk.subZone && helperStore.registeredUndo.last == true,
        "Default helper caller preserves location and existing undo behavior")

  reset(); let skip = FixtureTransfer(); skip.store.groceryItems = [milk]
  let skipCandidates = reviewed(skip, rows: [milk]); HouseholdSync.shared.denied = [.inventoryAdd,.inventoryEdit]
  skip.commitPantryTransfer(candidates: skipCandidates, resolutions: [milk.id:.skip])
  check(skip.store.groceryItems.isEmpty && skip.store.inventoryItems.isEmpty, "Skip needs removal rights but no inventory mutation rights")

  reset(); let unrelated = FixtureTransfer(); unrelated.store.groceryItems = [milk]
  let unrelatedCandidates = reviewed(unrelated, rows: [milk]); unrelated.commitPantryTransfer(candidates: unrelatedCandidates, resolutions: [:])
  PurchaseImportLog.shared.records.append(otherRecord)
  ToastCenter.shared.action?()
  check(unrelated.store.inventoryItems.isEmpty && unrelated.store.groceryItems == [milk] && PurchaseImportLog.shared.records == [otherRecord],
        "Undo removes only its own import records, preserving unrelated newer imports")

  reset(); let addOnlyUndo = FixtureTransfer(); addOnlyUndo.store.groceryItems = [milk]
  let addOnlyCandidates = reviewed(addOnlyUndo, rows: [milk])
  addOnlyUndo.commitPantryTransfer(candidates: addOnlyCandidates, resolutions: [:])
  HouseholdSync.shared.denied = [.inventoryEdit]
  ToastCenter.shared.action?()
  check(addOnlyUndo.store.inventoryItems.isEmpty && addOnlyUndo.store.groceryItems == [milk],
        "Undo of a pure addition requires removal, not unrelated edit rights")

  for kind in 0..<5 {
   reset(); let guarded = FixtureTransfer(); guarded.store.groceryItems = [milk]
   if kind == 3 { guarded.store.inventoryItems = [oldMilk] }
   let cs = reviewed(guarded, rows: [milk])
   guarded.commitPantryTransfer(candidates: cs, resolutions: kind == 3 ? [milk.id:.merge] : [:])
   if kind == 0 { guarded.store.inventoryItems[0].name = "Household edit" }
   if kind == 1 { guarded.store.groceryItems.append(bread) }
   if kind == 2 { HouseholdSync.shared.denied = [.inventoryRemove] }
   if kind == 3 { HouseholdSync.shared.denied = [.inventoryEdit] }
   if kind == 4 { HouseholdSync.shared.denied = [.groceryAdd] }
   let invBeforeUndo = guarded.store.inventoryItems, groceryBeforeUndo = guarded.store.groceryItems
   let historyBeforeUndo = PurchaseImportLog.shared.records
   ToastCenter.shared.action?()
   check(guarded.store.inventoryItems == invBeforeUndo && guarded.store.groceryItems == groceryBeforeUndo && PurchaseImportLog.shared.records == historyBeforeUndo,
         "Undo must leave all records untouched after newer edits or permission loss")
   check(!ToastCenter.shared.warnings.isEmpty, "Rejected undo must explain why")
  }
  if !failures.isEmpty {
   for message in failures { FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8)) }
   fatalError("Grocery pantry transfer: \(failures.count) of \(count) checks failed")
  }
  print("PASS: grocery pantry transfer production orchestration: \(count) checks")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='stocked-grocery-transfer-') as directory:
    path = Path(directory)
    (path/'Fixture.swift').write_text(fixture + methods + '\n}\n' + selection + dtos + merge_helper)
    (path/'Checks.swift').write_text(checks)
    subprocess.run(['swiftc','-parse-as-library',str(root/'Stocked/QuantityParser.swift'),
                    str(path/'Fixture.swift'),str(path/'Checks.swift'),'-o',str(path/'checks')],check=True)
    subprocess.run([str(path/'checks')],check=True)
