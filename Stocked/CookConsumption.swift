// CookConsumption.swift — Improvement #11: cooking a meal should change what's in the pantry.
//
// This is the single biggest gap between what the app models and what happened in the kitchen.
// There are four cook-complete paths and only ONE of them touches inventory:
//
//   CookingFlow.finishMeal            → deducts, but only via a sheet the user can skip
//   WeekMealPlannerView.toggleCooked  → adds a leftover row, no deduction at all
//   CookLaterCommandCenter.toggleCooked → same
//   GuestDataStore.setCookAheadStatus → same
//
// So marking a planned meal cooked from the planner — the most common way people do it — is a
// complete no-op on stock. The chicken stays in the pantry forever. Every downstream number is
// then wrong: pantry value, low-stock alerts, readiness days, waste insights, and the reservation
// engine's "available" figure.
//
// This builds proposed deductions from a meal's ingredient list and routes them through the
// existing `ProposedChange` + `ReconcileSheet` primitive — the app's cleanest deduction path,
// already used by the inventory-intent parser. The user confirms; nothing is deducted behind
// their back.

import SwiftUI

// MARK: - Proposal builder

@MainActor
enum CookConsumption {

    /// How much of a container one serving of a dish is assumed to use.
    ///
    /// Deliberately conservative. Over-deducting makes the app tell people they're out of things
    /// they still have, which is the failure mode that destroys trust in a pantry app; under-
    /// deducting just means they correct it later. `StockedDeductions` uses a flat 0.25 regardless
    /// of servings — this at least scales with the size of the meal.
    static func portionUsed(servings: Int) -> Double {
        let base = 0.2
        let scaled = base * (Double(max(1, servings)) / 2.0)
        return min(0.75, max(0.1, scaled))
    }

    /// Match a meal's ingredients against inventory and propose a level reduction for each hit.
    ///
    /// Ingredients with no inventory match are skipped silently — a recipe naming "salt" when the
    /// user never logged salt is normal, not an error worth surfacing.
    static func proposals(for meal: PlannedMeal, store: GuestDataStore) -> [ProposedChange] {
        let portion = portionUsed(servings: meal.servings)
        var out: [ProposedChange] = []
        var claimed = Set<UUID>()

        for line in meal.ingredients {
            let name = RecipeIngredients.parse(line).name
            let needle = name.isEmpty ? line : name
            guard !needle.trimmingCharacters(in: .whitespaces).isEmpty else { continue }

            // First unclaimed match, so a recipe listing "onion" twice doesn't deduct one item
            // twice as far.
            guard let item = store.inventoryItems.first(where: {
                !claimed.contains($0.id)
                && $0.level > 0
                && IngredientStockMatch.matches(ingredient: needle, itemName: $0.name)
            }) else { continue }

            claimed.insert(item.id)
            let newLevel = max(0, item.level - portion)

            out.append(ProposedChange(
                itemID: item.id,
                displayName: item.name,
                action: newLevel <= 0.01 ? .remove : .setLevel(newLevel),
                reason: newLevel <= 0.01 ? "Used up cooking \(meal.title)" : "Used cooking \(meal.title)"))
        }
        return out
    }

    /// True when there's anything worth asking the user about.
    static func hasProposals(for meal: PlannedMeal, store: GuestDataStore) -> Bool {
        !proposals(for: meal, store: store).isEmpty
    }
}

// MARK: - Sheet presentation

/// Wraps `ReconcileSheet` with cooking-specific copy, and offers to capture leftovers in the same
/// step — the moment a meal is marked cooked is exactly when someone knows whether there are any.
struct CookCompletionSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let meal: PlannedMeal
    var onDone: () -> Void = {}

    @State private var saveLeftovers = false
    @State private var leftoverPortions = 2

    private var proposals: [ProposedChange] {
        CookConsumption.proposals(for: meal, store: session.guestStore)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                List {
                    Section {
                        ForEach(proposals) { change in
                            HStack {
                                Image(systemName: "minus.circle")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(change.displayName).stockedFont(.rowTitle)
                                    Text(change.effectText).stockedFont(.caption)
                                        .foregroundStyle(session.themeSecondaryText)
                                }
                            }
                        }
                    } header: {
                        Text("Update your pantry")
                    } footer: {
                        Text(proposals.isEmpty
                             ? "Nothing in your pantry matched this meal's ingredients, so there's nothing to deduct."
                             : "Amounts are estimates based on \(meal.servings) serving\(meal.servings == 1 ? "" : "s"). You can adjust anything afterwards in Inventory.")
                    }

                    Section {
                        Toggle("Save leftovers", isOn: $saveLeftovers)
                        if saveLeftovers {
                            Stepper("\(leftoverPortions) portion\(leftoverPortions == 1 ? "" : "s")",
                                    value: $leftoverPortions, in: 1...20)
                        }
                    } footer: {
                        Text("Leftovers get their own clock so they're eaten instead of forgotten.")
                    }
                }
                .listStyle(.insetGrouped)

                Button {
                    apply()
                } label: {
                    Text(proposals.isEmpty ? "Done" : "Update pantry")
                        .scaledFont(16, weight: .semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(session.accentColor).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 18).padding(.bottom, 14)
            }
            .stockedScreen()
            .navigationTitle("Cooked \(meal.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Skip") { onDone(); dismiss() }
                }
            }
        }
    }

    private func apply() {
        let changes = proposals

        // #5 — snapshot levels BEFORE the write. Taking it afterwards would capture the
        // post-deduction values and make "undo" a no-op.
        let snapshot: [(id: UUID, level: Double)] = changes.compactMap { change in
            guard let id = change.itemID,
                  let item = session.guestStore.inventoryItems.first(where: { $0.id == id })
            else { return nil }
            return (id, item.level)
        }

        let applied = session.guestStore.applyProposalBatch(
            InventoryProposalBatch(
                origin: .reconciliation,
                title: "Pantry update for \(meal.title)",
                changes: changes,
                mergePolicy: .storeCompatible
            ),
            brandPreferences: session.guestStore.cookingProfile.brandPreferences,
            retailerID: GroceryKnowledgeBase.retailer(matching: session.preferredStore)?.id,
            // This flow already provides its immediate, level-specific undo toast below.
            registerUndo: false
        ).appliedCount

        if saveLeftovers {
            LeftoversStore.shared.add(title: meal.title, portions: leftoverPortions, storage: "Fridge")
        }

        // Deduction is estimated, so it always gets an undo — the amounts are a guess and the
        // user should be able to take it back without hunting through Inventory.
        if applied > 0 {
            let store = session.guestStore
            ToastCenter.shared.undo("Pantry updated for \(meal.title)") {
                for entry in snapshot {
                    store.updateInventoryLevel(id: entry.id, level: entry.level)
                }
            }
        }

        HapticManager.success()
        onDone()
        dismiss()
    }
}
