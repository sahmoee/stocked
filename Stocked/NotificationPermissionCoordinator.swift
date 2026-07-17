// NotificationPermissionCoordinator.swift — single, presentation-safe permission ask.
//
// System permission UI must never be requested from launch restoration, migrations, or a
// property observer. iOS can queue a request made before the first active key window; the app
// then appears blank while the dialog does not become visible until a later activation.

import Foundation
import UIKit
@preconcurrency import UserNotifications

@MainActor
enum NotificationPermissionCoordinator {

    private static let promptedKey = "didPromptNotificationsOnce_v1"
    private static var promptTask: Task<Void, Never>?

    static var hasPromptedOnce: Bool {
        UserDefaults.standard.bool(forKey: promptedKey)
    }

    /// Called only after onboarding/sign-in completes. The request waits for an active scene
    /// and key window, then gives SwiftUI one additional beat to finish mounting MainTabView.
    static func promptOnceAfterOnboarding() {
        guard !hasPromptedOnce else { return }
        schedulePrompt(initialDelay: 1.5, markOneTimeDecision: true)
    }

    /// Called from an explicit Settings toggle. It still waits for a presentation-ready scene,
    /// but does not add the longer onboarding delay.
    static func promptFromUserAction() {
        schedulePrompt(initialDelay: 0.15, markOneTimeDecision: true)
    }

    private static func schedulePrompt(initialDelay: TimeInterval,
                                       markOneTimeDecision: Bool) {
        promptTask?.cancel()
        promptTask = Task { @MainActor in
            if initialDelay > 0 {
                try? await Task.sleep(for: .seconds(initialDelay))
            }
            guard !Task.isCancelled else { return }

            // Do not ask until UIKit has an active scene and a key window. Retry briefly rather
            // than issuing a request that iOS may park behind launch. If readiness never arrives,
            // leave the marker unset so a later explicit call can retry safely.
            for _ in 0..<40 {
                if canPresentSystemPrompt { break }
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            guard canPresentSystemPrompt else { return }

            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else {
                if markOneTimeDecision {
                    UserDefaults.standard.set(true, forKey: promptedKey)
                }
                return
            }

            // Mark immediately before presenting so repeated state changes cannot enqueue two
            // overlapping system requests. A denied or dismissed system decision still counts
            // as the one automatic onboarding ask.
            if markOneTimeDecision {
                UserDefaults.standard.set(true, forKey: promptedKey)
            }
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    private static var canPresentSystemPrompt: Bool {
        guard UIApplication.shared.applicationState == .active else { return false }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows)
            .contains(where: \.isKeyWindow)
    }

    /// Runs body only when notifications are already authorized (or provisional). It never
    /// requests permission and is therefore safe for launch/background rescheduling.
    static func ifAuthorized(_ body: @escaping @MainActor () -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                Task { @MainActor in body() }
            default:
                break
            }
        }
    }
}
