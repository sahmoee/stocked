// DatabaseSyncBus.swift
// Central sync coordinator — all databases publish changes here, all databases
// subscribe and update each other. One-shot sync on launch; live sync on writes.
//
//  Flow:
//    GuestDataStore.addInventoryItem  → bus.inventoryChanged
//    GuestDataStore.addUserRecipe     → bus.recipeAdded        → RecipeDatabase.upsert
//    RecipeDatabase mutation          → bus.recipeDatabaseMutation(exact revision + delta)
//    WebRecipeCatalogue.save          → bus.webRecipeAdded     → RecipeDatabase.upsert
//    OfflineRecipeCache.add           → bus.offlineRecipeAdded → RecipeDatabase.upsert
//    IngredientDatabase (static)      → read-only seed, no sync needed

import Foundation
import Combine

// MARK: - Sync Events

enum DatabaseEvent {
    case inventoryItemAdded(name: String)
    case inventoryItemUpdated(name: String)
    case inventoryItemRemoved(name: String)
    case userRecipeChanged(UserRecipe)
    case userRecipeDeleted(id: UUID)
    case webRecipeFetched(title: String, sourceURL: String, sourceName: String,
                          ingredients: [String], steps: [String],
                          category: String, cuisine: String, tags: [String])
    case offlineRecipeCached(title: String, ingredients: [String], steps: [String])
    case groceryItemAdded(name: String)
    /// Exact actor-owned mutation. Prefer `recipeMutations` when observing writable recipes.
    case recipeDatabaseMutation(RecipeDatabaseChange)
    /// Compatibility notification for older integrations. New code must publish through
    /// RecipeDatabase so it receives a revision and a precise delta.
    @available(*, deprecated, message: "Observe recipeMutations and write through RecipeDatabase")
    case recipeDatabaseChanged(count: Int)
    case fullSync  // trigger a complete re-sync of all sources
}

// MARK: - DatabaseSyncBus

@MainActor
final class DatabaseSyncBus {
    static let shared = DatabaseSyncBus()
    private init() { subscribeAll() }

    private let subject = PassthroughSubject<DatabaseEvent, Never>()
    private let recipeMutationSubject = CurrentValueSubject<RecipeDatabaseChange?, Never>(nil)
    private var cancellables = Set<AnyCancellable>()
    private var latestRecipeRevision: UInt64 = 0

    /// Publish an event from any database write
    func publish(_ event: DatabaseEvent) {
        if case .recipeDatabaseMutation(let change) = event {
            publishRecipeMutation(change)
        } else {
            subject.send(event)
        }
    }

    /// Publishes the actor-owned recipe delta exactly once and retains the latest revision
    /// for observers that subscribe after the write completed.
    func publishRecipeMutation(_ change: RecipeDatabaseChange) {
        guard change.revision > latestRecipeRevision else { return }
        latestRecipeRevision = change.revision
        recipeMutationSubject.send(change)
        subject.send(.recipeDatabaseMutation(change))
    }

    /// Subscribe to all events — run sync reactions
    private func subscribeAll() {
        subject.sink { [weak self] event in
            guard let self else { return }
            Task { await self.handle(event) }
        }
        .store(in: &cancellables)
    }

    private func handle(_ event: DatabaseEvent) async {
        switch event {

        case .userRecipeChanged(let recipe):
            await RecipeDatabaseManager.shared.save(userRecipe: recipe)

        case .userRecipeDeleted(let id):
            await RecipeDatabaseManager.shared.delete(id: id)

        case .webRecipeFetched(let title, let url, let source, let ingredients,
                               let steps, let category, let cuisine, let tags):
            let classification = RecipeClassifier.classify(
                title: title,
                rawCuisine: cuisine,
                rawCategory: category,
                keywords: tags,
                ingredients: ingredients.map { RecipeIngredient(name: $0, amount: "") },
                instructions: steps
            )
            let entry = RecipeDatabaseEntry(
                title: title, description: "",
                sourceURL: url, sourceName: source,
                prepTime: "", cookTime: "", totalTime: "", servings: "4",
                category: classification.category, cuisine: classification.cuisine,
                tags: classification.tags + tags, ingredients: ingredients, steps: steps
            )
            await RecipeDatabase.shared.upsert(entry, origin: .webCatalogue)

        case .offlineRecipeCached(let title, let ingredients, let steps):
            let classification = RecipeClassifier.classify(
                title: title,
                rawCuisine: nil,
                rawCategory: "Dinner",
                keywords: [],
                ingredients: ingredients.map { RecipeIngredient(name: $0, amount: "") },
                instructions: steps
            )
            let entry = RecipeDatabaseEntry(
                title: title, description: "",
                sourceURL: "", sourceName: "TheMealDB",
                prepTime: "", cookTime: "", totalTime: "", servings: "4",
                category: classification.category, cuisine: classification.cuisine,
                tags: classification.tags, ingredients: ingredients, steps: steps
            )
            await RecipeDatabase.shared.upsert(entry, origin: .offlineCache)

        case .fullSync:
            Task { await RecipeDatabaseManager.shared.mergeAllSources() }

        case .recipeDatabaseMutation, .recipeDatabaseChanged:
            break // publication only; the actor has already committed these rows

        default:
            break // inventory/grocery events handled by views directly
        }
    }
}

// MARK: - Convenience publishers anyone can observe

extension DatabaseSyncBus {
    /// Replayable, typed recipe deltas. Consumers can apply adjacent revisions and request a
    /// versioned snapshot only if they observe a gap.
    var recipeMutations: AnyPublisher<RecipeDatabaseChange, Never> {
        recipeMutationSubject.compactMap { $0 }.eraseToAnyPublisher()
    }

    var inventoryChanges: AnyPublisher<DatabaseEvent, Never> {
        subject.filter {
            if case .inventoryItemAdded = $0 { return true }
            if case .inventoryItemUpdated = $0 { return true }
            if case .inventoryItemRemoved = $0 { return true }
            return false
        }.eraseToAnyPublisher()
    }

    var recipeChanges: AnyPublisher<DatabaseEvent, Never> {
        subject.filter {
            if case .userRecipeChanged = $0 { return true }
            if case .userRecipeDeleted = $0 { return true }
            if case .webRecipeFetched = $0 { return true }
            if case .offlineRecipeCached = $0 { return true }
            if case .recipeDatabaseMutation = $0 { return true }
            if case .recipeDatabaseChanged = $0 { return true }
            return false
        }.eraseToAnyPublisher()
    }
}
