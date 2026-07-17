// ReservationEngine.swift
// ─────────────────────────────────────────────────────────────────
// RL-003/RL-005 — the pure Available / Reserved / Total inventory brain.
//
// Reservations are DERIVED, never stored: this engine re-derives every claim
// from the current planned meals + inventory each time it runs, so repeated
// recalculation is idempotent by construction (same inputs → same snapshot,
// no accumulation, no physical deduction of inventory).
//
//   Total Owned  = physical quantity logged in inventory.
//   Reserved     = quantity committed to upcoming planned meals (incl. meals
//                  already prepped/cooked ahead — that food is still spoken for).
//   Available    = Total − Reserved, floored at zero. A deficit is surfaced as
//                  an explicit shortage state instead of a misleading negative.
//
// Meals are walked in chronological order (day, then breakfast→snack) so a
// shortage lands on the LATER meal — the earlier meal keeps its claim, which
// matches how people actually resolve over-allocation ("Friday's tacos are the
// problem, not Tuesday's"). Items that expire before a meal's date cannot be
// claimed by that meal. Unconfirmed grocery items never count as owned.
//
// Pure & explicitly nonisolated with immutable Sendable DTOs, following the
// CookLaterCrossCheckEngine / MakeabilityEngine pattern, so it is safe under
// Swift 6 default main-actor isolation and directly unit-testable.
// ─────────────────────────────────────────────────────────────────

import Foundation

// MARK: - DTOs

/// One meal's claim on one inventory item — the "labeled reservation" the item
/// detail screen renders (linked meal, scheduled date, reserved amount).
nonisolated struct ReservationClaim: Identifiable, Sendable, Equatable {
    let id: String
    let mealID: UUID
    let mealTitle: String
    let mealType: String
    let dayIndex: Int
    let date: Date
    let ingredient: String     // parsed ingredient name (e.g. "chicken thighs")
    let rawIngredient: String  // the meal's original ingredient line
    let amount: Double         // in `unit`; 0 when the amount is unquantifiable
    let unit: String           // "" = count of items/containers
    let prepared: Bool         // meal is already prepped/cooked ahead

    var amountDisplay: String {
        guard amount > 0 else { return "reserved" }
        let n = amount.rounded(toPlaces: 2).clean
        return unit.isEmpty ? n : "\(n) \(unit)"
    }
}

/// Why a projected need cannot be met from what is owned.
nonisolated enum ReservationShortageReason: String, Sendable, Equatable {
    case notInStock       // nothing in inventory matches at all
    case overAllocated    // matched, but earlier meals (or a Cook Anyway) claimed it
    case expiresBeforeMeal// matched, but everything expires before the meal's date

    var label: String {
        switch self {
        case .notInStock:        return "Not in stock"
        case .overAllocated:     return "Already reserved"
        case .expiresBeforeMeal: return "Expires first"
        }
    }
}

/// A specific, actionable conflict: which meal, which ingredient, how much is
/// missing, and why. Ordered earliest/most-urgent first by the engine.
nonisolated struct MealConflict: Identifiable, Sendable, Equatable {
    let id: String
    let mealID: UUID
    let mealTitle: String
    let mealType: String
    let dayIndex: Int
    let date: Date
    let ingredient: String
    let rawIngredient: String
    let missingAmount: Double  // in `unit`; 0 = "the whole thing" for count-less lines
    let unit: String
    let reason: ReservationShortageReason

    var missingDisplay: String {
        guard missingAmount > 0 else { return ingredient.displayNormalized }
        let n = missingAmount.rounded(toPlaces: 2).clean
        return unit.isEmpty
            ? "\(n) \(ingredient.displayNormalized)"
            : "\(n) \(unit) \(ingredient.displayNormalized)"
    }
}

