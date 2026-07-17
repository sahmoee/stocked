// ReservationLedger.swift
// ─────────────────────────────────────────────────────────────────
// RL-003/RL-004/RL-006 — the one main-actor home for derived reservations.
//
// The ledger owns NO planning data: it caches the pure ReservationEngine
// snapshot keyed off GuestDataStore's revision counters (inventoryRevision ×
// planRevision), the same derived-state discipline stockMatchCache and the
// Cook hub insights already use. Any plan or inventory mutation bumps a
// revision, the next `refreshIfNeeded(store:)` re-derives, and because the
// engine is a pure function of its inputs the recalculation is idempotent —
// call it once or fifty times, the snapshot is identical and nothing manual
// (grocery rows, meal edits, override history) is touched.
//
// It also persists the small Cook Anyway override log (RL-004). An override's
// consumption feeds back into projections only while the inventory revision it
// was recorded under is still current — the moment inventory actually changes
// (the cooking flow deducting, a restock, anything), the physical numbers take
// over and the override stops counting, so consumption is never double-applied.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

// MARK: - Cook Anyway override record

/// One ingredient a Cook Anyway consumed, in the recipe's own units.
nonisolated struct ReservationOverrideIngredient: Codable, Sendable, Equatable {
    var name: String
    var amount: Double = 0     // 0 = amount was unquantifiable
    var unit: String = ""
}

/// A persisted Cook Anyway decision: what was cooked, what it consumed, and
/// which planned meals it knowingly stepped on.
nonisolated struct ReservationOverrideRecord: Identifiable, Codable, Sendable, Equatable {
    var id = UUID()
    var date = Date()
    var recipeTitle: String
    var ingredients: [ReservationOverrideIngredient] = []
    var affectedMealTitles: [String] = []
    var addedReplacementsToGrocery: Bool = false
    /// The store's inventoryRevision when recorded. While this still matches,
    /// the consumption is projected forward; once inventory changes, physical
    /// data wins and this record becomes history only.
    var inventoryRevisionAtCreation: Int = -1
}

// MARK: - Ledger

@Observable
@MainActor
final class ReservationLedger {
    static let shared = ReservationLedger()

    /// The current derived picture. Views read this in `body`; it is replaced
    /// wholesale by refresh, never mutated in place.
    private(set) var snapshot: ReservationSnapshot = .empty

    /// Cook Anyway history, newest last. Small and capped.
    private(set) var overrideLog: [ReservationOverrideRecord] = []

    // Cache keys — @ObservationIgnored so a refresh check inside a view's
    // .task/.onChange never itself schedules another render.
    @ObservationIgnored private var lastInventoryRevision = Int.min
    @ObservationIgnored private var lastPlanRevision = Int.min
    @ObservationIgnored private var lastOverrideStamp = Int.min
    @ObservationIgnored private var overrideStamp = 0

    private static let logKey = "reservationOverrideLog_v1"
    private static let logCap = 100

    private init() {
        overrideLog = LocalDatabase.shared.loadArray(ReservationOverrideRecord.self,
                                                     key: Self.logKey) ?? []
    }

    // MARK: Refresh (RL-006)

    /// Recompute the snapshot only when something it depends on changed.
    /// Cheap to call from every surface's .task / .onChange — that is the point.
    func refreshIfNeeded(store: GuestDataStore) {
        guard store.inventoryRevision != lastInventoryRevision
                || store.planRevision != lastPlanRevision
                || overrideStamp != lastOverrideStamp else { return }
        refresh(store: store)
    }

    /// Unconditional recompute. Idempotent: the engine is pure, so re-running
    /// with unchanged inputs produces an identical snapshot.
    func refresh(store: GuestDataStore) {
        snapshot = ReservationEngine.compute(
            meals: store.plannedMeals,
            inventory: store.inventoryItems,
            pendingConsumption: pendingConsumption(currentInventoryRevision: store.inventoryRevision))
        lastInventoryRevision = store.inventoryRevision
        lastPlanRevision = store.planRevision
        lastOverrideStamp = overrideStamp
    }

