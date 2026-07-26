// NotificationEngagement.swift — Improvement #14: send fewer, better-timed nudges.
//
// The app can now schedule five recurring reminder types plus per-item expiry alerts (capped at
// 40), step timers, toolbox timers and thaw reminders. They all compete for the same attention at
// times the user picked once during setup and never revisited. Notification fatigue is what kills
// pantry apps — people mute them, and then the expiry warning that mattered never lands.
//
// Two changes, both conservative:
//   1. Learn when the user ACTUALLY opens the app and acts on notifications, and shift delivery
//      into that window rather than a default hour.
//   2. Cap how many notifications a single day can carry, and merge the overflow into one digest.
//
// This is advisory: `DailyBriefNotificationManager` asks it for a better hour, and keeps the user's
// explicit setting if they ever set one deliberately.

import Foundation
import UserNotifications

// MARK: - Model

nonisolated struct EngagementSample: Codable, Sendable {
    /// Hour of day, 0…23.
    var hour: Int
    /// 1 for an app open, 3 for acting on a notification — acting is much stronger evidence.
    var weight: Int
    var date: Date = Date()
}

// MARK: - Store

@MainActor
@Observable
final class NotificationEngagement {
    static let shared = NotificationEngagement()

    private let persistence = FeatureStore<EngagementSample>(key: FeatureStoreKeys.notifyEngagement)
    private(set) var samples: [EngagementSample] = []

    /// Ceiling on scheduled notifications per day, across all types. Above this we merge.
    static let dailyCap = 4
    /// Below this many samples we don't trust the learned hour and leave the user's setting alone.
    private let minimumSamples = 12

    private init() { samples = persistence.load() }

    func flush() { persistence.flush() }

    // MARK: Recording

    func recordAppOpen(at date: Date = Date()) {
        record(hour: Calendar.current.component(.hour, from: date), weight: 1, date: date)
    }

    /// The user tapped or acted on a notification — the strongest signal we get about when
    /// they're actually receptive.
    func recordNotificationAction(at date: Date = Date()) {
        record(hour: Calendar.current.component(.hour, from: date), weight: 3, date: date)
    }

    private func record(hour: Int, weight: Int, date: Date) {
        samples.append(EngagementSample(hour: hour, weight: weight, date: date))
        // 60 days is enough to learn a routine and short enough to follow a change in one.
        let cutoff = Date().addingTimeInterval(-60 * 86_400)
        samples = samples.filter { $0.date > cutoff }.suffix(600).map { $0 }
        persistence.save(samples)
    }

    // MARK: Reading

    /// Weighted opens per hour.
    var histogram: [Int: Int] {
        samples.reduce(into: [:]) { $0[$1.hour, default: 0] += $1.weight }
    }

    /// The hour the user is most reliably reachable, or nil while we're still learning.
    var learnedHour: Int? {
        let total = samples.reduce(0) { $0 + $1.weight }
        guard total >= minimumSamples else { return nil }
        return histogram.max { $0.value < $1.value }?.key
    }

    /// A better hour for a reminder, respecting a sensible window and the reminder's own purpose.
    ///
    /// - `preferred` is the user's configured hour; we only move off it when we have real evidence.
    /// - `earliest`/`latest` keep a "what's for dinner" nudge out of 3am even if that's genuinely
    ///   when this user opens the app.
    func suggestedHour(preferred: Int, earliest: Int = 7, latest: Int = 21) -> Int {
        guard let learned = learnedHour else { return preferred }
        // Never drag a reminder more than three hours from what the user chose. If they set 7am,
        // they meant morning — learning shouldn't quietly turn that into an evening alert.
        let bounded = min(max(learned, preferred - 3), preferred + 3)
        return min(max(bounded, earliest), latest)
    }

    var confidenceLabel: String {
        let total = samples.reduce(0) { $0 + $1.weight }
        if total < minimumSamples { return "Learning your routine" }
        guard let h = learnedHour else { return "Learning your routine" }
        let display = h == 0 ? "12 AM" : (h < 12 ? "\(h) AM" : (h == 12 ? "12 PM" : "\(h - 12) PM"))
        return "You usually check around \(display)"
    }

    // MARK: Volume control

    /// How many of our own notifications are already pending for the current day.
    /// Scoped to Stocked identifiers only — the app must never touch other pending requests.
    static func pendingToday() async -> Int {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        let cal = Calendar.current
        return requests.filter { req in
            guard req.identifier.hasPrefix("stocked_") || req.identifier.hasPrefix("thaw-") else { return false }
            guard let trigger = req.trigger as? UNCalendarNotificationTrigger,
                  let next = trigger.nextTriggerDate() else { return false }
            return cal.isDateInToday(next)
        }.count
    }

    /// True when adding another notification today would push past the cap — the caller should
    /// fold its content into the daily brief instead of scheduling separately.
    static func shouldMergeIntoDigest() async -> Bool {
        await pendingToday() >= dailyCap
    }
}
