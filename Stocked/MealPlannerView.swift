// MealPlannerView.swift — Weekly meal plan with calendar + list toggle
import SwiftUI
import Combine

// Helper for sheet(item:) binding on calendar quick-add
// One enum drives a single .sheet(item:) — three stacked .sheet modifiers on one view
// is unreliable in SwiftUI (only one fires). Context travels as associated values.
enum MealPlannerSheet: Identifiable {
    case picker(day: Int, type: String)
    case missingIngredients
    case quickAdd(day: Int)
    var id: String {
        switch self {
        case .picker(let d, let t): return "picker-\(d)-\(t)"
        case .missingIngredients:   return "missing"
        case .quickAdd(let d):      return "quick-\(d)"
        }
    }
}

// MARK: - Calendar day cell — extracted so .dropDestination can infer its generic
struct CalendarDayCell: View {
    @Environment(AppSession.self) var session
    let dayNum:     Int
    let isToday:    Bool
    let isPast:     Bool
    let offset:     Int
    let hasMeal:    Bool
    let pastMeal:   LocalPastMeal?
    let isSelected: Bool
    var onTap:      () -> Void
    var onDrop:     (String, Int) -> Void   // (itemName, offset)

    var body: some View {
        Button(action: onTap) {
            ZStack {
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm)
                    .fill(isPast ? Color.stockedCharcoal.opacity(0.06) :
                          isSelected ? Color.stockedGold.opacity(0.25) :
                          isToday ? Color.stockedGold :
                          Color.stockedWhite.opacity(0.28))
                    .overlay(
                        RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm)
                            .stroke(isSelected ? Color.stockedGold : Color.clear, lineWidth: 1.5)
                    )
                VStack(spacing: 2) {
                    Text("\(dayNum)")
                        .font(.stockedSystem(size: 14, weight: isToday || isSelected ? .bold : .regular))
                        .foregroundStyle(isToday ? Color.stockedWhite :
                                         isPast  ? Color.stockedCharcoal.opacity(0.3)
                                                 : Color.stockedCharcoal)
                    HStack(spacing: 2) {
                        if hasMeal    { Circle().fill(Color.stockedGold ).frame(width: 5, height: 5) }
                        if pastMeal != nil { Circle().fill(Color.stockedGreen).frame(width: 5, height: 5) }
                    }
                    .frame(height: 6)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
        }
        .buttonStyle(.plain)
        .disabled(isPast && pastMeal == nil)
        .dropDestination(for: String.self) { items, _ -> Bool in
            guard (0..<7).contains(offset), let name = items.first else { return false }
            onDrop(name, offset)
            return true
        }
    }
}

// PlannedMeal is defined in Models.swift

