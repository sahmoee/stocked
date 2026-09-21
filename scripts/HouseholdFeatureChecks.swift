import Foundation

// In-memory boundaries only. The tested FeatureSync, domain models, permission policy,
// merge policy, and extracted KitchenFeatureSnapshot are production sources.
nonisolated struct FeatureFixture: HouseholdSyncable, Equatable {
    var id = UUID()
    var updatedAt: Double = 0
    var lastWriterID = ""
    var title = "Fixture", name = "Fixture", label = "Fixture", crop = "Fixture"
    var contents = "Fixture", place = "Fixture", recipeTitle = "Fixture"
    var isFresh = true
}
typealias LeftoverEntry = FeatureFixture
typealias EaterProfile = FeatureFixture
typealias KitchenEvent = FeatureFixture
typealias SharedExpense = FeatureFixture
typealias HarvestEntry = FeatureFixture
typealias ContainerLabel = FeatureFixture
typealias TakeoutEntry = FeatureFixture
nonisolated struct StoreLayout: Codable, Sendable { var store = ""; var trips = 0; var updatedAt: Double = 0; var lastWriterID = "" }
@MainActor final class LeftoversStore { static let shared = LeftoversStore(); var entries: [LeftoverEntry] = []; func flush() {} }
@MainActor final class FamilyProfileStore { static let shared = FamilyProfileStore(); var profiles: [EaterProfile] = []; func flush() {} }
@MainActor final class EventStore { static let shared = EventStore(); var events: [KitchenEvent] = []; func flush() {} }
@MainActor final class SplitStore { static let shared = SplitStore(); var expenses: [SharedExpense] = []; var people: [String] = []; func flush() {} }
@MainActor final class StoreLayoutStore { static let shared = StoreLayoutStore(); var layouts: [StoreLayout] = []; var activeStore = ""; func flush() {} }
@MainActor final class HarvestStore { static let shared = HarvestStore(); var entries: [HarvestEntry] = []; func flush() {} }
@MainActor final class ContainerLabelStore { static let shared = ContainerLabelStore(); var labels: [ContainerLabel] = []; func flush() {} }
@MainActor final class TakeoutStore { static let shared = TakeoutStore(); var entries: [TakeoutEntry] = []; func flush() {} }
@MainActor final class HouseholdCookStore { static let shared = HouseholdCookStore(); var entries: [FeatureFixture] = [] }
@MainActor final class PlanAheadStore {
    static let shared = PlanAheadStore()
    var scheduledMeals: [ScheduledMeal] = [], rules: [MealPlanRule] = [], templates: [MealPlanTemplate] = []
    var flushes = 0
    var undoClears = 0
    func flush() { flushes += 1 }
    func clearUndo() { undoClears += 1 }
}
extension SmartCookbookRule: HouseholdSyncable {}
@MainActor final class SmartCookbookStore {
    static let shared = SmartCookbookStore(); var rules: [SmartCookbookRule] = []; var flushes = 0
    func flush() { flushes += 1 }
}
@MainActor final class SyncConflictLog {
    static let shared = SyncConflictLog()
    func record(entityType: String, entityName: String, replaced: String, winning: String, writer: String) {}
}
@MainActor final class HouseholdSync {
    static let shared = HouseholdSync()
    var operations: [(UUID, HouseholdEntityType, HouseholdOperationType)] = []
    var pendingOps: [PendingHouseholdOperation] = []
    func enqueue(entityID: UUID, entityType: HouseholdEntityType, operation: HouseholdOperationType) {
        operations.append((entityID, entityType, operation))
    }
}

