// FoodNameMatcher.swift
// One boundary-aware canonical matcher for inventory, recipes, receipts, and zones.
import Foundation

nonisolated struct FoodMatch: Sendable, Equatable {
    let score: Double
    let matchedTokens: [String]
    var isConfident: Bool { score >= 0.72 }
}

nonisolated enum FoodNameMatcher {
    private static let stopWords: Set<String> = [
        "the", "a", "an", "of", "and", "with", "style", "brand", "organic", "natural",
        "fresh", "premium", "great", "value", "hill", "country", "fare", "heb", "h", "e", "b"
    ]

    private static let synonyms: [String: String] = [
        "scallions": "green onion", "scallion": "green onion", "spring onions": "green onion",
        "garbanzo": "chickpea", "garbanzos": "chickpea", "chickpeas": "chickpea",
        "yoghurt": "yogurt", "capsicum": "bell pepper", "courgette": "zucchini",
        "aubergine": "eggplant", "confectioners sugar": "powdered sugar", "canned": "can"
    ]

    /// PERF: `normalized(_:)` is the single hottest string path in the app — it runs
    /// ~4–6× per `matches()` call, and `matches()` runs O(ingredients × inventory) for
    /// every recipe card in the Discover rails. Sorting `synonyms` on every call (longest
    /// key first, so multi-word phrases replace before their sub-words) was pure repeated
    /// work. Sort once here; the dictionary is a compile-time constant so the order is stable.
    private static let synonymsByLengthDesc: [(from: String, to: String)] =
        synonyms.sorted { $0.key.count > $1.key.count }.map { (from: $0.key, to: $0.value) }

    static func normalized(_ raw: String) -> String {
        var text = raw.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
        text = text.replacingOccurrences(of: "&", with: " and ")
        text = text.components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        for (from, to) in synonymsByLengthDesc {
            text = replacingWholePhrase(from, with: to, in: text)
        }
        return text.split(separator: " ").map { singular(String($0)) }.joined(separator: " ")
    }

    static func tokens(_ raw: String, droppingStopWords: Bool = true) -> [String] {
        normalized(raw).split(separator: " ").map(String.init).filter {
            !droppingStopWords || !stopWords.contains($0)
        }
    }

    static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        let p = normalized(phrase)
        let t = normalized(text)
        guard !p.isEmpty, !t.isEmpty else { return false }
        return (" " + t + " ").contains(" " + p + " ")
    }

    static func matches(_ lhs: String, _ rhs: String) -> FoodMatch {
        let a = normalized(lhs), b = normalized(rhs)
        guard !a.isEmpty, !b.isEmpty else { return FoodMatch(score: 0, matchedTokens: []) }
        if a == b { return FoodMatch(score: 1, matchedTokens: tokens(a)) }
        if containsPhrase(a, in: b) || containsPhrase(b, in: a) {
            let shorter = min(a.count, b.count), longer = max(a.count, b.count)
            return FoodMatch(score: 0.88 + 0.1 * Double(shorter) / Double(max(1, longer)),
                             matchedTokens: tokens(shorter == a.count ? a : b))
        }
        let aa = Set(tokens(a)), bb = Set(tokens(b))
        guard !aa.isEmpty, !bb.isEmpty else { return FoodMatch(score: 0, matchedTokens: []) }
        let intersection = aa.intersection(bb)
        let containment = Double(intersection.count) / Double(min(aa.count, bb.count))
        let jaccard = Double(intersection.count) / Double(aa.union(bb).count)
        let score = min(0.86, containment * 0.68 + jaccard * 0.32)
        return FoodMatch(score: score, matchedTokens: intersection.sorted())
    }

    static func bestMatch<T>(for query: String, in values: [T], name: (T) -> String,
                             minimumScore: Double = 0.72) -> T? {
        values.compactMap { value -> (T, Double)? in
            let score = matches(query, name(value)).score
            return score >= minimumScore ? (value, score) : nil
        }.max(by: { $0.1 < $1.1 })?.0
    }

    static func anyPhrase(in text: String, phrases: [String]) -> Bool {
        phrases.sorted(by: { $0.count > $1.count }).contains { containsPhrase($0, in: text) }
    }

    private static func replacingWholePhrase(_ phrase: String, with replacement: String, in text: String) -> String {
        (" " + text + " ")
            .replacingOccurrences(of: " " + phrase + " ", with: " " + replacement + " ")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func singular(_ word: String) -> String {
        guard word.count > 3 else { return word }
        if word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
        if word.hasSuffix("oes") { return String(word.dropLast(2)) }
        if word.hasSuffix("ses") || word.hasSuffix("xes") || word.hasSuffix("ches") || word.hasSuffix("shes") {
            return String(word.dropLast(2))
        }
        if word.hasSuffix("s"), !word.hasSuffix("ss") { return String(word.dropLast()) }
        return word
    }
}
