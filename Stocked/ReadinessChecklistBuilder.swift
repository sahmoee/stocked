//
//  ReadinessChecklistBuilder.swift
//  Stocked
//
//  Builds the "Before You Start" checklist as data, so BeforeYouStartView can
//  render sections without hand-deriving them and so the logic is unit-testable.
//
//  The checklist has four sections from the spec:
//    1. Equipment      — devices + accessories the chosen method needs
//    2. Pull From Inventory — ingredients to take out (with prep hints)
//    3. Prep Before Heating — knife/measure/setup tasks to finish before heat
//    4. Optional Decisions — the "stop here or keep going" choices
//
//  It reads an existing CookingMethod (by id) for equipment/stages and a recipe's
//  ingredients for the pull/prep rows. Pure & non-isolated.
//

import Foundation

nonisolated enum ReadinessChecklistBuilder {

    struct Item: Identifiable, Sendable, Equatable {
        var id: String { "\(section.rawValue):\(title.lowercased())" }
        let title: String
        let detail: String?
        let section: Section
        /// True for items the user must resolve before heat (chopping, measuring,
        /// confirming a sealing ring). Optional-decision rows are never blocking.
        let isPreHeatBlocking: Bool

        init(_ title: String, detail: String? = nil, section: Section, blocking: Bool = false) {
            self.title = title
            self.detail = detail
            self.section = section
            self.isPreHeatBlocking = blocking
        }
    }

    enum Section: String, Sendable, CaseIterable {
        case equipment      = "Equipment"
        case pull           = "Pull From Inventory"
        case prep           = "Prep Before Heating Anything"
        case optional       = "Optional Decisions"
    }

    /// Build the full checklist.
    /// - Parameters:
    ///   - methodID: id of the chosen CookingMethod (looked up in the catalog).
    ///   - ingredients: the preparation's ingredient lines.
    ///   - anchorName: the anchor item (for friendlier copy).
    static func build(methodID: String?,
                     ingredients: [RecipeIngredient],
                     anchorName: String?) -> [Item] {
        var items: [Item] = []

        // 1. Equipment — from the method's required + alternative devices, plus
        //    a small set of universal accessories.
        if let id = methodID, let method = CookingMethodCatalog.method(id: id) {
            for eq in method.requiredEquipment {
                items.append(.init(eq.rawValue, detail: "Needed for: \(method.name)", section: .equipment, blocking: true))
            }
            // Accessories implied by combined/pressure workflows.
            if method.name.lowercased().contains("pressure") || method.requiredEquipment.contains(.instantPot) {
                items.append(.init("Sealing ring installed", detail: "Confirm it's seated before locking the lid.", section: .equipment, blocking: true))
                items.append(.init("Pressure valve checked", detail: "Make sure it moves freely.", section: .equipment, blocking: true))
            }
            if method.isCombined {
                items.append(.init("Transfer plate", detail: "For moving food between stages.", section: .equipment))
            }
        }
        // Universal basics (deduped by title later if a method added them).
        for basic in ["Tongs or spatula", "Knife", "Cutting board"] {
            items.append(.init(basic, section: .equipment))
        }

        // 2. Pull From Inventory — one row per ingredient, prep hint in detail.
        if let anchor = anchorName, !anchor.isEmpty {
            items.append(.init("Remove \(anchor.displayNormalized) from the fridge", detail: "Let it lose the worst of the chill while you prep.", section: .pull))
        }
        for ing in ingredients where !ing.isOptional {
            let d = [ing.amount.isEmpty ? nil : ing.amount, ing.prep].compactMap { $0 }.joined(separator: " · ")
            items.append(.init(ing.name.displayNormalized, detail: d.isEmpty ? nil : d, section: .pull))
        }

        // 3. Prep Before Heating — derive tasks from ingredient prep notes so the
        //    user finishes chopping/measuring before turning on heat.
        for ing in ingredients where !ing.isOptional {
            if let prep = ing.prep, !prep.isEmpty {
                items.append(.init("\(prep.capitalized) \(ing.name.displayNormalized)", section: .prep, blocking: true))
            }
        }
        items.append(.init("Measure any liquids", section: .prep, blocking: true))
        items.append(.init("Set out your transfer plate and tools", section: .prep))

        // 4. Optional Decisions — the nonjudgmental "how far do you want to go".
        items.append(.init("Add one easy side?", detail: "Or keep it simple — the entrée is enough.", section: .optional))
        items.append(.init("Cook now and serve later?", section: .optional))
        items.append(.init("Prep extra of an overlapping ingredient for another meal?", section: .optional))
        items.append(.init("Save part of this for lunch?", section: .optional))

        return dedupedByTitleWithinSection(items)
    }

    /// Items grouped for section-by-section rendering, in canonical order.
    static func grouped(_ items: [Item]) -> [(section: Section, items: [Item])] {
        Section.allCases.compactMap { s in
            let group = items.filter { $0.section == s }
            return group.isEmpty ? nil : (s, group)
        }
    }

    /// The blocking prep/equipment items that must be done before heat.
    static func blockingItems(_ items: [Item]) -> [Item] { items.filter(\.isPreHeatBlocking) }

    // MARK: - Helpers

    private static func dedupedByTitleWithinSection(_ items: [Item]) -> [Item] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }
}
