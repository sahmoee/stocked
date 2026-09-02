// MealPlannerSubViews.swift — Calendar and list sub-views for MealPlannerView.
// Extracted from MealPlannerView.swift (item #17).
// Add this file to your Xcode project target.
import SwiftUI
import EventKit

// MARK: - MealPlannerView sub-view extensions
extension MealPlannerView {

// MARK: - Calendar Grid View
    var calendarGrid: some View {
        let cal = Calendar.current
        let today = Date()
        let weekdaySymbols = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"]

        // Build a 4-week calendar starting from the nearest Sunday before today
        let todayWeekday = cal.component(.weekday, from: today) - 1
        let calStart = cal.date(byAdding: .day, value: -todayWeekday, to: today) ?? today

        return VStack(alignment: .leading, spacing: 0) {
            // Weekday headers
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { d in
                    Text(d).scaledFont(10, weight: .bold)
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20).padding(.bottom, 8)

            // 4-week grid
            ForEach(0..<4, id: \.self) { week in
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { weekday in
                        let day = cal.date(byAdding: .day, value: week * 7 + weekday, to: calStart) ?? calStart
                        let dayNum = cal.component(.day, from: day)
                        let isToday = cal.isDateInToday(day)
                        let isPast = day < cal.startOfDay(for: today) && !isToday
                        let offset = cal.dateComponents([.day], from: cal.startOfDay(for: today), to: cal.startOfDay(for: day)).day ?? 0
                        let hasMeal = (0..<7).contains(offset) && !meals(for: offset).isEmpty
                        let pastMeal = session.guestStore.pastMeals.first { $0.date == shortDate(day) }
                        let isSelected = selectedCalendarDay == offset && (0..<7).contains(offset)

                        CalendarDayCell(
                            dayNum:     dayNum,
                            isToday:    isToday,
                            isPast:     isPast,
                            offset:     offset,
                            hasMeal:    hasMeal,
                            pastMeal:   pastMeal,
                            isSelected: isSelected,
                            onTap: {
                                if (0..<7).contains(offset) {
                                    motion.animate(.standard, intent: .spatial) {
                                        selectedCalendarDay = selectedCalendarDay == offset ? nil : offset
                                    }
                                }
                            },
                            onDrop: { itemName, dayOffset in
                                let meal = PlannedMeal(
                                    dayIndex:    dayOffset,
                                    title:       itemName,
                                    servings:    2,
                                    ingredients: [itemName],
                                    mealType:    "Dinner"
                                )
                                motion.animate(.standard, intent: .spatial) {
                                    plannedMeals.append(meal)
                                    selectedCalendarDay = dayOffset
                                }
                                HapticManager.success()
                            }
                        )
                        .environment(session)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 2)
            }
            .padding(.bottom, 12)

            // Legend
            HStack(spacing: 16) {
                HStack(spacing: 5) { Circle().fill(Color.stockedGold).frame(width:7,height:7); Text("Planned").font(.stockedSystem(size:10)).foregroundStyle(session.themeTextColor.opacity(0.5)) }
                HStack(spacing: 5) { Circle().fill(Color.stockedGreen).frame(width:7,height:7); Text("Cooked").font(.stockedSystem(size:10)).foregroundStyle(session.themeTextColor.opacity(0.5)) }
            }
            .padding(.horizontal, 24).padding(.bottom, 12)

            // Day detail panel — shown when a day is tapped
            if let selDay = selectedCalendarDay {
                calendarDayDetail(dayOffset: selDay)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                                            removal: .opacity))
            }
        }
    }

    // #1 — Convert a drag-built meal into a saved recipe and clear its building state.
    func saveBuildingMealAsRecipe(_ meal: PlannedMeal) {
        let recipe = UserRecipe(
            title:       meal.title == "New Recipe" ? "My Recipe" : meal.title,
            servings:    meal.servings,
            ingredients: meal.ingredients.map { RecipeIngredient(name: $0, amount: "") }
        )
        session.guestStore.addUserRecipe(recipe)
        // Mark the planned meal as no longer "building" (now a real scheduled meal).
        if let idx = plannedMeals.firstIndex(where: { $0.id == meal.id }) {
            plannedMeals[idx].isBuilding = false
        }
        HapticManager.success()
        withAnimation { savedRecipeToast = "Saved “\(recipe.title.displayNormalized)” to your recipes" }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { withAnimation { savedRecipeToast = nil } }
        }
    }

    // MARK: - Calendar Day Detail Panel
    @ViewBuilder
    private func calendarDayDetail(dayOffset: Int) -> some View {
        let dayLabel = days[min(dayOffset, days.count - 1)].label
        let mealsForDay = meals(for: dayOffset)
        let isFuture = dayOffset > 0

        VStack(alignment: .leading, spacing: 0) {
            // Day header row
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        Text(dayLabel)
                            .scaledFont(16, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        if isFuture && !mealsForDay.isEmpty {
                            Text("SCHEDULED")
                                .scaledFont(9, weight: .bold)
                                .foregroundStyle(Color.stockedGold)
                                .padding(.horizontal, 7).padding(.vertical, 3)
                                .background(Color.stockedGold.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                    Text(mealsForDay.isEmpty ? "No meals planned" : "\(mealsForDay.count) meal\(mealsForDay.count == 1 ? "" : "s") planned")
                        .scaledFont(11)
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                }
                Spacer()
                // Quick-add button for future days
                if isFuture || dayOffset == 0 {
                    Button {
                        withAnimation { activeSheet = .quickAdd(day: dayOffset) }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "plus")
                                .scaledFont(11, weight: .semibold)
                            Text("Add")
                                .scaledFont(12, weight: .semibold)
                        }
                        .foregroundStyle(Color.stockedWhite)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color.stockedGold).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Divider().padding(.horizontal, 16)

            if mealsForDay.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "fork.knife")
                            .scaledFont(22).foregroundStyle(session.themeTextColor.opacity(0.2))
                        Text("Tap + Add to plan a meal for this day")
                            .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.35))
                            .multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 20)
                    Spacer()
                }
            } else {
                ForEach(mealsForDay) { meal in
                    VStack(spacing: 0) {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 6) {
                                    Text(meal.mealType.uppercased())
                                        .scaledFont(9, weight: .bold)
                                        .foregroundStyle(Color.stockedGold)
                                    if meal.isBuilding {
                                        Text("Building")
                                            .scaledFont(9, weight: .semibold)
                                            .foregroundStyle(Color.stockedGreen)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Color.stockedGreen.opacity(0.12))
                                            .clipShape(Capsule())
                                    } else if isFuture {
                                        Text("Scheduled")
                                            .scaledFont(9, weight: .semibold)
                                            .foregroundStyle(Color.stockedGold.opacity(0.7))
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Color.stockedGold.opacity(0.10))
                                            .clipShape(Capsule())
                                    }
                                }
                                // Building meals: tap the title to rename it.
                                if meal.isBuilding {
                                    Button {
                                        renamingMeal = meal
                                        renameText = meal.title
                                    } label: {
                                        HStack(spacing: 5) {
                                            Text(meal.title.displayNormalized)
                                                .scaledFont(14, design: .serif)
                                                .foregroundStyle(session.themeTextColor)
                                            Image(systemName: "pencil")
                                                .scaledFont(10).foregroundStyle(session.themeTextColor.opacity(0.4))
                                        }
                                    }.buttonStyle(.plain)
                                } else {
                                    Text(meal.title.displayNormalized)
                                        .scaledFont(14, design: .serif)
                                        .foregroundStyle(session.themeTextColor)
                                }
                                Text(meal.isBuilding
                                     ? "\(meal.ingredients.count) ingredient\(meal.ingredients.count == 1 ? "" : "s")"
                                     : "\(meal.servings) serving\(meal.servings == 1 ? "" : "s")")
                                    .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.4))
                            }
                            Spacer()
                            HStack(spacing: 6) {
                                if meal.isBuilding {
                                    Button { saveBuildingMealAsRecipe(meal) } label: {
                                        Text("Save")
                                            .scaledFont(11, weight: .semibold)
                                            .foregroundStyle(Color.stockedGreen)
                                            .padding(.horizontal, 9).padding(.vertical, 5)
                                            .overlay(Capsule().stroke(Color.stockedGreen, lineWidth: 1))
                                    }.buttonStyle(.plain)
                                }
                                Button { preppingMeal = meal; navigateToPrep = true } label: {
                                    Text("Prep")
                                        .scaledFont(11, weight: .semibold)
                                        .foregroundStyle(Color.stockedGold)
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .overlay(Capsule().stroke(Color.stockedGold, lineWidth: 1))
                                }.buttonStyle(.plain)
                                Button { cookTransitionMeal = meal } label: {
                                    Text("Cook Now")
                                        .scaledFont(11, weight: .semibold)
                                        .foregroundStyle(Color.stockedWhite)
                                        .padding(.horizontal, 9).padding(.vertical, 5)
                                        .background(Color.stockedGold).clipShape(Capsule())
                                }.buttonStyle(.plain)
                                Button { withAnimation { plannedMeals.removeAll { $0.id == meal.id } } } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .scaledFont(18)
                                        .foregroundStyle(session.themeTextColor.opacity(0.25))
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 10)
                        // RL-005 — projected shortages for this meal, with repairs.
                        ForEach(conflicts(for: meal)) { conflict in
                            PlanConflictRow(conflict: conflict,
                                            onAddToGrocery: { repairAddToGrocery(conflict) },
                                            onRelease:      { releaseReservation(conflict) })
                                .padding(.horizontal, 16).padding(.bottom, 8)
                        }
                        Divider().padding(.horizontal, 16)
                    }
                }
            }
        }
        .background(session.isDarkMode ? Color.darkSurface.opacity(0.9) : Color.stockedWhite.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    // MARK: - List View
    var listView: some View {
        VStack(spacing: 12) {
            ForEach(days.indices, id: \.self) { i in
                DayPlanCard(
                    dayLabel:    days[i].label,
                    dayIndex:    i,
                    meals:       meals(for: i),
                    isExpanded:  selectedDay == i,
                    mealTypes:   mealTypes,
                    onToggle:    { motion.animate(.standard, intent: .spatial) { selectedDay = selectedDay == i ? -1 : i } },
                    onAddMeal:   { type in activeSheet = .picker(day: i, type: type) },
                    onRemoveMeal:{ meal in withAnimation { plannedMeals.removeAll { $0.id == meal.id } } },
                    onCookNow:   { meal in cookTransitionMeal = meal },
                    onPrepNow:   { meal in preppingMeal = meal; navigateToPrep = true },
                    conflictsByMeal:  conflictsByMeal,
                    onConflictGrocery: { repairAddToGrocery($0) },
                    onConflictRelease: { releaseReservation($0) }
                )
            }
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
    }

    // MARK: - Summary Footer
    var summaryFooter: some View {
        VStack(spacing: 14) {
            HStack(spacing: 0) {
                summaryBadge(value: "\(plannedMeals.count)", label: "Meals Planned")
                Divider().frame(height: 32)
                summaryBadge(value: "\(missingIngredients.count)", label: "Items Missing")
                Divider().frame(height: 32)
                // RL-005 — cross-meal shortages (reservations + expiry), not
                // just plain missing items; derived live from the edit state.
                summaryBadge(value: "\(planConflicts.count)", label: "Conflicts")
            }
            .padding(16)
            .background(Color.stockedWhite.opacity(0.28)).clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20)

            if !missingIngredients.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Missing ingredients").scaledFont(12, weight: .bold)
                        .foregroundStyle(session.themeTextColor.opacity(0.45)).padding(.horizontal, 24)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(missingIngredients.prefix(8), id: \.self) { ing in
                                Text(ing).scaledFont(12, weight: .semibold)
                                    .foregroundStyle(Color.stockedGold)
                                    .padding(.horizontal, 12).padding(.vertical, 10)
                                    .background(Color.stockedGold.opacity(0.10))
                                    .clipShape(Capsule())
                            }
                        }
                        .stockedScrollTargetLayout().padding(.horizontal, 20)
                    }
                    .stockedHorizontalSnap()
                }
            }

            // Improvement #6: close the plan→grocery loop for the WHOLE week in one tap.
            // generateGroceryFromMealPlan() already skips in-stock items, cooked meals, and
            // dedupes against the list — it just never had a caller until now.
            Button {
                let added = session.guestStore.generateGroceryFromMealPlan()
                ToastCenter.shared.success(added > 0
                    ? "Added \(added) item\(added == 1 ? "" : "s") to grocery"
                    : "Grocery already has everything for this plan")
                HapticManager.select()
            } label: {
                Label("Build Grocery List", systemImage: "cart.badge.plus")
                    .scaledFont(16, weight: .semibold, design: .serif)
                    .foregroundStyle(Color.stockedCharcoal)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(Color.stockedGold.opacity(0.18))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                        .stroke(Color.stockedGold.opacity(0.5), lineWidth: 1))
            }
            .buttonStyle(.plain).padding(.horizontal, 24)

            Button { savePlan() } label: {
                Label("Save Plan", systemImage: "checkmark.circle.fill")
                    .scaledFont(16, weight: .semibold, design: .serif)
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }
            .buttonStyle(.plain).padding(.horizontal, 24).padding(.bottom, 16)
        }
    }

    // MARK: - Helpers
    private func shortDate(_ d: Date) -> String {
        DateFormatter.localizedString(from: d, dateStyle: .short, timeStyle: .none)
    }

    private func summaryBadge(value: String, label: String) -> some View {
        VStack(spacing: 3) {
            Text(value).scaledFont(22, weight: .bold, design: .serif).foregroundStyle(Color.stockedGold)
            Text(label).scaledFont(10).foregroundStyle(session.themeTextColor.opacity(0.5))
        }.frame(maxWidth: .infinity)
    }

    private func savePlan() {
        for meal in plannedMeals {
            let mealDate = Calendar.current.date(byAdding: .day, value: meal.dayIndex, to: Date()) ?? Date()
            let dateStr = shortDate(mealDate)
            session.guestStore.pastMeals.append(LocalPastMeal(title: "\(meal.mealType): \(meal.title)", date: dateStr))
        }
        saved = true
    }

    // Called immediately after a recipe is added to the plan
    func handleRecipeAdded(_ meal: PlannedMeal) {
        let missing = meal.ingredients.filter { ing in
            let lower = ing.lowercased()
            let inStock = session.guestStore.inventoryItems.contains {
                $0.name.lowercased().contains(lower) || lower.contains($0.name.lowercased())
            }
            let inList = session.guestStore.groceryItems.contains {
                $0.name.lowercased() == lower
            }
            return !inStock && !inList
        }
        guard !missing.isEmpty else { return }

        if session.autoAddMissingToGrocery {
            // Toggle ON — send directly without asking
            for ing in missing {
                session.guestStore.addToGroceryIfMissing(ing, recommended: true, recipeSource: meal.title)
            }
        } else {
            // Toggle OFF — show popup so user can review/deselect
            pendingMeal    = meal
            missingForPending = missing
            selectedMissing   = Set(missing)  // all pre-selected; user can deselect
            activeSheet       = .missingIngredients
        }
    }

    // Called from MissingIngredientsSheet confirm button
    func addSelectedToGrocery() {
        guard let meal = pendingMeal else { return }
        for ing in selectedMissing {
            let lower = ing.lowercased()
            let inList = session.guestStore.groceryItems.contains { $0.name.lowercased() == lower }
            if !inList {
                session.guestStore.addToGroceryIfMissing(ing, recommended: true, recipeSource: meal.title)
            }
        }
        pendingMeal       = nil
        missingForPending = []
        selectedMissing   = []
    }

} // extension MealPlannerView

