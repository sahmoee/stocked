//
//  SideSuggestionEngine.swift
//  Stocked
//
//  Pure decision logic for adaptive side suggestions. Factored out of
//  HandsOffOpportunityView so the same ranking can be reused by the hands-off
//  window, the "Add Something" intent, and unit tests.
//
//  Principle (from the Cook Now spec): the entrée is enough. Sides are optional,
//  fit the remaining window and current inventory, and "do nothing" is always a
//  first-class outcome. This engine only *ranks ideas* — it never forces a side.
//
//  Additive & non-isolated so it is trivially testable and callable from any actor.
//

import Foundation

nonisolated enum SideSuggestionEngine {

    /// A ranked side idea with just enough metadata for a card/row.
    struct Suggestion: Identifiable, Sendable, Equatable {
        var id: String { title.lowercased() }
        let title: String
        /// Rough minutes to make, so callers can bucket by remaining window.
        let approxMinutes: Int
        /// True when at least one meaningful word matched current inventory.
        let usesInventory: Bool
        /// Loose "feel" tag so callers can honor fresh / filling / light asks.
        let profile: Profile

        enum Profile: String, Sendable { case fresh, filling, light, comforting, neutral }
    }

    /// Effort ceiling maps to how many ideas we surface. Bare-minimum shows a
    /// tight, no-pressure set; higher energy shows more.
    /// - Parameters:
    ///   - remainingMinutes: hands-off window (or time the user is willing to give).
    ///   - inventoryNamesLowercased: names of in-stock items, lowercased.
    ///   - preferFresh/preferFilling/preferLight: optional bias from AddSomethingScope.
    ///   - limit: max suggestions to return.
    static func suggestions(remainingMinutes: Int,
                            inventoryNamesLowercased: [String],
                            preferFresh: Bool = false,
                            preferFilling: Bool = false,
                            preferLight: Bool = false,
                            limit: Int = 6) -> [Suggestion] {

        // A curated pool. approxMinutes lets us respect the remaining window;
        // profile lets us honor "something fresh/filling/light".
        let pool: [Suggestion] = [
            .init(title: "Bagged salad",        approxMinutes: 3,  usesInventory: false, profile: .fresh),
            .init(title: "Sliced cucumber",     approxMinutes: 4,  usesInventory: false, profile: .fresh),
            .init(title: "Sautéed spinach",     approxMinutes: 5,  usesInventory: false, profile: .light),
            .init(title: "Steamed broccoli",    approxMinutes: 6,  usesInventory: false, profile: .light),
            .init(title: "Buttered peas",       approxMinutes: 5,  usesInventory: false, profile: .comforting),
            .init(title: "Microwave rice",      approxMinutes: 5,  usesInventory: false, profile: .filling),
            .init(title: "Rice",                approxMinutes: 15, usesInventory: false, profile: .filling),
            .init(title: "Couscous",            approxMinutes: 12, usesInventory: false, profile: .filling),
            .init(title: "Macaroni",            approxMinutes: 15, usesInventory: false, profile: .comforting),
            .init(title: "Mashed potatoes",     approxMinutes: 20, usesInventory: false, profile: .comforting),
            .init(title: "Roasted vegetables",  approxMinutes: 20, usesInventory: false, profile: .light),
            .init(title: "Garlic bread",        approxMinutes: 10, usesInventory: false, profile: .comforting),
        ]

        // Keep only ideas that fit the window (with a small grace margin).
        let windowFit = pool.filter { $0.approxMinutes <= max(5, remainingMinutes) }
        let base = windowFit.isEmpty ? pool.filter { $0.approxMinutes <= 6 } : windowFit

        // Mark inventory matches on a per-idea basis.
        let marked: [Suggestion] = base.map { s in
            let words = s.title.lowercased().split(separator: " ").map(String.init)
            let matched = words.contains { w in inventoryNamesLowercased.contains { $0.contains(w) } }
            return matched
                ? Suggestion(title: s.title, approxMinutes: s.approxMinutes, usesInventory: true, profile: s.profile)
                : s
        }

        // Score: inventory match dominates; then honor any profile bias; then
        // prefer quicker options so the default lean is low-effort.
        func score(_ s: Suggestion) -> Int {
            var v = 0
            if s.usesInventory { v += 100 }
            if preferFresh   && s.profile == .fresh   { v += 25 }
            if preferFilling && s.profile == .filling { v += 25 }
            if preferLight   && (s.profile == .light || s.profile == .fresh) { v += 20 }
            v += max(0, 30 - s.approxMinutes)   // quicker ranks a little higher
            return v
        }

        let ranked = marked.sorted {
            let a = score($0), b = score($1)
            return a == b ? $0.approxMinutes < $1.approxMinutes : a > b
        }
        return Array(ranked.prefix(max(1, limit)))
    }

    /// Convenience preview string ("Rice, Couscous, …") for a compact subtitle.
    static func previewLine(_ suggestions: [Suggestion], max: Int = 3) -> String {
        guard !suggestions.isEmpty else { return "Options from your kitchen." }
        return suggestions.prefix(max).map(\.title).joined(separator: ", ")
    }
}
