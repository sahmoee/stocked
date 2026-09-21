// ThawPlanner.swift — Feature 5: freezer awareness + "take it out tonight".
//
// Frozen food fails in one specific way: you remember it at 6pm when it needs 12 hours. This reads
// what's actually in the freezer, works out thaw time by weight and method, matches it against
// tomorrow's planned meals, and can schedule the reminder at the moment it needs to come out.

import SwiftUI
import UserNotifications

// MARK: - Thaw math (pure)

nonisolated enum ThawMethod: String, CaseIterable, Sendable {
    case fridge = "Fridge"
    case coldWater = "Cold water"
    case microwave = "Microwave"

    var guidance: String {
        switch self {
        case .fridge:    return "Safest. Plan ahead — roughly 5 hours per pound."
        case .coldWater: return "Faster, but change the water every 30 min and cook immediately."
        case .microwave: return "Fastest, but cook it right away — edges begin to cook."
        }
    }
}

nonisolated struct ThawEstimate: Sendable {
    let hours: Double
    let method: ThawMethod
    /// When to take it out so it's ready at `readyBy`.
    let takeOutAt: Date

    var readable: String {
        if hours < 1 { return "\(Int(hours * 60)) min" }
        if hours < 24 { return "\(String(format: hours == hours.rounded() ? "%.0f" : "%.1f", hours)) hr" }
        return "\(String(format: "%.1f", hours / 24)) days"
    }
}

nonisolated enum ThawCalculator {
    /// Hours to thaw, by method and weight. Conservative on purpose — under-thawed is a ruined dinner,
    /// over-thawed in the fridge is fine.
    static func hours(pounds: Double, method: ThawMethod) -> Double {
        let lb = max(0.25, pounds)
        switch method {
        case .fridge:    return max(4, lb * 5)          // ~5 hr/lb, min 4
        case .coldWater: return max(0.5, lb * 0.5)      // ~30 min/lb
        case .microwave: return max(0.1, lb * 0.1)      // ~6 min/lb
        }
    }

    static func estimate(pounds: Double, method: ThawMethod, readyBy: Date) -> ThawEstimate {
        let h = hours(pounds: pounds, method: method)
        let takeOut = readyBy.addingTimeInterval(-h * 3600)
        return ThawEstimate(hours: h, method: method, takeOutAt: takeOut)
    }

    /// Best-guess weight for an item, from its size fields when present, else a sensible default.
    static func pounds(for item: LocalInventoryItem) -> Double {
        if let amount = item.sizeAmount, let unit = item.sizeUnit?.lowercased() {
            if unit.contains("lb") || unit.contains("pound") { return amount }
            if unit.contains("oz") { return amount / 16 }
            if unit.contains("kg") { return amount * 2.205 }
            if unit.contains("g") { return amount / 453.6 }
        }
        return 1.0
    }
}

// MARK: - Planner

@MainActor
struct ThawPlan: Identifiable {
    let id = UUID()
    let item: LocalInventoryItem
    let estimate: ThawEstimate
    let forMeal: String?
}

// MARK: - UI

struct ThawPlannerView: View {
    @Environment(AppSession.self) private var session
    @State private var method: ThawMethod = .fridge
    @State private var dinnerHour = 18
    @State private var scheduled: Set<UUID> = []

