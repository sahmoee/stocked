// HouseholdSharingUI.swift
// ─────────────────────────────────────────────────────────────────────────────
// Session 2 of CloudKit household sharing: the pieces that make the SHARE LINK
// path work end to end.
//   1. HouseholdAppDelegate — receives the system callback when the user taps a
//      household share link (userDidAcceptCloudKitShareWith).
//   2. CloudSharingView — wraps UICloudSharingController, the native Messages/Mail
//      invite sheet, shown after creating a household.
//
// Wired in StockedApp via @UIApplicationDelegateAdaptor.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import UIKit
import CloudKit
import UserNotifications
import os

// MARK: - App delegate for share acceptance

final class HouseholdAppDelegate: NSObject, UIApplicationDelegate {

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Register for silent remote notifications so CloudKit can push household changes.
        application.registerForRemoteNotifications()
        // #13 — receive taps on our local reminders so they can deep-link to a screen.
        UNUserNotificationCenter.current().delegate = self
        // #17 — register expiry-reminder action buttons ("Add to Grocery", "Mark Used").
        Task { @MainActor in NotificationActionRegistrar.registerCategories() }
        // #4 — subscribe to MetricKit crash/hang diagnostics (on-device, no SDK).
        DiagnosticsMonitor.shared.start()
        return true
    }

    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Log.transfer.notice("Registered for remote notifications")
    }

    func application(_ application: UIApplication,
                     didFailToRegisterForRemoteNotificationsWithError error: Error) {
        Log.transfer.error("Remote notif registration failed: \(error.localizedDescription, privacy: .public)")
    }

    // A CloudKit household push arrived → pull the latest shared data.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        guard let notification = CKNotification(fromRemoteNotificationDictionary: userInfo),
              notification.subscriptionID?.hasPrefix("household-") == true else {
            completionHandler(.noData); return
        }
        Log.transfer.notice("Household push received")
        Task { @MainActor in
            if let store = HouseholdShareBridge.shared.store {
                await HouseholdCloudKit.shared.handleRemoteNotification(into: store)
                completionHandler(.newData)
            } else {
                completionHandler(.noData)
            }
        }
    }

    // Called when the user accepts a CKShare (taps the invite link). We hand the
    // metadata to the manager, which accepts it and pulls the shared pantry.
    func application(_ application: UIApplication,
                     userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Log.transfer.notice("Received CloudKit share acceptance")
        Task { @MainActor in
            let ok = await HouseholdCloudKit.shared.acceptShare(cloudKitShareMetadata)
            if ok {
                // Adopt the household's shared pantry AND contribute our local items.
                if let store = HouseholdShareBridge.shared.store {
                    await HouseholdCloudKit.shared.migrateLocalIntoHousehold(store: store)
                }
                HouseholdShareBridge.shared.didJoin = true
            }
        }
    }
}

// MARK: - #13 Local-notification tap routing
// The app's local reminders (expiry, "use it up" cook suggestion, daily brief) set a
// userInfo["action"]; when the user taps one, route to the matching screen via
// NotificationCenter so MainTabView can switch tabs / open the right destination.
extension HouseholdAppDelegate: UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        Task { @MainActor in
            // #17 — let the rich-action handler take action buttons + item deep-links first.
            if NotificationActionHandler.handle(response) {
                completionHandler(); return
            }
            // Legacy screen-level routing for notifications without an item payload.
            let action = response.notification.request.content.userInfo["action"] as? String
            switch action {
            case "openCookRightNow":
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.cook)
                NotificationCenter.default.post(name: .stockedOpenCookRightNow, object: nil)
            case "openInventory":
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.inventory)
            case "openMealPlanner":
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.cook)
                // Let the tab switch mount CookHubView before delivering the destination event.
                await Task.yield()
                NotificationCenter.default.post(name: .stockedOpenCookLater, object: nil)
            case "openBrief":
                NotificationCenter.default.post(name: .stockedShowBrief, object: nil)
            default:
                break
            }
            completionHandler()
        }
    }

    // Show banners even while the app is foregrounded, so reminders aren't silently dropped.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

// MARK: - Bridge so the delegate can reach the live data store

// The app delegate has no direct reference to AppSession's store; this lightweight
// bridge is set once at launch so share-accept can merge into the right store.
@MainActor
final class HouseholdShareBridge {
    static let shared = HouseholdShareBridge()
    private init() {}
    weak var store: GuestDataStore?
    var didJoin = false
}

// MARK: - UICloudSharingController wrapper (the invite sheet)

struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowReadWrite, .allowPrivate]
        return controller
    }

    func updateUIViewController(_ uiViewController: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        func cloudSharingController(_ csc: UICloudSharingController,
                                    failedToSaveShareWithError error: Error) {
            Log.transfer.error("Share save failed: \(error.localizedDescription, privacy: .public)")
        }
        func itemTitle(for csc: UICloudSharingController) -> String? {
            "My Stocked. Kitchen"
        }
    }
}
