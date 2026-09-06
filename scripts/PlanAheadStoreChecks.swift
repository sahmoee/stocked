// Native boundary harness: production PlanAheadStore + PlanAheadCore + MealPlanExchange.
// External persistence, permission, sync and active-planner owners are in-memory fixtures.
// This does not test disk durability, real household networking, UIKit or inventory accounting.
// xcrun swiftc Stocked/PlanAheadCore.swift Stocked/MealPlanExchange.swift Stocked/PlanAheadStore.swift scripts/PlanAheadStoreChecks.swift -o /tmp/stocked-plan-store
import Foundation

nonisolated protocol HouseholdSyncable: Codable, Identifiable, Sendable where ID == UUID {
    var updatedAt: Double { get set }
    var lastWriterID: String { get set }
}

nonisolated enum FeatureStoreKeys {
    static let scheduledMeals = "dates", mealPlanRules = "rules", mealPlanTemplates = "templates"
}

@MainActor private enum MemoryFiles { static var data: [String: Data] = [:] }
@MainActor final class FeatureStore<Element: Codable & Sendable> {
    let key: String
    init(key: String) { self.key = key }
    func load() -> [Element] { MemoryFiles.data[key].flatMap { try? JSONDecoder().decode([Element].self, from: $0) } ?? [] }
    func save(_ values: [Element]) { MemoryFiles.data[key] = try! JSONEncoder().encode(values) }
    func flush() { }
}

nonisolated enum HouseholdPermission { case mealPlanEdit }
@MainActor final class HouseholdSync {
    static let shared = HouseholdSync()
    var permitted = true
    func can(_ permission: HouseholdPermission) -> Bool { permitted }
    func authorize(_ permission: HouseholdPermission) -> Bool { permitted }
}

@MainActor final class FeatureSync {
    static let shared = FeatureSync()
    var isApplyingRemote = false
    private var clock: Double = 1000
    enum Keys { static let scheduledMeals = "dates", mealPlanRules = "rules", mealPlanTemplates = "templates" }
    nonisolated static func stamped<T: HouseholdSyncable>(_ value: T) -> T {
        var result = value
        result.updatedAt = 1_750_000_000_123.125
        result.lastWriterID = "fixture-member-with-a-realistic-long-household-identifier"
        return result
    }
    func stampMutation<T: HouseholdSyncable & Equatable>(_ key: String, old: [T], current: [T]) -> [T] {
        guard !isApplyingRemote else { return current }
        return current.map { value in
            let previous = old.first { $0.id == value.id }
            guard previous != value else { return value }
            var result = Self.stamped(value)
            clock += 1; result.updatedAt += clock
            return result
        }
    }
}

// The active-owner wire shape used by production; additional UI metadata is irrelevant here.
nonisolated struct PlannedMeal: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var dayIndex: Int
    var title: String
    var servings: Int
    var ingredients: [String]
    var mealType: String
    var isCooked = false
    var isBuilding = false
    var updatedAt: Double = 0
    var lastWriterID = ""
}

@MainActor final class GuestDataStore {
    private var stamping = false
    var inventoryUnits = 10
    var deductionCalls = 0
    var plannedMeals: [PlannedMeal] = [] { didSet {
        guard !stamping else { return }
        stamping = true; defer { stamping = false }
        guard HouseholdSync.shared.permitted else { plannedMeals = oldValue; return }
        for i in plannedMeals.indices where oldValue.first(where: { $0.id == plannedMeals[i].id }) != plannedMeals[i] {
            plannedMeals[i].updatedAt += 1
            plannedMeals[i].lastWriterID = "active-member"
        }
    } }
    func flushPendingSaves() { }
    func deductIngredients(_ ingredients: [String]) { deductionCalls += 1; inventoryUnits -= ingredients.count }
}

@MainActor @main struct PlanAheadStoreChecks {
    static var count = 0
    static var failures: [String] = []
    static let store = PlanAheadStore.shared
    static let zone = "America/Chicago"

