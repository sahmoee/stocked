// OnboardingTelemetry.swift — #20 Onboarding completion telemetry.
//
// The first-run activation card (seed staples / scan a receipt) exists, but there's no way to
// tell whether people actually complete it. This records lightweight, on-device funnel events so
// you can see the activation rate (surface them in a debug view, or pair with MetricKit/your
// UsageMetrics). Nothing leaves the device; no existing files are modified.
//
// Call the static markers at the relevant points, e.g.:
//   OnboardingTelemetry.shared.mark(.cardShown)        // when the activation card appears
//   OnboardingTelemetry.shared.mark(.tappedSeedStaples)
//   OnboardingTelemetry.shared.mark(.tappedScanReceipt)
//   OnboardingTelemetry.shared.mark(.firstItemAdded)   // first inventory item ever
//   OnboardingTelemetry.shared.mark(.completed)        // your definition of "activated"

import Foundation
import Observation

@Observable
final class OnboardingTelemetry {
    static let shared = OnboardingTelemetry()

    enum Event: String, CaseIterable, Codable {
        case cardShown
        case tappedSeedStaples
        case tappedScanReceipt
        case firstItemAdded
        case completed
    }

    /// First time each event fired (idempotent — only the first occurrence is recorded).
    private(set) var firsts: [String: Date]

    private let key = "onboarding_funnel_v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Date].self, from: data) {
            firsts = decoded
        } else {
            firsts = [:]
        }
    }

    /// Records the first occurrence of an event. Subsequent calls are ignored.
    func mark(_ event: Event) {
        guard firsts[event.rawValue] == nil else { return }
        firsts[event.rawValue] = Date()
        persist()
    }

    /// Did the user reach the given step?
    func reached(_ event: Event) -> Bool { firsts[event.rawValue] != nil }

    /// A simple ordered funnel summary for a debug view.
    func funnelSummary() -> [(step: String, at: Date?)] {
        Event.allCases.map { ($0.rawValue, firsts[$0.rawValue]) }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(firsts) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    #if DEBUG
    func _reset() { firsts = [:]; UserDefaults.standard.removeObject(forKey: key) }
    #endif
}