/// Ingredient-centric rollup of conflicts — "you are 1.5 lb of chicken short,
/// first bites on Thursday's tacos". Earliest-affected first.
nonisolated struct ProjectedShortage: Identifiable, Sendable, Equatable {
    let id: String
    let ingredient: String
    let totalMissing: Double   // in `unit`; 0 when unquantifiable
    let unit: String
    let earliestDayIndex: Int
    let earliestDate: Date
    let firstAffectedMeal: String
    let affectedMealTitles: [String]

    var missingDisplay: String {
        guard totalMissing > 0 else { return ingredient.displayNormalized }
        let n = totalMissing.rounded(toPlaces: 2).clean
        return unit.isEmpty
            ? "\(n) \(ingredient.displayNormalized)"
            : "\(n) \(unit) \(ingredient.displayNormalized)"
    }
}

/// Per-inventory-item Total / Reserved / Available breakdown.
nonisolated struct ReservationBreakdown: Identifiable, Sendable, Equatable {
    let id: UUID               // inventory item id
    let itemName: String
    let unit: String           // display unit ("" = count of `containerType`)
    let containerType: String
    let totalOwned: Double     // in display unit
    let reserved: Double
    let available: Double      // max(0, totalOwned − reserved) — never negative
    let shortfall: Double      // how far reserved exceeds owned (0 when covered)
    let quantified: Bool       // false when we lack the data to do honest math
    let claims: [ReservationClaim]

    var isShort: Bool { shortfall > 0.001 }

    private func fmt(_ v: Double) -> String {
        let n = v.rounded(toPlaces: 2).clean
        if !unit.isEmpty { return "\(n) \(unit)" }
        return containerType.isEmpty ? n : "\(n) \(containerType)\(v == 1 ? "" : "s")"
    }
    var totalDisplay: String     { fmt(totalOwned) }
    var reservedDisplay: String  { fmt(reserved) }
    var availableDisplay: String { fmt(available) }
    var shortfallDisplay: String { fmt(shortfall) }
}

/// Inventory consumed by a Cook Anyway override that the physical inventory may
/// not reflect yet — the ledger feeds these in only until the inventory itself
/// changes (see ReservationLedger), so nothing is ever double-counted.
nonisolated struct ReservationPendingConsumption: Sendable, Equatable {
    let ingredient: String
    let amount: Double
    let unit: String
}

// MARK: - Snapshot

/// Everything one derivation pass produced. Immutable; replace, never mutate.
nonisolated struct ReservationSnapshot: Sendable, Equatable {
    let breakdowns: [ReservationBreakdown]      // items with any claim, name-sorted
    let byItemID: [UUID: ReservationBreakdown]
    let conflicts: [MealConflict]               // earliest/most urgent first
    let shortages: [ProjectedShortage]          // ingredient rollup, earliest first
    let reservedNames: Set<String>              // normalized claimed ingredient names

    static let empty = ReservationSnapshot(
        breakdowns: [], byItemID: [:], conflicts: [], shortages: [], reservedNames: [])
}

// MARK: - Engine

