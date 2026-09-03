import Foundation

/// Generation-gated loading state: cancelled or older queries cannot replace newer results.
nonisolated struct FinderRequestState: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case idle, loading, ready, failed }
    private(set) var phase: Phase = .idle
    private(set) var count = 0
    private var generation = 0
    mutating func begin() -> Int { generation &+= 1; phase = .loading; return generation }
    mutating func complete(_ token: Int, count: Int) -> Bool {
        guard token == generation, phase == .loading else { return false }
        self.count = count; phase = .ready; return true
    }
    mutating func fail(_ token: Int) -> Bool {
        guard token == generation, phase == .loading else { return false }
        phase = .failed; return true
    }
    mutating func cancel() { generation &+= 1; phase = .idle }
}

nonisolated enum FinderDuration {
    private static let expression = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|s)"#)
    static func minutes(_ value: String) -> Int? {
        let text = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !text.contains("-"), !text.contains("–") else { return nil }
        guard !text.contains("includ"), !(text.hasPrefix("p") && !text.contains("t") && text.contains("m")) else { return nil }
        if let n = Int(text), n >= 0 { return n }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return nil }
        var seconds: Double = 0
        for match in matches {
            guard let nr = Range(match.range(at: 1), in: text), let ur = Range(match.range(at: 2), in: text), let n = Double(text[nr]), n < 1_000_000 else { return nil }
            let unit = text[ur]
            seconds += n * (unit.hasPrefix("d") ? 86400 : unit.hasPrefix("h") ? 3600 : unit.hasPrefix("s") ? 1 : 60)
        }
        let remainder = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        guard !remainder.contains(where: \.isNumber) else { return nil }
        return Int(ceil(seconds / 60))
    }
}

/// Pure quantity accounting, separate from food aliases and unit conversion adapters.
nonisolated enum FinderQuantityPool {
    struct Stock: Sendable { var family: String; var amount: Double }
    struct Need: Sendable { var family: String?; var amount: Double?; var matchingStock: [Int] }
    static func coverage(stock: [Stock], needs: [Need]) -> (required: Int, have: Int, uncertain: Int) {
        var remaining = stock.map { max(0, $0.amount) }, have = 0, uncertain = 0
        for need in needs {
            let candidates = need.matchingStock.filter { stock.indices.contains($0) && remaining[$0] > 0 }
            guard !candidates.isEmpty else { continue }
            guard let amount = need.amount, amount > 0, let family = need.family else { have += 1; uncertain += 1; continue }
            let compatible = candidates.filter { stock[$0].family == family }
            guard !compatible.isEmpty else { have += 1; uncertain += 1; continue }
            var required = amount
            for index in compatible { let used = min(remaining[index], required); remaining[index] -= used; required -= used }
            if required <= 0.0001 { have += 1 }
        }
        return (needs.count, have, uncertain)
    }
}

