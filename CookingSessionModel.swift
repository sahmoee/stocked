// CookingSessionModel.swift
// ─────────────────────────────────────────────────────────────────
// The shared vocabulary for the adaptive cooking workspace. Every Cook Now
// surface — Start With Something, intent selection, method comparison,
// Before You Start, hands-off orchestration, Cook Ahead, Finish & Serve —
// speaks these types so they stay consistent and the session can represent
// anything from "one ingredient prepared" to "a full meal cooked ahead".
//
// Design stance (from the spec):
//   • Cooking is NOT synonymous with making a complete meal. Every enum here
//     has first-class support for single-component and partial sessions.
//   • Nothing is required. A session with no meal ID, no sides, and one
//     completed entrée is a fully valid, successful session.
//   • These are pure value types (nonisolated, Codable, Sendable) so they can
//     live in snapshots, cross actors, and drive previews/tests freely.
// ─────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Source of the session

/// Where a cooking session originated. The anchor may be a raw ingredient, a
/// planned meal, a saved/online recipe, a leftover, or just an idea the user
/// typed — none of which should force a full-recipe workflow.
nonisolated enum CookSessionSource: String, Codable, Sendable, CaseIterable {
    case inventoryItem      // "Start With Something" from the pantry
    case plannedMeal        // opened from the meal planner / calendar
    case savedRecipe        // from the user's recipe vault
    case onlineRecipe       // from browse / online
    case leftover           // cooked food already on hand
    case userIdea           // free-typed "I already know what I'm making"
    case expiringIngredient // use-it-up entry
    case previouslyCooked   // re-cook of a past meal

    var label: String {
        switch self {
        case .inventoryItem:      return "From your kitchen"
        case .plannedMeal:        return "From your plan"
        case .savedRecipe:        return "Saved recipe"
        case .onlineRecipe:       return "Online recipe"
        case .leftover:           return "Leftover"
        case .userIdea:           return "Your idea"
        case .expiringIngredient: return "Use it up"
        case .previouslyCooked:   return "Cooked before"
        }
    }
}

// MARK: - Intent (what the user wants to DO with the anchor)

/// The seven Cook Now intents. Selected AFTER an anchor item is chosen so the
/// workspace can scope everything downstream to the user's real goal.
nonisolated enum CookIntent: String, Codable, Sendable, CaseIterable, Identifiable {
    case justMakeThis      // a good way to prepare one item; no sides implied
    case addSomething      // add one or two things without a full-meal process
    case buildFullMeal     // a complete meal around the item
    case trySomethingNew   // variety: new cuisines, techniques, flavors
    case useWhatIHave      // prioritize the most makeable ideas
    case useItUp           // build around expiring / open / leftover items
    case alreadyKnowPlan   // skip discovery, go straight to prep + execution

    var id: String { rawValue }

    var title: String {
        switch self {
        case .justMakeThis:    return "Just Make This"
        case .addSomething:    return "Add Something"
        case .buildFullMeal:   return "Build a Full Meal"
        case .trySomethingNew: return "Try Something New"
        case .useWhatIHave:    return "Use What I Have"
        case .useItUp:         return "Use It Up"
        case .alreadyKnowPlan: return "I Already Know What I'm Making"
        }
    }

    var blurb: String {
        switch self {
        case .justMakeThis:    return "A good way to prepare this. No sides or full meal required."
        case .addSomething:    return "Add one or two things without a complicated meal."
        case .buildFullMeal:   return "Create a complete meal around this item."
        case .trySomethingNew: return "Preparations, cuisines, and techniques you don't usually use."
        case .useWhatIHave:    return "Prioritize ideas you can make right now."
        case .useItUp:         return "Build around what's expiring, open, or taking up space."
        case .alreadyKnowPlan: return "Skip discovery. Help me prep and cook it."
        }
    }

    var icon: String {
        switch self {
        case .justMakeThis:    return "frying.pan"
        case .addSomething:    return "plus.circle"
        case .buildFullMeal:   return "fork.knife"
        case .trySomethingNew: return "sparkles"
        case .useWhatIHave:    return "checkmark.circle"
        case .useItUp:         return "clock.badge.exclamationmark"
        case .alreadyKnowPlan: return "hand.raised"
        }
    }

    /// Intents that skip standalone-preparation discovery entirely.
    var skipsDiscovery: Bool { self == .alreadyKnowPlan }
}

/// How much additional effort under "Add Something" — keeps the add-on scoped.
nonisolated enum AddSomethingScope: String, Codable, Sendable, CaseIterable, Identifiable {
    case oneEasySide, twoSides, somethingFresh, somethingFilling, sauceOrTopping, useSoonItems, chooseForMe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .oneEasySide:     return "One easy side"
        case .twoSides:        return "Two sides"
        case .somethingFresh:  return "Something fresh"
        case .somethingFilling:return "Something filling"
        case .sauceOrTopping:  return "A sauce or topping"
        case .useSoonItems:    return "Use what needs to be used"
        case .chooseForMe:     return "Choose for me"
        }
    }
}

// MARK: - Effort level

