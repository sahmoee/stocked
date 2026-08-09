// DatabaseSyncBus.swift
// Central sync coordinator — all databases publish changes here, all databases
// subscribe and update each other. One-shot sync on launch; live sync on writes.
//
//  Flow:
//    GuestDataStore.addInventoryItem  → bus.inventoryChanged
//    GuestDataStore.addUserRecipe     → bus.recipeAdded        → RecipeDatabase.upsert
//    RecipeDatabase.upsert            → bus.recipeDatabaseChanged
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
    case userRecipeAdded(title: String, ingredients: [String], steps: [String])
    case userRecipeUpdated(title: String)
    case webRecipeFetched(title: String, sourceURL: String, sourceName: String,
                          ingredients: [String], steps: [String],
                          category: String, cuisine: String, tags: [String])
    case offlineRecipeCached(title: String, ingredients: [String], steps: [String])
    case groceryItemAdded(name: String)
    /// Emitted after a batch of recipes is folded straight into RecipeDatabase (e.g. the
    /// Mac-harvested cache) rather than through one of the per-recipe add paths above. It
    /// carries no payload to re-import — the rows are already stored — and exists only to
    /// tell observers (counts, open browse views) that the pool grew.
    case recipeDatabaseChanged(count: Int)
    case fullSync  // trigger a complete re-sync of all sources
}

// MARK: - DatabaseSyncBus

@MainActor
final class DatabaseSyncBus {
    static let shared = DatabaseSyncBus()
    private init() { subscribeAll() }

    private let subject = PassthroughSubject<DatabaseEvent, Never>()
    private var cancellables = Set<AnyCancellable>()

    /// Publish an event from any database write
    func publish(_ event: DatabaseEvent) {
        subject.send(event)
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

        case .userRecipeAdded(let title, let ingredients, let steps):
            guard !title.isEmpty else { break }
            let classification = RecipeClassifier.classify(
                title: title,
                rawCuisine: nil,
                rawCategory: "Dinner",
                keywords: ["my recipe"],
                ingredients: ingredients.map { RecipeIngredient(name: $0, amount: "") },
                instructions: steps
            )
            let entry = RecipeDatabaseEntry(
                title: title, description: "",
                sourceURL: "", sourceName: "My Recipes",
                prepTime: "", cookTime: "", totalTime: "", servings: "4",
                category: classification.category, cuisine: classification.cuisine,
                tags: classification.tags + ["my recipe"], ingredients: ingredients, steps: steps
            )
            await RecipeDatabase.shared.upsert(entry)

        case .userRecipeUpdated(let title):
            // Title rename only — look up existing entry and update it
            if let existing = await RecipeDatabase.shared.entry(for: title) {
                await RecipeDatabase.shared.upsert(existing)
            }

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
            await RecipeDatabase.shared.upsert(entry)

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
            await RecipeDatabase.shared.upsert(entry)

        case .fullSync:
            Task { await RecipeDatabaseManager.shared.mergeAllSources() }

        default:
            break // inventory/grocery events handled by views directly
        }
    }
}

// MARK: - Convenience publishers anyone can observe

extension DatabaseSyncBus {
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
            if case .userRecipeAdded = $0 { return true }
            if case .userRecipeUpdated = $0 { return true }
            if case .webRecipeFetched = $0 { return true }
            if case .offlineRecipeCached = $0 { return true }
            if case .recipeDatabaseChanged = $0 { return true }
            return false
        }.eraseToAnyPublisher()
    }
}
