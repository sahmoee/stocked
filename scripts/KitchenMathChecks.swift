// Run without a simulator:
// xcrun swiftc Stocked/KitchenMathCore.swift scripts/KitchenMathChecks.swift -o /tmp/stocked-kitchen-math-checks
import Foundation

@main struct KitchenMathChecks {
    static func main() {
        var count = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            count += 1; precondition(value(), "FAILED: \(message)")
        }
        func output(_ result: KitchenMathResult?, _ label: String) -> Double {
            result!.outputs.first(where: { $0.label == label })!.value
        }
        func near(_ value: Double, _ expected: Double) -> Bool { abs(value - expected) < 0.000001 }
        let us = Locale(identifier: "en_US"), de = Locale(identifier: "de_DE")
        check(KitchenMathCore.parse("12.5", locale: us) == 12.5, "Decimal point")
        check(KitchenMathCore.parse("12,5", locale: de) == 12.5, "Locale decimal comma")
        check(KitchenMathCore.parse("1.200", locale: de) == nil, "Reject ambiguous local grouping separator")
        let arabic = Locale(identifier: "ar_EG")
        check(KitchenMathCore.parse(KitchenMathCore.input(12.5, locale: arabic), locale: arabic) == 12.5, "Localized decimal digits round trip")
        check(KitchenMathCore.parse(" 12.5 \n", locale: us) == 12.5, "Surrounding whitespace")
        for value in ["", "12abc", "NaN", "inf", "-1", "1e4", "1,200", ".", "3.4.5", "1.", "1 200"] {
            check(KitchenMathCore.parse(value, locale: us) == nil, "Reject incomplete/ambiguous \(value)")
        }
        check(KitchenMathCore.parse(String(repeating: "1", count: 33), locale: us) == nil, "Input bound")
        check(KitchenMathCore.number(0.00001, locale: us) != "0", "Small nonzero results never display as zero")
        for tool in KitchenMathTool.allCases {
            let example = Dictionary(uniqueKeysWithValues: tool.fields.map { ($0.id, $0.example) })
            check(KitchenMathCore.evaluate(tool, values: example) != nil, "Valid example: \(tool)")
            check(KitchenMathCore.evaluate(tool, values: [:]) == nil, "Missing fields: \(tool)")
            for field in tool.fields {
                var invalid = example; invalid[field.id] = .infinity
                check(KitchenMathCore.evaluate(tool, values: invalid) == nil, "Nonfinite \(tool).\(field.id)")
                invalid[field.id] = field.maximum + 1
                check(KitchenMathCore.evaluate(tool, values: invalid) == nil, "Upper bound \(tool).\(field.id)")
                invalid[field.id] = -1
                check(KitchenMathCore.evaluate(tool, values: invalid) == nil, "Negative \(tool).\(field.id)")
            }
        }
        let price = KitchenMathCore.evaluate(.unitPrice, values: ["aPrice": 4.5, "aSize": 500, "bPrice": 6, "bSize": 750])
        check(near(output(price, "Package A, per 100 units"), 0.9), "Price normalization A")
        check(near(output(price, "Package B, per 100 units"), 0.8), "Price normalization B")
        check(near(output(price, "Saving versus the higher unit price"), 100 / 9), "Equal quantity savings")
        let tie = KitchenMathCore.evaluate(.unitPrice, values: ["aPrice": 2, "aSize": 200, "bPrice": 5, "bSize": 500])
        check(output(tie, "Saving versus the higher unit price") == 0, "Equal unit prices")
        let packs = KitchenMathCore.evaluate(.packages, values: ["need": 1200, "size": 500, "price": 3.5])
        check(output(packs, "Packages") == 3 && output(packs, "Left over") == 300, "Whole package rounding")
        check(output(packs, "Estimated total") == 10.5, "Package cost")
        let decimalPacks = KitchenMathCore.evaluate(.packages, values: ["need": 0.07, "size": 0.01, "price": 3.5])
        check(output(decimalPacks, "Packages") == 7, "Decimal precision does not add a spurious pack")
        let decimalPortions = KitchenMathCore.evaluate(.portions, values: ["batch": 0.3, "portion": 0.1, "perBox": 2])
        check(output(decimalPortions, "Full servings") == 3 && output(decimalPortions, "Remainder") == 0, "Decimal precision preserves whole portions")
        let zeroPrices = KitchenMathCore.evaluate(.unitPrice, values: ["aPrice": 0, "aSize": 100, "bPrice": 0, "bSize": 200])
        check(output(zeroPrices, "Saving versus the higher unit price") == 0, "Free prices compare without division by zero")
        let pan = KitchenMathCore.evaluate(.pans, values: ["aLength": 9, "aDepth": 2, "bLength": 9, "bWidth": 9, "bDepth": 2], originalRound: true)
        check(near(output(pan, "Recipe multiplier"), 4 / Double.pi), "Round to square pan")
        let doubledDepth = KitchenMathCore.evaluate(.pans, values: ["aLength": 9, "aDepth": 1, "bLength": 9, "bDepth": 2], originalRound: true, replacementRound: true)
        check(output(doubledDepth, "Recipe multiplier") == 2, "Batter depth matters")
        let baker = KitchenMathCore.evaluate(.baker, values: ["flour": 500, "water": 325, "salt": 10, "yeast": 5, "fat": 20, "sugar": 15])
        check(output(baker, "Water") == 65 && output(baker, "Salt") == 2, "Baker percentages")
        check(output(baker, "Total dough weight") == 875, "Dough weight")
        let wetter = KitchenMathCore.evaluate(.hydration, values: ["flour": 500, "water": 300, "target": 70])
        check(output(wetter, "Water to add") == 50 && output(wetter, "Flour to add") == 0, "Raise hydration")
        let drier = KitchenMathCore.evaluate(.hydration, values: ["flour": 500, "water": 350, "target": 50])
        check(output(drier, "Flour to add") == 200 && output(drier, "Water to add") == 0, "Lower hydration without removing dough")
        check(KitchenMathCore.evaluate(.hydration, values: ["flour": 500, "water": 300, "target": 0]) == nil, "Reject zero hydration divisor")
        let ratio = KitchenMathCore.evaluate(.ratio, values: ["base": 300, "other": 200, "newBase": 450])
        check(output(ratio, "New second ingredient") == 300, "Ratio scaling")
        let trim = KitchenMathCore.evaluate(.yield, values: ["need": 800, "loss": 20])
        check(output(trim, "Buying weight") == 1000, "Yield inversion")
        check(KitchenMathCore.evaluate(.yield, values: ["need": 800, "loss": 100]) == nil, "Reject total loss")
        let portions = KitchenMathCore.evaluate(.portions, values: ["batch": 1800, "portion": 250, "perBox": 2])
        check(output(portions, "Full servings") == 7 && output(portions, "Remainder") == 50, "Portion remainder")
        check(output(portions, "Total containers including remainder") == 5, "Separate remainder container")
        let small = KitchenMathCore.evaluate(.portions, values: ["batch": 50, "portion": 250, "perBox": 2])
        check(output(small, "Full servings") == 0 && output(small, "Total containers including remainder") == 1, "Small batch")
        let timing = KitchenMathCore.evaluate(.batches, values: ["items": 40, "capacity": 12, "parallel": 2, "minutes": 18, "turnaround": 3])
        check(output(timing, "Total time") == 39, "Parallel rounds with turnaround")
        let one = KitchenMathCore.evaluate(.batches, values: ["items": 12, "capacity": 12, "parallel": 2, "minutes": 18, "turnaround": 3])
        check(output(one, "Total time") == 18, "No trailing turnaround")
        check(KitchenMathCore.evaluate(.batches, values: ["items": 1.5, "capacity": 12, "parallel": 2, "minutes": 18, "turnaround": 3]) == nil, "Whole count required")
        let offer = KitchenMathCore.evaluate(.offers, values: ["price": 45, "discount": 20, "coupon": 5, "tax": 8.25])
        check(near(output(offer, "Estimated total"), 33.5575), "Offer order and tax")
        let free = KitchenMathCore.evaluate(.offers, values: ["price": 10, "discount": 50, "coupon": 100, "tax": 10])
        check(output(free, "Estimated total") == 0 && output(free, "Coupon applied") == 5, "Coupon capped")
        print("Kitchen Math: \(count) checks passed")
    }
}
