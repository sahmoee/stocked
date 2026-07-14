// SourceRank.swift
//
// One place that decides the ORDER in which the app should try data sources, so it spends the
// cheapest, most reliable option first and only falls through to paid/quota-limited APIs when
// needed. This wraps the existing SourceHealth reliability scoring; SourceHealth answers "is this
// source working lately?", SourceRank answers "which tier should I try first?".
//
// Additive: a policy helper. Callers ask SourceRank for an ordering and follow it.

import Foundation

/// Cost/reliability tier of a data source. Lower rawValue = try first.
enum SourceTier: Int, Comparable, CaseIterable {
    /// On-device data: CommonGroceryDB, IngredientMatcher, cached results. Free and instant.
    case local = 0
    /// Free public APIs: Open Food Facts, USDA, TheMealDB. No quota cost.
    case free = 1
    /// Paid/quota-limited APIs: Spoonacular. Use last, and sparingly.
    case paid = 2

    static func < (l: SourceTier, r: SourceTier) -> Bool { l.rawValue < r.rawValue }

    var label: String {
        switch self {
        case .local: return "On device"
        case .free:  return "Free source"
        case .paid:  return "Premium source"
        }
    }
}

/// A named source with its tier and (optional) network domain for health lookups.
struct RankedSource: Equatable {
    let name: String
    let tier: SourceTier
    /// Domain used to consult SourceHealth, or nil for purely local sources.
    let domain: String?

    init(_ name: String, _ tier: SourceTier, domain: String? = nil) {
        self.name = name; self.tier = tier; self.domain = domain
    }
}

enum SourceRank {

    // MARK: - Known sources per data kind

    /// Barcode/product lookup: local cache, then Open Food Facts (free), then any paid cleanup.
    static let productSources: [RankedSource] = [
        .init("Local catalog", .local),
        .init("Open Food Facts", .free, domain: "openfoodfacts.org"),
        .init("Spoonacular", .paid, domain: "spoonacular.com"),
    ]

    /// Nutrition: local DB, then USDA (free authority), then estimate.
    static let nutritionSources: [RankedSource] = [
        .init("Local nutrition", .local),
        .init("USDA", .free, domain: "nal.usda.gov"),
        .init("Spoonacular", .paid, domain: "spoonacular.com"),
    ]

    /// Recipes: cached/local, then free recipe APIs, then Spoonacular last (quota).
    static let recipeSources: [RankedSource] = [
        .init("Saved + cached", .local),
        .init("TheMealDB", .free, domain: "themealdb.com"),
        .init("Web sources", .free),
        .init("Spoonacular", .paid, domain: "spoonacular.com"),
    ]

    // MARK: - Ordering

    /// Order a source list cheapest-first, and within the same tier, healthiest-first
    /// (using SourceHealth). Sources known to be unhealthy are pushed to the back of their tier
    /// but never dropped — they remain a last resort.
    @MainActor
    static func ordered(_ sources: [RankedSource]) -> [RankedSource] {
        sources.sorted { a, b in
            if a.tier != b.tier { return a.tier < b.tier }
            let ha = a.domain.map { SourceHealth.shared.score($0) } ?? 1.0
            let hb = b.domain.map { SourceHealth.shared.score($0) } ?? 1.0
            return ha > hb
        }
    }

    /// Convenience: the ordered names only.
    @MainActor
    static func orderedNames(_ sources: [RankedSource]) -> [String] {
        ordered(sources).map { $0.name }
    }
}
