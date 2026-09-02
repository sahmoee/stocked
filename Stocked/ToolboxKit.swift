// ToolboxKit.swift — Shared infrastructure for the Kitchen Toolbox suite.
//
// Performance notes (code improvements shipped here):
//  • ToolboxCoders / ToolboxFormatters: JSONEncoder/JSONDecoder and DateFormatter are
//    expensive to allocate. They are created ONCE as statics and reused by every toolbox
//    screen instead of being rebuilt per call.
//  • ToolboxKitchenSnapshot: a SINGLE O(n) pass over the inventory computes value, waste-risk,
//    low-stock, expiry, and zone breakdowns together, instead of each screen running its
//    own repeated .filter chains over the same array.
//  • GroceryTemplateStore: bounded (max 20 templates), saved once per mutation via didSet,
//    mirroring the coalesced-persistence pattern GuestDataStore uses.
//  • All snapshot payloads are plain value types computed OFF the render path (screens
//    compute them in .task / .onAppear and cache in @State), so SwiftUI bodies stay cheap.
import SwiftUI

// MARK: - Cached coders (perf)

@MainActor
enum ToolboxCoders {
    static let encoder = JSONEncoder()
    static let decoder = JSONDecoder()
}

// MARK: - Cached formatters (perf)

@MainActor
enum ToolboxFormatters {
    static let currency: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        return f
    }()
    static let monthDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()
    static let weekday: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()

    static func dollars(_ value: Double) -> String {
        currency.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }
}

// MARK: - Kitchen snapshot (single-pass aggregation, perf)

/// One pass over the inventory that every insight screen can share.
struct ToolboxKitchenSnapshot: Equatable {
    var totalItems = 0
    var pricedItems = 0
    var totalValue: Double = 0
    var valueByZone: [String: Double] = [:]
    var countByZone: [String: Int] = [:]
    var expiredCount = 0
    var expiringSoonCount = 0
    var lowStockCount = 0
    var leftoverCount = 0
    var expiredValue: Double = 0

    @MainActor
    static func compute(from items: [LocalInventoryItem]) -> ToolboxKitchenSnapshot {
        var s = ToolboxKitchenSnapshot()
        for item in items {
            s.totalItems += 1
            let zone = item.storageCategory.rawValue
            s.countByZone[zone, default: 0] += 1
            if let price = item.price {
                let value = price * Double(max(1, item.quantity))
                s.pricedItems += 1
                s.totalValue += value
                s.valueByZone[zone, default: 0] += value
                if item.isExpired { s.expiredValue += value }
            }
            if item.isExpired { s.expiredCount += 1 }
            else if item.isExpiringSoon { s.expiringSoonCount += 1 }
            if item.isLow { s.lowStockCount += 1 }
            if item.isLeftover { s.leftoverCount += 1 }
        }
        return s
    }
}

// MARK: - Grocery templates (feature: reusable shopping lists)

struct GroceryTemplate: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var items: [String]
    var created: Date = Date()
}

@Observable
@MainActor
final class GroceryTemplateStore {
    static let shared = GroceryTemplateStore()

    var templates: [GroceryTemplate] = [] {
        didSet { persist() }   // coalesced: one write per mutation, mirrors store pattern
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.groceryTemplates),
           let decoded = try? ToolboxCoders.decoder.decode([GroceryTemplate].self, from: data) {
            templates = decoded
        }
    }

    func save(name: String, items: [String]) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !items.isEmpty else { return }
        templates.insert(GroceryTemplate(name: trimmed, items: items), at: 0)
        if templates.count > 20 { templates = Array(templates.prefix(20)) }   // bounded (perf)
    }

    func delete(_ template: GroceryTemplate) {
        templates.removeAll { $0.id == template.id }
    }

    private func persist() {
        if let data = try? ToolboxCoders.encoder.encode(templates) {
            UserDefaults.standard.set(data, forKey: DefaultsKey.groceryTemplates)
        }
    }
}

// MARK: - Monthly budget storage (feature: grocery budget)

@MainActor
enum GroceryBudget {
    static var monthlyLimit: Double {
        get { UserDefaults.standard.double(forKey: DefaultsKey.monthlyGroceryBudget) }
        set { UserDefaults.standard.set(newValue, forKey: DefaultsKey.monthlyGroceryBudget) }
    }

    /// Sum of price records dated within the current calendar month.
    static func spentThisMonth(_ records: [PriceRecord]) -> Double {
        let cal = Calendar.current
        let now = Date()
        var total: Double = 0
        for r in records where cal.isDate(r.date, equalTo: now, toGranularity: .month) {
            total += r.price
        }
        return total
    }
}

// MARK: - Shared UI: empty state (UI/UX: consistent empty states)

struct ToolboxEmptyState: View {
    @Environment(AppSession.self) private var session
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .scaledFont(40, weight: .light)
                .foregroundStyle(session.themeSecondaryText.opacity(0.6))
            Text(title)
                .scaledFont(17, weight: .semibold)
                .foregroundStyle(session.themeTextColor)
            Text(message)
                .scaledFont(14)
                .foregroundStyle(session.themeSecondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared UI: expiry urgency chip (UI/UX: consistent urgency colors)

struct ExpiryUrgencyChip: View {
    let daysLeft: Int

    private var label: String {
        if daysLeft < 0  { return "Expired" }
        if daysLeft == 0 { return "Today" }
        if daysLeft == 1 { return "1 day" }
        return "\(daysLeft) days"
    }
    private var color: Color {
        if daysLeft < 0  { return .red }
        if daysLeft <= 2 { return .orange }
        if daysLeft <= KitchenThresholds.expiringSoonDays { return .yellow }
        return .green
    }

    var body: some View {
        Text(label)
            .scaledFont(11, weight: .semibold)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.14)))
            .accessibilityLabel(daysLeft < 0 ? "Expired" : "Expires in \(label)")
    }
}

// MARK: - Shared UI: stat tile

struct ToolboxStatTile: View {
    @Environment(AppSession.self) private var session
    let value: String
    let label: String
    var tint: Color? = nil

    var body: some View {
        VStack(spacing: 5) {
            Text(value)
                .scaledFont(22, weight: .bold, design: .rounded)
                .foregroundStyle(tint ?? session.themeTextColor)

                .fixedSize(horizontal: false, vertical: true)
            Text(label)
                .scaledFont(11, weight: .medium)
                .foregroundStyle(session.themeSecondaryText)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(session.themeCardColor)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }
}

// MARK: - Shared UI: card row

struct ToolboxCard<Content: View>: View {
    @Environment(AppSession.self) private var session
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(session.themeCardColor)
            )
    }
}

// MARK: - Shared UI: section label

struct ToolboxSectionLabel: View {
    @Environment(AppSession.self) private var session
    let text: String

    var body: some View {
        Text(text.uppercased())
            .scaledFont(11, weight: .semibold)
            .foregroundStyle(session.themeSecondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 6)
    }
}
