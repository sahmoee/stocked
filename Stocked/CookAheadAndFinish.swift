// CookAheadAndFinish.swift
// ─────────────────────────────────────────────────────────────────
// Cook Ahead Now and Finish & Serve — cooking a planned dinner earlier in the
// day WITHOUT changing the plan.
//
// The rule, straight from the spec: cooking early changes only the cook time.
// The meal stays on its planned day. It is never marked eaten, never moved to
// lunch, never removed from tonight. It moves through a cook-ahead lifecycle
// (prepped → marinating → cooking early → cooked → cooling → stored → ready to
// reheat → served) and later surfaces under Finish & Serve with reheat and
// finishing guidance.
//
// Two surfaces here:
//   • CookAheadStatusView — the status tracker for one meal being cooked ahead,
//     with cooling/storage/reheat guidance and lifecycle advance.
//   • FinishAndServeView — the list of everything cooked ahead and waiting,
//     each opening its status tracker / finish steps. (Replaces the batch 7
//     Finish & Serve stub.)
// ─────────────────────────────────────────────────────────────────

import SwiftUI

// MARK: - Cook Ahead status tracker (one meal)

struct CookAheadStatusView: View {
    let mealID: UUID

    @Environment(AppSession.self) var session
    @Environment(\.dismiss) private var dismiss
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    private var meal: PlannedMeal? { store.plannedMeals.first { $0.id == mealID } }

    /// The lifecycle stages we walk the user through (served is terminal).
    private let flow: [CookAheadStatus] = [.cookingEarly, .cooked, .cooling, .stored, .readyToReheat, .served]

    var body: some View {
        StockedShell(showBack: true, titleText: "Cook Ahead") {
            if let meal {
                VStack(alignment: .leading, spacing: 18) {
                    header(meal)
                    timeline(meal)
                    guidance(meal)
                    advanceButton(meal)
                    Spacer(minLength: 20)
                }
            } else {
                CookEmptyStateInline(text: "This meal is no longer available.")
            }
        }
    }

    private func header(_ meal: PlannedMeal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meal.title)
                .scaledFont(22, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            HStack(spacing: 6) {
                Image(systemName: meal.cookAheadStatus.icon).scaledFont(12, weight: .semibold)
                Text(meal.cookAheadStatus.label)
                    .scaledFont(13, weight: .semibold)
            }
            .foregroundStyle(Color.stockedGold)
            Text("Still planned for \(dayLabel(meal.dayIndex)) · \(meal.mealType). Cooking early only changes the cook time.")
                .scaledFont(12.5)
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
    }

