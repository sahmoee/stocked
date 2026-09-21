import SwiftUI

struct PlanAheadView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var store = PlanAheadStore.shared
    @State private var page = 0
    @State private var firstDay = Date()
    @State private var showSkipped = false
    @State private var message = ""
    @State private var loading = false
    @State private var task: Task<Void, Never>?
    @State private var previewID = UUID()
    @State private var editor: PlanningEditor?
    @State private var review: PlanningReview?
    @State private var deletion: PlanningDeletion?

    private var canEdit: Bool { HouseholdSync.shared.can(.mealPlanEdit) }
    private var dateKeys: [String] {
        (0..<7).compactMap { offset in
            Calendar.current.date(byAdding: .day, value: offset, to: firstDay).flatMap {
                try? PlanAheadCore.dateKey(for: $0, timeZoneID: TimeZone.current.identifier)
            }
        }
    }
    private var visibleMeals: [ScheduledMeal] {
        let keys = Set(dateKeys)
        return store.scheduledMeals.filter { keys.contains($0.civilDate) && (showSkipped || !$0.isSkipped) }
            .sorted { ($0.civilDate, $0.mealType, $0.title, $0.id.uuidString) < ($1.civilDate, $1.mealType, $1.title, $1.id.uuidString) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("A little planning, a calmer week").font(.stocked(.title2))
                    Text("Keep real dates here. Review repeat schedules, then choose which meals to add to your active week when you’re ready.")
                        .font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
                    Picker("Planning tools", selection: $page) {
                        Text("Dates").tag(0); Text("Templates").tag(1); Text("Repeats").tag(2)
                    }.pickerStyle(.segmented)
                    if !canEdit { Label("Your household role can view these plans but cannot change them.", systemImage: "lock").font(.stocked(.footnote)) }
                    if !HouseholdSync.shared.syncMealPlans {
                        Label("Meal plan sharing is off on this device. These edits will stay here until you turn it on in household settings.", systemImage: "icloud.slash")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    }
                    if page == 0 { datesPage }
                    else if page == 1 { templatesPage }
                    else { repeatsPage }
                    if loading { ProgressView("Preparing your preview…") }
                    if !message.isEmpty { Text(message).font(.stocked(.body)).accessibilityAddTraits(.updatesFrequently) }
                    if let error = store.lastError { Text(error).font(.stocked(.footnote)) }
                    if store.canUndoDates || store.canUndoWeek {
                        ToolboxCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("Undo this visit").font(.stocked(.headline))
                                Text("Only unchanged additions are removed. Later edits and other meals stay.")
                                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                                if store.canUndoDates { Button("Undo last dated additions") { perform { "Removed \(try store.undoDates()) unchanged dated meals." } } }
                                if store.canUndoWeek { Button("Undo last active-week additions") { perform { "Removed \(try store.undoWeek(store: session.guestStore)) unchanged active meals." } } }
                            }
                        }.disabled(!canEdit || loading)
                    }
                    Text("Templates and dated plans use your household’s existing storage and sharing. Creating them never buys food, deducts inventory or pays for AI.")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                }.padding(20).foregroundStyle(session.themeTextColor)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Plan ahead").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $editor) { request in
                switch request {
                case .template(let value, let baseline):
                    PlanTemplateEditor(template: value) { try store.saveTemplate($0, expected: baseline) }.environment(session)
                case .rule(let value, let baseline):
                    PlanRuleEditor(rule: value, templates: store.templates) { try store.saveRule($0, expected: baseline) }.environment(session)
                case .meal(let value, let baseline):
                    ScheduledMealEditor(meal: value) { try store.saveMeal($0, expected: baseline) }.environment(session)
                }
            }
            .sheet(item: $review) { request in
                PlanningReviewView(review: request) {
                    let count: Int
                    switch request.payload {
                    case .dates(let value): count = try store.apply(value)
                    case .week(let value): count = try store.activate(value, store: session.guestStore)
                    }
                    message = "Added \(count) meals. Your existing meals were kept."
                }.environment(session)
            }
            .confirmationDialog(deletion?.title ?? "Remove this item?", isPresented: Binding(
                get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
                if let deletion {
                    Button(deletion.action, role: .destructive) {
                        perform {
                            switch deletion {
                            case .template(let item): try store.removeTemplate(item)
                            case .rule(let item): try store.removeRule(item)
                            case .meal(let item): try store.removeMeal(item)
                            }
                            return "Updated. Other saved meals were kept."
                        }
                    }
                }
            } message: { Text(deletion?.detail ?? "") }
            .onDisappear { previewID = UUID(); task?.cancel(); loading = false; store.clearUndo() }
        }.tint(session.themeButtonColor)
    }

    private var datesPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            DatePicker("Week starting", selection: $firstDay, displayedComponents: .date)
            HStack {
                Button { shift(-7) } label: { Label("Earlier", systemImage: "chevron.left").frame(minHeight: 44) }
                Spacer()
                Button("Today") { firstDay = Date() }.frame(minHeight: 44)
                Spacer()
                Button { shift(7) } label: { Label("Later", systemImage: "chevron.right").frame(minHeight: 44) }
            }
            Text("Dates are shown as entered. Each meal keeps its schedule’s time zone.")
                .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
            Button { newDatedMeal() } label: { Label("Add a dated meal", systemImage: "plus.circle").frame(minHeight: 44) }.disabled(!canEdit)
            Toggle("Show skipped meals", isOn: $showSkipped).font(.stocked(.footnote))
            if visibleMeals.isEmpty {
                Label("Room for something good. Add a meal, or use a template from Repeats.", systemImage: "calendar")
                    .padding(.vertical, 20).foregroundStyle(session.themeSecondaryText)
            }
            ForEach(dateKeys, id: \.self) { key in
                let meals = visibleMeals.filter { $0.civilDate == key }
                if !meals.isEmpty {
                    Text(dateLabel(key)).font(.stocked(.headline)).padding(.top, 6)
                    ForEach(meals.prefix(60)) { meal in
                        ToolboxCard {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(meal.title).font(.stocked(.headline)).strikethrough(meal.isSkipped)
                                    Text("\(meal.mealType) · \(meal.servings) servings").font(.stocked(.footnote))
                                    Text(meal.timeZoneID).font(.stocked(.caption)).foregroundStyle(session.themeSecondaryText)
                                    if meal.movedToWeek { Label("Added to the active week", systemImage: "checkmark.circle").font(.stocked(.footnote)) }
                                    if meal.isSkipped { Text("Skipped · repeat previews will keep this choice").font(.stocked(.footnote)) }
                                }
                                Spacer()
                                Menu {
                                    if !meal.movedToWeek {
                                        Button("Edit this dated meal") { editor = .meal(meal, meal) }
                                        Button(meal.isSkipped ? "Restore this meal" : "Skip this meal") { perform { try store.skip(meal); return "Updated this date only." } }
                                    }
                                    Button("Remove…", role: .destructive) { deletion = .meal(meal) }
                                } label: { Image(systemName: "ellipsis.circle").frame(minWidth: 44, minHeight: 44) }
                                    .disabled(!canEdit).accessibilityLabel("Options for \(meal.title)")
                            }
                        }
                    }
                    if meals.count > 60 { Text("Showing the first 60 meals for this date.").font(.stocked(.footnote)) }
                }
            }
            Button("Review meals for the active week") { previewWeek() }
                .buttonStyle(.borderedProminent).disabled(loading || !canEdit || visibleMeals.isEmpty)
            Text("Only meals dated today through the next six days can move into the active week. Same-name meals in the same slot are skipped. The copy follows the active planner’s existing day slots; it does not stay linked to its calendar date.")
                .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
        }
    }

    private var templatesPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Save a week you’d like to use again. Templates store meal details, not cooked status or grocery changes.")
                .foregroundStyle(session.themeSecondaryText)
            Button("Make a template") { editor = .template(MealPlanTemplate(name: "", entries: []), nil) }.buttonStyle(.borderedProminent).disabled(!canEdit)
            Button("Capture my active week") { captureTemplate() }.disabled(!canEdit || session.guestStore.plannedMeals.isEmpty)
            ForEach(store.templates.prefix(50)) { template in
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(template.name).font(.stocked(.headline))
                        Text("\(template.entries.count) meals · up to seven days").font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                        ViewThatFits(in: .horizontal) {
                            HStack { templateActions(template) }
                            VStack(alignment: .leading) { templateActions(template) }
                        }
                    }
                }
            }
            if store.templates.count > 50 { Text("Showing the first 50 shared templates.").font(.stocked(.footnote)) }
        }
    }

    @ViewBuilder private func templateActions(_ template: MealPlanTemplate) -> some View {
        Button("Use & repeat") { newRule(template) }.disabled(!canEdit)
        Button("Edit") { editor = .template(template, template) }.disabled(!canEdit)
        Button("Remove…", role: .destructive) { deletion = .template(template) }.disabled(!canEdit)
    }

    private var repeatsPage: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Choose a template, a first date and how often it repeats. Save the schedule, then review its dated meals before adding them. Up to 12 repeats; nothing runs while the app is closed.")
                .foregroundStyle(session.themeSecondaryText)
            if store.templates.isEmpty { Button("Make your first template") { page = 1 } }
            else { Button("New repeat schedule") { if let template = store.templates.first { newRule(template) } }.buttonStyle(.borderedProminent).disabled(!canEdit) }
            ForEach(store.rules.prefix(100)) { rule in
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(rule.name).font(.stocked(.headline))
                        Text("From \(rule.startDate) · every \(rule.intervalWeeks) week\(rule.intervalWeeks == 1 ? "" : "s") · \(rule.occurrences) times")
                            .font(.stocked(.footnote))
                        Text(rule.timeZoneID).font(.stocked(.caption)).foregroundStyle(session.themeSecondaryText)
                        if rule.isPaused { Text("Paused · existing dated meals stay").font(.stocked(.footnote)) }
                        Button("Preview dated meals") { previewRule(rule) }.disabled(loading || !canEdit || rule.isPaused)
                        ViewThatFits(in: .horizontal) {
                            HStack { ruleActions(rule) }
                            VStack(alignment: .leading) { ruleActions(rule) }
                        }
                    }
                }
            }
            if store.rules.count > 100 { Text("Showing the first 100 shared repeat schedules.").font(.stocked(.footnote)) }
            Text("Editing a template or repeat schedule changes new previews. It does not replace dated meals you already added or edited. Skip one dated meal to keep that exception.")
                .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
        }
    }

    @ViewBuilder private func ruleActions(_ rule: MealPlanRule) -> some View {
        Button("Edit") { editor = .rule(rule, rule) }.disabled(!canEdit)
        Button(rule.isPaused ? "Resume" : "Pause") {
            perform { var value = rule; value.isPaused.toggle(); try store.saveRule(value, expected: rule); return value.isPaused ? "Future additions paused. Existing dated meals stay." : "Repeat previews enabled." }
        }.disabled(!canEdit)
        Button("Remove…", role: .destructive) { deletion = .rule(rule) }.disabled(!canEdit)
    }

    private func shift(_ days: Int) {
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: firstDay) else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { firstDay = date }
    }
    private func dateLabel(_ key: String) -> String {
        guard let date = try? PlanAheadCore.parseDate(key, timeZoneID: TimeZone.current.identifier) else { return key }
        return date.formatted(date: .complete, time: .omitted)
    }
    private func newDatedMeal() {
        perform {
            let key = try PlanAheadCore.dateKey(for: firstDay, timeZoneID: TimeZone.current.identifier)
            editor = .meal(ScheduledMeal(civilDate: key, timeZoneID: TimeZone.current.identifier, title: "", mealType: "Dinner", servings: 2, ingredients: []), nil)
            return ""
        }
    }
    private func captureTemplate() {
        let source = session.guestStore.plannedMeals.filter { !$0.isBuilding }
        guard (1...21).contains(source.count), source.allSatisfy({ (0..<7).contains($0.dayIndex) }) else {
            message = "Capture between 1 and 21 finished meal entries from the active seven-day plan."; return
        }
        let entries = source.map { MealPlanTemplateEntry(dayOffset: $0.dayIndex, title: $0.title, mealType: $0.mealType, servings: $0.servings, ingredients: $0.ingredients) }
        editor = .template(MealPlanTemplate(name: "", entries: entries), nil)
    }
    private func newRule(_ template: MealPlanTemplate) {
        perform {
            let date = try PlanAheadCore.dateKey(for: firstDay, timeZoneID: TimeZone.current.identifier)
            editor = .rule(MealPlanRule(name: template.name, templateID: template.id, startDate: date,
                timeZoneID: TimeZone.current.identifier, intervalWeeks: 1, occurrences: 4), nil)
            return ""
        }
    }
    private func previewRule(_ rule: MealPlanRule) {
        task?.cancel(); loading = true; message = ""
        let requestID = UUID(); previewID = requestID
        task = Task {
            defer { if previewID == requestID { loading = false } }
            do { let value = try await store.expansionReview(for: rule); try Task.checkCancellation(); review = PlanningReview(payload: .dates(value)) }
            catch is CancellationError { }
            catch { if previewID == requestID { message = error.localizedDescription } }
        }
    }
    private func previewWeek() {
        task?.cancel(); loading = true; message = ""
        let requestID = UUID(); previewID = requestID
        let source = visibleMeals
        task = Task {
            defer { if previewID == requestID { loading = false } }
            do { let value = try await store.weekReview(from: source, active: session.guestStore.plannedMeals); try Task.checkCancellation(); review = PlanningReview(payload: .week(value)) }
            catch is CancellationError { }
            catch { if previewID == requestID { message = error.localizedDescription } }
        }
    }
    private func perform(_ action: () throws -> String) {
        do { message = try action() } catch { message = error.localizedDescription }
    }
}

