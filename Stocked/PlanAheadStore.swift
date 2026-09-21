import Foundation
import Observation

nonisolated struct PlanExpansionReview: Sendable {
    let rule: MealPlanRule
    let template: MealPlanTemplate
    let revision: UInt64
    let additions: [ScheduledMeal]
}

nonisolated struct PlanWeekReview: Sendable {
    let revision: UInt64
    let active: [PlannedMeal]
    let proposals: [PlanActivationProposal]
    let source: [ScheduledMeal]
}

/// A feature owner in the existing LocalDatabase/FeatureSync system, not a new recipe database.
/// Dated records never reserve food or become cooking candidates without a reviewed handoff.
@MainActor @Observable final class PlanAheadStore {
    static let shared = PlanAheadStore()
    @ObservationIgnored private let mealsFile = FeatureStore<ScheduledMeal>(key: FeatureStoreKeys.scheduledMeals)
    @ObservationIgnored private let rulesFile = FeatureStore<MealPlanRule>(key: FeatureStoreKeys.mealPlanRules)
    @ObservationIgnored private let templatesFile = FeatureStore<MealPlanTemplate>(key: FeatureStoreKeys.mealPlanTemplates)
    @ObservationIgnored private var stamping = false
    private(set) var revision: UInt64 = 0
    private(set) var lastError: String?
    @ObservationIgnored private var addedDates: [ScheduledMeal] = []
    @ObservationIgnored private var activatedMeals: [PlannedMeal] = []
    @ObservationIgnored private var activatedDates: [ScheduledMeal] = []
    private(set) var canUndoDates = false
    private(set) var canUndoWeek = false

    var scheduledMeals: [ScheduledMeal] = [] { didSet {
        guard !stamping, scheduledMeals != oldValue else { return }; stamping = true
        defer { stamping = false }
        guard mayApply() else { scheduledMeals = oldValue; return }
        scheduledMeals = FeatureSync.shared.stampMutation(FeatureSync.Keys.scheduledMeals, old: oldValue, current: scheduledMeals)
        mealsFile.save(scheduledMeals); revision &+= 1
    } }
    var rules: [MealPlanRule] = [] { didSet {
        guard !stamping, rules != oldValue else { return }; stamping = true
        defer { stamping = false }
        guard mayApply() else { rules = oldValue; return }
        rules = FeatureSync.shared.stampMutation(FeatureSync.Keys.mealPlanRules, old: oldValue, current: rules)
        rulesFile.save(rules); revision &+= 1
    } }
    var templates: [MealPlanTemplate] = [] { didSet {
        guard !stamping, templates != oldValue else { return }; stamping = true
        defer { stamping = false }
        guard mayApply() else { templates = oldValue; return }
        templates = FeatureSync.shared.stampMutation(FeatureSync.Keys.mealPlanTemplates, old: oldValue, current: templates)
        templatesFile.save(templates); revision &+= 1
    } }

    private init() {
        stamping = true
        scheduledMeals = mealsFile.load(); rules = rulesFile.load(); templates = templatesFile.load()
        stamping = false
    }

    enum Failure: LocalizedError {
        case permission, changed, missingTemplate, noAdditions, limit(String)
        var errorDescription: String? {
            switch self {
            case .permission: "Your household role cannot edit meal plans."
            case .changed: "The plan changed during review. Close this preview and review the latest version."
            case .missingTemplate: "This template is no longer available. Choose another template."
            case .noAdditions: "There are no new meals to add. Existing, skipped and already-used meals are kept."
            case .limit(let message): message
            }
        }
    }

    func flush() { mealsFile.flush(); rulesFile.flush(); templatesFile.flush() }

    private func mayApply() -> Bool {
        if FeatureSync.shared.isApplyingRemote || HouseholdSync.shared.can(.mealPlanEdit) { return true }
        lastError = Failure.permission.localizedDescription
        return false
    }

    private func authorize() throws {
        guard HouseholdSync.shared.authorize(.mealPlanEdit) else { throw Failure.permission }
        lastError = nil
    }

