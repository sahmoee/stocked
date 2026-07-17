// ReservationOverrideSheet.swift
// ─────────────────────────────────────────────────────────────────
// RL-004 — the informative (never blocking) Cook Anyway review.
//
// Shown before cooking a recipe whose ingredients are reserved for planned
// meals. It lays out exactly which reservations the cook would consume — the
// ingredient, the linked meal, its scheduled day, and the amount — and offers
// three honest exits:
//
//   • Cook Anyway            — consume the reservations, log the override,
//                              and let every surface recalculate.
//   • Add Replacement…       — put the consumed ingredients on the grocery
//                              list first (deduped via addToGroceryIfMissing).
//   • Choose Another Meal    — back out with the plan intact.
//
// The sheet never mutates plannedMeals or inventory itself; the override is
// recorded through ReservationLedger and reservations re-derive from there.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

/// Item-backed payload so the sheet is always explicitly identifiable
/// (Bool-plus-optional presentation state is against house rules).
struct ReservationOverridePayload: Identifiable {
    let recipe: UserRecipe
    let touches: [ReservationClaim]
    var id: UUID { recipe.id }
}

struct ReservationOverrideSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    let recipe: UserRecipe
    let touches: [ReservationClaim]
    /// Called after the override is recorded — proceed into the cook flow.
    let onCookAnyway: () -> Void

    @State private var addedToGrocery = false

    private var store: GuestDataStore { session.guestStore }

    /// Distinct reserved ingredient names, in claim order.
    private var reservedIngredients: [String] {
        var names: [String] = []
        for t in touches where !names.contains(t.ingredient) { names.append(t.ingredient) }
        return names
    }

    /// Distinct affected meals with their soonest date, soonest first.
    private var affectedMeals: [(title: String, date: Date, dayIndex: Int)] {
        var seen: [String: (Date, Int)] = [:]
        var order: [String] = []
        for t in touches {
            if let existing = seen[t.mealTitle] {
                if t.dayIndex < existing.1 { seen[t.mealTitle] = (t.date, t.dayIndex) }
            } else {
                order.append(t.mealTitle)
                seen[t.mealTitle] = (t.date, t.dayIndex)
            }
        }
        return order.compactMap { title in
            guard let (date, day) = seen[title] else { return nil }
            return (title, date, day)
        }.sorted { $0.dayIndex < $1.dayIndex }
    }

    private func dayLabel(_ dayIndex: Int, _ date: Date) -> String {
        if dayIndex == 0 { return "Today" }
        if dayIndex == 1 { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEEE"
        return f.string(from: date)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {

                        // ── Header ────────────────────────────────────
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                Image(systemName: "calendar.badge.exclamationmark")
                                    .font(.system(size: 18))
                                    .foregroundStyle(Color.stockedGold)
                                Text("Ready if plans change")
                                    .font(.system(size: 22, weight: .bold, design: .serif))
                                    .foregroundStyle(session.themeTextColor)
                            }
                            Text("“\(recipe.title.displayNormalized)” uses ingredients reserved for planned meals. You can still cook it — here's what it touches.")
                                .font(.system(size: 13))
                                .foregroundStyle(session.themeTextColor.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.top, 18)

                        // ── Reserved ingredients it would consume ─────
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(text: "RESERVED INGREDIENTS USED")
                            VStack(spacing: 0) {
                                ForEach(Array(touches.enumerated()), id: \.element.id) { idx, claim in
                                    HStack(spacing: 10) {
                                        FoodIconView(name: claim.ingredient, size: 26, emojiSize: 16)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(claim.ingredient.displayNormalized)
                                                .font(.system(size: 13.5, weight: .semibold))
                                                .foregroundStyle(session.themeTextColor)
                                                .lineLimit(1)
                                            Text("\(claim.mealTitle.displayNormalized) · \(dayLabel(claim.dayIndex, claim.date))")
                                                .font(.system(size: 11.5))
                                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                                                .lineLimit(1)
                                        }
                                        Spacer(minLength: 6)
                                        Text(claim.amountDisplay)
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(Color.stockedGold)
                                            .fixedSize()
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    if idx < touches.count - 1 {
                                        Divider().overlay(session.themeTextColor.opacity(0.08)).padding(.leading, 46)
                                    }
                                }
                            }
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }

                        // ── Affected future meals ─────────────────────
                        VStack(alignment: .leading, spacing: 10) {
                            SectionHeader(text: "PLANNED MEALS AFFECTED")
                            VStack(spacing: 0) {
                                ForEach(Array(affectedMeals.enumerated()), id: \.element.title) { idx, meal in
                                    HStack(spacing: 10) {
                                        Image(systemName: "calendar")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.stockedGold)
                                        Text(meal.title.displayNormalized)
                                            .font(.system(size: 13.5, design: .serif))
                                            .foregroundStyle(session.themeTextColor)
                                            .lineLimit(1)
                                        Spacer(minLength: 6)
                                        Text(dayLabel(meal.dayIndex, meal.date))
                                            .font(.system(size: 11.5, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                                            .fixedSize()
                                    }
                                    .padding(.horizontal, 12).padding(.vertical, 9)
                                    if idx < affectedMeals.count - 1 {
                                        Divider().overlay(session.themeTextColor.opacity(0.08)).padding(.leading, 34)
                                    }
                                }
                            }
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            Text("These meals will be re-checked automatically — anything left short shows up as a conflict in the planner.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(session.themeTextColor.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        // ── Actions ───────────────────────────────────
                        VStack(spacing: 10) {
                            Button {
                                ReservationLedger.shared.recordOverride(
                                    recipeTitle: recipe.title,
                                    touches: touches,
                                    addedReplacementsToGrocery: addedToGrocery,
                                    store: store)
                                HapticManager.success()
                                dismiss()
                                onCookAnyway()
                            } label: {
                                Label("Cook Anyway", systemImage: "flame.fill")
                                    .font(.system(size: 16, weight: .semibold, design: .serif))
                                    .foregroundStyle(Color.stockedWhite)
                                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                                    .background(Color.stockedGold)
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                            }
                            .buttonStyle(.plain)
                            .a11yButton("Cook anyway, consuming reserved ingredients")

                            Button {
                                guard !addedToGrocery else { return }
                                for name in reservedIngredients {
                                    store.addToGroceryIfMissing(name, recommended: true,
                                                                recipeSource: recipe.title)
                                }
                                withAnimation { addedToGrocery = true }
                                HapticManager.success()
                            } label: {
                                Label(addedToGrocery ? "Replacements Added to Grocery" : "Add Replacement to Grocery",
                                      systemImage: addedToGrocery ? "checkmark.circle.fill" : "cart.badge.plus")
                                    .font(.system(size: 14.5, weight: .semibold))
                                    .foregroundStyle(addedToGrocery ? Color.stockedGreen : Color.stockedGold)
                                    .frame(maxWidth: .infinity).padding(.vertical, 13)
                                    .background((addedToGrocery ? Color.stockedGreen : Color.stockedGold).opacity(0.12))
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                            }
                            .buttonStyle(.plain)
                            .disabled(addedToGrocery)

                            Button { dismiss() } label: {
                                Text("Choose Another Meal")
                                    .font(.system(size: 14))
                                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 4)

                        Spacer(minLength: 24)
                    }
                    .padding(.horizontal, 22)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
