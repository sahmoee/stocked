import Foundation
@preconcurrency import UserNotifications
import SwiftUI

/// Session-owned timer tasks, notifications and the soonest-running Live Activity.
@MainActor @Observable final class StepTimerEngine {
    private(set) var timers: [Int: StepTimer] = [:]
    var recipeTitle = ""
    var totalSteps = 0
    var onStateChange: (() -> Void)?
    private(set) var notificationStatus: String?
    @ObservationIgnored private var stepTexts: [Int: String] = [:]
    @ObservationIgnored private var notificationIDs: [Int: String] = [:]
    @ObservationIgnored private var notificationTasks: [Int: Task<Void, Never>] = [:]
    @ObservationIgnored private var notificationGenerations: [Int: UUID] = [:]
    @ObservationIgnored private let liveOwner = UUID()
    @ObservationIgnored private var liveStep: Int?
    @ObservationIgnored private var liveDeadline: Date?

    nonisolated static func detectSeconds(in text: String) -> Int? { CookingTimerPolicy.detectSeconds(in: text) }

    func startTimer(stepIndex: Int, stepText: String) {
        guard stepIndex >= 0, stepIndex < 10_000,
              totalSteps <= 0 || stepIndex < totalSteps else { return }
        let timer: StepTimer
        if let existing = timers[stepIndex] { timer = existing }
        else {
            guard timers.count < CookingTimerPolicy.maximumTimers,
                  let seconds = Self.detectSeconds(in: stepText) else { return }
            timer = StepTimer(stepIndex: stepIndex, seconds: seconds)
            timers[stepIndex] = timer
        }
        guard timer.start(onFinish: { [weak self] in self?.handleFinished($0) }) else { return }
        stepTexts[stepIndex] = String(stepText.prefix(CookingTimerPolicy.maximumTextCharacters))
        if notificationIDs[stepIndex] == nil { notificationIDs[stepIndex] = "stocked.step.\(UUID().uuidString)" }
        scheduleNotification(stepIndex: stepIndex)
        updateLiveActivity(); onStateChange?()
    }

    func pauseTimer(stepIndex: Int) {
        guard let timer = timers[stepIndex], timer.isRunning else { return }
        timer.pause(); cancelNotification(stepIndex: stepIndex)
        updateLiveActivity(); onStateChange?()
    }
    func resetTimer(stepIndex: Int) {
        guard let timer = timers[stepIndex] else { return }
        timer.reset(); cancelNotification(stepIndex: stepIndex)
        updateLiveActivity(); onStateChange?()
    }

    func exportStates() -> [CookSessionTimerState] {
        let now = Date()
        return timers.values.sorted { $0.stepIndex < $1.stepIndex }.map { timer in
            timer.refresh(now: now)
            return CookSessionTimerState(stepIndex: timer.stepIndex, stepText: stepTexts[timer.stepIndex] ?? "",
                totalSeconds: timer.totalSeconds, endDate: timer.endDate,
                pausedRemaining: !timer.isRunning && !timer.isFinished ? timer.remaining : nil,
                isFinished: timer.isFinished, notificationID: notificationIDs[timer.stepIndex])
        }
    }

    func restore(_ states: [CookSessionTimerState]) {
        cancelAll()
        let now = Date()
        for state in states.prefix(CookingTimerPolicy.maximumTimers) {
            guard state.stepIndex >= 0, state.stepIndex < 10_000,
                  totalSteps <= 0 || state.stepIndex < totalSteps,
                  (1...CookingTimerPolicy.maximumSeconds).contains(state.totalSeconds),
                  timers[state.stepIndex] == nil else { continue }
            let remaining: Int
            if state.isFinished { remaining = 0 }
            else if let end = state.endDate { remaining = CookingTimerPolicy.remaining(until: end, now: now, total: state.totalSeconds) }
            else { remaining = min(state.totalSeconds, max(0, state.pausedRemaining ?? state.totalSeconds)) }
            let timer = StepTimer(stepIndex: state.stepIndex, seconds: state.totalSeconds,
                                  remaining: remaining, isFinished: state.isFinished || remaining == 0)
            timers[state.stepIndex] = timer
            stepTexts[state.stepIndex] = String(state.stepText.prefix(CookingTimerPolicy.maximumTextCharacters))
            // New IDs survive relaunch. Legacy snapshots retain only their exact old step ID.
            if let id = state.notificationID, id.hasPrefix("stocked.step."), UUID(uuidString: String(id.dropFirst("stocked.step.".count))) != nil {
                notificationIDs[state.stepIndex] = id
            } else { notificationIDs[state.stepIndex] = "step_timer_\(state.stepIndex)" }
            if state.endDate != nil, !timer.isFinished,
               timer.start(now: now, restoringDeadline: state.endDate, onFinish: { [weak self] in self?.handleFinished($0) }) {
                scheduleNotification(stepIndex: state.stepIndex)
            } else { cancelNotification(stepIndex: state.stepIndex) }
        }
        updateLiveActivity()
    }