    /// Remote unions/restores remain complete. Local writes can reduce an over-limit union,
    /// but never silently truncate another member's accepted records to satisfy a local cap.
    private func checkBudget<T: HouseholdSyncable & Equatable>(_ next: [T], old: [T], count: Int, bytes: Int) throws {
        let encoder = JSONEncoder()
        let previous = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Budget changed/new records as they will travel, including household stamps.
        // Accepted remote records stay intact; local reductions of an oversized union remain possible.
        let wirePreview = try next.map { value in
            guard previous[value.id] != value else { return value }
            let stamped = FeatureSync.stamped(value)
            guard try encoder.encode(stamped).count <= PlanAheadCore.maximumEncodedBytes else {
                throw Failure.limit("This planning entry has too much text to share. Shorten its ingredient lines or use fewer template meals before saving.")
            }
            return stamped
        }
        guard next.count <= max(count, old.count),
              try encoder.encode(wirePreview).count <= max(bytes, encoder.encode(old).count) else {
            throw Failure.limit("This planning collection is full. Use a smaller schedule or remove unneeded entries before adding more.")
        }
    }

    func saveTemplate(_ value: MealPlanTemplate, expected: MealPlanTemplate?) throws {
        try authorize(); try PlanAheadCore.validate(value)
        guard templates.first(where: { $0.id == value.id }) == expected else { throw Failure.changed }
        var next = templates.filter { $0.id != value.id }; next.append(value)
        try checkBudget(next, old: templates, count: 20, bytes: 64 * 1024)
        templates = next; flush()
    }

    func saveRule(_ value: MealPlanRule, expected: MealPlanRule?) throws {
        try authorize(); try PlanAheadCore.validate(value)
        guard templates.contains(where: { $0.id == value.templateID }) else { throw Failure.missingTemplate }
        guard rules.first(where: { $0.id == value.id }) == expected else { throw Failure.changed }
        var next = rules.filter { $0.id != value.id }; next.append(value)
        try checkBudget(next, old: rules, count: 50, bytes: 16 * 1024)
        rules = next; flush()
    }

    func saveMeal(_ value: ScheduledMeal, expected: ScheduledMeal?) throws {
        try authorize(); try PlanAheadCore.validate(value)
        guard scheduledMeals.first(where: { $0.id == value.id }) == expected else { throw Failure.changed }
        if expected?.movedToWeek == true {
            throw Failure.limit("This meal has already been added to the active week. Edit it in the active planner; its dated record stays as a reference.")
        }
        var next = scheduledMeals.filter { $0.id != value.id }; next.append(value)
        try checkBudget(next, old: scheduledMeals, count: 600, bytes: 256 * 1024)
        scheduledMeals = next; flush()
    }

    func skip(_ expected: ScheduledMeal) throws {
        var value = expected; value.isSkipped.toggle()
        try saveMeal(value, expected: expected)
    }

    func removeTemplate(_ expected: MealPlanTemplate) throws {
        try authorize()
        guard templates.first(where: { $0.id == expected.id }) == expected else { throw Failure.changed }
        guard !rules.contains(where: { $0.templateID == expected.id }) else {
            throw Failure.limit("Remove the repeat schedules using this template first. Existing dated meals will stay.")
        }
        templates.removeAll { $0.id == expected.id }; flush()
    }

    func removeRule(_ expected: MealPlanRule) throws {
        try authorize()
        guard rules.first(where: { $0.id == expected.id }) == expected else { throw Failure.changed }
        rules.removeAll { $0.id == expected.id }; flush()
    }

    func removeMeal(_ expected: ScheduledMeal) throws {
        try authorize()
        guard scheduledMeals.first(where: { $0.id == expected.id }) == expected else { throw Failure.changed }
        if expected.ruleID != nil && !expected.movedToWeek {
            if !expected.isSkipped { try skip(expected) }
        } else {
            scheduledMeals.removeAll { $0.id == expected.id }; flush()
        }
    }

    func expansionReview(for expected: MealPlanRule) async throws -> PlanExpansionReview {
        guard let rule = rules.first(where: { $0.id == expected.id }), rule == expected else { throw Failure.changed }
        guard let template = templates.first(where: { $0.id == rule.templateID }) else { throw Failure.missingTemplate }
        let existing = scheduledMeals, version = revision
        let work = Task.detached(priority: .userInitiated) {
            try PlanAheadCore.expand(rule: rule, template: template, existing: existing)
        }
        let additions = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard version == revision else { throw Failure.changed }
        guard !additions.isEmpty else { throw Failure.noAdditions }
        return PlanExpansionReview(rule: rule, template: template, revision: version, additions: additions)
    }

    func apply(_ review: PlanExpansionReview) throws -> Int {
        try authorize()
        guard revision == review.revision, rules.first(where: { $0.id == review.rule.id }) == review.rule,
              templates.first(where: { $0.id == review.template.id }) == review.template else { throw Failure.changed }
        let next = scheduledMeals + review.additions
        try checkBudget(next, old: scheduledMeals, count: 600, bytes: 256 * 1024)
        scheduledMeals = next
        let ids = Set(review.additions.map(\.id))
        addedDates = scheduledMeals.filter { ids.contains($0.id) }
        canUndoDates = !addedDates.isEmpty; flush()
        return addedDates.count
    }

