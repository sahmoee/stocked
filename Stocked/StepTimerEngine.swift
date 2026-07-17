// StepTimerEngine.swift
// ─────────────────────────────────────────────────────────────────
// Concurrent per-step countdown timers for the cook flow.
// • Parses step text for time mentions automatically
// • Runs multiple timers simultaneously (e.g. roasting + boiling)
// • Fires a local notification when each timer expires
// • Integrates with UNUserNotificationCenter for background alerts
// ─────────────────────────────────────────────────────────────────
import Foundation
import UserNotifications
import SwiftUI

// MARK: - Single timer state
@Observable
final class StepTimer {
    let stepIndex: Int
    let totalSeconds: Int
    var remaining: Int
    var isRunning = false
    var isFinished = false
    private var task: Task<Void, Never>?

    init(stepIndex: Int, seconds: Int) {
        self.stepIndex = stepIndex
        self.totalSeconds = seconds
        self.remaining = seconds
    }

    /// RL-001 — rebuild a timer from a persisted session snapshot with an
    /// already-elapsed portion (or as finished, when the timer ran out while
    /// the app was closed / the device was locked).
    init(stepIndex: Int, seconds: Int, remaining: Int, isFinished: Bool) {
        self.stepIndex = stepIndex
        self.totalSeconds = seconds
        self.remaining = max(0, remaining)
        self.isFinished = isFinished
    }

    func start(onFinish: @escaping (Int) -> Void) {
        guard !isFinished else { return }
        isRunning = true
        task = Task { @MainActor in
            while remaining > 0 && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                if !Task.isCancelled { remaining -= 1 }
            }
            guard !Task.isCancelled else { return }
            isRunning = false
            isFinished = true
            onFinish(stepIndex)
        }
    }

    func pause() {
        task?.cancel(); task = nil
        isRunning = false
    }

    func reset() {
        pause()
        remaining = totalSeconds
        isFinished = false
    }

    var displayString: String {
        let m = remaining / 60
        let s = remaining % 60
        return String(format: "%d:%02d", m, s)
    }

    var progress: Double {
        totalSeconds == 0 ? 0 : 1 - Double(remaining) / Double(totalSeconds)
    }
}

// MARK: - Engine (owns all timers for one cook session)
@MainActor
@Observable
final class StepTimerEngine {

    var timers: [Int: StepTimer] = [:]

    // #16 — context for the Live Activity, set by the cook flow.
    var recipeTitle: String = ""
    var totalSteps: Int = 0

    // RL-001 — step text per timer so persisted sessions can rebuild
    // notifications and the Live Activity on resume.
    private var stepTexts: [Int: String] = [:]
    /// RL-001 — the cook flow hooks this to capture a session snapshot whenever
    /// timer state changes (start / pause / reset / finish).
    var onStateChange: (() -> Void)? = nil

    // MARK: - Time parsing
    /// Returns detected seconds from a step string, or nil if none found.
    nonisolated static func detectSeconds(in text: String) -> Int? {
        let t = text.lowercased()

        // Patterns: "30 minutes", "5 mins", "1 hour 30 minutes", "45 seconds", "1½ hours"
        var totalSeconds = 0
        var found = false

        // Hours
        let hourPatterns = [
            #"(\d+[\.\s]?\d*)\s*(?:hours?|hrs?)"#,
            #"(one|two|three|four|five|six)\s*hours?"#
        ]
        let wordHours = ["one":1,"two":2,"three":3,"four":4,"five":5,"six":6]

        for pattern in hourPatterns {
            if let match = t.range(of: pattern, options: .regularExpression) {
                let sub = String(t[match])
                if let word = wordHours.first(where: { sub.contains($0.key) }) {
                    totalSeconds += word.value * 3600; found = true
                } else if let num = extractNumber(from: sub) {
                    totalSeconds += Int(num * 3600); found = true
                }
            }
        }

        // Minutes
        let minPattern = #"(\d+[\u00BD\u2153\u2154]?\.?\d*)\s*(?:minutes?|mins?)"#
        if let match = t.range(of: minPattern, options: .regularExpression) {
            let sub = String(t[match])
            if let num = extractNumber(from: sub) {
                totalSeconds += Int(num * 60); found = true
            }
        }

        // Seconds
        let secPattern = #"(\d+)\s*(?:seconds?|secs?)"#
        if let match = t.range(of: secPattern, options: .regularExpression) {
            let sub = String(t[match])
            if let num = extractNumber(from: sub) {
                totalSeconds += Int(num); found = true
            }
        }

        return found && totalSeconds > 0 ? totalSeconds : nil
    }

