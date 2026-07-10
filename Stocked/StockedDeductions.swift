// StockedDeductions.swift
// Weighted post-cook deduction: the "Confirm what you used" sheet now lets the
// user say how MUCH of each ingredient they used (None / Half / All), so the
// pantry deduction can be proportional instead of all-or-nothing.
//
// Kept as an extension (additive) so GuestDataStore itself doesn't churn.

import SwiftUI

extension GuestDataStore {
    /// Deduct ingredients with a per-ingredient portion multiplier.
    /// portion 1.0 mirrors the classic deduction (-0.25 level); 0.5 deducts half
    /// of that; 0 is skipped. Matching uses the shared IngredientStockMatch so
    /// "2.6 lbs Chicken" finds "Chicken Breast".
    func deductIngredients(weighted: [(name: String, portion: Double)]) {
        for entry in weighted where entry.portion > 0 {
            guard let idx = inventoryItems.firstIndex(where: {
                IngredientStockMatch.matches(ingredient: entry.name, itemName: $0.name)
            }) else { continue }
            let delta = 0.25 * min(1.0, max(0.0, entry.portion))
            withAnimation {
                inventoryItems[idx].level = max(0, inventoryItems[idx].level - delta)
            }
            // Mirror the classic close-the-loop behavior: auto-add to grocery when
            // this deduction emptied the item and the toggle is on.
            if inventoryItems[idx].level <= 0,
               UserDefaults.standard.bool(forKey: DBKey.autoAddMissing.rawValue) {
                addToGroceryIfMissing(inventoryItems[idx].name, recommended: true)
            }
        }
    }
}
