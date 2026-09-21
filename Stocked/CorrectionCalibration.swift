import Foundation

/// Local calibration evidence. No raw receipt/photo text belongs in this bounded store.
nonisolated struct CorrectionCalibration {
    enum Kind: String, Codable, Sendable { case itemName, zone, expiry, quantity }
    enum Outcome: String, Codable, Sendable { case accepted, edited, rejected }
    struct Record: Codable, Sendable {
        var predicted: String
        var final: String
        var accepted = 0
        var edited = 0
        var rejected = 0
        var updatedAt = Date()
    }
    static let maximumRecords = 250
    static let maximumText = 512
    static let maximumCounter = 1_000_000
    static let maximumEncodedBytes = 1024 * 1024
    private(set) var records: [String: Record]

    init(records: [String: Record] = [:], now: Date = Date()) {
        self.records = [:]
        for (key, row) in records.sorted(by: { $0.value.updatedAt == $1.value.updatedAt ? $0.key < $1.key : $0.value.updatedAt > $1.value.updatedAt }) {
            guard self.records.count < Self.maximumRecords,
                  key.utf8.count <= Self.maximumText * 4 + 32,
                  let separator = key.firstIndex(of: "|"), Kind(rawValue: String(key[..<separator])) != nil,
                  !key[key.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let clean = Self.repaired(row, now: now) else { continue }
            self.records[key] = clean
        }
    }
    @discardableResult
    mutating func record(kind: Kind, original: String, predicted: String, final: String, outcome: Outcome, now: Date = Date()) -> Bool {
        guard let original = Self.text(original), let predicted = Self.text(predicted), let final = Self.text(final),
              now.timeIntervalSince1970.isFinite else { return false }
        let key = kind.rawValue + "|" + original
        var row = records[key] ?? Record(predicted: predicted, final: final)
        // Evidence from another prediction/correction pair cannot endorse this pair.
        if Self.normalized(row.predicted) != Self.normalized(predicted) || Self.normalized(row.final) != Self.normalized(final) {
            row = Record(predicted: predicted, final: final)
        }
        row.predicted = predicted; row.final = final; row.updatedAt = now
        switch outcome {
        case .accepted: row.accepted = min(Self.maximumCounter, row.accepted + 1)
        case .edited: row.edited = min(Self.maximumCounter, row.edited + 1)
        case .rejected: row.rejected = min(Self.maximumCounter, row.rejected + 1)
        }
        records[key] = row
        if records.count > Self.maximumRecords {
            let keep = records.sorted { $0.value.updatedAt == $1.value.updatedAt ? $0.key < $1.key : $0.value.updatedAt > $1.value.updatedAt }.prefix(Self.maximumRecords)
            records = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        return true
    }
    func confidence(kind: Kind, original: String, predicted: String, base: Double) -> Double {
        let bounded = base.isFinite ? min(1, max(0, base)) : 0
        guard let original = Self.text(original), let predicted = Self.text(predicted),
              let row = records[kind.rawValue + "|" + original],
              Self.normalized(row.predicted) == Self.normalized(predicted) else { return bounded }
        let accepted = Double(row.accepted), corrected = Double(row.edited) + Double(row.rejected)
        let total = max(1, accepted + corrected)
        return min(0.99, max(0.1, bounded + accepted / total * 0.15 - corrected / total * 0.2))
    }
    func promptCorrections(limit: Int = 24) -> [String: String] {
        let limit = min(100, max(0, limit))
        guard limit > 0 else { return [:] }
        let ranked = records.filter { key, row in
            key.hasPrefix(Kind.itemName.rawValue + "|") && row.edited > 0 && row.edited >= row.rejected
                && Self.normalized(row.predicted) != Self.normalized(row.final)
        }.sorted { a, b in
            if a.value.edited != b.value.edited { return a.value.edited > b.value.edited }
            if a.value.rejected != b.value.rejected { return a.value.rejected < b.value.rejected }
            if a.value.updatedAt != b.value.updatedAt { return a.value.updatedAt > b.value.updatedAt }
            return a.key < b.key
        }
        var seen = Set<String>(), result: [String: String] = [:]
        for (_, row) in ranked where result.count < limit {
            guard seen.insert(Self.normalized(row.predicted)).inserted else { continue }
            result[row.predicted] = row.final
        }
        return result
    }
    private static func text(_ raw: String) -> String? {
        guard raw.utf8.count <= maximumText * 4, raw.count <= maximumText else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.subtracting(.whitespacesAndNewlines).contains($0) }) else { return nil }
        return value
    }
    private static func normalized(_ text: String) -> String { text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func repaired(_ row: Record, now: Date) -> Record? {
        guard let predicted = text(row.predicted), let final = text(row.final),
              row.updatedAt.timeIntervalSince1970.isFinite,
              row.updatedAt.timeIntervalSince(now) <= 300 else { return nil }
        return Record(predicted: predicted, final: final,
                      accepted: min(maximumCounter, max(0, row.accepted)),
                      edited: min(maximumCounter, max(0, row.edited)),
                      rejected: min(maximumCounter, max(0, row.rejected)), updatedAt: row.updatedAt)
    }
}
