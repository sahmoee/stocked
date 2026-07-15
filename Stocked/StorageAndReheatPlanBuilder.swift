//
//  StorageAndReheatPlanBuilder.swift
//  Stocked
//
//  Turns "I cooked this ahead" into concrete, honest cooling / storage /
//  reheating guidance. Used by CookAheadStatusView and the Finish & Serve flow.
//
//  The guidance is intentionally conservative and text-only (no false food-safety
//  promises). It adapts to a few properties of the dish — saucy vs. dry, whether
//  a crisp element needs a separate finishing step, whether it freezes well.
//
//  Pure & non-isolated.
//

import Foundation

nonisolated enum StorageAndReheatPlanBuilder {

    /// Lightweight description of the cooked food, so guidance can adapt.
    struct DishProfile: Sendable {
        var name: String
        var isSaucy: Bool = false          // braises, stews, gravies → reheat covered, add liquid
        var hasCrispElement: Bool = false  // skin/crust → separate broiler/air-fryer finish
        var freezesWell: Bool = true
        var serveTime: Date? = nil         // intended serve time (from the plan)

        init(name: String, isSaucy: Bool = false, hasCrispElement: Bool = false,
             freezesWell: Bool = true, serveTime: Date? = nil) {
            self.name = name
            self.isSaucy = isSaucy
            self.hasCrispElement = hasCrispElement
            self.freezesWell = freezesWell
            self.serveTime = serveTime
        }
    }

    struct Plan: Sendable, Equatable {
        var cooling: [String]
        var storage: [String]
        var reheating: [String]
        var finishing: [String]   // fresh/crisp steps done right before serving
    }

    static func plan(for dish: DishProfile) -> Plan {
        var cooling: [String] = [
            "Let \(dish.name.displayNormalized) rest a few minutes off the heat.",
            "Cool to room temperature reasonably quickly — don't leave it out for hours.",
        ]
        if dish.isSaucy {
            cooling.append("Cooling in a wider container helps a saucy dish drop temperature faster.")
        }

        var storage: [String] = [
            "Transfer to an airtight container once no longer steaming.",
            "Refrigerate until it's time to finish for the meal.",
        ]
        if dish.isSaucy {
            storage.append("Keep some of the cooking liquid with it so it doesn't dry out.")
        }
        if dish.freezesWell {
            storage.append("Freezes well if the meal moves further out than a day or two.")
        }

        var reheating: [String] = []
        if dish.isSaucy {
            reheating.append("Reheat gently, covered, adding a splash of the reserved liquid or water.")
            reheating.append("Stir once or twice so it warms evenly.")
        } else {
            reheating.append("Reheat covered on low-to-medium heat so it warms through without drying.")
        }

        var finishing: [String] = []
        if dish.hasCrispElement {
            finishing.append("Crisp the exterior under the broiler or in the air fryer for the last couple of minutes.")
        }
        finishing.append("Add anything fresh — herbs, a squeeze of citrus, a sauce — right before plating.")

        // If we know the serve time, add a light timing nudge.
        if let serve = dish.serveTime {
            finishing.insert("Aim to start reheating shortly before \(Self.timeString(serve)).", at: 0)
        }

        return Plan(cooling: cooling, storage: storage, reheating: reheating, finishing: finishing)
    }

    private static func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}
