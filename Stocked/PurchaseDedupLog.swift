// PurchaseDedupLog.swift — RL-007 persisted recent-import history + trip identity.
//
// PurchaseImportLog is the memory PurchaseDedupEngine reasons over: every accepted
// automated import (receipt line, completed shopping-trip line) leaves a small record
// here. Capped at ~200 entries and pruned past 7 days, so it stays a "recent trips"
// log — never a full purchase history (priceHistory already covers spend tracking).
//
// It also owns the shopping-trip identifier (RL-010): a trip started at H-E-B and
// finished at Costco an hour later shares ONE trip id across both store segments,
// so the dedupe engine understands "same trip, different store" — and a later
// receipt scan of either store still matches its segment by store + name + time.
//
// Persistence follows the LocalDatabase per-key JSON pattern used by GuestDataStore;
// the trip id rides in UserDefaults (tiny, settings-shaped).

import Foundation

@Observable
final class PurchaseImportLog {
    static let shared = PurchaseImportLog()

    // MARK: Tuning
    static let maxRecords = 200
    static let retention: TimeInterval = 7 * 24 * 60 * 60
    /// A trip segment completed within this window continues the same trip id; longer
    /// gaps start a new trip. Shorter than the engine's 12h dedupe window on purpose —
    /// morning and evening shopping are different trips, but the engine can still
    /// compare across them.
    static let tripContinuationWindow: TimeInterval = 6 * 60 * 60

    private(set) var records: [PurchaseImportRecord] = []

    private let dbKey            = "purchaseImportLog_v1"
    private let tripIDKey        = "purchaseImportTripID_v1"
    private let tripTouchedAtKey = "purchaseImportTripTouchedAt_v1"

    private init() {
        records = LocalDatabase.shared.loadArray(PurchaseImportRecord.self, key: dbKey) ?? []
        pruneAndPersistIfChanged()
    }

    // MARK: Trip identity

    /// The trip id to stamp on an import happening now. Reuses the active trip when its
    /// last activity is recent (multi-store trips → same id, per-store segments), else
    /// mints a fresh one. Touches the activity timestamp either way.
    func currentTripID(now: Date = Date()) -> String {
        let ud = UserDefaults.standard
        let touched = ud.double(forKey: tripTouchedAtKey)
        var id = ud.string(forKey: tripIDKey) ?? ""
        let stale = touched <= 0 || now.timeIntervalSince1970 - touched > Self.tripContinuationWindow
        if id.isEmpty || stale { id = "trip-" + UUID().uuidString }
        ud.set(id, forKey: tripIDKey)
        ud.set(now.timeIntervalSince1970, forKey: tripTouchedAtKey)
        return id
    }

    /// Store names already logged under a trip id — the trip's store segments, in first-seen
    /// order. Lets callers say "this trip covered H-E-B and Costco".
    func storeSegments(forTrip tripID: String) -> [String] {
        var seen = Set<String>(); var out: [String] = []
        for r in records where r.transactionKey == tripID && !r.store.isEmpty {
            if seen.insert(r.store).inserted { out.append(r.store) }
        }
        return out
    }

    // MARK: Recording

    /// Append accepted imports, then cap + prune. One call per commit keeps the on-disk
    /// rewrite (whole-value store) to a single write per import event.
    func record(_ newRecords: [PurchaseImportRecord]) {
        guard !newRecords.isEmpty else { return }
        records.append(contentsOf: newRecords)
        pruneAndPersistIfChanged(force: true)
    }

    // MARK: Housekeeping

    private func pruneAndPersistIfChanged(force: Bool = false, now: Date = Date()) {
        let before = records.count
        records.removeAll { now.timeIntervalSince($0.importedAt) > Self.retention }
        if records.count > Self.maxRecords {
            // Keep the newest entries; the log is ordered by append time.
            records = Array(records.suffix(Self.maxRecords))
        }
        if force || records.count != before {
            LocalDatabase.shared.save(records, key: dbKey)
        }
    }
}