// MARK: - Meal Planner View
struct MealPlannerView: View {
    let servings:        Int
    var initialItemName: String = ""   // set when opened by inventory drag
    var initialDayIndex: Int    = 0    // day index to pre-select (0 = today)
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) var motion
    @State var plannedMeals: [PlannedMeal] = []
    @State var selectedDay  = 0
    @State var pickingDay   = 0
    @State var pickingType  = "Dinner"
    @State var saved        = false
    @State var isCalendarView = false
    @State var cookingMeal: PlannedMeal? = nil
    @State var navigateToCook = false
    // Cook Now workspace: planned-meal cook transition (start now / cook ahead / prep).
    @State var cookTransitionMeal: PlannedMeal? = nil
    @State var cookAheadMeal: PlannedMeal? = nil
    @State var navigateToCookAhead = false
    @State var preppingMeal: PlannedMeal? = nil
    @State var navigateToPrep = false
    @State var renamingMeal: PlannedMeal? = nil       // #1 building-meal rename
    @State var renameText: String = ""
    @State var savedRecipeToast: String? = nil        // confirmation after "Save as recipe"
    @State var selectedCalendarDay: Int? = nil  // tapped day for detail panel
    // Missing-items popup
    @State var pendingMeal: PlannedMeal?   = nil  // meal waiting for grocery confirm
    @State var missingForPending: [String] = []   // missing ingredients for pendingMeal
    @State var selectedMissing: Set<String> = []  // user deselects items they don't need
    @State var activeSheet: MealPlannerSheet? = nil   // single sheet driver
    @State var shouldDismissAfterSave = false
    // RL-005 — projected conflicts for the CURRENT (possibly unsaved) plan.
    // Derived through the pure ReservationEngine against the local edit state,
    // so warnings track edits live and auto-clear the moment they're resolved.
    @State var planConflicts: [MealConflict] = []
    @Environment(\.dismiss) var dismiss

    let mealTypes = RecipeTaxonomy.categories.filter { ["Breakfast", "Lunch", "Dinner"].contains($0) }

    // Next 7 days
    var days: [(label: String, date: Date)] {
        (0..<7).map { offset in
            let d = Calendar.current.date(byAdding: .day, value: offset, to: Date()) ?? Date()
            let f = DateFormatter()
            f.dateFormat = offset == 0 ? "'Today'" : offset == 1 ? "'Tomorrow'" : "EEEE"
            return (f.string(from: d), d)
        }
    }

    func meals(for dayIndex: Int) -> [PlannedMeal] {
        plannedMeals.filter { $0.dayIndex == dayIndex }
    }

    var missingIngredients: [String] {
        var missing: [String] = []
        for meal in plannedMeals {
            for ing in meal.ingredients {
                let inStock = session.guestStore.inventoryItems.contains {
                    $0.name.lowercased().contains(ing.lowercased()) || ing.lowercased().contains($0.name.lowercased())
                }
                if !inStock && !missing.contains(ing) { missing.append(ing) }
            }
        }
        return missing
    }

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 0) {

                // Header with view toggle
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Meal Planner")
                            .scaledFont(28, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Text("Plan meals for the week.")
                            .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.55))
                    }
                    Spacer()
                    // Calendar / List view toggle — icon shows where you'll GO, not where you are
                    Button {
                        motion.animate(.standard, intent: .spatial) { isCalendarView.toggle() }
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: isCalendarView ? "list.bullet" : "calendar")
                                .scaledFont(18)
                                .foregroundStyle(Color.stockedGold)
                            Text(isCalendarView ? "List" : "Calendar")
                                .scaledFont(9, weight: .semibold)
                                .foregroundStyle(session.themeTextColor.opacity(0.45))
                        }
                        .frame(width: 52, height: 44)
                        .background(Color.stockedWhite.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 24).padding(.bottom, 20)

                if isCalendarView {
                    calendarGrid
                } else {
                    listView
                }

                // Summary + Save
                if !plannedMeals.isEmpty {
                    summaryFooter
                }
            }
        }
        .navigationDestination(isPresented: $navigateToCook) {
            if let meal = cookingMeal {
                RecipeOverviewView(title: meal.title, servings: meal.servings, ingredients: meal.ingredients)
            }
        }
        .navigationDestination(isPresented: $navigateToCookAhead) {
            if let meal = cookAheadMeal {
                CookAheadStatusView(mealID: meal.id)
            }
        }
        .sheet(item: $cookTransitionMeal) { meal in
            PlannedMealCookTransitionView(
                meal: meal,
                onStartCooking: { m in cookingMeal = m; navigateToCook = true },
                onCookAhead:    { m in cookAheadMeal = m; navigateToCookAhead = true },
                onPrepOnly:     { m in preppingMeal = m; navigateToPrep = true }
            )
            .environment(session)
        }
        .navigationDestination(isPresented: $navigateToPrep) {
            if let meal = preppingMeal {
                PrepNowView(meal: meal)
            }
        }
        .alert("Rename recipe", isPresented: Binding(get: { renamingMeal != nil }, set: { if !$0 { renamingMeal = nil } })) {
            TextField("Recipe name", text: $renameText)
            Button("Cancel", role: .cancel) { renamingMeal = nil }
            Button("Save") {
                if let m = renamingMeal,
                   let idx = plannedMeals.firstIndex(where: { $0.id == m.id }) {
                    let trimmed = renameText.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { plannedMeals[idx].title = trimmed }
                }
                renamingMeal = nil
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = savedRecipeToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedGreen)
                    Text(toast).scaledFont(13, weight: .semibold).foregroundStyle(.white)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.stockedCharcoal).clipShape(Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.bottom, 130)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case let .picker(day, type):
                RecipePickerSheet(mealType: type) { title, ings in
                    let meal = PlannedMeal(dayIndex: day, title: title,
                                           servings: servings, ingredients: ings, mealType: type)
                    withAnimation { plannedMeals.append(meal) }
                    handleRecipeAdded(meal)
                }
                .environment(session)
            case .missingIngredients:
                MissingIngredientsSheet(
                    recipeName:      pendingMeal?.title ?? "",
                    missingItems:    missingForPending,
                    selectedItems:   $selectedMissing,
                    onConfirm: {
                        addSelectedToGrocery()
                        activeSheet = nil
                    },
                    onDismiss: { activeSheet = nil }
                )
                .environment(session)
            case let .quickAdd(day):
                calendarQuickAddSheet(day: day)
            }
        }
        .alert("Plan Saved", isPresented: $saved) {
            Button("Done") { shouldDismissAfterSave = true }
        } message: {
            Text("Your meal plan has been saved. Returning to home.")
        }
        .onChange(of: shouldDismissAfterSave) { _, val in
            if val { dismiss() }
        }
        .dismissKeyboardOnTap()
        .onAppear {
            // Load persisted planned meals (including any "building" meal assembled by
            // dragging inventory items onto a day from the Pantry tab).
            plannedMeals = session.guestStore.plannedMeals
            // If opened by a direct inventory drag with an item name, also add it.
            if !initialItemName.isEmpty {
                if let idx = plannedMeals.firstIndex(where: { $0.dayIndex == initialDayIndex && $0.isBuilding }) {
                    if !plannedMeals[idx].ingredients.contains(where: { $0.caseInsensitiveCompare(initialItemName) == .orderedSame }) {
                        plannedMeals[idx].ingredients.append(initialItemName)
                    }
                } else {
                    plannedMeals.append(PlannedMeal(
                        dayIndex:    initialDayIndex,
                        title:       "New Recipe",
                        servings:    servings > 0 ? servings : 2,
                        ingredients: [initialItemName],
                        mealType:    "Dinner",
                        isBuilding:  true
                    ))
                }
                selectedCalendarDay = initialDayIndex
                isCalendarView = true
            } else if plannedMeals.contains(where: { $0.isBuilding }) {
                // Surface a building meal assembled via drag, even without a direct item.
                selectedCalendarDay = plannedMeals.first(where: { $0.isBuilding })?.dayIndex
                isCalendarView = true
            }
        }
        .onChange(of: plannedMeals) { _, newValue in
            // Persist any local changes back to the store. The store's didSet
            // bumps planRevision, so every other surface's reservations follow.
            session.guestStore.plannedMeals = newValue
            recomputeConflicts()   // RL-006: plan mutations drive recalculation
        }
        .task { recomputeConflicts() }
        .onChange(of: session.guestStore.inventoryRevision) { _, _ in recomputeConflicts() }
    }

    // MARK: - RL-005 conflict detection + repairs

    /// Re-derive projected conflicts for the plan as currently edited. Pure and
    /// idempotent — recomputing never duplicates warnings or touches user data.
    func recomputeConflicts() {
        planConflicts = ReservationEngine.compute(meals: plannedMeals,
                                                  inventory: session.guestStore.inventoryItems).conflicts
    }

    /// The conflicts belonging to one meal card, urgency order preserved.
    func conflicts(for meal: PlannedMeal) -> [MealConflict] {
        planConflicts.filter { $0.mealID == meal.id }
    }

    /// Conflicts keyed by meal for the list-view day cards.
    var conflictsByMeal: [UUID: [MealConflict]] {
        Dictionary(grouping: planConflicts, by: \.mealID)
    }

    /// Repair: buy the missing amount (consolidated — dedup lives in the store).
    func repairAddToGrocery(_ conflict: MealConflict) {
        session.guestStore.addToGroceryIfMissing(conflict.ingredient,
                                                 recommended: true,
                                                 recipeSource: conflict.mealTitle)
        HapticManager.success()
    }

    /// Repair: release the reservation by dropping the shorted ingredient line
    /// from that meal. Only the one line moves; the meal itself stays planned.
    func releaseReservation(_ conflict: MealConflict) {
        guard let idx = plannedMeals.firstIndex(where: { $0.id == conflict.mealID }) else { return }
        withAnimation {
            plannedMeals[idx].ingredients.removeAll { $0 == conflict.rawIngredient }
        }
        HapticManager.success()
    }

    // Quick add sheet opened from calendar tap
    func calendarQuickAddSheet(day: Int) -> some View {
        let mealTypes = RecipeTaxonomy.categories.filter { ["Breakfast", "Lunch", "Dinner", "Snack"].contains($0) }
        return NavigationStack {
            VStack(spacing: 0) {
                Text("Add Meal — Day \(day == 0 ? "Today" : "in \(day) day\(day == 1 ? "" : "s")")")
                    .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.45))
                    .padding(.top, 8)
                List {
                    ForEach(mealTypes, id: \.self) { mealType in
                        Button {
                            // Close this sheet, then open the recipe picker for the day/type.
                            activeSheet = nil
                            Task {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                activeSheet = .picker(day: day, type: mealType)
                            }
                        } label: {
                            HStack {
                                Text(mealType)
                                    .scaledFont(16, weight: .semibold, design: .serif)
                                    .foregroundStyle(session.themeTextColor)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.3))
                            }
                            .padding(.vertical, 4)
                        }
                        .listRowBackground(Color.clear)
                    }
                }
                .listStyle(.plain)
            }
            .navigationTitle("What are you planning?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { activeSheet = nil }
                        .foregroundStyle(Color.stockedGold)
                }
            }
        }
    }
}
