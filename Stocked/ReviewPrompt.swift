// ReviewPrompt.swift — Asks for an App Store review after a real kitchen win (a finished cook
// that updated the pantry), never on launch or mid-task. Apple already caps the system prompt at
// three per year; on top of that this only asks after the 3rd and 10th completed cook, and at
// most once per app version.
import StoreKit
import SwiftUI

enum ReviewPrompt {
    static let askAtCompletedCooks: Set<Int> = [3, 10]

    static func cookCompleted(_ requestReview: RequestReviewAction) {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: DBKey.reviewPromptCookCount.rawValue) + 1
        defaults.set(count, forKey: DBKey.reviewPromptCookCount.rawValue)
        guard askAtCompletedCooks.contains(count) else { return }
        let version = BuildConfig.version
        guard defaults.string(forKey: DBKey.reviewPromptLastVersion.rawValue) != version else { return }
        defaults.set(version, forKey: DBKey.reviewPromptLastVersion.rawValue)
        requestReview()
    }
}
