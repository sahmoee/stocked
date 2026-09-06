import SwiftUI
import UniformTypeIdentifiers

struct MealCalendarDocument: FileDocument {
    static var readableContentTypes: [UTType] { [UTType(filenameExtension: "ics") ?? .plainText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct MealPlanToolsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Binding var meals: [PlannedMeal]
    @State private var fromDay = 0
    @State private var toDay = 1
    @State private var firstDay = Date()
    @State private var exportDocument: MealCalendarDocument?
    @State private var exporting = false
    @State private var message = ""
    @State private var addedMeals: [PlannedMeal] = []
    @State private var reviewCopies = false
    @State private var reviewedCopies: [PlannedMeal] = []
    @State private var reviewedFromDay = 0
    @State private var reviewedToDay = 1

    private var planned: [PlannedMeal] { meals.filter { !$0.isBuilding } }
    private var copies: [PlannedMeal] {
        guard fromDay != toDay, meals.count < 200 else { return [] }
        var keys = Set(meals.map { MealPlanExchange.duplicateKey(day: $0.dayIndex, title: $0.title, type: $0.mealType) })
        return meals.filter { $0.dayIndex == fromDay && !$0.isBuilding }.compactMap { meal in
            let key = MealPlanExchange.duplicateKey(day: toDay, title: meal.title, type: meal.mealType)
            guard keys.insert(key).inserted else { return nil }
            var copy = meal
            copy.dayIndex = toDay; copy.isCooked = false
            copy.cookAheadStatus = .none; copy.updatedAt = 0; copy.lastWriterID = ""
            return copy
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Reuse a day you enjoyed, or save your plan to a calendar file.")
                    ToolboxCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Repeat meals").font(.headline)
                            Picker("Copy from", selection: $fromDay) {
                                ForEach(0..<7) { Text(dayName($0)).tag($0) }
                            }
                            Picker("Add to", selection: $toDay) {
                                ForEach(0..<7) { Text(dayName($0)).tag($0) }
                            }
                            Text("Existing meals stay. Same-name meals in the same slot are skipped. Copies start as not cooked; food is not deducted.")
                                .font(.caption).foregroundStyle(session.themeSecondaryText)
                            ForEach(copies.prefix(30)) { meal in
                                Label("\(meal.mealType): \(meal.title)", systemImage: "plus.circle")
                            }
                            Button("Review \(copies.count) additions") {
                                reviewedCopies = copies; reviewedFromDay = fromDay; reviewedToDay = toDay
                                reviewCopies = true
                            }
                                .disabled(copies.isEmpty || !HouseholdSync.shared.can(.mealPlanEdit))
                            if !addedMeals.isEmpty {
                                Button("Undo last additions") { undo() }
                            }
                        }
                    }
                    ToolboxCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Calendar file").font(.headline)
                            DatePicker("Day 1 of this plan", selection: $firstDay, displayedComponents: .date)
                            Text("Exports \(planned.count) meals as private all-day events. Only meal names, meal slots and servings are included. This is a copy, not a live calendar connection. Check the dates before importing it into your calendar.")
                                .font(.caption).foregroundStyle(session.themeSecondaryText)
                            Button("Save .ics file") { exportCalendar() }
                                .disabled(planned.isEmpty || !HouseholdSync.shared.can(.backupExport))
                        }
                    }
                    if !message.isEmpty { Text(message).accessibilityAddTraits(.updatesFrequently) }
                }
                .padding(20).foregroundStyle(session.themeTextColor)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Plan tools").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Add \(reviewedCopies.count) meals to \(dayName(reviewedToDay))?", isPresented: $reviewCopies, titleVisibility: .visible) {
                Button("Add meals") { repeatDay() }
            }
            .fileExporter(isPresented: $exporting, document: exportDocument,
                          contentType: UTType(filenameExtension: "ics") ?? .plainText,
                          defaultFilename: "Stocked-meal-plan.ics") { result in
                switch result {
                case .success: message = "Calendar file saved."
                case .failure: message = "The calendar file wasn't saved. You can try again."
                }
            }
        }.tint(session.accentColor)
    }

    private func dayName(_ day: Int) -> String {
        if day == 0 { return "Today" }
        if day == 1 { return "Tomorrow" }
        let date = Calendar.current.date(byAdding: .day, value: day, to: Date()) ?? Date()
        return date.formatted(.dateTime.weekday(.wide))
    }

    private func repeatDay() {
        guard HouseholdSync.shared.can(.mealPlanEdit) else { message = "Your household role can't edit this plan."; return }
        guard reviewedFromDay == fromDay, reviewedToDay == toDay, reviewedCopies == copies else {
            message = "The plan changed while you were reviewing. Check the updated additions and review again."
            return
        }
        let additions = reviewedCopies.map { entry in var copy = entry; copy.id = UUID(); return copy }
        guard !additions.isEmpty, meals.count + additions.count <= 200 else { message = "No additions made. Choose another day or reduce the plan size."; return }
        meals += additions
        // Read the authoritative stamped values so undo won't remove a later household edit.
        addedMeals = session.guestStore.plannedMeals.filter { item in additions.contains { $0.id == item.id } }
        message = addedMeals.isEmpty ? "No meals were added. Your household role or plan may have changed."
            : "Added \(addedMeals.count) meals. They'll sync with your household."
    }

    private func undo() {
        guard HouseholdSync.shared.can(.mealPlanEdit) else { message = "Your household role can't edit this plan."; return }
        let unchangedIDs = Set(addedMeals.filter { entry in meals.contains(entry) }.map(\.id))
        meals.removeAll { unchangedIDs.contains($0.id) }
        message = "Removed \(unchangedIDs.count) unchanged additions. Any meals edited since then were kept."
        addedMeals = []
    }

    private func exportCalendar() {
        guard HouseholdSync.shared.can(.backupExport) else { message = "Your household role can't export this plan."; return }
        do {
            let entries = planned.map { MealPlanExchange.Entry(id: $0.id, day: $0.dayIndex, title: $0.title, mealType: $0.mealType, servings: $0.servings) }
            exportDocument = MealCalendarDocument(text: try MealPlanExchange.calendar(entries, starting: firstDay))
            exporting = true
        } catch { message = error.localizedDescription }
    }
}
