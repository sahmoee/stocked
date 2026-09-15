// UnitMath.swift — unit-aware quantity math for inventory merging (#B2).
//
// Lets the smart-merge in GuestDataStore treat "500 g" and "1 lb" of the same
// item as one row with a summed amount, instead of two rows. Conservative by
// design: only mass<->mass and volume<->volume conversions; anything else is
// "not convertible" and falls back to the existing same-unit-only merge rule.
import Foundation

nonisolated enum UnitMath {

    enum Family { case mass, volume }

    /// Canonical factor to the family base unit (grams for mass, milliliters
    /// for volume). Keys are lowercased, period-stripped unit spellings.
    private static let mass: [String: Double] = [
        "g": 1, "gram": 1, "grams": 1,
        "kg": 1000, "kilogram": 1000, "kilograms": 1000,
        "oz": 28.3495, "ounce": 28.3495, "ounces": 28.3495,
        "lb": 453.592, "lbs": 453.592, "pound": 453.592, "pounds": 453.592,
    ]
    private static let volume: [String: Double] = [
        "ml": 1, "milliliter": 1, "milliliters": 1, "millilitre": 1, "millilitres": 1,
        "l": 1000, "liter": 1000, "liters": 1000, "litre": 1000, "litres": 1000,
        "fl oz": 29.5735, "floz": 29.5735, "fluid ounce": 29.5735, "fluid ounces": 29.5735,
        "cup": 236.588, "cups": 236.588,
        "pt": 473.176, "pint": 473.176, "pints": 473.176,
        "qt": 946.353, "quart": 946.353, "quarts": 946.353,
        "gal": 3785.41, "gallon": 3785.41, "gallons": 3785.41,
        "tbsp": 14.7868, "tablespoon": 14.7868, "tablespoons": 14.7868,
        "tsp": 4.92892, "teaspoon": 4.92892, "teaspoons": 4.92892,
    ]

    static func normalized(_ unit: String) -> String {
        unit.lowercased().replacingOccurrences(of: ".", with: "")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func baseFactor(for unit: String) -> Double? {
        let key = normalized(unit)
        return mass[key] ?? volume[key]
    }

    static func family(of unit: String) -> Family? {
        let u = normalized(unit)
        if mass[u] != nil { return .mass }
        if volume[u] != nil { return .volume }
        return nil
    }

    /// Whether two units can be summed (same family). Same spelling counts too.
    static func convertible(_ a: String, _ b: String) -> Bool {
        let na = normalized(a), nb = normalized(b)
        if na == nb { return true }
        guard let fa = family(of: na), let fb = family(of: nb) else { return false }
        return fa == fb
    }

    /// Convert an amount between convertible units. Returns nil when not convertible.
    static func convert(_ amount: Double, from: String, to: String) -> Double? {
        guard amount.isFinite, amount >= 0 else { return nil }
        let nf = normalized(from), nt = normalized(to)
        if nf == nt { return amount }
        guard convertible(nf, nt), let a = baseFactor(for: nf), let b = baseFactor(for: nt) else { return nil }
        // Divide factors first: identical large-unit values need not overflow
        // through an unnecessary intermediate base-unit quantity.
        let result = amount * (a / b)
        return result.isFinite ? result : nil
    }
}