@main @MainActor struct HouseholdFeatureChecks {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); count += 1
    }
    static func main() throws {
        let sync = FeatureSync.shared
        sync.wipeAll()
        defer { sync.wipeAll() }
        let planScope = FeatureSync.collections(inventory: false, mealPlans: true, recipes: false)
        let recipeScope = FeatureSync.collections(inventory: false, mealPlans: false, recipes: true)
        check(planScope == ["scheduledMeals", "mealPlanRules", "mealPlanTemplates"], "Planning scope does not inherit inventory/recipe sharing")
        check(recipeScope == ["smartCookbooks"], "Cookbook uses recipe sharing only")
        for type in [HouseholdEntityType.scheduledMeal, .mealPlanRule, .mealPlanTemplate] {
            check(HouseholdMutationAuthorization.requiredPermission(entityType: type, operationType: .delete) == .mealPlanEdit, "Planning mutation permission")
            check(HouseholdSharingScope.includes(type, inventory: false, grocery: false, recipes: false, mealPlans: true), "Planning queue works when inventory disabled")
            check(!HouseholdSharingScope.includes(type, inventory: true, grocery: true, recipes: true, mealPlans: false), "Disabled planning keeps queue private")
        }
        check(HouseholdMutationAuthorization.requiredPermission(entityType: .smartCookbook, operationType: .restore) == .recipeEdit, "Cookbook restore permission")
        check(!HouseholdSharingScope.includes(.smartCookbook, inventory: true, grocery: true, recipes: false, mealPlans: true), "Disabled recipe sharing keeps cookbook queue")
        var meal = ScheduledMeal(civilDate: "2026-09-12", timeZoneID: "America/Chicago", title: "Fixture", mealType: "Dinner", servings: 2, ingredients: ["1 cup rice"])
        var cookbook = SmartCookbookRule(); cookbook.name = "Fixture cookbook"
        PlanAheadStore.shared.scheduledMeals = [meal]
        SmartCookbookStore.shared.rules = [cookbook]
        let hiddenID = UUID(), planID = UUID(), bookID = UUID()
        sync.recordDelete(collection: "leftovers", id: hiddenID)
        sync.recordDelete(collection: "scheduledMeals", id: planID)
        sync.recordDelete(collection: "smartCookbooks", id: bookID)
        let payload = sync.pushPayload(included: planScope)
        check(payload["scheduledMeals"] != nil && payload["leftovers"] == nil && payload["smartCookbooks"] == nil, "Payload obeys domain sharing")
        check(payload["smartCookbooksDeleted"] == nil, "Unsent cookbook deletion stays local")
        let checkpoint = payload["featureSyncCheckpoint"] as! [String: Any]
        check(Set((checkpoint["tombstoneRevisions"] as! [String: UInt64]).keys) == ["scheduledMeals"], "Checkpoint carries only shared domains")
        let captured = sync.tombstoneSnapshot(included: planScope)
        check(captured == ["scheduledMeals": [planID.uuidString]], "Capture only transmitted tombstones")
        sync.acknowledgeTombstones(captured)
        check(sync.tombstoneSnapshot()["smartCookbooks"] == [bookID.uuidString] && sync.tombstoneSnapshot()["leftovers"] == [hiddenID.uuidString], "Unsent deletions survive acknowledgement")
        let oldDates = sync.tombstoneDateSnapshot(included: recipeScope)
        let oldDeletes = sync.tombstoneSnapshot(included: recipeScope)
        sync.recordDelete(collection: "smartCookbooks", id: bookID)
        sync.acknowledgeTombstones(oldDeletes, capturedDates: oldDates)
        check(sync.tombstoneSnapshot()["smartCookbooks"] == [bookID.uuidString], "A fresh re-delete survives an earlier request acknowledgement")
        HouseholdSync.shared.operations = []
        meal = sync.stampMutation("scheduledMeals", old: [], current: [meal])[0]
        check(HouseholdSync.shared.operations.last?.1 == .scheduledMeal && HouseholdSync.shared.operations.last?.2 == .restore, "New/restored dated ID has domain restore operation")
        var edited = meal; edited.title = "Edited"; edited.updatedAt += 1
        _ = sync.stampMutation("scheduledMeals", old: [meal], current: [edited])
        check(HouseholdSync.shared.operations.last?.2 == .update, "Already-stamped local edit still queued")
        _ = sync.stampMutation("smartCookbooks", old: [cookbook], current: [])
        check(HouseholdSync.shared.operations.last?.1 == .smartCookbook && HouseholdSync.shared.operations.last?.2 == .delete, "Cookbook deletion uses correct entity")
        let snapshot = sync.backupSnapshot()
        let bytes = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(KitchenFeatureSnapshot.self, from: bytes)
        check(decoded.scheduledMeals?.count == 1 && decoded.smartCookbooks?.count == 1, "New feature backup roundtrip")
        var legacyJSON = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        for key in ["scheduledMeals", "mealPlanRules", "mealPlanTemplates", "smartCookbooks"] { legacyJSON[key] = nil }
        let legacy = try JSONDecoder().decode(KitchenFeatureSnapshot.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        check(legacy.scheduledMeals == nil && legacy.smartCookbooks == nil, "Old feature snapshots decode missing additive fields")
        sync.restoreBackupSnapshot(legacy, merge: false)
        check(PlanAheadStore.shared.scheduledMeals.count == 1 && SmartCookbookStore.shared.rules.count == 1, "Old replace backup does not erase absent new stores")
        var replacement = snapshot; var changed = meal; changed.title = "Backup version"
        replacement.scheduledMeals = [changed]
        sync.restoreBackupSnapshot(replacement, merge: true)
        check(PlanAheadStore.shared.scheduledMeals[0].title == "Fixture", "Merge backup keeps current version of known ID")
        sync.restoreBackupSnapshot(replacement, merge: false)
        check(PlanAheadStore.shared.scheduledMeals[0].title == "Backup version", "Explicit replacement applies new collection")
        check(PlanAheadStore.shared.flushes > 0 && SmartCookbookStore.shared.flushes > 0, "Both owners flushed after restore")
        check(PlanAheadStore.shared.undoClears > 1, "Backup replacement clears prior undo state")
        var remote = changed; remote.title = "Remote version"; remote.updatedAt = 9_999_999_999_999
        let rows = try JSONSerialization.jsonObject(with: JSONEncoder().encode([remote]))
        sync.apply(["scheduledMeals": rows], included: recipeScope)
        check(PlanAheadStore.shared.scheduledMeals[0].title == "Backup version", "Disabled planning pull is ignored")
        sync.apply(["scheduledMeals": rows], included: planScope)
        check(PlanAheadStore.shared.scheduledMeals[0].title == "Remote version", "Enabled planning pull applies LWW")
        HouseholdSync.shared.pendingOps = [PendingHouseholdOperation(entityID: remote.id, entityType: .scheduledMeal, operationType: .restore)]
        sync.apply(["scheduledMeals": [], "scheduledMealsDeleted": [remote.id.uuidString]], included: planScope)
        check(PlanAheadStore.shared.scheduledMeals.count == 1, "A pending restore survives an earlier-batch tombstone response")
        HouseholdSync.shared.pendingOps = []
        sync.apply(["scheduledMeals": [], "scheduledMealsDeleted": [remote.id.uuidString]], included: planScope)
        check(PlanAheadStore.shared.scheduledMeals.isEmpty, "Acknowledged remote deletion applies after pending restore clears")
        sync.wipeAll()
        check(PlanAheadStore.shared.scheduledMeals.isEmpty && SmartCookbookStore.shared.rules.isEmpty && sync.tombstoneSnapshot().isEmpty, "Erase clears stores and ledgers")
        print("Household feature checks passed: \(count)")
    }
}