    /// Preserve existing OS requests, but prevent an in-flight permission request
    /// from scheduling a stale timer after this screen/session releases its state.
    func suspendKeepingNotifications() {
        for task in notificationTasks.values { task.cancel() }
        notificationTasks.removeAll(); notificationGenerations.removeAll()
        for timer in timers.values { timer.pause() }
        timers.removeAll(); stepTexts.removeAll(); notificationIDs.removeAll()
        endOwnedLiveActivity()
    }
    func cancelAll() {
        for step in Array(notificationIDs.keys) { cancelNotification(stepIndex: step) }
        for timer in timers.values { timer.pause() }
        timers.removeAll(); stepTexts.removeAll(); notificationIDs.removeAll()
        endOwnedLiveActivity()
    }
    func hasTimer(for stepIndex: Int) -> Bool { timers[stepIndex] != nil }

    private func handleFinished(_ step: Int) {
        HapticManager.success()
        updateLiveActivity(); onStateChange?()
    }
    private func updateLiveActivity() {
        let running = timers.values.filter { $0.isRunning && !$0.isFinished && $0.endDate != nil }
            .min { ($0.endDate!, $0.stepIndex) < ($1.endDate!, $1.stepIndex) }
        guard let running, let end = running.endDate else { endOwnedLiveActivity(); return }
        guard liveStep != running.stepIndex || liveDeadline != end else { return }
        liveStep = running.stepIndex; liveDeadline = end
        LiveActivityManager.shared.start(recipeTitle: recipeTitle, stepNumber: running.stepIndex + 1,
            totalSteps: totalSteps, stepText: stepTexts[running.stepIndex] ?? "", endDate: end, owner: liveOwner)
    }
    private func endOwnedLiveActivity() {
        if liveStep != nil { LiveActivityManager.shared.end(owner: liveOwner) }
        liveStep = nil; liveDeadline = nil
    }

    private func scheduleNotification(stepIndex: Int) {
        notificationTasks[stepIndex]?.cancel()
        let token = UUID(); notificationGenerations[stepIndex] = token
        guard let deadline = timers[stepIndex]?.endDate else { return }
        if let previous = notificationIDs[stepIndex] {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [previous])
        }
        // Each run owns a distinct request: a late add from an old run cannot
        // overwrite or cancel the resumed run's notification.
        let id = "stocked.step.\(UUID().uuidString)"
        notificationIDs[stepIndex] = id
        notificationTasks[stepIndex] = Task { @MainActor [weak self] in
            let center = UNUserNotificationCenter.current()
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound])
                guard let self, !Task.isCancelled, self.notificationGenerations[stepIndex] == token,
                      self.timers[stepIndex]?.isRunning == true, self.timers[stepIndex]?.endDate == deadline else { return }
                guard granted else { self.notificationStatus = "Timer runs here. Enable notifications in Settings for background alerts."; return }
                let seconds = deadline.timeIntervalSinceNow
                guard seconds.isFinite, seconds > 0 else { return }
                let content = UNMutableNotificationContent()
                content.title = "Timer finished"
                content.body = "Step \(stepIndex + 1) — \((self.stepTexts[stepIndex] ?? "").prefix(100))"
                content.sound = .default
                try await center.add(UNNotificationRequest(identifier: id, content: content,
                    trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, seconds), repeats: false)))
                guard !Task.isCancelled, self.notificationGenerations[stepIndex] == token else {
                    center.removePendingNotificationRequests(withIdentifiers: [id])
                    return
                }
                self.notificationStatus = nil
                self.notificationTasks[stepIndex] = nil
            } catch {
                guard let self, !Task.isCancelled, self.notificationGenerations[stepIndex] == token else { return }
                self.notificationStatus = "Timer runs here, but its background alert could not be scheduled."
                self.notificationTasks[stepIndex] = nil
            }
        }
    }
    private func cancelNotification(stepIndex: Int) {
        notificationTasks.removeValue(forKey: stepIndex)?.cancel()
        notificationGenerations[stepIndex] = nil
        if let id = notificationIDs[stepIndex] {
            UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [id])
        }
    }
}
