// SyncArchitecture.swift
// One place documenting the three intentionally different sync paths in Stocked.
import Foundation

nonisolated enum StockedSyncArchitecture {
    nonisolated enum Path: String, Sendable {
        /// Cross-account household collaboration. Worker JSON + KV, durable local queue/tombstones.
        case workerHousehold
        /// Same Apple-ID pantry handoff through iCloud key-value storage.
        case sharedPantryKVS
        /// Existing CKShare-based screens/records. Active only where explicitly referenced.
        case cloudKitShare
    }

    static let primaryHouseholdPath: Path = .workerHousehold

    static func purpose(of path: Path) -> String {
        switch path {
        case .workerHousehold: return "Cross-account collaborative inventory, grocery, recipes, and plans"
        case .sharedPantryKVS: return "Same-account device synchronization and nudges"
        case .cloudKitShare: return "Explicit CloudKit share workflows still used by legacy household screens"
        }
    }
}
