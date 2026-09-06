// Native check: swiftc Stocked/MealPlanExchange.swift Stocked/UnitConverter.swift scripts/FreeKitchenChecks.swift -o <temporary executable>
import Foundation

@main struct FreeKitchenChecks {
    static func main() throws {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            count += 1; precondition(condition(), label)
        }
        check(UnitConverter.density(for: "mystery powder") == nil, "Unknown ingredients do not become water")
        check(UnitConverter.density(for: "almond flour") == nil, "Do not substitute densities by substring")
        check(UnitConverter.density(for: "cooked rice") == nil, "Preparation changes density")
        check(UnitConverter.density(for: "  ALL-PURPOSE  FLOUR ") == 0.53, "Normalize whitespace and case")
        check(UnitConverter.cupsToGrams(1, ingredient: "flour")! < 130, "Flour density conversion")
        check(UnitConverter.cupsToGrams(.infinity, ingredient: "water") == nil, "Reject infinite measure")
        check(UnitConverter.gramsToCups(-1, ingredient: "water") == nil, "Reject negative measure")
        check(UnitConverter.convert(amount: 1, unit: "cup", ingredient: "mystery", to: .metric).unit == "ml", "Same-family conversion needs no density")
        check(UnitConverter.formatAmount(1.0e100) != nil, "Huge finite imported numbers format without an integer trap")
        check(UnitConverter.formatAmount(.infinity) == nil, "Infinite results are not rendered as valid conversions")
        check(UnitConverter.formatAmount(12.5) == "12.5", "Normal fractional amounts remain readable")
        let oversizedConversion = UnitConverter.convert(amount: 1.0e308, unit: "cup", ingredient: "water", to: .metric)
        check(oversizedConversion.unit == "cup" && oversizedConversion.value.isFinite, "Overflow preserves the original amount and unit")
        let id = UUID(uuidString: "12345678-1234-1234-1234-123456789012")!
        let entry = MealPlanExchange.Entry(id: id, day: 1, title: "Soup, beans; café\nBEGIN:VEVENT", mealType: "Dinner", servings: 2)
        let zone = TimeZone(identifier: "America/Chicago")!
        let date = ISO8601DateFormatter().date(from: "2026-03-07T18:00:00Z")!
        let text = try MealPlanExchange.calendar([entry], starting: date, generated: date, timeZone: zone)
        check(text.contains("DTSTART;VALUE=DATE:20260308\r\n"), "DST date is correct")
        check(text.contains("DTEND;VALUE=DATE:20260309\r\n"), "All-day event ends next calendar day")
        check(text.contains("Soup\\, beans\\; café\\nBEGIN:VEVENT"), "Escape untrusted text without event injection")
        check(text.components(separatedBy: "\r\nBEGIN:VEVENT\r\n").count == 2, "Exactly one event")
        check(text.contains("CLASS:PRIVATE"), "Calendar privacy")
        let control = MealPlanExchange.Entry(id: id, day: 1, title: "Soup\u{0}\u{7f}\u{1b}", mealType: "Dinner", servings: 2)
        let sanitized = try MealPlanExchange.calendar([control], starting: date)
        check(!sanitized.contains("\u{0}") && !sanitized.contains("\u{7f}") && !sanitized.contains("\u{1b}"), "Calendar removes forbidden control characters")
        let replay = try MealPlanExchange.calendar([entry], starting: date, generated: date, timeZone: zone)
        check(text == replay, "Replay retains UID")
        let unicode = "SUMMARY:" + String(repeating: "👨‍🍳é", count: 40)
        let folded = MealPlanExchange.fold(unicode)
        check(folded.components(separatedBy: "\r\n").allSatisfy { $0.utf8.count <= 75 }, "UTF8 lines obey octet limit")
        check(folded.replacingOccurrences(of: "\r\n ", with: "") == unicode, "Folding preserves Unicode exactly")
        check(MealPlanExchange.duplicateKey(day: 2, title: " SOUP  Beans ", type: "Dinner") == MealPlanExchange.duplicateKey(day: 2, title: "soup beans", type: "dinner"), "Repeated meals deduplicate")
        check(MealPlanExchange.duplicateKey(day: 2, title: "Soup", type: "Lunch") != MealPlanExchange.duplicateKey(day: 2, title: "Soup", type: "Dinner"), "Different slots stay separate")
        do {
            _ = try MealPlanExchange.calendar(Array(repeating: entry, count: 201), starting: date)
            preconditionFailure("Oversized exports must fail visibly")
        } catch MealPlanExchange.Failure.tooLarge { count += 1 }
        do {
            let invalid = MealPlanExchange.Entry(id: id, day: -1, title: "Soup", mealType: "Lunch", servings: 1)
            _ = try MealPlanExchange.calendar([invalid], starting: date)
            preconditionFailure("Invalid day must not shift events")
        } catch MealPlanExchange.Failure.invalidDay { count += 1 }
        do {
            _ = try MealPlanExchange.calendar([entry, entry], starting: date)
            preconditionFailure("Duplicate event identifiers must not create conflicting calendar entries")
        } catch MealPlanExchange.Failure.duplicateEvent { count += 1 }
        print("\(count) free kitchen checks passed")
    }
}
