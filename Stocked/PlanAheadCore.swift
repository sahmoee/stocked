import Foundation
import CryptoKit

/// Dated planning is kept outside the legacy relative-day cooking workspace.
/// These records have no inventory, grocery, cooking or network side effects.
nonisolated struct ScheduledMeal: HouseholdSyncable, Equatable {
    var id = UUID()
    var civilDate: String
    var timeZoneID: String
    var title: String
    var mealType: String
    var servings: Int
    var ingredients: [String]
    var recipeID: UUID? = nil
    var ruleID: UUID? = nil
    var templateEntryID: UUID? = nil
    var isSkipped = false
    var movedToWeek = false
    var updatedAt: Double = 0
    var lastWriterID = ""
}

nonisolated struct MealPlanTemplateEntry: Codable, Identifiable, Sendable, Equatable {
    var id = UUID()
    var dayOffset: Int
    var title: String
    var mealType: String
    var servings: Int
    var ingredients: [String]
    var recipeID: UUID? = nil
}

nonisolated struct MealPlanTemplate: HouseholdSyncable, Equatable {
    var id = UUID()
    var name: String
    var entries: [MealPlanTemplateEntry]
    var updatedAt: Double = 0
    var lastWriterID = ""
}

nonisolated struct MealPlanRule: HouseholdSyncable, Equatable {
    var id = UUID()
    var name: String
    var templateID: UUID
    var startDate: String
    var timeZoneID: String
    var intervalWeeks: Int
    var occurrences: Int
    var isPaused = false
    var updatedAt: Double = 0
    var lastWriterID = ""
}

// Keep memberwise initializers available, while tolerating absent additive metadata.
// Required identity/content fields still fail decoding rather than inventing data.
extension ScheduledMeal {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        civilDate = try c.decode(String.self, forKey: .civilDate)
        timeZoneID = try c.decode(String.self, forKey: .timeZoneID)
        title = try c.decode(String.self, forKey: .title)
        mealType = try c.decode(String.self, forKey: .mealType)
        servings = try c.decode(Int.self, forKey: .servings)
        ingredients = try c.decode([String].self, forKey: .ingredients)
        recipeID = try c.decodeIfPresent(UUID.self, forKey: .recipeID)
        ruleID = try c.decodeIfPresent(UUID.self, forKey: .ruleID)
        templateEntryID = try c.decodeIfPresent(UUID.self, forKey: .templateEntryID)
        isSkipped = try c.decodeIfPresent(Bool.self, forKey: .isSkipped) ?? false
        movedToWeek = try c.decodeIfPresent(Bool.self, forKey: .movedToWeek) ?? false
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        lastWriterID = try c.decodeIfPresent(String.self, forKey: .lastWriterID) ?? ""
    }
}

extension MealPlanTemplate {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        entries = try c.decode([MealPlanTemplateEntry].self, forKey: .entries)
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        lastWriterID = try c.decodeIfPresent(String.self, forKey: .lastWriterID) ?? ""
    }
}

extension MealPlanRule {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        templateID = try c.decode(UUID.self, forKey: .templateID)
        startDate = try c.decode(String.self, forKey: .startDate)
        timeZoneID = try c.decode(String.self, forKey: .timeZoneID)
        intervalWeeks = try c.decode(Int.self, forKey: .intervalWeeks)
        occurrences = try c.decode(Int.self, forKey: .occurrences)
        isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused) ?? false
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? 0
        lastWriterID = try c.decodeIfPresent(String.self, forKey: .lastWriterID) ?? ""
    }
}

nonisolated struct PlanActivationProposal: Identifiable, Sendable, Equatable {
    var id: UUID { occurrenceID }
    let occurrenceID: UUID
    let activeMealID: UUID
    let civilDate: String
    let timeZoneID: String
    let dayOffset: Int
    let title: String
    let mealType: String
    let servings: Int
    let ingredients: [String]
    let recipeID: UUID?
}

