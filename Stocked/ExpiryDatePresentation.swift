import Foundation

nonisolated enum ExpiryDatePresentation {
    static func reminder(name: String, isEstimated: Bool) -> (title: String, body: String) {
        if isEstimated {
            return ("Estimated use-by reminder", "\(name) has an estimated use-by date of tomorrow. Check the package date.")
        }
        return ("Use-by reminder", "\(name) has a saved use-by date of tomorrow. Check the package date.")
    }

    static func soonSummary(items: String, includesEstimate: Bool) -> String {
        let summary = "Use-by reminders soon for \(items)."
        return includesEstimate ? summary + " Some dates are estimates; check the packages." : summary
    }
}
