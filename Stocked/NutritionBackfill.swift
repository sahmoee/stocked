// NutritionBackfill.swift
// #13 Estimate calories for recipes that have none, by summing per-ingredient calories
// from the local NutritionDatabase first (free, instant) and USDA as a fallback. Runs
// once per install in the background, bounded and throttled to respect the USDA quota.
// Writes the estimate into RecipeDatabaseEntry.calories.

import Foundation
import os

@MainActor
enum NutritionBackfill {

    static func runIfNeeded() {
        let flagKey = "didBackfillNutrition.lastRun.v2"
        let last = UserDefaults.standard.object(forKey: flagKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) >= 24 * 3600 else { return }
        Task(priority: .background) {
            await run(limit: 40)
            UserDefaults.standard.set(Date(), forKey: flagKey)
        }
    }

    private static func run(limit: Int) async {
        let entries = await RecipeDatabase.shared.all()
        let missing = entries.filter { $0.calories.isEmpty }.prefix(limit)
        guard !missing.isEmpty else { return }
        Log.data.notice("Backfilling nutrition for \(missing.count, privacy: .public) recipes")
        var filled = 0
        for var entry in missing {
            if let kcal = await estimateCalories(for: entry.ingredients), kcal > 0 {
                entry.calories = "\(kcal)"
                await RecipeDatabase.shared.upsert(entry)
                filled += 1
            }
            try? await Task.sleep(nanoseconds: 300_000_000)   // be gentle on USDA
        }
        Log.data.notice("Nutrition backfill complete: \(filled, privacy: .public) filled")
    }

    /// Sum per-ingredient calories. Uses the parsed ingredient name; local DB first,
    /// USDA only for misses. Returns an integer total (approximate).
    private static func estimateCalories(for ingredients: [String]) async -> Int? {
        guard !ingredients.isEmpty else { return nil }
        var total = 0
        var counted = 0
        for line in ingredients {
            let name = IngredientSynonyms.canonical(RecipeIngredients.parse(line).name)
            guard !name.isEmpty else { continue }
            var candidates: [NutritionCandidate] = []
            if let facts = NutritionDatabase.facts(for: name), facts.calories > 0 {
                candidates.append(.init(facts: facts, source: "Stocked nutrition",
                                        authority: 0.76, match: .name))
            }
            async let usda = USDANutritionClient.shared.facts(for: name)
            async let fatSecret = RetailEnrichmentClient.fatSecretFacts(for: name)
            if let facts = await usda, facts.calories > 0 {
                candidates.append(.init(facts: facts, source: "USDA FoodData Central",
                                        authority: 0.98, match: .name))
            }
            if let facts = await fatSecret, facts.calories > 0 {
                candidates.append(.init(facts: facts, source: "FatSecret Platform API",
                                        authority: 0.82, match: .name))
            }
            if let result = NutritionReconciler.reconcile(candidates) {
                total += result.facts.calories
                counted += 1
            }
        }
        // Only return an estimate if we matched a meaningful share of ingredients.
        guard counted >= max(2, ingredients.count / 2) else { return nil }
        return total
    }
}
