// SourceHealth.swift
// #6 Per-source reliability tracking. Records success/failure per domain so we can
// rank working sources first and auto-demote ones that keep failing. Persisted to
// UserDefaults; cheap, local, no network.

import Foundation
import os

@MainActor
final class SourceHealth {
    static let shared = SourceHealth()

    private struct Stat: Codable { var success: Int = 0; var failure: Int = 0; var lastFailure: Date? = nil }
    private var stats: [String: Stat] = [:]
    private let key = "sourceHealth_v1"

    private init() { load() }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Stat].self, from: data) {
            stats = decoded
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(stats) { UserDefaults.standard.set(data, forKey: key) }
    }

    func recordSuccess(_ domain: String) {
        var s = stats[domain] ?? Stat(); s.success += 1; stats[domain] = s; persist()
    }
    func recordFailure(_ domain: String) {
        var s = stats[domain] ?? Stat(); s.failure += 1; s.lastFailure = Date(); stats[domain] = s; persist()
        Log.net.debug("Source failure recorded: \(domain, privacy: .public)")
    }

    /// 0…1 reliability score. Unknown sources start optimistic (0.7) so new sources
    /// get a fair chance before being demoted.
    func score(_ domain: String) -> Double {
        guard let s = stats[domain], s.success + s.failure > 0 else { return 0.7 }
        let total = Double(s.success + s.failure)
        var base = Double(s.success) / total
        // Recent failures sting more: decay the score if it failed in the last hour.
        if let last = s.lastFailure, Date().timeIntervalSince(last) < 3600 { base *= 0.6 }
        return base
    }

    /// True if a source has failed enough that it should be skipped for now.
    func isUnhealthy(_ domain: String) -> Bool {
        guard let s = stats[domain], s.failure >= 5 else { return false }
        return score(domain) < 0.2
    }

    /// Sort domains best-first by reliability.
    func ranked(_ domains: [String]) -> [String] {
        domains.sorted { score($0) > score($1) }
    }
}
