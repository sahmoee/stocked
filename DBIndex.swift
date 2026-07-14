// DBIndex.swift — Reusable indexing primitives for the Build 131 database pass.
//
// The app's in-memory "databases" (ingredients, brands, nutrition, recipes, knowledge base)
// historically answered lookups with linear `.filter { $0.name.lowercased() == … }` scans,
// re-lowercasing every element on every keystroke. These helpers replace that with:
//   • DBNormalize        — normalize a string ONCE (#2)
//   • NameIndex          — O(1) exact-name lookup (#1)
//   • PrefixIndex        — fast autocomplete by leading characters (#3)
//   • PositionIndex      — O(1) "where is the element with id X" for by-id mutation (#5)
//
// All are value types / lightweight classes with no external dependencies.

import Foundation

// MARK: - Normalization (#2)
// One canonical place to fold case + diacritics + surrounding whitespace, so the SAME
// rule is used to build an index and to query it. Diacritic folding makes "jalapeño" and
// "jalapeno" match.

enum DBNormalize {
    static func key(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// First `n` characters of the normalized key — the bucket used by PrefixIndex.
    static func prefixBucket(_ s: String, length n: Int = 2) -> String {
        let k = key(s)
        return String(k.prefix(n))
    }
}

// MARK: - Exact-name index (#1)
// Maps a normalized name (and optional synonyms/aliases) to the element. Built once,
// queried in O(1). Use for "look up the entry for this exact ingredient/brand/food".

struct NameIndex<Element> {
    private var map: [String: Element] = [:]

    init() {}

    /// Build from a sequence, deriving the primary key and any extra keys (synonyms) per element.
    init<S: Sequence>(_ elements: S,
                      key keyFor: (Element) -> String,
                      extraKeys: (Element) -> [String] = { _ in [] }) where S.Element == Element {
        for el in elements {
            let primary = DBNormalize.key(keyFor(el))
            if !primary.isEmpty, map[primary] == nil { map[primary] = el }
            for extra in extraKeys(el) {
                let k = DBNormalize.key(extra)
                if !k.isEmpty, map[k] == nil { map[k] = el }
            }
        }
    }

    /// O(1) exact lookup on the normalized form of `name`.
    func first(matching name: String) -> Element? { map[DBNormalize.key(name)] }
    func contains(_ name: String) -> Bool { map[DBNormalize.key(name)] != nil }
    var count: Int { map.count }
}

// MARK: - Prefix index for autocomplete (#3)
// Buckets element indices by the first N normalized characters, so typing narrows the
// candidate set with a dictionary hit instead of scanning everything. Returns candidate
// indices into the caller's backing array; the caller does final ranking.

struct PrefixIndex {
    private var buckets: [String: [Int]] = [:]
    private let bucketLength: Int

    init(bucketLength: Int = 2) { self.bucketLength = bucketLength }

    init<S: Sequence>(_ names: S, bucketLength: Int = 2) where S.Element == String {
        self.bucketLength = bucketLength
        for (i, name) in names.enumerated() {
            let b = DBNormalize.prefixBucket(name, length: bucketLength)
            guard !b.isEmpty else { continue }
            buckets[b, default: []].append(i)
        }
    }

    /// Candidate indices whose name could match `query` by prefix. For queries shorter than
    /// the bucket length, unions the matching buckets; longer queries use the leading bucket.
    func candidates(for query: String) -> [Int] {
        let q = DBNormalize.key(query)
        guard !q.isEmpty else { return [] }
        if q.count >= bucketLength {
            return buckets[String(q.prefix(bucketLength))] ?? []
        }
        // Short query: union every bucket that starts with it.
        return buckets.compactMap { $0.key.hasPrefix(q) ? $0.value : nil }.flatMap { $0 }
    }
}

// MARK: - Position index for by-id mutation (#5)
// Replaces O(n) `firstIndex(where: { $0.id == id })` with an O(1) dictionary lookup.
// Rebuild after a bulk replace; update incrementally on single insert/remove.

struct PositionIndex {
    private var map: [UUID: Int] = [:]

    init() {}
    init<S: Sequence>(_ ids: S) where S.Element == UUID {
        for (i, id) in ids.enumerated() { map[id] = i }
    }

    func index(of id: UUID) -> Int? { map[id] }
    mutating func rebuild<S: Sequence>(from ids: S) where S.Element == UUID {
        map.removeAll(keepingCapacity: true)
        for (i, id) in ids.enumerated() { map[id] = i }
    }
}
