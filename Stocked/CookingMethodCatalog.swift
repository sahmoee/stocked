// CookingMethodCatalog.swift
// ─────────────────────────────────────────────────────────────────
// The cooking-method knowledge base. Methods are described by OUTCOME and
// TRADEOFF, never as a bare appliance list, so the comparison screen can tell
// the user what each choice actually gives them: texture, browning, moisture,
// active vs total time, cleanup, attention, best use, cook-ahead suitability,
// and whether it frees other appliances for simultaneous work.
//
// Combined-device workflows (sear then pressure cook, skillet then oven, etc.)
// are first-class here — a method may require more than one piece of equipment
// and may run in stages.
//
// Pure value data (nonisolated, Sendable) so previews/tests can use it freely.
// Method suitability is filtered against the user's owned + available
// equipment by the comparison view.
// ─────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Qualitative scales

nonisolated enum MethodScale: Int, Codable, Sendable, Comparable {
    case none = 0, low, medium, high, veryHigh
    static func < (l: MethodScale, r: MethodScale) -> Bool { l.rawValue < r.rawValue }
    var label: String {
        switch self {
        case .none:     return "None"
        case .low:      return "Low"
        case .medium:   return "Medium"
        case .high:     return "High"
        case .veryHigh: return "Very high"
        }
    }
}

// MARK: - Method definition

nonisolated struct CookingMethod: Identifiable, Sendable, Equatable {
    let id: String                       // stable key stored on the session
    let name: String                     // "Sear → Pressure Cook"
    let stages: [String]                 // ordered device stages
    let requiredEquipment: [KitchenEquipment]
    let alternativeEquipment: [KitchenEquipment]  // acceptable substitutes for a required device

    // Outcome
    let texture: String
    let browning: MethodScale
    let moisture: MethodScale
    let resultSummary: String            // one-line "what you get"

    // Effort / logistics
    let activeMinutes: Int
    let totalMinutes: Int
    let cleanup: MethodScale
    let attention: MethodScale           // how hands-on
    let bestUseCase: String
    let goodForCookAhead: Bool
    let freesOtherAppliances: Bool       // long hands-off window usable elsewhere

    var isCombined: Bool { stages.count > 1 }

    /// Whether the user can run this now given owned + available equipment.
    /// A required device is satisfied by itself OR any listed alternative.
    func isAvailable(usable: Set<KitchenEquipment>) -> Bool {
        for needed in requiredEquipment {
            if usable.contains(needed) { continue }
            let altOK = alternativeEquipment.contains { usable.contains($0) }
            if !altOK { return false }
        }
        return true
    }

    /// Equipment this method needs that the user cannot currently use.
    func blockingEquipment(usable: Set<KitchenEquipment>) -> [KitchenEquipment] {
        requiredEquipment.filter { needed in
            !usable.contains(needed) && !alternativeEquipment.contains { usable.contains($0) }
        }
    }
}

// MARK: - Catalog

