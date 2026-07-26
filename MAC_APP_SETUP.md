# Stocked for Mac — Setup (Mac Catalyst, same project, same target)

The code side is DONE (`Stocked/MacCatalystSupport.swift` + audit notes inside it).
The Mac app is the SAME app: sync, household editing, recipes (add/edit/import/AI),
images, grocery, planner, cooking, QA — all identical code paths. What remains is
five minutes of checkboxes in Xcode, because target destinations can't be added
safely from outside Xcode.

## 1. Enable the Mac destination (2 clicks)
Xcode → select the **Stocked** target → **General** → *Supported Destinations* →
**+** → **Mac (Mac Catalyst)**.
Leave interface at "Scale to Match iPad" (the app's iPad layout is what the Mac gets;
window minimum is enforced in code at 1000×700).

## 2. Keep the iOS-only pieces iOS-only (2 dropdowns)
The widget and share extensions stay iPhone/iPad (Live Activities and the iOS share
sheet don't apply to the Mac build):
Stocked target → **Build Phases** → **Embed Foundation Extensions** (or Embed App
Extensions) → in the row for **StockedWidgets** set *Platforms* to **iOS**, and the
same for **StockedShareExtension**. (If you don't see a Platforms column, use the
Filter icon at the right of each row.)

## 3. Sandbox + network (1 checkbox)
Enabling Catalyst adds **App Sandbox** to Signing & Capabilities for the Mac build.
Inside App Sandbox, tick **Outgoing Connections (Client)** — without it the Mac app
has no network (worker, sync, images all fail silently).
Camera: if you want barcode scanning on Macs with a camera, also tick **Camera**
under App Sandbox → Hardware.

## 4. Build & run
Scheme destination → **My Mac (Mac Catalyst)** → Run. Sign in with Apple, iCloud
restore, household join/sync, recipe add/edit with photos (PhotosPicker browses the
Mac library and file system), web/social import, receipt photo import — all work.
Barcode live-scan uses the Mac's camera when present; the photo/manual paths cover
the rest.

## 5. Distribution (later)
App Store Connect: the Catalyst build uploads under the same app record with the
"Mac" platform added. Pricing/TestFlight work the same as iOS. If you'd rather not
ship a Mac build yet, the checkbox alternative is App Store Connect → your app →
"Also available on Mac with Apple Silicon" (zero work, runs the iPad app as-is on
M-series Macs) — Catalyst is the better experience, though.

## What was audited (no blockers found)
- ActivityKit (Live Activities): compiles under Catalyst; disabled at runtime by the
  existing `areActivitiesEnabled` guard.
- WidgetCenter reloads: API exists on Catalyst; harmless with the widget embed
  filtered to iOS.
- Haptics (UIImpactFeedback/UINotificationFeedback): silent no-ops on Mac.
- `isIdleTimerDisabled`, UIKit appearance calls, keyboard shortcuts (⌘1–4 already
  implemented in MainTabView), PhotosPicker, AVCapture, CloudKit, UserNotifications:
  all Catalyst-available.
- UIDevice idiom is .pad on Catalyst → the iPad code path renders, which the
  MainTabView architecture already treats as first-class.
