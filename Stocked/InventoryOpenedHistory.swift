import Foundation
import Observation

nonisolated struct InventoryOpenedRecord: Codable, Sendable, Equatable {
    let inventoryID: UUID
    let openedAt: Date
}

/// Device-local convenience history; deliberately not part of household or backup state.
@MainActor @Observable
final class InventoryOpenedHistory {
    nonisolated deinit {}
    static let shared = InventoryOpenedHistory()
    private(set) var records: [InventoryOpenedRecord]
    private let persistence = FeatureStore<InventoryOpenedRecord>(key: FeatureStoreKeys.inventoryOpened)

    private init() { records = persistence.load() }

    func openedDate(for id: UUID) -> Date? {
        records.first(where: { $0.inventoryID == id })?.openedAt
    }

    @discardableResult
    func markOpened(id: UUID, at date: Date, activeIDs: Set<UUID>) -> Bool {
        guard activeIDs.contains(id), openedDate(for: id) == nil else { return false }
        records = records.filter { activeIDs.contains($0.inventoryID) }
        records.append(InventoryOpenedRecord(inventoryID: id, openedAt: date))
        records = Array(records.suffix(1000))
        persist()
        return true
    }

    func undoOpened(id: UUID, expected: Date) {
        records.removeAll { $0.inventoryID == id && $0.openedAt == expected }
        persist()
    }

    private func persist() {
        persistence.save(records)
        persistence.flush()
    }

    func clear() { records = []; persistence.clear() }
}
