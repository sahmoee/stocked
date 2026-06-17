// FuzzyMatch.swift
// Lightweight fuzzy matching for search fields. Supports subsequence matching
// (so "chkn" matches "chicken") plus a simple typo-tolerant score, without pulling
// in any dependency. Designed for short item/recipe names, not large corpora.

import Foundation

// nonisolated: pure string-matching helpers; safe to call from the RecipeDatabase actor.
nonisolated enum FuzzyMatch {

    /// True if `query` fuzzily matches `candidate`. Empty query matches everything.
    static func matches(_ query: String, _ candidate: String) -> Bool {
        let q = normalize(query)
        guard !q.isEmpty else { return true }
        let c = normalize(candidate)
        if c.contains(q) { return true }               // fast path: substring
        if isSubsequence(q, of: c) { return true }      // "chkn" → "chicken"
        return levenshtein(q, c.prefix(q.count + 2).description) <= maxDistance(for: q)
    }

    /// A 0…1 relevance score for ranking results (higher = better).
    static func score(_ query: String, _ candidate: String) -> Double {
        let q = normalize(query)
        guard !q.isEmpty else { return 0 }
        let c = normalize(candidate)
        if c == q { return 1.0 }
        if c.hasPrefix(q) { return 0.9 }
        if c.contains(q) { return 0.75 }
        if isSubsequence(q, of: c) { return 0.5 }
        let d = levenshtein(q, c)
        return max(0, 0.4 - Double(d) * 0.1)
    }

    // MARK: - Helpers
    private static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .diacriticInsensitive, locale: nil)
    }

    private static func maxDistance(for q: String) -> Int {
        q.count <= 4 ? 1 : 2
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var it = haystack.makeIterator()
        for ch in needle {
            var found = false
            while let h = it.next() {
                if h == ch { found = true; break }
            }
            if !found { return false }
        }
        return true
    }

    /// Classic Levenshtein edit distance.
    static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i-1] == b[j-1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j-1] + 1, prev[j-1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
