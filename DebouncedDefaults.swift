// DebouncedDefaults.swift
// #11 perf: slider-driven settings (sizes, offsets, positions) fire their didSet on every
// value change while dragging — dozens of synchronous UserDefaults writes per gesture.
// This coalesces rapid writes to the same key, persisting only the last value after a
// short idle, so dragging a slider doesn't hammer disk. Non-slider settings keep writing
// immediately (no behavior change there).

import Foundation

@MainActor
final class DebouncedDefaults {
    static let shared = DebouncedDefaults()

    private var pending: [String: Any] = [:]
    private var timers: [String: Task<Void, Never>] = [:]
    private let delay: UInt64 = 350_000_000   // 0.35s idle before the write lands

    private init() {}

    /// Coalesced write: remembers the latest value for `key` and flushes after a brief idle.
    func set(_ value: Any, forKey key: String) {
        pending[key] = value
        timers[key]?.cancel()
        timers[key] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: self?.delay ?? 350_000_000)
            guard !Task.isCancelled, let self else { return }
            if let v = self.pending.removeValue(forKey: key) {
                UserDefaults.standard.set(v, forKey: key)
            }
            self.timers.removeValue(forKey: key)
        }
    }

    /// Force any pending writes to disk immediately (e.g. on background/terminate).
    func flushAll() {
        for (key, value) in pending {
            timers[key]?.cancel()
            UserDefaults.standard.set(value, forKey: key)
        }
        pending.removeAll()
        timers.removeAll()
    }
}
