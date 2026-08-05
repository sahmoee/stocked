// FoodNameMatcher.swift
// One boundary-aware canonical matcher for inventory, recipes, receipts, and zones.
import Foundation

nonisolated struct FoodMatch: Sendable, Equatable {
    let score: Double
    let matchedTokens: [String]
    var isConfident: Bool { score >= 0.72 }
}

// MARK: - Memo store
//
// PERF (the Cook Now freeze, July 2026): `normalized(_:)` performs ~40 transient
// String allocations, and `matches(_:_:)` called it SIX times per comparison —
// four of those on strings that were already normalized. Cook Now classifies
// ~150 recipes × ~10 ingredients against ~60 inventory items, twice per pass, so
// a single "See meals" open was on the order of a million `normalized` calls on
// the main actor. That is the watchdog kill (signal 9), not a slow algorithm.
//
// Two fixes, both here so every caller in the app benefits and no call site
// changes: (1) memoize `normalized` on the raw string — food names repeat
// constantly, hit rate is >95%; (2) internal variants of `containsPhrase` and
// `tokens` that trust an already-normalized input, so `matches` normalizes twice
// instead of six times. A whole-pair result cache sits on top of that.
//
// Locked rather than actor-isolated because `FoodNameMatcher` is `nonisolated`
// and synchronous by contract — hundreds of call sites depend on that, and an
// uncontended NSLock costs far less than the work it saves.
private nonisolated final class FoodMatchMemo: @unchecked Sendable {
    static let shared = FoodMatchMemo()

    private let lock = NSLock()
    private var norm: [String: String] = [:]
    private var pairs: [String: FoodMatch] = [:]
    private var toks: [String: Set<String>] = [:]

    // Bounded: a long session sees a lot of receipt OCR noise. Clearing wholesale
    // beats an LRU here — refilling is cheap and the caches re-warm in one pass.
    //
    // PERF (the July 2026 field report): `pairCap` used to be 8000 and it was the
    // wrong number by an order of magnitude. A Cook Now pass over the full
    // Discover catalog asks about ~700 distinct ingredients against ~78 inventory
    // names — 54,000 distinct pairs. The cache filled, wholesale-cleared, filled
    // again, and cleared, roughly seven times per pass, so the hit rate inside a
    // single pass was near zero AND every miss paid the key-construction cost on
    // top of the compute. That is the cliff between "14 recipes, 17 ms" and
    // "134 recipes, 1230 ms" in the process log — 10× the recipes for 72× the
    // time, which is not the shape of an honestly linear algorithm.
    //
    // The real fix is the token index in KitchenAvailability, which stops most of
    // those pairs from ever being asked about. This raises the ceiling anyway so
    // the remaining pairs actually stay cached across a pass.
    private let normCap = 8000
    private let pairCap = 40000
    private let tokCap = 8000

    func normalized(_ raw: String, _ compute: (String) -> String) -> String {
        lock.lock()
        if let hit = norm[raw] { lock.unlock(); return hit }
        lock.unlock()

        let value = compute(raw)

        lock.lock()
        if norm.count >= normCap { norm.removeAll(keepingCapacity: true) }
        norm[raw] = value
        lock.unlock()
        return value
    }

    func match(_ a: String, _ b: String, _ compute: (String, String) -> FoodMatch) -> FoodMatch {
        // Order-independent key: `matches` is symmetric.
        let key = a <= b ? a + "\u{1}" + b : b + "\u{1}" + a
        lock.lock()
        if let hit = pairs[key] { lock.unlock(); return hit }
        lock.unlock()

        let value = compute(a, b)

        lock.lock()
        if pairs.count >= pairCap { pairs.removeAll(keepingCapacity: true) }
        pairs[key] = value
        lock.unlock()
        return value
    }

    func tokenSet(_ raw: String, _ compute: (String) -> Set<String>) -> Set<String> {
        lock.lock()
        if let hit = toks[raw] { lock.unlock(); return hit }
        lock.unlock()

        let value = compute(raw)

        lock.lock()
        if toks.count >= tokCap { toks.removeAll(keepingCapacity: true) }
        toks[raw] = value
        lock.unlock()
        return value
    }

    /// Memory-warning / test hook. Correctness never depends on cache contents:
    /// the inputs are pure strings and the transform is deterministic.
    func purge() {
        lock.lock()
        norm.removeAll(keepingCapacity: false)
        pairs.removeAll(keepingCapacity: false)
        toks.removeAll(keepingCapacity: false)
        lock.unlock()
    }
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

    /// Drop every cached normalization and comparison. Safe at any time — the
    /// caches are pure memoization of deterministic pure functions.
    static func purgeCaches() { FoodMatchMemo.shared.purge() }

    static func normalized(_ raw: String) -> String {
        FoodMatchMemo.shared.normalized(raw, computeNormalized)
    }

    private static func computeNormalized(_ raw: String) -> String {
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
        tokensOfNormalized(normalized(raw), droppingStopWords: droppingStopWords)
    }

    /// The token set `matches(_:_:)` compares — memoized, and exposed so callers
    /// can index by it.
    ///
    /// THE GUARANTEE THIS EXISTS FOR: read `computeMatch` and every path to a
    /// non-zero score requires the two token sets to intersect. Equality shares
    /// all tokens; phrase containment means one name's words appear verbatim
    /// inside the other's, so its tokens are a subset; and the fallback score is
    /// `containment * 0.68 + jaccard * 0.32`, both of which are zero when the
    /// intersection is empty. So *disjoint token sets imply score 0*, exactly,
    /// with no threshold tuning involved — which makes it safe to skip the
    /// comparison entirely rather than compute a zero.
    ///
    /// The one hole is a name that normalizes to nothing but stop words, whose
    /// token set is empty and so intersects nothing. Callers must treat an empty
    /// set as "compare against everything" rather than "matches nothing".
    static func matchTokens(_ raw: String) -> Set<String> {
        FoodMatchMemo.shared.tokenSet(raw) { Set(tokensOfNormalized(normalized($0))) }
    }

    /// Tokens of a string that is ALREADY normalized — skips the re-normalization
    /// `tokens(_:)` used to pay for inside `matches`.
    private static func tokensOfNormalized(_ text: String, droppingStopWords: Bool = true) -> [String] {
        text.split(separator: " ").map(String.init).filter {
            !droppingStopWords || !stopWords.contains($0)
        }
    }

    static func containsPhrase(_ phrase: String, in text: String) -> Bool {
        containsNormalizedPhrase(normalized(phrase), in: normalized(text))
    }

    /// Both arguments already normalized.
    private static func containsNormalizedPhrase(_ p: String, in t: String) -> Bool {
        guard !p.isEmpty, !t.isEmpty else { return false }
        return (" " + t + " ").contains(" " + p + " ")
    }

    static func matches(_ lhs: String, _ rhs: String) -> FoodMatch {
        FoodMatchMemo.shared.match(lhs, rhs, computeMatch)
    }

    private static func computeMatch(_ lhs: String, _ rhs: String) -> FoodMatch {
        let a = normalized(lhs), b = normalized(rhs)
        guard !a.isEmpty, !b.isEmpty else { return FoodMatch(score: 0, matchedTokens: []) }
        if a == b { return FoodMatch(score: 1, matchedTokens: tokensOfNormalized(a)) }
        if containsNormalizedPhrase(a, in: b) || containsNormalizedPhrase(b, in: a) {
            let shorter = min(a.count, b.count), longer = max(a.count, b.count)
            return FoodMatch(score: 0.88 + 0.1 * Double(shorter) / Double(max(1, longer)),
                             matchedTokens: tokensOfNormalized(shorter == a.count ? a : b))
        }
        let aa = Set(tokensOfNormalized(a)), bb = Set(tokensOfNormalized(b))
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
        let t = normalized(text)
        return phrases.sorted(by: { $0.count > $1.count })
            .contains { containsNormalizedPhrase(normalized($0), in: t) }
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
