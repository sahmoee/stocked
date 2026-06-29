// GroceryDedup.swift — Normalized de-duplication for grocery items (#17).
//
// Adding from Low Stock + Usuals + manual entry could otherwise create "Milk", "milk", and
// "Crème" / "Creme" as separate lines. This centralizes the "are these the same grocery item?"
// decision using the same accent/case folding as search (SearchNormalization), so dedup and
// search agree. Pure and static → unit-testable without the session.

import Foundation

enum GroceryDedup {
    /// True if `candidate` already exists in `existing` (case- and accent-insensitive, trimmed).
    static func isDuplicate(_ candidate: String, in existing: [String]) -> Bool {
        let c = SearchNormalization.fold(candidate)
        guard !c.isEmpty else { return true }   // blank never gets added
        return existing.contains { SearchNormalization.fold($0) == c }
    }

    /// Returns the input list with normalized-duplicate names removed, keeping first occurrence
    /// and original casing.
    static func deduped(_ names: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for n in names {
            let key = SearchNormalization.fold(n)
            if key.isEmpty || seen.contains(key) { continue }
            seen.insert(key); out.append(n)
        }
        return out
    }
}
