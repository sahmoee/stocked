// xcrun swiftc Stocked/RecipeMigrationSafety.swift Stocked/RecipeImportCommitPolicy.swift scripts/RecipeImportCommitChecks.swift -o /tmp/stocked-import-commit
import Foundation
@main struct RecipeImportCommitChecks {
    static func main() throws {
        var checks = 0
        func check(_ value: Bool) { precondition(value); checks += 1 }
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        let incoming = RecipeMigrationIdentity(id: UUID(), title: "Soup", sourceURL: "https://example.com/soup", contentHash: "raw-source")
        let original = RecipeMigrationIdentity(id: UUID(), title: "Old title", sourceURL: "https://example.com/soup?utm_source=index", contentHash: "older-source")
        let later = RecipeMigrationIdentity(id: UUID(), title: "Renamed", sourceURL: nil, contentHash: "raw-source")
        try RecipeImportCommitPolicy.validate(incoming, existing: [RecipeMigrationIdentity](), approvedDuplicateIDs: [], canEdit: true)
        check(true)
        check(rejects { try RecipeImportCommitPolicy.validate(incoming, existing: [original], approvedDuplicateIDs: [], canEdit: true) })
        try RecipeImportCommitPolicy.validate(incoming, existing: [original], approvedDuplicateIDs: [original.id], canEdit: true)
        check(true)
        check(rejects { try RecipeImportCommitPolicy.validate(incoming, existing: [original, later], approvedDuplicateIDs: [original.id], canEdit: true) })
        check(rejects { try RecipeImportCommitPolicy.validate(incoming, existing: [original], approvedDuplicateIDs: [original.id], canEdit: false) })
        let unrelated = RecipeMigrationIdentity(id: UUID(), title: "Roast", sourceURL: "https://example.com/roast", contentHash: "roast-source")
        try RecipeImportCommitPolicy.validate(incoming, existing: [unrelated], approvedDuplicateIDs: [], canEdit: true)
        check(true)
        print("Private import commit: \(checks) native checks passed (concurrent additions, explicit duplicate consent and revoked permission)")
    }
}
