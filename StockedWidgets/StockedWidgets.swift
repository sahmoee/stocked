// StockedWidgets.swift — WIDGET EXTENSION TARGET ONLY.
// Home Screen (#13: small + medium) and Lock Screen (#14: circular / inline / rectangular)
// widgets showing kitchen status from the App Group snapshot. Self-contained colors so it
// doesn't depend on the app's Color extensions.
import WidgetKit
import SwiftUI

extension View {
    nonisolated func widgetScaledFont(
        _ size: CGFloat,
        weight: Font.Weight = .regular,
        design: Font.Design = .default
    ) -> some View {
        modifier(WidgetScaledFontModifier(size: size, weight: weight, design: design))
    }
}

private struct WidgetScaledFontModifier: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var scaled: CGFloat = 14
    @AppStorage(
        "stocked.appTextSize",
        store: UserDefaults(suiteName: "group.com.sowens.Stocked")
    ) private var appTextSizeRaw = "Standard"
    let weight: Font.Weight
    let design: Font.Design

    nonisolated init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _scaled = ScaledMetric(wrappedValue: size, relativeTo: Self.textStyle(for: size))
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(
            size: scaled * Self.appScale(for: appTextSizeRaw),
            weight: weight,
            design: design
        ))
    }

    nonisolated private static func appScale(for value: String) -> CGFloat {
        switch value {
        case "XS": 0.82
        case "Small": 0.9
        case "Medium": 1.1
        case "Large": 1.22
        case "XL": 1.36
        case "XXL": 1.52
        default: 1.06
        }
    }

    nonisolated private static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: return .caption2
        case ..<13: return .caption
        case ..<16: return .subheadline
        case ..<20: return .headline
        case ..<28: return .title2
        default: return .largeTitle
        }
    }
}

/// WidgetKit owns the outer family size, so atomic values adapt inside that shape.
/// Every candidate remains linked to system Dynamic Type and Stocked's app text size.
private struct WidgetFittedValue: View {
    let value: String
    let preferredSize: CGFloat

    var body: some View {
        ViewThatFits(in: .horizontal) {
            candidate(preferredSize)
            candidate(preferredSize * 0.86)
            candidate(preferredSize * 0.72)
            candidate(max(13, preferredSize * 0.58))
        }
        .contentTransition(.numericText())
    }

