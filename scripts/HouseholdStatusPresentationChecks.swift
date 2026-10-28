import Foundation

@main struct HouseholdStatusPresentationChecks {
    static func main() {
        func status(offline: Bool = false, pending: Int = 0, conflicts: Int = 0, error: String? = nil, repair: Bool = false) -> String {
            HouseholdStatusPresentation.summary(isOffline: offline, pending: pending, conflicts: conflicts,
                                                error: error, isRepairing: repair)
        }
        precondition(status() == "Up to date")
        precondition(status(pending: 1) == "1 change waiting to sync")
        precondition(status(pending: 3) == "3 changes waiting to sync")
        precondition(status(offline: true).contains("Offline"))
        precondition(!status(error: "Authentication expired").contains("Offline"))
        precondition(status(error: "Authentication expired").contains("saved on this device"))
        precondition(status(conflicts: 1).contains("needs review"))
        precondition(status(conflicts: 2).contains("changes need review"))
        precondition(status(conflicts: 1, error: "error").contains("review"))
        precondition(status(error: "") == "Up to date")
        precondition(status(pending: 3, conflicts: 2, error: "failure", repair: true).hasPrefix("Repairing"))
        print("PASS: 11 household status checks; failure does not invent offline or success state")
    }
}
