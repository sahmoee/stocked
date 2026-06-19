// SyncConflictResolver.swift — #12 Household Sync conflict resolution.
//
// When two devices in a shared household edit the same item, CloudKit can hand back competing
// versions. This file holds a PURE merge policy (no CloudKit dependency, fully unit-testable) so
// the rule is explicit and verified instead of "whichever write happened to land last."
//
// Policy: per-record last-writer-wins by a modification timestamp, with two refinements:
//   • Deletions are tombstoned and win over edits older than the deletion.
//   • Quantities use the most-recent value (not max), matching user expectation that the latest
//     edit reflects reality.
//
// To adopt: have the records you sync expose `id`, `modifiedAt`, and (optionally) `isDeleted`,
// then call SyncConflictResolver.merge(local:remote:) to get the winning set. This file does not
// change any existing type; it operates on a lightweight protocol you can conform models to later.

import Foundation

/// Anything mergeable by this resolver. Conform your synced models to it when wiring sync.
protocol SyncMergeable: Identifiable where ID: Hashable {
    var modifiedAt: Date { get }
    var isDeleted: Bool { get }
}

enum SyncConflictResolver {

    /// Merge two sets of records (e.g. local vs. remote) into the winning set.
    /// - For each id present in either side, the record with the newer `modifiedAt` wins.
    /// - A tombstoned (isDeleted) record removes the item from the result unless a *newer*
    ///   non-deleted edit exists.
    static func merge<T: SyncMergeable>(local: [T], remote: [T]) -> [T] {
        var winners: [T.ID: T] = [:]
        for record in local + remote {
            if let existing = winners[record.id] {
                winners[record.id] = newer(existing, record)
            } else {
                winners[record.id] = record
            }
        }
        // Drop records whose winning version is a tombstone.
        return winners.values.filter { !$0.isDeleted }
    }

    /// The newer of two records by timestamp; ties favor a deletion (safer to converge on removed).
    static func newer<T: SyncMergeable>(_ a: T, _ b: T) -> T {
        if a.modifiedAt == b.modifiedAt {
            return a.isDeleted ? a : b
        }
        return a.modifiedAt > b.modifiedAt ? a : b
    }

    /// Resolve a single id from two optional candidates (e.g. one side doesn't have it).
    static func resolve<T: SyncMergeable>(_ a: T?, _ b: T?) -> T? {
        switch (a, b) {
        case let (x?, y?): return newer(x, y)
        case let (x?, nil): return x
        case let (nil, y?): return y
        case (nil, nil): return nil
        }
    }
}
