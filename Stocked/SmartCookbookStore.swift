import Foundation
import Observation

extension SmartCookbookRule: HouseholdSyncable {}

/// Persists only bounded rules. Recipes remain owned by GuestDataStore.
@MainActor @Observable
final class SmartCookbookStore {
    static let shared = SmartCookbookStore()
    private let persistence = FeatureStore<SmartCookbookRule>(key: FeatureStoreKeys.smartCookbooks)
    private var stamping = false
    private(set) var revision = 0
    var rules: [SmartCookbookRule] = [] {
        didSet {
            guard !stamping, rules != oldValue else { return }
            if !FeatureSync.shared.isApplyingRemote {
                guard HouseholdSync.shared.authorize(.recipeEdit) else {
                    stamping = true; rules = oldValue; stamping = false; return
                }
                stamping = true
                rules = FeatureSync.shared.stampMutation(FeatureSync.Keys.smartCookbooks, old: oldValue, current: rules)
                stamping = false
            }
            revision &+= 1
            persistence.save(rules)
        }
    }

    private init() { stamping = true; rules = persistence.load(); stamping = false }

    func save(_ draft: SmartCookbookRule, replacing baseline: SmartCookbookRule?) throws {
        guard HouseholdSync.shared.authorize(.recipeEdit) else { throw EditError.permission }
        var next = rules
        var value = try draft.validated()
        if let baseline {
            guard let index = next.firstIndex(where: { $0.id == baseline.id }), next[index] == baseline else { throw EditError.changed }
            value.id = baseline.id
            value.updatedAt = baseline.updatedAt
            value.lastWriterID = baseline.lastWriterID
            next[index] = value
        } else {
            guard !next.contains(where: { $0.id == value.id }) else { throw EditError.changed }
            value.updatedAt = 0; value.lastWriterID = ""
            next.append(value)
        }
        // Budget the actual wire shape, including stamps that stampMutation will add.
        let previous = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let wirePreview = next.map { value in previous[value.id] == value ? value : FeatureSync.stamped(value) }
        try SmartCookbookRule.validateChange(from: rules, to: wirePreview)
        rules = next
    }

    func delete(_ baseline: SmartCookbookRule) throws {
        guard HouseholdSync.shared.authorize(.recipeEdit) else { throw EditError.permission }
        guard rules.first(where: { $0.id == baseline.id }) == baseline else { throw EditError.changed }
        rules.removeAll { $0.id == baseline.id }
    }

    func flush() { persistence.flush() }

    /// Used by the central remote/wipe owner. A user deletion uses delete(_:).
    func clear() {
        guard FeatureSync.shared.isApplyingRemote else { return }
        rules = []; persistence.clear()
    }

    enum EditError: LocalizedError {
        case changed, permission
        var errorDescription: String? {
            switch self {
            case .changed: "This cookbook changed or was removed on another device. Close this editor and open the latest version before saving."
            case .permission: "Your household role cannot change recipes or cookbooks. Ask a household owner to update your access."
            }
        }
    }
}

nonisolated enum SmartCookbookData {
    static func record(_ recipe: UserRecipe) -> SmartCookbookRecord {
        let norm = SmartCookbookQuery.normalize
        // Only saved labels are used. Never infer dietary safety from ingredients or a title.
        let metadata = recipe.tags + (recipe.categories ?? [])
        let cuisines = [recipe.cuisine, RecipeTaxonomy.parentCuisine(recipe.cuisine)].compactMap { $0 }
        return SmartCookbookRecord(id: recipe.id, title: recipe.title,
            searchText: norm(([recipe.title, recipe.description, recipe.cuisine] + metadata + recipe.ingredients.map(\.name)).joined(separator: " ")),
            cuisines: Set(cuisines.map(norm)), categories: Set((recipe.categories ?? []).map(norm)),
            tags: Set(recipe.tags.map(norm)), prepMinutes: FinderDuration.minutes(recipe.prepTime),
            cookMinutes: FinderDuration.minutes(recipe.cookTime), isFavorite: recipe.isFavorited, dateCreated: recipe.dateCreated)
    }
}
