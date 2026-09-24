import Foundation

/// Discovery rules, separate from inventory availability and dietary exclusion.
nonisolated enum PreparationDiscoveryPolicy {
    static func words(_ text: String) -> Set<String> {
        Set(FoodNameMatcher.tokens(text))
    }

    static func role(title: String, explicit: DishRole) -> DishRole {
        guard explicit == .unspecified else { return explicit }
        let tokens = words(title)
        if !tokens.isDisjoint(with: ["bowl", "taco", "sandwich", "wrap", "soup", "stew", "casserole", "pasta"]) { return .fullMeal }
        // A sauce or vegetable in a main's title does not make the main a side.
        if !tokens.isDisjoint(with: ["chicken", "wing", "beef", "steak", "pork", "salmon", "fish", "turkey", "shrimp", "tofu"]) { return .entree }
        if !tokens.isDisjoint(with: ["sauce", "dressing", "marinade", "glaze", "dip", "gravy", "topping"]) { return .component }
        if !tokens.isDisjoint(with: ["salad", "rice", "potato", "vegetable", "slaw", "bread", "roll", "side"]) { return .side }
        return .entree
    }

    static func additionRank(title: String, scope: AddSomethingScope?, usesExpiring: Bool) -> Int {
        let tokens = words(title)
        switch scope {
        case .somethingFresh: return tokens.isDisjoint(with: ["salad", "slaw", "cucumber", "fruit", "tomato"]) ? 1 : 0
        case .somethingFilling: return tokens.isDisjoint(with: ["potato", "rice", "bean", "bread", "lentil", "pasta"]) ? 1 : 0
        case .useSoonItems: return usesExpiring ? 0 : 1
        default: return 0
        }
    }

    static func accepts(title: String, ingredients: [String], explicitRole: DishRole,
                        anchor: String, intent: CookIntent, scope: AddSomethingScope?) -> Bool {
        let role = role(title: title, explicit: explicitRole)
        if intent == .addSomething {
            // Accompaniments need not contain the entrée's ingredient.
            switch scope {
            case .sauceOrTopping: return role == .component
            case .oneEasySide, .twoSides, .somethingFresh, .somethingFilling: return role == .side
            case .useSoonItems, .chooseForMe, nil: return role == .side || role == .component
            }
        }
        let anchorWords = words(anchor)
        let recipeWords = words(([title] + ingredients).joined(separator: " "))
        guard anchorWords.isSubset(of: recipeWords) else { return false }
        // An entrée is a valid foundation for a full meal, including wings.
        return intent != .buildFullMeal || role == .entree || role == .fullMeal || role == .side
    }
}

nonisolated enum CookDiscoveryTimePolicy {
    static func accepts(prep: String, cook: String, budget: String?) -> Bool {
        guard let budget, budget != "60+ min" else { return true }
        guard let limit = FinderDuration.minutes(budget),
              let prepMinutes = FinderDuration.minutes(prep),
              let cookMinutes = FinderDuration.minutes(cook) else { return false }
        return prepMinutes + cookMinutes <= limit
    }
}
