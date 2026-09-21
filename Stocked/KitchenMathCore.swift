import Foundation

/// Small, deterministic kitchen calculations. No inventory changes or provider requests.
nonisolated enum KitchenMathTool: String, CaseIterable, Identifiable, Codable, Sendable {
    case unitPrice, packages, pans, baker, hydration, ratio, yield, portions, batches, offers
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unitPrice: "Compare unit prices"
        case .packages: "Buy enough packages"
        case .pans: "Scale for a different pan"
        case .baker: "Baker’s percentages"
        case .hydration: "Adjust dough hydration"
        case .ratio: "Scale an ingredient ratio"
        case .yield: "Allow for trimming"
        case .portions: "Pack portions"
        case .batches: "Plan batch timing"
        case .offers: "Check a shopping offer"
        }
    }
    var subtitle: String {
        switch self {
        case .unitPrice: "Compare different package sizes in the same unit."
        case .packages: "Round up packs and see the amount left over."
        case .pans: "Use pan dimensions to find a batter multiplier."
        case .baker: "Express water, salt and other ingredients against flour."
        case .hydration: "Find the flour or water to add to reach your target."
        case .ratio: "Keep a two-ingredient proportion when scaling."
        case .yield: "Buy enough produce after peel, cores and trimming."
        case .portions: "Divide a cooked batch into servings and containers."
        case .batches: "Count rounds, turnaround time and total minutes."
        case .offers: "Apply a percentage offer, coupon and tax in order."
        }
    }
    var icon: String {
        switch self {
        case .unitPrice: "tag"
        case .packages: "shippingbox"
        case .pans: "rectangle.on.rectangle"
        case .baker: "percent"
        case .hydration: "drop"
        case .ratio: "scalemass"
        case .yield: "carrot"
        case .portions: "square.stack.3d.up"
        case .batches: "clock"
        case .offers: "receipt"
        }
    }
    var usesCurrency: Bool { self == .unitPrice || self == .packages || self == .offers }
    var fields: [KitchenMathField] {
        switch self {
        case .unitPrice:
            [field("aPrice", "Package A price", "money", 4.50, zero: true), field("aSize", "Package A size", "same unit", 500),
             field("bPrice", "Package B price", "money", 6, zero: true), field("bSize", "Package B size", "same unit", 750)]
        case .packages:
            [field("need", "Amount needed", "same unit", 1200), field("size", "Amount per package", "same unit", 500),
             field("price", "Price per package", "money", 3.50, zero: true)]
        case .pans:
            [field("aLength", "Original length or diameter", "same unit", 9), field("aWidth", "Original width", "same unit", 9),
             field("aDepth", "Original batter depth", "same unit", 2), field("bLength", "New length or diameter", "same unit", 10),
             field("bWidth", "New width", "same unit", 10), field("bDepth", "New batter depth", "same unit", 2)]
        case .baker:
            [field("flour", "Total flour", "g", 500), field("water", "Water", "g", 325, zero: true),
             field("salt", "Salt", "g", 10, zero: true), field("yeast", "Yeast", "g", 5, zero: true),
             field("fat", "Fat", "g", 20, zero: true), field("sugar", "Sugar", "g", 15, zero: true)]
        case .hydration:
            [field("flour", "Current flour", "g", 500), field("water", "Current water", "g", 300, zero: true),
             field("target", "Target hydration", "%", 70, maximum: 300)]
        case .ratio:
            [field("base", "Original base ingredient", "same unit", 300), field("other", "Original second ingredient", "same unit", 200, zero: true),
             field("newBase", "New base ingredient", "same unit", 450)]
        case .yield:
            [field("need", "Usable amount needed", "g", 800), field("loss", "Estimated trim loss", "%", 20, zero: true, maximum: 99.9)]
        case .portions:
            [field("batch", "Cooked batch weight", "g", 1800), field("portion", "Weight per serving", "g", 250),
             field("perBox", "Servings per container", "servings", 2, whole: true)]
        case .batches:
            [field("items", "Items to make", "items", 40, whole: true), field("capacity", "Items per tray or batch", "items", 12, whole: true),
             field("parallel", "Trays or batches at once", "batches", 2, whole: true), field("minutes", "Minutes per round", "min", 18),
             field("turnaround", "Minutes between rounds", "min", 3, zero: true)]
        case .offers:
            [field("price", "Shelf total before tax", "money", 45), field("discount", "Percentage discount", "%", 20, zero: true, maximum: 100),
             field("coupon", "Coupon after discount", "money", 5, zero: true), field("tax", "Tax on discounted subtotal", "%", 8.25, zero: true, maximum: 100)]
        }
    }
    private func field(_ id: String, _ title: String, _ unit: String, _ example: Double,
                       zero: Bool = false, maximum: Double = 1_000_000, whole: Bool = false) -> KitchenMathField {
        KitchenMathField(id: id, title: title, unit: unit, example: example, allowsZero: zero, maximum: maximum, whole: whole)
    }
    func visibleFields(originalRound: Bool, replacementRound: Bool) -> [KitchenMathField] {
        fields.filter { !(self == .pans && (($0.id == "aWidth" && originalRound) || ($0.id == "bWidth" && replacementRound))) }
    }
    var guidance: String {
        switch self {
        case .unitPrice: "Use the same currency and quantity unit for both packages. Compare like-for-like products and usable amounts; membership conditions are separate."
        case .packages: "Use matching quantity units. This estimates whole packages; it does not add anything to your grocery list. Enter zero if a price is unknown."
        case .pans: "Measure the inside of both pans in the same unit. Batter depth is the intended fill level, not the pan’s full height. Shape and depth affect cooking: this does not calculate a new baking time."
        case .baker: "Enter weights in grams. Flour is always 100%. Include starter flour and water in their respective totals; water from other ingredients is not inferred."
        case .hydration: "Enter total flour and water by weight, including any starter. The result adds one ingredient; it never asks you to remove mixed dough. Other ingredients’ water is not inferred."
        case .ratio: "Keep the same measurement unit for each ingredient before and after scaling. This preserves a ratio; it does not infer cooking time or safe preservation formulas."
        case .yield: "Trim loss is your estimate, not a food database value. A 20% loss leaves 80% usable. This rounds the buying amount up to the next gram."
        case .portions: "Use the finished cooked weight. Full servings are packed first; a smaller remainder gets its own container. Container capacity is a planning estimate."
        case .batches: "One round runs all parallel trays or batches together. Include preheating or preparation separately. Times are planning estimates; check the recipe’s doneness guidance."
        case .offers: "Assumes a percentage discount first, then a fixed coupon, then tax. Stores may apply exclusions, tax and rounding differently. A coupon cannot make the subtotal negative."
        }
    }
}

