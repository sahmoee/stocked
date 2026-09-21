// MatchRing.swift
// ─────────────────────────────────────────────────────────────────────────────
// A reusable, at-a-glance "how much of this recipe can I make?" indicator, plus the
// plain-language explanation that goes with it ("8 of 10 ingredients", "missing only
// sour cream", "uses chicken expiring tomorrow").
//
// Both read the app's CANONICAL coverage logic (OnlineRecipeMatch.stockMatch) rather than
// re-deriving matching, so the ring, the explanation, and the existing "Ready / N missing"
// badges never disagree. No asset catalog — the ring is drawn with SwiftUI Shapes, matching
// the app's icons-as-Shapes rule.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

// MARK: - Coverage value

/// A recipe's inventory coverage, plus the context needed for a human explanation.
nonisolated struct RecipeCoverage: Equatable, Sendable {
    let have: Int
    let total: Int
    /// Canonical names still missing (already run through the matcher). May be empty.
    let missingNames: [String]
    /// Names of in-stock items used by this recipe that are expiring soon — the "cook this to
    /// use it up" hook. May be empty.
    let expiringUsed: [String]

    var fraction: Double { total > 0 ? Double(have) / Double(total) : 0 }
    var isReady: Bool { total > 0 && have >= total }
    var missingCount: Int { max(0, total - have) }

    /// Color the ring/label should use, brighter on dark for contrast (mirrors the app's rule).
    func tint(dark: Bool) -> Color {
        if total == 0 { return dark ? Color.white.opacity(0.35) : Color.stockedCharcoal.opacity(0.3) }
        switch fraction {
        case 1:            return dark ? Color(red: 0.40, green: 0.78, blue: 0.50) : Color.stockedGreen
        case 0.6..<1:      return dark ? Color.stockedGoldDark : Color.stockedGold
        default:           return dark ? Color(red: 0.90, green: 0.55, blue: 0.45) : Color.stockedError
        }
    }
}

// MARK: - Coverage builder

enum RecipeCoverageBuilder {
    /// Build coverage for an online recipe from the store, using the canonical matcher and the
    /// store's expiring-soon list. Kept in one place so callers don't re-implement matching.
    @MainActor
    static func make(for recipe: OnlineRecipe, store: GuestDataStore) -> RecipeCoverage {
        make(for: recipe, inStock: store.inStockNameSet,
             expiringNames: store.expiringSoonItems.map { $0.name.lowercased() })
    }

    /// Snapshot-based overload used by background recipe-detail preparation. It avoids
    /// touching the observable store while parsing and matching a large ingredient list.
    nonisolated static func make(for recipe: OnlineRecipe, inStock: Set<String>,
                                 expiringNames: [String]) -> RecipeCoverage {
        // BUG THIS FIXES: `have`/`total` came from the 0.72 token matcher while
        // `missingNames` was built by raw substring containment, and
        // `missingCount` was derived as `total - have`. The count and the named
        // list were therefore produced by two different rules inside one struct,
        // so "Missing only X" could name an ingredient the count did not
        // include (or omit one it did). Both now come from the same pass.
        let c = OnlineRecipeMatch.coverage(recipe, inStock: inStock)
        let names = RecipeIngredients.names(recipe.ingredients)
            .map { IngredientSynonyms.canonical($0) }
            .filter { !$0.isEmpty }
        let expiringUsed = expiringNames.filter { exp in
            names.contains { KitchenAvailability.nameMatches($0, exp) }
        }
        return RecipeCoverage(have: c.have, total: c.total,
                              missingNames: c.missingNames, expiringUsed: expiringUsed)
    }
}

// MARK: - Match explanation (plain language)

enum MatchExplanation {
    /// One short, honest line. Prioritizes the most actionable signal:
    /// expiring-use hook > "missing only X" > "N of M" > ready. Returns nil when there's no
    /// pantry signal to speak to (empty kitchen), so callers can hide it.
    nonisolated static func line(for c: RecipeCoverage) -> String? {
        guard c.total > 0 else { return nil }

        if let first = c.expiringUsed.first {
            return "Uses \(first), expiring soon"
        }
        if c.isReady {
            return "You have everything"
        }
        if c.missingCount == 1, let only = c.missingNames.first {
            return "Missing only \(only)"
        }
        if c.have == 0 {
            return "None on hand yet"
        }
        return "You have \(c.have) of \(c.total) ingredients"
    }
}

// MARK: - The ring

/// Circular inventory-coverage indicator. Draws a track + a progress arc and a compact
/// "have/total" (or a check when ready) in the middle. Sizes to `size`.
struct MatchRing: View {
    let coverage: RecipeCoverage
    var size: CGFloat = 40
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        let tint = coverage.tint(dark: dark)
        let lineWidth = max(3, size * 0.11)

        ZStack {
            Circle()
                .stroke(tint.opacity(dark ? 0.22 : 0.16), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, coverage.fraction))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.5), value: coverage.fraction)

            if coverage.total == 0 {
                Image(systemName: "questionmark")
                    .font(.stockedSystem(size: size * 0.34, weight: .bold))
                    .foregroundStyle(tint)
            } else if coverage.isReady {
                Image(systemName: "checkmark")
                    .font(.stockedSystem(size: size * 0.36, weight: .heavy))
                    .foregroundStyle(tint)
            } else {
                VStack(spacing: -1) {
                    Text("\(coverage.have)")
                        .font(.stockedSystem(size: size * 0.34, weight: .heavy))
                        .foregroundStyle(tint)
                    Rectangle().fill(tint.opacity(0.35))
                        .frame(width: size * 0.30, height: 1)
                    Text("\(coverage.total)")
                        .font(.stockedSystem(size: size * 0.26, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.7))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(coverage.total == 0
            ? "Ingredient match unknown"
            : "\(coverage.have) of \(coverage.total) ingredients on hand")
    }
}

/// A pill variant for tight spots (recipe list rows) where a full ring is too big.
struct MatchPill: View {
    let coverage: RecipeCoverage
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        guard coverage.total > 0 else { return AnyView(EmptyView()) }
        let dark = scheme == .dark
        let tint = coverage.tint(dark: dark)
        let text = coverage.isReady ? "Ready" : "\(coverage.have)/\(coverage.total)"
        return AnyView(
            HStack(spacing: 3) {
                Image(systemName: coverage.isReady ? "checkmark.circle.fill" : "circle.lefthalf.filled")
                    .scaledFont(9, weight: .bold)
                Text(text).scaledFont(10, weight: .bold)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(tint.opacity(dark ? 0.18 : 0.12)))
        )
    }
}
