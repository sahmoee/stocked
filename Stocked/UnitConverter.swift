// UnitConverter.swift
// Ingredient-aware unit conversion: US ⇄ Metric, including the hard case of
// volume ⇄ weight (cups ⇄ grams), which depends on the ingredient's density.
//
// Scope (per product decision): Metric/US with cups↔grams. Densities cover common
// cooking ingredients; unknown densities stay unknown. Volume and mass conversions
// within their own families remain available without guessing an ingredient's weight.

import Foundation

enum UnitSystem: String, CaseIterable, Codable, Sendable {
    case us      // cups, oz, lb, tsp, tbsp, °F
    case metric  // ml, g, kg, °C

    var label: String { self == .us ? "US" : "Metric" }
}

// Canonical measurement kinds the converter understands.
enum MeasureKind: Sendable {
    case volume   // ml-based
    case mass     // g-based
    case count    // unitless (e.g. "2 eggs")
}

struct UnitConverter {

    // MARK: - Density table (grams per millilitre)
    // Used to bridge volume ⇄ mass. Only exact normalized ingredient names match.
    private static let densities: [(key: String, gPerMl: Double)] = [
        ("water", 1.00), ("milk", 1.03), ("cream", 1.01), ("oil", 0.92),
        ("olive oil", 0.92), ("honey", 1.42), ("maple syrup", 1.37), ("syrup", 1.33),
        ("flour", 0.53), ("all-purpose flour", 0.53), ("bread flour", 0.55),
        ("sugar", 0.85), ("granulated sugar", 0.85), ("brown sugar", 0.93),
        ("powdered sugar", 0.56), ("salt", 1.22), ("table salt", 1.22),
        ("kosher salt", 0.69), ("butter", 0.96), ("rice", 0.85), ("rolled oats", 0.41),
        ("oats", 0.41), ("cocoa", 0.41), ("cocoa powder", 0.41), ("yogurt", 1.03),
        ("sour cream", 1.00), ("ketchup", 1.14), ("peanut butter", 1.09),
        ("cornstarch", 0.54), ("baking soda", 0.92), ("baking powder", 0.90),
        ("breadcrumbs", 0.36), ("parmesan", 0.42), ("shredded cheese", 0.40),
    ]

    /// Exact normalized identities only: almond flour is not all-purpose flour,
    /// and cooked rice is not dry rice. Values remain kitchen estimates.
    static func density(for ingredient: String) -> Double? {
        let n = ingredient.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return densities.first(where: { $0.key == n })?.gPerMl
    }

    // MARK: - Base conversions (to ml / to g)
    // Volume units → millilitres
    private static let mlPer: [String: Double] = [
        "tsp": 4.92892, "teaspoon": 4.92892, "teaspoons": 4.92892,
        "tbsp": 14.7868, "tablespoon": 14.7868, "tablespoons": 14.7868,
        "cup": 236.588, "cups": 236.588,
        "fl oz": 29.5735, "fluid ounce": 29.5735, "floz": 29.5735,
        "ml": 1.0, "milliliter": 1.0, "millilitre": 1.0,
        "l": 1000.0, "liter": 1000.0, "litre": 1000.0,
        "pint": 473.176, "quart": 946.353, "gallon": 3785.41,
    ]
    // Mass units → grams
    private static let gPer: [String: Double] = [
        "g": 1.0, "gram": 1.0, "grams": 1.0,
        "kg": 1000.0, "kilogram": 1000.0,
        "oz": 28.3495, "ounce": 28.3495, "ounces": 28.3495,
        "lb": 453.592, "lbs": 453.592, "pound": 453.592, "pounds": 453.592,
    ]

    static func kind(of unit: String) -> MeasureKind {
        let u = unit.lowercased().trimmingCharacters(in: .whitespaces)
        if mlPer[u] != nil { return .volume }
        if gPer[u] != nil { return .mass }
        return .count
    }

    // MARK: - Public conversion
    /// Convert `amount unit` of `ingredient` into the target system, returning a
    /// (value, unit) pair chosen for readability. Count units pass through unchanged.
    static func convert(amount: Double, unit: String, ingredient: String,
                        to system: UnitSystem) -> (value: Double, unit: String) {
        guard amount.isFinite, amount >= 0 else { return (amount, unit) }
        let u = unit.lowercased().trimmingCharacters(in: .whitespaces)
        switch kind(of: u) {
        case .count:
            return (amount, unit)
        case .volume:
            let ml = amount * (mlPer[u] ?? 1.0)
            guard ml.isFinite else { return (amount, unit) }
            return system == .metric
                ? readableMetricVolume(ml)
                : readableUSVolume(ml)
        case .mass:
            let g = amount * (gPer[u] ?? 1.0)
            guard g.isFinite else { return (amount, unit) }
            return system == .metric
                ? readableMetricMass(g)
                : readableUSMass(g)
        }
    }

    /// The headline cross-conversion: cups (volume) → grams (mass) for an ingredient.
    static func cupsToGrams(_ cups: Double, ingredient: String) -> Double? {
        guard cups.isFinite, cups >= 0, let density = density(for: ingredient) else { return nil }
        let ml = cups * (mlPer["cup"] ?? 236.588)
        let grams = ml * density
        return grams.isFinite ? grams : nil
    }

    /// grams → cups for an ingredient.
    static func gramsToCups(_ grams: Double, ingredient: String) -> Double? {
        guard grams.isFinite, grams >= 0, let density = density(for: ingredient) else { return nil }
        let cups = (grams / density) / (mlPer["cup"] ?? 236.588)
        return cups.isFinite ? cups : nil
    }

    // MARK: - Readable formatting
    /// Imported numbers must never pass through Int(Double), which traps when a
    /// finite value exceeds Int.max. Formatting also avoids multiplication overflow.
    static func formatAmount(_ value: Double, fractionDigits: Int = 1) -> String? {
        guard value.isFinite else { return nil }
        let digits = min(3, max(0, fractionDigits))
        var text = String(format: "%.*f", digits, value)
        if digits > 0 {
            while text.last == "0" { text.removeLast() }
            if text.last == "." { text.removeLast() }
        }
        return text
    }

    private static func readableMetricVolume(_ ml: Double) -> (Double, String) {
        ml >= 1000 ? (round1(ml / 1000), "l") : (round1(ml), "ml")
    }
    private static func readableUSVolume(_ ml: Double) -> (Double, String) {
        let cups = ml / 236.588
        if cups >= 0.25 { return (round1(cups), cups == 1 ? "cup" : "cups") }
        let tbsp = ml / 14.7868
        if tbsp >= 1 { return (round1(tbsp), "tbsp") }
        return (round1(ml / 4.92892), "tsp")
    }
    private static func readableMetricMass(_ g: Double) -> (Double, String) {
        g >= 1000 ? (round1(g / 1000), "kg") : (round1(g), "g")
    }
    private static func readableUSMass(_ g: Double) -> (Double, String) {
        let lb = g / 453.592
        return lb >= 1 ? (round1(lb), lb == 1 ? "lb" : "lbs") : (round1(g / 28.3495), "oz")
    }

    private static func round1(_ x: Double) -> Double {
        let scaled = x * 10
        return scaled.isFinite ? scaled.rounded() / 10 : x
    }
}
