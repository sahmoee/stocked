// KitchenAvailability.swift
// ─────────────────────────────────────────────────────────────────────────────
// THE single authority for "do I have this?" and "how much of this recipe can I
// make?".
//
// WHY THIS FILE EXISTS
// Before this file, the app answered "is this ingredient in stock?" six
// different ways:
//
//   1. CookNowEngine.looseMatch      — two-way substring, count > 2 guard
//   2. GuestDataStore.looseMatch     — byte-identical copy of #1
//   3. RecipeVaultViews.looseMatch   — byte-identical copy of #1
//   4. KitchenStock.isInStock        — two-way substring on a name Set
//   5. SurpriseRecipeEngine.inStock  — two-way substring, local closure
//   6. OnlineRecipeMatch.stockMatch  — FoodNameMatcher score >= 0.72
//
// Substring matching (#1–#5) is far LOOSER than token scoring (#6): "oil"
// satisfies "olive oil", "garlic" satisfies "garlic powder", and any three-char
// collision passes. So the Cook tab (which used #1) over-reported readiness
// while the Recipes tab (which used #6) under-reported it, and the same kitchen
// produced "100% — everything in stock" on one screen and "5 missing" on
// another for comparable recipes.
//
// On top of that the two paths disagreed about the DENOMINATOR: the Cook path
// dropped optional ingredients, the Recipes path counted them.
//
// Everything now routes here. The five substring matchers are kept as thin
// deprecated shims that forward to `nameMatches` so call sites did not have to
// change in one enormous diff, but they no longer carry any logic of their own.
//
// RULES THIS FILE OWNS — change them here and every surface follows:
//   • what counts as a name match           (confidenceThreshold)
//   • what counts as "in stock"             (availableFillFloor)
//   • whether optional ingredients count    (coverage excludes them)
//   • what a coverage fraction means        (Coverage)
//
// Pure, nonisolated, Sendable-safe: callers may run it off the main actor and
// cache the result against the store's revision counters, exactly as
// CookNowCompute and stockMatchCache already do. Nothing here touches the store.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

