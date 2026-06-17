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
        completion(StockedEntry(date: Date(), snapshot: WidgetStore.load()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<StockedEntry>) -> Void) {
        let entry = StockedEntry(date: Date(), snapshot: WidgetStore.load())
        // Hourly refresh as a backstop; the app force-reloads on real data changes.
        let next = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date().addingTimeInterval(3600)
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
        case .accessoryCircular:  circular
        case .accessoryInline:    inline
        case .accessoryRectangular: rectangular
        default:                  small
        }
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
        .supportedFamilies([.systemSmall, .systemMedium,
                            .accessoryCircular, .accessoryInline, .accessoryRectangular])
    }
}

@main
struct StockedWidgetBundle: WidgetBundle {
    var body: some Widget {
        StockedStatusWidget()
        CookTimerLiveActivity()
    }
}
