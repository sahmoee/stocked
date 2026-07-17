# HANDOFF REPORT

## Summary

Fixed the first-launch blank screen that occurred after installing a new build over an existing Stocked installation. The failure was caused by two one-time launch operations running before the first usable frame:

1. The new-device iCloud restore ran whenever its marker was missing, even when a complete local kitchen already existed after an app update.
2. The SwiftData checkpoint migration performed a full-table fetch for every source record on the main actor, creating quadratic work. Its completion marker explains why force-closing and reopening made the app work normally.

Restored notification preferences also triggered notification authorization during that launch work, allowing iOS to queue the system dialog behind the not-yet-ready scene.

## Files Changed

### Stocked/StockedApp.swift
- Defers the SwiftData checkpoint for three seconds so the main UI renders first.
- Awaits the new cooperative asynchronous migration.

### Stocked/DataMigration.swift
- Changes the migration to async.
- Fetches each SwiftData table once and indexes rows by record ID.
- Replaces O(n²) per-record full-table fetches with O(n) dictionary-backed upserts.
- Yields every 40 records so the main actor can render and process interaction.
- Preserves the non-destructive migration flag and save behavior.

### Stocked/KitchenTransferManager.swift
- Treats iCloud auto-restore as new-device recovery only.
- Skips and seals the restore marker when onboarding, identity, or meaningful local kitchen data already exists.
- Prevents an app update from merging and synchronously flushing the entire kitchen during launch.

### Stocked/AppSession.swift
- Notification preference changes now persist without automatically presenting system UI.
- Adds updateNotificationsEnabledFromUser(_:) for explicit Settings actions.

### Stocked/NotificationPermissionCoordinator.swift
- Waits for an active foreground scene and key window before requesting authorization.
- Coalesces duplicate permission tasks.
- Keeps automatic onboarding requests separate from explicit Settings requests.
- Leaves the marker unset when a presentation-ready scene never becomes available.

### Stocked/GuestDataStore.swift
- Routes legacy notification-permission calls through the central presentation-safe coordinator.

### Stocked/SettingsPageView.swift
- Uses the explicit user-action notification toggle method.

### Stocked/DrawerSettingsContent.swift
- Uses the explicit user-action notification toggle method.

### Stocked/StockedRemoteConfig.swift
- Decodes the Worker's current `{ config, sig, servedAt }` response envelope.
- Retains compatibility with older direct-config responses.
- Caches only the decoded config object.
- Adds a failed-request backoff to stop duplicate launch failure requests/logs.

### StockedWidgets/StockedWidgets.entitlements
- Adds the shared App Group required by WidgetShared.

### Stocked.xcodeproj/project.pbxproj
- Sets all app, widget, and share-extension configurations to Swift 6 language mode.
- Assigns the widget entitlement file to Debug and Release.

## Validation

- Every Swift source file in Stocked, StockedWidgets, and StockedShareExtension passed Swift parser validation.
- All entitlement files passed `plutil -lint`.
- `Stocked.xcodeproj/project.pbxproj` passed `plutil -lint`.
- Delta and full-project archives passed ZIP integrity validation.

A complete Apple-platform compile cannot be run in this container because Xcode and the iOS SDK are unavailable.

## Required Xcode Check

Confirm `group.com.sowens.Stocked` is enabled in Signing & Capabilities for Stocked, StockedWidgets, and StockedShareExtension. Because widget signing entitlements changed, clean the build folder before installing the test build.

## Regression Test

1. Install the previous App Store/TestFlight/development build and create or retain kitchen data.
2. Install the patched build over it without deleting the app.
3. Verify the splash advances into the app and remains responsive.
4. Verify no notification dialog appears during migration or preference restoration.
5. Open Settings and toggle notifications on; the system dialog should appear only after the active app window is visible.
6. Force quit and reopen; no one-time recovery or migration should repeat.