// Pure, platform-independent state/query contract. AND between categories, OR within
// categories, AND for dietary requirements. Discovery signals affect ranking only.
nonisolated enum FinderCategory: String, CaseIterable, Codable, Sendable, Identifiable {
    case meal, ingredient, cuisine, diet, mood, time, kitchen
    var id: String { rawValue }
    var title: String { switch self {
    case .meal: "Meal"; case .ingredient: "Main ingredient"; case .cuisine: "Cuisine"
    case .diet: "Dietary"; case .mood: "Mood"; case .time: "Time"; case .kitchen: "Kitchen"
    } }
    var question: String { switch self {
    case .meal: "What kind of meal are you making?"
    case .ingredient: "What do you want to cook with?"
    case .cuisine: "What flavors are you in the mood for?"
    case .diet: "Any dietary preferences?"
    case .mood: "What sounds good right now?"
    case .time: "How much time do you have?"
    case .kitchen: "Should we use what you have?"
    } }
    var instruction: String { switch self {
    case .meal: "Choose one or more. You can skip anything you don’t care about."
    case .ingredient: "Pick as many as you’d like."
    case .cuisine: "Choose any cuisines that sound good."
    case .diet: "We’ll only show recipes with matching dietary metadata."
    case .mood: "Choose the feeling or cooking style you want."
    case .time: "We’ll use the recipe’s total time."
    case .kitchen: "Match recipes against your Stocked inventory."
    } }
    var icon: String { switch self {
    case .meal: "fork.knife"; case .ingredient: "carrot"; case .cuisine: "globe"
    case .diet: "leaf"; case .mood: "heart"; case .time: "clock"; case .kitchen: "refrigerator"
    } }
    var options: [FinderChoice] { switch self {
    case .meal: [.breakfast, .brunch, .lunch, .dinner, .snack, .appetizer, .sideDish, .dessert, .drink]
    case .ingredient: [.chicken, .beef, .pork, .turkey, .seafood, .fish, .shrimp, .pasta, .rice, .vegetables, .beans, .eggs, .tofu, .noPreference]
    case .cuisine: [.african, .american, .cajun, .caribbean, .chinese, .french, .greek, .indian, .italian, .jamaican, .japanese, .korean, .latin, .mediterranean, .mexican, .middleEastern, .southern, .thai, .vietnamese, .somethingNew, .noPreference]
    case .diet: [.vegetarian, .vegan, .pescatarian, .noRestrictions]
    case .mood: [.quick, .comfort, .healthy, .lightFresh, .hearty, .onePot, .slowCooker, .airFryer, .grilled, .baked, .noCook, .familyFriendly, .mealPrep, .somethingNew, .surpriseMe]
    case .time: [.under15, .under30, .under45, .under60, .over60, .noTimeLimit]
    case .kitchen: [.useWhatIHave, .mostlyHave, .canShop, .noPreference]
    } }
}

nonisolated enum FinderChoice: String, Codable, Sendable, CaseIterable, Identifiable {
    case breakfast, brunch, lunch, dinner, snack, appetizer, sideDish, dessert, drink
    case chicken, beef, pork, turkey, seafood, fish, shrimp, pasta, rice, vegetables, beans, eggs, tofu
    case african, american, cajun, caribbean, chinese, french, greek, indian, italian, jamaican, japanese, korean, latin, mediterranean, mexican, middleEastern, southern, thai, vietnamese
    case vegetarian, vegan, pescatarian
    case quick, comfort, healthy, lightFresh, hearty, onePot, slowCooker, airFryer, grilled, baked, noCook, familyFriendly, mealPrep, somethingNew, surpriseMe
    case under15, under30, under45, under60, over60, noTimeLimit
    case useWhatIHave, mostlyHave, canShop, noPreference, noRestrictions
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sideDish: "Side Dish"; case .cajun: "Cajun & Creole"; case .middleEastern: "Middle Eastern"
        case .lightFresh: "Light & Fresh"; case .onePot: "One Pot"; case .slowCooker: "Slow Cooker"
        case .airFryer: "Air Fryer"; case .noCook: "No-Cook"; case .familyFriendly: "Family-Friendly"
        case .mealPrep: "Meal Prep"; case .somethingNew: "Something New"; case .surpriseMe: "Surprise Me"
        case .under15: "Under 15 min"; case .under30: "Under 30 min"; case .under45: "Under 45 min"
        case .under60: "Under 1 hour"; case .over60: "1 hour or more"; case .noTimeLimit: "No time limit"
        case .useWhatIHave: "Use what I have"; case .mostlyHave: "Mostly use what I have"
        case .canShop: "I can shop for ingredients"; case .noPreference: "No preference"
        case .noRestrictions: "No restrictions"
        default: rawValue.prefix(1).uppercased() + rawValue.dropFirst()
        }
    }
    var isNeutral: Bool { [.noPreference, .noRestrictions, .noTimeLimit, .canShop].contains(self) }
    var isDiscovery: Bool { self == .somethingNew || self == .surpriseMe }
    var icon: String { switch self {
    case .breakfast, .brunch: "sunrise"; case .lunch: "takeoutbag.and.cup.and.straw"
    case .dinner: "fork.knife"; case .snack: "carrot"; case .appetizer: "leaf"
    case .sideDish: "bowl"; case .dessert: "birthday.cake"; case .drink: "cup.and.saucer"
    default: "checkmark"
    } }
}

