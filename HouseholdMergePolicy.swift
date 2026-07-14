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
        if remoteUpdatedAt != localUpdatedAt { return remoteUpdatedAt > localUpdatedAt }
        guard remoteWriterID != localWriterID else { return false }
        return remoteWriterID > localWriterID
    }

    /// Returns the larger server revision. Revisions are advisory ordering metadata; entity-level
    /// timestamps still decide individual records.
    static func advancedRevision(local: Int, remote: Int) -> Int { max(local, remote) }
}
