// LiveActivityManager.swift — MAIN APP TARGET ONLY.
// Starts/updates/ends the cook-timer Live Activity. Driven by an end Date so the Lock
// Screen + Dynamic Island count down on-device without per-second app updates.
// ⚠️ Requires "NSSupportsLiveActivities = YES" in the app's Info.plist.
import Foundation
@preconcurrency import ActivityKit
import os

@MainActor
@Observable
final class LiveActivityManager {
    static let shared = LiveActivityManager()
    private init() {}

    private let log = Logger(subsystem: "com.sowens.Stocked", category: "liveactivity")
    private var current: Activity<CookTimerAttributes>?

    /// Whether iOS will allow Live Activities right now (Info.plist key present AND the
    /// user's Settings toggle on). False is the most common reason timers never appear.
    var isEnabled: Bool { ActivityAuthorizationInfo().areActivitiesEnabled }

    /// Human-readable reason the last start failed — shown in the cook flow so the
    /// problem is visible on-device, no Xcode console required. nil = last start OK.
    var lastFailure: String? = nil
    /// Set when a request SUCCEEDS, so the user can tell the request went through even if
    /// nothing renders (which would mean the widget extension lacks the Live Activity view).
    var lastInfo: String? = nil

    /// Start (or replace) the Live Activity for the currently-running step timer.
    func start(recipeTitle: String, stepNumber: Int, totalSteps: Int, stepText: String, endDate: Date) {
        let info = ActivityAuthorizationInfo()
        guard info.areActivitiesEnabled else {
            // Either NSSupportsLiveActivities is missing from Info.plist, or the user has
            // Live Activities turned off in Settings for this app.
            lastInfo = nil
            lastFailure = "Lock Screen timer unavailable — turn on Live Activities in Settings → Stocked, and make sure ‘Supports Live Activities’ is YES in the app target's Info."
            log.error("Live Activity NOT started: activities are disabled (check Info.plist NSSupportsLiveActivities = YES, and Settings → Stocked → Live Activities).")
            return
        }
        end()   // one timer on the Lock Screen at a time

        let attributes = CookTimerAttributes(recipeTitle: recipeTitle.isEmpty ? "Cooking" : recipeTitle)
        let state = CookTimerAttributes.ContentState(
            stepNumber: stepNumber, totalSteps: totalSteps,
            stepText: String(stepText.prefix(80)), endDate: endDate, isRunning: true)
        do {
            current = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: endDate.addingTimeInterval(120)),
                pushType: nil)
            lastFailure = nil
            lastInfo = "Timer requested ✓. If it's not on your Lock Screen, the widget extension's @main bundle must list CookTimerLiveActivity() and that file must belong to the StockedWidgets target."
            log.log("Live Activity started for step \(stepNumber, privacy: .public) (ends in \(Int(endDate.timeIntervalSinceNow), privacy: .public)s).")
        } catch {
            current = nil
            lastFailure = "Lock Screen timer couldn't start (\(error.localizedDescription)). Check the widget extension includes CookTimerLiveActivity and CookTimerActivity is in both targets."
            lastInfo = nil
            log.error("Live Activity request FAILED: \(error.localizedDescription, privacy: .public). Most likely the widget extension doesn't include CookTimerLiveActivity / CookTimerAttributes, or the App ID lacks the capability.")
        }
    }

    func end() {
        guard let activity = current else { return }
        current = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