    private func timeline(_ meal: PlannedMeal) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(flow.enumerated()), id: \.offset) { idx, stage in
                let reached = flowIndex(meal.cookAheadStatus) >= idx
                HStack(spacing: 10) {
                    ZStack {
                        Circle().fill(reached ? Color.stockedGreen : session.themeTextColor.opacity(0.15)).frame(width: 22, height: 22)
                        if reached { Image(systemName: "checkmark").scaledFont(10, weight: .bold).foregroundStyle(Color.stockedWhite) }
                    }
                    Text(stage.label)
                        .font(.stockedSystem(size: 13.5, weight: reached ? .semibold : .regular))
                        .foregroundStyle(reached ? session.themeTextColor : session.themeTextColor.opacity(0.5))
                    Spacer()
                }
                .padding(.vertical, 5)
                if idx < flow.count - 1 {
                    Rectangle().fill(reached ? Color.stockedGreen.opacity(0.4) : session.themeTextColor.opacity(0.1))
                        .frame(width: 2, height: 14).padding(.leading, 10)
                }
            }
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    /// Stage-appropriate cooling / storage / reheat guidance.
    private func guidance(_ meal: PlannedMeal) -> some View {
        let tips = guidanceTips(for: meal.cookAheadStatus)
        return Group {
            if !tips.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("For best results")
                        .scaledFont(14, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    ForEach(tips, id: \.self) { tip in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "checkmark.circle").scaledFont(12).foregroundStyle(Color.stockedGold).padding(.top, 1)
                            Text(tip).scaledFont(12.5).foregroundStyle(session.themeTextColor.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                .padding(.horizontal, CookStyle.screenHPad)
            }
        }
    }

    private func guidanceTips(for status: CookAheadStatus) -> [String] {
        switch status {
        case .cookingEarly, .cooked:
            return ["Let it cool before covering so it doesn't steam and go soggy.",
                    "Keep any crisp components separate — re-crisp them at serving.",
                    "Reserve some cooking liquid to add back when reheating."]
        case .cooling:
            return ["Cool at room temperature no longer than two hours, then refrigerate.",
                    "Store in a shallow container so it cools evenly."]
        case .stored:
            return ["Reheat gently, covered, adding a splash of the reserved liquid.",
                    "Make fresh sides (rice, salad) closer to serving.",
                    "Crisp components can go under the broiler for a minute."]
        case .readyToReheat:
            return ["Warm through covered, then finish uncovered if you want a crisp top.",
                    "Add fresh herbs or a squeeze of acid right before serving."]
        default:
            return []
        }
    }

    private func advanceButton(_ meal: PlannedMeal) -> some View {
        let next = nextStage(after: meal.cookAheadStatus)
        return VStack(spacing: 8) {
            if let next {
                Button {
                    store.setCookAheadStatus(next, for: meal.id)
                    HapticManager.light()
                } label: {
                    Text(next == .served ? "Serve Now" : "Mark \(next.label)")
                        .scaledFont(15.5, weight: .semibold, design: .serif)
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                        .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL).stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .buttonStyle(.plain)
            } else {
                Text("Served — enjoy!")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(Color.stockedGreen)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    // MARK: Helpers

    private func flowIndex(_ status: CookAheadStatus) -> Int { flow.firstIndex(of: status) ?? -1 }
    private func nextStage(after status: CookAheadStatus) -> CookAheadStatus? {
        guard let i = flow.firstIndex(of: status) else { return flow.first }
        return i + 1 < flow.count ? flow[i + 1] : nil
    }
    private func dayLabel(_ idx: Int) -> String {
        switch idx { case 0: return "today"; case 1: return "tomorrow"; default: return "day \(idx + 1)" }
    }
}

// MARK: - Finish & Serve (replaces batch 7 stub)

struct FinishAndServeView: View {
    @Environment(AppSession.self) var session
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var openMealID: UUID? = nil
    @State private var goStatus = false

    private var meals: [PlannedMeal] { store.cookedAheadMeals }

    var body: some View {
        StockedShell(showBack: true, titleText: "Finish & Serve") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cooked ahead, ready to finish")
                    .scaledFont(20, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

                if meals.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "refrigerator").scaledFont(36).foregroundStyle(session.themeTextColor.opacity(0.3))
                        Text("Nothing waiting to finish")
                            .scaledFont(16, weight: .semibold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Text("When you cook a planned meal early, it'll appear here with reheat and finishing steps.")
                            .scaledFont(13)
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    VStack(spacing: 10) {
                        ForEach(meals) { meal in
                            mealCard(meal)
                        }
                    }
                    .padding(.horizontal, CookStyle.screenHPad)
                }
                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goStatus) {
                if let openMealID { CookAheadStatusView(mealID: openMealID) }
            }
        }
    }

    private func mealCard(_ meal: PlannedMeal) -> some View {
        Button { openMealID = meal.id; goStatus = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.stockedGold.opacity(0.14)).frame(width: 42, height: 42)
                    Image(systemName: meal.cookAheadStatus.icon).scaledFont(17, weight: .semibold).foregroundStyle(Color.stockedGold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(meal.title)
                        .scaledFont(15, weight: .semibold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text("\(meal.cookAheadStatus.label) · for \(dayLabel(meal.dayIndex)) \(meal.mealType.lowercased())")
                        .scaledFont(12)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
                Spacer()
                Image(systemName: "chevron.right").scaledFont(12, weight: .semibold).foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(14)
            .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }
        .buttonStyle(.plain)
        .a11yButton("\(meal.title), \(meal.cookAheadStatus.label). Open to finish and serve.")
    }

    private func dayLabel(_ idx: Int) -> String {
        switch idx { case 0: return "today"; case 1: return "tomorrow"; default: return "day \(idx + 1)" }
    }
}

// MARK: - Small inline empty state

struct CookEmptyStateInline: View {
    let text: String
    @Environment(AppSession.self) var session
    var body: some View {
        VStack {
            Text(text)
                .scaledFont(14)
                .foregroundStyle(session.themeTextColor.opacity(0.55))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
        .padding(.horizontal, CookStyle.screenHPad)
    }
}
