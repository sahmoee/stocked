// AppAnalytics.swift — One on-device event log for the whole app (#7).
//
// Onboarding has its own funnel telemetry; the rest of the app has no consistent way to record
// "what happened." This is a single, lightweight wrapper to log meaningful events — a recipe was
// saved, a receipt was scanned, a cook session finished — so usage can be understood and surfaced
// in the existing insights views. Everything stays on device; nothing is sent anywhere.
//
// Follows the OnboardingTelemetry pattern: an @Observable singleton persisted to UserDefaults.
// Additive — call AppAnalytics.shared.log(.recipeSaved) at the relevant points; no existing files
// need to change for this to compile.

import Foundation
import Observation

@Observable
final class AppAnalytics {
    static let shared = AppAnalytics()

    /// The meaningful things a user can do. Keep names stable; they are persisted as raw strings.
    enum Event: String, CaseIterable, Codable {
        // Onboarding / setup
        case onboardingCompleted
        // Inventory
        case itemAdded
        case itemEdited
        case barcodeScanned
        case receiptScanned
        // Recipes
        case recipeViewed
        case recipeSaved
        case recipeImported
        // Cooking
        case cookStarted
        case cookCompleted
        // Grocery
        case groceryItemAdded
        case groceryItemChecked
        case groceryListShared
        // Data
        case dataExported
        case kitchenTransferred
        // Correction (pairs with UserCorrections)
        case dataCorrected
    }

    /// Total count per event.
    private(set) var counts: [String: Int]
    /// Timestamp of the most recent occurrence per event.
    private(set) var lastSeen: [String: Date]

    private let countsKey = "app_analytics_counts_v1"
    private let lastSeenKey = "app_analytics_lastseen_v1"
    private let enabledKey = "app_analytics_enabled_v1"

    /// #19 — opt-out. Everything is on-device, but the user still owns the choice. Default on;
    /// when off, `log` is a no-op and existing counts can be cleared via `reset()`.
    var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: enabledKey) }
    }

    private init() {
        counts = AppAnalytics.loadDict(countsKey)
        lastSeen = AppAnalytics.loadDates(lastSeenKey)
        isEnabled = UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    // MARK: - Logging

    /// Record one occurrence of an event. No-op when the user has opted out.
    func log(_ event: Event) {
        guard isEnabled else { return }
        counts[event.rawValue, default: 0] += 1
        lastSeen[event.rawValue] = Date()
        persist()
    }

    /// Total times an event has occurred.
    func count(_ event: Event) -> Int { counts[event.rawValue] ?? 0 }

    /// When an event last occurred, if ever.
    func lastOccurred(_ event: Event) -> Date? { lastSeen[event.rawValue] }

    /// A snapshot of all non-zero counts, highest first — handy for an insights/debug view.
    var summary: [(event: String, count: Int)] {
        counts.filter { $0.value > 0 }
            .sorted { $0.value > $1.value }
            .map { (event: $0.key, count: $0.value) }
    }

    /// Clear everything (e.g. a privacy reset).
    func reset() {
        counts.removeAll(); lastSeen.removeAll(); persist()
    }

    // MARK: - Persistence

    private func persist() {
        if let d = try? JSONEncoder().encode(counts) { UserDefaults.standard.set(d, forKey: countsKey) }
        if let d = try? JSONEncoder().encode(lastSeen) { UserDefaults.standard.set(d, forKey: lastSeenKey) }
    }

    private static func loadDict(_ key: String) -> [String: Int] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Int].self, from: data) else { return [:] }
        return decoded
    }

    private static func loadDates(_ key: String) -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: Date].self, from: data) else { return [:] }
        return decoded
    }
}
