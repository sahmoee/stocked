import Foundation

/// Original implementation of the RFC 5545 exchange format. No calendar access,
/// network request, ingredient data, or household identifiers are needed.
nonisolated enum MealPlanExchange {
    struct Entry: Sendable, Equatable {
        let id: UUID
        let day: Int
        let title: String
        let mealType: String
        let servings: Int
    }

    enum Failure: LocalizedError {
        case tooLarge, invalidDay, duplicateEvent
        var errorDescription: String? {
            switch self {
            case .tooLarge: "Export up to 200 meals at a time."
            case .invalidDay: "Choose meals within the seven-day plan."
            case .duplicateEvent: "The plan contains duplicate meal entries. Review the plan before exporting."
            }
        }
    }

    static func calendar(_ entries: [Entry], starting start: Date, generated: Date = Date(),
                         timeZone: TimeZone = .current) throws -> String {
        guard entries.count <= 200 else { throw Failure.tooLarge }
        guard start.timeIntervalSinceReferenceDate.isFinite, generated.timeIntervalSinceReferenceDate.isFinite,
              entries.allSatisfy({ (0..<7).contains($0.day) }) else { throw Failure.invalidDay }
        guard Set(entries.map { "\($0.id.uuidString):\($0.day)" }).count == entries.count else { throw Failure.duplicateEvent }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.calendar = cal
        day.timeZone = timeZone; day.dateFormat = "yyyyMMdd"
        let utc = DateFormatter()
        utc.locale = Locale(identifier: "en_US_POSIX"); utc.calendar = cal
        utc.timeZone = TimeZone(secondsFromGMT: 0); utc.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        var lines = ["BEGIN:VCALENDAR", "VERSION:2.0", "PRODID:-//Sowens Studios//Stocked Meal Plan//EN", "CALSCALE:GREGORIAN"]
        for entry in entries {
            guard let date = cal.date(byAdding: .day, value: entry.day, to: cal.startOfDay(for: start)),
                  let end = cal.date(byAdding: .day, value: 1, to: date) else { throw Failure.invalidDay }
            let dateKey = day.string(from: date)
            lines += ["BEGIN:VEVENT", "UID:\(entry.id.uuidString.lowercased())-\(dateKey)@stocked",
                      "DTSTAMP:\(utc.string(from: generated))", "DTSTART;VALUE=DATE:\(dateKey)",
                      "DTEND;VALUE=DATE:\(day.string(from: end))",
                      "SUMMARY:\(escape(entry.mealType + ": " + entry.title))",
                      "DESCRIPTION:\(escape("Planned in Stocked. Servings: \(entry.servings). Exported copy; later app edits do not update this calendar file."))",
                      "TRANSP:TRANSPARENT", "CLASS:PRIVATE", "END:VEVENT"]
        }
        lines += ["END:VCALENDAR"]
        return lines.map(fold).joined(separator: "\r\n") + "\r\n"
    }

    static func duplicateKey(day: Int, title: String, type: String) -> String {
        func normalized(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        // Length prefixes prevent ingredient/name delimiters from colliding.
        let name = normalized(title), slot = normalized(type)
        return "\(day):\(slot.utf8.count):\(slot):\(name)"
    }

    private static func escape(_ value: String) -> String {
        let text = String(String.UnicodeScalarView(value.prefix(2000).unicodeScalars.filter {
            $0.value >= 0x20 && $0.value != 0x7f || [0x09, 0x0a, 0x0d].contains($0.value)
        }))
        return text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: ",", with: "\\,")
    }

    /// Fold by UTF-8 octets, never in the middle of a Unicode scalar.
    static func fold(_ value: String) -> String {
        var lines: [String] = [], line = "", bytes = 0
        for scalar in value.unicodeScalars {
            let text = String(scalar), size = text.utf8.count
            if bytes + size > 75 { lines.append(line); line = " "; bytes = 1 }
            line += text; bytes += size
        }
        lines.append(line)
        return lines.joined(separator: "\r\n")
    }
}
