# QA identity, autonomy, completed tickets and build numbering

Implemented September 3, 2026. Earlier Recipe Hub, web browser/import and ticket fixes remain in
place; this batch adds QA ownership/lifecycle behavior and build-only automation.

## Stocked QA changes

- `QAIdentityCore.swift` / `QAIdentityStore.swift`: per-installation Key/Shalise selection; exact
  hardware model, iPhone/iPad family, simulator flag and random QA-specific device identifier.
  Device mapping was checked against [DeviceKit's primary identifier table](https://github.com/devicekit/DeviceKit/blob/master/Source/Device.generated.swift).
  Unknown identifiers remain visible instead of guessing a model. A local-only vendor token detects
  a backup restored onto another device; the vendor token is never uploaded.
- The QA home screen and report composer expose tester selection. Ticket list filtering supports
  tester and device family; ticket detail permits explicit attribution of an old report. Old reports
  remain unassigned and never inherit the editing device's hardware. Runs, diagnostic exports,
  tickets, folder handoffs and search include captured identity where available.
- New ticket numbers include an installation suffix so two offline devices cannot reuse the same
  build/sequence number. New report fields are optional on persisted and remote legacy records.
- `fixed` is displayed as **Completed** and is excluded from default active work, counters and
  blocker lists unless manual review is required. Completed history stays available. Explicitly
  choosing a completed status turns on completed-ticket visibility.
- Linked failed/blocked checklist rows derive **Resolved**, not Pass. Their original stored verdict,
  notes and links survive, including note edits, so refiling or a fresh regression restores the
  active failure. Untested checks and actual device passes are not rewritten.
- Same-origin automatic findings have stable check IDs. A fresh recurrence can reopen a completed
  automatic ticket without losing its original report/resolution. Historical cached failures do not
  reopen tickets, and shipped-resolution repair cannot close a refile/regression again.
- Repeated findings update the retained screenshot instead of writing an orphan attachment for a
  discarded duplicate. New critical findings/regressions get priority within the three-ticket budget.
- Enabling QA after launching with QA off now starts the runner without a relaunch. The app retains
  a weak store reference while QA is off; no checks run until enabled. Removed the independent delayed
  publisher that could outlive an Auto-publish preference change or duplicate a new session.
- Read-only full diagnostics run automatically on a ten-minute foreground cadence, reuse the fresh
  invariant snapshot and reject stale/cancelled results. New, unattempted queued reports are Pending,
  not self-generated delivery-failure tickets; only current failed attempts justify that finding.
- Accessibility sweeps debounce navigation, skip QA overlays and active cooking, and cap automatic
  work at 8 ms. Partial scans never claim a pass. Two fresh complete observations are needed before
  filing a possible accessibility issue for manual review. This does not replace VoiceOver testing.
- Folder-size inspection is off-main and bounded to 2,000 entries/250 ms. All checks retain the
  existing QA gate, foreground/cooking deferral, cancellation and explicit Auto-publish preference.
- Section 45 adds 12 device checks. The checkbook now contains **362 checks**, including 92 appended
  recipe/browser/QA checks; none were automatically marked as a physical-device pass.

## Build automation scope

Stocked, Atlas, Nova (iOS and tvOS), The SESH and ReelPromo-iOS now use shared-scheme pre-actions and
sandboxed per-target plist stamping. Mac-only projects remain excluded. Stocked owns the identical
script vendored into the other four repositories. Public versions remain manual, and Nova's old
script no longer increments MARKETING_VERSION. TestFlight wrappers no longer double-bump builds.
ReelPromo now reads its manually set version from Xcode instead of a hardcoded Info.plist value.

See `scripts/QA_BUILD_NUMBER.md` for locking, failed-build gaps, direct-target limitations and
the intermediate Xcode embedded-version warning observed during validation. Final app/extension
metadata is checked independently. No app sandbox or signing entitlement was weakened.

## Shared compatibility and rollout

UnifiedWorker owns the QA envelope merge; Stocked is the new identity producer and all released
app clients remain compatible consumers. The Worker patch preserves omitted identity, check/run,
origin, regression and manual-review fields when an older client edits a ticket. Explicit newer
values/nulls still win. Family summaries remain available, with additive model/tester counts.
It does not change QA authentication, app scoping, household data or stored recipe records.

The Worker patch is tested locally and **awaits deployment approval**. Roll out that compatibility
patch before installing the updated Stocked client. No migration or legacy ownership guessing is
required. Existing optional-field behavior remains the fallback; production has not been deployed
as part of this QA-identity batch.

## Verification

| Check | Result |
| --- | --- |
| Native identity/lifecycle conditions | 58 passed |
| Native QA feature/coverage conditions | 44 passed |
| Native Find a Recipe conditions | 126 passed |
| Native browser/pagination/SQLite conditions | 129 passed |
| Browser JavaScript conditions | 15 passed |
| Build numbering fixture tests | 7 passed in each of the 5 repositories |
| Worker test suite, including old-client identity preservation | 86 passed |
| Worker type-check and deployment dry-run | Passed; not deployed |
| QA capability parity audit | All 5 iOS projects passed the static audit |
| Stocked generic-iOS test-bundle compilation | Passed; app/share/widget/tests share one integer, version 5 unchanged |
| Atlas, Nova iOS, The SESH and ReelPromo generic-iOS builds | Passed; final app/extension build values agree |
| Nova generic-tvOS build | Passed; build 39, version 1.7 unchanged |
| ReelPromo unsigned local archive | Passed; archive and app both build 3, version 1.0 unchanged |
| Swift XCTest additions | 4 identity/wire/lifecycle tests compiled; not executed on a device |
| Simulator builds/tests, device installs, TestFlight upload | Not performed |

The build tests cover same-build stamping, marketing-version preservation, dotted-build migration,
concurrent reservations, restoring an older checkout, per-DerivedData reservations, and failure on
a missing reservation. Wire tests cover captured-device preservation, legacy decoding, manual-review
completion and resolved-versus-passed semantics. Existing compiler/toolchain warnings are not claimed
as resolved. Code compilation is not UI, VoiceOver, performance or signing verification.

## Remaining device setup and checks

On each phone and iPad, select **Key** or **Shalise** in QA → Tester and device after installing the
updated app. Confirm the displayed hardware and separate QA device IDs. Exercise first-enable,
report creation, cross-device sync, completed/history filtering, manual review and refiling on both
device families. Real-device UI, VoiceOver, freeze/memory behavior and signed distribution remain
manual checks. Simulator validation stays paused unless explicitly approved.
