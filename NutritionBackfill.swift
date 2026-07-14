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
        let flagKey = "didBackfillNutrition_v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        Task(priority: .background) {
            await run(limit: 40)
            UserDefaults.standard.set(true, forKey: flagKey)
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
            // Local DB first (free, instant).
            if let facts = NutritionDatabase.facts(for: name), facts.calories > 0 {
                total += facts.calories; counted += 1; continue
            }
            // USDA fallback (cached inside the client).
            if let facts = await USDANutritionClient.shared.facts(for: name), facts.calories > 0 {
                total += facts.calories; counted += 1
            }
        }
        // Only return an estimate if we matched a meaningful share of ingredients.
        guard counted >= max(2, ingredients.count / 2) else { return nil }
        return total
    }
}
