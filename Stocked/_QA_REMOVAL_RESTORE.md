# QA Removal — Restore Guide

> Restored: the Settings entry and runtime mounts described below were re-enabled.
> This file remains as history for the intentional removal/restoration boundary.

**What:** QA was taken out of the shipping app by (1) cutting its two entry points
and (2) removing the user-facing changelog entries that advertised it. All 28
`QA*.swift` / `StockedQAView.swift` files remain in the tree, compiled and untouched.
Nothing was deleted or stubbed. Re-enabling the tool is two pastes; the changelog
copy is optional to restore.

**Why the entry cut is safe:** `QARecorder.shared.isEnabled` can only become true
from inside the QA hub, which is only reachable through the Settings → QA row. With
the row gone, `isEnabled` stays false forever, so every remaining QA hook in live
code (`.qaScreen(...)`, `QARecorder.shared.enteredScreen`,
`QAProcessTracker.shared.begin`, `QABackgroundRunner.shared.runSoon/start`) is a
no-op. The window mounts self-gate too (`QAShakeDetector.sync()` needs `isEnabled`;
`QAFloatingButtonWindow.syncFromGate()` needs `hasEverUnlocked`), so even left in
place they would not arm — they were removed only to keep the root view tree clean.

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
            // file a ticket about whatever is on screen.
            QAIssueReporter()
                .zIndex(2450)

            // QA heads-up display — opt-in, read-only, cannot be tapped.
            QAHUD()
                .zIndex(2350)

            // QA touch trail (Build 73) — pure listener recogniser on the window.
            QATouchTrailTracker()
                .zIndex(2410)

            // Live touch rings (Build 73) — off by default, hosted above the
            // level QAScreenshot photographs.
            QATouchOverlayMount()
                .zIndex(2420)

            // Floating QA button (Build 73) — shortcut to the single QA screen,
            // available only after the passcode has been entered once.
            QAFloatingButtonMount()
                .zIndex(2460)

            // Shake to report (Build 74) — accelerometer only spins while QA mode is on.
            QAShakeMount()
                .zIndex(2470)
```

(The original had longer explanatory comments on the FloatingButton and Shake mounts;
they are shortened here for the restore. The behaviour is identical — the comment text
was never load-bearing.)

## Restore step 3 (optional) — AppChangelog.swift user-facing copy

Four changelog version blocks were cleaned because they described QA/"testing mode"
to end users, who now cannot reach it:
- **v4.18 (Build 74)** — removed entirely (all 10 entries were QA).
- **v4.17 (Build 73)** — removed entirely (all 6 entries were QA).
- **v4.15 (Build 71)** — removed entirely (all 11 entries were QA, incl. the
  "Press and hold to report a problem" entry).
- **v4.16 (Build 72)** — kept only "Cook Now got dramatically faster"; removed its
  3 QA entries.
- **v4.14 (Build 70)** — kept its 3 real product entries; removed its 3 QA entries
  ("One place for QA", "QA counts that are actually counted", "New process and flow
  tracker").

If QA becomes a shipping feature again, restore this copy from git history
(`git show 9317a94:Stocked/AppChangelog.swift`). It is NOT required for the tool to
work — it is only the What's New text.

## Nothing else

- No pbxproj change (the project uses `PBXFileSystemSynchronized` groups — QA files
  are already compiled in).
- The worker's `/qa/*` routes were NOT touched. They stay deployed and answer as
  before; the app simply never calls them while QA is off.
