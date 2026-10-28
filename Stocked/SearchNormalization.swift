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

    /// Discovery only: every query word must match a field, with one typo allowed
    /// for words of at least four characters. Never use this to merge records or
    /// decide which ingredients are safe to cook with.
    static func discoveryMatches(_ fields: [String], query: String) -> Bool {
        let foldedQuery = fold(query)
        guard !foldedQuery.isEmpty else { return true }
        let normalized = fields.map(fold)
        let terms = words(foldedQuery)
        guard !terms.isEmpty else { return normalized.contains { $0.contains(foldedQuery) } }
        if normalized.contains(where: { $0.contains(foldedQuery) }) { return true }
        let candidates = normalized.flatMap(words)
        return terms.allSatisfy { term in
            normalized.contains { $0.contains(term) } ||
                (term.count >= 4 && term.count <= 64 && candidates.contains {
                    $0.count >= 4 && $0.count <= 64 && oneEditApart(term, $0)
                })
        }
    }

    private static func words(_ value: String) -> [String] {
        value.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Bounded linear comparison, including adjacent transpositions.
    private static func oneEditApart(_ lhs: String, _ rhs: String) -> Bool {
        let a = Array(lhs), b = Array(rhs)
        guard abs(a.count - b.count) <= 1 else { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            guard edits <= 1 else { return false }
            if a.count == b.count {
                if i + 1 < a.count && a[i] == b[j + 1] && a[i + 1] == b[j] {
                    i += 2; j += 2
                } else { i += 1; j += 1 }
            } else if a.count > b.count { i += 1 }
            else { j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
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
