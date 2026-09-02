// PlannedMealCookTransition.swift
// ─────────────────────────────────────────────────────────────────
// The bridge between the meal planner and the cooking workspace. Opening a
// planned meal to cook offers the choices the spec requires, and crucially
// preserves the relationship between the cooking session and the planned meal:
//
//   • Start Cooking — cook it now for its planned slot (today's dinner, now).
//   • Cook Ahead Now — cook it earlier than planned; it STAYS on its day and
//     enters the cook-ahead lifecycle (→ Finish & Serve later). Cooking early
//     changes only the cook time, never the plan.
//   • Prep Only — just get ingredients ready.
//   • Simplify / one component — scope down without leaving the plan.
//
// This is a lightweight sheet the planner presents. It links the CookNowSession
// to the meal (plannedMealID + serve-later/cook-ahead flags) so downstream
// screens know they're serving a planned meal.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct PlannedMealCookTransitionView: View {
    let meal: PlannedMeal

    @Environment(AppSession.self) var session
    @Environment(\.dismiss) private var dismiss
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    /// Callbacks so the presenting planner controls navigation.
    var onStartCooking: (PlannedMeal) -> Void
    var onCookAhead:    (PlannedMeal) -> Void
    var onPrepOnly:     (PlannedMeal) -> Void

    private var isFuture: Bool { meal.dayIndex > 0 }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 16) {
                    header
                    VStack(spacing: 10) {
                        // Cook ahead leads when the meal is planned for a future day.
                        if isFuture {
                            choice(icon: "clock.arrow.circlepath", title: "Cook Ahead Now",
                                   subtitle: "Cook it early — it stays on \(dayLabel(meal.dayIndex))'s plan and moves to Finish & Serve.",
                                   primary: true) {
                                store.setCookAheadStatus(.cookingEarly, for: meal.id)
                                dismiss(); onCookAhead(meal)
                            }
                            choice(icon: "flame", title: "Start Cooking (serve now)",
                                   subtitle: "Cook and eat now instead of \(dayLabel(meal.dayIndex)).", primary: false) {
                                dismiss(); onStartCooking(meal)
                            }
                        } else {
                            choice(icon: "flame", title: "Start Cooking",
                                   subtitle: "Cook it now for \(meal.mealType.lowercased()).", primary: true) {
                                dismiss(); onStartCooking(meal)
                            }
                            choice(icon: "clock.arrow.circlepath", title: "Cook Ahead",
                                   subtitle: "Cook now, cool and store, finish at meal time.", primary: false) {
                                store.setCookAheadStatus(.cookingEarly, for: meal.id)
                                dismiss(); onCookAhead(meal)
                            }
                        }
                        choice(icon: "list.bullet.clipboard", title: "Prep Only",
                               subtitle: "Just get the ingredients ready for later.", primary: false) {
                            store.setCookAheadStatus(.prepped, for: meal.id)
                            dismiss(); onPrepOnly(meal)
                        }
                    }
                    Text("However you cook it, the meal keeps its place on your plan until you serve it.")
                        .scaledFont(11.5)
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 4)
                    Spacer()
                }
                .padding(20)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(meal.title)
                .scaledFont(20, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            Text("Planned for \(dayLabel(meal.dayIndex)) · \(meal.mealType)")
                .scaledFont(12.5, weight: .semibold)
                .foregroundStyle(Color.stockedGold)
        }
    }

    private func choice(icon: String, title: String, subtitle: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button {
            action()
            HapticManager.light()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(primary ? Color.stockedGold.opacity(0.2) : Color.stockedGold.opacity(0.1))
                        .frame(width: 40, height: 40)
                    Image(systemName: icon).scaledFont(16, weight: .semibold).foregroundStyle(Color.stockedGold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .scaledFont(15, weight: .semibold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text(subtitle)
                        .scaledFont(12)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").scaledFont(12, weight: .semibold).foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(primary
                        ? (dark ? Color.darkSurface : Color.stockedWhite.opacity(0.8))
                        : (dark ? Color.darkSurface.opacity(0.6) : Color.stockedWhite.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                .stroke(primary ? Color.stockedGold.opacity(0.4) : Color.clear, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }
        .buttonStyle(.plain)
        .a11yButton("\(title). \(subtitle)")
    }

    private func dayLabel(_ idx: Int) -> String {
        switch idx { case 0: return "today"; case 1: return "tomorrow"; default: return "day \(idx + 1)" }
    }
}
