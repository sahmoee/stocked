// ToolboxPlanning.swift — Planning tools for the Kitchen Toolbox.
// Expiry Calendar • Batch Cook Planner • List Templates • Grocery Budget
import SwiftUI

// MARK: - Expiry Calendar

struct ExpiryCalendarView: View {
    @Environment(AppSession.self) private var session
    @State private var monthAnchor = Date()
    @State private var selectedDay: Date? = nil
    @State private var expiryByDay: [Date: [LocalInventoryItem]] = [:]

    private static let cal = Calendar.current

    private func compute() {
        var map: [Date: [LocalInventoryItem]] = [:]
        for item in session.guestStore.inventoryItems {
            guard let exp = item.expirationDate else { continue }
            let day = Self.cal.startOfDay(for: exp)
            map[day, default: []].append(item)
        }
        expiryByDay = map
    }

    private var monthDays: [Date?] {
        guard let interval = Self.cal.dateInterval(of: .month, for: monthAnchor) else { return [] }
        let firstWeekday = Self.cal.component(.weekday, from: interval.start)   // 1 = Sunday
        let dayCount = Self.cal.range(of: .day, in: .month, for: monthAnchor)?.count ?? 30
        var cells: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for offset in 0..<dayCount {
            cells.append(Self.cal.date(byAdding: .day, value: offset, to: interval.start))
        }
        return cells
    }

