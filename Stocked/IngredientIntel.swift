// IngredientIntel.swift — contextual, offline ingredient smarts surfaced anywhere an ingredient
// line is shown. No manual entry: it parses the measure + name already on screen and offers
// predictive unit conversions and substitutions in a subtle menu (tap the ⇄ glyph, or long-press
// the row). Fully local + instant (reuses UnitConverter's density table) so there's no lag.

import SwiftUI
import UIKit

enum IngredientIntel {
    // Compact unit tables (own copy so target selection + formatting are fully controlled).
    static let mlPer: [String: Double] = [
        "tsp": 4.92892, "teaspoon": 4.92892, "teaspoons": 4.92892,
        "tbsp": 14.7868, "tablespoon": 14.7868, "tablespoons": 14.7868,
        "cup": 236.588, "cups": 236.588, "fl oz": 29.5735, "floz": 29.5735,
        "ml": 1, "milliliter": 1, "l": 1000, "liter": 1000, "litre": 1000,
        "pint": 473.176, "quart": 946.353, "gallon": 3785.41,
    ]
    static let gPer: [String: Double] = [
        "g": 1, "gram": 1, "grams": 1, "kg": 1000, "kilogram": 1000,
        "oz": 28.3495, "ounce": 28.3495, "ounces": 28.3495,
        "lb": 453.592, "lbs": 453.592, "pound": 453.592, "pounds": 453.592,
    ]
    // MARK: Parse a measure like "4 g", "1 1/2 cups", "½ tsp"
    //
    // Improvement #2 — delegates to `MeasureParser`. This used to be its own implementation with a
    // six-entry fraction table; it now inherits the full ⅛…⅞ set, two-token units ("fl oz"),
    // comma decimals and range handling. Signature unchanged.
    //
    // The returned unit is mapped back through this file's own `mlPer`/`gPer` tables because
    // `convertTargets` below keys off them directly.
    static func parseMeasure(_ s: String) -> (amount: Double?, unit: String) {
        let m = MeasureParser.parse(s)
        let unit = (mlPer[m.unit] != nil || gPer[m.unit] != nil) ? m.unit : ""
        return (m.amount, unit)
    }

    // MARK: Predictive conversions (2 sensible targets, formatted)
    static func convertTargets(measure: String, name: String) -> [String] {
        let (amt, unit) = parseMeasure(measure)
        guard let a = amt, !unit.isEmpty else { return [] }
        let dens = UnitConverter.density(for: name)
        if let ml = mlPer[unit] {                    // volume in → show weight + tidy volume
            let totalMl = a * ml
            return [fmtMass(totalMl * dens), fmtVol(totalMl)]
        } else if let g = gPer[unit] {               // mass in → show volume + other mass unit
            let totalG = a * g
            return [fmtVol(totalG / dens), fmtMassUS(totalG)]
        }
        return []
    }

    private static func fmtMass(_ g: Double) -> String { g >= 1000 ? "\(r1(g/1000)) kg" : "\(Int(g.rounded())) g" }
    private static func fmtMassUS(_ g: Double) -> String { g >= 453.592 ? "\(r1(g/453.592)) lb" : "\(r1(g/28.3495)) oz" }
    private static func fmtVol(_ ml: Double) -> String {
        let cups = ml / 236.588
        if cups >= 0.25 { return "\(r1(cups)) \(cups == 1 ? "cup" : "cups")" }
        let tbsp = ml / 14.7868
        if tbsp >= 1 { return "\(r1(tbsp)) tbsp" }
        return "\(r1(ml / 4.92892)) tsp"
    }
    private static func r1(_ x: Double) -> String {
        let v = (x * 10).rounded() / 10
        return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    }

    // MARK: Substitutions (compact local table; sub + ratio)
    private static let subs: [String: [(sub: String, ratio: String)]] = [
        "butter": [("olive oil", "¾ the amount"), ("coconut oil", "1:1"), ("applesauce", "1:1")],
        "egg": [("flax egg (1 tbsp flax + 3 tbsp water)", "per egg"), ("¼ cup applesauce", "per egg"), ("¼ cup mashed banana", "per egg")],
        "milk": [("almond milk", "1:1"), ("oat milk", "1:1"), ("soy milk", "1:1")],
        "buttermilk": [("milk + 1 tbsp lemon juice", "per cup")],
        "sugar": [("honey", "¾ the amount"), ("maple syrup", "¾ the amount")],
        "brown sugar": [("white sugar + 1 tbsp molasses", "per cup")],
        "flour": [("almond flour", "1:1"), ("oat flour", "1:1")],
        "sour cream": [("greek yogurt", "1:1")],
        "heavy cream": [("¾ cup milk + ¼ cup butter", "per cup"), ("coconut cream", "1:1")],
        "yogurt": [("sour cream", "1:1")],
        "vegetable oil": [("melted butter", "1:1"), ("applesauce", "1:1")],
        "cornstarch": [("2 tbsp flour", "per 1 tbsp")],
    ]
    static func substitutions(_ name: String) -> [(sub: String, ratio: String)] {
        let n = name.lowercased().trimmingCharacters(in: .whitespaces)
        if let exact = subs[n] { return exact }
        if let (_, list) = subs.first(where: { n.contains($0.key) || $0.key.contains(n) }) { return list }
        return []
    }

