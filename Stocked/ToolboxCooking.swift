// ToolboxCooking.swift — Cooking tools for the Kitchen Toolbox.
// Recipe Roulette • Kitchen Timers • Unit Converter • Leftover Ideas
import SwiftUI
@preconcurrency import UserNotifications
import Combine

// MARK: - Recipe Roulette

struct RecipeRouletteView: View {
    @Environment(AppSession.self) private var session
    @State private var cuisineFilter = "Any"
    @State private var favoritesOnly = false
    @State private var result: UserRecipe? = nil
    @State private var spinning = false
    @State private var cyclingTitle = ""
    @State private var spinTask: Task<Void, Never>? = nil

    private var cuisines: [String] {
        var set = Set<String>()
        for r in session.guestStore.userRecipes where !r.cuisine.trimmingCharacters(in: .whitespaces).isEmpty {
            set.insert(r.cuisine)
        }
        return ["Any"] + set.sorted()
    }

    private var pool: [UserRecipe] {
        session.guestStore.userRecipes.filter { recipe in
            (cuisineFilter == "Any" || recipe.cuisine == cuisineFilter)
            && (!favoritesOnly || recipe.isFavorited)
        }
    }

    private func spin() {
        let candidates = pool
        guard !candidates.isEmpty else {
            ToastCenter.shared.info("No recipes match those filters")
            return
        }
        HapticManager.medium()
        spinTask?.cancel()
        // Respect Reduce Motion (UI/UX): skip the cycling animation entirely.
        if UIAccessibility.isReduceMotionEnabled || candidates.count == 1 {
            result = candidates.randomElement()
            HapticManager.success()
            return
        }
        spinning = true
        result = nil
        spinTask = Task { @MainActor in
            for step in 0..<12 {
                guard !Task.isCancelled else { return }
                cyclingTitle = candidates.randomElement()?.title ?? ""
                // Ease out: ticks get slower toward the end.
                try? await Task.sleep(nanoseconds: UInt64(60_000_000 + step * 22_000_000))
            }
            guard !Task.isCancelled else { return }
            spinning = false
            result = candidates.randomElement()
            HapticManager.success()
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if session.guestStore.userRecipes.isEmpty {
                    ToolboxEmptyState(icon: "dice",
                                      title: "No recipes to spin",
                                      message: "Save a few recipes first, then let the roulette pick dinner for you.")
                } else {
                    ToolboxCard {
                        VStack(alignment: .leading, spacing: 12) {
                            if cuisines.count > 1 {
                                HStack {
                                    Text("Cuisine")
                                        .scaledFont(14, weight: .medium)
                                        .foregroundStyle(session.themeSecondaryText)
                                    Spacer()
                                    Picker("Cuisine", selection: $cuisineFilter) {
                                        ForEach(cuisines, id: \.self) { Text($0) }
                                    }
                                    .tint(session.accentColor)
                                }
                            }
                            Toggle(isOn: $favoritesOnly) {
                                Text("Favorites only")
                                    .scaledFont(14, weight: .medium)
                                    .foregroundStyle(session.themeSecondaryText)
                            }
                            .tint(session.accentColor)
                            Text("\(pool.count) recipe\(pool.count == 1 ? "" : "s") in the pool")
                                .scaledFont(12)
                                .foregroundStyle(session.themeSecondaryText)
                        }
                    }

                    // Result / spinner card
                    ZStack {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(session.accentColor.opacity(session.isDarkMode ? 0.16 : 0.10))
                        if spinning {
                            Text(cyclingTitle)
                                .scaledFont(18, weight: .bold, design: .serif)
                                .foregroundStyle(session.themeSecondaryText)
                                .padding(20)
                                .transition(.opacity)
                        } else if let recipe = result {
                            VStack(spacing: 8) {
                                Text("Tonight, make")
                                    .scaledFont(12, weight: .semibold)
                                    .foregroundStyle(session.themeSecondaryText)
                                Text(recipe.title)
                                    .scaledFont(21, weight: .bold, design: .serif)
                                    .foregroundStyle(session.themeTextColor)
                                    .multilineTextAlignment(.center)
                                HStack(spacing: 10) {
                                    if !recipe.cuisine.isEmpty {
                                        Text(recipe.cuisine)
                                            .scaledFont(11, weight: .semibold)
                                            .padding(.horizontal, 8).padding(.vertical, 3)
                                            .background(Capsule().fill(session.accentColor.opacity(0.18)))
                                            .foregroundStyle(session.accentColor)
                                    }
                                    if !recipe.cookTime.isEmpty {
                                        Label(recipe.cookTime, systemImage: "clock")
                                            .scaledFont(11, weight: .medium)
                                            .foregroundStyle(session.themeSecondaryText)
                                    }
                                }
                            }
                            .padding(20)
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "dice")
                                    .scaledFont(30, weight: .light)
                                Text("Spin to pick dinner")
                                    .scaledFont(14, weight: .medium)
                            }
                            .foregroundStyle(session.themeSecondaryText)
                        }
                    }
                    .frame(minHeight: 140)
                    .animation(UIAccessibility.isReduceMotionEnabled ? nil : .easeInOut(duration: 0.15), value: cyclingTitle)

                    Button { spin() } label: {
                        Label(result == nil ? "Spin" : "Spin again", systemImage: "arrow.triangle.2.circlepath")
                            .scaledFont(16, weight: .bold)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 14).fill(session.accentColor))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    .disabled(spinning)
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Recipe Roulette")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { spinTask?.cancel() }
    }
}

