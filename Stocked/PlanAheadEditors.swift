import SwiftUI

/// Editors keep local drafts. The caller owns permission checks, stale-edit checks,
/// persistence and household synchronization, and throws if a save is no longer valid.
struct PlanTemplateEditor: View {
    @Environment(AppSession.self) private var session
    private let original: MealPlanTemplate
    private let onSave: (MealPlanTemplate) throws -> Void
    @State private var draft: MealPlanTemplate
    @State private var editingEntry: MealPlanTemplateEntry?
    @State private var removingEntry: MealPlanTemplateEntry?

    init(template: MealPlanTemplate, onSave: @escaping (MealPlanTemplate) throws -> Void) {
        original = template; self.onSave = onSave
        _draft = State(initialValue: template)
    }

    var body: some View {
        PlanEditorShell(title: "Meal template", isDirty: draft != original, onSave: save) {
            Text("Save a week you like, then choose when to use it. Editing this template leaves meals already on your calendar unchanged.")
                .foregroundStyle(session.themeSecondaryText)
            PlanEditorTextField(label: "Template name", placeholder: "Easy dinners", text: $draft.name)
            Text("\(draft.entries.count) of 21 meals").font(.stocked(.headline))
            if draft.entries.isEmpty {
                Text("Add your first meal below. Day 1 means the first date you choose when using this template.")
                    .foregroundStyle(session.themeSecondaryText)
            }
            ForEach(draft.entries) { entry in
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Day \(entry.dayOffset + 1) · \(entry.mealType)")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                        Text(entry.title).font(.stocked(.headline))
                        Text("\(entry.servings) servings · \(entry.ingredients.count) ingredients")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                        ViewThatFits(in: .horizontal) {
                            HStack { editButton(entry); removeButton(entry) }
                            VStack(alignment: .leading) { editButton(entry); removeButton(entry) }
                        }
                    }
                }
            }
            Button {
                editingEntry = MealPlanTemplateEntry(dayOffset: 0, title: "", mealType: "Dinner", servings: 2, ingredients: [])
            } label: {
                Label("Add a meal", systemImage: "plus.circle").frame(maxWidth: .infinity, minHeight: 44)
            }.buttonStyle(.bordered).disabled(draft.entries.count >= PlanAheadCore.maximumTemplateEntries)
        }
        .sheet(item: $editingEntry) { entry in
            PlanTemplateEntryEditor(entry: entry) { updated in
                var proposed = draft
                if let index = proposed.entries.firstIndex(where: { $0.id == updated.id }) {
                    proposed.entries[index] = updated
                } else { proposed.entries.append(updated) }
                // An unnamed parent draft is allowed while meals are being composed.
                guard proposed.entries.count <= PlanAheadCore.maximumTemplateEntries else { throw PlanAheadCore.Failure.tooManyEntries }
                try PlanAheadCore.validate(updated)
                draft.entries = proposed.entries
            }.environment(session)
        }
        .confirmationDialog("Remove this meal from the template?", isPresented: Binding(
            get: { removingEntry != nil }, set: { if !$0 { removingEntry = nil } }), titleVisibility: .visible) {
                Button("Remove meal", role: .destructive) {
                    if let entry = removingEntry { draft.entries.removeAll { $0.id == entry.id } }
                    removingEntry = nil
                }
                Button("Keep meal", role: .cancel) { removingEntry = nil }
            } message: { Text("Meals already added to your calendar stay unchanged. Save the template to keep this change.") }
    }

    private func editButton(_ entry: MealPlanTemplateEntry) -> some View {
        Button { editingEntry = entry } label: { Label("Edit meal", systemImage: "pencil").frame(minHeight: 44) }
            .accessibilityLabel("Edit \(entry.title)")
    }
    private func removeButton(_ entry: MealPlanTemplateEntry) -> some View {
        Button(role: .destructive) { removingEntry = entry } label: {
            Label("Remove", systemImage: "trash").frame(minHeight: 44)
        }.accessibilityLabel("Remove \(entry.title) from template")
    }
    private func save() throws {
        try PlanAheadCore.validate(draft)
        try onSave(draft)
    }
}