nonisolated enum FinderSort: String, CaseIterable, Codable, Sendable, Identifiable {
    case bestMatch, readyToCook, fastest, highestRated, recentlyAdded, recentlyCooked, mostCooked, az, za
    var id: String { rawValue }
    var label: String { switch self {
    case .bestMatch: "Best match"; case .readyToCook: "Ready to cook"; case .fastest: "Fastest"
    case .highestRated: "Highest rated"; case .recentlyAdded: "Recently added"
    case .recentlyCooked: "Recently cooked"; case .mostCooked: "Most cooked"; case .az: "A–Z"; case .za: "Z–A"
    } }
}

nonisolated struct FinderFilters: Equatable, Sendable, Codable {
    var query = ""
    var selections: [FinderCategory: Set<FinderChoice>] = [:]
    var sort: FinderSort = .bestMatch
    subscript(_ category: FinderCategory) -> Set<FinderChoice> {
        get { selections[category, default: []] }
        set { selections[category] = newValue }
    }
    var hasChoices: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selections.values.contains { !$0.isEmpty } }
    var usesInventory: Bool { self[.kitchen].contains(.useWhatIHave) || self[.kitchen].contains(.mostlyHave) || sort == .readyToCook }
    mutating func toggle(_ choice: FinderChoice, in category: FinderCategory) {
        guard category.options.contains(choice) else { return }
        if self[category].contains(choice) { self[category].remove(choice); return }
        if category == .time || category == .kitchen || choice.isNeutral || choice == .surpriseMe {
            self[category] = [choice]
        } else {
            self[category] = self[category].filter { !$0.isNeutral && $0 != .surpriseMe }
            self[category].insert(choice)
        }
    }
    mutating func remove(_ choice: FinderChoice, in category: FinderCategory) { self[category].remove(choice) }
    func active(_ category: FinderCategory) -> Set<FinderChoice> { self[category].filter { !$0.isNeutral } }
}

nonisolated struct FinderFlow: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case quiz(Int), review, results }
    var filters = FinderFilters()
    var phase: Phase = .quiz(0)
    var enteredBySearch = false
    var editingReview = false
    var needsClearConfirmation = false
    mutating func start(search: Bool) { enteredBySearch = search; if search { phase = .results } }
    mutating func next(skip: Bool = false) {
        guard case .quiz(let index) = phase else { return }
        if skip { filters[FinderCategory.allCases[index]] = [] }
        if editingReview { editingReview = false; phase = .review }
        else { phase = index == 6 ? .review : .quiz(index + 1) }
    }
    mutating func edit(_ category: FinderCategory) {
        editingReview = true
        phase = .quiz(FinderCategory.allCases.firstIndex(of: category)!)
    }
    /// True means the host should pop back to the Recipe Hub. Draft remains intact.
    mutating func back() -> Bool {
        if editingReview { editingReview = false; phase = .review; return false }
        switch phase {
        case .quiz(let index): if index == 0 { return true }; phase = .quiz(index - 1)
        case .review: phase = .quiz(6)
        case .results: if enteredBySearch { return true }; phase = .review
        }
        return false
    }
    mutating func requestClear() {
        if filters.hasChoices { needsClearConfirmation = true } else { clear() }
    }
    mutating func clear() { self = FinderFlow() }
}

nonisolated struct FinderRecord: Identifiable, Sendable {
    var id: String
    var title: String
    var searchText: String
    var sortTitle: String = ""
    var facets: [FinderCategory: Set<FinderChoice>] = [:]
    var totalMinutes: Int?
    var rating: Double?
    var ratingCount: Int?
    var addedAt: Date?
    var lastCooked: Date?
    var cookCount = 0
    var cuisineCookCount = 0
    var required = 0
    var have = 0
    var uncertain = 0
    var hasAllergenConflict = false
    var missing: Int { max(0, required - have) }
    var ready: Bool { required > 0 && missing == 0 && uncertain == 0 }
}

