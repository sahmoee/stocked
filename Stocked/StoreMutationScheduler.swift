// StoreMutationScheduler.swift
// Main-actor debounce coordinator for persistence-adjacent store side effects.
import Foundation

@MainActor
final class StoreMutationScheduler {
    nonisolated enum Key: Hashable, Sendable { case widgetRefresh, householdPush }
    private var tasks: [Key: Task<Void, Never>] = [:]

    func schedule(_ key: Key, delay: Duration,
                  operation: @escaping @MainActor @Sendable () async -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard !Task.isCancelled else { return }
            await operation()
            self?.tasks[key] = nil
        }
    }

    func cancelAll() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}
