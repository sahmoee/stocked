import Foundation

@main struct ExpiryDatePresentationChecks {
    static func main() {
        let estimate = ExpiryDatePresentation.reminder(name: "Milk", isEstimated: true)
        precondition(estimate.title.contains("Estimated"))
        precondition(estimate.body.contains("estimated"))
        precondition(estimate.body.contains("Milk") && estimate.body.contains("tomorrow"))
        precondition(!estimate.body.contains("expires tomorrow"))
        let entered = ExpiryDatePresentation.reminder(name: "Yogurt", isEstimated: false)
        precondition(entered.body.contains("saved use-by date"))
        precondition(!entered.body.contains("printed") && !entered.body.contains("estimated"))
        precondition(ExpiryDatePresentation.soonSummary(items: "Milk and eggs", includesEstimate: true).contains("Some dates are estimates"))
        precondition(!ExpiryDatePresentation.soonSummary(items: "Milk", includesEstimate: false).contains("estimates"))
        print("PASS: 8 expiry wording checks; estimates remain explicit in reminders")
    }
}
