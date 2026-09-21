import Foundation

/// Consent applies only to duplicate records actually shown before opening the editor.
/// Recheck the current owner at commit so a later household addition is never overlooked.
nonisolated enum RecipeImportCommitPolicy {
    enum Failure: LocalizedError {
        case permission, duplicate(String)
        var errorDescription: String? {
            switch self {
            case .permission: "Your household role cannot add recipes. Nothing was saved."
            case .duplicate(let title): "Looks familiar: ‘\(title)’ is already saved or was added while you were editing. Nothing was saved. Cancel back to the import review to decide whether you want a separate copy."
            }
        }
    }
    static func validate<S: Sequence>(_ incoming: RecipeMigrationIdentity, existing: S,
                                      approvedDuplicateIDs: Set<UUID>, canEdit: Bool) throws where S.Element == RecipeMigrationIdentity {
        guard canEdit else { throw Failure.permission }
        let keys = incoming.keys
        for current in existing where !approvedDuplicateIDs.contains(current.id) {
            if !keys.isDisjoint(with: current.keys) { throw Failure.duplicate(current.title) }
        }
    }
}
