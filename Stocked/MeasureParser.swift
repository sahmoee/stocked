// MeasureParser.swift — Improvement #2: ONE measurement parser for the whole app.
//
// Before this file there were six independent parsers of strings like "1 1/2 cups flour":
//   ParsedQuantity.parse            (StockedIntelligence)   — regex, ½¼¾ only, no mixed "1 1/2"
//   IngredientIntel.parseMeasure    (IngredientIntel)       — ½¼¾⅓⅔⅛, own unit tables
//   CookLaterCrossCheckEngine.parse (CookLaterCommandCenter)— the most complete, incl. "fl oz"
//   QuantityParser.parse            (QuantityParser)        — container-aware, ½¼¾⅓⅔
//   CookingFlow.scaleIngredient     (inline regex)          — ½⅓⅔¼¾
//   RecipeIngredientLine.scaledAmount (Models)              — no unicode fractions at all
//
// They disagreed on which fractions exist, whether "1 1/2" parses, and even how many millilitres
// are in a cup (240 in one, 236.588 in three). Every parsing bug had to be fixed six times.
//
// This is the union of all six — the widest fraction table, mixed numbers, two-token units,
// comma decimals and ranges — and the other parsers now delegate to it while keeping their own
// signatures, so no call site had to change.
//
// Pure and `nonisolated`: safe from actors, and directly unit-testable.

import Foundation

// MARK: - Result

nonisolated struct Measure: Sendable, Equatable, Hashable {
    /// nil when the text carried no number ("salt to taste").
    var amount: Double?
    /// Canonical lowercase singular unit ("cup", "tbsp", "g"). Empty = a count, not a measure.
    var unit: String
    /// Everything after the amount and unit, trimmed.
    var name: String
    /// The original string, untouched.
    var raw: String

    var isEmpty: Bool { amount == nil && unit.isEmpty && name.isEmpty }
    var hasAmount: Bool { (amount ?? 0) > 0 }

    /// "1½ cups flour" — amount rendered back as a vulgar fraction where one exists.
    var display: String {
        var parts: [String] = []
        if let a = amount, a > 0 { parts.append(MeasureParser.pretty(a)) }
        if !unit.isEmpty { parts.append(unit) }
        if !name.isEmpty { parts.append(name) }
        return parts.joined(separator: " ")
    }
}

nonisolated enum MeasureFamily: String, Sendable {
    case volume, mass, count
}

// MARK: - Parser

