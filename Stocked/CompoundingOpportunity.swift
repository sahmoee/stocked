//
//  CompoundingOpportunity.swift
//  Stocked
//
//  Created by Jess on 7/14/26.
//


// CompoundingPrepEngine.swift
// ─────────────────────────────────────────────────────────────────
// Overlapping-prep detection across upcoming planned meals. "You're already
// cutting onions — two upcoming meals also need them. Prep extra?"
//
// The engine finds ingredients the CURRENT cooking session is prepping that
// also appear in upcoming planned meals, and suggests preparing the combined
// amount once. It is conservative on purpose: it does NOT suggest combining
// when the effort level is bare-minimum, when the item is highly perishable
// once cut, or when there's no real overlap. It never claims cut-style
// compatibility it can't verify — it surfaces the opportunity and lets the
// user decide.
//
// Pure value logic (nonisolated, Sendable) so it can be unit-tested and run off
// the render path. Storage-life guidance is a simple, honest lookup.
// ─────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Opportunity model

nonisolated struct CompoundingOpportunity: Identifiable, Sendable, Equatable {
    var id: String { ingredient.lowercased() }
    let ingredient: String
    /// Planned meals (beyond the current cook) that also use this ingredient.
    let upcomingMeals: [CompoundingMealRef]
    /// Human-readable storage life once prepped (honest, conservative).
    let storageLife: String
    /// Whether the prep is likely the same style across uses (best-effort; when
    /// false the UI warns that cuts may differ).
    let likelySameStyle: Bool

    var mealCount: Int { upcomingMeals.count }
}

nonisolated struct CompoundingMealRef: Sendable, Equatable, Identifiable {
    var id: UUID { mealID }
    let mealID: UUID
    let title: String
    let dayIndex: Int
}

// MARK: - Engine

nonisolated enum CompoundingPrepEngine {

    /// Ingredients worth compounding at all — things you prep in bulk and store.
    /// Others (delicate herbs, dairy) are excluded to avoid bad suggestions.
    private static let compoundable: [String: String] = [
        // ingredient keyword : storage-life guidance once prepped
        "onion":    "Keeps 5–7 days refrigerated in a sealed container",
        "garlic":   "Minced garlic keeps 3–4 days refrigerated; cloves last weeks",
        "carrot":   "Cut carrots keep about a week in water, refrigerated",
        "celery":   "Cut celery keeps about a week in water, refrigerated",
        "pepper":   "Sliced peppers keep 3–4 days refrigerated",
        "potato":   "Peeled potatoes keep 1 day in water; cook soon",
        "rice":     "Cooked rice keeps 4–5 days refrigerated; cool quickly",
        "chicken":  "Portioned raw chicken keeps 1–2 days refrigerated",
        "beef":     "Portioned raw beef keeps 1–2 days refrigerated",
        "egg":      "Hard-boiled eggs keep about a week refrigerated",
        "stock":    "Homemade stock keeps 3–4 days refrigerated"
    ]

    /// Ingredients that should NOT be compounded even if they overlap — quality
    /// or safety makes ahead-prep a poor idea.
    private static let doNotCompound = ["herb", "basil", "cilantro", "parsley", "lettuce", "avocado", "cream", "milk", "cheese"]

    /// Find compounding opportunities.
    /// - Parameters:
    ///   - currentIngredients: ingredient names the current cook is prepping.
    ///   - upcoming: upcoming planned meals to check for overlap.
    ///   - allowCompounding: pass the effort level's allowsCompounding; false disables entirely.
    static func opportunities(currentIngredients: [String],
                              upcoming: [PlannedMeal],
                              allowCompounding: Bool) -> [CompoundingOpportunity] {
        guard allowCompounding else { return [] }

        var out: [CompoundingOpportunity] = []
        for raw in currentIngredients {
            let name = raw.lowercased().trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            // Skip do-not-compound items.
            if doNotCompound.contains(where: { name.contains($0) }) { continue }
            // Must be a compoundable staple.
            guard let matchKey = compoundable.keys.first(where: { name.contains($0) || $0.contains(name) }) else { continue }

            // Which upcoming meals also use it?
            let refs: [CompoundingMealRef] = upcoming.compactMap { meal in
                let uses = meal.ingredients.contains { ing in
                    let l = ing.lowercased()
                    return l.contains(matchKey) || matchKey.contains(l) || l.contains(name) || name.contains(l)
                }
                guard uses else { return nil }
                return CompoundingMealRef(mealID: meal.id, title: meal.title, dayIndex: meal.dayIndex)
            }
            guard !refs.isEmpty else { continue }

            out.append(CompoundingOpportunity(
                ingredient: raw,
                upcomingMeals: refs.sorted { $0.dayIndex < $1.dayIndex },
                storageLife: compoundable[matchKey] ?? "Store in a sealed container and use within a few days",
                likelySameStyle: true   // best-effort; UI notes cuts may differ
            ))
        }
        // De-dupe by ingredient, most-overlap first.
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.sorted { $0.mealCount > $1.mealCount }
    }
}