    /// Everything currently in the freezer.
    /// Improvement #9 — reads the prebuilt zone index instead of filtering the whole pantry on
    /// every render pass.
    private var frozen: [LocalInventoryItem] {
        InventoryIndex.shared.items(in: .freezer)
    }
    /// Tomorrow's planned meals (dayIndex 1), used to label why something should come out.
    private var tomorrowMeals: [PlannedMeal] {
        session.guestStore.plannedMeals.filter { $0.dayIndex == 1 && !$0.isCooked }
    }
    private var readyBy: Date {
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) ?? Date()
        return cal.date(bySettingHour: dinnerHour, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    private var plans: [ThawPlan] {
        frozen.map { item in
            let est = ThawCalculator.estimate(pounds: ThawCalculator.pounds(for: item), method: method, readyBy: readyBy)
            let meal = tomorrowMeals.first { m in
                m.ingredients.contains { $0.lowercased().contains(item.name.lowercased()) }
                || m.title.lowercased().contains(item.name.lowercased())
            }
            return ThawPlan(item: item, estimate: est, forMeal: meal?.title)
        }
        .sorted { $0.estimate.takeOutAt < $1.estimate.takeOutAt }
    }

    var body: some View {
        Group {
            if frozen.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "snowflake").scaledFont(34)
                        .foregroundStyle(session.themeTextColor.opacity(0.25))
                    Text("Nothing in the freezer").scaledFont(16, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                    Text("Items stored in the Freezer zone show up here with thaw timing.")
                        .scaledFont(13).multilineTextAlignment(.center)
                        .foregroundStyle(session.themeTextColor.opacity(0.55)).padding(.horizontal, 40)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    Section {
                        Picker("Method", selection: $method) {
                            ForEach(ThawMethod.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }.pickerStyle(.segmented)
                        Stepper("Eating around \(dinnerHour):00 tomorrow", value: $dinnerHour, in: 6...23)
                        Text(method.guidance).font(.stocked(.footnote)).foregroundStyle(.secondary)
                    }

                    Section("Take out") {
                        ForEach(plans) { plan in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack {
                                    Text(plan.item.name).scaledFont(15, weight: .semibold)
                                        .foregroundStyle(session.themeTextColor)
                                    Spacer()
                                    Text(plan.estimate.readable).scaledFont(12, weight: .bold)
                                        .foregroundStyle(session.accentColor)
                                }
                                if let meal = plan.forMeal {
                                    Text("for \(meal)").scaledFont(12)
                                        .foregroundStyle(session.themeTextColor.opacity(0.6))
                                }
                                Text("Take out \(takeOutLabel(plan.estimate.takeOutAt))")
                                    .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.55))
                                Button {
                                    schedule(plan)
                                } label: {
                                    HStack(spacing: 5) {
                                        Image(systemName: scheduled.contains(plan.id) ? "bell.fill" : "bell")
                                        Text(scheduled.contains(plan.id) ? "Reminder set" : "Remind me")
                                    }
                                    .scaledFont(11, weight: .semibold)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(scheduled.contains(plan.id) ? Color.green.opacity(0.15) : session.themeTextColor.opacity(0.07))
                                    .foregroundStyle(scheduled.contains(plan.id) ? .green : session.themeTextColor.opacity(0.8))
                                    .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(scheduled.contains(plan.id))
                            }
                            .padding(.vertical, 3)
                        }
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .stockedScreen()
        .navigationTitle("Thaw Planner")
        .navigationBarTitleDisplayMode(.inline)
        .withInventoryIndex(session.guestStore)
    }

    private func takeOutLabel(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "EEE h:mm a"
        return date < Date() ? "now — it's already tight" : f.string(from: date)
    }

    private func schedule(_ plan: ThawPlan) {
        HapticManager.light()
        let content = UNMutableNotificationContent()
        content.title = "Take out \(plan.item.name)"
        content.body = plan.forMeal.map { "For \($0) tomorrow — needs \(plan.estimate.readable) to thaw." }
            ?? "Needs \(plan.estimate.readable) to thaw in the \(plan.estimate.method.rawValue.lowercased())."
        content.sound = .default

        let fire = max(plan.estimate.takeOutAt, Date().addingTimeInterval(60))
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let request = UNNotificationRequest(identifier: "thaw-\(plan.id.uuidString)",
                                            content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: comps, repeats: false))
        UNUserNotificationCenter.current().add(request) { _ in }
        scheduled.insert(plan.id)
    }
}
