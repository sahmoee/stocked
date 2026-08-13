// MealsReadyNowGenerator.swift
// Creates and stores one inventory-aware recipe through the existing authenticated
// Claude Worker route. Inventory mutations are coalesced so a receipt containing many
// lines causes one generation pass after the batch settles, not one paid request per row.

import Foundation

@MainActor
final class MealsReadyNowGenerator {
    static let shared = MealsReadyNowGenerator()

    private var automaticTask: Task<Void, Never>?
    private var generationInFlight = false

    private init() {}

    func inventoryDidChange(store: GuestDataStore) {
        automaticTask?.cancel()
        automaticTask = Task { [weak self, weak store] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let self, let store else { return }
            _ = await self.generateAndStore(in: store)
        }
    }

    @discardableResult
    func generateAndStore(in store: GuestDataStore) async -> UUID? {
        guard !generationInFlight else { return nil }
        let available = store.inventoryItems
            .filter { $0.level > 0 }
            .map(\.name)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !available.isEmpty else { return nil }

        generationInFlight = true
        defer { generationInFlight = false }

        let profile = store.cookingProfile
        let dietary = profile.dietaryStyle.trimmingCharacters(in: .whitespacesAndNewlines)
        let options = RecipeGeneratorAI.Options(
            haveItems: Array(available.prefix(60)),
            dietary: dietary.isEmpty || dietary == "Any" ? nil : dietary,
            maxTime: "45 minutes",
            cuisinePreference: [],
            mustUse: Array(available.prefix(5)),
            avoidGeneric: true,
            minIngredients: 4,
            minSteps: 3,
            dietaryRules: DietaryGuard.Rules(allergens: profile.allergens)
        )
        guard let recipe = await RecipeGeneratorAI.generate(
            idea: "Create a practical meal I can cook now using mostly my available inventory. Minimize extra ingredients.",
            options: options
        ) else { return nil }
        return store.saveGeneratedRecipe(recipe)
    }
}
