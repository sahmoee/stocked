import Foundation

/// Presentation only: connectivity and a failed request are different facts.
nonisolated enum HouseholdStatusPresentation {
    static func summary(isOffline: Bool, pending: Int, conflicts: Int, error: String?,
                        isRepairing: Bool = false) -> String {
        if isRepairing { return "Repairing household storage…" }
        if conflicts > 0 { return "\(conflicts) household change\(conflicts == 1 ? " needs" : "s need") review" }
        if isOffline { return "Offline. Your changes are saved on this device." }
        if let error, !error.isEmpty { return "Couldn't sync. Your changes are saved on this device." }
        if pending > 0 { return "\(pending) change\(pending == 1 ? "" : "s") waiting to sync" }
        return "Up to date"
    }
}
