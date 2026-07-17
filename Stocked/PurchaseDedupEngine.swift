// PurchaseDedupEngine.swift — RL-007 duplicate-purchase protection (pure logic).
//
// The same shopping trip can reach inventory through four doors — completing the
// grocery list, scanning the receipt, scanning barcodes at home, or typing items
// in by hand. Without a cross-door memory, "buy milk → check it off → scan the
// receipt" doubles the milk. This file is the shared, pure "have we already
// imported this purchase?" decision: candidates + the recent import history in,
// per-candidate duplicate flags with human-readable evidence out.
//
// Pure and nonisolated (Sendable DTOs only) so it's unit-testable without the
// session and callable from any actor. Persistence of the history lives in
// PurchaseImportLog (PurchaseDedupLog.swift); the review UX lives in
// PurchaseDedupReviewView.swift. The engine never mutates anything.

import Foundation

// MARK: - Where an import came from

nonisolated enum PurchaseImportSource: String, Codable, Sendable {
    case receipt      = "receipt"
    case shoppingTrip = "shopping-trip"
    case barcode      = "barcode"
    case manual       = "manual"

    /// Short phrase used inside evidence sentences ("…from today's receipt scan").
    var evidenceLabel: String {
        switch self {
        case .receipt:      return "receipt scan"
        case .shoppingTrip: return "shopping trip"
        case .barcode:      return "barcode scan"
        case .manual:       return "manual add"
        }
    }
}

// MARK: - History record (persisted by PurchaseImportLog)

/// One line of a past import: enough detail to recognize the same purchase arriving
/// again through a different door, small enough to keep ~200 of them on disk.
nonisolated struct PurchaseImportRecord: Identifiable, Codable, Sendable, Equatable {
    var id             = UUID()
    var normalizedName: String            // PurchaseDedupEngine.normalizedName(displayName)
    var displayName:    String
    var quantity:       Int     = 1
    var sizeAmount:     Double? = nil     // package size, when known ("14" of "14 oz")
    var sizeUnit:       String? = nil
    var store:          String  = ""      // "" = unknown store
    var barcode:        String? = nil
    var source:         PurchaseImportSource = .manual
    var transactionKey: String  = ""      // shopping-trip / receipt identifier
    var importedAt:     Date    = Date()
}

// MARK: - Candidate awaiting import

/// A line the user is about to import. `id` is the caller's identity for the line
/// (grocery item id, receipt line id) so decisions can be routed back.
nonisolated struct PurchaseImportCandidate: Identifiable, Sendable, Equatable {
    var id:         UUID
    var name:       String
    var quantity:   Int     = 1
    var sizeAmount: Double? = nil
    var sizeUnit:   String? = nil
    var store:      String  = ""
    var barcode:    String? = nil
    var source:     PurchaseImportSource
}

// MARK: - Verdicts

/// What the user chose to do with a flagged candidate.
///  - merge:    same physical purchase — refresh the existing row's details, don't re-count.
///  - keepBoth: a legitimate second purchase — import normally (quantities sum).
///  - skip:     duplicate — the line never enters inventory.
nonisolated enum PurchaseDupResolution: String, Sendable, Equatable {
    case merge, keepBoth, skip
}

/// A likely-duplicate finding for one candidate, with the matched history line and a
/// plain-language explanation the review sheet can show verbatim.
nonisolated struct PurchaseDupFlag: Identifiable, Sendable, Equatable {
    var id: UUID { candidateID }
    let candidateID: UUID
    let matched:     PurchaseImportRecord
    let evidence:    String   // "Already added from today's H-E-B receipt scan, 2h ago"
    let isStrong:    Bool     // same transaction key or same barcode → near-certain
}

// MARK: - Engine