// MARK: - Day Plan Card
struct DayPlanCard: View {
    @Environment(AppSession.self) var session
    let dayLabel:    String
    let dayIndex:    Int
    let meals:       [PlannedMeal]
    let isExpanded:  Bool
    let mealTypes:   [String]
    let onToggle:    () -> Void
    let onAddMeal:   (String) -> Void
    let onRemoveMeal:(PlannedMeal) -> Void
    let onCookNow:   (PlannedMeal) -> Void
    let onPrepNow:   (PlannedMeal) -> Void
    // RL-005 — projected shortages per meal + repair callbacks. Defaulted so
    // the card stays drop-in for callers that don't do conflict detection.
    var conflictsByMeal: [UUID: [MealConflict]] = [:]
    var onConflictGrocery: (MealConflict) -> Void = { _ in }
    var onConflictRelease: (MealConflict) -> Void = { _ in }

    private var dayConflictCount: Int {
        meals.reduce(0) { $0 + (conflictsByMeal[$1.id]?.count ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack {
                    Text(dayLabel)
                        .scaledFont(16, weight: .semibold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    // RL-005 — day-level conflict badge, visible even collapsed.
                    if dayConflictCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill").scaledFont(9)
                            Text("\(dayConflictCount)").scaledFont(11, weight: .bold)
                        }
                        .foregroundStyle(Color.stockedError)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.stockedError.opacity(0.10))
                        .clipShape(Capsule())
                    }
                    if !meals.isEmpty {
                        Text("\(meals.count) meal\(meals.count == 1 ? "" : "s")")
                            .scaledFont(12).foregroundStyle(Color.stockedGold)
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.4))
                }
                .padding(14).contentShape(Rectangle())
            }.buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    Divider().padding(.horizontal, 14)
                    ForEach(meals) { meal in
                        VStack(spacing: 0) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(meal.mealType)
                                        .scaledFont(10, weight: .semibold)
                                        .foregroundStyle(Color.stockedGold)
                                    Text(meal.title)
                                        .scaledFont(14, design: .serif)
                                        .foregroundStyle(session.themeTextColor)
                                    Text("\(meal.servings) servings")
                                        .scaledFont(11)
                                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                                }
                                Spacer()
                                HStack(spacing: 8) {
                                    Button { onPrepNow(meal) } label: {
                                        Text("Prep")
                                            .scaledFont(11, weight: .semibold)
                                            .foregroundStyle(Color.stockedGold)
                                            .padding(.horizontal, 9).padding(.vertical, 5)
                                            .overlay(Capsule().stroke(Color.stockedGold, lineWidth: 1))
                                    }.buttonStyle(.plain)
                                    Button { onCookNow(meal) } label: {
                                        Text("Cook Now")
                                            .scaledFont(11, weight: .semibold)
                                            .foregroundStyle(Color.stockedWhite)
                                            .padding(.horizontal, 9).padding(.vertical, 5)
                                            .background(Color.stockedGold).clipShape(Capsule())
                                    }.buttonStyle(.plain)
                                    Button { onRemoveMeal(meal) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .scaledFont(18)
                                            .foregroundStyle(session.themeTextColor.opacity(0.25))
                                    }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            // RL-005 — this meal's projected shortages + repairs.
                            ForEach(conflictsByMeal[meal.id] ?? []) { conflict in
                                PlanConflictRow(conflict: conflict,
                                                onAddToGrocery: { onConflictGrocery(conflict) },
                                                onRelease:      { onConflictRelease(conflict) })
                                    .padding(.horizontal, 14).padding(.bottom, 8)
                            }
                            Divider().padding(.horizontal, 14)
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(mealTypes, id: \.self) { type in
                            let has = meals.contains { $0.mealType == type }
                            Button { onAddMeal(type) } label: {
                                Label(type, systemImage: "plus.circle")
                                    .scaledFont(12, weight: .semibold)
                                    .foregroundStyle(has ? Color.stockedCharcoal.opacity(0.3) : Color.stockedGold)
                                    .padding(.horizontal, 10).padding(.vertical, 11)
                                    .background(has ? Color.stockedCharcoal.opacity(0.06) : Color.stockedGold.opacity(0.12))
                                    .clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                        Spacer()
                    }.padding(14)
                }
            }
        }
        .background(session.themeCardColor)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Recipe Picker Sheet
