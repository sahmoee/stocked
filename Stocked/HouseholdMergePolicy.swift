// HouseholdMergePolicy.swift
// Pure, deterministic last-write-wins policy shared by the Worker sync client and tests.
import Foundation

nonisolated enum HouseholdMergePolicy {
    /// Millisecond timestamps win first. Equal timestamps are resolved by a stable writer id so
    /// merge order never changes the result. Equal empty ids keep the local value to avoid churn.
    static func remoteWins(remoteUpdatedAt: Double,
                           remoteWriterID: String,
                           localUpdatedAt: Double,
                           localWriterID: String) -> Bool {
        // A NaN/±inf stamp (corrupt row or a buggy peer) compares false against everything,
        // which pinned the record forever (or let +inf beat every future edit). Non-finite
        // stamps rank as "unknown/oldest" so any real edit wins and sync converges.
        let remote = sanitizedTimestamp(remoteUpdatedAt)
        let local = sanitizedTimestamp(localUpdatedAt)
        if remote != local { return remote > local }
        guard remoteWriterID != localWriterID else { return false }
        return remoteWriterID > localWriterID
    }

    /// Returns the larger server revision. Revisions are advisory ordering metadata; entity-level
    /// timestamps still decide individual records.
    static func advancedRevision(local: Int, remote: Int) -> Int { max(local, remote) }

    /// Finite, non-negative milliseconds; anything else is treated as 0 (never edited).
    static func sanitizedTimestamp(_ value: Double) -> Double {
        value.isFinite && value > 0 ? value : 0
    }
}
