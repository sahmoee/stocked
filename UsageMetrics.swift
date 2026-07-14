import Foundation

// ─────────────────────────────────────────────────────────────────────
// Build 255 — Local usage instrumentation (#20).
//
// A privacy-respecting, LOCAL-ONLY analytics layer. Nothing leaves the
// device — every event is a counter in UserDefaults. The point isn't to
// surveil the user; it's so you (the developer) can see, on your own
// device or a tester's, which of the app's many features actually earn
// their complexity — and which to cut. With 26 Home widgets, multiple
// scanners, meal planning, and online recipes, that signal is the most
// valuable input to future "what to improve" decisions.
//
// Usage:  UsageMetrics.shared.record(.cookStarted)
//         UsageMetrics.shared.record(.widgetAdded, detail: widget.rawValue)
// Read:   UsageMetrics.shared.summary()  (or the Usage Insights debug view)
// ─────────────────────────────────────────────────────────────────────

/// The set of things worth counting. Keep this enum the single registry of events so the
/// debug view can enumerate everything and nothing gets tracked ad hoc.
enum UsageEvent: String, CaseIterable {
    // Cooking
    case cookStarted
    case cookCompleted
    case cookRightNowOpened
    // Recipes
    case recipeSaved
    case recipeImportedOnline
    case discoverOpened
    case onlineRecipeOpened
    case recipeSearched
    // Inventory
    case itemAddedManual
    case itemAddedScan
    case receiptScanned
    case barcodeScanned
    case quickUpdateUsed
    case itemDeleted
    case staplesSeeded
    // Grocery
    case groceryItemAdded
    case groceryChecked
    case groceryCleared
    // Home / widgets
    case homeEditModeEntered
    case widgetAdded
    case widgetRemoved
    case widgetsReordered
    case dailyBriefOpened
    // Planning
    case mealPlanned

    var label: String {
        switch self {
        case .cookStarted:         return "Cook started"
        case .cookCompleted:       return "Cook completed"
        case .cookRightNowOpened:  return "Cook Right Now opened"
        case .recipeSaved:         return "Recipe saved"
        case .recipeImportedOnline:return "Online recipe imported"
        case .discoverOpened:      return "Discover opened"
        case .onlineRecipeOpened:  return "Online recipe opened"
        case .recipeSearched:      return "Recipe searched"
        case .itemAddedManual:     return "Item added (manual)"
        case .itemAddedScan:       return "Item added (scan)"
        case .receiptScanned:      return "Receipt scanned"
        case .barcodeScanned:      return "Barcode scanned"
        case .quickUpdateUsed:     return "Quick Update used"
        case .itemDeleted:         return "Item deleted"
        case .staplesSeeded:       return "Starter staples seeded"
        case .groceryItemAdded:    return "Grocery item added"
        case .groceryChecked:      return "Grocery item checked"
        case .groceryCleared:      return "Grocery cleared"
        case .homeEditModeEntered: return "Home edit mode entered"
        case .widgetAdded:         return "Widget added"
        case .widgetRemoved:       return "Widget removed"
        case .widgetsReordered:    return "Widgets reordered"
        case .dailyBriefOpened:    return "Daily Brief opened"
        case .mealPlanned:         return "Meal planned"
        }
    }
}

/// One feature's usage record.
struct UsageStat: Identifiable {
    var id: String { event }
    let event: String
    let label: String
    let count: Int
    let lastUsed: Date?
}

@MainActor
final class UsageMetrics {
    static let shared = UsageMetrics()
    private init() { load() }

    // Opt-out switch (defaults ON, but it's all local so there's nothing to leak).
    private let enabledKey = "stocked.usageMetricsEnabled_v1"
    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: enabledKey) == nil ? true
                                                                      : UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey); if !newValue { /* keep history */ } }
    }

    private let countsKey = "stocked.usageCounts_v1"   // [eventRaw: Int]
    private let lastKey   = "stocked.usageLast_v1"     // [eventRaw: timeIntervalSince1970]
    private let firstLaunchKey = "stocked.usageFirstLaunch_v1"

    private(set) var counts: [String: Int] = [:]
    private(set) var lastUsed: [String: TimeInterval] = [:]

    /// Record one occurrence of an event. `detail` lets callers note a sub-key (e.g. which
    /// widget) — stored as a separate "event:detail" counter so the top-level count stays clean.
    func record(_ event: UsageEvent, detail: String? = nil) {
        guard isEnabled else { return }
        bump(event.rawValue)
        if let detail, !detail.isEmpty { bump("\(event.rawValue)#\(detail)") }
        save()
    }

    private func bump(_ key: String) {
        counts[key, default: 0] += 1
        lastUsed[key] = Date().timeIntervalSince1970
    }

    /// Per-event summary for the top-level events, busiest first.
    func summary() -> [UsageStat] {
        UsageEvent.allCases.map { ev in
            UsageStat(event: ev.rawValue,
                      label: ev.label,
                      count: counts[ev.rawValue] ?? 0,
                      lastUsed: lastUsed[ev.rawValue].map { Date(timeIntervalSince1970: $0) })
        }
        .sorted { $0.count > $1.count }
    }

    /// Detail breakdown for one event (e.g. widget add counts by widget name).
    func detailBreakdown(for event: UsageEvent) -> [(String, Int)] {
        let prefix = "\(event.rawValue)#"
        return counts.compactMap { key, value in
            key.hasPrefix(prefix) ? (String(key.dropFirst(prefix.count)), value) : nil
        }
        .sorted { $0.1 > $1.1 }
    }

    var firstLaunch: Date {
        if let t = UserDefaults.standard.object(forKey: firstLaunchKey) as? Double {
            return Date(timeIntervalSince1970: t)
        }
        let now = Date()
        UserDefaults.standard.set(now.timeIntervalSince1970, forKey: firstLaunchKey)
        return now
    }

    var totalEvents: Int { counts.filter { !$0.key.contains("#") }.values.reduce(0, +) }

    func reset() {
        counts = [:]; lastUsed = [:]
        UserDefaults.standard.removeObject(forKey: countsKey)
        UserDefaults.standard.removeObject(forKey: lastKey)
    }

    private func load() {
        counts   = (UserDefaults.standard.dictionary(forKey: countsKey) as? [String: Int]) ?? [:]
        lastUsed = (UserDefaults.standard.dictionary(forKey: lastKey) as? [String: TimeInterval]) ?? [:]
        _ = firstLaunch  // ensure stamped
    }
    private func save() {
        UserDefaults.standard.set(counts, forKey: countsKey)
        UserDefaults.standard.set(lastUsed, forKey: lastKey)
    }
}