struct PlanRuleEditor: View {
    @Environment(AppSession.self) private var session
    private let original: MealPlanRule
    private let templates: [MealPlanTemplate]
    private let onSave: (MealPlanRule) throws -> Void
    @State private var draft: MealPlanRule

    init(rule: MealPlanRule, templates: [MealPlanTemplate], onSave: @escaping (MealPlanRule) throws -> Void) {
        original = rule; self.templates = templates; self.onSave = onSave
        _draft = State(initialValue: rule)
    }

    var body: some View {
        PlanEditorShell(title: "Repeat a template", isDirty: draft != original, onSave: save) {
            Text("Choose a template and a start date. Each time you apply this repeat, you review the dates before any meals are added.")
                .foregroundStyle(session.themeSecondaryText)
            PlanEditorTextField(label: "Repeat name", placeholder: "Our easy dinner weeks", text: $draft.name)
            ToolboxCard {
                Picker("Meal template", selection: $draft.templateID) {
                    if !templates.contains(where: { $0.id == draft.templateID }) {
                        Text("Choose an available template").tag(draft.templateID)
                    }
                    ForEach(templates) { Text($0.name).tag($0.id) }
                }.pickerStyle(.menu)
            }
            PlanCivilDateField(label: "First day", civilDate: $draft.startDate, timeZoneID: $draft.timeZoneID)
            ToolboxCard {
                VStack(alignment: .leading, spacing: 16) {
                    Stepper(value: $draft.intervalWeeks, in: 1...4) {
                        Text(draft.intervalWeeks == 1 ? "Repeat every week" : "Repeat every \(draft.intervalWeeks) weeks")
                    }
                    Stepper(value: $draft.occurrences, in: 1...12) {
                        Text("Repeat \(draft.occurrences) \(draft.occurrences == 1 ? "time" : "times")")
                    }
                    Toggle("Pause this repeat", isOn: $draft.isPaused)
                }
            }
            Text(scheduleSummary).foregroundStyle(session.themeSecondaryText)
            if draft.isPaused {
                Label("Paused repeats add no meals. Existing dates stay on your calendar.", systemImage: "pause.circle")
                    .font(.stocked(.footnote))
            }
        }
    }

    private var scheduleSummary: String {
        guard let template = templates.first(where: { $0.id == draft.templateID }),
              (1...12).contains(draft.occurrences), (1...4).contains(draft.intervalWeeks) else {
            return "Choose a template to see how many meals this will add."
        }
        let count = template.entries.count * draft.occurrences
        return "Up to \(count) dated meals across \((draft.occurrences - 1) * draft.intervalWeeks + 1) weeks. Repeats stop after the count you choose, always within one year. Previously added, skipped or moved meals are kept."
    }
    private func save() throws {
        try PlanAheadCore.validate(draft)
        guard let template = templates.first(where: { $0.id == draft.templateID }) else { throw PlanAheadCore.Failure.wrongTemplate }
        try PlanAheadCore.validate(template)
        try onSave(draft)
    }
}

struct ScheduledMealEditor: View {
    @Environment(AppSession.self) private var session
    private let original: ScheduledMeal
    private let onSave: (ScheduledMeal) throws -> Void
    @State private var draft: ScheduledMeal
    @State private var ingredientsText: String
    @State private var showingRecipes = false

    init(meal: ScheduledMeal, onSave: @escaping (ScheduledMeal) throws -> Void) {
        original = meal; self.onSave = onSave
        _draft = State(initialValue: meal)
        _ingredientsText = State(initialValue: meal.ingredients.joined(separator: "\n"))
    }
    private var isDirty: Bool { draft != original || ingredientsText != original.ingredients.joined(separator: "\n") }

