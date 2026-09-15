import Foundation

/// Container-aware quantities. Only a leading quantity and an explicit package size
/// affect the numbers; digits in the remaining product name remain product text.
nonisolated struct ParsedAmount: Equatable, Codable, Sendable {
    var count: Double
    var container: String
    var amountEach: Double?
    var unitEach: String?
    var item: String
    /// Transient parse feedback; absent in older encoded amounts.
    var validationMessage: String? = nil

    var display: String {
        let base = container == "item" ? "\(Self.trim(count))\(item.isEmpty ? "" : " " + item)"
            : "\(Self.trim(count)) \(QuantityParser.plural(container, count: count))"
        if let amountEach, let unitEach { return "\(base) · \(Self.trim(amountEach)) \(unitEach) each" }
        return base
    }
    static func trim(_ value: Double) -> String {
        guard value.isFinite else { return "—" }
        if abs(value) >= 1_000_000_000 { return String(format: "%.6g", value) }
        var text = String(format: "%.2f", value)
        while text.last == "0" { text.removeLast() }
        if text.last == "." { text.removeLast() }
        return text == "-0" ? "0" : text
    }
}

nonisolated enum QuantityParser {
    static let maximumCharacters = 4096
    static let maximumAmount = 1_000_000_000.0
    static let numberWords: [String: Double] = [
        "zero": 0, "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "dozen": 12, "couple": 2, "few": 3, "half": 0.5, "quarter": 0.25, "third": 1.0 / 3
    ]
    private static let fraction: [Character: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 1.0/3, "⅔": 2.0/3, "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875, "⅕": 0.2, "⅖": 0.4, "⅗": 0.6, "⅘": 0.8, "⅙": 1.0/6, "⅚": 5.0/6]
    private static let containerAliases: [String: String] = [
        "bag": "bag", "bags": "bag", "can": "can", "cans": "can", "box": "box", "boxes": "box",
        "pack": "pack", "packs": "pack", "package": "package", "packages": "package", "jar": "jar", "jars": "jar",
        "bottle": "bottle", "bottles": "bottle", "bunch": "bunch", "bunches": "bunch", "carton": "carton", "cartons": "carton",
        "container": "container", "containers": "container", "case": "case", "cases": "case", "loaf": "loaf", "loaves": "loaf",
        "stick": "stick", "sticks": "stick", "roll": "roll", "rolls": "roll", "tub": "tub", "tubs": "tub", "bar": "bar", "bars": "bar",
        "clove": "clove", "cloves": "clove", "head": "head", "heads": "head"
    ]
    private static let unitAliases: [String: String] = [
        "oz":"oz", "ounce":"oz", "ounces":"oz", "lb":"lb", "lbs":"lb", "pound":"lb", "pounds":"lb",
        "g":"g", "gram":"g", "grams":"g", "kg":"kg", "kilogram":"kg", "kilograms":"kg",
        "ml":"ml", "milliliter":"ml", "milliliters":"ml", "millilitre":"ml", "millilitres":"ml",
        "l":"l", "liter":"l", "liters":"l", "litre":"l", "litres":"l", "cup":"cup", "cups":"cup",
        "tbsp":"tbsp", "tablespoon":"tbsp", "tablespoons":"tbsp", "tsp":"tsp", "teaspoon":"tsp", "teaspoons":"tsp",
        "gallon":"gallon", "gallons":"gallon", "quart":"quart", "quarts":"quart", "pint":"pint", "pints":"pint", "floz":"fl oz"
    ]
    static let containers = Set(containerAliases.keys).union(["dozen"])
    static let units = Set(unitAliases.keys).union(["fl"])
    private static let packageHyphen = try! NSRegularExpression(pattern: #"(?<=\d)-(?=(?:packs?|bags?|cans?|boxes?|bottles?)\b)"#)

    static func parse(_ raw: String) -> ParsedAmount {
        // Reject oversized work before lowercase/token arrays; never silently parse a truncated amount.
        guard raw.utf8.count <= maximumCharacters * 4, raw.count <= maximumCharacters else {
            return ParsedAmount(count: 0, container: "item", amountEach: nil, unitEach: nil, item: String(raw.prefix(120)), validationMessage: "Use a shorter quantity description (up to 4,096 characters).")
        }
        let lower = raw.lowercased()
        let spaced = packageHyphen.stringByReplacingMatches(in: lower, range: NSRange(lower.startIndex..., in: lower), withTemplate: " ")
        let tokens = spaced.split(whereSeparator: { $0.isWhitespace }).map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: "();")) }
        guard !tokens.isEmpty else { return ParsedAmount(count: 1, container: "item", amountEach: nil, unitEach: nil, item: "") }
        var index = 0
        let first = leadingNumber(tokens, at: &index)
        if let first, !valid(first) { return invalid(tokens) }
        // Explicit nonfinite/invalid numeric input is not a request for one item.
        if first == nil, looksNumeric(tokens[0]) { return invalid(tokens) }
        var count = first ?? 1
        if index < tokens.count, tokens[index] == "dozen" { count *= 12; index += 1 }
        guard valid(count) else { return invalid(tokens) }
        var container = "item", amountEach: Double?, unitEach: String?
        if index < tokens.count, let package = containerAliases[tokens[index]] {
            container = package; index += 1
            if index < tokens.count, tokens[index] == "of" || tokens[index] == "·" { index += 1 }
            var sizeIndex = index
            if let size = leadingNumber(tokens, at: &sizeIndex), let unit = measure(tokens, at: sizeIndex) {
                guard valid(size), size > 0 else { return invalid(tokens) }
                amountEach = size; unitEach = unit.name; index = sizeIndex + unit.count
                if index < tokens.count, tokens[index] == "each" { index += 1 }
                if index < tokens.count, tokens[index] == "of" { index += 1 }
            } else if index + 1 < tokens.count, looksNumeric(tokens[index]), measure(tokens, at: index + 1) != nil {
                return invalid(tokens)
            }
        } else if let unit = measure(tokens, at: index) {
            container = unit.name; index += unit.count
            if index < tokens.count, tokens[index] == "of" { index += 1 }
        }
        let item = tokens.dropFirst(index).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedAmount(count: count, container: container, amountEach: amountEach, unitEach: unitEach, item: item)
    }

    private static func leadingNumber(_ tokens: [String], at index: inout Int) -> Double? {
        guard index < tokens.count else { return nil }
        let start = index
        // Articles qualify fractional phrases instead of adding one whole container.
        if ["a", "an"].contains(tokens[index]), index + 1 < tokens.count,
           let fraction = numberWords[tokens[index + 1]], fraction < 1 { index += 1 }
        guard let initial = number(tokens[index]) ?? numberWords[tokens[index]] else { index = start; return nil }
        var result = initial; index += 1
        if initial < 1, index < tokens.count, ["a", "an"].contains(tokens[index]) { index += 1 }
        if initial >= 1, initial == initial.rounded(), index < tokens.count,
           isFraction(tokens[index]), let additional = number(tokens[index]), additional > 0, additional < 1 {
            result += additional; index += 1
        } else if initial >= 1, initial == initial.rounded(), index < tokens.count, tokens[index] == "and" {
            var fractionIndex = index + 1
            if fractionIndex < tokens.count, ["a", "an"].contains(tokens[fractionIndex]) { fractionIndex += 1 }
            if fractionIndex < tokens.count,
               let additional = number(tokens[fractionIndex]) ?? numberWords[tokens[fractionIndex]],
               additional > 0, additional < 1 {
                result += additional; index = fractionIndex + 1
            }
        }
        return result
    }
    private static func number(_ input: String) -> Double? {
        var text = input.replacingOccurrences(of: "−", with: "-")
        let mixed = text.split(separator: "-", omittingEmptySubsequences: false)
        if mixed.count == 2, mixed[1].contains("/"), let whole = Double(mixed[0]), whole >= 0,
           let part = number(String(mixed[1])), part > 0, part < 1 { return whole + part }
        if let last = text.last, let value = fraction[last] {
            let head = String(text.dropLast())
            if head.isEmpty || head == "+" { return value }
            if head == "-" { return -value }
            guard let whole = Double(head) else { return nil }
            // Preserve a minus sign even on negative zero; -0½ must not become +½.
            return whole.sign == .minus ? whole - value : whole + value
        }
        if text.contains("/") {
            let parts = text.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, let top = Double(parts[0]), let bottom = Double(parts[1]), bottom > 0 else { return nil }
            return top / bottom
        }
        if text.contains(",") {
            let groups = text.split(separator: ",", omittingEmptySubsequences: false)
            if groups.count > 1, (1...3).contains(groups[0].count), groups.dropFirst().allSatisfy({ $0.count == 3 && $0.allSatisfy(\.isNumber) }) {
                text = groups.joined()
            } else if groups.count == 2 { text = groups.joined(separator: ".") }
        }
        return Double(text)
    }
    private static func measure(_ tokens: [String], at index: Int) -> (name: String, count: Int)? {
        guard index < tokens.count else { return nil }
        let clean: (String) -> String = { $0.trimmingCharacters(in: CharacterSet(charactersIn: ".,:")) }
        if index + 1 < tokens.count, ["fl", "fluid"].contains(clean(tokens[index])),
           ["oz", "ounce", "ounces"].contains(clean(tokens[index + 1])) { return ("fl oz", 2) }
        return unitAliases[clean(tokens[index])].map { ($0, 1) }
    }
    private static func valid(_ value: Double) -> Bool { value.isFinite && value >= 0 && value <= maximumAmount }
    private static func isFraction(_ value: String) -> Bool { value.contains("/") || value.contains { fraction[$0] != nil } }
    private static func looksNumeric(_ value: String) -> Bool {
        ["nan", "inf", "infinity"].contains(value) || (!value.isEmpty && value.allSatisfy { $0.isNumber || fraction[$0] != nil || "/.,+-−eE".contains($0) })
    }
    private static func invalid(_ tokens: [String]) -> ParsedAmount {
        ParsedAmount(count: 0, container: "item", amountEach: nil, unitEach: nil, item: tokens.joined(separator: " "), validationMessage: "Enter a finite quantity from 0 to 1,000,000,000. Package sizes must be greater than zero.")
    }
    static func plural(_ word: String, count: Double) -> String {
        guard count != 1 else { return word }
        if ["oz", "fl oz", "lb", "g", "kg", "ml", "l", "tbsp", "tsp", "dozen"].contains(word) { return word }
        if word == "loaf" { return "loaves" }
        if word == "box" || word == "bunch" { return word + "es" }
        return word.hasSuffix("s") ? word : word + "s"
    }
}