    private nonisolated static func extractNumber(from string: String) -> Double? {
        // Handle "1½" → 1.5, "30" → 30, "1.5" → 1.5
        let s = string
            .replacingOccurrences(of: "½", with: ".5")
            .replacingOccurrences(of: "⅓", with: ".33")
            .replacingOccurrences(of: "⅔", with: ".67")
            .replacingOccurrences(of: "¼", with: ".25")
            .replacingOccurrences(of: "¾", with: ".75")
        // Extract first number
        if let match = s.range(of: #"\d+\.?\d*"#, options: .regularExpression) {
            return Double(s[match])
        }
        return nil
    }

    // MARK: - Timer control
    func startTimer(stepIndex: Int, stepText: String) {
        stepTexts[stepIndex] = stepText
        if let existing = timers[stepIndex] {
            existing.start { [weak self] idx in self?.handleFinished(idx, stepText: stepText) }
            // Resuming a paused countdown: the original notification was
            // canceled on pause, so schedule a fresh one for the remaining time.
            scheduleNotification(stepIndex: stepIndex, seconds: existing.remaining, stepText: stepText)
            // #16 — resume: relaunch the Live Activity for the remaining time.
            LiveActivityManager.shared.start(
                recipeTitle: recipeTitle, stepNumber: stepIndex + 1, totalSteps: totalSteps,
                stepText: stepText, endDate: Date().addingTimeInterval(TimeInterval(existing.remaining)))
            onStateChange?()
            return
        }
        guard let secs = Self.detectSeconds(in: stepText), secs > 0 else { return }
        let timer = StepTimer(stepIndex: stepIndex, seconds: secs)
        timers[stepIndex] = timer
        timer.start { [weak self] idx in self?.handleFinished(idx, stepText: stepText) }
        scheduleNotification(stepIndex: stepIndex, seconds: secs, stepText: stepText)
        // #16 — surface the running timer on the Lock Screen / Dynamic Island.
        LiveActivityManager.shared.start(
            recipeTitle: recipeTitle, stepNumber: stepIndex + 1, totalSteps: totalSteps,
            stepText: stepText, endDate: Date().addingTimeInterval(TimeInterval(secs)))
        onStateChange?()
    }

    func pauseTimer(stepIndex: Int) {
        timers[stepIndex]?.pause()
        cancelNotification(stepIndex: stepIndex)
        LiveActivityManager.shared.end()
        onStateChange?()
    }

    func resetTimer(stepIndex: Int) {
        timers[stepIndex]?.reset()
        cancelNotification(stepIndex: stepIndex)
        LiveActivityManager.shared.end()
        onStateChange?()
    }

    // MARK: - RL-001 session persistence (export / restore / suspend)

    /// Capture every timer with wall-clock semantics: running timers store a
    /// fire DATE, paused timers a frozen remaining count. Called by the cook
    /// flow whenever it snapshots the session.
    func exportStates() -> [CookSessionTimerState] {
        timers.values
            .sorted { $0.stepIndex < $1.stepIndex }
            .map { t in
                CookSessionTimerState(
                    stepIndex: t.stepIndex,
                    stepText: stepTexts[t.stepIndex] ?? "",
                    totalSeconds: t.totalSeconds,
                    endDate: (t.isRunning && !t.isFinished)
                        ? Date().addingTimeInterval(TimeInterval(t.remaining)) : nil,
                    pausedRemaining: (!t.isRunning && !t.isFinished) ? t.remaining : nil,
                    isFinished: t.isFinished)
            }
    }

