// StoreMutationRecorder.swift
// Pure bookkeeping shared by GuestDataStore's collaborative collection didSets.
import Foundation

nonisolated struct StoreMutationDelta: Sendable, Equatable {
    let oldIDs: Set<UUID>
    let removedIDs: Set<UUID>
    let operations: [(id: UUID, type: HouseholdEntityType, op: HouseholdOperationType)]

    static func == (lhs: StoreMutationDelta, rhs: StoreMutationDelta) -> Bool {
        lhs.oldIDs == rhs.oldIDs && lhs.removedIDs == rhs.removedIDs &&
        lhs.operations.map { "\($0.id.uuidString)|\($0.type.rawValue)|\($0.op.rawValue)" } ==
        rhs.operations.map { "\($0.id.uuidString)|\($0.type.rawValue)|\($0.op.rawValue)" }
    }
}

nonisolated enum StoreMutationRecorder {
    static func delta(oldIDs: Set<UUID>, currentIDs: Set<UUID>, changedIDs: [UUID],
                      entityType: HouseholdEntityType) -> StoreMutationDelta {
        let removed = oldIDs.subtracting(currentIDs)
        var operations = changedIDs.map { id in
            (id: id, type: entityType, op: oldIDs.contains(id) ? HouseholdOperationType.update : .create)
        }
        operations.append(contentsOf: removed.sorted { $0.uuidString < $1.uuidString }
            .map { (id: $0, type: entityType, op: .delete) })
        return StoreMutationDelta(oldIDs: oldIDs, removedIDs: removed, operations: operations)
    }
}
