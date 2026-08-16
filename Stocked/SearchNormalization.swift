// SearchNormalization.swift — Diacritic- and case-insensitive search matching (#9).
//
// Inventory/recipe search previously did `name.lowercased().contains(query.lowercased())`,
// which fails across accents: typing "jalapeno" wouldn't match a stored "Jalapeño", and
// "creme" wouldn't match "crème". Folding both sides to a diacritic-insensitive, lowercased
// form fixes that and also trims/normalizes whitespace. This is the single place that
// defines "do these strings match for search", so every search surface stays consistent.

import Foundation

// nonisolated: pure string functions with no shared state, callable from any context —
// main-actor views AND nonisolated engines (PurchaseDedupEngine builds comparison keys
// off the main actor). Without this, the app's default main-actor isolation makes
// `fold` main-actor-isolated and every nonisolated caller fails to compile.
nonisolated enum SearchNormalization {

    /// Fold a string to a comparable form: lowercased, diacritic-stripped, whitespace-trimmed.
    /// Uses the current locale for correct case folding (e.g. Turkish İ/i).
    static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                  locale: .current)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True if `query` matches `text` as a search term (substring, accent/case-insensitive).
    /// An empty query matches everything (callers usually guard this themselves).
    static func matches(_ text: String, query: String) -> Bool {
        let q = fold(query)
        guard !q.isEmpty else { return true }
        return fold(text).contains(q)
    }
}

nonisolated extension String {
    /// Convenience: `item.name.searchMatches(query)`.
    func searchMatches(_ query: String) -> Bool {
        SearchNormalization.matches(self, query: query)
    }
    /// The folded form, for building comparison keys / sorts.
    var searchFolded: String { SearchNormalization.fold(self) }
}
