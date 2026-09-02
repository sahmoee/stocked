// MealPrepView.swift — Plan multiple meals, merge ingredients, get a sequenced prep order
import SwiftUI

// MARK: - Meal Prep session model
private struct PrepMeal: Identifiable {
    let id    = UUID()
    let title: String
    let ingredients: [String]
    var estimatedPrepMin: Int = 20
    var estimatedCookMin: Int = 30
    var source: String = ""   // "My Recipes" | "Quick Pick"
}

// MARK: - Merged ingredient line
private struct MergedIngredient: Identifiable {
    let id    = UUID()
    var name:  String
    var meals: [String]   // which meals need it
    var addedToGrocery = false
}

struct MealPrepView: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion
    @State private var selectedMeals:  [PrepMeal]     = []
    @State private var mergedIngredients: [MergedIngredient] = []
    @State private var step:           PrepStep        = .select
    @State private var showAddToast    = false

    private enum PrepStep { case select, review, plan }

    private var store: GuestDataStore { session.guestStore }

    // Quick-pick options. Refreshed from the recipe database on each visit (see
    // refreshQuickPicks); the universal pantry-staple set below is the fallback used only when
    // the database is empty, mirroring how the meal planner's Quick Options falls back.
    @State private var quickPicks: [PrepMeal] = MealPrepView.fallbackQuickPicks

    private static let fallbackQuickPicks: [PrepMeal] = [
        PrepMeal(title: "Grilled Chicken",    ingredients: ["Chicken breast","Olive oil","Garlic","Lemon","Herbs"],          estimatedPrepMin: 10, estimatedCookMin: 25, source: "Quick Pick"),
        PrepMeal(title: "Roasted Vegetables", ingredients: ["Mixed vegetables","Olive oil","Salt","Pepper","Rosemary"],       estimatedPrepMin: 15, estimatedCookMin: 35, source: "Quick Pick"),
        PrepMeal(title: "Brown Rice",         ingredients: ["Brown rice","Water","Salt","Butter"],                            estimatedPrepMin: 2,  estimatedCookMin: 45, source: "Quick Pick"),
        PrepMeal(title: "Greek Salad",        ingredients: ["Cucumber","Tomato","Red onion","Feta","Olives","Olive oil"],     estimatedPrepMin: 10, estimatedCookMin: 0,  source: "Quick Pick"),
        PrepMeal(title: "Overnight Oats",     ingredients: ["Oats","Milk","Honey","Banana","Chia seeds"],                    estimatedPrepMin: 5,  estimatedCookMin: 0,  source: "Quick Pick"),
        PrepMeal(title: "Egg Muffins",        ingredients: ["Eggs","Cheese","Spinach","Bell pepper","Salt","Pepper"],         estimatedPrepMin: 10, estimatedCookMin: 22, source: "Quick Pick"),
        PrepMeal(title: "Pasta Salad",        ingredients: ["Pasta","Cherry tomatoes","Basil","Olive oil","Parmesan"],        estimatedPrepMin: 8,  estimatedCookMin: 12, source: "Quick Pick"),
        PrepMeal(title: "Stir Fry",           ingredients: ["Protein of choice","Broccoli","Soy sauce","Garlic","Rice"],     estimatedPrepMin: 15, estimatedCookMin: 15, source: "Quick Pick"),
    ]

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 10) {
                        Text("🧑‍🍳").scaledFont(32)
                        Text("Meal Prep")
                            .scaledFont(32, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                    }
                    Text("Select meals → review ingredients → get your prep order")
                        .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.5))
                }
                .padding(.horizontal, 24).padding(.bottom, 20)

                // Step pills
                HStack(spacing: 0) {
                    ForEach(["Select","Review","Plan"].indices, id: \.self) { i in
                        let labels = ["Select","Review","Plan"]
                        let active = (step == .select && i == 0) || (step == .review && i == 1) || (step == .plan && i == 2)
                        Text(labels[i])
                            .scaledFont(12, weight: .semibold)
                            .foregroundStyle(active ? session.themeTextColor : session.themeTextColor.opacity(0.35))
                            .frame(maxWidth: .infinity).padding(.vertical, 8)
                            .background(active ? Color.stockedGold : Color.clear)
                    }
                }
                .background(Color.stockedWhite.opacity(0.3))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)).padding(.horizontal, 24).padding(.bottom, 20)

                // Step content
                switch step {
                case .select: selectStep
                case .review: reviewStep
                case .plan:   planStep
                }
            }
        }
        .overlay(alignment: .bottom) {
            if showAddToast {
                Text("✓ All ingredients added to grocery list")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(Color.stockedGreen).clipShape(RoundedRectangle(cornerRadius: 24))
                    .padding(.bottom, 100)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Refresh Quick Picks from the recipe database every time the screen appears, so the
        // suggestions are not a fixed list. Falls back to the static set when the DB is empty.
        .onAppear { refreshQuickPicks() }
    }

    // Pull a fresh, shuffled batch of presentable recipes from the database and map them to
    // prep-pick rows. Mirrors the meal planner's Quick Options refresh. Keeps the static
    // fallback set when the database has not loaded any recipes yet.
    private func refreshQuickPicks() {
        Task { @MainActor in
            let snap = await RecipeDatabaseManager.shared.loadSnapshot()
            guard !snap.isEmpty else { return }
            let picks = snap.shuffled().prefix(8)
            let mapped: [PrepMeal] = picks.map { entry in
                PrepMeal(title: entry.title,
                         ingredients: Array(entry.ingredients.prefix(8)),
                         estimatedPrepMin: Int(entry.prepTime.filter(\.isNumber)) ?? 15,
                         estimatedCookMin: Int(entry.cookTime.filter(\.isNumber)) ?? 30,
                         source: "Quick Pick")
            }
            if !mapped.isEmpty { quickPicks = mapped }
        }
    }

    // MARK: - Step 1: Select Meals
    private var selectStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel("MY RECIPES")
            if store.userRecipes.isEmpty {
                Text("No saved recipes yet — use Quick Picks below")
                    .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.4))
                    .padding(.horizontal, 24).padding(.vertical, 12)
            } else {
                ForEach(store.userRecipes) { r in
                    let meal = PrepMeal(title: r.title,
                                        ingredients: r.ingredientNames,
                                        estimatedPrepMin: Int(r.prepTime.filter(\.isNumber)) ?? 15,
                                        estimatedCookMin: Int(r.cookTime.filter(\.isNumber)) ?? 30,
                                        source: "My Recipes")
                    mealSelectRow(meal)
                }
            }

            sectionLabel("QUICK PICKS")
            ForEach(quickPicks) { meal in
                mealSelectRow(meal)
            }

            // CTA
            if !selectedMeals.isEmpty {
                Button {
                    buildMergedList()
                    motion.animate(.standard, intent: .spatial) { step = .review }
                } label: {
                    HStack {
                        Text("Review \(selectedMeals.count) Meal\(selectedMeals.count == 1 ? "" : "s")")
                            .scaledFont(17, weight: .semibold, design: .serif)
                        Spacer()
                        Image(systemName: "chevron.right")
                    }
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 24).padding(.vertical, 18)
                    .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
            }
        }
    }

    private func mealSelectRow(_ meal: PrepMeal) -> some View {
        let isSelected = selectedMeals.contains { $0.title == meal.title }
        return Button {
            motion.animate(.selection, intent: .spatial) {
                if isSelected { selectedMeals.removeAll { $0.title == meal.title } }
                else          { selectedMeals.append(meal) }
            }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Color.stockedGold : Color.stockedWhite.opacity(0.35))
                        .frame(width: 30, height: 30)
                    if isSelected {
                        Image(systemName: "checkmark").scaledFont(12, weight: .bold)
                            .foregroundStyle(session.themeTextColor)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(meal.title).scaledFont(15, weight: .semibold).foregroundStyle(session.themeTextColor)
                    HStack(spacing: 8) {
                        if meal.estimatedPrepMin > 0 {
                            Label("\(meal.estimatedPrepMin)m prep", systemImage: "clock")
                                .scaledFont(10)
                        }
                        if meal.estimatedCookMin > 0 {
                            Label("\(meal.estimatedCookMin)m cook", systemImage: "flame")
                                .scaledFont(10)
                        }
                        Text(meal.source).scaledFont(10, weight: .semibold)
                            .foregroundStyle(Color.stockedGold)
                    }.foregroundStyle(session.themeTextColor.opacity(0.45))
                }
                Spacer()
            }
            .padding(.horizontal, 24).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Step 2: Merged Ingredient Review
    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Summary
            HStack(spacing: 12) {
                statPill("\(selectedMeals.count)", "meals")
                statPill("\(mergedIngredients.count)", "ingredients")
                let missing = mergedIngredients.filter { ing in
                    !store.inventoryItems.contains { $0.name.lowercased().contains(ing.name.lowercased()) }
                }.count
                statPill("\(missing)", "to buy")
            }.padding(.horizontal, 24).padding(.bottom, 16)

            sectionLabel("MERGED INGREDIENT LIST")
            ForEach(mergedIngredients) { ing in
                let inStock = store.inventoryItems.contains {
                    $0.name.lowercased().contains(ing.name.lowercased()) ||
                    ing.name.lowercased().contains($0.name.lowercased())
                }
                HStack(spacing: 12) {
                    Image(systemName: inStock ? "checkmark.circle.fill" : "circle")
                        .scaledFont(18)
                        .foregroundStyle(inStock ? Color.stockedGreen : session.themeTextColor.opacity(0.3))
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ing.name).scaledFont(14).foregroundStyle(session.themeTextColor)
                            .strikethrough(inStock)
                        Text("For: \(ing.meals.joined(separator: " · "))")
                            .scaledFont(10).foregroundStyle(session.themeTextColor.opacity(0.4)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    if inStock {
                        Text("Stocked").scaledFont(10, weight: .bold).foregroundStyle(Color.stockedGreen)
                    }
                }
                .padding(.horizontal, 24).padding(.vertical, 9)
                .contentShape(Rectangle())
                Divider().padding(.leading, 60)
            }

            // CTAs
            VStack(spacing: 12) {
                Button {
                    addMissingToGrocery()
                } label: {
                    Label("Add Missing to Grocery List", systemImage: "cart.badge.plus")
                        .scaledFont(16, weight: .semibold, design: .serif)
                        .foregroundStyle(Color.stockedWhite).frame(maxWidth: .infinity)
                        .padding(.vertical, 17).background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)

                Button {
                    motion.animate(.standard, intent: .spatial) { step = .plan }
                } label: {
                    Label("See Prep Order", systemImage: "list.number")
                        .scaledFont(15, weight: .semibold)
                        .foregroundStyle(Color.stockedGold).frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.stockedGold.opacity(0.1)).clipShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)

                Button {
                    motion.animate(.standard, intent: .spatial) { step = .select }
                } label: {
                    Text("← Edit Selection").scaledFont(14)
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 24).padding(.top, 20)
        }
    }

    // MARK: - Step 3: Sequenced Prep Plan
    private var planStep: some View {
        // Sort by longest total time first (cook longest things first)
        let sorted = selectedMeals.sorted { ($0.estimatedPrepMin + $0.estimatedCookMin) > ($1.estimatedPrepMin + $1.estimatedCookMin) }
        let totalMin = sorted.reduce(0) { $0 + $1.estimatedPrepMin + $1.estimatedCookMin }

        return VStack(alignment: .leading, spacing: 0) {
            // Total estimate
            HStack {
                Label("Estimated total: ~\(totalMin) min", systemImage: "clock.fill")
                    .scaledFont(13, weight: .semibold).foregroundStyle(Color.stockedGold)
                Spacer()
            }.padding(.horizontal, 24).padding(.bottom, 16)

            sectionLabel("RECOMMENDED PREP ORDER")
            Text("Start with the longest-cooking items so everything finishes close together.")
                .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.45))
                .padding(.horizontal, 24).padding(.bottom, 12)

            ForEach(Array(sorted.enumerated()), id: \.element.id) { i, meal in
                HStack(spacing: 16) {
                    // Step number badge
                    ZStack {
                        Circle().fill(Color.stockedCharcoal).frame(width: 34, height: 34)
                        Text("\(i + 1)").scaledFont(14, weight: .bold).foregroundStyle(Color.stockedGold)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(meal.title)
                            .scaledFont(15, weight: .semibold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        HStack(spacing: 6) {
                            if meal.estimatedPrepMin > 0 {
                                Text("Prep \(meal.estimatedPrepMin)m").scaledFont(11)
                            }
                            if meal.estimatedPrepMin > 0 && meal.estimatedCookMin > 0 {
                                Text("·").scaledFont(11)
                            }
                            if meal.estimatedCookMin > 0 {
                                Text("Cook \(meal.estimatedCookMin)m").scaledFont(11)
                            }
                        }.foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                    Spacer()
                    // Key ingredients preview
                    Text(meal.ingredients.prefix(2).joined(separator: ", "))
                        .scaledFont(10).foregroundStyle(session.themeTextColor.opacity(0.35))
                        .fixedSize(horizontal: false, vertical: true).multilineTextAlignment(.trailing).frame(maxWidth: 80)
                }
                .padding(.horizontal, 24).padding(.vertical, 12)
                .background(i % 2 == 0 ? Color.stockedWhite.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())

                if i < sorted.count - 1 {
                    HStack {
                        Spacer().frame(width: 57)
                        Rectangle().fill(Color.stockedGold.opacity(0.3)).frame(width: 2, height: 20)
                        Spacer()
                    }
                }
            }

            VStack(spacing: 12) {
                NavigationLink(destination: GroceryListView()) {
                    Label("View Grocery List", systemImage: "cart")
                        .scaledFont(16, weight: .semibold, design: .serif)
                        .foregroundStyle(Color.stockedWhite).frame(maxWidth: .infinity)
                        .padding(.vertical, 17).background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: 14))
                }.buttonStyle(.plain)

                Button {
                    selectedMeals = []
                    mergedIngredients = []
                    motion.animate(.standard, intent: .spatial) { step = .select }
                } label: {
                    Text("Start Over").scaledFont(14)
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 24).padding(.top, 24)
        }
    }

    // MARK: - Helpers
    private func buildMergedList() {
        var dict: [String: [String]] = [:]
        for meal in selectedMeals {
            for ing in meal.ingredients {
                let key = ing.lowercased().trimmingCharacters(in: .whitespaces)
                if !key.isEmpty {
                    dict[key, default: []].append(meal.title)
                }
            }
        }
        mergedIngredients = dict.map { key, meals in
            MergedIngredient(name: key.prefix(1).uppercased() + key.dropFirst(), meals: meals)
        }.sorted { $0.name < $1.name }
    }

    private func addMissingToGrocery() {
        let stocked = Set(store.inventoryItems.map { $0.name.lowercased() })
        var added = 0
        for ing in mergedIngredients {
            let lower = ing.name.lowercased()
            let inStock = stocked.contains(where: { $0.contains(lower) || lower.contains($0) })
            let inList  = store.groceryItems.contains { $0.name.lowercased() == lower }
            guard !inStock && !inList else { continue }
            let source = ing.meals.first ?? ""
            store.addToGroceryIfMissing(ing.name, recommended: true, recipeSource: source)
            added += 1
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation { showAddToast = true }
        Task {
            try? await Task.sleep(nanoseconds: 3000000000)
            withAnimation { showAddToast = false }
        }
        BuildConfig.log("Meal prep: added \(added) ingredients to grocery list")
    }

    private func sectionLabel(_ t: String) -> some View {
        SectionHeader(text: t)
    }

    private func statPill(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).scaledFont(20, weight: .bold, design: .serif).foregroundStyle(session.themeTextColor)
            Text(label).scaledFont(10).foregroundStyle(session.themeTextColor.opacity(0.45))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(Color.stockedWhite.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }
}

#Preview { MealPrepView().environment(AppSession()) }
