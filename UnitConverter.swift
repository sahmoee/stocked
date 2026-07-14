// UnitConverter.swift
// Ingredient-aware unit conversion: US ⇄ Metric, including the hard case of
// volume ⇄ weight (cups ⇄ grams), which depends on the ingredient's density.
//
// Scope (per product decision): Metric/US with cups↔grams. Densities cover common
// cooking ingredients; anything unknown falls back to a water-like density so the
// conversion still produces a sensible (if approximate) number rather than failing.

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
    // Used to bridge volume ⇄ mass. Keys are matched as substrings of the ingredient
    // name (lowercased). Order doesn't matter; the most specific match wins.
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

    /// grams per millilitre for an ingredient (substring match, water fallback).
    static func density(for ingredient: String) -> Double {
        let n = ingredient.lowercased()
        // Prefer the longest matching key (more specific) for better accuracy.
        let match = densities
            .filter { n.contains($0.key) }
            .max(by: { $0.key.count < $1.key.count })
        return match?.gPerMl ?? 1.0
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
        let u = unit.lowercased().trimmingCharacters(in: .whitespaces)
        switch kind(of: u) {
        case .count:
            return (amount, unit)
        case .volume:
            let ml = amount * (mlPer[u] ?? 1.0)
            return system == .metric
                ? readableMetricVolume(ml)
                : readableUSVolume(ml)
        case .mass:
            let g = amount * (gPer[u] ?? 1.0)
            return system == .metric
                ? readableMetricMass(g)
                : readableUSMass(g)
        }
    }

    /// The headline cross-conversion: cups (volume) → grams (mass) for an ingredient.
    static func cupsToGrams(_ cups: Double, ingredient: String) -> Double {
        let ml = cups * (mlPer["cup"] ?? 236.588)
        return ml * density(for: ingredient)
    }

    /// grams → cups for an ingredient.
    static func gramsToCups(_ grams: Double, ingredient: String) -> Double {
        let ml = grams / density(for: ingredient)
        return ml / (mlPer["cup"] ?? 236.588)
    }

    // MARK: - Readable formatting
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

    private static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }
}
