// AICorrectionStore.swift
// Local confidence calibration from accepted, edited, and rejected AI suggestions.
import Foundation

@MainActor
final class AICorrectionStore {
    static let shared = AICorrectionStore()

    nonisolated enum Kind: String, Codable, Sendable { case itemName, zone, expiry, quantity }
    nonisolated enum Outcome: String, Codable, Sendable { case accepted, edited, rejected }

    nonisolated private struct Record: Codable, Sendable {
        var predicted: String
        var final: String
        var accepted: Int = 0
        var edited: Int = 0
        var rejected: Int = 0
        var updatedAt: Date = Date()
    }

    private let key = "aiCorrectionCalibration_v1"
    private var records: [String: Record] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Record].self, from: data) { records = decoded }
    }

    func record(kind: Kind, original: String, predicted: String, final: String, outcome: Outcome) {
        let k = keyFor(kind: kind, original: original)
        var row = records[k] ?? Record(predicted: predicted, final: final)
        row.predicted = predicted; row.final = final; row.updatedAt = Date()
        switch outcome { case .accepted: row.accepted += 1; case .edited: row.edited += 1; case .rejected: row.rejected += 1 }
        records[k] = row
        if records.count > 250 {
            records = Dictionary(uniqueKeysWithValues: records.sorted { $0.value.updatedAt > $1.value.updatedAt }.prefix(250))
        }
        if let data = try? JSONEncoder().encode(records) { UserDefaults.standard.set(data, forKey: key) }
    }

    func promptCorrections(limit: Int = 24) -> [String: String] {
        let useful = records.values
            .filter { $0.edited > 0 && $0.edited >= $0.rejected }
            .sorted { ($0.edited + $0.accepted) > ($1.edited + $1.accepted) }
            .prefix(limit)
        return useful.reduce(into: [String: String]()) { result, row in
            result[row.predicted] = row.final
        }
    }

    func adjustedConfidence(kind: Kind, original: String, predicted: String, base: Double) -> Double {
        guard let row = records[keyFor(kind: kind, original: original)] else { return base }
        let total = max(1, row.accepted + row.edited + row.rejected)
        let support = Double(row.accepted) / Double(total)
        let penalty = Double(row.rejected + row.edited) / Double(total)
        return max(0.1, min(0.99, base + support * 0.15 - penalty * 0.2))
    }

    private func keyFor(kind: Kind, original: String) -> String {
        kind.rawValue + "|" + FoodNameMatcher.normalized(original)
    }
}