nonisolated enum MeasureParser {

    // ── Fractions ────────────────────────────────────────────────────────────
    // The full Unicode set. Previously each parser knew a different subset, so "⅜ cup" parsed
    // in one screen and silently became "cup" in another.
    static let unicodeFractions: [Character: Double] = [
        "¼": 0.25,  "½": 0.5,   "¾": 0.75,
        "⅐": 1.0/7, "⅑": 1.0/9, "⅒": 0.1,
        "⅓": 1.0/3, "⅔": 2.0/3,
        "⅕": 0.2,   "⅖": 0.4,   "⅗": 0.6,   "⅘": 0.8,
        "⅙": 1.0/6, "⅚": 5.0/6,
        "⅛": 0.125, "⅜": 0.375, "⅝": 0.625, "⅞": 0.875,
    ]

    // ── Units ────────────────────────────────────────────────────────────────
    // One table, one canonical spelling, one conversion factor. 236.588 ml per cup —
    // ParsedQuantity used to say 240, which made the same recipe weigh differently on two screens.
    nonisolated struct UnitInfo: Sendable {
        let canonical: String
        let family: MeasureFamily
        /// ml for volume, g for mass, 1 for count.
        let base: Double
    }

    static let units: [String: UnitInfo] = {
        var t: [String: UnitInfo] = [:]
        func vol(_ canonical: String, _ ml: Double, _ aliases: [String]) {
            for a in aliases + [canonical] { t[a] = UnitInfo(canonical: canonical, family: .volume, base: ml) }
        }
        func mass(_ canonical: String, _ g: Double, _ aliases: [String]) {
            for a in aliases + [canonical] { t[a] = UnitInfo(canonical: canonical, family: .mass, base: g) }
        }
        vol("tsp",   4.92892, ["t", "ts", "tsps", "teaspoon", "teaspoons"])
        vol("tbsp",  14.7868, ["tb", "tbs", "tbsps", "tablespoon", "tablespoons", "tblsp"])
        vol("fl oz", 29.5735, ["floz", "fluid ounce", "fluid ounces", "fl. oz", "fl oz."])
        vol("cup",   236.588, ["c", "cups"])
        vol("pint",  473.176, ["pt", "pints"])
        vol("quart", 946.353, ["qt", "quarts"])
        vol("gallon", 3785.41, ["gal", "gallons"])
        vol("ml",    1.0,     ["milliliter", "millilitre", "milliliters", "millilitres", "cc"])
        vol("l",     1000.0,  ["liter", "litre", "liters", "litres"])
        mass("g",    1.0,     ["gram", "grams", "gm", "gms"])
        mass("kg",   1000.0,  ["kilogram", "kilograms", "kilo", "kilos"])
        mass("oz",   28.3495, ["ounce", "ounces"])
        mass("lb",   453.592, ["lbs", "pound", "pounds", "#"])
        mass("mg",   0.001,   ["milligram", "milligrams"])
        return t
    }()

    /// Multi-word units have to be matched before single tokens, longest first, or "fl oz" parses
    /// as the unit "fl" plus an ingredient called "oz".
    private static let multiWordUnits: [String] = ["fluid ounces", "fluid ounce", "fl. oz", "fl oz", "fl oz."]

    // ── Entry point ──────────────────────────────────────────────────────────

    static func parse(_ raw: String) -> Measure {
        let original = raw
        var s = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return Measure(amount: nil, unit: "", name: "", raw: original) }

        // Separate any vulgar fraction glued to a digit ("1½" → "1 ½") so tokenizing works.
        s = spaceOutFractions(s)
        // European decimals: "1,5 kg". Only when a digit sits on both sides, so "salt, pepper" is safe.
        s = s.replacingOccurrences(of: #"(?<=\d),(?=\d)"#, with: ".", options: .regularExpression)

        var tokens = s.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        var amount: Double? = nil

        // ── Amount: consume leading numeric tokens ───────────────────────────
        // Handles "2", "1/2", "½", "1 1/2", "1 ½", and ranges "2-3" / "2 to 3" (takes the low end —
        // under-buying is recoverable, over-scaling a recipe is not).
        if let first = tokens.first, let n = number(first) {
            var total = n
            tokens.removeFirst()
            // A whole number followed by a bare fraction is one mixed number.
            if isWhole(n), let next = tokens.first, let f = number(next), f < 1, isFractionToken(next) {
                total += f
                tokens.removeFirst()
            }
            // Range: drop the upper bound.
            if let next = tokens.first {
                if next == "-" || next == "to" || next == "–" {
                    if tokens.count > 1, number(tokens[1]) != nil { tokens.removeFirst(2) }
                } else if next.hasPrefix("-"), number(String(next.dropFirst())) != nil {
                    tokens.removeFirst()
                }
            }
            amount = total
        }

        // ── Unit: multi-word first, then single token ────────────────────────
        var unit = ""
        let rest = tokens.joined(separator: " ")
        if let mw = multiWordUnits.first(where: { rest.hasPrefix($0 + " ") || rest == $0 }),
           let info = units[mw] {
            unit = info.canonical
            let dropped = rest.dropFirst(mw.count).trimmingCharacters(in: .whitespaces)
            tokens = dropped.isEmpty ? [] : dropped.split(separator: " ").map(String.init)
        } else if let first = tokens.first {
            let cleaned = first.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
            if let info = units[cleaned] {
                unit = info.canonical
                tokens.removeFirst()
            }
        }

        // ── Name: whatever's left ────────────────────────────────────────────
        var name = tokens.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        // "of" survives from "2 cups of flour" and nothing downstream wants it.
        if name.hasPrefix("of ") { name = String(name.dropFirst(3)) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: " ,.-"))

        return Measure(amount: amount, unit: unit, name: name, raw: original)
    }

    // ── Numbers ──────────────────────────────────────────────────────────────

    /// One number from one token: "2", "2.5", "1/2", "½", "1½".
    static func number(_ token: String) -> Double? {
        let t = token.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
        guard !t.isEmpty else { return nil }

        // Pure vulgar fraction, or digits followed by one.
        if let last = t.last, let frac = unicodeFractions[last] {
            let head = String(t.dropLast())
            if head.isEmpty { return frac }
            if let whole = Double(head) { return whole + frac }
            return nil
        }
        // "1/2" or "3/4"
        if t.contains("/") {
            let parts = t.split(separator: "/")
            if parts.count == 2, let n = Double(parts[0]), let d = Double(parts[1]), d != 0 {
                return n / d
            }
            return nil
        }
        return Double(t)
    }

    private static func isFractionToken(_ t: String) -> Bool {
        t.contains("/") || t.contains(where: { unicodeFractions[$0] != nil })
    }
    private static func isWhole(_ d: Double) -> Bool { d == d.rounded() && d >= 1 }

    private static func spaceOutFractions(_ s: String) -> String {
        var out = ""
        for ch in s {
            if unicodeFractions[ch] != nil, let last = out.last, last.isNumber {
                out.append(" ")   // "1½" → "1 ½", so the mixed-number path sees two tokens
            }
            out.append(ch)
        }
        return out
    }

    /// Decimal back to the nicest readable form: 1.5 → "1½", 0.25 → "¼", 2.0 → "2".
    static func pretty(_ value: Double) -> String {
        guard value > 0 else { return "0" }
        let whole = floor(value)
        let frac = value - whole
        let glyphs: [(Double, String)] = [
            (0.125, "⅛"), (0.25, "¼"), (1.0/3, "⅓"), (0.375, "⅜"), (0.5, "½"),
            (0.625, "⅝"), (2.0/3, "⅔"), (0.75, "¾"), (0.875, "⅞"),
        ]
        if let hit = glyphs.first(where: { abs(frac - $0.0) < 0.02 }) {
            return whole == 0 ? hit.1 : "\(Int(whole))\(hit.1)"
        }
        if frac < 0.02 { return String(Int(whole)) }
        return String(format: "%.2f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    // ── Conversion ───────────────────────────────────────────────────────────

    static func family(of unit: String) -> MeasureFamily {
        units[unit.lowercased()]?.family ?? .count
    }

    /// Amount expressed in the family's base unit (ml or g). nil when it isn't a measurable unit.
    static func baseValue(amount: Double, unit: String) -> Double? {
        guard let info = units[unit.lowercased()] else { return nil }
        return amount * info.base
    }

    /// Convert between any two units of the same family. Cross-family needs a density —
    /// use `UnitConverter.convert` for that, which knows per-ingredient densities.
    static func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard let a = units[from.lowercased()], let b = units[to.lowercased()],
              a.family == b.family, b.base != 0 else { return nil }
        return amount * a.base / b.base
    }

    /// Canonical spelling for a unit token, or "" if unrecognised.
    static func canonicalUnit(_ token: String) -> String {
        units[token.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".,"))]?.canonical ?? ""
    }
}
