// CookTimerActivity.swift — shared between the MAIN APP target and the WIDGET target.
// ⚠️ TARGET MEMBERSHIP: tick BOTH "Stocked" and "StockedWidgets" (File Inspector).
// Defines the Live Activity's data shape for the cook-step timer (#16).
import Foundation
import ActivityKit

nonisolated struct CookTimerAttributes: ActivityAttributes {
    // Dynamic — updated as the timer runs.
    public struct ContentState: Codable, Hashable {
        var stepNumber: Int      // 1-based, for display
        var totalSteps: Int
        var stepText: String
        var endDate: Date        // when this step's timer fires; drives the countdown
        var isRunning: Bool
    }
    // Static — set once when the activity starts.
    var recipeTitle: String
}