struct RecipePickerSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let mealType:  String
    let onSelect:  (String, [String]) -> Void
    @State private var custom = ""
    @State private var dynamicOptions: [(String,[String])] = []   // loaded fresh from the recipe DB

    private var readyRecipes: [UserRecipe]  { session.guestStore.userRecipes }

    // Static starters used only as a fallback when the recipe database is empty.
    private var starterOptions: [(String,[String])] { [
        ("Pasta Aglio e Olio",  ["Pasta","Garlic","Olive Oil","Parsley"]),
        ("Stir Fry Rice",       ["Rice","Soy Sauce","Garlic","Mixed Veg","Eggs"]),
        ("Grilled Chicken",     ["Chicken Breast","Olive Oil","Garlic","Herbs"]),
        ("Salmon + Vegetables", ["Salmon","Broccoli","Olive Oil","Lemon"]),
        ("Omelette",            ["Eggs","Butter","Cheese","Herbs"]),
        ("Fried Rice",          ["Rice","Eggs","Soy Sauce","Garlic","Onion"]),
        ("Bean Tacos",          ["Tortillas","Black Beans","Salsa","Cheese","Lime"]),
        ("Chicken Curry",       ["Chicken","Coconut Milk","Curry Powder","Rice"]),
    ] }

    // What actually renders under "Quick Options": fresh DB picks, or starters if empty.
    private var quickOptions: [(String,[String])] {
        dynamicOptions.isEmpty ? starterOptions : dynamicOptions
    }

    // Pull a fresh, shuffled selection from the recipe database each time the sheet opens.
    private func refreshQuickOptions() {
        Task { @MainActor in
            let snap = await RecipeDatabaseManager.shared.loadSnapshot()
            guard !snap.isEmpty else { return }
            let picks = snap.shuffled().prefix(12)
            dynamicOptions = picks.map { entry in
                (entry.title, Array(entry.ingredients.prefix(5)))
            }
        }
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.15)).frame(width: 40, height: 4).padding(.top, 12)
                HStack {
                    Text("Pick \(mealType)").scaledFont(20, weight: .bold, design: .serif).foregroundStyle(session.themeTextColor)
                    Spacer()
                    Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").scaledFont(26).foregroundStyle(session.themeTextColor.opacity(0.25)) }.buttonStyle(.plain)
                }.padding(.horizontal, 24).padding(.vertical, 14)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        // Custom entry
                        HStack(spacing: 10) {
                            RecipePredictiveTextField(placeholder: "Type a recipe name…", text: $custom, recipesOnly: true, onSelect: { _ in })
                                .scaledFont(15).foregroundStyle(session.themeTextColor)
                            Button {
                                let n = custom.trimmingCharacters(in: .whitespaces)
                                guard !n.isEmpty else { return }
                                onSelect(n, []); dismiss()
                            } label: {
                                Image(systemName: "plus.circle.fill").scaledFont(26).foregroundStyle(custom.isEmpty ? Color.stockedCharcoal.opacity(0.3) : Color.stockedGold)
                            }.disabled(custom.isEmpty)
                        }
                        .padding(12).background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .padding(.horizontal, 20).padding(.bottom, 14)

                        // User recipes
                        if !readyRecipes.isEmpty {
                            sectionHeader("My Recipes")
                            ForEach(readyRecipes) { r in
                                pickerRow(r.title, ings: r.ingredients.map { "\($0.amount) \($0.name)".trimmingCharacters(in: .whitespaces) })
                            }
                        }

                        sectionHeader("Quick Options")
                        ForEach(Array(quickOptions.enumerated()), id: \.offset) { _, opt in
                            pickerRow(opt.0, ings: opt.1)
                        }
                        Color.clear.frame(height: 40)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear { refreshQuickOptions() }
    }

    private func sectionHeader(_ title: String) -> some View {
        SectionHeader(text: title.uppercased())
    }
    @ViewBuilder
    private func pickerRow(_ name: String, ings: [String]) -> some View {
        Button { onSelect(name, ings); dismiss() } label: {
            HStack {
                VStack(alignment: .leading, spacing: 10) {
                    Text(name).scaledFont(15, design: .serif).foregroundStyle(session.themeTextColor)
                    if !ings.isEmpty {
                        Text(ings.prefix(3).joined(separator: " · ")).scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: "plus.circle").scaledFont(18).foregroundStyle(Color.stockedGold)
            }
            .padding(.horizontal, 24).padding(.vertical, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
        Divider().padding(.horizontal, 24)
    }
}

// MARK: - Prep Now View
struct PrepNowView: View {
    let meal: PlannedMeal
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion

    private var daysUntil: Int { meal.dayIndex }

    // Prep timing fail-safe — ingredients requiring specific lead times
    private var prepAdvice: String? {
        guard daysUntil > 0 else { return nil }
        let ings = meal.ingredients.map { $0.lowercased() }
        if ings.contains(where: { $0.contains("marinate") || $0.contains("marinat") }) && daysUntil > 1 {
            return "Marinating is best 4–24 hours before cooking. If your meal is in \(daysUntil) day(s), prep the marinade the day before."
        }
        if ings.contains(where: { $0.contains("dough") || $0.contains("bread") }) && daysUntil > 1 {
            return "Dough benefits from 1–2 days of cold proofing. Start \(min(daysUntil, 2)) days before."
        }
        if daysUntil >= 3 {
            return "Your meal is \(daysUntil) day(s) away. Most chopping and prep is best done the day before — recommend starting prep on day \(daysUntil - 1)."
        }
        return nil
    }

    private var prepTasks: [(icon: String, task: String)] {
        var tasks: [(String, String)] = []
        let source = meal.ingredients.isEmpty
            ? ["Main protein","Vegetables","Seasonings","Pantry ingredients"]
            : meal.ingredients
        for ing in source {
            let l = ing.lowercased()
            if l.contains("chicken") || l.contains("beef") || l.contains("fish") || l.contains("pork") {
                tasks.append(("scissors",      "Trim and cut \(ing) into even pieces"))
                tasks.append(("drop.fill",     "Pat \(ing) dry with paper towels"))
            } else if l.contains("onion") || l.contains("garlic") || l.contains("shallot") {
                tasks.append(("scissors",      "Peel and finely mince \(ing)"))
            } else if l.contains("carrot") || l.contains("pepper") || l.contains("tomato") || l.contains("celery") {
                tasks.append(("scissors",      "Dice \(ing) into uniform pieces"))
            } else if l.contains("herb") || l.contains("parsley") || l.contains("basil") || l.contains("cilantro") {
                tasks.append(("leaf.fill",     "Wash and roughly chop \(ing)"))
            } else if l.contains("sauce") || l.contains("broth") || l.contains("stock") {
                tasks.append(("cup.and.saucer.fill", "Measure out \(ing) and set aside"))
            } else {
                tasks.append(("checkmark.circle", "Measure and prep \(ing)"))
            }
        }
        tasks.append(("flame.fill",       "Pre-heat oven or pan to the right temperature"))
        tasks.append(("cabinet.fill",     "Gather all equipment you'll need"))
        return Array(tasks.prefix(10))
    }

    @State private var completed: Set<Int> = []
    @State private var showReminder = false

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Prep Work")
                        .scaledFont(28, weight: .bold, design: .serif).foregroundStyle(session.themeTextColor)
                    Text("Get ready to cook \(meal.title).")
                        .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.55))
                }.padding(.horizontal, 24).padding(.bottom, 14)

                // Timing fail-safe warning
                if let advice = prepAdvice {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "clock.badge.exclamationmark").scaledFont(16).foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Prep Timing Advice").scaledFont(13, weight: .bold).foregroundStyle(.orange)
                            Text(advice).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(14).background(Color.orange.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    .padding(.horizontal, 20).padding(.bottom, 12)
                }

                // Reminder option
                if daysUntil >= 1 {
                    HStack(spacing: 10) {
                        Image(systemName: showReminder ? "bell.fill" : "bell")
                            .scaledFont(14).foregroundStyle(Color.stockedGold)
                        Text(showReminder ? "Prep reminder set!" : "Set a reminder to start prepping")
                            .scaledFont(13).foregroundStyle(session.themeTextColor)
                        Spacer()
                        Toggle("", isOn: $showReminder)
                            .labelsHidden().tint(Color.stockedGold)
                    }
                    .padding(12).background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    .padding(.horizontal, 20).padding(.bottom, 12)
                }

                // Progress
                HStack {
                    Text("\(completed.count) of \(prepTasks.count) tasks done")
                        .scaledFont(13, weight: .semibold).foregroundStyle(Color.stockedGold)
                    Spacer()
                    ProgressView(value: prepTasks.isEmpty ? 0 : Double(completed.count) / Double(prepTasks.count))
                        .tint(Color.stockedGold).frame(width: 100)
                }.padding(.horizontal, 24).padding(.bottom, 14)

                VStack(spacing: 8) {
                    ForEach(prepTasks.indices, id: \.self) { i in
                        Button {
                            motion.animate(.selection, intent: .spatial) {
                                if completed.contains(i) { completed.remove(i) } else { completed.insert(i) }
                            }
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle().fill(completed.contains(i) ? Color.stockedGold : Color.stockedCharcoal.opacity(0.15))
                                        .frame(width: 36, height: 36)
                                    Image(systemName: completed.contains(i) ? "checkmark" : prepTasks[i].icon)
                                        .scaledFont(14, weight: .semibold)
                                        .foregroundStyle(completed.contains(i) ? Color.stockedWhite : Color.stockedCharcoal)
                                }
                                Text(prepTasks[i].task)
                                    .scaledFont(14, design: .serif)
                                    .foregroundStyle(completed.contains(i) ? Color.stockedCharcoal.opacity(0.35) : Color.stockedCharcoal)
                                    .strikethrough(completed.contains(i))
                                    .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .padding(14)
                            .background(completed.contains(i) ? Color.stockedWhite.opacity(0.15) : Color.stockedWhite.opacity(0.30))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 20).padding(.bottom, 24)

                if completed.count == prepTasks.count {
                    VStack(spacing: 8) {
                        Text("✅ All prepped and ready!")
                            .scaledFont(20, weight: .bold, design: .serif).foregroundStyle(Color.stockedGold)
                        Text("Store covered items in the fridge. Come back to cook when you're ready.")
                            .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.6)).multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity).padding(20)
                    .background(Color.stockedGold.opacity(0.08)).clipShape(RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 20)
                }
            }
        }
    }
}

