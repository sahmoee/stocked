// MultiRecipeTimeline.swift — Feature 11: cook 2+ dishes so everything finishes together.
//
// The hardest part of a real meal isn't any single recipe — it's that the potatoes finish 20 minutes
// before the chicken. This reads durations out of step text, schedules every step BACKWARD from one
// target serve time, and interleaves them into a single ordered timeline.
//
// Pure logic in `TimelinePlanner` (deterministic, unit-testable); the view is a thin shell.

import SwiftUI

// MARK: - Model

nonisolated struct TimelineRecipe: Identifiable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var steps: [String]
}

nonisolated struct TimelineStep: Identifiable, Hashable, Sendable {
    var id = UUID()
    var recipe: String
    var text: String
    var minutes: Int          // duration this step occupies
    var startOffset: Int      // minutes BEFORE serve time that this step begins
    var isPassive: Bool       // baking/simmering — you're free during it

    var startsAtLabel: String { startOffset <= 0 ? "at serve" : "T‑\(startOffset)m" }
}

// MARK: - Planner (pure)

nonisolated enum TimelinePlanner {

    /// Pull a duration out of step text: "bake for 25 minutes", "simmer 1 hour", "rest 10 min".
    static func minutes(in step: String) -> Int {
        let s = step.lowercased()
        var total = 0
        // hours
        if let m = s.range(of: #"(\d+(?:\.\d+)?)\s*(hours?|hrs?)"#, options: .regularExpression) {
            let num = s[m].prefix(while: { $0.isNumber || $0 == "." })
            total += Int((Double(num) ?? 0) * 60)
        }
        // minutes
        if let m = s.range(of: #"(\d+)\s*(minutes?|mins?|m\b)"#, options: .regularExpression) {
            let num = s[m].prefix(while: { $0.isNumber })
            total += Int(num) ?? 0
        }
        if total > 0 { return total }
        // No explicit time — assume a short active step.
        return 5
    }

    /// Passive steps free you up to work on another dish.
    static func isPassive(_ step: String) -> Bool {
        let s = step.lowercased()
        return ["bake", "simmer", "roast", "rest", "marinate", "chill", "refrigerate", "boil",
                "braise", "proof", "rise", "cool", "steep", "slow cook"].contains { s.contains($0) }
    }

    /// Build one merged timeline. Each recipe is scheduled backward from serve time, then all steps
    /// are ordered by when they must start (earliest first).
    static func plan(_ recipes: [TimelineRecipe]) -> [TimelineStep] {
        var out: [TimelineStep] = []
        for r in recipes {
            // Walk this recipe's steps in reverse, accumulating offset from the end.
            var offset = 0
            var built: [TimelineStep] = []
            for step in r.steps.reversed() {
                let mins = minutes(in: step)
                offset += mins
                built.append(TimelineStep(recipe: r.title, text: step, minutes: mins,
                                          startOffset: offset, isPassive: isPassive(step)))
            }
            out.append(contentsOf: built)
        }
        // Earliest start first; ties broken so passive (start-and-walk-away) work goes first.
        return out.sorted {
            $0.startOffset != $1.startOffset ? $0.startOffset > $1.startOffset
                                             : ($0.isPassive && !$1.isPassive)
        }
    }

    /// Total wall-clock minutes the whole meal needs.
    static func totalMinutes(_ recipes: [TimelineRecipe]) -> Int {
        plan(recipes).map(\.startOffset).max() ?? 0
    }

    /// Clock time each step begins, given when you want to eat.
    static func clockTime(for step: TimelineStep, serveAt: Date) -> Date {
        serveAt.addingTimeInterval(-Double(step.startOffset) * 60)
    }
}

// MARK: - UI

struct MultiRecipeTimelineView: View {
    @Environment(AppSession.self) private var session
    @State private var recipes: [TimelineRecipe] = []
    @State private var serveAt = Calendar.current.date(bySettingHour: 18, minute: 30, second: 0, of: Date()) ?? Date()
    @State private var showAdd = false

