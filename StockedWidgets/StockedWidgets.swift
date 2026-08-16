// StockedWidgets.swift — WIDGET EXTENSION TARGET ONLY.
// Home Screen (#13: small + medium) and Lock Screen (#14: circular / inline / rectangular)
// widgets showing kitchen status from the App Group snapshot. Self-contained colors so it
// doesn't depend on the app's Color extensions.
import WidgetKit
import SwiftUI

// MARK: - Brand colors (kept local to the widget target)
private extension Color {
    static let wGold     = Color(red: 0.635, green: 0.447, blue: 0.098) // #A27219
    static let wGreen    = Color(red: 0.118, green: 0.502, blue: 0.196) // #1E8032
    static let wBg       = Color(red: 0.780, green: 0.671, blue: 0.506) // #C7AB81
    static let wCharcoal = Color(red: 0.176, green: 0.173, blue: 0.165) // #2D2C2A
}

private func stockTint(_ pct: Int) -> Color {
    pct >= 66 ? .wGreen : (pct >= 33 ? .wGold : .red)
}

// MARK: - Timeline
struct StockedEntry: TimelineEntry {
    let date: Date
    let snapshot: StockedWidgetSnapshot
}

struct StockedProvider: TimelineProvider {
    func placeholder(in context: Context) -> StockedEntry {
        StockedEntry(date: Date(), snapshot: .empty)
    }
    func getSnapshot(in context: Context, completion: @escaping (StockedEntry) -> Void) {
        completion(StockedEntry(date: Date(), snapshot: context.isPreview ? .preview : WidgetStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StockedEntry>) -> Void) {
        let entry = StockedEntry(date: Date(), snapshot: WidgetStore.load())
        // App writes trigger immediate reloads; this backstop also recovers from stale/empty data.
        let interval: TimeInterval = entry.snapshot.isEmpty ? 15 * 60 : (entry.snapshot.isStale ? 20 * 60 : 60 * 60)
        let next = Date().addingTimeInterval(interval)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - Views
struct StockedWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StockedEntry
    private var s: StockedWidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .systemSmall:        small
        case .systemMedium:       medium
        case .systemLarge:        large
        case .accessoryCircular:  circular
        case .accessoryInline:    inline
        case .accessoryRectangular: rectangular
        default:                  small
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Kitchen dashboard", systemImage: "refrigerator.fill")
                    .font(.system(.headline, design: .rounded, weight: .bold))
                Spacer()
                if s.isStale { Label("Open to refresh", systemImage: "arrow.clockwise").font(.caption2).foregroundStyle(.secondary) }
            }
            HStack(spacing: 12) {
                metric("\(s.stockPercent)%", "stocked", "chart.bar.fill", stockTint(s.stockPercent))
                metric("\(s.expiringCount)", "use soon", "clock.badge.exclamationmark", .orange)
                metric("\(s.groceryCount)", "to buy", "cart.fill", .wGold)
            }
            Divider()
            if let meal = s.todayMeal, !meal.isEmpty {
                row("fork.knife", .wGreen, s.todayMealType ?? "Today's meal", meal)
            }
            if !s.expiringNames.isEmpty {
                row("clock.badge.exclamationmark", .orange, "Use next", s.expiringNames.prefix(4).joined(separator: " • "))
            }
            if let names = s.lowStockNames, !names.isEmpty {
                row("chart.bar.fill", .wGold, "Running low", names.prefix(4).joined(separator: " • "))
            }
            Spacer(minLength: 0)
            Text("Updated \(s.updatedAt, style: .relative)").font(.caption2).foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: "stocked://home"))
    }

    private func metric(_ value: String, _ label: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(value).font(.system(.title2, design: .rounded, weight: .bold)).contentTransition(.numericText())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    // Home Screen — small: stock ring + headline alert.
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "refrigerator.fill").font(.system(size: 13)).foregroundStyle(Color.wGold)
                Text("Stocked.").font(.system(size: 14, weight: .bold, design: .serif)).foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
            Text("\(s.stockPercent)%")
                .font(.system(size: 40, weight: .heavy, design: .serif))
                .foregroundStyle(stockTint(s.stockPercent))
            Text("stocked").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if s.expiringCount > 0 {
                Label("\(s.expiringCount) expiring", systemImage: "clock.badge.exclamationmark")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(.orange).lineLimit(1)
            } else if s.lowStockCount > 0 {
                Label("\(s.lowStockCount) low", systemImage: "chart.bar.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.wGold).lineLimit(1)
            } else {
                Label("All good", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.wGreen).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "stocked://inventory"))   // #13 tap → Inventory
    }

    // Home Screen — medium: status + what to act on + today's meal.
    private var medium: some View {
        HStack(spacing: 16) {
            VStack(spacing: 2) {
                Text("\(s.stockPercent)%")
                    .font(.system(size: 38, weight: .heavy, design: .serif))
                    .foregroundStyle(stockTint(s.stockPercent))
                Text("stocked").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(width: 92)
            .padding(.vertical, 10)
            .background(stockTint(s.stockPercent).opacity(0.12), in: RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 6) {
                if let meal = s.todayMeal, !meal.isEmpty {
                    row("fork.knife", Color.wGreen, "Tonight", meal)
                }
                if s.expiringCount > 0 {
                    row("clock.badge.exclamationmark", .orange,
                        "\(s.expiringCount) expiring",
                        s.expiringNames.isEmpty ? "Use them soon" : s.expiringNames.joined(separator: ", "))
                }
                if s.lowStockCount > 0 {
                    row("chart.bar.fill", Color.wGold, "\(s.lowStockCount) running low", "Time to restock")
                }
                if s.groceryCount > 0 {
                    row("cart.fill", Color.wGold, "\(s.groceryCount) on the list", "Grocery items to buy")
                }
                if s.todayMeal == nil && s.expiringCount == 0 && s.lowStockCount == 0 && s.groceryCount == 0 {
                    row("checkmark.circle.fill", Color.wGreen, "Kitchen looks great", "Nothing needs attention")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .widgetURL(URL(string: "stocked://home"))   // #13 tap → Home dashboard
    }

    private func row(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // Lock Screen — circular: stock gauge.
    private var circular: some View {
        Gauge(value: Double(s.stockPercent), in: 0...100) {
            Image(systemName: "refrigerator.fill")
        } currentValueLabel: {
            Text("\(s.stockPercent)")
        }
        .gaugeStyle(.accessoryCircular)
        .widgetURL(URL(string: "stocked://inventory"))   // #13 tap → Inventory
    }

    // Lock Screen — inline: one-line status.
    private var inline: some View {
        Group {
            if s.expiringCount > 0 {
                Label("\(s.expiringCount) expiring soon", systemImage: "clock.badge.exclamationmark")
            } else {
                Label("\(s.stockPercent)% stocked", systemImage: "refrigerator.fill")
            }
        }
        .widgetURL(URL(string: "stocked://inventory"))   // #13 tap → Inventory
    }

    // Lock Screen — rectangular: stock + next concern.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(s.stockPercent)% stocked").font(.system(size: 15, weight: .bold))
            if s.expiringCount > 0 {
                Text("\(s.expiringCount) expiring soon").font(.system(size: 12))
            } else if let meal = s.todayMeal, !meal.isEmpty {
                Text("Tonight: \(meal)").font(.system(size: 12)).lineLimit(1)
            } else if s.lowStockCount > 0 {
                Text("\(s.lowStockCount) running low").font(.system(size: 12))
            } else {
                Text("Kitchen looks great").font(.system(size: 12))
            }
        }
        .widgetURL(URL(string: "stocked://home"))   // #13 tap → Home dashboard
    }
}

// MARK: - Widget + Bundle
struct StockedStatusWidget: Widget {
    let kind = "StockedStatusWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StockedProvider()) { entry in
            StockedWidgetView(entry: entry)
                .containerBackground(Color.wBg.opacity(0.0), for: .widget)
        }
        .configurationDisplayName("Kitchen Status")
        .description("Your stock level, what's expiring, and tonight's meal.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge,
                            .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

// MARK: - Expiring Soon widget (improvement #1)

struct ExpiringSoonWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: StockedEntry
    var body: some View {
        let s = entry.snapshot
        if family == .accessoryCircular {
            Gauge(value: Double(min(s.expiringCount, 10)), in: 0...10) {
                Image(systemName: "clock")
            } currentValueLabel: { Text("\(s.expiringCount)").fontWeight(.bold) }
            .gaugeStyle(.accessoryCircular)
            .widgetURL(URL(string: "stocked://inventory"))
        } else if family == .accessoryInline {
            Label(s.expiringCount == 0 ? "Nothing expiring" : "\(s.expiringCount) to use soon", systemImage: "clock.badge.checkmark")
                .widgetURL(URL(string: "stocked://inventory"))
        } else {
          VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: "clock.badge.exclamationmark").font(.system(size: 12, weight: .semibold))
                Text("Use soon").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(s.expiringCount)").font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(.orange)
            }
            if s.expiringNames.isEmpty {
                Text(s.expiringCount == 0 ? "Nothing expiring" : "\(s.expiringCount) expiring")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                ForEach(s.expiringNames.prefix(family == .systemMedium ? 4 : 3), id: \.self) { n in
                    Label(n, systemImage: "circle.fill").font(.system(size: 12)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .widgetURL(URL(string: "stocked://inventory"))
        }
    }
}

struct ExpiringSoonWidget: Widget {
    let kind = "StockedExpiringWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StockedProvider()) { entry in
            ExpiringSoonWidgetView(entry: entry)
                .containerBackground(Color.wBg.opacity(0.0), for: .widget)
        }
        .configurationDisplayName("Expiring Soon")
        .description("The items you should use up next.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

// MARK: - Grocery widget (improvement #1)

struct GroceryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    var entry: StockedEntry
    var body: some View {
        let s = entry.snapshot
        if family == .accessoryInline {
            Label("\(s.groceryCount) on grocery list", systemImage: "cart.fill")
                .widgetURL(URL(string: "stocked://grocery"))
        } else if family == .accessoryCircular {
          VStack(spacing: 0) {
            Image(systemName: "cart.fill")
            Text("\(s.groceryCount)").font(.headline)
          }.widgetURL(URL(string: "stocked://grocery"))
        } else {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Grocery list", systemImage: "cart.fill").font(.system(size: 13, weight: .bold))
                Spacer()
                Text("\(s.groceryCount)").font(.system(.headline, design: .rounded, weight: .bold)).foregroundStyle(Color.wGold)
            }
            if let names = s.groceryNames, !names.isEmpty {
                ForEach(names.prefix(family == .systemMedium ? 4 : 3), id: \.self) { name in
                    Label(name, systemImage: "circle").font(.system(size: 12)).lineLimit(1)
                }
            } else {
                Spacer(minLength: 0)
                Label("List is clear", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Color.wGreen)
            }
            Spacer(minLength: 0)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .widgetURL(URL(string: "stocked://grocery"))
        }
    }
}

struct GroceryWidget: Widget {
    let kind = "StockedGroceryWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StockedProvider()) { entry in
            GroceryWidgetView(entry: entry)
                .containerBackground(Color.wBg.opacity(0.0), for: .widget)
        }
        .configurationDisplayName("Grocery List")
        .description("Your next grocery items and remaining count.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

// MARK: - Meal and recipe options

struct TodayMealWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StockedEntry

    var body: some View {
        let meal = entry.snapshot.todayMeal
        if family == .accessoryInline {
            Label(meal.map { "Today: \($0)" } ?? "Plan today's meal", systemImage: "fork.knife")
                .widgetURL(URL(string: "stocked://cook"))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label(entry.snapshot.todayMealType ?? "Today's meal", systemImage: "fork.knife")
                        .font(.system(size: 13, weight: .bold))
                    Spacer()
                    Image(systemName: meal == nil ? "plus.circle.fill" : "arrow.right.circle.fill").foregroundStyle(Color.wGreen)
                }
                Spacer(minLength: 0)
                Text(meal ?? "Nothing planned yet")
                    .font(.system(family == .systemMedium ? .title3 : .headline, design: .serif, weight: .bold))
                    .lineLimit(family == .systemMedium ? 2 : 3)
                Text(meal == nil ? "Tap to choose a recipe" : "Tap to start cooking")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(URL(string: "stocked://cook"))
        }
    }
}

struct TodayMealWidget: Widget {
    let kind = "StockedTodayMealWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StockedProvider()) { entry in
            TodayMealWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Today's Meal")
        .description("See your planned meal and jump straight into cooking.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular])
    }
}

struct RecipeLibraryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: StockedEntry

    var body: some View {
        let snapshot = entry.snapshot
        if family == .accessoryInline {
            Label("\(snapshot.recipeCount ?? 0) saved recipes", systemImage: "book.closed.fill")
                .widgetURL(URL(string: "stocked://recipes"))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Recipe library", systemImage: "book.closed.fill").font(.system(size: 13, weight: .bold))
                    Spacer()
                    Text("\(snapshot.recipeCount ?? 0)").font(.headline).foregroundStyle(Color.wGold)
                }
                Spacer(minLength: 0)
                if let favorite = snapshot.favoriteRecipe, !favorite.isEmpty {
                    Text("Favorite").font(.caption2).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(favorite).font(.system(.headline, design: .serif, weight: .bold)).lineLimit(2)
                } else {
                    Text("Find something delicious").font(.system(.headline, design: .serif, weight: .bold)).lineLimit(2)
                    Text("Browse your recipes").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .widgetURL(URL(string: "stocked://recipes"))
        }
    }
}

struct RecipeLibraryWidget: Widget {
    let kind = "StockedRecipeLibraryWidget"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StockedProvider()) { entry in
            RecipeLibraryWidgetView(entry: entry).containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Recipe Library")
        .description("Open your saved recipes or return to a favorite.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryRectangular])
    }
}

@main
struct StockedWidgetBundle: WidgetBundle {
    var body: some Widget {
        StockedStatusWidget()
        ExpiringSoonWidget()
        GroceryWidget()
        TodayMealWidget()
        RecipeLibraryWidget()
        CookTimerLiveActivity()
    }
}