nonisolated enum KitchenAvailability {

    // MARK: - The rules

    /// Minimum `FoodNameMatcher` score for two food names to be considered the
    /// same thing. 0.72 is the value `FoodMatch.isConfident` already used and
    /// the value the Discover badges shipped with, so adopting it app-wide
    /// tightens the loose paths rather than loosening the strict one.
    static let confidenceThreshold: Double = 0.72

    /// Fill level strictly above which an item is considered available at all.
    /// `IngredientStockMatch` used 0.05, `CookNowCompute` used 0.0, and
    /// `inStockNameSet` used 0.0 on the raw (not effective) level. 0.05 is the
    /// honest one: an item scraped down to a smear is not an ingredient.
    static let availableFillFloor: Double = 0.05

    // MARK: - Name matching

    /// Are these two food names the same thing? Boundary- and synonym-aware.
    ///
    /// This replaces every `looseMatch`/`inStock` substring helper in the app.
    /// It is deliberately stricter than they were: substring containment is
    /// still a strong signal inside `FoodNameMatcher` (it scores 0.88+), but a
    /// bare three-character overlap no longer passes.
    static func nameMatches(_ lhs: String, _ rhs: String) -> Bool {
        FoodNameMatcher.matches(lhs, rhs).score >= confidenceThreshold
    }

    /// Score for callers that want to rank rather than threshold.
    static func matchScore(_ lhs: String, _ rhs: String) -> Double {
        FoodNameMatcher.matches(lhs, rhs).score
    }

    // MARK: - "Do I have this?" against name collections

    /// Is `ingredient` present in a collection of inventory item names?
    /// `names` is expected to already be filtered to available items (see
    /// `availableNames(in:)`).
    ///
    /// This is the linear fallback for callers holding an arbitrary sequence.
    /// Prefer the `Set<String>` overload below — it goes through the token index
    /// and skips the comparisons that provably score zero.
    static func isPresent(_ ingredient: String, inNames names: some Sequence<String>) -> Bool {
        let parsed = parsedName(ingredient)
        guard !parsed.isEmpty else { return false }
        return names.contains { nameMatches(parsed, $0) }
    }

    /// Indexed overload. Concrete types win overload resolution over generic
    /// ones, so every existing call site passing a `Set` — and they nearly all
    /// do, because `availableNames(in:)` returns one — picks this up with no
    /// source change and no behaviour change.
    static func isPresent(_ ingredient: String, inNames names: Set<String>) -> Bool {
        let parsed = parsedName(ingredient)
        guard !parsed.isEmpty else { return false }
        return index(for: names).contains(parsed)
    }

    /// Is `ingredient` present in an index the caller already built? The fastest
    /// form — no set hashing, no memo lookup, just the parse and the index hit.
    /// Callers that ask about one fixed inventory many times over (the Cook Now
    /// engine, above all) should hold a `NameIndex` and use this.
    static func isPresent(_ ingredient: String, in index: NameIndex) -> Bool {
        let parsed = parsedName(ingredient)
        guard !parsed.isEmpty else { return false }
        return index.contains(parsed)
    }

    /// Is `ingredient` present in the inventory?
    ///
    /// PERF: routed through the indexed name overload rather than scanning
    /// `items` directly. Building the name Set is O(n) allocation + hashing;
    /// the scan it replaces was O(n) *fuzzy comparisons*, each of which
    /// normalizes two strings and computes a token score. Behaviour is
    /// identical — `availableNames(in:)` applies the same `availableFillFloor`
    /// this loop did, and its lowercasing is a no-op because `nameMatches`
    /// normalizes (and therefore lowercases) both sides anyway.
    static func isPresent(_ ingredient: String, in items: [LocalInventoryItem]) -> Bool {
        isPresent(ingredient, inNames: availableNames(in: items))
    }

    /// The canonical available-item filter. Every "in stock" list in the app
    /// should start here so they all agree on the fill floor AND on reading
    /// `effectiveLevel` rather than the raw `level` (raw ignores the
    /// expiry-decay adjustment, which is why the Daily Brief used to disagree
    /// with Inventory about what was running low).
    static func availableItems(in items: [LocalInventoryItem]) -> [LocalInventoryItem] {
        items.filter { $0.effectiveLevel > availableFillFloor }
    }

    /// Lowercased names of everything available — the shape `inStockNameSet`,
    /// `KitchenStock`, and the Discover rails all want.
    static func availableNames(in items: [LocalInventoryItem]) -> Set<String> {
        Set(availableItems(in: items).map { $0.name.lowercased() })
    }

    /// Strip quantity/unit/prep noise off a recipe ingredient line so matching
    /// compares food to food. "1 cup all-purpose flour, sifted" → "flour".
    /// Falls back to the raw string when parsing yields nothing.
    static func parsedName(_ ingredientLine: String) -> String {
        // PERF: this runs once per ingredient per inventory comparison — millions of
        // times during a Cook Now classification pass — and `RecipeIngredients.parse`
        // is a full quantity/unit/prep parse. Memoized on the raw line; the transform
        // is pure and deterministic, so a cache hit is indistinguishable from a miss.
        ParsedNameMemo.shared.value(for: ingredientLine) { line in
            let parsed = RecipeIngredients.parse(line).name
            let trimmed = parsed.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? line.trimmingCharacters(in: .whitespacesAndNewlines)
                : trimmed
        }
    }

    // MARK: - Coverage

    /// How much of a recipe the kitchen covers. One shape, used by the Cook
    /// tab, the Recipes tab, the match ring, Home's meal count, and the
    /// planner — so the number, the ring, and the prose can never disagree.
    ///
    /// `total` counts REQUIRED ingredients only. Optional ingredients are
    /// excluded from both numerator and denominator; a recipe is not "missing"
    /// its garnish.
    nonisolated struct Coverage: Sendable, Equatable {
        let have: Int
        let total: Int
        /// Required ingredient display names still unaccounted for, computed by
        /// the SAME rule that produced `have` — so `missingNames.count` is
        /// always exactly `total - have`. (The previous `RecipeCoverage`
        /// computed these two by different rules and they could disagree.)
        let missingNames: [String]

        var fraction: Double { total > 0 ? Double(have) / Double(total) : 0 }
        var isComplete: Bool { total > 0 && have >= total }
        var missingCount: Int { max(0, total - have) }

        static let empty = Coverage(have: 0, total: 0, missingNames: [])
    }

    /// Coverage for a list of ingredient lines against available item names.
    ///
    /// - Parameters:
    ///   - lines: raw ingredient strings (quantities and prep notes are fine).
    ///   - optionalFlags: parallel array marking optional ingredients. Pass an
    ///     empty array when the caller has no optional information, in which
    ///     case `isOptionalLine` is consulted for the "(optional)" convention.
    ///   - availableNames: lowercased names of available inventory items.
    static func coverage(lines: [String],
                         optionalFlags: [Bool] = [],
                         availableNames: Set<String>) -> Coverage {
        var required: [String] = []
        required.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            let isOptional = index < optionalFlags.count
                ? optionalFlags[index]
                : isOptionalLine(line)
            guard !isOptional else { continue }
            let name = parsedName(line)
            guard !name.isEmpty else { continue }
            required.append(name)
        }

        guard !required.isEmpty else { return .empty }

        // PERF: one index build for the whole recipe instead of a full linear
        // fuzzy scan per required ingredient. `index(for:)` is memoized on the
        // name set, so classifying a catalog of recipes against one unchanged
        // inventory builds it exactly once.
        let idx = index(for: availableNames)

        var have = 0
        var missing: [String] = []
        for name in required {
            if idx.contains(name) {
                have += 1
            } else {
                missing.append(name)
            }
        }
        return Coverage(have: have, total: required.count, missingNames: missing)
    }

    // MARK: - Token index
    //
    // PERF (the Cook Now freeze, July 2026 field export): a full classification
    // pass asked about ~700 distinct ingredients against ~78 in-stock names —
    // ~54,000 fuzzy comparisons, each normalizing two strings and scoring their
    // tokens, every one of them on the main actor. The process log recorded
    // "14 recipes, 17 ms" against "134 recipes, 1230 ms": 10× the recipes for
    // 72× the time, which is not the shape of a linear algorithm.
    //
    // Almost all of those comparisons are answered zero. `FoodNameMatcher`
    // guarantees exactly when: read `matchTokens`' doc comment — every path to
    // a non-zero score requires the two token sets to intersect, so DISJOINT
    // TOKEN SETS IMPLY SCORE 0, precisely and with no threshold tuning. That
    // makes an inverted token index a lossless filter rather than a heuristic:
    // skipping a comparison here can never change an answer.
    //
    // The one hole is a name that normalizes to nothing but stop words, whose
    // token set is empty and therefore intersects nothing. Those are held in
    // `untokenized` and compared every time, per the contract `matchTokens`
    // states — an empty set means "compare against everything", not "matches
    // nothing".

    /// An inverted word → names index over a set of inventory names, so a
    /// lookup compares against the names sharing a word instead of all of them.
    nonisolated struct NameIndex: Sendable {
        private let names: [String]
        private let byToken: [String: [Int]]
        /// Names with no tokens at all — never findable by token, so always tried.
        private let untokenized: [Int]

        init(_ source: Set<String>) {
            var names: [String] = []
            var byToken: [String: [Int]] = [:]
            var untokenized: [Int] = []
            names.reserveCapacity(source.count)
            for name in source {
                let i = names.count
                names.append(name)
                let tokens = FoodNameMatcher.matchTokens(name)
                if tokens.isEmpty {
                    untokenized.append(i)
                } else {
                    for t in tokens { byToken[t, default: []].append(i) }
                }
            }
            self.names = names
            self.byToken = byToken
            self.untokenized = untokenized
        }

        /// Names that could possibly match `parsed`. A superset of the true
        /// matches — the caller still applies `nameMatches`.
        func candidates(for parsed: String) -> [String] {
            let tokens = FoodNameMatcher.matchTokens(parsed)
            guard !tokens.isEmpty else { return names }
            var hits = Set<Int>(untokenized)
            for t in tokens {
                if let bucket = byToken[t] { hits.formUnion(bucket) }
            }
            return hits.map { names[$0] }
        }

        func contains(_ parsed: String) -> Bool {
            candidates(for: parsed).contains { nameMatches(parsed, $0) }
        }
    }

    /// A memoized index over `names`. Cheap to call repeatedly with the same
    /// set — which is the point, since every recipe in a classification pass
    /// asks about the same inventory.
    static func index(for names: Set<String>) -> NameIndex {
        NameIndexMemo.shared.index(for: names)
    }

    /// Does this ingredient line mark itself optional? Mirrors the convention
    /// `IngredientStockMatch.isOptional` already recognises so imported
    /// recipes without a structured flag still behave correctly.
    static func isOptionalLine(_ line: String) -> Bool {
        FoodNameMatcher.anyPhrase(in: line, phrases: optionalPhrases)
    }

    /// Kept in one place so `IngredientStockMatch` and this type cannot drift.
    static let optionalPhrases = ["optional", "for garnish", "to taste", "as needed", "if desired"]

    // MARK: - Thresholds bridge

    /// Is this item running low? One rule, replacing the 0.2 / 0.25 / 0.33
    /// constants that were scattered across the widget, the Daily Brief, the
    /// grocery list, and the inventory sheets.
    ///
    /// Deliberately delegates to `LocalInventoryItem.isLow`, which already
    /// existed and already read `KitchenThresholds.lowFillLevel` — AND folds in
    /// the below-par check. Defining a second rule here, even a correct one,
    /// would recreate exactly the problem this file exists to remove. The value
    /// of this wrapper is discoverability: call sites reaching for an
    /// availability answer find it in one type.
    static func isRunningLow(_ item: LocalInventoryItem) -> Bool {
        item.isLow
    }

    /// Is this item critically low — near-empty rather than merely low? Used by
    /// the widget and notification copy, which want a tighter bar than the
    /// grocery suggestions do.
    static func isCriticallyLow(_ item: LocalInventoryItem) -> Bool {
        item.effectiveLevel > 0 && item.effectiveLevel < KitchenThresholds.criticalFillLevel
    }
}

