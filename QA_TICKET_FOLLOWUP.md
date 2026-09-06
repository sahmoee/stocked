# QA follow-up — September 3, 2026

## Scope and evidence boundary

Reviewed the complete cross-device app ticket collection: **162 records, 10 open** at intake,
including iPhone and iPad reports. Inspected attached ticket thumbnails, not just titles.
Published all ten scoped code-fix resolutions through the existing QA bridge and verified their
status/resolution by read-back. All 162 ticket records remain present; none was deleted or marked verified.
No simulator build/test, device installation, TestFlight upload, Worker deployment or server
deployment was performed in this follow-up. Prior client changes were preserved.

`fixed` means the code correction passed the validation below. **Physical-device verification
is pending** for all ten tickets; none is eligible for `verified` based on this work alone.
An installed phone build is still needed to judge actual drawer animation, layout, memory,
publisher WebKit behavior and watchdog recovery.

## Ticket corrections

| Ticket | Correction / retained implementation |
| --- | --- |
| STK-89-0140 | Cached results now publish in coalesced batches while website discovery runs concurrently. Usable cards no longer stay behind skeletons until networking finishes. |
| STK-89-0141 | One merged, globally sorted list combines downloaded and newly discovered recipes. Counts deduplicate matching canonical identities even outside the visible window. |
| STK-89-0142 | Removed Online/Database search choices and separate source labels. Publisher attribution remains on cards; only availability/offline notices distinguish failed sources. |
| STK-89-0135 | Full catalogue remains available automatically, alongside web discovery. Jamaican specificity, shared strict filters, honest empty states and explicit softer-preference alternatives remain intact. Prior server/Mac discovery-priority work is not redeployed here. |
| STK-89-0009 | Retained gesture-scoped drawer translation; added horizontal-axis guards so vertical scrolling cannot nudge it partially open. Pull-tab hit width is now 44 points. |
| STK-89-0008 | Grocery row text/checkboxes/metadata use semantic text/accent tokens rather than faded gold or fixed charcoal. Increased item/quantity text, wrapped metadata and enlarged row action/quantity controls to 44 points. |
| STK-89-0007 | Shared seven-category filters, removable chips and nine actual-field sorts are implemented; draft sort applies only on Apply. Added dedicated regression coverage. |
| STK-89-0006 | Confirmed Create with Stocked AI is disabled and labelled Coming Soon in hub and Add Recipe routes; implementation retained. |
| STK-89-0130 | Confirmed shared larger Home hero/Stock Level artwork geometry and existing adaptive-layout tests. No unrelated Home redesign. |
| STK-3-0002 | Retained utility-executor Cook classification, immutable revision-gated snapshots and delayed launch QA. Further reduced QA contention by coalescing nudges and cancelling on background; stale/changing runs cannot report clean results. |

Older discovery-priority provenance recorded on STK-89-0135: iOS `f0be9d0`, Mac `957f39e`,
Worker `f946416` / deployed version `36e2a672-5d64-4236-87d1-eba4cc9c61b7`, and the earlier
approved server/cache-bridge deployment. Those earlier deployment validations were not rerun
or represented as new deployments in this follow-up.

## QA infrastructure updates

- Added **80 physical-device checks** in stable appended sections **37–44**, for **350 total checks**: quiz/navigation,
  unified results/loading, dietary/inventory/history, browser, import/recovery, full catalogue
  and cross-device sharing, reported phone regressions, and QA recording/evidence.
- Existing checklist IDs and stored notes/ticket links are preserved. Changed definitions
  require retesting; new optional definition stamps remain backward-decodable.
- **Untested blockers count as open.** A clean invariant suite does not imply the UI is tested.
- Manual and automatic reports now export the same complete checkbook with actual verdicts.
  Automatic reports no longer claim a hardcoded 270 checks or send empty checklist coverage.
- Added 11 small deterministic runtime contract probes, explicitly labelled as fixtures.
  They never fetch websites or mark manual device checks passed.
- Fixed duplicate-identity QA: equal recipe titles are allowed; duplicate stable IDs remain errors.
- Fixed optional-ingredient QA: explicit required/optional flags govern structured ingredients;
  raw text inference is used only when flags are absent. Required ingredients are not silently dropped.
- QA reruns use inventory/recipe/plan/history/catalogue revisions, profile/substitution state
  and time instead of only array counts. Burst nudges coalesce. Background/disabled/cancelled or
  changing snapshots do not publish false clean results.
- Added screen and outcome breadcrumbs for Finder steps/review/results, filter/sort sheets,
  preview, browser navigation/loading/tools/cleanup, import/cancel/review/save. No page HTML,
  clipboard text, credentials or full browsing URLs are recorded by these new hooks.

## Validation

- **126** existing native Finder checks passed (quiz, navigation, filters, sorts, quantities,
  time boundaries, empty results, cancellation).
- **44** new native QA/merge/state checks passed, including the 11 runtime fixture contracts,
  legacy retest policy, sign-off semantics, source/personal identities and early/final result gating.
- **129** native browser/web/catalogue checks passed, plus **2 live publisher checks**.
  The SQLite fixture reaches 8,105 records and verifies paging beyond the 8,000 index.
- **15** production JavaScript extraction/jump checks passed.
- Total: **314 local checks + 2 live checks**. These are not device UI/performance measurements.
- Added **8 XCTest methods**: three unified-service merge checks and five QA integration checks,
  including real optional-flag coverage and complete checklist export. Device-target compilation
  validates these; XCTest execution on a phone remains pending.
- Generic iOS-device `build-for-testing` compiles the application, extensions and test bundle;
  no simulator destination or test run is used. Final log: `/tmp/stocked-qa-delivery-build.log`.
- `git diff --check` and the ticket-publication script syntax check pass.

## Remaining limitations / required phone pass

Web discovery is bounded to supported publishers, not an exhaustive internet index. Strict
combinations can legitimately have no matches; nutrition/allergen-free guarantees are not
invented. First-download and offline searches can only include records available on the device;
the full archive joins through the existing resumable download. Actual latency, long-session
memory behavior, VoiceOver/large-text layout and the reported Pro/Pro Max freezes require
the corrected client on those devices. Use QA-37 through QA-44 and leave unexercised rows untested.