    private func shiftMonth(_ delta: Int) {
        HapticManager.select()
        if let next = Self.cal.date(byAdding: .month, value: delta, to: monthAnchor) {
            monthAnchor = next
            selectedDay = nil
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // Month header
                HStack {
                    Button { shiftMonth(-1) } label: {
                        Image(systemName: "chevron.left").font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Previous month")
                    Spacer()
                    Text(ToolboxFormatters.monthYear.string(from: monthAnchor))
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Button { shiftMonth(1) } label: {
                        Image(systemName: "chevron.right").font(.system(size: 15, weight: .semibold))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Next month")
                }
                .foregroundStyle(session.accentColor)
                .padding(.horizontal, 6)

                // Weekday header
                HStack {
                    ForEach(["S", "M", "T", "W", "T", "F", "S"].indices, id: \.self) { i in
                        Text(["S", "M", "T", "W", "T", "F", "S"][i])
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(session.themeSecondaryText)
                            .frame(maxWidth: .infinity)
                    }
                }

                // Day grid
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
                    ForEach(Array(monthDays.enumerated()), id: \.offset) { _, day in
                        if let day {
                            dayCell(day)
                        } else {
                            Color.clear.frame(height: 40)
                        }
                    }
                }

                // Selected day list
                if let day = selectedDay {
                    let items = expiryByDay[Self.cal.startOfDay(for: day)] ?? []
                    ToolboxSectionLabel(text: "Expiring \(ToolboxFormatters.monthDay.string(from: day))")
                    if items.isEmpty {
                        Text("Nothing expires this day.")
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeSecondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(items) { item in
                            ToolboxCard {
                                HStack {
                                    Text(item.name)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(session.themeTextColor)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(item.storageCategory.icon) \(item.displayText)")
                                        .font(.system(size: 11))
                                        .foregroundStyle(session.themeSecondaryText)
                                }
                            }
                        }
                    }
                } else {
                    Text("Days with a dot have items expiring. Tap a day to see them.")
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeSecondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Expiry Calendar")
        .navigationBarTitleDisplayMode(.inline)
        .task { compute() }
        .refreshable { compute() }
    }

    @ViewBuilder
    private func dayCell(_ day: Date) -> some View {
        let key = Self.cal.startOfDay(for: day)
        let count = expiryByDay[key]?.count ?? 0
        let isToday = Self.cal.isDateInToday(day)
        let isSelected = selectedDay.map { Self.cal.isDate($0, inSameDayAs: day) } ?? false
        Button {
            HapticManager.select()
            selectedDay = day
        } label: {
            VStack(spacing: 3) {
                Text("\(Self.cal.component(.day, from: day))")
                    .font(.system(size: 13, weight: isToday ? .bold : .regular, design: .rounded))
                    .foregroundStyle(isSelected ? Color.white : (isToday ? session.accentColor : session.themeTextColor))
                Circle()
                    .fill(count > 0 ? (isSelected ? Color.white : Color.orange) : Color.clear)
                    .frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? session.accentColor : session.themeCardColor.opacity(count > 0 ? 1 : 0.45))
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(ToolboxFormatters.monthDay.string(from: day)), \(count) item\(count == 1 ? "" : "s") expiring")
    }
}

// MARK: - Batch Cook Planner

struct BatchCookPlannerView: View {
    @Environment(AppSession.self) private var session
    @State private var selected: UserRecipe? = nil
    @State private var multiplier = 2

    private func scaledAmount(_ ingredient: RecipeIngredient) -> String {
        if let qty = ingredient.quantity {
            let scaled = qty * Double(multiplier)
            let display = scaled == scaled.rounded() ? String(Int(scaled)) : String(format: "%.2g", scaled)
            if let unit = ingredient.unit, !unit.isEmpty { return "\(display) \(unit)" }
            return display
        }
        let base = ingredient.amount.trimmingCharacters(in: .whitespaces)
        return base.isEmpty ? "×\(multiplier)" : "\(base) ×\(multiplier)"
    }

    private func addAllToGrocery(_ recipe: UserRecipe) {
        var added = 0
        for ingredient in recipe.ingredients {
            let before = session.guestStore.groceryItems.count
            session.guestStore.addToGroceryIfMissing(
                ingredient.name, recommended: false,
                recipeSource: "\(recipe.title) ×\(multiplier)")
            if session.guestStore.groceryItems.count > before { added += 1 }
        }
        HapticManager.success()
        ToastCenter.shared.success(added == 0 ? "Everything is already on your list"
                                              : "Added \(added) ingredient\(added == 1 ? "" : "s") for \(recipe.title)")
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                if session.guestStore.userRecipes.isEmpty {
                    ToolboxEmptyState(icon: "square.stack.3d.up",
                                      title: "No recipes yet",
                                      message: "Save a recipe first, then scale it up here for meal prep and shop for the whole batch.")
                } else if let recipe = selected {
                    ToolboxCard {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(recipe.title)
                                .font(.system(size: 17, weight: .bold))
                                .foregroundStyle(session.themeTextColor)
                            HStack {
                                Text("Batches")
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(session.themeSecondaryText)
                                Spacer()
                                Stepper(value: $multiplier, in: 1...10) {
                                    Text("×\(multiplier)  ·  \(recipe.servings * multiplier) servings")
                                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                                        .foregroundStyle(session.accentColor)
                                }
                                .onChange(of: multiplier) { _, _ in HapticManager.select() }
                            }
                        }
                    }
                    ToolboxSectionLabel(text: "Scaled ingredients")
                    ForEach(recipe.ingredients) { ingredient in
                        ToolboxCard {
                            HStack {
                                Text(ingredient.name.capitalized)
                                    .font(.system(size: 14))
                                    .foregroundStyle(session.themeTextColor)
                                    .lineLimit(1)
                                Spacer()
                                Text(scaledAmount(ingredient))
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundStyle(session.accentColor)
                            }
                        }
                    }
                    Button { addAllToGrocery(recipe) } label: {
                        Label("Add batch to grocery list", systemImage: "cart.badge.plus")
                            .font(.system(size: 15, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(RoundedRectangle(cornerRadius: 14).fill(session.accentColor))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    Button {
                        HapticManager.light()
                        selected = nil
                        multiplier = 2
                    } label: {
                        Text("Pick a different recipe")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(session.accentColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                } else {
                    ToolboxSectionLabel(text: "Pick a recipe to batch")
                    ForEach(session.guestStore.userRecipes) { recipe in
                        Button {
                            HapticManager.light()
                            selected = recipe
                        } label: {
                            ToolboxCard {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(recipe.title)
                                            .font(.system(size: 14, weight: .medium))
                                            .foregroundStyle(session.themeTextColor)
                                            .lineLimit(1)
                                        Text("Serves \(recipe.servings) per batch")
                                            .font(.system(size: 11))
                                            .foregroundStyle(session.themeSecondaryText)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(session.themeSecondaryText.opacity(0.6))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Batch Cook Planner")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Grocery List Templates

struct GroceryTemplatesView: View {
    @Environment(AppSession.self) private var session
    @State private var templateStore = GroceryTemplateStore.shared
    @State private var showNameSheet = false
    @State private var newName = ""

    private func saveCurrentList() {
        let names = session.guestStore.groceryItems.filter { !$0.isChecked }.map { $0.name }
        guard !names.isEmpty else {
            ToastCenter.shared.info("Your grocery list is empty — nothing to save")
            return
        }
        templateStore.save(name: newName, items: names)
        HapticManager.success()
        ToastCenter.shared.success("Saved \"\(newName.trimmingCharacters(in: .whitespaces))\" (\(names.count) items)")
        newName = ""
    }

    private func load(_ template: GroceryTemplate) {
        var added = 0
        for name in template.items {
            let before = session.guestStore.groceryItems.count
            session.guestStore.addToGroceryIfMissing(name, recommended: false)
            if session.guestStore.groceryItems.count > before { added += 1 }
        }
        HapticManager.success()
        ToastCenter.shared.success(added == 0 ? "Everything is already on your list"
                                              : "Added \(added) item\(added == 1 ? "" : "s") from \(template.name)")
    }

    private func delete(_ template: GroceryTemplate) {
        let snapshot = template
        templateStore.delete(template)
        HapticManager.warning()
        // Undo affordance (UI/UX) — restores the exact template.
        ToastCenter.shared.undo("Deleted \"\(snapshot.name)\"") {
            GroceryTemplateStore.shared.templates.insert(snapshot, at: 0)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                Button {
                    HapticManager.light()
                    showNameSheet = true
                } label: {
                    Label("Save current grocery list as template", systemImage: "square.and.arrow.down")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(session.accentColor.opacity(0.14)))
                        .foregroundStyle(session.accentColor)
                }
                .buttonStyle(.plain)

                if templateStore.templates.isEmpty {
                    ToolboxEmptyState(icon: "list.bullet.rectangle",
                                      title: "No templates yet",
                                      message: "Save your weekly staples once, then reload them onto your grocery list in one tap.")
                } else {
                    ToolboxSectionLabel(text: "Your templates")
                    ForEach(templateStore.templates) { template in
                        ToolboxCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(template.name)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(session.themeTextColor)
                                        .lineLimit(1)
                                    Spacer()
                                    Text("\(template.items.count) items")
                                        .font(.system(size: 11))
                                        .foregroundStyle(session.themeSecondaryText)
                                }
                                Text(template.items.prefix(6).joined(separator: ", ") + (template.items.count > 6 ? "…" : ""))
                                    .font(.system(size: 12))
                                    .foregroundStyle(session.themeSecondaryText)
                                    .lineLimit(2)
                                HStack(spacing: 10) {
                                    Button { load(template) } label: {
                                        Label("Add to list", systemImage: "cart.badge.plus")
                                            .font(.system(size: 13, weight: .semibold))
                                            .padding(.horizontal, 12).padding(.vertical, 7)
                                            .background(Capsule().fill(session.accentColor))
                                            .foregroundStyle(.white)
                                    }
                                    .buttonStyle(.plain)
                                    Button { delete(template) } label: {
                                        Text("Delete")
                                            .font(.system(size: 13, weight: .semibold))
                                            .padding(.horizontal, 12).padding(.vertical, 7)
                                            .background(Capsule().fill(Color.red.opacity(0.12)))
                                            .foregroundStyle(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("List Templates")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Name this template", isPresented: $showNameSheet) {
            TextField("e.g. Weekly staples", text: $newName)
            Button("Save") { saveCurrentList() }
            Button("Cancel", role: .cancel) { newName = "" }
        } message: {
            Text("Saves the unchecked items on your current grocery list.")
        }
    }
}

// MARK: - Grocery Budget

struct BudgetTrackerView: View {
    @Environment(AppSession.self) private var session
    @State private var limitText = ""
    @State private var limit: Double = 0
    @State private var spent: Double = 0

    private func compute() {
        limit = GroceryBudget.monthlyLimit
        spent = GroceryBudget.spentThisMonth(session.guestStore.priceHistory)
        if limit > 0 { limitText = String(format: "%.0f", limit) }
    }

    private func saveLimit() {
        let value = Double(limitText.replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespaces)) ?? 0
        GroceryBudget.monthlyLimit = max(0, value)
        limit = GroceryBudget.monthlyLimit
        HapticManager.success()
        ToastCenter.shared.success(limit > 0 ? "Budget set to \(ToolboxFormatters.dollars(limit))/month"
                                             : "Budget cleared")
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Monthly budget")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                        HStack {
                            Text("$")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(session.themeSecondaryText)
                            TextField("0", text: $limitText)
                                .keyboardType(.decimalPad)
                                .font(.system(size: 16, weight: .semibold, design: .rounded))
                                .foregroundStyle(session.themeTextColor)
                            Button("Set") { saveLimit() }
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(session.accentColor)
                                .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(session.themeBgColor))
                    }
                }
                HStack(spacing: 10) {
                    ToolboxStatTile(value: ToolboxFormatters.dollars(spent), label: "Spent this month")
                    ToolboxStatTile(value: limit > 0 ? ToolboxFormatters.dollars(max(0, limit - spent)) : "—",
                                    label: "Remaining",
                                    tint: limit > 0 && spent > limit ? .red : .green)
                }
                if limit > 0 {
                    let ratio = min(1, spent / limit)
                    ToolboxCard {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(spent > limit
                                 ? "Over budget by \(ToolboxFormatters.dollars(spent - limit))"
                                 : "\(Int(ratio * 100))% of budget used")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(spent > limit ? .red : session.themeTextColor)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(session.themeBgColor)
                                    Capsule().fill(spent > limit ? Color.red : (ratio > 0.85 ? Color.orange : Color.green))
                                        .frame(width: max(6, geo.size.width * ratio))
                                }
                            }
                            .frame(height: 8)
                            .accessibilityLabel("\(Int(ratio * 100)) percent of budget used")
                        }
                    }
                }
                Text("Spending comes from your recorded prices — receipt scans and item prices dated this month.")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Grocery Budget")
        .navigationBarTitleDisplayMode(.inline)
        .task { compute() }
        .refreshable { compute() }
    }
}
