// GroceryDedup.swift — Normalized de-duplication for grocery items (#17).
//
// Adding from Low Stock + Usuals + manual entry could otherwise create "Milk", "milk", and
// "Crème" / "Creme" as separate lines. This centralizes the "are these the same grocery item?"
// decision using the same accent/case folding as search (SearchNormalization), so dedup and
// search agree. Pure and static → unit-testable without the session.

import Foundation

enum GroceryDedup {
    /// True if `candidate` already exists in `existing`. Matches on two levels:
    ///  1. accent/case fold (so "Milk" == "milk") — same as search, via SearchNormalization.
    ///  2. canonical ingredient identity (so "ground beef" == "beef mince" == "80/20 beef"),
    ///     via IngredientMatcher, so synonyms of the same thing collapse to one line.
    static func isDuplicate(_ candidate: String, in existing: [String]) -> Bool {
        let c = SearchNormalization.fold(candidate)
        guard !c.isEmpty else { return true }   // blank never gets added
        let cCanon = IngredientMatcher.canonical(candidate)
        return existing.contains { e in
            SearchNormalization.fold(e) == c || IngredientMatcher.canonical(e) == cCanon
        }
    }

    /// Returns the input list with duplicate names removed, keeping first occurrence and original
    /// casing. Uses canonical identity so synonyms ("scallion"/"green onion") collapse too.
    static func deduped(_ names: [String]) -> [String] {
        var seenFold = Set<String>()
        var seenCanon = Set<String>()
        var out: [String] = []
        for n in names {
            let fold = SearchNormalization.fold(n)
            let canon = IngredientMatcher.canonical(n)
            if fold.isEmpty || seenFold.contains(fold) || seenCanon.contains(canon) { continue }
            seenFold.insert(fold); seenCanon.insert(canon); out.append(n)
        }
        return out
    }
}