nonisolated enum ReservationEngine {

    private static let matchThreshold = 0.78
    private static let epsilon = 0.001

    /// Chronological rank inside one day.
    static func mealTypeRank(_ type: String) -> Int {
        switch type.lowercased() {
        case "breakfast": return 0
        case "lunch":     return 1
        case "dinner":    return 2
        case "snack":     return 3
        default:          return 4
        }
    }

    /// Derive the full reservation picture. Pure: same inputs, same output.
    /// - Parameters:
    ///   - meals: the planner's meals (cooked/building meals hold no reservations).
    ///   - inventory: the physical inventory (grocery items never count).
    ///   - pendingConsumption: Cook Anyway consumption not yet reflected in inventory.
    ///   - now: injection point for deterministic tests.
    static func compute(meals: [PlannedMeal],
                        inventory: [LocalInventoryItem],
                        pendingConsumption: [ReservationPendingConsumption] = [],
                        now: Date = Date()) -> ReservationSnapshot {

        let cal = Calendar.current
        let today = cal.startOfDay(for: now)

        // ── Chronological walk order ────────────────────────────────────
        // A meal marked served also releases its claim; prepped/cooked-ahead
        // meals KEEP theirs (the food is made or mid-flight — still committed).
        let active = meals
            .filter { !$0.isCooked && !$0.isBuilding && $0.cookAheadStatus != .served && $0.dayIndex >= 0 }
            .sorted {
                if $0.dayIndex != $1.dayIndex { return $0.dayIndex < $1.dayIndex }
                let ra = mealTypeRank($0.mealType), rb = mealTypeRank($1.mealType)
                if ra != rb { return ra < rb }
                return $0.id.uuidString < $1.id.uuidString   // stable, deterministic
            }

        // ── Per-item running ledger (base units: g / ml / count) ───────
        struct ItemState {
            let item: LocalInventoryItem
            let family: String        // "weight" | "volume" | "count"
            let ownedBase: Double
            var remainingBase: Double
        }
        var states: [UUID: ItemState] = [:]
        for item in inventory {
            let (family, owned) = ownedBase(of: item)
            states[item.id] = ItemState(item: item, family: family,
                                        ownedBase: owned, remainingBase: owned)
        }

        // Cook Anyway consumption comes off the top, before any meal claims —
        // that food is already in a pan somewhere.
        for pending in pendingConsumption {
            var base = pending.amount
            var family = "count"
            if !pending.unit.isEmpty, let fam = UnitMath.family(of: pending.unit) {
                family = fam == .mass ? "weight" : "volume"
                base = UnitMath.convert(pending.amount,
                                        from: pending.unit,
                                        to: fam == .mass ? "g" : "ml") ?? pending.amount
            }
            var need = base
            for match in matchingItems(for: pending.ingredient, in: inventory) {
                guard need > epsilon, var state = states[match.id],
                      state.family == family, state.remainingBase > epsilon else { continue }
                let take = min(state.remainingBase, need)
                state.remainingBase -= take
                need -= take
                states[match.id] = state
            }
        }

        var claimsByItem: [UUID: [ReservationClaim]] = [:]
        var conflicts: [MealConflict] = []
        var reservedNames = Set<String>()

        // ── Walk meals, earliest first ─────────────────────────────────
        for meal in active {
            let mealDay = cal.date(byAdding: .day, value: meal.dayIndex, to: today) ?? today
            let prepared = meal.cookAheadStatus.isCookedAhead

            for (index, raw) in meal.ingredients.enumerated() {
                let parsed = CookLaterCrossCheckEngine.parse(raw)
                guard !parsed.name.isEmpty else { continue }

                let matches = matchingItems(for: parsed.name, in: inventory)
                if matches.isEmpty {
                    conflicts.append(MealConflict(
                        id: "\(meal.id.uuidString)-\(index)",
                        mealID: meal.id, mealTitle: meal.title, mealType: meal.mealType,
                        dayIndex: meal.dayIndex, date: mealDay,
                        ingredient: parsed.name, rawIngredient: raw,
                        missingAmount: parsed.amount, unit: parsed.unit,
                        reason: .notInStock))
                    continue
                }

                // Consume expiring-soonest first so shelf life is spent wisely.
                let ordered = matches.sorted {
                    ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture)
                }
                // A match that expires before the meal's day is not usable then.
                let usable = ordered.filter { item in
                    guard let exp = item.expirationDate else { return true }
                    return cal.startOfDay(for: exp) >= cal.startOfDay(for: mealDay)
                }

                // Factor to convert a base amount back into the recipe's unit.
                let displayFactor = parsed.amount > epsilon && parsed.baseAmount > epsilon
                    ? parsed.amount / parsed.baseAmount : 1

                var needBase = parsed.baseAmount
                var sawUnquantified = false

                for item in usable {
                    guard needBase > epsilon, var state = states[item.id] else { continue }
                    // A genuinely empty item holds nothing to claim — skip it and
                    // let the shortage surface honestly.
                    if state.ownedBase <= epsilon { continue }
                    if state.family != parsed.family {
                        // The item matches by name but has no comparable quantity
                        // data (or an incomparable unit family). Reserve its
                        // presence without inventing numbers — the honest claim
                        // is "this item is spoken for", not a made-up amount.
                        if !sawUnquantified {
                            sawUnquantified = true
                            claimsByItem[item.id, default: []].append(ReservationClaim(
                                id: "\(meal.id.uuidString)-\(index)-\(item.id.uuidString)",
                                mealID: meal.id, mealTitle: meal.title, mealType: meal.mealType,
                                dayIndex: meal.dayIndex, date: mealDay,
                                ingredient: parsed.name, rawIngredient: raw,
                                amount: 0, unit: parsed.unit, prepared: prepared))
                            reservedNames.insert(FoodNameMatcher.normalized(parsed.name))
                            needBase = 0    // cannot honestly claim a shortage either
                        }
                        continue
                    }
                    guard state.remainingBase > epsilon else { continue }
                    let take = min(state.remainingBase, needBase)
                    state.remainingBase -= take
                    needBase -= take
                    states[item.id] = state
                    claimsByItem[item.id, default: []].append(ReservationClaim(
                        id: "\(meal.id.uuidString)-\(index)-\(item.id.uuidString)",
                        mealID: meal.id, mealTitle: meal.title, mealType: meal.mealType,
                        dayIndex: meal.dayIndex, date: mealDay,
                        ingredient: parsed.name, rawIngredient: raw,
                        amount: take * displayFactor, unit: parsed.unit, prepared: prepared))
                    reservedNames.insert(FoodNameMatcher.normalized(parsed.name))
                }

                if needBase > epsilon {
                    let reason: ReservationShortageReason =
                        usable.isEmpty ? .expiresBeforeMeal : .overAllocated
                    conflicts.append(MealConflict(
                        id: "\(meal.id.uuidString)-\(index)",
                        mealID: meal.id, mealTitle: meal.title, mealType: meal.mealType,
                        dayIndex: meal.dayIndex, date: mealDay,
                        ingredient: parsed.name, rawIngredient: raw,
                        missingAmount: needBase * displayFactor, unit: parsed.unit,
                        reason: reason))
                }
            }
        }

        // ── Assemble per-item breakdowns ───────────────────────────────
        var breakdowns: [ReservationBreakdown] = []
        for (itemID, claims) in claimsByItem {
            guard let state = states[itemID] else { continue }
            let item = state.item
            // Display in the item's own unit when it has one, else raw count.
            let displayUnit = (item.sizeUnit?.isEmpty == false && state.ownedBase > epsilon)
                ? (item.sizeUnit ?? "") : ""
            func toDisplay(_ base: Double) -> Double {
                guard state.ownedBase > epsilon else { return base }
                if displayUnit.isEmpty { return base }   // count family: base IS the count
                let baseUnit = state.family == "weight" ? "g" : state.family == "volume" ? "ml" : ""
                guard !baseUnit.isEmpty else { return base }
                return UnitMath.convert(base, from: baseUnit, to: displayUnit) ?? base
            }
            let reservedBase = state.ownedBase - state.remainingBase
            let sortedClaims = claims.sorted {
                if $0.dayIndex != $1.dayIndex { return $0.dayIndex < $1.dayIndex }
                return mealTypeRank($0.mealType) < mealTypeRank($1.mealType)
            }
            breakdowns.append(ReservationBreakdown(
                id: itemID,
                itemName: item.name,
                unit: displayUnit,
                containerType: item.containerType,
                totalOwned: toDisplay(state.ownedBase),
                reserved: toDisplay(reservedBase),
                available: toDisplay(max(0, state.remainingBase)),
                shortfall: 0,   // per-item ledger never over-draws; deficits live in conflicts
                // Only claim numeric precision when every reservation on this item
                // actually carried a comparable amount; otherwise the UI falls back
                // to "reserved for N meals" instead of inventing numbers.
                quantified: state.ownedBase > epsilon && sortedClaims.allSatisfy { $0.amount > 0 },
                claims: sortedClaims))
        }
        breakdowns.sort { $0.itemName.localizedCaseInsensitiveCompare($1.itemName) == .orderedAscending }

        // Earliest/most urgent conflicts first; stable within a slot.
        conflicts.sort {
            if $0.dayIndex != $1.dayIndex { return $0.dayIndex < $1.dayIndex }
            let ra = mealTypeRank($0.mealType), rb = mealTypeRank($1.mealType)
            if ra != rb { return ra < rb }
            return $0.id < $1.id
        }

        // ── Ingredient rollup ──────────────────────────────────────────
        var shortageOrder: [String] = []
        var grouped: [String: [MealConflict]] = [:]
        for c in conflicts {
            let key = FoodNameMatcher.normalized(c.ingredient) + "|" + c.unit
            if grouped[key] == nil { shortageOrder.append(key) }
            grouped[key, default: []].append(c)
        }
        let shortages: [ProjectedShortage] = shortageOrder.compactMap { key in
            guard let group = grouped[key], let first = group.first else { return nil }
            var titles: [String] = []
            for c in group where !titles.contains(c.mealTitle) { titles.append(c.mealTitle) }
            return ProjectedShortage(
                id: key,
                ingredient: first.ingredient,
                totalMissing: group.reduce(0) { $0 + $1.missingAmount },
                unit: first.unit,
                earliestDayIndex: first.dayIndex,
                earliestDate: first.date,
                firstAffectedMeal: first.mealTitle,
                affectedMealTitles: titles)
        }

        var byID: [UUID: ReservationBreakdown] = [:]
        for b in breakdowns { byID[b.id] = b }

        return ReservationSnapshot(breakdowns: breakdowns,
                                   byItemID: byID,
                                   conflicts: conflicts,
                                   shortages: shortages,
                                   reservedNames: reservedNames)
    }

    // MARK: - Recipe ↔ reservation matching (RL-004)

    /// Which of a recipe's ingredient names touch reserved ingredients. Loose
    /// containment both ways, mirroring GuestDataStore.isReservedForMeal, so
    /// "chicken" flags "chicken thighs" and vice versa.
    static func usesReserved(ingredientNames: [String], reservedNames: Set<String>) -> [String] {
        guard !reservedNames.isEmpty else { return [] }
        return ingredientNames.filter { name in
            let parsedName = RecipeIngredients.parse(name).name
            let key = FoodNameMatcher.normalized(parsedName.isEmpty ? name : parsedName)
            guard key.count > 2 else { return false }
            return reservedNames.contains { $0.contains(key) || key.contains($0) }
        }
    }

    // MARK: - Helpers

    /// Physical owned amount in family base units (g / ml / count). The level
    /// factor accounts for the partially-used current container — same rule the
    /// rest of the app uses for structured sizes. Expiry is NOT discounted here;
    /// the walk handles expiration explicitly against each meal's date.
    static func ownedBase(of item: LocalInventoryItem) -> (family: String, base: Double) {
        let fill = min(1, max(0, item.level))
        let containers = Double(max(0, item.quantity))
        if let size = item.sizeAmount, size > 0, let unit = item.sizeUnit, !unit.isEmpty {
            if let fam = UnitMath.family(of: unit) {
                let baseUnit = fam == .mass ? "g" : "ml"
                if let converted = UnitMath.convert(size * containers * fill, from: unit, to: baseUnit) {
                    return (fam == .mass ? "weight" : "volume", converted)
                }
            }
            // Countable size unit ("cans", "pieces", "count"…): treat as a count.
            return ("count", size * containers * fill)
        }
        // No structured size: the container count is all we honestly know.
        return ("count", containers * fill)
    }

    /// Boundary-aware name match against inventory, shared threshold with the
    /// planner's cross-check engine.
    private static func matchingItems(for name: String,
                                      in inventory: [LocalInventoryItem]) -> [LocalInventoryItem] {
        inventory
            .compactMap { item -> (LocalInventoryItem, Double)? in
                let score = FoodNameMatcher.matches(name, item.name).score
                return score >= matchThreshold ? (item, score) : nil
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}