/// Memo for `KitchenAvailability.parsedName`. Locked rather than actor-isolated
/// because the enum is `nonisolated` and synchronous by contract.
private nonisolated final class ParsedNameMemo: @unchecked Sendable {
    static let shared = ParsedNameMemo()
    private let lock = NSLock()
    private var cache: [String: String] = [:]
    private let cap = 4000

    func value(for key: String, _ compute: (String) -> String) -> String {
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        let value = compute(key)
        lock.lock()
        if cache.count >= cap { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        lock.unlock()
        return value
    }

    func purge() { lock.lock(); cache.removeAll(keepingCapacity: false); lock.unlock() }
}

/// Memo for `KitchenAvailability.index(for:)`. Keyed by the name set itself, so
/// the index is rebuilt exactly when the inventory actually changes and not on
/// any other signal. The cap is small on purpose: a handful of distinct name
/// sets are live at once (current inventory, plus whatever a sheet is holding),
/// and each index is proportional to the inventory, not the catalog.
private nonisolated final class NameIndexMemo: @unchecked Sendable {
    static let shared = NameIndexMemo()
    private let lock = NSLock()
    private var cache: [Set<String>: KitchenAvailability.NameIndex] = [:]
    private let cap = 8

    func index(for names: Set<String>) -> KitchenAvailability.NameIndex {
        lock.lock()
        if let hit = cache[names] { lock.unlock(); return hit }
        lock.unlock()

        let built = KitchenAvailability.NameIndex(names)

        lock.lock()
        if cache.count >= cap { cache.removeAll(keepingCapacity: true) }
        cache[names] = built
        lock.unlock()
        return built
    }

    func purge() { lock.lock(); cache.removeAll(keepingCapacity: false); lock.unlock() }
}

extension KitchenAvailability {
    /// Drop every memoized parse + name comparison. Safe at any time.
    /// Explicitly `nonisolated`: the module builds with default main-actor
    /// isolation, and this touches only lock-guarded pure caches.
    nonisolated static func purgeCaches() {
        ParsedNameMemo.shared.purge()
        NameIndexMemo.shared.purge()
        FoodNameMatcher.purgeCaches()
    }
}
