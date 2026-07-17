// NotificationPermissionCoordinator.swift — single, polite notification permission ask.
//
// WHY: the app previously called UNUserNotificationCenter.requestAuthorization from
// enterKitchen(), signIn(), the notifications toggle, and several scheduler paths. On a
// fresh install (or after an update that re-ran the login gate) the iOS permission dialog
// popped over the app during first launch — while migrations, household sync, image
// backfill and widget refresh were all running — which read as "the app froze with a
// notification stuck on screen".
//
// POLICY (decided 2026-07): ask exactly ONCE, shortly AFTER onboarding completes, once the
// main UI has had a moment to settle. Never ask again at launch. Explicit user actions in
// Settings (enabling a specific reminder) may still surface the system dialog via
// requestAuthorization if — and only if — the status is still .notDetermined.

import Foundation
@preconcurrency import UserNotifications

@MainActor
enum NotificationPermissionCoordinator {

    private static let promptedKey = "didPromptNotificationsOnce_v1"

    /// True once the one-time post-onboarding prompt has been shown (or the user has
    /// already made a decision through any other path).
    static var hasPromptedOnce: Bool {
        UserDefaults.standard.bool(forKey: promptedKey)
    }

    /// Call after onboarding completes (enterKitchen / signIn). Shows the system dialog at
    /// most once per install, ~1.5s after the main UI appears so it never competes with
    /// launch work. Safe to call repeatedly — every subsequent call is a no-op.
    static func promptOnceAfterOnboarding() {
        guard !hasPromptedOnce else { return }
        Task { @MainActor in
            // Let the first frame of the main app render before the dialog appears.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            // If the user already decided (via a Settings toggle or an earlier build),
            // record that and never ask again.
            guard settings.authorizationStatus == .notDetermined else {
                UserDefaults.standard.set(true, forKey: promptedKey)
                return
            }
            UserDefaults.standard.set(true, forKey: promptedKey)
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    /// Runs `body` only when notifications are already authorized (or provisional) —
    /// never triggers the system dialog. Schedulers use this so background rescheduling
    /// can never pop UI.
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