    var body: some View {
        PlanEditorShell(title: "Plan a meal", isDirty: isDirty, onSave: save) {
            Text("Keep a meal on a specific date. It joins cooking and grocery planning only when you choose to add it to your active week.")
                .foregroundStyle(session.themeSecondaryText)
            PlanCivilDateField(label: "Meal date", civilDate: $draft.civilDate, timeZoneID: $draft.timeZoneID)
            PlanMealFields(title: $draft.title, mealType: $draft.mealType, servings: $draft.servings,
                           ingredientsText: $ingredientsText) { showingRecipes = true }
            if draft.movedToWeek {
                Text("This meal already has a copy in your active week. Edits here leave that copy unchanged.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            }
        }
        .sheet(isPresented: $showingRecipes) {
            PlanSavedRecipePicker { recipe in
                draft.title = recipe.title; draft.servings = recipe.servings; draft.recipeID = recipe.id
                ingredientsText = PlanEditorIngredients.from(recipe).joined(separator: "\n")
            }.environment(session)
        }
    }
    private func save() throws {
        var proposed = draft
        proposed.ingredients = PlanEditorIngredients.lines(ingredientsText)
        try PlanAheadCore.validate(proposed)
        try onSave(proposed)
    }
}

private struct PlanTemplateEntryEditor: View {
    @Environment(AppSession.self) private var session
    private let original: MealPlanTemplateEntry
    private let onSave: (MealPlanTemplateEntry) throws -> Void
    @State private var draft: MealPlanTemplateEntry
    @State private var ingredientsText: String
    @State private var showingRecipes = false

    init(entry: MealPlanTemplateEntry, onSave: @escaping (MealPlanTemplateEntry) throws -> Void) {
        original = entry; self.onSave = onSave
        _draft = State(initialValue: entry)
        _ingredientsText = State(initialValue: entry.ingredients.joined(separator: "\n"))
    }
    private var isDirty: Bool { draft != original || ingredientsText != original.ingredients.joined(separator: "\n") }

    var body: some View {
        PlanEditorShell(title: "Template meal", isDirty: isDirty, onSave: save) {
            ToolboxCard {
                Picker("Day in the template", selection: $draft.dayOffset) {
                    ForEach(0..<7) { Text("Day \($0 + 1)").tag($0) }
                }.pickerStyle(.menu)
            }
            Text("Day 1 is the start date you choose when using the template.")
                .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            PlanMealFields(title: $draft.title, mealType: $draft.mealType, servings: $draft.servings,
                           ingredientsText: $ingredientsText) { showingRecipes = true }
        }
        .sheet(isPresented: $showingRecipes) {
            PlanSavedRecipePicker { recipe in
                draft.title = recipe.title; draft.servings = recipe.servings; draft.recipeID = recipe.id
                ingredientsText = PlanEditorIngredients.from(recipe).joined(separator: "\n")
            }.environment(session)
        }
    }
    private func save() throws {
        var proposed = draft
        proposed.ingredients = PlanEditorIngredients.lines(ingredientsText)
        try PlanAheadCore.validate(proposed)
        try onSave(proposed)
    }
}

private struct PlanEditorShell<Content: View>: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let title: String
    let isDirty: Bool
    let onSave: () throws -> Void
    @ViewBuilder let content: () -> Content
    @State private var errorMessage = ""
    @State private var confirmDiscard = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    content()
                    if !errorMessage.isEmpty {
                        Label(errorMessage, systemImage: "exclamationmark.circle")
                            .accessibilityAddTraits(.updatesFrequently)
                    }
                }.padding(20).frame(maxWidth: 680, alignment: .leading).frame(maxWidth: .infinity)
                    .font(.stocked(.body)).foregroundStyle(session.themeTextColor)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(session.themeBgColor, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if isDirty { confirmDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try onSave(); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }.font(.stocked(.body).bold())
                }
            }
        }
        .tint(session.accentColor)
        .interactiveDismissDisabled(isDirty)
        .confirmationDialog("Discard these changes?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) { }
        }
    }
}

private struct PlanEditorTextField: View {
    @Environment(AppSession.self) private var session
    let label: String
    let placeholder: String
    @Binding var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label).font(.stocked(.headline))
            TextField(placeholder, text: $text, axis: .vertical)
                .padding(12).background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(label)
        }
    }
}

private struct PlanCivilDateField: View {
    @Environment(AppSession.self) private var session
    let label: String
    @Binding var civilDate: String
    @Binding var timeZoneID: String