nonisolated enum PlanAheadCore {
    static let maximumTemplateEntries = 21
    static let maximumIngredients = 100
    static let maximumLineCharacters = 500
    static let maximumEncodedBytes = 48 * 1024
    static let maximumExpandedMeals = 252

    enum Failure: LocalizedError, Equatable {
        case invalidDate, invalidTimeZone, invalidText(String), invalidServings
        case invalidDayOffset, invalidRepeat, tooManyEntries, tooManyIngredients
        case tooLarge, duplicateIdentity, wrongTemplate, invalidMetadata
        var errorDescription: String? {
            switch self {
            case .invalidDate: "Choose a real calendar date in YYYY-MM-DD format."
            case .invalidTimeZone: "Choose a recognized time zone for this plan."
            case .invalidText(let field): "\(field) must be one nonempty line, within its length limit."
            case .invalidServings: "Choose between 1 and 100 servings."
            case .invalidDayOffset: "Template meals must be within its seven days."
            case .invalidRepeat: "Repeat every 1 to 4 weeks, up to 12 times within one year."
            case .tooManyEntries: "A template needs 1 to 21 meals."
            case .tooManyIngredients: "Use up to 100 ingredient lines for each meal."
            case .tooLarge: "This plan contains too much text. Reduce it before saving."
            case .duplicateIdentity: "The plan contains duplicate entries. Review it before continuing."
            case .wrongTemplate: "The selected repeat rule belongs to a different template."
            case .invalidMetadata: "This plan has invalid edit information."
            }
        }
    }

    static func validate(_ meal: ScheduledMeal) throws {
        _ = try parseDate(meal.civilDate, timeZoneID: meal.timeZoneID)
        try validateContent(title: meal.title, type: meal.mealType,
                            servings: meal.servings, ingredients: meal.ingredients)
        try validateMetadata(meal.updatedAt, meal.lastWriterID)
        try validateSize(meal)
    }

    static func validate(_ entry: MealPlanTemplateEntry) throws {
        guard (0..<7).contains(entry.dayOffset) else { throw Failure.invalidDayOffset }
        try validateContent(title: entry.title, type: entry.mealType,
                            servings: entry.servings, ingredients: entry.ingredients)
        try validateSize(entry)
    }

    static func validate(_ template: MealPlanTemplate) throws {
        try line(template.name, field: "Template name", maximum: 100)
        guard (1...maximumTemplateEntries).contains(template.entries.count) else { throw Failure.tooManyEntries }
        guard Set(template.entries.map(\.id)).count == template.entries.count else { throw Failure.duplicateIdentity }
        for entry in template.entries { try validate(entry) }
        try validateMetadata(template.updatedAt, template.lastWriterID)
        try validateSize(template)
    }

    static func validate(_ rule: MealPlanRule) throws {
        try line(rule.name, field: "Repeat name", maximum: 100)
        _ = try parseDate(rule.startDate, timeZoneID: rule.timeZoneID)
        guard (1...4).contains(rule.intervalWeeks), (1...12).contains(rule.occurrences) else {
            throw Failure.invalidRepeat
        }
        try validateMetadata(rule.updatedAt, rule.lastWriterID)
        try validateSize(rule)
    }

    /// Returns local noon on the named civil date. Round-trip component checks reject
    /// impossible dates (including an entire day skipped by a time-zone transition).
    static func parseDate(_ civilDate: String, timeZoneID: String) throws -> Date {
        let bytes = Array(civilDate.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45,
              bytes.enumerated().allSatisfy({ [4, 7].contains($0.offset) || (48...57).contains($0.element) }),
              let year = Int(civilDate.prefix(4)), (1...9999).contains(year),
              let month = Int(civilDate.dropFirst(5).prefix(2)), (1...12).contains(month),
              let day = Int(civilDate.suffix(2)), (1...31).contains(day) else { throw Failure.invalidDate }
        let calendar = try calendar(timeZoneID)
        let parts = DateComponents(calendar: calendar, timeZone: calendar.timeZone,
                                   era: 1, year: year, month: month, day: day, hour: 12)
        guard let date = calendar.date(from: parts) else { throw Failure.invalidDate }
        let actual = calendar.dateComponents([.era, .year, .month, .day], from: date)
        guard actual.era == 1, actual.year == year, actual.month == month, actual.day == day else {
            throw Failure.invalidDate
        }
        return date
    }

    static func dateKey(for date: Date, timeZoneID: String) throws -> String {
        guard date.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidDate }
        let parts = try calendar(timeZoneID).dateComponents([.era, .year, .month, .day], from: date)
        guard parts.era == 1, let year = parts.year, (1...9999).contains(year),
              let month = parts.month, let day = parts.day else { throw Failure.invalidDate }
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Returns only new occurrences. Known IDs are never overwritten, including skipped,
    /// moved, edited, or differently titled copies from an earlier template revision.
    static func expand(rule: MealPlanRule, template: MealPlanTemplate,
                       existing: [ScheduledMeal] = []) throws -> [ScheduledMeal] {
        try validate(rule)
        try validate(template)
        guard rule.templateID == template.id else { throw Failure.wrongTemplate }
        for meal in existing { try validate(meal) }
        guard !rule.isPaused else { return [] }
        let calendar = try calendar(rule.timeZoneID)
        let start = try parseDate(rule.startDate, timeZoneID: rule.timeZoneID)
        guard let end = calendar.date(byAdding: .year, value: 1, to: start) else { throw Failure.invalidRepeat }
        var known = Set(existing.map(\.id))
        var additions: [ScheduledMeal] = []
        for repeatIndex in 0..<rule.occurrences {
            for entry in template.entries {
                let offset = repeatIndex * rule.intervalWeeks * 7 + entry.dayOffset
                guard let date = calendar.date(byAdding: .day, value: offset, to: start), date < end else {
                    throw Failure.invalidRepeat
                }
                let key = try dateKey(for: date, timeZoneID: rule.timeZoneID)
                let id = occurrenceID(ruleID: rule.id, templateEntryID: entry.id, civilDate: key)
                guard known.insert(id).inserted else { continue }
                let meal = ScheduledMeal(id: id, civilDate: key, timeZoneID: rule.timeZoneID,
                                         title: entry.title, mealType: entry.mealType,
                                         servings: entry.servings, ingredients: entry.ingredients,
                                         recipeID: entry.recipeID, ruleID: rule.id, templateEntryID: entry.id)
                try validate(meal)
                additions.append(meal)
                guard additions.count <= maximumExpandedMeals else { throw Failure.tooLarge }
            }
        }
        return additions.sorted(by: ordered)
    }

    /// Review proposals only: the caller must recheck current state/permissions and
    /// commit through the existing plannedMeals owner. No old or distant date is clamped.
    static func activationProposals(from meals: [ScheduledMeal], now: Date = Date()) throws -> [PlanActivationProposal] {
        guard now.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalidDate }
        guard Set(meals.map(\.id)).count == meals.count else { throw Failure.duplicateIdentity }
        var result: [PlanActivationProposal] = []
        for meal in meals.sorted(by: ordered) {
            try validate(meal)
            guard !meal.isSkipped, !meal.movedToWeek else { continue }
            let calendar = try calendar(meal.timeZoneID)
            let date = try parseDate(meal.civilDate, timeZoneID: meal.timeZoneID)
            guard let offset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                                      to: calendar.startOfDay(for: date)).day,
                  (0..<7).contains(offset) else { continue }
            result.append(PlanActivationProposal(occurrenceID: meal.id, activeMealID: activeMealID(for: meal.id),
                                                  civilDate: meal.civilDate, timeZoneID: meal.timeZoneID,
                                                  dayOffset: offset, title: meal.title, mealType: meal.mealType,
                                                  servings: meal.servings, ingredients: meal.ingredients,
                                                  recipeID: meal.recipeID))
        }
        return result
    }

    static func occurrenceID(ruleID: UUID, templateEntryID: UUID, civilDate: String) -> UUID {
        stableUUID("stocked.plan-occurrence.v1", [ruleID.uuidString.lowercased(),
                                                templateEntryID.uuidString.lowercased(), civilDate])
    }

    static func activeMealID(for occurrenceID: UUID) -> UUID {
        stableUUID("stocked.plan-active-copy.v1", [occurrenceID.uuidString.lowercased()])
    }

    private static func stableUUID(_ namespace: String, _ values: [String]) -> UUID {
        let payload = ([namespace] + values).map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(payload.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80 // UUID custom-format version, SHA-256-derived.
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func calendar(_ timeZoneID: String) throws -> Calendar {
        guard !timeZoneID.isEmpty, timeZoneID.utf8.count <= 100,
              let zone = TimeZone(identifier: timeZoneID) else { throw Failure.invalidTimeZone }
        var result = Calendar(identifier: .gregorian)
        result.locale = Locale(identifier: "en_US_POSIX")
        result.timeZone = zone
        return result
    }

    private static func validateContent(title: String, type: String, servings: Int, ingredients: [String]) throws {
        try line(title, field: "Meal title", maximum: maximumLineCharacters)
        try line(type, field: "Meal type", maximum: 40)
        guard (1...100).contains(servings) else { throw Failure.invalidServings }
        guard ingredients.count <= maximumIngredients else { throw Failure.tooManyIngredients }
        for ingredient in ingredients { try line(ingredient, field: "Ingredient", maximum: maximumLineCharacters) }
    }

    private static func line(_ value: String, field: String, maximum: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.count <= maximum,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0)
                  || CharacterSet.newlines.contains($0) }) else { throw Failure.invalidText(field) }
    }

    private static func validateMetadata(_ updatedAt: Double, _ writer: String) throws {
        guard updatedAt.isFinite, updatedAt >= 0, writer.utf8.count <= 200,
              !writer.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw Failure.invalidMetadata
        }
    }

    private static func validateSize<T: Encodable>(_ value: T) throws {
        guard try JSONEncoder().encode(value).count <= maximumEncodedBytes else { throw Failure.tooLarge }
    }

    private static func ordered(_ lhs: ScheduledMeal, _ rhs: ScheduledMeal) -> Bool {
        if lhs.civilDate != rhs.civilDate { return lhs.civilDate < rhs.civilDate }
        if lhs.mealType != rhs.mealType { return lhs.mealType < rhs.mealType }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