private enum PlanningEditor: Identifiable {
    case template(MealPlanTemplate, MealPlanTemplate?), rule(MealPlanRule, MealPlanRule?), meal(ScheduledMeal, ScheduledMeal?)
    var id: UUID {
        switch self { case .template(let value, _): value.id; case .rule(let value, _): value.id; case .meal(let value, _): value.id }
    }
}

private enum PlanningDeletion {
    case template(MealPlanTemplate), rule(MealPlanRule), meal(ScheduledMeal)
    var title: String { "Remove this saved item?" }
    var action: String {
        switch self { case .meal(let meal) where meal.ruleID != nil && !meal.movedToWeek: "Skip this occurrence"; default: "Remove" }
    }
    var detail: String {
        switch self {
        case .template: "Templates still used by a repeat schedule must be kept. Other meals are unchanged."
        case .rule: "Existing dated meals stay. This schedule will no longer create new previews."
        case .meal(let meal) where meal.ruleID != nil && !meal.movedToWeek: "This occurrence stays marked as skipped so repeat previews do not bring it back."
        case .meal: "Only this dated record is removed. Active-week meals and recipes stay."
        }
    }
}

private struct PlanningReview: Identifiable {
    let id = UUID()
    enum Payload { case dates(PlanExpansionReview), week(PlanWeekReview) }
    let payload: Payload
    struct Line: Identifiable {
        let id: UUID; let date: String; let title: String; let detail: String; let ingredients: [String]
    }
    var lines: [Line] {
        switch payload {
        case .dates(let value): value.additions.map { Line(id: $0.id, date: $0.civilDate, title: $0.title, detail: "\($0.mealType) · \($0.servings) servings · \($0.timeZoneID)", ingredients: $0.ingredients) }
        case .week(let value): value.proposals.map { Line(id: $0.occurrenceID, date: $0.civilDate, title: $0.title, detail: "Active day \($0.dayOffset + 1) · \($0.mealType) · \($0.servings) servings · \($0.timeZoneID)", ingredients: $0.ingredients) }
        }
    }
    var title: String { switch payload { case .dates: "Review dated meals"; case .week: "Review active-week additions" } }
    var explanation: String {
        switch payload {
        case .dates: "These dates are separate from cooking and grocery reservations. Existing dated meals and skipped occurrences stay unchanged."
        case .week: "This copies eligible dates into the active seven-day planner. It can reserve ingredients there, but never deducts food or marks a meal cooked. Copies do not stay linked to calendar dates."
        }
    }
}

