# Stocked — App Store Compliance Reference

This document lists every compliance-relevant item in the Stocked project: what is present,
what each capability requires, and the manual Xcode steps that a zip delivery cannot perform.
Keep it current when capabilities change.

---

## 1. Entitlements (Stocked/Stocked.entitlements)

| Entitlement | Purpose | Portal capability needed |
| --- | --- | --- |
| aps-environment | Push notifications | Push Notifications |
| com.apple.developer.applesignin | Sign in with Apple (a login path) | Sign in with Apple |
| com.apple.developer.healthkit | Write cooked-meal nutrition to Apple Health | HealthKit |
| com.apple.developer.healthkit.background-delivery | Health background delivery | HealthKit |
| com.apple.developer.icloud-container-identifiers | iCloud backups + household sync | iCloud (CloudKit) |
| com.apple.developer.icloud-services | CloudKit services | iCloud (CloudKit) |
| com.apple.developer.ubiquity-container-identifiers | iCloud document container | iCloud |
| com.apple.developer.ubiquity-kvstore-identifier | iCloud key-value store | iCloud |
| com.apple.developer.kernel.increased-memory-limit | Larger memory ceiling | Increased Memory Limit |
| com.apple.developer.user-fonts | Custom fonts | (none) |
| com.apple.developer.usernotifications.time-sensitive | Time-sensitive notifications | Time Sensitive Notifications |
| com.apple.security.application-groups | App Group group.com.sowens.Stocked (widget + share ext + main app) | App Groups |

Share Extension (StockedShareExtension.entitlements) declares only the App Group.

REQUIRED: every entitlement above must have its matching capability enabled for the App ID
in the Apple Developer portal (or via Signing and Capabilities in Xcode). HealthKit in
particular must be enabled there or device builds and archive validation fail.

---

## 2. Info.plist privacy usage strings (all present)

- NSCameraUsageDescription — receipt and barcode scanning
- NSPhotoLibraryUsageDescription / NSPhotoLibraryAddUsageDescription — recipe and receipt photos
- NSLocationWhenInUseUsageDescription — find nearby grocery stores
- NSUserNotificationsUsageDescription — expiry and reminder notifications
- NSHealthShareUsageDescription / NSHealthUpdateUsageDescription — Apple Health nutrition logging

RULE: any API behind an entitlement or usage string requires a purpose string even if the
feature is optional. Rebuilding Info.plist from an old baseline has twice dropped strings and
caused the App Store validation error "Missing purpose string" — always edit the CURRENT
Info.plist and preserve existing keys.

---

## 3. Privacy manifests (PrivacyInfo.xcprivacy)

Apple requires a privacy manifest in every target that calls a required-reason API directly.

Main app (Stocked/PrivacyInfo.xcprivacy) declares:
- Tracking: false; no tracking domains; no advertising identifiers.
- Collected data: Other User Content (inventory/recipe text), Photos or Videos (receipts),
  Health (write-only nutrition), Coarse Location (store finder) — all App Functionality, none
  used for tracking.
- Accessed APIs with reasons: UserDefaults CA92.1, File Timestamp C617.1, Disk Space E174.1.

Share Extension (StockedShareExtension/PrivacyInfo.xcprivacy) declares:
- UserDefaults CA92.1 (it reads and writes the shared App Group to hand content to the app).

MANUAL XCODE STEP (a zip cannot do this): the manifest files must be added to their target's
membership so they ship in the bundle. As of the current project the main manifest is NOT
referenced in the project file, which means it is not being bundled and does nothing. For each
manifest: select the file in Xcode, open the File Inspector, and check the correct target under
Target Membership (Stocked for the app manifest, StockedShareExtension for the extension one).
Confirm by archiving and checking the manifest appears in the app bundle.

---

## 4. Version and build numbers (single source of truth)

The project file (project.pbxproj) is the source of truth: MARKETING_VERSION 4.13 and
CURRENT_PROJECT_VERSION 33 across all six slots (app, widgets, share extension; both configs).

Info.plist now references these via CFBundleShortVersionString equals dollar
MARKETING_VERSION and CFBundleVersion equals dollar CURRENT_PROJECT_VERSION, instead of the
old hardcoded 2.14 and 7 that were overriding the project file and making the version look
stuck. BuildConfig fallbacks are synced to 4.13 and 33 for the in-app footer and What is New.

MANUAL XCODE STEP: remove the "Auto-increment build" Run Script phase (Stocked target, Build
Phases, minus). The auto_increment_build.sh file is removed from the repo, but the build phase
that ran it must be removed by hand or it keeps rewriting the build number. After that, set
Version and Build only in the General tab per release.

---

## 5. Export compliance

ITSAppUsesNonExemptEncryption is set to false in Info.plist. This is correct only if the app
uses just standard HTTPS/TLS (which it does: URLSession to public APIs and the Cloudflare
Worker). If custom or proprietary encryption is ever added, this must change and an export
compliance review may be required.

---

## 6. Background modes

UIBackgroundModes: fetch, remote-notification. These back the daily brief refresh and push
notifications. Both are justified by shipped features; no other background modes are declared.

---

## 7. App Store Connect privacy answers (must match the manifest)

When filling the App Privacy questionnaire, mirror the manifest: data collected is used for
App Functionality only, not for tracking, no third-party advertising, no data brokers.
Receipt, recipe, and inventory text sent to the Cloudflare Worker and Anthropic for AI parsing
is user content used to provide the feature, not linked to identity for tracking.

---

## 8. Login and account (App Review)

Two login paths only: Sign in with Apple, or continue as a guest with a name. Apps offering
third-party sign-in must offer Sign in with Apple (satisfied). Account deletion is available
in-app (Delete Account wipes local data, leaves any household, and forgets the Apple identity
vault), satisfying the account-deletion requirement.
