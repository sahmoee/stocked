// CookLaterFlows.swift — Cook Later branch (Checkpoint 3).
//
// Per the build decision, Cook Later WRAPS the existing planner rather than replacing it. Cook
// Later Home is a new styled entry that surfaces upcoming planned meals and routes into the real
// MealPlannerView (the Weekly Planner) and MealPrepView (Prep Work). It reuses store.plannedMeals
// and the existing planning/prep flows — no parallel planner is built.

import SwiftUI

struct CookLaterHomeView: View {
    @Environment(AppSession.self) private var session
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var goPlanner = false
    @State private var goPrep = false

    // Upcoming = not-yet-cooked planned meals, soonest day first.
    private var upcoming: [PlannedMeal] {
        store.plannedMeals
            .filter { !$0.isCooked }
            .sorted { $0.dayIndex < $1.dayIndex }
    }

    private func dayLabel(_ idx: Int) -> String {
        switch idx {
        case 0: return "Today"
        case 1: return "Tomorrow"
        default: return "In \(idx) days"
        }
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Cook Later") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("The week, handled.")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Plan meals ahead and prep with confidence.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

                // Plan-ahead hero → the real Weekly Planner.
                VStack(spacing: CookStyle.sectionSpacing) {
                    CookHeroCard(
                        title: "Plan a Meal",
                        subtitle: "Add meals to any day of the week.",
                        icon: "calendar.badge.plus",
                        tint: Color.stockedCharcoal, textOnDark: true
                    ) { goPlanner = true }

                    CookHeroCard(
                        title: "Prep Work",
                        subtitle: "Get a prep checklist for your planned meals.",
                        icon: "checklist",
                        tint: Color.stockedGold, textOnDark: true
                    ) { goPrep = true }
                }
                .padding(.horizontal, CookStyle.screenHPad)

                // Upcoming plans (PlannerCard list) or empty state.
                VStack(alignment: .leading, spacing: 10) {
                    Text("Upcoming Plans")
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .padding(.horizontal, CookStyle.screenHPad)

                    if upcoming.isEmpty {
                        CookEmptyState(
                            icon: "calendar",
                            title: "Nothing planned yet",
                            message: "Plan a meal and it'll show up here for the week ahead.",
                            ctaTitle: "Plan a Meal"
                        ) { goPlanner = true }
                    } else {
                        VStack(spacing: 10) {
                            ForEach(upcoming.prefix(8)) { meal in
                                CookPlannerCard(
                                    title: meal.title,
                                    subtitle: dayLabel(meal.dayIndex),
                                    mealType: meal.mealType,
                                    isCooked: meal.isCooked
                                ) { goPlanner = true }
                            }
                        }
                        .padding(.horizontal, CookStyle.screenHPad)
                    }
                }

                Spacer(minLength: 20)
            }
        }
        .navigationDestination(isPresented: $goPlanner) { MealPlannerView(servings: 4) }
        .navigationDestination(isPresented: $goPrep) { MealPrepView() }
    }
}
