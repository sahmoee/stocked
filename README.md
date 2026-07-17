# Stocked Delta — QA Removal (2026-07-17)

The QA Workbook idea is scrapped. This delta removes every trace of it from the app.

## Apply
1. Copy the three files in `Stocked/` over the repo's files (full replacements).
2. Run `remove_qa_files.command` (or delete these 7 files by hand):
   `Stocked/QAChangeLog.swift`, `QAFeedback.swift`, `QAFloatingOverlay.swift`,
   `QAWorkbook.swift`, `QAWorkbookTheme.swift`, `QAWorkbookViews.swift`,
   `QAWorkbookContent.json`
3. Rebuild. No pbxproj edits needed (synchronized folders).

## What changed
- `StockedApp.swift` — removed the QAFloatingOverlay layer from RootView.
- `SettingsPageView.swift` — removed the hidden "QA" row, the access-code alert, and
  its two @State vars.
- `HouseholdSync.swift` — removed the QA blob from household push/pull. (Households
  that already synced a `qa` blob just carry a small inert field server-side; nothing
  reads or writes it anymore. No Worker change needed.)

Verified: zero remaining references to QAWorkbook/QAFeedback/QAChangeLog/QAFloatingOverlay
anywhere in the app, widgets, share extension, or tests.

Also included: `PLATFORM_ROLES.md` — recommended division of labor across Netlify,
Namecheap, GitHub, the Cloudflare Worker, and Build Buddy.