nonisolated enum CookingMethodCatalog {

    /// The full method library. The comparison view selects the subset relevant
    /// to the anchor (by simple category) and orders by availability + effort.
    static let all: [CookingMethod] = [
        CookingMethod(
            id: "sear_pressure",
            name: "Sear → Pressure Cook",
            stages: ["Sear on grill or skillet", "Pressure cook"],
            requiredEquipment: [.instantPot],
            alternativeEquipment: [.grill, .castIron, .stovetop],
            texture: "Fall-apart tender with a browned exterior",
            browning: .high, moisture: .high,
            resultSummary: "Deep browning, very tender interior, flavorful braising liquid",
            activeMinutes: 18, totalMinutes: 55,
            cleanup: .high, attention: .low,
            bestUseCase: "Tougher cuts you want tender with real browning",
            goodForCookAhead: true, freesOtherAppliances: true
        ),
        CookingMethod(
            id: "pressure_only",
            name: "Pressure Cook Only",
            stages: ["Pressure cook"],
            requiredEquipment: [.instantPot],
            alternativeEquipment: [],
            texture: "Tender, moist, less exterior browning",
            browning: .low, moisture: .veryHigh,
            resultSummary: "Lowest active effort, one appliance, very tender",
            activeMinutes: 8, totalMinutes: 45,
            cleanup: .low, attention: .low,
            bestUseCase: "Low-energy cooking; hands-off tenderness",
            goodForCookAhead: true, freesOtherAppliances: true
        ),
        CookingMethod(
            id: "grill_only",
            name: "Grill Only",
            stages: ["Grill"],
            requiredEquipment: [.grill],
            alternativeEquipment: [.castIron, .stovetop],
            texture: "Charred exterior, firmer interior",
            browning: .veryHigh, moisture: .medium,
            resultSummary: "Fast, charred, firmer texture; needs attention",
            activeMinutes: 15, totalMinutes: 20,
            cleanup: .low, attention: .high,
            bestUseCase: "Quick cooking with char; tender cuts",
            goodForCookAhead: false, freesOtherAppliances: false
        ),
        CookingMethod(
            id: "castiron_oven",
            name: "Cast Iron → Oven",
            stages: ["Sear in cast iron", "Finish in oven"],
            requiredEquipment: [.castIron, .oven],
            alternativeEquipment: [.stovetop],
            texture: "Strong crust, roasted through",
            browning: .veryHigh, moisture: .medium,
            resultSummary: "Restaurant-style crust and roasted flavor; more monitoring",
            activeMinutes: 15, totalMinutes: 35,
            cleanup: .medium, attention: .medium,
            bestUseCase: "Thick cuts you want crusty and evenly cooked",
            goodForCookAhead: false, freesOtherAppliances: false
        ),
        CookingMethod(
            id: "slow_cook",
            name: "Slow Cook",
            stages: ["Slow cook"],
            requiredEquipment: [.slowCooker],
            alternativeEquipment: [.instantPot],
            texture: "Very tender, soft exterior",
            browning: .none, moisture: .veryHigh,
            resultSummary: "Minimal active work; cook far ahead; softer exterior",
            activeMinutes: 10, totalMinutes: 300,
            cleanup: .low, attention: .none,
            bestUseCase: "Cooking well ahead with almost no attention",
            goodForCookAhead: true, freesOtherAppliances: true
        ),
        CookingMethod(
            id: "air_fry",
            name: "Air Fry",
            stages: ["Air fry"],
            requiredEquipment: [.airFryer],
            alternativeEquipment: [.oven, .toasterOven],
            texture: "Crisp exterior, quick",
            browning: .high, moisture: .medium,
            resultSummary: "Fast and crisp with little oil; one appliance",
            activeMinutes: 8, totalMinutes: 22,
            cleanup: .low, attention: .low,
            bestUseCase: "Quick crisp results; smaller portions",
            goodForCookAhead: false, freesOtherAppliances: true
        ),
        CookingMethod(
            id: "stovetop_sear",
            name: "Stovetop Sear",
            stages: ["Sear on stovetop"],
            requiredEquipment: [.stovetop],
            alternativeEquipment: [.castIron, .grill],
            texture: "Browned exterior, quick",
            browning: .high, moisture: .medium,
            resultSummary: "Fast and flexible on any pan; needs attention",
            activeMinutes: 15, totalMinutes: 20,
            cleanup: .low, attention: .high,
            bestUseCase: "Everyday quick cooking",
            goodForCookAhead: false, freesOtherAppliances: false
        ),
        CookingMethod(
            id: "oven_roast",
            name: "Oven Roast",
            stages: ["Roast in oven"],
            requiredEquipment: [.oven],
            alternativeEquipment: [.toasterOven],
            texture: "Evenly roasted",
            browning: .medium, moisture: .medium,
            resultSummary: "Hands-off roasting; frees the stovetop for sides",
            activeMinutes: 10, totalMinutes: 40,
            cleanup: .low, attention: .low,
            bestUseCase: "Larger cuts and sheet-pan cooking",
            goodForCookAhead: true, freesOtherAppliances: true
        )
    ]

    static func method(id: String) -> CookingMethod? { all.first { $0.id == id } }

    /// Methods reasonable for a protein anchor (the common case). For non-protein
    /// anchors we still return the general set; ordering does the useful work.
    static func candidates(forAnchor anchor: String) -> [CookingMethod] {
        // The whole library applies broadly; the comparison view orders by
        // availability then effort. We keep this simple and honest rather than
        // pretending to know an exact per-ingredient method map.
        all
    }
}
