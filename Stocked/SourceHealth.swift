// SourceHealth.swift
// #6 Per-source reliability tracking. Records success/failure per domain so we can
// rank working sources first and auto-demote ones that keep failing. Persisted to
// UserDefaults; cheap, local, no network.

import Foundation
import os

/// Sendable, persistence-independent view of provider reliability. Field reconciliation accepts
/// these snapshots rather than reaching into the main-actor `SourceHealth` store, so receipt and
/// catalog work remains deterministic and testable off the UI actor.
nonisolated struct SourceHealthSnapshot: Codable, Equatable, Sendable {
    var sourceID: String
    var successes: Int
    var failures: Int
    var lastSuccess: Date?
    var lastFailure: Date?
    var averageLatency: TimeInterval?

    init(sourceID: String, successes: Int = 0, failures: Int = 0,
         lastSuccess: Date? = nil, lastFailure: Date? = nil,
         averageLatency: TimeInterval? = nil) {
        self.sourceID = sourceID.lowercased()
        self.successes = max(0, successes)
        self.failures = max(0, failures)
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
        self.averageLatency = averageLatency
    }

    /// 0...1 score with an optimistic prior for unknown sources and a temporary recent-failure
    /// penalty. The small Bayesian prior prevents one lucky request from appearing perfect.
    func reliability(at now: Date = Date()) -> Double {
        let total = successes + failures
        guard total > 0 else { return 0.7 }
        var score = Double(successes + 2) / Double(total + 3)
        if let lastFailure, now.timeIntervalSince(lastFailure) < 3_600,
           (lastSuccess.map({ $0 < lastFailure }) ?? true) {
            score *= 0.6
        }
        if let averageLatency, averageLatency > 5 {
            // Reliability still dominates; very slow sources receive only a bounded 20% demotion
            // so faster healthy fallbacks can run first without declaring the source broken.
            let latencyPenalty = min(0.20, (averageLatency - 5) / 100)
            score *= 1 - latencyPenalty
        }
        return max(0, min(1, score))
    }
}

@MainActor
final class SourceHealth {
    static let shared = SourceHealth()

    private struct Stat: Codable {
        var success: Int = 0
        var failure: Int = 0
        var lastSuccess: Date? = nil
        var lastFailure: Date? = nil
        var averageLatency: TimeInterval? = nil

        private enum CodingKeys: String, CodingKey {
            case success, failure, lastSuccess, lastFailure, averageLatency
        }

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            success = try c.decodeIfPresent(Int.self, forKey: .success) ?? 0
            failure = try c.decodeIfPresent(Int.self, forKey: .failure) ?? 0
            lastSuccess = try c.decodeIfPresent(Date.self, forKey: .lastSuccess)
            lastFailure = try c.decodeIfPresent(Date.self, forKey: .lastFailure)
            averageLatency = try c.decodeIfPresent(TimeInterval.self, forKey: .averageLatency)
        }
    }
    private var stats: [String: Stat] = [:]
    private let key = "sourceHealth_v1"

    private init() { load() }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Stat].self, from: data) {
            stats = decoded.reduce(into: [String: Stat]()) { result, pair in
                let key = normalized(pair.key)
                guard !key.isEmpty else { return }
                var merged = result[key] ?? Stat()
                merged.success += pair.value.success
                merged.failure += pair.value.failure
                merged.lastSuccess = [merged.lastSuccess, pair.value.lastSuccess].compactMap { $0 }.max()
                merged.lastFailure = [merged.lastFailure, pair.value.lastFailure].compactMap { $0 }.max()
                merged.averageLatency = pair.value.averageLatency ?? merged.averageLatency
                result[key] = merged
            }
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(stats) { UserDefaults.standard.set(data, forKey: key) }
    }

    func recordSuccess(_ domain: String) {
        let key = normalized(domain)
        var s = stats[key] ?? Stat()
        s.success += 1
        s.lastSuccess = Date()
        stats[key] = s
        persist()
    }
    func recordFailure(_ domain: String) {
        let key = normalized(domain)
        var s = stats[key] ?? Stat()
        s.failure += 1
        s.lastFailure = Date()
        stats[key] = s
        persist()
        Log.net.debug("Source failure recorded: \(key, privacy: .public)")
    }

    /// Uniform entry point so every source path can log its outcome with one call rather than
    /// branching at each site. Pass whether the fetch succeeded; this routes to the existing
    /// success/failure counters. Adopt this in RecipeAPIClient, SpoonacularClient, barcode, and
    /// the receipt Worker so SourceHealth actually reflects real API behavior.
    func record(_ domain: String, success: Bool, latency: TimeInterval? = nil) {
        success ? recordSuccess(domain) : recordFailure(domain)
        guard let latency, latency >= 0 else { return }
        let key = normalized(domain)
        var stat = stats[key] ?? Stat()
        stat.averageLatency = stat.averageLatency.map { $0 * 0.75 + latency * 0.25 } ?? latency
        stats[key] = stat
        persist()
    }

    /// 0…1 reliability score. Unknown sources start optimistic (0.7) so new sources
    /// get a fair chance before being demoted.
    func score(_ domain: String) -> Double {
        snapshot(for: domain).reliability()
    }

    /// True if a source has failed enough that it should be skipped for now.
    func isUnhealthy(_ domain: String) -> Bool {
        guard let s = stats[normalized(domain)], s.failure >= 5 else { return false }
        return score(domain) < 0.2
    }

    /// Sort domains best-first by reliability.
    func ranked(_ domains: [String]) -> [String] {
        domains.sorted { score($0) > score($1) }
    }

    func snapshot(for domain: String) -> SourceHealthSnapshot {
        let key = normalized(domain)
        guard let stat = stats[key] else { return SourceHealthSnapshot(sourceID: key) }
        return SourceHealthSnapshot(sourceID: key, successes: stat.success, failures: stat.failure,
                                    lastSuccess: stat.lastSuccess, lastFailure: stat.lastFailure,
                                    averageLatency: stat.averageLatency)
    }

    /// Batch form for passing a consistent health view into one reconciliation transaction.
    func snapshots(for domains: [String]? = nil) -> [String: SourceHealthSnapshot] {
        let requested = domains ?? Array(stats.keys)
        let keys = Set(requested.map(normalized).filter { !$0.isEmpty })
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, snapshot(for: $0)) })
    }

    private func normalized(_ domain: String) -> String {
        domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
