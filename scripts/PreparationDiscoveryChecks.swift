import Foundation
@main struct PreparationDiscoveryChecks {
    static func main() {
        var count = 0
        func check(_ value: Bool, _ message: String) { count += 1; precondition(value, message) }
        func accepts(_ title: String, _ intent: CookIntent, role: DishRole = .unspecified,
                     scope: AddSomethingScope? = nil, anchor: String = "Chicken wings") -> Bool {
            PreparationDiscoveryPolicy.accepts(title: title, ingredients: ["chicken wings", "salt", "pepper"],
                explicitRole: role, anchor: anchor, intent: intent, scope: scope)
        }
        for intent in CookIntent.allCases where intent != .addSomething {
            check(accepts("Crispy Chicken Wings", intent), "Wings disappear for \(intent)")
            check(!accepts("Crispy Chicken Wings", intent, anchor: "salmon"), "Unrelated anchor matched")
        }
        check(PreparationDiscoveryPolicy.accepts(title: "Roasted Potatoes", ingredients: ["potatoes", "oil", "salt"],
            explicitRole: .unspecified, anchor: "Potato", intent: .buildFullMeal, scope: nil), "Vegetable foundation excluded")
        check(PreparationDiscoveryPolicy.accepts(title: "Steamed Rice", ingredients: ["rice", "water", "salt"],
            explicitRole: .side, anchor: "Rice", intent: .buildFullMeal, scope: nil), "Rice foundation excluded")
        check(accepts("Buffalo Sauce Chicken Wings", .buildFullMeal), "Sauce word hides an entrée")
        check(accepts("Chicken Wing Dinner Bowl", .buildFullMeal), "Meal excluded")
        check(!accepts("Chicken Wing Dip", .buildFullMeal, role: .component), "Explicit component becomes main")
        for scope in AddSomethingScope.allCases {
            let expectedRole: DishRole = scope == .sauceOrTopping ? .component : .side
            check(PreparationDiscoveryPolicy.accepts(title: "Simple accompaniment", ingredients: ["rice", "water", "salt"],
                explicitRole: expectedRole, anchor: "Chicken wings", intent: .addSomething, scope: scope), "Side unnecessarily requires chicken: \(scope)")
            check(!accepts("Chicken Wings", .addSomething, role: .entree, scope: scope), "Entrée offered as side")
        }
        check(PreparationDiscoveryPolicy.words("Fresh scallions") == PreparationDiscoveryPolicy.words("green onions"), "Shared food synonyms retained")
        check(PreparationDiscoveryPolicy.words("CHICKEN-wing").isSubset(of: PreparationDiscoveryPolicy.words("Chicken wings")), "Case/hyphen/plural")
        check(PreparationDiscoveryPolicy.words("potatoes") == PreparationDiscoveryPolicy.words("potato"), "Potato plural")
        check(!PreparationDiscoveryPolicy.words("ham").isSubset(of: PreparationDiscoveryPolicy.words("hamburger")), "Substring false match")
        check(PreparationDiscoveryPolicy.role(title: "Rice Bowl", explicit: .unspecified) == .fullMeal, "Meal precedence")
        check(PreparationDiscoveryPolicy.role(title: "Garlic Bread", explicit: .unspecified) == .side, "Side inference")
        check(PreparationDiscoveryPolicy.role(title: "Yogurt Dressing", explicit: .unspecified) == .component, "Sauce inference")
        check(PreparationDiscoveryPolicy.additionRank(title: "Cucumber Salad", scope: .somethingFresh, usesExpiring: false) == 0, "Fresh ranking")
        check(PreparationDiscoveryPolicy.additionRank(title: "Rice", scope: .somethingFilling, usesExpiring: false) == 0, "Filling ranking")
        check(PreparationDiscoveryPolicy.additionRank(title: "Any side", scope: .useSoonItems, usesExpiring: true) == 0, "Use soon ranking")
        check(CookDiscoveryTimePolicy.accepts(prep: "5 min", cook: "10 min", budget: "15 min"), "Exact time fits")
        check(!CookDiscoveryTimePolicy.accepts(prep: "10 min", cook: "10 min", budget: "15 min"), "Prep counts toward budget")
        check(!CookDiscoveryTimePolicy.accepts(prep: "", cook: "10 min", budget: "30 min"), "Unknown prep cannot promise deadline")
        check(CookDiscoveryTimePolicy.accepts(prep: "", cook: "", budget: nil), "Unrestricted unknown times retained")
        check(CookDiscoveryTimePolicy.accepts(prep: "30 min", cook: "90 min", budget: "60+ min"), "Open-ended time")
        print("PASS: \(count) preparation checks across all seven intents and seven addition scopes")
    }
}
