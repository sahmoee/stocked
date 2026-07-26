import SwiftUI

// #13 Week meal planner. A simple 7-day view of planned meals that syncs across the household
// (planned meals flow through the same worker document as inventory/recipes). Add a meal to any
// day, mark it cooked, or remove it. Reads/writes session.guestStore.plannedMeals.

struct WeekMealPlannerView: View {
    private static let cardCorner: CGFloat = 20   // matches app card radius (StockedUI.cornerRadiusLg)
    @Environment(AppSession.self) private var session
    @State private var addingDay: Int? = nil
    @State private var newTitle = ""
    @State private var newMealType = "Dinner"
    /// #11 — the meal awaiting a "what did this use?" confirm.
    @State private var cookedMeal: PlannedMeal? = nil

    private let mealTypes = ["Breakfast", "Lunch", "Dinner"]
    private var weekdayNames: [String] {
        let f = DateFormatter()
        let cal = Calendar.current
        return (0..<7).map { offset in
            guard let d = cal.date(byAdding: .day, value: offset, to: Date()) else { return "" }
            if offset == 0 { return "Today" }
            if offset == 1 { return "Tomorrow" }
            f.dateFormat = "EEEE"
            return f.string(from: d)
        }
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Meal Plan") {
            VStack(spacing: 14) {
                ForEach(0..<7, id: \.self) { day in
                    dayCard(day)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
        // #11 — close the loop between "I cooked this" and what's actually left in the pantry.
        .sheet(item: $cookedMeal) { meal in
            CookCompletionSheet(meal: meal)
        }
    }

    private func meals(on day: Int) -> [PlannedMeal] {
        session.guestStore.plannedMeals.filter { $0.dayIndex == day && !$0.isBuilding }
    }

    private func dayCard(_ day: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(weekdayNames[day]).font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                Button { addingDay = (addingDay == day ? nil : day); newTitle = "" } label: {
                    Image(systemName: addingDay == day ? "xmark" : "plus")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain)
                .a11yButton(addingDay == day ? "Cancel adding meal" : "Add a meal to \(weekdayNames[day])")
            }

            let dayMeals = meals(on: day)
            if dayMeals.isEmpty && addingDay != day {
                Text("No meals planned").font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.4))
            }
            ForEach(dayMeals) { meal in
                HStack(spacing: 10) {
                    Button { toggleCooked(meal) } label: {
                        Image(systemName: meal.isCooked ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18)).foregroundStyle(meal.isCooked ? Color.stockedGold : session.themeTextColor.opacity(0.3))
                    }.buttonStyle(.plain)
                    .a11yButton(meal.isCooked ? "Mark \(meal.title) not cooked" : "Mark \(meal.title) cooked")
                    VStack(alignment: .leading, spacing: 1) {
                        Text(meal.title).font(.system(size: 14, weight: .medium))
                            .foregroundStyle(session.themeTextColor)
                            .strikethrough(meal.isCooked)
                        Text(meal.mealType).font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                    Spacer()
                    Button { remove(meal) } label: {
                        Image(systemName: "trash").font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.35))
                    }.buttonStyle(.plain)
                    .a11yButton("Remove \(meal.title)")
                }
                .padding(.vertical, 4)
            }

            if addingDay == day {
                VStack(spacing: 8) {
                    TextField("Meal name", text: $newTitle)
                        .font(.system(size: 14)).foregroundStyle(session.themeTextColor)
                        .padding(10).background(session.themeBgColor, in: RoundedRectangle(cornerRadius: 8))
                    Picker("Type", selection: $newMealType) {
                        ForEach(mealTypes, id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                    Button { addMeal(day) } label: {
                        Text("Add").font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                            .background(Color.stockedGold, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(newTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.top, 4)
            }
        }
        .padding(14)
        .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: Self.cardCorner))
    }

    private func addMeal(_ day: Int) {
        let t = newTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var meal = PlannedMeal(dayIndex: day, title: t, servings: 2, ingredients: [], mealType: newMealType)
        meal.updatedAt = Date().timeIntervalSince1970 * 1000
        session.guestStore.plannedMeals.append(meal)
        newTitle = ""; addingDay = nil
    }
    private func toggleCooked(_ meal: PlannedMeal) {
        guard let i = session.guestStore.plannedMeals.firstIndex(where: { $0.id == meal.id }) else { return }
        session.guestStore.plannedMeals[i].isCooked.toggle()
        // Improvement #11 — marking a meal cooked here used to be a complete no-op on stock, so
        // the ingredients stayed in the pantry forever and every downstream number drifted.
        // Now it offers the deductions (and leftovers) in one confirm step.
        if session.guestStore.plannedMeals[i].isCooked {
            if CookConsumption.hasProposals(for: meal, store: session.guestStore) {
                cookedMeal = meal
            } else {
                session.guestStore.addLeftover(named: meal.title, servings: meal.servings)
            }
        }
    }
    private func remove(_ meal: PlannedMeal) {
        session.guestStore.plannedMeals.removeAll { $0.id == meal.id }
    }
}