    private func candidate(_ size: CGFloat) -> some View {
        Text(value)
            .widgetScaledFont(size, weight: .heavy, design: .serif)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: true)
    }
}

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
                    .widgetScaledFont(17, weight: .bold, design: .rounded)
                Spacer()
                if s.isStale { Label("Open to refresh", systemImage: "arrow.clockwise").widgetScaledFont(11).foregroundStyle(.secondary) }
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
            Text("Updated \(s.updatedAt, style: .relative)").widgetScaledFont(11).foregroundStyle(.secondary)
        }
        .widgetURL(URL(string: "stocked://home"))
    }

    private func metric(_ value: String, _ label: String, _ icon: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Image(systemName: icon).foregroundStyle(tint)
            WidgetFittedValue(value: value, preferredSize: 22)
            Text(label).widgetScaledFont(12).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10).background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    // Home Screen — small: stock ring + headline alert.
    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "refrigerator.fill").widgetScaledFont(13).foregroundStyle(Color.wGold)
                Text("Stocked.").widgetScaledFont(14, weight: .bold, design: .serif).foregroundStyle(.primary)
            }
            Spacer(minLength: 0)
            WidgetFittedValue(value: "\(s.stockPercent)%", preferredSize: 40)
                .foregroundStyle(stockTint(s.stockPercent))
            Text("stocked").widgetScaledFont(12).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if s.expiringCount > 0 {
                Label("\(s.expiringCount) expiring", systemImage: "clock.badge.exclamationmark")
                    .widgetScaledFont(11, weight: .semibold).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if s.lowStockCount > 0 {
                Label("\(s.lowStockCount) low", systemImage: "chart.bar.fill")
                    .widgetScaledFont(11, weight: .semibold).foregroundStyle(Color.wGold).fixedSize(horizontal: false, vertical: true)
            } else {
                Label("All good", systemImage: "checkmark.circle.fill")
                    .widgetScaledFont(11, weight: .semibold).foregroundStyle(Color.wGreen).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(URL(string: "stocked://inventory"))   // #13 tap → Inventory
    }

    // Home Screen — medium: status + what to act on + today's meal.
    private var medium: some View {
        ViewThatFits(in: .horizontal) {
            mediumContent(tileWidth: 92, spacing: 16)
            mediumContent(tileWidth: 72, spacing: 10)
            mediumContent(tileWidth: 58, spacing: 8)
        }
        .widgetURL(URL(string: "stocked://home"))   // #13 tap → Home dashboard
    }

    private func mediumContent(tileWidth: CGFloat, spacing: CGFloat) -> some View {
        HStack(spacing: spacing) {
            VStack(spacing: 2) {
                WidgetFittedValue(value: "\(s.stockPercent)%", preferredSize: 38)
                    .foregroundStyle(stockTint(s.stockPercent))
                Text("stocked").widgetScaledFont(11).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: tileWidth)
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
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
        }
    }

    private func row(_ icon: String, _ tint: Color, _ title: String, _ detail: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).widgetScaledFont(13).foregroundStyle(tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).widgetScaledFont(13, weight: .semibold).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                Text(detail).widgetScaledFont(11).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            Text("\(s.stockPercent)% stocked").widgetScaledFont(15, weight: .bold)
            if s.expiringCount > 0 {
                Text("\(s.expiringCount) expiring soon").widgetScaledFont(12)
            } else if let meal = s.todayMeal, !meal.isEmpty {
                Text("Tonight: \(meal)").widgetScaledFont(12).fixedSize(horizontal: false, vertical: true)
            } else if s.lowStockCount > 0 {
                Text("\(s.lowStockCount) running low").widgetScaledFont(12)
            } else {
                Text("Kitchen looks great").widgetScaledFont(12)
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
                Image(systemName: "clock.badge.exclamationmark").widgetScaledFont(12, weight: .semibold)
                Text("Use soon").widgetScaledFont(13, weight: .bold)
                Spacer()
                WidgetFittedValue(value: "\(s.expiringCount)", preferredSize: 17).foregroundStyle(.orange)
            }
            if s.expiringNames.isEmpty {
                Text(s.expiringCount == 0 ? "Nothing expiring" : "\(s.expiringCount) expiring")
                    .widgetScaledFont(12).foregroundStyle(.secondary)
            } else {
                ForEach(s.expiringNames.prefix(family == .systemMedium ? 4 : 3), id: \.self) { n in
                    Label(n, systemImage: "circle.fill").widgetScaledFont(12).fixedSize(horizontal: false, vertical: true)
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
            Text("\(s.groceryCount)").widgetScaledFont(17, weight: .semibold)
          }.widgetURL(URL(string: "stocked://grocery"))
        } else {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Grocery list", systemImage: "cart.fill").widgetScaledFont(13, weight: .bold)
                Spacer()
                WidgetFittedValue(value: "\(s.groceryCount)", preferredSize: 17).foregroundStyle(Color.wGold)
            }
            if let names = s.groceryNames, !names.isEmpty {
                ForEach(names.prefix(family == .systemMedium ? 4 : 3), id: \.self) { name in
                    Label(name, systemImage: "circle").widgetScaledFont(12).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Spacer(minLength: 0)
                Label("List is clear", systemImage: "checkmark.circle.fill").widgetScaledFont(12).foregroundStyle(Color.wGreen)
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
                        .widgetScaledFont(13, weight: .bold)
                    Spacer()
                    Image(systemName: meal == nil ? "plus.circle.fill" : "arrow.right.circle.fill").foregroundStyle(Color.wGreen)
                }
                Spacer(minLength: 0)
                Text(meal ?? "Nothing planned yet")
                    .widgetScaledFont(family == .systemMedium ? 20 : 17, weight: .bold, design: .serif)
                    .fixedSize(horizontal: false, vertical: true)
                Text(meal == nil ? "Tap to choose a recipe" : "Tap to start cooking")
                    .widgetScaledFont(12).foregroundStyle(.secondary)
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
                    Label("Recipe library", systemImage: "book.closed.fill").widgetScaledFont(13, weight: .bold)
                    Spacer()
                    Text("\(snapshot.recipeCount ?? 0)").widgetScaledFont(17, weight: .semibold).foregroundStyle(Color.wGold)
                }
                Spacer(minLength: 0)
                if let favorite = snapshot.favoriteRecipe, !favorite.isEmpty {
                    Text("Favorite").widgetScaledFont(11).foregroundStyle(.secondary).textCase(.uppercase)
                    Text(favorite).widgetScaledFont(17, weight: .bold, design: .serif).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Find something delicious").widgetScaledFont(17, weight: .bold, design: .serif).fixedSize(horizontal: false, vertical: true)
                    Text("Browse your recipes").widgetScaledFont(12).foregroundStyle(.secondary)
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