    /// Overrides whose consumption inventory has not caught up with yet.
    private func pendingConsumption(currentInventoryRevision: Int) -> [ReservationPendingConsumption] {
        overrideLog
            .filter { $0.inventoryRevisionAtCreation == currentInventoryRevision }
            .flatMap { record in
                record.ingredients.map {
                    ReservationPendingConsumption(ingredient: $0.name,
                                                  amount: $0.amount,
                                                  unit: $0.unit)
                }
            }
    }

    // MARK: Accessors (RL-003 / RL-005)

    /// Total / Reserved / Available breakdown for one item, or nil when nothing
    /// is reserved against it (then Available == everything owned).
    func breakdown(for item: LocalInventoryItem) -> ReservationBreakdown? {
        snapshot.byItemID[item.id]
    }

    func totalOwned(for item: LocalInventoryItem) -> Double? { breakdown(for: item)?.totalOwned }
    func reserved(for item: LocalInventoryItem) -> Double?   { breakdown(for: item)?.reserved }
    func available(for item: LocalInventoryItem) -> Double?  { breakdown(for: item)?.available }

    /// Ingredient-centric projected shortages, earliest/most urgent first.
    /// Auto-clears: a resolved shortage simply stops appearing on the next derive.
    func shortages() -> [ProjectedShortage] { snapshot.shortages }

    /// Meal-centric conflicts, earliest/most urgent first.
    func conflicts() -> [MealConflict] { snapshot.conflicts }

    /// The reservation claims a recipe's ingredients would collide with —
    /// drives the "Ready if plans change" badge and the Cook Anyway review.
    func reservedTouches(ingredientNames: [String]) -> [ReservationClaim] {
        let hits = ReservationEngine.usesReserved(ingredientNames: ingredientNames,
                                                  reservedNames: snapshot.reservedNames)
        guard !hits.isEmpty else { return [] }
        let hitKeys = hits.map { FoodNameMatcher.normalized(RecipeIngredients.parse($0).name.isEmpty
                                                            ? $0 : RecipeIngredients.parse($0).name) }
        var claims: [ReservationClaim] = []
        for breakdown in snapshot.breakdowns {
            for claim in breakdown.claims {
                let key = FoodNameMatcher.normalized(claim.ingredient)
                guard hitKeys.contains(where: { $0.contains(key) || key.contains($0) }) else { continue }
                if !claims.contains(where: { $0.id == claim.id }) { claims.append(claim) }
            }
        }
        return claims.sorted {
            if $0.dayIndex != $1.dayIndex { return $0.dayIndex < $1.dayIndex }
            return ReservationEngine.mealTypeRank($0.mealType) < ReservationEngine.mealTypeRank($1.mealType)
        }
    }

    // MARK: Cook Anyway (RL-004)

    /// Record a Cook Anyway decision and immediately re-derive so every surface
    /// (planner conflicts, item details, Cook Now badges) reflects it.
    func recordOverride(recipeTitle: String,
                        touches: [ReservationClaim],
                        addedReplacementsToGrocery: Bool,
                        store: GuestDataStore) {
        // One consumption entry per distinct ingredient (a claim can be split
        // across several inventory items — sum them, don't duplicate).
        var byIngredient: [String: ReservationOverrideIngredient] = [:]
        var order: [String] = []
        for claim in touches {
            let key = FoodNameMatcher.normalized(claim.ingredient) + "|" + claim.unit
            if var existing = byIngredient[key] {
                existing.amount += claim.amount
                byIngredient[key] = existing
            } else {
                order.append(key)
                byIngredient[key] = ReservationOverrideIngredient(name: claim.ingredient,
                                                                  amount: claim.amount,
                                                                  unit: claim.unit)
            }
        }
        var affected: [String] = []
        for claim in touches where !affected.contains(claim.mealTitle) { affected.append(claim.mealTitle) }

        let record = ReservationOverrideRecord(
            recipeTitle: recipeTitle,
            ingredients: order.compactMap { byIngredient[$0] },
            affectedMealTitles: affected,
            addedReplacementsToGrocery: addedReplacementsToGrocery,
            inventoryRevisionAtCreation: store.inventoryRevision)

        overrideLog.append(record)
        if overrideLog.count > Self.logCap {
            overrideLog.removeFirst(overrideLog.count - Self.logCap)
        }
        LocalDatabase.shared.save(overrideLog, key: Self.logKey)
        overrideStamp &+= 1
        refresh(store: store)
    }
}