nonisolated enum FinderQuery {
    static func normalize(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
    static func acceptsTime(_ minutes: Int?, selection: FinderChoice?) -> Bool {
        guard let selection, selection != .noTimeLimit else { return true }
        guard let minutes, minutes >= 0 else { return false }
        switch selection {
        case .under15: return minutes <= 15
        case .under30: return minutes <= 30
        case .under45: return minutes <= 45
        case .under60: return minutes <= 60
        case .over60: return minutes > 60
        default: return true
        }
    }
    static func matches(_ row: FinderRecord, filters: FinderFilters) -> Bool {
        guard !row.hasAllergenConflict else { return false }
        let words = normalize(filters.query).split(whereSeparator: \.isWhitespace)
        guard words.allSatisfy({ row.searchText.contains($0) }) else { return false }
        for category in [FinderCategory.meal, .ingredient, .cuisine, .mood] {
            var choices = filters.active(category).filter { !$0.isDiscovery }
            if category == .mood, choices.remove(.quick) != nil {
                // Quick is one of the OR choices, always based on TOTAL time.
                if let time = row.totalMinutes, time <= 30 { continue }
                if choices.isEmpty { return false }
            }
            if !choices.isEmpty && choices.isDisjoint(with: row.facets[category, default: []]) { return false }
        }
        guard filters.active(.diet).isSubset(of: row.facets[.diet, default: []]) else { return false }
        guard acceptsTime(row.totalMinutes, selection: filters[.time].first) else { return false }
        if filters[.kitchen].contains(.useWhatIHave), !row.ready { return false }
        if filters[.kitchen].contains(.mostlyHave) {
            guard row.required > 0, row.have * 100 >= row.required * 70 else { return false }
        }
        return true
    }
    static func stableVariety(_ id: String) -> UInt64 {
        id.utf8.reduce(UInt64(1469598103934665603)) { ($0 ^ UInt64($1)) &* 1099511628211 }
    }
    static func ordered(_ a: FinderRecord, before b: FinderRecord, filters: FinderFilters) -> Bool {
        switch filters.sort {
        case .readyToCook:
            if a.ready != b.ready { return a.ready }
            if (a.required == 0) != (b.required == 0) { return a.required > 0 }
            if a.missing != b.missing { return a.missing < b.missing }
            if a.uncertain != b.uncertain { return a.uncertain < b.uncertain }
        case .fastest:
            if a.totalMinutes != b.totalMinutes { return (a.totalMinutes ?? Int.max) < (b.totalMinutes ?? Int.max) }
        case .highestRated:
            if a.rating != b.rating { return (a.rating ?? -1) > (b.rating ?? -1) }
            if a.ratingCount != b.ratingCount { return (a.ratingCount ?? 0) > (b.ratingCount ?? 0) }
        case .recentlyAdded:
            if a.addedAt != b.addedAt { return (a.addedAt ?? .distantPast) > (b.addedAt ?? .distantPast) }
        case .recentlyCooked:
            if a.lastCooked != b.lastCooked { return (a.lastCooked ?? .distantPast) > (b.lastCooked ?? .distantPast) }
        case .mostCooked:
            if a.cookCount != b.cookCount { return a.cookCount > b.cookCount }
        case .bestMatch:
            if filters[.kitchen].contains(.mostlyHave), a.missing != b.missing { return a.missing < b.missing }
            if filters[.mood].contains(.somethingNew), a.cookCount != b.cookCount { return a.cookCount < b.cookCount }
            if filters[.cuisine].contains(.somethingNew), a.cuisineCookCount != b.cuisineCookCount { return a.cuisineCookCount < b.cuisineCookCount }
            if filters[.mood].contains(.surpriseMe) || filters[.mood].contains(.somethingNew) || filters[.cuisine].contains(.somethingNew) {
                let lhs = stableVariety(a.id), rhs = stableVariety(b.id)
                if lhs != rhs { return lhs < rhs }
            }
            let score: (FinderRecord) -> Int = { row in
                [FinderCategory.meal, .ingredient, .cuisine, .mood].reduce(0) {
                    $0 + filters.active($1).intersection(row.facets[$1, default: []]).count
                }
            }
            let lhs = score(a), rhs = score(b)
            if lhs != rhs { return lhs > rhs }
        case .az, .za: break
        }
        let lhs = a.sortTitle.isEmpty ? normalize(a.title) : a.sortTitle
        let rhs = b.sortTitle.isEmpty ? normalize(b.title) : b.sortTitle
        if lhs != rhs { return filters.sort == .za ? lhs > rhs : lhs < rhs }
        return a.id < b.id
    }
    static func results(_ rows: [FinderRecord], filters: FinderFilters) -> [FinderRecord] {
        rows.filter { matches($0, filters: filters) }.sorted { ordered($0, before: $1, filters: filters) }
    }
}