    /// Improvement #1 — asks the unified engine, not just this file's 12-entry table, so the ⇄
    /// affordance now appears on the ~73 ingredients the built-in database knows and on anything
    /// the user has added a swap for.
    static func hasActions(measure: String, name: String) -> Bool {
        if !convertTargets(measure: measure, name: name).isEmpty { return true }
        return !substitutions(name).isEmpty
            || StockedDatabase.shared.hasSubstitution(for: name)
    }

    /// Split a combined line ("4 g sugar", "1 1/2 cups flour") into (measure, name).
    static func split(_ line: String) -> (measure: String, name: String) {
        let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return ("", line) }
        func isNum(_ w: String) -> Bool {
            if Double(w) != nil { return true }
            if w.contains("/"), w.split(separator: "/").count == 2 { return true }
            if w.count == 1, "½¼¾⅓⅔⅛".contains(w) { return true }
            return false
        }
        var i = 0
        while i < words.count && isNum(words[i]) { i += 1 }
        let (_, unit) = parseMeasure(line)
        if i < words.count, !unit.isEmpty, words[i].lowercased().replacingOccurrences(of: ".", with: "") == unit { i += 1 }
        let name = words[i...].joined(separator: " ")
        return (words[0..<i].joined(separator: " "), name.isEmpty ? line : name)
    }
    static func hasActions(line: String) -> Bool { let s = split(line); return hasActions(measure: s.measure, name: s.name) }
}

extension IngredientActionsButton {
    /// Convenience for sites that only have a combined line string.
    init(line: String) { let s = IngredientIntel.split(line); self.init(measure: s.measure, name: s.name) }
}

extension View {
    /// Long-press a combined ingredient line ("4 g sugar") for conversions / substitutions.
    func ingredientQuickActions(line: String) -> some View {
        let s = IngredientIntel.split(line)
        return ingredientQuickActions(measure: s.measure, name: s.name)
    }
}

// MARK: - Shared menu content (used by both the tap-menu and the long-press context menu)

/// Improvement #1 — `userEntries` lets a call site pass the user's own swaps so they appear here
/// too, and they sort first. Defaulted to empty so existing call sites are unaffected.
@ViewBuilder
func ingredientQuickMenu(measure: String, name: String,
                         userEntries: [UserSubstitutionEntry] = []) -> some View {
    let conv = IngredientIntel.convertTargets(measure: measure, name: name)
    let subs = SubstitutionEngine.local(for: name, userEntries: userEntries)
    if !conv.isEmpty {
        Section("Convert") {
            ForEach(conv, id: \.self) { value in
                Button { UIPasteboard.general.string = value; HapticManager.light() } label: { Label(value, systemImage: "arrow.left.arrow.right") }
            }
        }
    }
    if !subs.isEmpty {
        Section("Substitute") {
            ForEach(subs.prefix(6)) { s in
                Button { UIPasteboard.general.string = s.substitute; HapticManager.light() } label: {
                    Text(s.detail.isEmpty ? s.substitute : "\(s.substitute) · \(s.detail)")
                }
            }
        }
    }
}

// MARK: - Subtle inline affordance (only appears when there's something to offer)

struct IngredientActionsButton: View {
    /// #1 — pulls the user's own saved swaps into the menu. Before this, a swap you added yourself
    /// only ever appeared on the Databases screen; here you'd see 12 hardcoded entries instead.
    @Environment(AppSession.self) private var session
    let measure: String
    let name: String
    var body: some View {
        if IngredientIntel.hasActions(measure: measure, name: name) {
            Menu {
                ingredientQuickMenu(measure: measure, name: name,
                                    userEntries: session.guestStore.userSubstitutions)
            } label: {
                Image(systemName: "arrow.left.arrow.right.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .fixedSize()
            .accessibilityLabel("Convert or substitute \(name)")
        }
    }
}

// MARK: - Attach long-press actions to any ingredient view (zero layout change)

private struct IngredientQuickActionsModifier: ViewModifier {
    let measure: String
    let name: String
    func body(content: Content) -> some View {
        if IngredientIntel.hasActions(measure: measure, name: name) {
            content.contextMenu { ingredientQuickMenu(measure: measure, name: name) }
        } else {
            content
        }
    }
}

extension View {
    /// Long-press an ingredient line to convert units / see substitutions (predictive, no typing).
    func ingredientQuickActions(measure: String, name: String) -> some View {
        modifier(IngredientQuickActionsModifier(measure: measure, name: name))
    }
}
