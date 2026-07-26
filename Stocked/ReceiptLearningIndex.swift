// ReceiptLearningIndex.swift — Improvement #13: receipt scanning that gets better with use.
//
// Today `GuestDataStore.translateOCR(_:)` does an EXACT, full-string, case-insensitive match over
// an array it re-decodes from UserDefaults on every call — and it's called once per line of every
// receipt. Three consequences:
//
//   1. "ORG CHKN BRST" learned once does nothing for "ORG CHKN BRST 2LB" next week. Receipt lines
//      vary by weight, promo suffix and register software; exact matching almost never re-fires.
//   2. Corrections aren't scoped to a store, so H-E-B's "GV" and Walmart's "GV" fight over the
//      same key even though they mean different things.
//   3. O(n) decode × n lines is O(n²) JSON decoding per scan.
//
// This adds a store-scoped, fuzzy-tolerant index built once per scan. It reads the SAME
// `ocrDictionary` the app already writes, so nothing needs migrating and the existing correction
// UI keeps working unchanged.

import Foundation

// MARK: - Model

nonisolated struct StoreScopedCorrection: Codable, Sendable, Hashable {
    var raw: String
    var resolved: String
    var store: String
    var useCount: Int
}

// MARK: - Index

@MainActor
@Observable
final class ReceiptLearningIndex {
    static let shared = ReceiptLearningIndex()
    private init() {}

    /// Built from `ocrDictionary` once per scan rather than per line.
    private var exact: [String: String] = [:]
    /// Tokenised form of each learned raw string, for the fuzzy pass.
    private var tokenized: [(tokens: Set<String>, resolved: String, useCount: Int)] = []
    private var builtCount = -1

    private let storeScopeKey = "ocrStoreScope_v1"

    /// Per-store overrides layered on top of the global dictionary.
    /// Key is "store|rawLowercased" so two chains can disagree about the same abbreviation.
    private var storeScoped: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storeScopeKey),
                  let map = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
            return map
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: storeScopeKey)
            }
        }
    }

    // MARK: Build

    /// Call once before processing a receipt. Cheap when the dictionary hasn't changed.
    func rebuildIfNeeded(from dictionary: [OCRTranslation]) {
        guard dictionary.count != builtCount else { return }
        rebuild(from: dictionary)
    }

    func rebuild(from dictionary: [OCRTranslation]) {
        var ex: [String: String] = [:]
        var tk: [(Set<String>, String, Int)] = []
        for entry in dictionary {
            let key = ReceiptLearningIndex.normalize(entry.rawText)
            guard !key.isEmpty else { continue }
            ex[key] = entry.resolved
            tk.append((ReceiptLearningIndex.tokens(entry.rawText), entry.resolved, entry.useCount))
        }
        exact = ex
        // Most-used first: when two learned entries both plausibly match a messy line, the one the
        // user has confirmed more often is the better bet.
        tokenized = tk.sorted { $0.2 > $1.2 }.map { (tokens: $0.0, resolved: $0.1, useCount: $0.2) }
        builtCount = dictionary.count
    }

    // MARK: Lookup

    /// Resolve an OCR line to a product name.
    ///
    /// Order: this store's own correction → global exact match → fuzzy token overlap.
    /// Returns nil when nothing is confident enough, so the caller falls through to the
    /// abbreviation DB and then the AI, exactly as before.
    func resolve(_ raw: String, store: String) -> String? {
        let key = ReceiptLearningIndex.normalize(raw)
        guard !key.isEmpty else { return nil }

        if !store.isEmpty, let scoped = storeScoped["\(store.lowercased())|\(key)"] {
            return scoped
        }
        if let hit = exact[key] { return hit }
        return fuzzy(raw)
    }

    /// Token-overlap match. "ORG CHKN BRST 2LB" still finds the entry learned from
    /// "ORG CHKN BRST" because three of its four meaningful tokens line up.
    ///
    /// The 0.7 threshold and the two-token floor are deliberately strict: a wrong product name on a
    /// receipt is worse than no name, because the user may not notice it in the review list.
    private func fuzzy(_ raw: String) -> String? {
        let want = ReceiptLearningIndex.tokens(raw)
        guard want.count >= 2 else { return nil }
        var bestScore = 0.0
        var best: String? = nil
        for candidate in tokenized {
            guard candidate.tokens.count >= 2 else { continue }
            let overlap = Double(want.intersection(candidate.tokens).count)
            let score = overlap / Double(max(want.count, candidate.tokens.count))
            if score > bestScore { bestScore = score; best = candidate.resolved }
        }
        return bestScore >= 0.7 ? best : nil
    }

    // MARK: Learn

    /// Record a correction against a specific store as well as globally.
    /// The caller still writes the global entry via `GuestDataStore.learnOCRCorrection`; this adds
    /// the store dimension so chains with conflicting abbreviations stop overwriting each other.
    func learn(raw: String, resolved: String, store: String) {
        guard !store.isEmpty else { return }
        let key = ReceiptLearningIndex.normalize(raw)
        guard !key.isEmpty, key != resolved.lowercased() else { return }
        var map = storeScoped
        map["\(store.lowercased())|\(key)"] = resolved
        // Bound it — receipts generate a lot of one-off lines and this lives in UserDefaults.
        if map.count > 500 { map = Dictionary(uniqueKeysWithValues: Array(map).suffix(400)) }
        storeScoped = map
        builtCount = -1   // force a rebuild so the new entry applies to the rest of this receipt
    }

    var storeScopedCount: Int { storeScoped.count }
    var learnedCount: Int { exact.count }

    // MARK: Normalisation

    nonisolated static func normalize(_ s: String) -> String {
        s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Meaningful tokens only: drop pure numbers, weights and units, which are the parts that
    /// change line-to-line for the same product.
    nonisolated static func tokens(_ s: String) -> Set<String> {
        let noise: Set<String> = ["lb", "lbs", "oz", "ea", "ct", "pk", "kg", "g", "f", "t", "x"]
        return Set(
            s.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { token in
                    guard token.count >= 2 else { return false }
                    if Double(token) != nil { return false }
                    if noise.contains(token) { return false }
                    // "2lb", "16oz" — a number glued to a unit.
                    if token.first?.isNumber == true { return false }
                    return true
                }
        )
    }
}