    private var steps: [TimelineStep] { TimelinePlanner.plan(recipes) }
    private var total: Int { TimelinePlanner.totalMinutes(recipes) }

    var body: some View {
        Group {
            if recipes.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "timeline.selection")
                        .font(.system(size: 34)).foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text("Cook several dishes at once")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(session.themeTextColor)
                    Text("Add two or more dishes and Stocked works backward from when you want to eat, so everything lands at the same time.")
                        .font(.system(size: 13)).multilineTextAlignment(.center)
                        .foregroundStyle(session.themeTextColor.opacity(0.55)).padding(.horizontal, 40)
                    Button { showAdd = true } label: {
                        Text("Add a dish").font(.system(size: 14, weight: .semibold))
                            .padding(.horizontal, 20).padding(.vertical, 10)
                            .background(session.accentColor).foregroundStyle(.white).clipShape(Capsule())
                    }.buttonStyle(.plain).padding(.top, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        DatePicker("Eat at", selection: $serveAt, displayedComponents: .hourAndMinute)
                        HStack {
                            Text("Start cooking")
                            Spacer()
                            Text(startLabel).font(.system(size: 15, weight: .bold)).foregroundStyle(session.accentColor)
                        }
                        Text("\(recipes.count) dishes · about \(total) minutes total")
                            .font(.footnote).foregroundStyle(.secondary)
                    }

                    Section("Timeline") {
                        ForEach(steps) { s in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(spacing: 2) {
                                    Text(timeLabel(s)).font(.system(size: 12, weight: .bold, design: .monospaced))
                                        .foregroundStyle(session.accentColor)
                                    if s.isPassive {
                                        Image(systemName: "hourglass").font(.system(size: 9))
                                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                                    }
                                }
                                .frame(width: 58, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.recipe).font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                                    Text(s.text).font(.system(size: 13))
                                        .foregroundStyle(session.themeTextColor)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }

                    Section {
                        ForEach(recipes) { r in Text(r.title) }
                            .onDelete { idx in recipes.remove(atOffsets: idx) }
                    } header: { Text("Dishes") }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .stockedScreen()
        .navigationTitle("Cook Together")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { showAdd = true } label: { Image(systemName: "plus") } } }
        .sheet(isPresented: $showAdd) { AddTimelineDishSheet { recipes.append($0) } }
    }

    private var startLabel: String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: serveAt.addingTimeInterval(-Double(total) * 60))
    }
    private func timeLabel(_ s: TimelineStep) -> String {
        let f = DateFormatter(); f.timeStyle = .short
        return f.string(from: TimelinePlanner.clockTime(for: s, serveAt: serveAt))
    }
}

private struct AddTimelineDishSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    let onAdd: (TimelineRecipe) -> Void
    @State private var title = ""
    @State private var stepsText = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Dish name", text: $title)
                Section {
                    TextField("One step per line", text: $stepsText, axis: .vertical).lineLimit(4...14)
                } header: { Text("Steps") } footer: {
                    Text("Durations are read from the text — \"bake 25 minutes\", \"simmer 1 hour\". Steps without a time are treated as 5 minutes of active work.")
                }
                if !session.guestStore.plannedMeals.isEmpty {
                    Section("Or use a planned meal") {
                        ForEach(session.guestStore.plannedMeals.filter { !$0.isCooked }, id: \.id) { m in
                            Button(m.title) { title = m.title }
                        }
                    }
                }
            }
            .navigationTitle("Add a dish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        let steps = stepsText.split(separator: "\n")
                            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        onAdd(TimelineRecipe(title: title.trimmingCharacters(in: .whitespaces),
                                             steps: steps.isEmpty ? ["Cook"] : steps))
                        dismiss()
                    }
                    .font(.body.bold())
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
    }
}
