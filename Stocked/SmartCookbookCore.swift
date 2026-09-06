import Foundation

/// A saved query, never a separate copy of recipe records.
nonisolated struct SmartCookbookRule: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var name = ""
    var text = ""
    var cuisine = ""
    var category = ""
    var requiredTags: [String] = []
    var excludedTags: [String] = []
    var favoritesOnly = false
    var maxPrepMinutes: Int?
    var maxCookMinutes: Int?
    var order: Order = .name
    var updatedAt: Double = 0
    var lastWriterID = ""

    static let maximumRules = 50
    static let maximumEncodedBytes = 32 * 1024

    static func validateCollection(_ rules: [Self]) throws {
        guard rules.count <= maximumRules,
              Set(rules.map(\.id)).count == rules.count,
              try JSONEncoder().encode(rules).count <= maximumEncodedBytes else {
            throw ValidationError.collectionFull
        }
        for rule in rules { _ = try rule.validated() }
    }

    /// Concurrent offline additions are preserved by household merge. An oversized
    /// collection can be reduced safely instead of trapping users above the limit.
    static func validateChange(from old: [Self], to next: [Self]) throws {
        let oldBytes = try JSONEncoder().encode(old).count
        let nextBytes = try JSONEncoder().encode(next).count
        if next.count <= maximumRules && nextBytes <= maximumEncodedBytes {
            try validateCollection(next); return
        }
        guard (old.count > maximumRules || oldBytes > maximumEncodedBytes),
              next.count <= old.count, nextBytes <= oldBytes,
              next.count < old.count || nextBytes < oldBytes,
              Set(next.map(\.id)).count == next.count else { throw ValidationError.collectionFull }
        for rule in next { _ = try rule.validated() }
    }

    enum Order: String, Codable, CaseIterable, Sendable {
        case name, newest, shortestCookTime
        var label: String {
            switch self {
            case .name: "Recipe name"
            case .newest: "Recently saved"
            case .shortestCookTime: "Shortest cook time"
            }
        }
    }

    func validated() throws -> Self {
        var rule = self
        rule.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.name.isEmpty, rule.name.count <= 80, text.count <= 200,
              cuisine.count <= 80, category.count <= 80,
              requiredTags.count <= 10, excludedTags.count <= 10,
              (requiredTags + excludedTags).allSatisfy({ $0.count <= 80 }),
              [maxPrepMinutes, maxCookMinutes].compactMap({ $0 }).allSatisfy({ (0...1440).contains($0) }) else {
            throw ValidationError.invalid
        }
        rule.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.cuisine = cuisine.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        rule.requiredTags = normalizedTags(requiredTags)
        rule.excludedTags = normalizedTags(excludedTags)
        guard Set(rule.requiredTags.map(SmartCookbookQuery.normalize)).isDisjoint(with: Set(rule.excludedTags.map(SmartCookbookQuery.normalize))) else {
            throw ValidationError.contradictoryTags
        }
        return rule
    }

    private func normalizedTags(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter {
            !$0.isEmpty && seen.insert(SmartCookbookQuery.normalize($0)).inserted
        }
    }

    enum ValidationError: LocalizedError {
        case invalid, contradictoryTags, collectionFull
        var errorDescription: String? {
            switch self {
            case .invalid: "Give the cookbook a short name. Use up to 10 tags per list and times between 0 and 1,440 minutes."
            case .contradictoryTags: "A tag cannot be both required and excluded. Remove it from one list."
            case .collectionFull: "Keep up to 50 smart cookbooks with short rules. Remove an unused cookbook or shorten its filters first."
            }
        }
    }
}

nonisolated struct SmartCookbookRecord: Sendable {
    var id: UUID
    var title: String
    var searchText: String
    var cuisines: Set<String>
    var categories: Set<String>
    var tags: Set<String>
    var prepMinutes: Int?
    var cookMinutes: Int?
    var isFavorite: Bool
    var dateCreated: Date
}

nonisolated struct SmartCookbookMatches: Sendable {
    var ids: [UUID] = []
    var total = 0
    var unknownTimeExcluded = 0
}

nonisolated enum SmartCookbookQuery {
    static let maximumVisible = 240
    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func matchesMetadata(_ record: SmartCookbookRecord, rule: SmartCookbookRule) -> Bool {
        Prepared(rule).matches(record)
    }

    private struct Prepared {
        var text: String, cuisine: String, category: String
        var required: Set<String>, excluded: Set<String>
        var favoritesOnly: Bool
        init(_ rule: SmartCookbookRule) {
            text = normalize(rule.text); cuisine = normalize(rule.cuisine); category = normalize(rule.category)
            required = Set(rule.requiredTags.map(normalize)); excluded = Set(rule.excludedTags.map(normalize))
            favoritesOnly = rule.favoritesOnly
        }
        func matches(_ record: SmartCookbookRecord) -> Bool {
            (!favoritesOnly || record.isFavorite)
                && (text.isEmpty || record.searchText.contains(text))
                && (cuisine.isEmpty || record.cuisines.contains(cuisine))
                && (category.isEmpty || record.categories.contains(category))
                && required.isSubset(of: record.tags) && excluded.isDisjoint(with: record.tags)
        }
    }

    static func scan<S: Sequence>(_ records: S, rule: SmartCookbookRule, limit: Int = 60) throws -> SmartCookbookMatches where S.Element == SmartCookbookRecord {
        let cap = min(max(1, limit), maximumVisible)
        let prepared = Prepared(rule)
        var result = SmartCookbookMatches()
        var retained: [SmartCookbookRecord] = []
        for record in records {
            try Task.checkCancellation()
            guard prepared.matches(record) else { continue }
            if let maximum = rule.maxPrepMinutes, let time = record.prepMinutes, time > maximum { continue }
            if let maximum = rule.maxCookMinutes, let time = record.cookMinutes, time > maximum { continue }
            if (rule.maxPrepMinutes != nil && record.prepMinutes == nil) || (rule.maxCookMinutes != nil && record.cookMinutes == nil) {
                result.unknownTimeExcluded += 1; continue
            }
            result.total += 1
            // Maintain just the visible result window; never sort or retain the entire catalogue.
            if retained.count < cap || comesBefore(record, retained[retained.count - 1], order: rule.order) {
                var low = 0, high = retained.count
                while low < high {
                    let middle = (low + high) / 2
                    if comesBefore(record, retained[middle], order: rule.order) { high = middle } else { low = middle + 1 }
                }
                retained.insert(record, at: low)
                if retained.count > cap { retained.removeLast() }
            }
        }
        result.ids = retained.map(\.id)
        return result
    }

    private static func comesBefore(_ lhs: SmartCookbookRecord, _ rhs: SmartCookbookRecord, order: SmartCookbookRule.Order) -> Bool {
        switch order {
        case .newest:
            if lhs.dateCreated != rhs.dateCreated { return lhs.dateCreated > rhs.dateCreated }
        case .shortestCookTime:
            if lhs.cookMinutes != rhs.cookMinutes { return (lhs.cookMinutes ?? Int.max) < (rhs.cookMinutes ?? Int.max) }
        case .name: break
        }
        let left = normalize(lhs.title), right = normalize(rhs.title)
        return left == right ? lhs.id.uuidString < rhs.id.uuidString : left < right
    }
}
