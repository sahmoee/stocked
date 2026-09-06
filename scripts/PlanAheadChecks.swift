import Foundation

// Native-only boundary stub. Production models conform to FeatureHouseholdSync's protocol.
nonisolated protocol HouseholdSyncable: Codable, Identifiable, Sendable where ID == UUID {
    var updatedAt: Double { get set }
    var lastWriterID: String { get set }
}

@main
struct PlanAheadChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        checks += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) {
        do { try body(); fatalError("Expected rejection: \(message)") }
        catch { checks += 1 }
    }

    static func main() throws {
        let zone = "America/Chicago"
        let start = try PlanAheadCore.parseDate("2026-03-07", timeZoneID: zone)
        check(try PlanAheadCore.dateKey(for: start, timeZoneID: zone) == "2026-03-07", "Civil date round-trip")
        check(try PlanAheadCore.dateKey(for: PlanAheadCore.parseDate("2028-02-29", timeZoneID: zone), timeZoneID: zone) == "2028-02-29", "Leap day")
        for date in ["2026-02-29", "2026-04-31", "2026-00-01", "2026-13-01", "2026-01-00", "2026-1-01", "2026-01-01T12:00:00Z", " 2026-01-01", "0000-01-01", "２０２６-01-01"] {
            rejects("Invalid civil date \(date)") { _ = try PlanAheadCore.parseDate(date, timeZoneID: zone) }
        }
        rejects("Unknown timezone") { _ = try PlanAheadCore.parseDate("2026-01-01", timeZoneID: "not/a-zone") }
        rejects("Skipped civil day") { _ = try PlanAheadCore.parseDate("2011-12-30", timeZoneID: "Pacific/Apia") }
        rejects("Non-finite now") { _ = try PlanAheadCore.dateKey(for: Date(timeIntervalSinceReferenceDate: .infinity), timeZoneID: zone) }

        let entryID = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
        let recipeID = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
        let templateID = UUID(uuidString: "33333333-3333-4333-8333-333333333333")!
        let ruleID = UUID(uuidString: "44444444-4444-4444-8444-444444444444")!
        let entry = MealPlanTemplateEntry(id: entryID, dayOffset: 1, title: "Lentil soup", mealType: "Dinner",
                                          servings: 4, ingredients: ["2 cups lentils"], recipeID: recipeID)
        var template = MealPlanTemplate(id: templateID, name: "A simple week", entries: [entry])
        var rule = MealPlanRule(id: ruleID, name: "Sunday soup", templateID: templateID,
                               startDate: "2026-03-07", timeZoneID: zone, intervalWeeks: 1, occurrences: 3)
        let first = try PlanAheadCore.expand(rule: rule, template: template)
        check(first.map(\.civilDate) == ["2026-03-08", "2026-03-15", "2026-03-22"], "Weekly expansion crosses DST by civil date")
        check(first.allSatisfy { $0.recipeID == recipeID && $0.ruleID == ruleID && $0.templateEntryID == entryID }, "References retained")
        check(first.allSatisfy { !$0.isSkipped && !$0.movedToWeek && $0.updatedAt == 0 && $0.lastWriterID.isEmpty }, "Expansion has no completed/stamped state")
        check(try first == PlanAheadCore.expand(rule: rule, template: template), "Deterministic expansion")
        check(Set(first.map(\.id)).count == first.count, "Occurrence dates have distinct identities")
        check(first[0].id == PlanAheadCore.occurrenceID(ruleID: ruleID, templateEntryID: entryID, civilDate: "2026-03-08"), "ID contract")
        let copyID = PlanAheadCore.activeMealID(for: first[0].id)
        check(copyID != first[0].id && copyID == PlanAheadCore.activeMealID(for: first[0].id), "Active-copy identity is stable and separate")

        var edited = first[0]; edited.title = "A household edit"; edited.isSkipped = true
        var moved = first[1]; moved.movedToWeek = true
        template.entries[0].title = "New template title"
        let remaining = try PlanAheadCore.expand(rule: rule, template: template, existing: [edited, moved])
        check(remaining.count == 1 && remaining[0].id == first[2].id && remaining[0].title == "New template title", "Known edited/skipped/moved records are never replaced")
        check(edited.title == "A household edit" && edited.isSkipped && moved.movedToWeek, "Inputs stay unchanged")
        check(try PlanAheadCore.expand(rule: rule, template: template, existing: first).isEmpty, "Repeated preview is idempotent")
        rule.isPaused = true
        check(try PlanAheadCore.expand(rule: rule, template: template).isEmpty, "Paused rule adds nothing")
        rule.isPaused = false

        func meal(_ date: String) -> ScheduledMeal {
            ScheduledMeal(civilDate: date, timeZoneID: zone, title: "Soup", mealType: "Dinner", servings: 2, ingredients: [])
        }
        var skipped = meal("2026-03-09"); skipped.isSkipped = true
        var activated = meal("2026-03-10"); activated.movedToWeek = true
        let proposals = try PlanAheadCore.activationProposals(from: [meal("2026-03-06"), meal("2026-03-07"),
            meal("2026-03-08"), meal("2026-03-13"), meal("2026-03-14"), skipped, activated], now: start)
        check(proposals.map(\.dayOffset) == [0, 1, 6], "Only active-week dates, without clamping or skipped/moved rows")
        check(proposals.allSatisfy { $0.activeMealID == PlanAheadCore.activeMealID(for: $0.occurrenceID) }, "Activation identity")
        let fallNow = try PlanAheadCore.parseDate("2026-10-31", timeZoneID: zone)
        check(try PlanAheadCore.activationProposals(from: [meal("2026-11-01")], now: fallNow).first?.dayOffset == 1, "Fall DST uses calendar day rather than 24-hour division")
        let springTomorrow = try PlanAheadCore.parseDate("2026-03-08", timeZoneID: zone)
        check(springTomorrow.timeIntervalSince(start) == 23 * 3600, "Spring fixture actually spans a 23-hour day")
        let duplicate = meal("2026-03-08")
        rejects("Duplicate activation input") { _ = try PlanAheadCore.activationProposals(from: [duplicate, duplicate], now: start) }
        let utcNow = ISO8601DateFormatter().date(from: "2026-03-08T01:00:00Z")!
        check(try PlanAheadCore.dateKey(for: utcNow, timeZoneID: zone) == "2026-03-07", "Explicit timezone controls date, not current system setting")

        var invalidTemplate = template; invalidTemplate.entries = []
        rejects("Empty template") { try PlanAheadCore.validate(invalidTemplate) }
        invalidTemplate.entries = [entry, entry]
        rejects("Duplicate template entry") { try PlanAheadCore.validate(invalidTemplate) }
        invalidTemplate.entries = (0..<22).map { _ in var copy = entry; copy.id = UUID(); return copy }
        rejects("Template entry bound") { try PlanAheadCore.validate(invalidTemplate) }
        var invalidEntry = entry; invalidEntry.dayOffset = 7
        rejects("Template offset bound") { try PlanAheadCore.validate(invalidEntry) }
        invalidEntry = entry; invalidEntry.ingredients = Array(repeating: "salt", count: 101)
        rejects("Ingredient count bound") { try PlanAheadCore.validate(invalidEntry) }
        invalidEntry = entry; invalidEntry.title = String(repeating: "x", count: 501)
        rejects("Line bound") { try PlanAheadCore.validate(invalidEntry) }
        invalidEntry.title = "Title\nInjected line"
        rejects("Single line required") { try PlanAheadCore.validate(invalidEntry) }
        invalidEntry = entry; invalidEntry.servings = 0
        rejects("Serving bound") { try PlanAheadCore.validate(invalidEntry) }
        invalidEntry = entry; invalidEntry.ingredients = Array(repeating: String(repeating: "🥣", count: 500), count: 100)
        rejects("Encoded byte bound, including multibyte text") { try PlanAheadCore.validate(invalidEntry) }
        var corrupt = meal("2026-03-08"); corrupt.updatedAt = .nan
        rejects("Non-finite timestamp") { try PlanAheadCore.validate(corrupt) }
        var invalidRule = rule; invalidRule.intervalWeeks = 0
        rejects("Repeat interval lower bound") { try PlanAheadCore.validate(invalidRule) }
        invalidRule.intervalWeeks = 5
        rejects("Repeat interval upper bound") { try PlanAheadCore.validate(invalidRule) }
        invalidRule = rule; invalidRule.occurrences = 13
        rejects("Repeat count upper bound") { try PlanAheadCore.validate(invalidRule) }
        invalidRule = rule; invalidRule.templateID = UUID()
        rejects("Rule/template mismatch") { _ = try PlanAheadCore.expand(rule: invalidRule, template: template) }
        let maxEntries = (0..<21).map { index in
            MealPlanTemplateEntry(dayOffset: index % 7, title: "Meal \(index)", mealType: "Dinner", servings: 2, ingredients: [])
        }
        let maxTemplate = MealPlanTemplate(id: templateID, name: "Full week", entries: maxEntries)
        var maxRule = rule; maxRule.intervalWeeks = 4; maxRule.occurrences = 12
        let maxExpansion = try PlanAheadCore.expand(rule: maxRule, template: maxTemplate)
        check(maxExpansion.count == 252, "Maximum finite expansion is accepted in full")
        check(maxExpansion.last!.civilDate < "2027-03-07", "Maximum repeat ends within one year")

        let encoder = JSONEncoder(), decoder = JSONDecoder()
        let encoded = try encoder.encode(first[0])
        check(try decoder.decode(ScheduledMeal.self, from: encoded) == first[0], "Scheduled Codable round-trip")
        var wire = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in ["recipeID", "ruleID", "templateEntryID", "isSkipped", "movedToWeek", "updatedAt", "lastWriterID"] { wire.removeValue(forKey: key) }
        let legacy = try decoder.decode(ScheduledMeal.self, from: JSONSerialization.data(withJSONObject: wire))
        check(!legacy.isSkipped && !legacy.movedToWeek && legacy.recipeID == nil && legacy.updatedAt == 0 && legacy.lastWriterID.isEmpty, "Omitted additive meal metadata defaults safely")
        wire.removeValue(forKey: "civilDate")
        rejects("Missing core date isn't invented") { _ = try decoder.decode(ScheduledMeal.self, from: JSONSerialization.data(withJSONObject: wire)) }
        var ruleWire = try JSONSerialization.jsonObject(with: encoder.encode(rule)) as! [String: Any]
        for key in ["isPaused", "updatedAt", "lastWriterID"] { ruleWire.removeValue(forKey: key) }
        let decodedRule = try decoder.decode(MealPlanRule.self, from: JSONSerialization.data(withJSONObject: ruleWire))
        check(!decodedRule.isPaused && decodedRule.updatedAt == 0 && decodedRule.lastWriterID.isEmpty, "Omitted rule metadata defaults safely")
        var templateWire = try JSONSerialization.jsonObject(with: encoder.encode(template)) as! [String: Any]
        for key in ["updatedAt", "lastWriterID"] { templateWire.removeValue(forKey: key) }
        let decodedTemplate = try decoder.decode(MealPlanTemplate.self, from: JSONSerialization.data(withJSONObject: templateWire))
        check(decodedTemplate.updatedAt == 0 && decodedTemplate.lastWriterID.isEmpty, "Omitted template metadata defaults safely")
        print("PlanAheadCore: \(checks) checks passed (dates, DST, repeat limits, IDs, privacy-free projections, preservation, validation and Codable).")
    }
}
