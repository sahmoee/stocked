// RecipeCost.swift — per-recipe cost estimate from the user's OWN price history.
//
// For each recipe ingredient, find the average paid price for a matching item name in
// priceHistory. The estimate is honest about coverage: it reports how many ingredients it
// could price, and callers show "est. from N of M ingredients" instead of pretending the
// number is complete. No external price APIs — this is grounded in what the user actually
// paid, which also makes it household-local and free.
import Foundation

nonisolated enum RecipeCost {

    nonisolated struct Estimate: Sendable {
        let total: Double          // summed average price of priced ingredients
        let pricedCount: Int       // ingredients a price was found for
        let totalCount: Int        // ingredients considered
        var isUseful: Bool { pricedCount > 0 }
        var display: String { String(format: "$%.2f", total) }
    }

    /// Average paid price per normalized item name.
    static func priceIndex(from history: [PriceRecord]) -> [String: Double] {
        var sums: [String: (Double, Int)] = [:]
        for r in history where r.price > 0 {
            let k = norm(r.itemName)
            guard !k.isEmpty else { continue }
            let cur = sums[k] ?? (0, 0)
            sums[k] = (cur.0 + r.price, cur.1 + 1)
        }
        return sums.mapValues { $0.0 / Double($0.1) }
    }

    /// Estimate a recipe's cost from ingredient names. `ingredients` are display names
    /// (measure text is fine; matching is contains-based on normalized words).
    static func estimate(ingredients: [String], history: [PriceRecord]) -> Estimate {
        let index = priceIndex(from: history)
        guard !index.isEmpty, !ingredients.isEmpty else {
            return Estimate(total: 0, pricedCount: 0, totalCount: ingredients.count)
        }
        var total = 0.0
        var priced = 0
        for ing in ingredients {
            let k = norm(ing)
            guard !k.isEmpty else { continue }
            // Exact key first, then a contains match either direction.
            if let p = index[k] {
                total += p; priced += 1; continue
            }
            if let hit = index.first(where: { $0.key.contains(k) || k.contains($0.key) }) {
                total += hit.value; priced += 1
            }
        }
        return Estimate(total: total, pricedCount: priced, totalCount: ingredients.count)
    }

    private static func norm(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && Double($0) == nil }
            .joined(separator: " ")
    }
}
