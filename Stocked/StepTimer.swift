import Foundation
import Observation

/// One actor owns the observable timer. A deadline, rather than tick count, owns time.
@MainActor @Observable final class StepTimer {
    let stepIndex: Int
    let totalSeconds: Int
    private(set) var remaining: Int
    private(set) var isRunning = false
    private(set) var isFinished = false
    private(set) var endDate: Date?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()

    init(stepIndex: Int, seconds: Int, remaining: Int? = nil, isFinished: Bool = false) {
        self.stepIndex = stepIndex
        self.totalSeconds = CookingTimerPolicy.validDuration(seconds)
        self.remaining = isFinished ? 0 : min(self.totalSeconds, max(0, remaining ?? self.totalSeconds))
        self.isFinished = isFinished || self.remaining == 0
    }

    @discardableResult
    func start(now: Date = Date(), restoringDeadline: Date? = nil, onFinish: @escaping (Int) -> Void) -> Bool {
        guard !isRunning, !isFinished, remaining > 0, now.timeIntervalSince1970.isFinite else { return false }
        let latestDeadline = now.addingTimeInterval(TimeInterval(remaining))
        if let restoringDeadline {
            guard restoringDeadline.timeIntervalSince1970.isFinite, restoringDeadline > now else { return false }
            // Keep the saved fraction of a second rather than rounding it forward on each restore.
            endDate = min(restoringDeadline, latestDeadline)
        } else { endDate = latestDeadline }
        isRunning = true
        runID = UUID(); let token = runID
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                guard let self, self.runID == token, !Task.isCancelled else { return }
                self.refresh(now: Date())
                if self.isFinished { self.task = nil; onFinish(self.stepIndex); return }
            }
        }
        return true
    }

    func refresh(now: Date = Date()) {
        guard isRunning, let endDate else { return }
        remaining = CookingTimerPolicy.remaining(until: endDate, now: now, total: totalSeconds)
        if remaining == 0 { isRunning = false; isFinished = true; self.endDate = nil }
    }
    func pause(now: Date = Date()) {
        refresh(now: now)
        runID = UUID(); task?.cancel(); task = nil
        isRunning = false; endDate = nil
    }
    func reset() {
        pause(); remaining = totalSeconds; isFinished = totalSeconds == 0
    }
    var displayString: String { CookingTimerPolicy.display(remaining) }
    var progress: Double { totalSeconds == 0 ? 0 : min(1, max(0, 1 - Double(remaining) / Double(totalSeconds))) }
    deinit { task?.cancel() }
}