nonisolated struct KitchenMathField: Identifiable, Sendable {
    let id: String
    let title: String
    let unit: String
    let example: Double
    let allowsZero: Bool
    let maximum: Double
    let whole: Bool
    func problem(_ value: Double?) -> String? {
        guard let value, value.isFinite else { return "Enter a complete number." }
        guard value >= 0, allowsZero || value > 0 else { return allowsZero ? "Use zero or a positive amount." : "Use an amount greater than zero." }
        guard value <= maximum else { return "Use an amount no greater than \(KitchenMathCore.number(maximum))." }
        if whole && value != value.rounded() { return "Use a whole number." }
        return nil
    }
}

nonisolated struct KitchenMathOutput: Identifiable, Sendable {
    var id: String { label }
    let label: String
    let value: Double
    let unit: String
    var decimals: Int = 2
}

nonisolated struct KitchenMathResult: Sendable {
    let summary: String
    let outputs: [KitchenMathOutput]
    let formula: String
}

nonisolated enum KitchenMathCore {
    /// Strict parsing prevents NumberFormatter accepting a valid prefix from "12abc".
    /// Grouping separators are intentionally rejected to avoid ambiguous pasted quantities.
    static func parse(_ raw: String, locale: Locale = .current) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 32 else { return nil }
        let separator = locale.decimalSeparator ?? "."
        guard separator == "." || !trimmed.contains(".") else { return nil }
        let normalized = trimmed.replacingOccurrences(of: separator, with: ".").map { character -> String in
            if character.unicodeScalars.allSatisfy({ CharacterSet.decimalDigits.contains($0) }),
               let digit = character.wholeNumberValue { return String(digit) }
            return String(character)
        }.joined()
        guard normalized.range(of: "^[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil,
              let value = Double(normalized), value.isFinite else { return nil }
        return value
    }
    static func number(_ value: Double, decimals: Int = 2, locale: Locale = .current) -> String {
        if value != 0, abs(value) < pow(10, -Double(decimals)) {
            return value.formatted(.number.locale(locale).notation(.scientific).precision(.significantDigits(1...4)))
        }
        return value.formatted(.number.locale(locale).precision(.fractionLength(0...decimals)))
    }
    static func input(_ value: Double, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale).grouping(.never).precision(.fractionLength(0...4)))
    }
    /// Decimal measurements such as 0.07/0.01 can land a few ULPs past an integer.
    /// Correct only machine-rounding noise; never round a meaningful partial pack down.
    private static func wholeCount(_ quotient: Double, rounding: FloatingPointRoundingRule) -> Double {
        let nearest = quotient.rounded()
        if abs(quotient - nearest) <= max(quotient.ulp, nearest.ulp) * 8 { return nearest }
        return quotient.rounded(rounding)
    }
    static func evaluate(_ tool: KitchenMathTool, values: [String: Double], originalRound: Bool = false,
                         replacementRound: Bool = false) -> KitchenMathResult? {
        let fields = tool.visibleFields(originalRound: originalRound, replacementRound: replacementRound)
        guard fields.allSatisfy({ $0.problem(values[$0.id]) == nil }) else { return nil }
        func n(_ key: String) -> Double { values[key] ?? 0 }
        func row(_ title: String, _ value: Double, _ unit: String, _ decimals: Int = 2) -> KitchenMathOutput {
            KitchenMathOutput(label: title, value: value, unit: unit, decimals: decimals)
        }
        let result: KitchenMathResult
        switch tool {
        case .unitPrice:
            let a = n("aPrice") / n("aSize"), b = n("bPrice") / n("bSize")
            let tied = abs(a - b) <= max(a, b) * 1e-10
            result = .init(summary: tied ? "The unit prices match." : "Package \(a < b ? "A" : "B") costs less per unit.",
                outputs: [row("Package A, per 100 units", a * 100, "money", 4), row("Package B, per 100 units", b * 100, "money", 4),
                          row("Saving versus the higher unit price", tied ? 0 : (1 - min(a, b) / max(a, b)) * 100, "%")],
                formula: "Unit price = package price ÷ package size. Savings compare equal quantities.")
        case .packages:
            let packs = wholeCount(n("need") / n("size"), rounding: .up)
            result = .init(summary: "Buy \(number(packs, decimals: 0)) whole \(packs == 1 ? "package" : "packages").",
                outputs: [row("Packages", packs, "", 0), row("Total amount", packs * n("size"), "units"),
                          row("Left over", max(0, packs * n("size") - n("need")), "units"), row("Estimated total", packs * n("price"), "money")],
                formula: "Packages = amount needed ÷ amount per package, rounded up. A zero price means cost is unknown.")
        case .pans:
            func area(_ prefix: String, _ round: Bool) -> Double {
                round ? Double.pi * pow(n(prefix + "Length") / 2, 2) : n(prefix + "Length") * n(prefix + "Width")
            }
            let factor = area("b", replacementRound) * n("bDepth") / (area("a", originalRound) * n("aDepth"))
            result = .init(summary: "Multiply ingredient amounts by \(number(factor, decimals: 3)).",
                outputs: [row("Recipe multiplier", factor, "×", 3), row("Original recipe amount", factor * 100, "%")],
                formula: "Multiplier = new batter volume ÷ original batter volume. Round area = π × (diameter ÷ 2)²; rectangular area = length × width.")
        case .baker:
            let keys = ["water", "salt", "yeast", "fat", "sugar"]
            let names = ["Water", "Salt", "Yeast", "Fat", "Sugar"]
            let rows = zip(keys, names).map { row($0.1, n($0.0) / n("flour") * 100, "%") }
            result = .init(summary: "Flour is the 100% reference.",
                outputs: [row("Flour", 100, "%")] + rows + [row("Total dough weight", n("flour") + keys.reduce(0) { $0 + n($1) }, "g")],
                formula: "Each baker’s percentage = ingredient weight ÷ total flour weight × 100.")
        case .hydration:
            let current = n("water") / n("flour") * 100
            let addWater = max(0, n("flour") * n("target") / 100 - n("water"))
            let addFlour = max(0, n("water") * 100 / n("target") - n("flour"))
            result = .init(summary: abs(current - n("target")) < 1e-9 ? "Your dough already meets the target." : "Add \(number(addWater > 0 ? addWater : addFlour)) g of \(addWater > 0 ? "water" : "flour").",
                outputs: [row("Current hydration", current, "%"), row("Target hydration", n("target"), "%"),
                          row("Water to add", addWater, "g"), row("Flour to add", addFlour, "g")],
                formula: "Hydration = water weight ÷ flour weight × 100. Add water for a higher target or flour for a lower target.")
        case .ratio:
            let factor = n("newBase") / n("base")
            result = .init(summary: "Use \(number(n("other") * factor)) units of the second ingredient.",
                outputs: [row("Multiplier", factor, "×", 3), row("New base ingredient", n("newBase"), "units"),
                          row("New second ingredient", n("other") * factor, "units")],
                formula: "Multiplier = new base amount ÷ original base amount. Multiply the other ingredient by the same factor.")
        case .yield:
            let buy = wholeCount(n("need") / (1 - n("loss") / 100), rounding: .up)
            result = .init(summary: "Buy approximately \(number(buy, decimals: 0)) g before trimming.",
                outputs: [row("Buying weight", buy, "g", 0), row("Usable amount needed", n("need"), "g"),
                          row("Estimated trimming", buy * n("loss") / 100, "g")],
                formula: "Buying weight = usable amount ÷ (1 − trim loss ÷ 100), rounded up to a whole gram.")
        case .portions:
            let servings = wholeCount(n("batch") / n("portion"), rounding: .down)
            let difference = n("batch") - servings * n("portion")
            let remainder = abs(difference) <= n("batch").ulp * 8 ? 0 : max(0, difference)
            let fullContainers = ceil(servings / n("perBox"))
            result = .init(summary: "\(number(servings, decimals: 0)) full \(servings == 1 ? "serving" : "servings")\(remainder > 0 ? " plus a smaller remainder" : "").",
                outputs: [row("Full servings", servings, "", 0), row("Remainder", remainder, "g"),
                          row("Containers for full servings", fullContainers, "", 0), row("Total containers including remainder", fullContainers + (remainder > 0 ? 1 : 0), "", 0)],
                formula: "Full servings round down. Full-serving containers round up. Any smaller remainder has its own container.")
        case .batches:
            let batches = ceil(n("items") / n("capacity")), rounds = ceil(batches / n("parallel"))
            let elapsed = rounds * n("minutes") + max(0, rounds - 1) * n("turnaround")
            result = .init(summary: "Allow \(number(elapsed)) minutes after preparation.",
                outputs: [row("Trays or batches", batches, "", 0), row("Sequential rounds", rounds, "", 0),
                          row("Cooking time", rounds * n("minutes"), "min"), row("Turnaround time", max(0, rounds - 1) * n("turnaround"), "min"),
                          row("Total time", elapsed, "min")],
                formula: "Rounds = batches ÷ simultaneous capacity, rounded up. Total = rounds × minutes + gaps × turnaround.")
        case .offers:
            let discount = n("price") * n("discount") / 100
            let coupon = min(n("coupon"), max(0, n("price") - discount))
            let subtotal = max(0, n("price") - discount - coupon), tax = subtotal * n("tax") / 100
            result = .init(summary: "Estimated checkout total: \(number(subtotal + tax)).",
                outputs: [row("Percentage discount", discount, "money"), row("Coupon applied", coupon, "money"),
                          row("Discounted subtotal", subtotal, "money"), row("Estimated tax", tax, "money"),
                          row("Estimated total", subtotal + tax, "money"), row("Saving versus full price with tax", n("price") * (1 + n("tax") / 100) - subtotal - tax, "money")],
                formula: "Subtotal = max(0, shelf price × (1 − discount ÷ 100) − coupon). Tax applies to this subtotal; store rounding may differ.")
        }
        guard result.outputs.allSatisfy({ $0.value.isFinite && abs($0.value) <= 1e12 }) else { return nil }
        return result
    }
}