// MARK: - Plan Conflict Row (RL-005)
// One projected shortage on a meal card: the specific ingredient, how much is
// missing, and why — with inline repairs. Warnings are derived (never stored),
// so a fixed conflict simply stops rendering on the next recalculation.
struct PlanConflictRow: View {
    @Environment(AppSession.self) var session
    let conflict: MealConflict
    let onAddToGrocery: () -> Void
    let onRelease: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .scaledFont(11)
                    .foregroundStyle(Color.stockedError)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Short \(conflict.missingDisplay)")
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(hintText)
                        .scaledFont(10.5)
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(action: onAddToGrocery) {
                    Label("Add to Grocery", systemImage: "cart.badge.plus")
                        .scaledFont(10.5, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.stockedGold.opacity(0.12))
                        .clipShape(Capsule())
                }.buttonStyle(.plain)
                Button(action: onRelease) {
                    Label("Release", systemImage: "arrow.uturn.backward")
                        .scaledFont(10.5, weight: .semibold)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(session.themeTextColor.opacity(0.06))
                        .clipShape(Capsule())
                }.buttonStyle(.plain)
                Spacer(minLength: 0)
            }
        }
        .padding(10)
        .background(Color.stockedError.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
    }

    /// Why it's short + the "adjust servings" nudge where that would help.
    private var hintText: String {
        switch conflict.reason {
        case .notInStock:
            return "Not in your inventory yet."
        case .overAllocated:
            return "Earlier meals claim it first — buy more, lower servings, or release it here."
        case .expiresBeforeMeal:
            return "What you own expires before this meal — plan it sooner or restock."
        }
    }
}