    static func check(_ condition: Bool, _ message: String) {
        count += 1
        if !condition { failures.append(message); print("FAIL: \(message)") }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); check(false, message) } catch { check(true, message) }
    }
    static func rejectsAsync(_ message: String, _ body: () async throws -> Void) async {
        do { try await body(); check(false, message) } catch { check(true, message) }
    }
    static func remote(_ change: () -> Void) {
        FeatureSync.shared.isApplyingRemote = true; change(); FeatureSync.shared.isApplyingRemote = false
    }
    static func reset() {
        HouseholdSync.shared.permitted = true
        remote { store.scheduledMeals = []; store.rules = []; store.templates = [] }
        store.clearUndo()
    }
    static func meal(_ title: String = "Lentil soup") throws -> ScheduledMeal {
        ScheduledMeal(civilDate: try PlanAheadCore.dateKey(for: Date(), timeZoneID: zone), timeZoneID: zone,
                      title: title, mealType: "Dinner", servings: 4, ingredients: ["2 cups lentils"])
    }
    static func install(occurrences: Int = 2) throws -> (MealPlanTemplate, MealPlanRule) {
        let template = MealPlanTemplate(name: "Soup week", entries: [MealPlanTemplateEntry(dayOffset: 0, title: "Lentil soup", mealType: "Dinner", servings: 4, ingredients: ["2 cups lentils"])])
        try store.saveTemplate(template, expected: nil)
        let rule = MealPlanRule(name: "Weekly soup", templateID: template.id,
            startDate: try PlanAheadCore.dateKey(for: Date(), timeZoneID: zone), timeZoneID: zone, intervalWeeks: 1, occurrences: occurrences)
        try store.saveRule(rule, expected: nil)
        return (store.templates[0], store.rules[0])
    }

    static func main() async throws {
        reset()
        var installed = try install()
        var review = try await store.expansionReview(for: installed.1)
        var changedRule = installed.1; changedRule.name = "Updated rule"
        try store.saveRule(changedRule, expected: installed.1)
        rejects("stale rule expansion cannot commit") { _ = try store.apply(review) }
        rejects("stale rule editor cannot overwrite newer rule") { try store.saveRule(installed.1, expected: installed.1) }
        rejects("stale rule delete cannot remove newer rule") { try store.removeRule(installed.1) }

        reset(); installed = try install()
        review = try await store.expansionReview(for: installed.1)
        var changedTemplate = installed.0; changedTemplate.entries[0].title = "New soup"
        try store.saveTemplate(changedTemplate, expected: installed.0)
        rejects("stale template expansion cannot commit") { _ = try store.apply(review) }
        rejects("stale template editor cannot overwrite newer template") { try store.saveTemplate(installed.0, expected: installed.0) }
        rejects("referenced template cannot be removed") { try store.removeTemplate(store.templates[0]) }

        reset(); installed = try install()
        review = try await store.expansionReview(for: installed.1)
        HouseholdSync.shared.permitted = false
        rejects("revoked permission blocks reviewed expansion") { _ = try store.apply(review) }
        rejects("revoked permission blocks direct save") { try store.saveMeal(meal(), expected: nil) }
        let before = store.scheduledMeals
        store.scheduledMeals = [try meal()]
        check(store.scheduledMeals == before && store.lastError != nil, "direct local mutation is reverted without permission")
        let fromRemote = try meal("Remote date")
        remote { store.scheduledMeals = [fromRemote] }
        check(store.scheduledMeals == [fromRemote], "remote pull can apply for a viewer without restamping")
        let revision = store.revision
        remote { store.scheduledMeals = [fromRemote] }
        check(store.revision == revision, "unchanged remote pull does not bump revision")

        reset(); installed = try install()
        review = try await store.expansionReview(for: installed.1)
        check(try store.apply(review) == 2, "reviewed occurrences are added")
        let firstAdded = store.scheduledMeals[0]
        try store.removeMeal(firstAdded)
        check(store.scheduledMeals.first(where: { $0.id == firstAdded.id })?.isSkipped == true, "removing recurring date keeps a skip marker")
        await rejectsAsync("repeat expansion cannot recreate existing or skipped occurrences") { _ = try await store.expansionReview(for: store.rules[0]) }
        changedRule = store.rules[0]; changedRule.occurrences = 3
        try store.saveRule(changedRule, expected: store.rules[0])
        review = try await store.expansionReview(for: store.rules[0])
        check(review.additions.count == 1 && !review.additions.contains(where: { $0.id == firstAdded.id }), "extending rule proposes only the new occurrence")
        check(try store.apply(review) == 1, "new occurrence commits without replacing skip")
        check(store.scheduledMeals.count == 3 && store.scheduledMeals.first(where: { $0.id == firstAdded.id })?.isSkipped == true, "saved dates and skip remain intact")

        reset(); installed = try install(occurrences: 3)
        review = try await store.expansionReview(for: installed.1)
        _ = try store.apply(review)
        let unchangedID = store.scheduledMeals[2].id
        var editedDate = store.scheduledMeals[0]; editedDate.title = "Edited after expansion"
        try store.saveMeal(editedDate, expected: store.scheduledMeals[0])
        let deletedDateID = store.scheduledMeals[1].id
        remote { store.scheduledMeals.removeAll { $0.id == deletedDateID } }
        check(try store.undoDates() == 1, "date undo removes only unchanged additions")
        check(store.scheduledMeals.count == 1 && store.scheduledMeals[0].title == editedDate.title && !store.scheduledMeals.contains(where: { $0.id == unchangedID || $0.id == deletedDateID }), "date undo preserves later edit and never resurrects deletion")

        reset()
        let active = GuestDataStore()
        let original = try meal()
        try store.saveMeal(original, expected: nil)
        var week = try await store.weekReview(from: store.scheduledMeals, active: active.plannedMeals)
        var changedDate = store.scheduledMeals[0]; changedDate.servings = 6
        try store.saveMeal(changedDate, expected: store.scheduledMeals[0])
        rejects("dated edit after active preview prevents activation") { _ = try store.activate(week, store: active) }
        week = try await store.weekReview(from: store.scheduledMeals, active: active.plannedMeals)
        active.plannedMeals.append(PlannedMeal(dayIndex: 1, title: "Other dinner", servings: 2, ingredients: [], mealType: "Dinner"))
        rejects("concurrent active planner edit prevents activation") { _ = try store.activate(week, store: active) }
        week = try await store.weekReview(from: store.scheduledMeals, active: active.plannedMeals)
        HouseholdSync.shared.permitted = false
        rejects("permission revoked after active review blocks activation") { _ = try store.activate(week, store: active) }
        HouseholdSync.shared.permitted = true
        check(try store.activate(week, store: active) == 1, "active handoff adds one actual planned meal")
        check(active.inventoryUnits == 10 && active.deductionCalls == 0 && active.plannedMeals.allSatisfy { !$0.isCooked }, "activation neither calls deduction nor marks meals cooked")
        check(store.scheduledMeals[0].movedToWeek, "active handoff marks source date moved")
        await rejectsAsync("moved occurrence does not activate twice") { _ = try await store.weekReview(from: store.scheduledMeals, active: active.plannedMeals) }
        rejects("moved source cannot be edited as a new dated meal") { try store.saveMeal(store.scheduledMeals[0], expected: store.scheduledMeals[0]) }
        let movedID = store.scheduledMeals[0].id
        check(active.plannedMeals.contains { $0.id == PlanAheadCore.activeMealID(for: movedID) }, "active ID is stable from source occurrence")
        check(try store.undoWeek(store: active) == 1 && !store.scheduledMeals[0].movedToWeek, "unchanged active undo removes handoff and restores dated availability")
        check(active.plannedMeals.count == 1 && active.plannedMeals[0].title == "Other dinner", "active undo preserves unrelated existing meal")

        reset()
        let duplicates = GuestDataStore()
        let first = try meal("Crème soup"), second = try meal(" creme  SOUP ")
        try store.saveMeal(first, expected: nil); try store.saveMeal(second, expected: nil)
        week = try await store.weekReview(from: store.scheduledMeals, active: [])
        check(week.proposals.count == 1, "in-batch normalized active duplicate skipped")
        let proposal = week.proposals[0]
        var priorCopy = PlannedMeal(dayIndex: 0, title: "Renamed old active copy", servings: 4, ingredients: [], mealType: "Lunch")
        priorCopy.id = proposal.activeMealID
        duplicates.plannedMeals = [priorCopy]
        let filtered = try await store.weekReview(from: store.scheduledMeals, active: duplicates.plannedMeals)
        check(!filtered.proposals.contains { $0.activeMealID == priorCopy.id }, "stable identity duplicate is skipped even after active title changes")
        let sameMeal = PlannedMeal(dayIndex: 0, title: " CREME SOUP ", servings: 9, ingredients: [], mealType: "dinner")
        await rejectsAsync("existing active title and slot duplicate is not added again") {
            _ = try await store.weekReview(from: store.scheduledMeals, active: [sameMeal])
        }

        reset()
        let forUndo = GuestDataStore()
        for title in ["One", "Two", "Three"] { try store.saveMeal(meal(title), expected: nil) }
        week = try await store.weekReview(from: store.scheduledMeals, active: [])
        _ = try store.activate(week, store: forUndo)
        let editedID = forUndo.plannedMeals[0].id, removedID = forUndo.plannedMeals[1].id
        forUndo.plannedMeals[0].title = "Edited active meal"
        forUndo.plannedMeals.removeAll { $0.id == removedID }
        check(try store.undoWeek(store: forUndo) == 1, "active undo removes only unchanged active/date pair")
        check(forUndo.plannedMeals.count == 1 && forUndo.plannedMeals[0].id == editedID, "active undo preserves edited meal and does not resurrect removed copy")
        check(store.scheduledMeals.filter(\.movedToWeek).count == 2, "edited and removed active copies keep their moved history")

        reset()
        let changedSourceOwner = GuestDataStore()
        for title in ["Source one", "Source two", "Source three"] { try store.saveMeal(meal(title), expected: nil) }
        week = try await store.weekReview(from: store.scheduledMeals, active: [])
        _ = try store.activate(week, store: changedSourceOwner)
        let changedSourceID = store.scheduledMeals[0].id, deletedSourceID = store.scheduledMeals[1].id
        remote {
            store.scheduledMeals[0].title = "Household source edit"
            store.scheduledMeals.removeAll { $0.id == deletedSourceID }
        }
        check(try store.undoWeek(store: changedSourceOwner) == 1, "active undo also requires an unchanged dated source")
        check(changedSourceOwner.plannedMeals.count == 2 && store.scheduledMeals.first(where: { $0.id == changedSourceID })?.title == "Household source edit" && !store.scheduledMeals.contains(where: { $0.id == deletedSourceID }), "source edits and deletions are preserved during active undo")

        reset()
        let remoteDates = try (0..<601).map { index in try meal("Remote \(index)") }
        remote { store.scheduledMeals = remoteDates }
        check(store.scheduledMeals.count == 601, "over-limit accepted remote union is not truncated")
        rejects("over-limit dated collection cannot grow locally") { try store.saveMeal(meal("Extra"), expected: nil) }
        try store.removeMeal(store.scheduledMeals[0])
        check(store.scheduledMeals.count == 600, "over-limit remote union can be reduced")

        reset()
        let encoder = JSONEncoder(), templateCap = 64 * 1024
        let fullLine = String(repeating: "x", count: 500)
        let largeTemplate = MealPlanTemplate(name: "Existing template", entries: [MealPlanTemplateEntry(
            dayOffset: 0, title: "Existing meal", mealType: "Dinner", servings: 2,
            ingredients: Array(repeating: fullLine, count: 75))])
        try store.saveTemplate(largeTemplate, expected: nil)
        var boundaryTemplate = MealPlanTemplate(name: "Near the storage boundary", entries: [MealPlanTemplateEntry(
            dayOffset: 0, title: "Boundary meal", mealType: "Dinner", servings: 2, ingredients: [])])
        let targetBytes = templateCap - 1
        while try encoder.encode(store.templates + [boundaryTemplate]).count < targetBytes - 503 {
            boundaryTemplate.entries[0].ingredients.append(fullLine)
        }
        let gap = targetBytes - (try encoder.encode(store.templates + [boundaryTemplate]).count)
        boundaryTemplate.entries[0].ingredients.append(String(repeating: "x", count: gap - 3))
        let beforeTemplates = store.templates
        let unstampedBytes = try encoder.encode(beforeTemplates + [boundaryTemplate]).count
        let stampedBytes = try encoder.encode(beforeTemplates + [FeatureSync.stamped(boundaryTemplate)]).count
        check(unstampedBytes <= templateCap && stampedBytes > templateCap, "boundary fixture crosses collection cap only when real-shaped stamps are included")
        rejects("template save preflights stamp growth before accepting near-cap payload") { try store.saveTemplate(boundaryTemplate, expected: nil) }
        check(store.templates == beforeTemplates, "stamp-budget rejection preserves existing templates")
        while try encoder.encode(beforeTemplates + [FeatureSync.stamped(boundaryTemplate)]).count > templateCap - 64 {
            boundaryTemplate.entries[0].ingredients.removeLast()
        }
        try store.saveTemplate(boundaryTemplate, expected: nil)
        check(try encoder.encode(store.templates).count <= templateCap && store.templates.count == 2, "reduced template succeeds and stays within cap after actual stamps")

        reset()
        var recordBoundary = MealPlanTemplate(name: "Individual entry boundary", entries: [MealPlanTemplateEntry(
            dayOffset: 0, title: "Large template meal", mealType: "Dinner", servings: 2, ingredients: [])])
        let recordTarget = PlanAheadCore.maximumEncodedBytes - 1
        while try encoder.encode(recordBoundary).count < recordTarget - 503 {
            recordBoundary.entries[0].ingredients.append(fullLine)
        }
        let recordGap = recordTarget - (try encoder.encode(recordBoundary).count)
        recordBoundary.entries[0].ingredients.append(String(repeating: "x", count: recordGap - 3))
        try PlanAheadCore.validate(recordBoundary)
        check(try encoder.encode(FeatureSync.stamped(recordBoundary)).count > PlanAheadCore.maximumEncodedBytes,
              "valid unstamped individual record crosses48KiB only after its sharing stamp")
        rejects("individual record limit is checked after stamps even when total collection fits") { try store.saveTemplate(recordBoundary, expected: nil) }
        check(store.templates.isEmpty, "oversized stamped record is not partially stored")
        while try encoder.encode(FeatureSync.stamped(recordBoundary)).count > PlanAheadCore.maximumEncodedBytes - 64 {
            recordBoundary.entries[0].ingredients.removeLast()
        }
        try store.saveTemplate(recordBoundary, expected: nil)
        try PlanAheadCore.validate(store.templates[0])
        check(true, "accepted stamped record remains valid for later expansion")

        reset()
        let staleOwner = GuestDataStore()
        try store.saveMeal(meal("Deleted before preview begins"), expected: nil)
        let staleSource = store.scheduledMeals
        try store.removeMeal(store.scheduledMeals[0])
        await rejectsAsync("stale source removed before weekReview cannot activate a phantom meal") {
            let stale = try await store.weekReview(from: staleSource, active: [])
            _ = try store.activate(stale, store: staleOwner)
        }
        check(staleOwner.plannedMeals.isEmpty, "stale source does not change active planner")

        reset()
        let staleEditOwner = GuestDataStore()
        try store.saveMeal(meal("Old title before preview"), expected: nil)
        let oldSource = store.scheduledMeals
        var currentSource = store.scheduledMeals[0]; currentSource.title = "New household title"
        try store.saveMeal(currentSource, expected: store.scheduledMeals[0])
        await rejectsAsync("source edited before weekReview cannot activate the older contents") {
            let stale = try await store.weekReview(from: oldSource, active: [])
            _ = try store.activate(stale, store: staleEditOwner)
        }
        check(staleEditOwner.plannedMeals.isEmpty, "stale edited source leaves active planner unchanged")

        if failures.isEmpty { print("Plan ahead store: \(count) native boundary checks passed") }
        else {
            print("Plan ahead store: \(count - failures.count)/\(count) passed; \(failures.count) failure(s)")
            Foundation.exit(1)
        }
    }
}
