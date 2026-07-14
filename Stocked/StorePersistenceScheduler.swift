// StorePersistenceScheduler.swift
// Main-actor coalescing for GuestDataStore persistence without mixing timer state into the store.
import Foundation

@MainActor
final class StorePersistenceScheduler {
    private var pending: [String: @MainActor () -> Void] = [:]
    private var flushTask: Task<Void, Never>?

    func schedule(key: String, delay: Duration = .milliseconds(250),
                  persist: @escaping @MainActor () -> Void) {
        pending[key] = persist
        flushTask?.cancel()
        flushTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.flush()
        }
    }

    func flush() {
        flushTask?.cancel()
        flushTask = nil
        let work = pending
        pending.removeAll()
        for key in work.keys.sorted() { work[key]?() }
    }

    func cancel() {
        flushTask?.cancel()
        flushTask = nil
        pending.removeAll()
    }
}
