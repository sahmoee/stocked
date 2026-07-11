// QuantityParser.swift — natural-language quantity + unit parsing for Stocked.
//
// Turns free text people actually type/say into a structured quantity, so scanning, adding,
// and receipt review can all offer flexible amounts:
//   "4 bags of chips"        -> 4 × bag
//   "6 poptarts"             -> 6 × item              (item = poptart)
//   "half a bag of cheese"   -> 0.5 × bag
//   "6 cans of 8 oz"         -> 6 × can, 8 oz each
//   "12 oz"                  -> 1 × 12 oz
//   "a dozen eggs"           -> 12 × item
//   "2 1/2 lbs chicken"      -> 2.5 lb
//
// Pure value type + parser; no UI, no dependencies. Pair with QuantityInputView for editing.

import Foundation

struct ParsedAmount: Equatable, Codable {
    /// How many containers/items (e.g. 4 bags, 6 cans, 0.5 bag, 12 eggs).
    var count: Double
    /// The container/packaging or "item" (bag, can, box, jar, bottle, pack, bunch, item, …).
    var container: String
    /// Optional amount per container (e.g. 8 for "6 cans of 8 oz").
    var amountEach: Double?
    /// Optional unit for amountEach (oz, lb, g, ml, …). If container is a measure (oz, lb),
    /// this is nil and the measure lives in `container`.
    var unitEach: String?
    /// The leftover descriptor (the item name text, e.g. "chips", "cheese").
    var item: String

    /// A tidy human string, e.g. "6 cans · 8 oz each" or "0.5 bag" or "12 oz".
    var display: String {
        let n = ParsedAmount.trim(count)
        let base = container == "item"
            ? "\(n)\(item.isEmpty ? "" : " \(item)")"
            : "\(n) \(pluralize(container, count))"
        if let a = amountEach, let u = unitEach {
            return "\(base) · \(ParsedAmount.trim(a)) \(u) each"
        }
        return base
    }

    static func trim(_ d: Double) -> String {
        d == d.rounded() ? String(Int(d)) : String(format: "%.2f", d).replacingOccurrences(of: ".00", with: "")
    }

    private func pluralize(_ word: String, _ n: Double) -> String {
        guard n != 1 else { return word }
        if word.hasSuffix("s") || word.hasSuffix("x") { return word + "es" }
        return word + "s"
    }
}

enum QuantityParser {

    static let numberWords: [String: Double] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6,
        "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
        "dozen": 12, "couple": 2, "few": 3, "half": 0.5, "quarter": 0.25, "third": 0.333
    ]

    static let containers: Set<String> = [
        "bag", "bags", "can", "cans", "box", "boxes", "pack", "packs", "package", "packages",
        "jar", "jars", "bottle", "bottles", "bunch", "bunches", "carton", "cartons",
        "container", "containers", "case", "cases", "loaf", "loaves", "stick", "sticks",
        "dozen", "roll", "rolls", "tub", "tubs", "bar", "bars", "clove", "cloves", "head", "heads"
    ]

    static let units: Set<String> = [
        "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds", "g", "gram", "grams",
        "kg", "kilogram", "ml", "l", "liter", "liters", "litre", "litres", "cup", "cups",
        "tbsp", "tsp", "gallon", "gallons", "quart", "quarts", "pint", "pints", "fl", "floz"
    ]

    /// Parse free text into a structured quantity. Always returns something usable.
    static func parse(_ raw: String) -> ParsedAmount {
        let lower = raw.lowercased()
            .replacingOccurrences(of: " of ", with: " of ")
        var tokens = tokenize(lower)

        var count: Double? = nil
        var container = "item"
        var amountEach: Double? = nil
        var unitEach: String? = nil
        var itemWords: [String] = []

        var i = 0
        var pendingNumber: Double? = nil
        var sawOf = false

        while i < tokens.count {
            let tok = tokens[i]

            // number (digit, fraction like 1/2, or mixed "2 1/2")
            if let num = numeric(tok) {
                if let p = pendingNumber { pendingNumber = p + num } // mixed number "2 1/2"
                else { pendingNumber = num }
                i += 1; continue
            }
            if let w = numberWords[tok] {
                pendingNumber = (pendingNumber ?? 0) + (pendingNumber != nil && w < 1 ? w : w)
                if pendingNumber == 0 { pendingNumber = w }
                i += 1; continue
            }

            // "of" separates count/container from an each-amount ("6 cans of 8 oz")
            if tok == "of" { sawOf = true; i += 1; continue }

            // a container word
            if containers.contains(tok) {
                let singular = singularContainer(tok)
                if !sawOf { count = count ?? pendingNumber ?? 1; container = singular }
                else { /* "bag of..." with of before container is unusual; treat as container */ container = singular }
                pendingNumber = nil
                i += 1; continue
            }

            // a measurement unit
            if units.contains(tok) {
                let u = normalizeUnit(tok)
                if sawOf, let n = pendingNumber {
                    amountEach = n; unitEach = u          // "6 cans of 8 oz"
                } else if container == "item", let n = pendingNumber {
                    // "12 oz" with no container -> a single measured amount
                    count = 1; container = u; _ = n
                    amountEach = nil; unitEach = nil
                    // represent as count of the measured amount:
                    count = n; container = u
                } else {
                    container = u; count = count ?? pendingNumber ?? 1
                }
                pendingNumber = nil
                i += 1; continue
            }

            // otherwise it's part of the item name
            if !tok.isEmpty && tok != "of" { itemWords.append(tok) }
            i += 1
        }

        // leftover number with no container -> count of items ("6 poptarts")
        if count == nil { count = pendingNumber ?? 1 }

        let item = itemWords.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return ParsedAmount(count: max(0, count ?? 1),
                              container: container,
                              amountEach: amountEach,
                              unitEach: unitEach,
                              item: item)
    }

    // MARK: helpers

    private static func tokenize(_ s: String) -> [String] {
        s.replacingOccurrences(of: "-", with: " ")
            .components(separatedBy: CharacterSet(charactersIn: " ,;\n\t"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func numeric(_ tok: String) -> Double? {
        if let d = Double(tok) { return d }
        // fraction "1/2"
        if tok.contains("/") {
            let parts = tok.split(separator: "/")
            if parts.count == 2, let a = Double(parts[0]), let b = Double(parts[1]), b != 0 { return a / b }
        }
        // unicode fractions
        let fr: [String: Double] = ["½": 0.5, "¼": 0.25, "¾": 0.75, "⅓": 0.333, "⅔": 0.667]
        if let f = fr[tok] { return f }
        return nil
    }

    private static func singularContainer(_ tok: String) -> String {
        if tok == "dozen" { return "dozen" }
        if tok == "loaves" { return "loaf" }
        if tok.hasSuffix("es") && (tok == "boxes" || tok == "bunches" || tok == "cases") { return String(tok.dropLast(2)) }
        if tok.hasSuffix("s") { return String(tok.dropLast()) }
        return tok
    }

    private static func normalizeUnit(_ tok: String) -> String {
        switch tok {
        case "ounce", "ounces": return "oz"
        case "pound", "pounds", "lbs": return "lb"
        case "gram", "grams": return "g"
        case "kilogram": return "kg"
        case "liter", "liters", "litre", "litres": return "l"
        case "cups": return "cup"
        case "gallons": return "gallon"
        case "quarts": return "quart"
        case "pints": return "pint"
        case "floz", "fl": return "fl oz"
        default: return tok
        }
    }
}