// MARK: - Missing Ingredients Sheet
struct MissingIngredientsSheet: View {
    @Environment(AppSession.self) var session
    let recipeName:   String
    let missingItems: [String]
    @Binding var selectedItems: Set<String>
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                // Handle
                Capsule()
                    .fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4)
                    .padding(.top, 12)
                    .padding(.bottom, 16)

                // Header
                VStack(spacing: 6) {
                    Text("Missing Ingredients")
                        .scaledFont(22, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text("For \"\(recipeName)\"")
                        .scaledFont(14)
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                    Text("Deselect any items you already have or don't need.")
                        .scaledFont(12)
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .padding(.bottom, 20)

                // Ingredient list
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(missingItems, id: \.self) { item in
                            let isSelected = selectedItems.contains(item)
                            Button {
                                if isSelected { selectedItems.remove(item) }
                                else          { selectedItems.insert(item) }
                            } label: {
                                HStack(spacing: 14) {
                                    ZStack {
                                        Circle()
                                            .fill(isSelected ? Color.stockedGold : Color.clear)
                                            .frame(width: 24, height: 24)
                                        Circle()
                                            .stroke(isSelected ? Color.stockedGold : Color.stockedCharcoal.opacity(0.3), lineWidth: 1.5)
                                            .frame(width: 24, height: 24)
                                        if isSelected {
                                            Image(systemName: "checkmark")
                                                .scaledFont(11, weight: .bold)
                                                .foregroundStyle(session.themeTextColor)
                                        }
                                    }
                                    Text(item)
                                        .scaledFont(15, design: .serif)
                                        .foregroundStyle(isSelected ? session.themeTextColor : session.themeTextColor.opacity(0.4))
                                        .strikethrough(!isSelected, color: session.themeTextColor.opacity(0.3))
                                    Spacer()
                                }
                                .padding(.horizontal, 24)
                                .padding(.vertical, 13)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.horizontal, 24)
                        }
                    }
                }

                // Select/deselect all
                HStack {
                    Button {
                        if selectedItems.count == missingItems.count {
                            selectedItems.removeAll()
                        } else {
                            selectedItems = Set(missingItems)
                        }
                    } label: {
                        Text(selectedItems.count == missingItems.count ? "Deselect All" : "Select All")
                            .scaledFont(13, weight: .medium)
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Text("\(selectedItems.count) of \(missingItems.count) selected")
                        .scaledFont(12)
                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)

                // Action buttons
                VStack(spacing: 10) {
                    Button {
                        guard !selectedItems.isEmpty else { onDismiss(); return }
                        onConfirm()
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "cart.badge.plus")
                            Text(selectedItems.isEmpty ? "Skip — Don't Add" : "Add \(selectedItems.count) Item\(selectedItems.count == 1 ? "" : "s") to Grocery List")
                        }
                        .scaledFont(16, weight: .semibold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(selectedItems.isEmpty ? Color.stockedCharcoal.opacity(0.15) : Color.stockedGold)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .buttonStyle(.plain)
                    .disabled(false)

                    Button(action: onDismiss) {
                        Text("Skip for now")
                            .scaledFont(14)
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}
