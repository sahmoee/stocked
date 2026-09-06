// Native: xcrun swiftc Stocked/RecipeMigrationSafety.swift scripts/RecipeMigrationSafetyChecks.swift -o /tmp/stocked-migration-safety
import Foundation

@main struct RecipeMigrationSafetyChecks {
    static func main() {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) { checks += 1; precondition(value(), label) }
        let existing = RecipeMigrationIdentity(id: UUID(), title: "Crème  Soup", sourceURL: "https://example.com/soup?serves=2", contentHash: "source-one")
        let sameTitle = RecipeMigrationIdentity(id: UUID(), title: " creme\n soup ", sourceURL: nil, contentHash: nil)
        let sameSource = RecipeMigrationIdentity(id: UUID(), title: "Renamed", sourceURL: "https://EXAMPLE.com/soup?serves=2&utm_source=news#recipe", contentHash: nil)
        let unique = RecipeMigrationIdentity(id: UUID(), title: "Roast", sourceURL: nil, contentHash: "hash-two")
        let repeated = RecipeMigrationIdentity(id: UUID(), title: "Another roast", sourceURL: nil, contentHash: "hash-two")
        let sameID = RecipeMigrationIdentity(id: UUID(), title: "Changed title", sourceURL: nil, contentHash: "source-one")
        let reasons = RecipeMigrationSafety.duplicateReasons(incoming: [sameTitle, sameSource, unique, repeated, sameID], existing: [existing])
        check(reasons[sameTitle.id] != nil, "normalized title catches a reimport")
        check(reasons[sameSource.id] != nil, "same source ignores only tracking and fragment")
        check(reasons[unique.id] == nil, "new recipe initially selected")
        check(reasons[repeated.id]?.hasPrefix("Repeated") == true, "in-batch repeated content unselected")
        check(reasons[sameID.id] != nil, "source hash survives renaming")
        let otherQuery = RecipeMigrationIdentity(id: UUID(), title: "Different portion recipe", sourceURL: "https://example.com/soup?serves=4", contentHash: nil)
        check(RecipeMigrationSafety.duplicateReasons(incoming: [otherQuery], existing: [existing]).isEmpty, "meaningful query identity preserved")
        check(RecipeMigrationSafety.duplicateReasons(incoming: [unique], existing: [unique])[unique.id] != nil, "commit recheck catches a concurrent addition")
        let unchanged = UUID(), edited = UUID(), deleted = UUID(), unrelated = UUID()
        let eligible = RecipeMigrationSafety.unchangedAdditionIDs(saved: [unchanged: "a", edited: "b", deleted: "c"], current: [unchanged: "a", edited: "new", unrelated: "other"])
        check(eligible == [unchanged], "undo only removes unchanged additions, never edited/deleted/unrelated records")
        let oldest = UUID()
        var order = [oldest]
        for _ in 0..<250 { order = RecipeMigrationSafety.retainingNewest(order, appending: UUID()) }
        check(order.count == 250 && !order.contains(oldest), "undo history drops only the oldest fingerprint at250")
        let newest = order.last!
        order = RecipeMigrationSafety.retainingNewest(order, appending: newest)
        check(order.count == 250 && order.last == newest && Set(order).count == 250, "retracking an ID keeps a unique deterministic order")
        print("Recipe migration safety: \(checks) native checks passed")
    }
}
