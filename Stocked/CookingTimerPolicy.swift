import Foundation

/// Bounded, deterministic timer math shared by recipe parsing, countdowns and restore.
nonisolated enum CookingTimerPolicy {
    static let maximumSeconds = 30 * 24 * 60 * 60
    static let maximumTextCharacters = 32_768
    static let maximumTimers = 128
    private static let fractions: [Character: Double] = ["½": 0.5, "⅓": 1.0 / 3, "⅔": 2.0 / 3, "¼": 0.25, "¾": 0.75, "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875]
    private static let words: [String: Double] = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "half": 0.5, "quarter": 0.25]
    // Compiled once, not once per instruction row/body evaluation.
    private static let pattern = try! NSRegularExpression(pattern: #"(?<![\p{L}\d./−-])((?:\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?[½⅓⅔¼¾⅛⅜⅝⅞]?|[½⅓⅔¼¾⅛⅜⅝⅞]|one|two|three|four|five|six|half|quarter))(?:\s*(?:–|—|-|to)\s*((?:\d+(?:\.\d+)?|one|two|three|four|five|six)))?\s*(hours?|hrs?|minutes?|mins?|seconds?|secs?)\b"#, options: .caseInsensitive)

    /// The first duration group is the timer. Adjacent smaller units form one group;
    /// separate actions ("bake 30 minutes, cool 10 minutes") are never silently added.
    /// A range uses its upper endpoint; the UI states this before starting.
    static func detectSeconds(in text: String) -> Int? {
        guard text.count <= maximumTextCharacters else { return nil }
        let input = text.lowercased() as NSString
        let matches = pattern.matches(in: input as String, range: NSRange(location: 0, length: input.length))
        var total = 0.0
        var previousEnd: Int?
        var previousMultiplier = Double.infinity
        for match in matches {
            let unit = input.substring(with: match.range(at: 3))
            let multiplier = unit.hasPrefix("h") ? 3600.0 : unit.hasPrefix("m") ? 60.0 : 1.0
            if let previousEnd {
                let between = input.substring(with: NSRange(location: previousEnd, length: match.range.location - previousEnd))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard multiplier < previousMultiplier, between.isEmpty || between == "and" else { break }
            }
            guard let first = number(input.substring(with: match.range(at: 1))) else { return nil }
            let second = match.range(at: 2).location == NSNotFound ? first : number(input.substring(with: match.range(at: 2)))
            guard let second else { return nil }
            let seconds = max(first, second) * multiplier
            guard seconds.isFinite, seconds > 0, seconds <= Double(maximumSeconds), total <= Double(maximumSeconds) - seconds else { return nil }
            total += seconds
            previousMultiplier = multiplier
            previousEnd = NSMaxRange(match.range)
        }
        guard total > 0 else { return nil }
        return Int(total.rounded(.up))
    }

    private static func number(_ input: String) -> Double? {
        if let word = words[input] { return word }
        if let last = input.last, let fraction = fractions[last] {
            return (Double(input.dropLast()) ?? 0) + fraction
        }
        if input.contains("/") {
            let parts = input.split(whereSeparator: \.isWhitespace)
            guard let tail = parts.last else { return nil }
            let fraction = tail.split(separator: "/")
            guard fraction.count == 2, let numerator = Double(fraction[0]), let denominator = Double(fraction[1]), denominator > 0 else { return nil }
            return (parts.count == 2 ? Double(parts[0]) ?? 0 : 0) + numerator / denominator
        }
        return Double(input)
    }

    static func validDuration(_ seconds: Int) -> Int { min(maximumSeconds, max(0, seconds)) }
    static func remaining(until deadline: Date, now: Date, total: Int) -> Int {
        let seconds = deadline.timeIntervalSince(now)
        guard seconds.isFinite else { return 0 }
        return Int(min(Double(validDuration(total)), max(0, seconds)).rounded(.up))
    }
    static func display(_ seconds: Int) -> String {
        let seconds = validDuration(seconds)
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, (seconds % 3600) / 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
    static func spoken(_ seconds: Int) -> String {
        let seconds = validDuration(seconds)
        var parts: [String] = []
        let hours = seconds / 3600, minutes = seconds % 3600 / 60, rest = seconds % 60
        if hours > 0 { parts.append("\(hours) hour\(hours == 1 ? "" : "s")") }
        if minutes > 0 { parts.append("\(minutes) minute\(minutes == 1 ? "" : "s")") }
        if rest > 0 || parts.isEmpty { parts.append("\(rest) second\(rest == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

nonisolated enum ReminderClockPolicy {
    static func hour(_ value: Int?, fallback: Int = 7) -> Int { min(23, max(0, value ?? fallback)) }
    static func minute(_ value: Int?) -> Int { min(59, max(0, value ?? 0)) }
}