    /// Rebuild timers from a persisted session, adjusted for elapsed wall-clock
    /// time. A running timer whose fire date passed while the app was away
    /// restores as finished/ready. Running timers re-schedule their local
    /// notification (identical identifier — replaces any still-pending one).
    func restore(_ states: [CookSessionTimerState]) {
        var soonestRunning: (index: Int, text: String, remaining: Int)? = nil
        for s in states {
            stepTexts[s.stepIndex] = s.stepText
            if s.isFinished {
                timers[s.stepIndex] = StepTimer(stepIndex: s.stepIndex, seconds: s.totalSeconds,
                                                remaining: 0, isFinished: true)
            } else if let end = s.endDate {
                let remaining = Int(end.timeIntervalSinceNow.rounded())
                if remaining <= 0 {
                    // Finished while paused/backgrounded/locked — show it done.
                    timers[s.stepIndex] = StepTimer(stepIndex: s.stepIndex, seconds: s.totalSeconds,
                                                    remaining: 0, isFinished: true)
                } else {
                    let timer = StepTimer(stepIndex: s.stepIndex, seconds: s.totalSeconds,
                                          remaining: remaining, isFinished: false)
                    timers[s.stepIndex] = timer
                    let text = s.stepText
                    timer.start { [weak self] idx in self?.handleFinished(idx, stepText: text) }
                    scheduleNotification(stepIndex: s.stepIndex, seconds: remaining, stepText: text)
                    if soonestRunning == nil || remaining < (soonestRunning?.remaining ?? .max) {
                        soonestRunning = (s.stepIndex, text, remaining)
                    }
                }
            } else {
                // Paused mid-count: frozen exactly where the user left it.
                timers[s.stepIndex] = StepTimer(stepIndex: s.stepIndex, seconds: s.totalSeconds,
                                                remaining: s.pausedRemaining ?? s.totalSeconds,
                                                isFinished: false)
            }
        }
        // #16 — one Live Activity: surface the soonest-ending running timer.
        if let running = soonestRunning {
            LiveActivityManager.shared.start(
                recipeTitle: recipeTitle, stepNumber: running.index + 1, totalSteps: totalSteps,
                stepText: running.text,
                endDate: Date().addingTimeInterval(TimeInterval(running.remaining)))
        }
    }

    /// Stop in-app countdown tasks WITHOUT canceling the pending timer
    /// notifications — used when the user pauses and leaves the cook. Running
    /// pots keep cooking in the real world, so the notification still fires
    /// even if the device stays locked longer than the timer.
    func suspendKeepingNotifications() {
        for timer in timers.values { timer.pause() }
        timers.removeAll()
        stepTexts.removeAll()
        LiveActivityManager.shared.end()
    }

    func cancelAll() {
        // Capture the step indices BEFORE clearing so we can remove exactly the timer
        // notifications this engine scheduled. Previously this called
        // removeAllPendingNotificationRequests(), which also deleted the kitchen reminders
        // (expiry / cook / staples / prep / daily brief) whenever a user left a cooking
        // session — a second cause of reminders never firing outside the app.
        let timerIDs = timers.keys.map { "step_timer_\($0)" }
        for timer in timers.values { timer.pause() }
        timers.removeAll()
        if !timerIDs.isEmpty {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: timerIDs)
        }
        LiveActivityManager.shared.end()
    }

    func hasTimer(for stepIndex: Int) -> Bool {
        StepTimerEngine.detectSeconds(in: "") != nil || timers[stepIndex] != nil
    }

    private func handleFinished(_ stepIndex: Int, stepText: String) {
        HapticManager.success()
        LiveActivityManager.shared.end()
        onStateChange?()   // RL-001 — persist the finished state immediately
    }

    // MARK: - Local notifications
    private func scheduleNotification(stepIndex: Int, seconds: Int, stepText: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "⏱ Timer Done"
            content.body = "Step \(stepIndex + 1) complete — \(stepText.prefix(60))"
            content.sound = .default
            let trigger = UNTimeIntervalNotificationTrigger(timeInterval: TimeInterval(seconds), repeats: false)
            let id = "step_timer_\(stepIndex)"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
        }
    }

    private func cancelNotification(stepIndex: Int) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(
            withIdentifiers: ["step_timer_\(stepIndex)"]
        )
    }
}
