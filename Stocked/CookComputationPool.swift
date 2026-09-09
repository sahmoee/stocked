import Foundation

/// Overlapping Cook surfaces share one revision's work. A disappearing screen
/// releases only its own request; the last reader cancels the underlying worker.
@MainActor
final class CookComputationPool<Value: Sendable> {
    private struct Entry {
        let id: UUID
        let task: Task<Value?, Never>
        var readers: Set<UUID>
    }

    private var entries: [String: Entry] = [:]

    func value(for key: String,
               start: @MainActor () -> Task<Value?, Never>) async -> Value? {
        guard !Task.isCancelled else { return nil }
        let reader = UUID()
        let entry: Entry
        if var existing = entries[key] {
            existing.readers.insert(reader)
            entries[key] = existing
            entry = existing
        } else {
            entry = Entry(id: UUID(), task: start(), readers: [reader])
            entries[key] = entry
        }

        let result = await withTaskCancellationHandler {
            await entry.task.value
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.release(key: key, entryID: entry.id, reader: reader)
            }
        }
        let acceptsResult = !Task.isCancelled && !entry.task.isCancelled
        release(key: key, entryID: entry.id, reader: reader)
        return acceptsResult ? result : nil
    }

    func cancelAll() {
        for entry in entries.values { entry.task.cancel() }
        entries.removeAll()
    }

    private func release(key: String, entryID: UUID, reader: UUID) {
        guard var entry = entries[key], entry.id == entryID else { return }
        entry.readers.remove(reader)
        if entry.readers.isEmpty {
            entry.task.cancel()
            entries.removeValue(forKey: key)
        } else {
            entries[key] = entry
        }
    }
}