// MARK: - Kitchen Timers

private struct KitchenToolboxTimer: Identifiable, Equatable {
    let id = UUID()
    var label: String
    var endDate: Date
    var totalSeconds: Int
    var notificationID: String { "toolbox.timer.\(id.uuidString)" }
}

struct MultiTimerView: View {
    @Environment(AppSession.self) private var session
    @State private var timers: [KitchenToolboxTimer] = []
    @State private var now = Date()
    @State private var newLabel = ""
    @State private var minutes = 10
    // One shared clock drives every row (perf) instead of a Timer per row.
    private let clock = Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()

    private func start() {
        guard timers.count < 4 else {
            ToastCenter.shared.info("Four timers is the limit — clear one first")
            return
        }
        let label = newLabel.trimmingCharacters(in: .whitespaces)
        let timer = KitchenToolboxTimer(
            label: label.isEmpty ? "Timer \(timers.count + 1)" : label,
            endDate: Date().addingTimeInterval(Double(minutes * 60)),
            totalSeconds: minutes * 60)
        timers.append(timer)
        newLabel = ""
        HapticManager.success()
        // Local notification so the timer still fires if the app is backgrounded.
        // Cancelled by ITS OWN identifier only — never removeAllPendingNotificationRequests.
        let content = UNMutableNotificationContent()
        content.title = "⏰ \(timer.label) is done"
        content.body = "Your \(minutes)-minute kitchen timer just finished."
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Double(minutes * 60), repeats: false)
        let request = UNNotificationRequest(identifier: timer.notificationID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request, withCompletionHandler: nil)
    }

    private func cancel(_ timer: KitchenToolboxTimer) {
        timers.removeAll { $0.id == timer.id }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [timer.notificationID])
        HapticManager.light()
    }

    private func remaining(_ timer: KitchenToolboxTimer) -> Int {
        max(0, Int(timer.endDate.timeIntervalSince(now).rounded()))
    }

    private func format(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 12) {
                        TextField("Label (e.g. Pasta)", text: $newLabel)
                            .scaledFont(15)
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(session.themeBgColor))
                        HStack {
                            Stepper(value: $minutes, in: 1...180) {
                                Text("\(minutes) min")
                                    .scaledFont(15, weight: .semibold, design: .rounded)
                                    .foregroundStyle(session.themeTextColor)
                            }
                            .onChange(of: minutes) { _, _ in HapticManager.select() }
                        }
                        Button { start() } label: {
                            Label("Start timer", systemImage: "play.fill")
                                .scaledFont(15, weight: .semibold)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 11)
                                .background(RoundedRectangle(cornerRadius: 12).fill(session.accentColor))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if timers.isEmpty {
                    ToolboxEmptyState(icon: "timer",
                                      title: "No timers running",
                                      message: "Run up to four at once — pasta, sauce, oven, and a rest timer. You'll get a notification when each finishes.")
                } else {
                    ForEach(timers) { timer in
                        let left = remaining(timer)
                        ToolboxCard {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .stroke(session.themeBgColor, lineWidth: 4)
                                    Circle()
                                        .trim(from: 0, to: timer.totalSeconds > 0
                                              ? CGFloat(left) / CGFloat(timer.totalSeconds) : 0)
                                        .stroke(left == 0 ? Color.green : session.accentColor,
                                                style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                        .rotationEffect(.degrees(-90))
                                }
                                .frame(width: 40, height: 40)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(timer.label)
                                        .scaledFont(14, weight: .semibold)
                                        .foregroundStyle(session.themeTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(left == 0 ? "Done!" : format(left))
                                        .scaledFont(17, weight: .bold, design: .monospaced)
                                        .foregroundStyle(left == 0 ? .green : session.accentColor)
                                        .accessibilityLabel(left == 0 ? "\(timer.label) done" : "\(timer.label), \(left / 60) minutes \(left % 60) seconds left")
                                }
                                Spacer()
                                Button { cancel(timer) } label: {
                                    Image(systemName: left == 0 ? "checkmark.circle.fill" : "xmark.circle.fill")
                                        .scaledFont(22)
                                        .foregroundStyle(left == 0 ? .green : session.themeSecondaryText.opacity(0.5))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(left == 0 ? "Dismiss timer" : "Cancel timer")
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Kitchen Timers")
        .navigationBarTitleDisplayMode(.inline)
        .onReceive(clock) { now = $0 }
    }
}

// MARK: - Unit Converter

struct MeasurementConverterView: View {
    @Environment(AppSession.self) private var session
    @State private var amountText = "1"
    @State private var unit = "cup"
    @State private var ingredient = ""
    @State private var targetSystem: UnitSystem = .metric
    @State private var showCupsToGrams = false

    private static let units = ["tsp", "tbsp", "cup", "fl oz", "ml", "L", "oz", "lb", "g", "kg"]

    private var amount: Double { Double(amountText.trimmingCharacters(in: .whitespaces)) ?? 0 }

    private var conversion: (value: Double, unit: String) {
        UnitConverter.convert(amount: amount, unit: unit,
                              ingredient: ingredient.isEmpty ? "water" : ingredient,
                              to: targetSystem)
    }

    private var cupsToGramsResult: Double? {
        guard showCupsToGrams, unit == "cup", !ingredient.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return UnitConverter.cupsToGrams(amount, ingredient: ingredient)
    }

    private func pretty(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                ToolboxCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 10) {
                            TextField("Amount", text: $amountText)
                                .keyboardType(.decimalPad)
                                .scaledFont(16, weight: .semibold, design: .rounded)
                                .padding(10)
                                .frame(width: 100)
                                .background(RoundedRectangle(cornerRadius: 10).fill(session.themeBgColor))
                            Picker("Unit", selection: $unit) {
                                ForEach(Self.units, id: \.self) { Text($0) }
                            }
                            .tint(session.accentColor)
                            Spacer()
                        }
                        HStack {
                            Text("Convert to")
                                .scaledFont(14, weight: .medium)
                                .foregroundStyle(session.themeSecondaryText)
                            Spacer()
                            Picker("System", selection: $targetSystem) {
                                ForEach(UnitSystem.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 160)
                        }
                        Toggle(isOn: $showCupsToGrams) {
                            Text("Cups → grams (needs an ingredient)")
                                .scaledFont(13, weight: .medium)
                                .foregroundStyle(session.themeSecondaryText)
                        }
                        .tint(session.accentColor)
                        if showCupsToGrams {
                            TextField("Ingredient (e.g. flour, sugar, butter)", text: $ingredient)
                                .scaledFont(15)
                                .padding(10)
                                .background(RoundedRectangle(cornerRadius: 10).fill(session.themeBgColor))
                        }
                    }
                }
                // Result
                ToolboxCard {
                    VStack(spacing: 6) {
                        Text("\(pretty(amount)) \(unit) =")
                            .scaledFont(13, weight: .medium)
                            .foregroundStyle(session.themeSecondaryText)
                        Text("\(pretty(conversion.value)) \(conversion.unit)")
                            .scaledFont(26, weight: .bold, design: .rounded)
                            .foregroundStyle(session.accentColor)
                        if let grams = cupsToGramsResult {
                            Divider().padding(.vertical, 2)
                            Text("≈ \(pretty(grams)) g of \(ingredient.trimmingCharacters(in: .whitespaces))")
                                .scaledFont(15, weight: .semibold, design: .rounded)
                                .foregroundStyle(session.themeTextColor)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                }
                Text("Cup-to-gram estimates appear only for ingredients with a known density. If a weight is missing, use a kitchen scale; your original measurement stays unchanged.")
                    .scaledFont(12)
                    .foregroundStyle(session.themeSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Unit Converter")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Leftover Ideas

struct LeftoverIdeasView: View {
    @Environment(AppSession.self) private var session

    private static let ideaRules: [(keywords: [String], ideas: [String])] = [
        (["rice"],                  ["Fried rice with whatever vegetables you have", "Rice pudding with milk and cinnamon", "Stuffed peppers"]),
        (["chicken", "turkey"],     ["Chicken salad sandwiches", "Quick chicken quesadillas", "Chicken noodle soup", "Chicken fried rice"]),
        (["beef", "steak"],         ["Steak tacos with quick-pickled onions", "Beef and vegetable stir fry", "Steak and eggs breakfast"]),
        (["pasta", "spaghetti", "noodle"], ["Pasta frittata — crisp it in a pan with eggs", "Cold pasta salad with a vinaigrette", "Baked pasta with cheese on top"]),
        (["pork"],                  ["Pork fried rice", "Pulled-pork style sandwiches", "Pork ramen bowls"]),
        (["potato", "mashed"],      ["Potato pancakes or croquettes", "Shepherd's-pie style bake", "Breakfast hash with a fried egg"]),
        (["fish", "salmon", "tuna"],["Fish cakes with a lemon mayo", "Fish tacos with slaw", "Flake into a grain bowl"]),
        (["vegetable", "veggie", "broccoli", "carrot", "pepper"], ["Blend into a quick soup", "Vegetable fried rice", "Fold into an omelet or frittata"]),
        (["soup", "stew", "chili"], ["Serve over rice or baked potatoes", "Use as a pasta sauce base", "Freeze in single portions for later"]),
        (["bread", "baguette"],     ["French toast", "Homemade croutons or breadcrumbs", "Panzanella (bread salad)"]),
        (["pizza"],                 ["Reheat in a skillet for a crispy base", "Chop into a breakfast scramble"]),
        (["bean", "lentil"],        ["Mash into a quick bean dip", "Add to quesadillas or tacos", "Stir into soups for body"]),
    ]

    private static let genericIdeas = [
        "Fried rice takes almost any leftover protein or vegetable",
        "Frittatas and omelets are leftover magnets",
        "Quesadillas: cheese plus almost anything works",
        "Grain bowls: rice or quinoa base, leftovers on top, sauce over",
        "Soup it: sauté onion and garlic, add leftovers and broth",
    ]

    private func ideas(for item: LocalInventoryItem) -> [String] {
        let haystack = (item.name + " " + (item.leftoverMeal ?? "")).lowercased()
        for rule in Self.ideaRules where rule.keywords.contains(where: { haystack.contains($0) }) {
            return rule.ideas
        }
        return Array(Self.genericIdeas.shuffled().prefix(3))
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                let leftovers = session.guestStore.inventoryItems.filter { $0.isLeftover }
                if leftovers.isEmpty {
                    ToolboxEmptyState(icon: "takeoutbag.and.cup.and.straw",
                                      title: "No leftovers tracked",
                                      message: "Mark items as leftovers in your inventory and this screen will suggest ways to turn them into new meals.")
                    ToolboxSectionLabel(text: "Universal leftover moves")
                    ForEach(Self.genericIdeas, id: \.self) { idea in
                        ToolboxCard {
                            Label(idea, systemImage: "lightbulb")
                                .scaledFont(13, weight: .medium)
                                .foregroundStyle(session.themeTextColor)
                        }
                    }
                } else {
                    ForEach(leftovers) { item in
                        ToolboxCard {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Text(item.name)
                                        .scaledFont(15, weight: .semibold)
                                        .foregroundStyle(session.themeTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Spacer()
                                    if let days = item.daysUntilExpiry {
                                        ExpiryUrgencyChip(daysLeft: days)
                                    }
                                }
                                ForEach(ideas(for: item), id: \.self) { idea in
                                    Label(idea, systemImage: "lightbulb")
                                        .scaledFont(13)
                                        .foregroundStyle(session.themeSecondaryText)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 8)
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .navigationTitle("Leftover Ideas")
        .navigationBarTitleDisplayMode(.inline)
    }
}