    func weekReview(from source: [ScheduledMeal], active: [PlannedMeal]) async throws -> PlanWeekReview {
        guard currentSourceMatches(source) else { throw Failure.changed }
        let version = revision
        let work = Task.detached(priority: .userInitiated) {
            let eligible = try PlanAheadCore.activationProposals(from: source)
            var keys = Set(active.map { MealPlanExchange.duplicateKey(day: $0.dayIndex, title: $0.title, type: $0.mealType) })
            var ids = Set(active.map(\.id))
            return eligible.filter { item in
                let key = MealPlanExchange.duplicateKey(day: item.dayOffset, title: item.title, type: item.mealType)
                return ids.insert(item.activeMealID).inserted && keys.insert(key).inserted
            }
        }
        let proposals = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
        try Task.checkCancellation()
        guard version == revision else { throw Failure.changed }
        guard !proposals.isEmpty else { throw Failure.noAdditions }
        return PlanWeekReview(revision: version, active: active, proposals: proposals, source: source)
    }

    func activate(_ review: PlanWeekReview, store: GuestDataStore) throws -> Int {
        try authorize()
        guard revision == review.revision, store.plannedMeals == review.active,
              currentSourceMatches(review.source) else { throw Failure.changed }
        // Crossing midnight/travelling while the review is open also requires a fresh preview.
        let now = try PlanAheadCore.activationProposals(from: review.source)
        guard review.proposals.allSatisfy({ now.contains($0) }) else { throw Failure.changed }
        let additions = review.proposals.map { proposal -> PlannedMeal in
            var meal = PlannedMeal(dayIndex: proposal.dayOffset, title: proposal.title, servings: proposal.servings,
                                   ingredients: proposal.ingredients, mealType: proposal.mealType)
            meal.id = proposal.activeMealID
            return meal
        }
        guard store.plannedMeals.count + additions.count <= 200 else {
            throw Failure.limit("Keep the active week under 200 meals. Remove unneeded active meals first.")
        }
        store.plannedMeals += additions
        let ids = Set(additions.map(\.id))
        activatedMeals = store.plannedMeals.filter { ids.contains($0.id) }
        guard activatedMeals.count == additions.count else { throw Failure.permission }
        store.flushPendingSaves()
        let sourceIDs = Set(review.proposals.map(\.occurrenceID))
        var updated = scheduledMeals
        for i in updated.indices where sourceIDs.contains(updated[i].id) { updated[i].movedToWeek = true }
        scheduledMeals = updated
        activatedDates = scheduledMeals.filter { sourceIDs.contains($0.id) }
        canUndoWeek = !activatedMeals.isEmpty; flush()
        return activatedMeals.count
    }

    func undoDates() throws -> Int {
        try authorize()
        let ids = Set(addedDates.filter { scheduledMeals.contains($0) }.map(\.id))
        scheduledMeals.removeAll { ids.contains($0.id) }
        addedDates = []; canUndoDates = false; flush()
        return ids.count
    }

    func undoWeek(store: GuestDataStore) throws -> Int {
        try authorize()
        let eligible = activatedDates.filter { old in
            scheduledMeals.contains(old) && activatedMeals.contains { meal in
                meal.id == PlanAheadCore.activeMealID(for: old.id) && store.plannedMeals.contains(meal)
            }
        }
        let sourceIDs = Set(eligible.map(\.id)), mealIDs = Set(eligible.map { PlanAheadCore.activeMealID(for: $0.id) })
        store.plannedMeals.removeAll { mealIDs.contains($0.id) }; store.flushPendingSaves()
        var updated = scheduledMeals
        for i in updated.indices where sourceIDs.contains(updated[i].id) { updated[i].movedToWeek = false }
        scheduledMeals = updated
        activatedDates = []; activatedMeals = []; canUndoWeek = false; flush()
        return eligible.count
    }

    func clearUndo() {
        addedDates = []; activatedDates = []; activatedMeals = []
        canUndoDates = false; canUndoWeek = false
    }

    private func currentSourceMatches(_ source: [ScheduledMeal]) -> Bool {
        Set(source.map(\.id)).count == source.count && source.allSatisfy { expected in
            scheduledMeals.first(where: { $0.id == expected.id }) == expected
        }
    }
}
