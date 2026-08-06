# QA Removal — Restore Guide

**What:** QA was taken out of the shipping app by cutting its two entry points.
All 28 `QA*.swift` / `StockedQAView.swift` files remain in the tree, compiled and
untouched. Nothing was deleted or stubbed. Re-enabling is two pastes.

**Why it's safe:** `QARecorder.shared.isEnabled` can only become true from inside
the QA hub, which is only reachable through the Settings → QA row. With the row
gone, `isEnabled` stays false forever, so every remaining QA hook in live code
(`.qaScreen(...)`, `QARecorder.shared.enteredScreen`, `QAProcessTracker.shared.begin`,
`QABackgroundRunner.shared.runSoon/start`) is a no-op. The window mounts self-gate
too (`QAShakeDetector.sync()` needs `isEnabled`; `QAFloatingButtonWindow.syncFromGate()`
needs `hasEverUnlocked`), so even left in place they would not arm — they were removed
only to keep the root view tree clean.

---

## Restore step 1 — SettingsPageView.swift

Replace the "QA ENTRY REMOVED" comment block (just above `BuildInfoFooter()`) with:

```swift
                    // QA — code-gated release checklist (Checkbook v4.13.69) with the
                    // Worker bridge to the StockedQA companion app. Deliberately last.
                    settingsSectionRow(icon: "checklist", tint: Color.stockedCharcoal,
                                       title: "QA",
                                       subtitle: "Everything QA · testers only") {
                        activeSheet = .qa
                    }
```

(The `.qa` enum case and its `.sheet` arm were left in place — no other change needed here.)

## Restore step 2 — StockedApp.swift

In `RootView`'s root `ZStack`, replace the "QA ENTRY REMOVED" comment block (between
`.allowsHitTesting(true)` and the `HouseholdSyncProgress()` comment) with the eight
mounts below, in this order and with these exact zIndex values:

```swift
            // QA tap counter — a zero-size observer that installs a non-cancelling
            // recognizer on the window, active only in QA mode.
            QATapTracker()
                .zIndex(2400)

            // QA issue reporter — press and hold anywhere while QA mode is on to
            // file a ticket about whatever is on screen. Like QATapTracker, this
            // renders nothing: it installs a long-press recognizer on the window
            // that neither cancels nor delays touches, so the app underneath keeps
            // behaving exactly as it would with QA off. The sheet it presents is
            // the only thing the tester ever sees.
            QAIssueReporter()
                .zIndex(2450)

            // QA heads-up display — opt-in, read-only, cannot be tapped. Off by
            // default even inside QA mode.
            QAHUD()
                .zIndex(2350)

            // QA touch trail (Build 73) — a pure listener recogniser on the window
            // that records where touches land so a report can say what was pressed
            // and the screenshot can ring it. Records nothing while QA mode is off.
            QATouchTrailTracker()
                .zIndex(2410)

            // Live touch rings (Build 73) — off by default, and hosted in a UIWindow
            // ABOVE the level `QAScreenshot` photographs, so turning it on never
            // double-draws a touch into a bug report.
            QATouchOverlayMount()
                .zIndex(2420)

            // CONSOLIDATED (July 2026): the floating QA bubble used to be a second,
            // parallel QA surface with its own subset of controls. Every QA feature
            // now lives in one place — Settings → QA — so there is one
            // screen to learn and one export to send. The reporter and HUD above are
            // deliberately not a return of that bubble: one has no visual presence at
            // all, the other has no touch presence at all.
            //
            // BUILD 73 REVISITS THAT, NARROWLY. What comes back is not the old
            // parallel surface — it is a shortcut to the same single QA screen,
            // available only after the passcode has been entered once. The reason
            // the original was consolidated away was duplication of *controls*;
            // this duplicates none. It exists because the QA screen lives four taps
            // deep inside Settings, which is four taps a tester cannot take while
            // reproducing the thing they are trying to report.
            //
            // Zero-size: it only hands the session to a UIWindow that lives above
            // the app entirely, which is the only way a QA control can sit on top of
            // a sheet, a cover, a popover or an alert.
            QAFloatingButtonMount()
                .zIndex(2460)

            // Shake to report (Build 74) — zero-size, and the only reason it is a
            // view at all is to get a lifetime tied to the app's and a place to
            // watch QA mode and the toggle. The accelerometer only spins while QA
            // mode is on; with QA off this mounts, reads two booleans and does
            // nothing else for the life of the process.
            QAShakeMount()
                .zIndex(2470)
```

## Nothing else

- No pbxproj change (the project uses `PBXFileSystemSynchronized` groups — QA files
  are already compiled in).
- The worker's `/qa/*` routes were NOT touched. They stay deployed and answer as
  before; the app simply never calls them while QA is off.
- `Info.plist`'s `NSUbiquitousContainers` (`iCloud.Stocked`) was left intact — an
  unrelated chat trimmed only the explanatory comment above it, not the keys.