private struct PlanningReviewView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let review: PlanningReview
    let onApply: () throws -> Void
    @State private var error: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(review.explanation).foregroundStyle(session.themeSecondaryText)
                    Text("\(review.lines.count) meals to add").font(.stocked(.headline))
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(review.lines) { line in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.date).font(.stocked(.caption)).foregroundStyle(session.themeSecondaryText)
                                Text(line.title).font(.stocked(.headline))
                                Text(line.detail).font(.stocked(.footnote))
                                if !line.ingredients.isEmpty {
                                    DisclosureGroup("Ingredients (\(line.ingredients.count))") {
                                        Text(line.ingredients.joined(separator: "\n")).font(.stocked(.footnote)).frame(maxWidth: .infinity, alignment: .leading)
                                    }.font(.stocked(.footnote))
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                                .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                    if let error { Text(error).foregroundStyle(session.themeSecondaryText) }
                    Button("Add these \(review.lines.count) meals") {
                        do { try onApply(); dismiss() } catch { self.error = error.localizedDescription }
                    }.buttonStyle(.borderedProminent).disabled(!HouseholdSync.shared.can(.mealPlanEdit))
                }.padding(20).foregroundStyle(session.themeTextColor)
            }
            .background(session.themeBgColor.ignoresSafeArea()).navigationTitle(review.title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }.tint(session.themeButtonColor)
    }
}