nonisolated enum PurchaseDedupEngine {

    /// How far back a purchase still counts as "the same trip". Long enough to cover
    /// "shopped this morning, scanned the receipt tonight", short enough that a weekly
    /// re-buy of milk is never flagged.
    static let defaultWindow: TimeInterval = 12 * 60 * 60

    /// Canonical comparison key for a product name. FoodNameMatcher folds synonyms and
    /// plurals ("Scallions" == "green onion"); SearchNormalization is the accent/case
    /// fallback for names the matcher reduces to nothing.
    static func normalizedName(_ raw: String) -> String {
        let canon = FoodNameMatcher.normalized(raw)
        return canon.isEmpty ? SearchNormalization.fold(raw) : canon
    }

    /// Deterministic transaction key for an automated import (receipt scan): same store +
    /// same receipt date + same item lines always produce the same key, so re-scanning a
    /// receipt is recognized as *that* receipt, not merely similar shopping. Uses a stable
    /// FNV-1a hash — Swift's Hasher is seeded per-launch and can't be persisted.
    static func transactionKey(store: String, date: Date, itemNames: [String]) -> String {
        let day = Int(date.timeIntervalSince1970 / 86_400)   // calendar-ish bucket, tz-agnostic
        let names = itemNames.map { normalizedName($0) }.sorted().joined(separator: "|")
        return "rcpt-\(SearchNormalization.fold(store))-\(day)-\(stableHash(names))"
    }

    /// Flags likely duplicates among `candidates` against the recent import history.
    /// Returns candidateID → best flag; unflagged candidates are absent from the map.
    static func evaluate(candidates: [PurchaseImportCandidate],
                         history: [PurchaseImportRecord],
                         transactionKey: String = "",
                         now: Date = Date(),
                         window: TimeInterval = defaultWindow) -> [UUID: PurchaseDupFlag] {
        // Only recent history participates; buying milk again next week is not a duplicate.
        let recent = history.filter {
            let age = now.timeIntervalSince($0.importedAt)
            return age >= 0 && age <= window
        }
        guard !recent.isEmpty else { return [:] }

        var flags: [UUID: PurchaseDupFlag] = [:]
        for candidate in candidates {
            let key = normalizedName(candidate.name)
            var best: (flag: PurchaseDupFlag, rank: Int)? = nil

            for record in recent {
                guard let hit = match(candidate, key: key, against: record,
                                      candidateTransactionKey: transactionKey, now: now) else { continue }
                // Prefer the strongest evidence (rank), then the most recent record.
                if let current = best {
                    if hit.rank > current.rank ||
                       (hit.rank == current.rank && record.importedAt > current.flag.matched.importedAt) {
                        best = hit
                    }
                } else {
                    best = hit
                }
            }
            if let best { flags[candidate.id] = best.flag }
        }
        return flags
    }

    // MARK: Single pairwise match

    /// Rank: 3 = same transaction, 2 = same barcode, 1 = same product name (+ store/time).
    private static func match(_ candidate: PurchaseImportCandidate, key: String,
                              against record: PurchaseImportRecord,
                              candidateTransactionKey: String,
                              now: Date) -> (flag: PurchaseDupFlag, rank: Int)? {
        // Stores must agree when both are known — buying eggs at Costco after buying eggs
        // at H-E-B the same day is two real purchases, not a duplicate.
        let cStore = SearchNormalization.fold(candidate.store)
        let rStore = SearchNormalization.fold(record.store)
        let storeCompatible = cStore.isEmpty || rStore.isEmpty || cStore == rStore

        // Names must refer to the same product for every evidence level below.
        let sameName = !key.isEmpty &&
            (key == record.normalizedName || FoodNameMatcher.matches(candidate.name, record.displayName).isConfident)

        // 1. Same transaction: the exact receipt/trip was already imported. This holds even
        //    across a store-name detection hiccup, so it's checked before the store gate.
        if !candidateTransactionKey.isEmpty, candidateTransactionKey == record.transactionKey, sameName {
            let e = "This \(record.source.evidenceLabel) was already imported \(timePhrase(record.importedAt, now: now))\(storeSuffix(record.store))"
            return (PurchaseDupFlag(candidateID: candidate.id, matched: record, evidence: e, isStrong: true), 3)
        }

        guard storeCompatible else { return nil }

        // 2. Same barcode at the same store within the window: near-certain duplicate.
        if let cb = candidate.barcode, let rb = record.barcode, !cb.isEmpty, cb == rb {
            let e = "Same barcode already added \(timePhrase(record.importedAt, now: now)) via \(record.source.evidenceLabel)\(storeSuffix(record.store))"
            return (PurchaseDupFlag(candidateID: candidate.id, matched: record, evidence: e, isStrong: true), 2)
        }

        guard sameName else { return nil }

        // 3. Same product name. Package sizes veto the match when both are known and
        //    clearly different (a 32 oz and a 12 oz are two purchases, not one).
        if let ca = candidate.sizeAmount, let cu = candidate.sizeUnit,
           let ra = record.sizeAmount, let ru = record.sizeUnit,
           let converted = UnitMath.convert(ca, from: cu, to: ru), ra > 0 {
            let ratio = converted / ra
            if ratio > 1.5 || ratio < 0.66 { return nil }
        }

        var detail: [String] = []
        if candidate.quantity == record.quantity { detail.append("same quantity (\(record.quantity))") }
        else { detail.append("qty \(record.quantity) then") }
        if let ra = record.sizeAmount, let ru = record.sizeUnit { detail.append("\(ra.cleanAmount) \(ru)") }
        let e = "Already added from \(dayPhrase(record.importedAt, now: now)) \(record.source.evidenceLabel)\(storeSuffix(record.store)) — \(detail.joined(separator: ", ")), \(timePhrase(record.importedAt, now: now))"
        return (PurchaseDupFlag(candidateID: candidate.id, matched: record, evidence: e, isStrong: false), 1)
    }

    // MARK: Wording helpers (pure)

    private static func storeSuffix(_ store: String) -> String {
        store.isEmpty ? "" : " at \(store)"
    }

    /// "today's" / "yesterday's" — kept to plain interval math so the engine stays
    /// deterministic and calendar-free (the 12h window makes the distinction coarse anyway).
    private static func dayPhrase(_ date: Date, now: Date) -> String {
        now.timeIntervalSince(date) < 18 * 3600 ? "today's" : "yesterday's"
    }

    private static func timePhrase(_ date: Date, now: Date) -> String {
        let mins = max(1, Int(now.timeIntervalSince(date) / 60))
        if mins < 60 { return "\(mins) min ago" }
        let hours = mins / 60
        return hours < 24 ? "\(hours)h ago" : "\(hours / 24)d ago"
    }

    /// Stable FNV-1a 64-bit hash (Swift's Hasher is per-launch seeded → unusable for keys
    /// that must survive relaunch).
    private static func stableHash(_ s: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return String(hash, radix: 36)
    }
}

// MARK: - Tiny formatting convenience

nonisolated private extension Double {
    /// "14" not "14.0"; "1.5" stays "1.5". Local to the engine so we don't collide with
    /// the app-wide `clean` helpers.
    var cleanAmount: String {
        self == rounded() ? String(Int(self)) : String(format: "%.2g", self)
    }
}
