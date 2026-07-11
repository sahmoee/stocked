// KitchenHealthScore.swift — the composite Kitchen Health % (#261).
// ─────────────────────────────────────────────────────────────────
// THE RULE: the user-defined must-have items (Kitchen Goals staples) are the real
// baseline. Once the user has answered "what does stocked mean to you?", the score is
// anchored to how many of THEIR staples are in stock, blended with three supporting
// signals so the number reflects the whole kitchen:
//
//   • Staples in stock  — 55%  (the anchor; absorbs the weight of any missing signal)
//   • Par levels        — 15%  (items with a "keep at least N" target that are at/above it)
//   • Freshness         — 15%  (in-date items; expiring-soon counts half, expired zero)
//   • Meal readiness    — 15%  (saved/catalog recipes fully cookable right now)
//
// A signal that has no data (no par levels set, empty inventory, no recipes) is dropped
// and its weight flows INTO the staples component — never sideways — so staples always
// dominate and the score never punishes features the user hasn't adopted.
//
// If Kitchen Goals are NOT configured, GuestDataStore.stockPercent keeps its historical
// average-fill fallback; nothing here runs.
import Foundation

// MARK: - Breakdown row (for the Kitchen Report UI)

struct KitchenHealthComponent: Identifiable {
    let name: String
    let icon: String      // SF Symbol
    let percent: Int      // 0–100 for this signal alone
    let weight: Int       // effective weight actually used, after redistribution
    var id: String { name }
}

// MARK: - Composite computation

extension GuestDataStore {

    /// The four health signals with their EFFECTIVE weights (unavailable signals removed,
    /// their weight folded into Staples). First element is always Staples.
    var kitchenHealthComponents: [KitchenHealthComponent] {
        let inStock = inStockNameSet

        // ── Staples (the anchor) ─────────────────────────────────────
        let staplesPct = KitchenStock.percent(staples: stockStaples, inStock: inStock)

        // ── Par levels ───────────────────────────────────────────────
        let parItems = inventoryItems.filter { $0.parQuantity != nil }
        let parPct: Int? = parItems.isEmpty ? nil : Int(
            (Double(parItems.filter { !$0.isBelowPar }.count) / Double(parItems.count) * 100).rounded())

        // ── Freshness ────────────────────────────────────────────────
        // In-date = 1, expiring soon = 0.5, expired = 0. Items without an expiry date
        // count as fresh (nothing is known to be wrong with them).
        let freshPct: Int? = inventoryItems.isEmpty ? nil : {
            let score = inventoryItems.reduce(0.0) { acc, item in
                if item.isExpired { return acc }
                if item.isExpiringSoon { return acc + 0.5 }
                return acc + 1.0
            }
            return Int((score / Double(inventoryItems.count) * 100).rounded())
        }()

        // ── Meal readiness ───────────────────────────────────────────
        // Fully-cookable recipes over the recipes that could be judged (catalog entries
        // with a non-empty ingredient match, plus saved AI recipes). Same numerator as
        // availableMeals so this agrees with the Meals Ready stat on the same screen.
        let judgeable = cookCatalog.filter { stockMatch(for: $0).total > 0 }.count
                      + savedGeneratedRecipes.count
        let readyPct: Int? = judgeable == 0 ? nil : Int(
            (Double(min(availableMeals, judgeable)) / Double(judgeable) * 100).rounded())

        // ── Assemble with weight redistribution into Staples ─────────
        var staplesWeight = 55
        var rows: [KitchenHealthComponent] = []
        if let p = parPct   { rows.append(.init(name: "Par Levels",     icon: "target",                 percent: p, weight: 15)) } else { staplesWeight += 15 }
        if let f = freshPct { rows.append(.init(name: "Freshness",      icon: "leaf.fill",              percent: f, weight: 15)) } else { staplesWeight += 15 }
        if let r = readyPct { rows.append(.init(name: "Meal Readiness", icon: "fork.knife",             percent: r, weight: 15)) } else { staplesWeight += 15 }
        rows.insert(.init(name: "Your Staples",   icon: "checklist",              percent: staplesPct, weight: staplesWeight), at: 0)
        return rows
    }

    /// 0–100 weighted blend of the components above. Staples dominate by construction.
    var kitchenHealthComposite: Int {
        let rows = kitchenHealthComponents
        let totalWeight = rows.map(\.weight).reduce(0, +)
        guard totalWeight > 0 else { return 0 }
        let weighted = rows.reduce(0.0) { $0 + Double($1.percent) * Double($1.weight) }
        return Int((weighted / Double(totalWeight)).rounded())
    }
}
