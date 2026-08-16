// Formatters.swift
// #12 perf: DateFormatter creation is expensive. These shared, cached instances avoid
// constructing a new formatter inside row bodies / loops, where it can run hundreds of
// times during scrolling. Use these instead of `DateFormatter()` in hot paths.

import Foundation

/// `ISO8601DateFormatter` is mutable and does not conform to `Sendable`. Keep the
/// cached formatter private and serialize its use so callers can safely format
/// dates from any actor without recreating the formatter for every conversion.
nonisolated final class StockedISO8601Formatter: @unchecked Sendable {
    private let lock = NSLock()
    private let formatter: ISO8601DateFormatter

    init(formatOptions: ISO8601DateFormatter.Options = [.withInternetDateTime]) {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = formatOptions
    }

    func string(from date: Date) -> String {
        lock.lock()
        defer { lock.unlock() }
        return formatter.string(from: date)
    }

    func date(from string: String) -> Date? {
        lock.lock()
        defer { lock.unlock() }
        return formatter.date(from: string)
    }
}

nonisolated enum StockedFormatters {
    /// Weekday name, e.g. "Monday".
    static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f
    }()

    /// Medium date, no time, e.g. "Jun 5, 2026".
    static let mediumDate: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f
    }()

    /// Short date, no time, e.g. "6/5/26".
    static let shortDate: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .none; return f
    }()

    /// Short date + time, e.g. "6/5/26, 6:31 PM".
    static let shortDateTime: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .short; f.timeStyle = .short; return f
    }()

    /// File-stamp date, e.g. "2026-06-05".
    static let fileStamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f
    }()

    /// Shared ISO-8601 formatter for backup/transfer encoding.
    static let iso8601 = StockedISO8601Formatter()
    static let iso8601Fractional = StockedISO8601Formatter(
        formatOptions: [.withInternetDateTime, .withFractionalSeconds]
    )

    /// Time-of-day greeting ("Good Morning" / "Good Afternoon" / "Good Evening"), based on the
    /// current hour. Single source of truth — previously duplicated as a private computed
    /// property in six different views.
    static var timeOfDayGreeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12:  return "Good Morning"
        case 12..<17: return "Good Afternoon"
        default:      return "Good Evening"
        }
    }

    /// Normalize a duration string for display. Converts an ISO-8601 duration
    /// ("PT20M", "PT1H30M", "PT2H") into friendly text ("20 min", "1 hr 30 min",
    /// "2 hr"). Strings that are already human-readable ("30 min", "15 mins") pass
    /// through unchanged. Empty / unparseable ISO returns "".
    static func prettyDuration(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        // Not an ISO duration → assume it's already human-friendly, leave as-is.
        guard s.hasPrefix("PT") || s.hasPrefix("P") else { return s }
        var body = Substring(s.dropFirst(s.hasPrefix("PT") ? 2 : 1))
        var hours = 0, minutes = 0
        if let h = body.range(of: "H") {
            hours = Int(body[body.startIndex..<h.lowerBound]) ?? 0
            body = body[h.upperBound...]
        }
        if let m = body.range(of: "M") {
            minutes = Int(body[body.startIndex..<m.lowerBound]) ?? 0
        }
        if hours == 0 && minutes == 0 { return "" }
        if hours > 0 && minutes > 0 { return "\(hours) hr \(minutes) min" }
        return hours > 0 ? "\(hours) hr" : "\(minutes) min"
    }
}
