// PersistenceLifecycle.swift
// Keeps the app alive long enough for pending writes to reach disk when it leaves the
// foreground, and tells the user when saving keeps failing instead of only logging it.
import SwiftUI
import UIKit

@MainActor
final class PersistenceLifecycle {
    static let shared = PersistenceLifecycle()
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var lastFailureToast: Date = .distantPast
    private var consecutiveFailures = 0
    /// Owners with a debounced save in flight (e.g. an in-progress cook) register a flush.
    private var pendingFlushes: [ObjectIdentifier: () -> Void] = [:]

    func registerPendingFlush(_ owner: AnyObject, _ flush: @escaping () -> Void) {
        pendingFlushes[ObjectIdentifier(owner)] = flush
    }

    func clearPendingFlush(_ owner: AnyObject) {
        pendingFlushes.removeValue(forKey: ObjectIdentifier(owner))
    }

    /// Runs the in-memory flushes, then asks iOS for background time until the
    /// LocalDatabase queue has written everything. Without this a swipe-away or a
    /// suspension inside the 150 ms write coalescing window loses the last edits.
    func flushForBackground(_ inMemoryFlushes: () -> Void) {
        inMemoryFlushes()
        let flushes = pendingFlushes
        pendingFlushes.removeAll()
        for flush in flushes.values { flush() }
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Stocked save") { [weak self] in
            Task { @MainActor in self?.finish() }
        }
        Task { @MainActor [weak self] in
            await LocalDatabase.shared.flush()
            self?.finish()
        }
    }

    private func finish() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Called from LocalDatabase's write queue (hopped to main). Warns at most once a minute.
    func recordWrite(succeeded: Bool) {
        guard !succeeded else { consecutiveFailures = 0; return }
        consecutiveFailures += 1
        guard consecutiveFailures >= 2, Date().timeIntervalSince(lastFailureToast) > 60 else { return }
        lastFailureToast = Date()
        ToastCenter.shared.warning("Stocked couldn't save your latest changes. Free up some storage, then try again.", duration: 6)
    }
}

/// Lets an overlay-presented form veto MainTabView's tap-outside / swipe-down close while it
/// holds unsaved input; the form then asks "Discard this item?" instead of losing the draft.
@MainActor
@Observable
final class OverlayDismissGuard {
    static let shared = OverlayDismissGuard()
    @ObservationIgnored var interceptor: (() -> Void)?

    /// Returns true when the close was intercepted.
    func intercept() -> Bool {
        guard let interceptor else { return false }
        interceptor()
        return true
    }
}
