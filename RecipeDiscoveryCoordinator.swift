// RecipeDiscoveryCoordinator.swift
// Bounded source execution and quota-aware source planning outside the SwiftUI loader.
import Foundation

nonisolated struct RecipeDiscoveryPlan: Sendable, Equatable {
    let mealDBCategories: Int
    let randomMealDB: Int
    let firstLetters: Int
    let areas: Int
    let useSpoonacular: Bool
    let spoonacularCount: Int

    static func make(cacheCount: Int, spoonacularRemainingPoints: Int,
                     mealDBHealth: Double, isForced: Bool) -> RecipeDiscoveryPlan {
        let wellSeeded = cacheCount >= 180 && !isForced
        return RecipeDiscoveryPlan(
            mealDBCategories: wellSeeded ? 5 : (mealDBHealth < 0.3 ? 4 : 11),
            randomMealDB: wellSeeded ? 6 : 16,
            firstLetters: wellSeeded ? 2 : 5,
            areas: wellSeeded ? 3 : 6,
            useSpoonacular: spoonacularRemainingPoints >= 10 && cacheCount < 260,
            spoonacularCount: spoonacularRemainingPoints >= 20 ? 20 : 10
        )
    }
}

nonisolated enum RecipeDiscoveryCoordinator {
    typealias RecipeTask = @Sendable () async -> [OnlineRecipe]

    static func boundedGather(_ tasks: [RecipeTask], maxConcurrent: Int = 4) async -> [OnlineRecipe] {
        guard !tasks.isEmpty else { return [] }
        var results: [OnlineRecipe] = []
        var next = 0
        while next < tasks.count, !Task.isCancelled {
            let end = min(next + max(1, maxConcurrent), tasks.count)
            let slice = tasks[next..<end]
            await withTaskGroup(of: [OnlineRecipe].self) { group in
                for task in slice { group.addTask { await task() } }
                for await batch in group { results.append(contentsOf: batch) }
            }
            next = end
        }
        return results
    }
}