/// The user's current energy. Affects appliance count, dish count, chopping,
/// component count, and whether sides/full meals are even suggested. The app
/// never pressures toward a bigger cook.
nonisolated enum CookEffortLevel: String, Codable, Sendable, CaseIterable, Identifiable {
    case bareMinimum, low, normal, haveEnergy, letMeCook, surpriseMe
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bareMinimum: return "Bare minimum"
        case .low:         return "Low effort"
        case .normal:      return "Normal"
        case .haveEnergy:  return "I have energy"
        case .letMeCook:   return "Let me cook"
        case .surpriseMe:  return "Surprise me"
        }
    }
    /// Rough ceiling on suggested extra components at this effort.
    var suggestedComponentCeiling: Int {
        switch self {
        case .bareMinimum: return 0
        case .low:         return 1
        case .normal:      return 2
        case .haveEnergy:  return 3
        case .letMeCook:   return 4
        case .surpriseMe:  return 3
        }
    }
    /// Whether compounding/overlap prep should be offered (bare minimum: never).
    var allowsCompounding: Bool { self != .bareMinimum }
}

// MARK: - Dish role (standalone vs full-meal distinction in the data model)

/// The role a preparation plays. This is what lets a chicken search return
/// standalone chicken preparations instead of only complete chicken dinners.
/// Additive + decode-safe on UserRecipe (old recipes decode as `.unspecified`).
nonisolated enum DishRole: String, Codable, Sendable, CaseIterable {
    case entree        // a standalone main / protein preparation
    case side          // a side dish
    case component     // a sauce, base, or building block for something else
    case fullMeal      // a complete meal (protein + sides, bowl, one-pot, etc.)
    case unspecified   // legacy / unknown

    var label: String {
        switch self {
        case .entree:      return "Entrée"
        case .side:        return "Side"
        case .component:   return "Component"
        case .fullMeal:    return "Full meal"
        case .unspecified: return "Recipe"
        }
    }
    /// Whether this preparation stands alone (no sides implied).
    var isStandalone: Bool { self == .entree || self == .side || self == .component }
}

// MARK: - Makeability (superset of the readiness tiers, for the workspace)

/// The expanded makeability buckets the workspace browses by. Readiness of a
/// specific recipe still comes from CookNowEngine; these are the catalog-level
/// categories the "Makeable Now" hub organizes.
nonisolated enum MakeabilityCategory: String, Codable, Sendable, CaseIterable, Identifiable {
    case entrees, proteins, sides, components, sauces, meals
    case almost, withSubstitution, useSoon, plannedLater
    case alreadyPrepped, marinating, cookedReadyToReheat
    var id: String { rawValue }
    var title: String {
        switch self {
        case .entrees:            return "Makeable Entrées"
        case .proteins:           return "Makeable Proteins"
        case .sides:              return "Makeable Sides"
        case .components:         return "Makeable Components"
        case .sauces:             return "Makeable Sauces"
        case .meals:              return "Makeable Meals"
        case .almost:             return "Almost Makeable"
        case .withSubstitution:   return "Ready With a Substitution"
        case .useSoon:            return "Use Soon"
        case .plannedLater:       return "Planned for Later"
        case .alreadyPrepped:     return "Already Prepped"
        case .marinating:         return "Marinating"
        case .cookedReadyToReheat:return "Cooked & Ready to Reheat"
        }
    }
}

// MARK: - Completion type (partial sessions are first-class)

/// What a session actually produced. Crucially, everything except
/// `.stoppedEarly` (and even that, if a component finished) is a SUCCESS.
nonisolated enum CookCompletionType: String, Codable, Sendable {
    case ingredientPrepared
    case entreeCompleted
    case sideCompleted
    case componentCompleted
    case mealCompleted
    case cookedForLater
    case partiallyCompleted
    case stoppedEarly

    /// The workspace treats any finished component as a win — no "incomplete meal" shaming.
    var isSuccessful: Bool { self != .stoppedEarly }

    var summaryLabel: String {
        switch self {
        case .ingredientPrepared: return "Ingredient prepped"
        case .entreeCompleted:    return "Entrée done"
        case .sideCompleted:      return "Side done"
        case .componentCompleted: return "Component done"
        case .mealCompleted:      return "Meal complete"
        case .cookedForLater:     return "Cooked for later"
        case .partiallyCompleted: return "Partially done"
        case .stoppedEarly:       return "Stopped"
        }
    }
}

// MARK: - Session status (the workspace lifecycle)

/// Where a session is in its lifecycle. Broad enough to model discovery,
/// getting ready, active cooking, hands-off windows, cook-ahead cooling and
/// storage, and finish-and-serve — without requiring any of them.
nonisolated enum CookSessionStatus: String, Codable, Sendable {
    case selectingIntent
    case selectingPreparation
    case selectingMethod
    case gettingReady        // Before You Start
    case cooking
    case handsOff            // long unattended window (pressure/slow/braise)
    case waitingForDecision
    case cooling
    case storing
    case readyToReheat
    case finishing           // Finish & Serve
    case completed
    case paused

    var isActive: Bool {
        switch self {
        case .completed, .paused: return false
        default: return true
        }
    }
    var isCookAheadHolding: Bool {
        self == .cooling || self == .storing || self == .readyToReheat
    }
}