    var body: some View {
        ToolboxCard {
            VStack(alignment: .leading, spacing: 14) {
                if let zone = TimeZone(identifier: timeZoneID),
                   let date = try? PlanAheadCore.parseDate(civilDate, timeZoneID: timeZoneID) {
                    DatePicker(label, selection: Binding(get: { date }, set: { value in
                        if let key = try? PlanAheadCore.dateKey(for: value, timeZoneID: timeZoneID) { civilDate = key }
                    }), displayedComponents: .date)
                    .environment(\.timeZone, zone)
                    .environment(\.calendar, Calendar(identifier: .gregorian))
                } else {
                    PlanEditorTextField(label: label, placeholder: "YYYY-MM-DD", text: $civilDate)
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Plan time zone").font(.stocked(.headline))
                    TextField("America/Chicago", text: $timeZoneID)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Plan time zone")
                    Button("Use this device’s time zone") { timeZoneID = TimeZone.current.identifier }
                        .frame(minHeight: 44)
                    Text("Dates use this time zone, even when someone in your household is travelling.")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                }
            }
        }
    }
}

private struct PlanMealFields: View {
    @Environment(AppSession.self) private var session
    @Binding var title: String
    @Binding var mealType: String
    @Binding var servings: Int
    @Binding var ingredientsText: String
    let chooseRecipe: () -> Void
    private var mealTypes: [String] {
        let standard = ["Breakfast", "Lunch", "Dinner", "Snack"]
        return standard.contains(mealType) || mealType.isEmpty ? standard : standard + [mealType]
    }
    var body: some View {
        Button(action: chooseRecipe) {
            Label("Choose a saved recipe", systemImage: "books.vertical").frame(maxWidth: .infinity, minHeight: 44)
        }.buttonStyle(.bordered)
        PlanEditorTextField(label: "Meal name", placeholder: "What sounds good?", text: $title)
        ToolboxCard {
            VStack(alignment: .leading, spacing: 14) {
                Picker("Meal", selection: $mealType) { ForEach(mealTypes, id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                Stepper(value: $servings, in: 1...100) { Text("\(servings) servings") }
            }
        }
        VStack(alignment: .leading, spacing: 7) {
            Text("Ingredients").font(.stocked(.headline))
            TextField("One ingredient per line, including any amount", text: $ingredientsText, axis: .vertical)
                .lineLimit(5...12).padding(12)
                .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Ingredients, one per line")
            Text("Ingredients are optional for a meal idea. Saved recipes copy their current amounts; editing these lines leaves the recipe unchanged.")
                .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
        }
    }
}

private struct PlanSavedRecipePicker: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let onChoose: (UserRecipe) -> Void
    @State private var search = ""
    @State private var errorMessage = ""
    private var matches: [UserRecipe] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array(session.guestStore.userRecipes.lazy.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }.prefix(30))
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    Text("Choose a recipe to copy its title, servings and ingredients. This uses your saved recipe as it is today.")
                        .foregroundStyle(session.themeSecondaryText)
                    if matches.isEmpty { Text("No saved recipes match. You can return and type a meal instead.") }
                    ForEach(matches) { recipe in
                        Button { choose(recipe) } label: {
                            ToolboxCard {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(recipe.title).font(.stocked(.headline))
                                    Text("\(recipe.servings) servings · \(recipe.ingredients.count) ingredients")
                                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            }
                        }.buttonStyle(.plain)
                    }
                    Text("Showing up to 30 matches. Search by recipe name to narrow the list.")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    if !errorMessage.isEmpty { Text(errorMessage).accessibilityAddTraits(.updatesFrequently) }
                }.padding(20).foregroundStyle(session.themeTextColor)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Saved recipes").navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Recipe name")
            .toolbarBackground(session.themeBgColor, for: .navigationBar).toolbarBackground(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.tint(session.accentColor)
    }
    private func choose(_ recipe: UserRecipe) {
        do {
            let captured = MealPlanTemplateEntry(dayOffset: 0, title: recipe.title, mealType: "Dinner",
                                                 servings: recipe.servings, ingredients: PlanEditorIngredients.from(recipe), recipeID: recipe.id)
            try PlanAheadCore.validate(captured)
            onChoose(recipe)
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}

private enum PlanEditorIngredients {
    static func from(_ recipe: UserRecipe) -> [String] {
        recipe.ingredients.map { ingredient in
            [ingredient.amount, ingredient.name].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.joined(separator: " ")
        }
    }
    static func lines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
