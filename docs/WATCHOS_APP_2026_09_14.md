# Stocked Apple Watch companion — September 14, 2026

Implemented a native dependent watchOS companion, embedded in the existing iOS app. Stocked on iPhone remains the authoritative kitchen. This document describes implemented workflows and verified code boundaries; it does not claim physical Watch acceptance.

## Wrist workflows

| Area | Implemented on Watch | iPhone continuation / limits |
|---|---|---|
| Grocery | Check/uncheck; add named items; set absolute quantity; confirm removal; show preferred store, package description and queued changes; search and page the full saved list | Additions that match an existing name return a conflict rather than incrementing it. Editable quantities 1–999; saved larger values remain truthful. Scanning, prices and per-item store assignment stay on iPhone. |
| Inventory | Quick add with storage location; list quantity, low stock and expiry; change quantity; move storage; set or clear expiry; search/page; local location filter | Container editing 0–999, addition 1–999. Expiry is user supplied, never a food-safety inference. Scanning, nutrition, sub-zone creation and detailed provenance stay on iPhone. |
| Recipes | Browse/search/page private saved and saved generated recipes; favorite/unfavorite; request full ingredients/instructions on demand; check ingredients; step forward/back; save step position; recognize a step duration and start a local timer | Recipe payloads are bounded. A recipe that cannot fit complete instructions says to continue on iPhone. Public discovery, importing, editing the recipe itself and AI remain on iPhone. Ingredient checks are session local; step position and eight downloaded recipe details survive relaunch. |
| Meals | Browse/search/page the active seven-day plan; add a named meal with date, slot and servings; reschedule a saved meal | Named additions carry no invented ingredient associations. Longer plan-ahead schedules, recipe/ingredient assignment, cooking completion and inventory-consumption review remain on iPhone. |
| Timer | Start, pause, resume, reset or replace one saved timer; countdown uses a deadline; allowed local notifications alert while the app is suspended | Independent of iPhone cooking timers and Live Activities. Maximum 24 hours. Focus, notification authorization and system delivery still apply. Recipe names are not placed in notification text. |
| Tools | Offline compatible-unit conversion and portion multiplier | Reuses iOS UnitMath and strict locale-aware KitchenMath parsing. No guessed density; cooking time does not scale automatically. |
| Connection | Last snapshot date; explicit refresh; pending changes; bounded receipt history; clear downloaded recipes/kitchen only after pending work finishes | Opening a capability that needs iPhone stores a deferred tab request. It asks the user to open Stocked on iPhone; it does not claim to force-launch the phone UI. Sharing control is in iPhone Settings → Data & Storage → Apple Watch. |

Native SwiftUI List, Form, NavigationStack, Toggle, Picker and Stepper controls provide Watch navigation and Crown scrolling. Text uses semantic styles and wrapping. Rejections appear over the active screen; routine sync status does not generate alerts. Existing editors resolve confirmed rows by stable ID, retain drafts and disable unavailable rows. Saves are visibly queued until confirmed.

## Ownership and transport

- Producer and authoritative mutation owner: `Stocked/StockedPhoneWatchBridge.swift`, using `GuestDataStore` permission/timestamp/sync hooks and `LocalDatabase.saveDataDurably`.
- Consumer: `StockedWatch/StockedWatchStore.swift` and `StockedWatchApp.swift`.
- App-specific contract and paired transport: `StockedWatchShared/StockedWatchContract.swift` and `StockedWatchTransport.swift`, compiled in both targets.
- No shared Worker, household-server or other app schema changes. No new API key, backend, package, account credential or hosted AI request.
- WatchConnectivity activates at `AppSession` initialization, before ordinary visible UI is required. Its serial delegate callbacks hop to the main actor before touching stores. iOS deactivation reactivates the session; iPhone sends require an installed paired Watch app.
- Latest snapshots and browse requests use replaceable application context. Reachable messages accelerate delivery. Durable user-info transfers are reserved for mutations and receipts and coalesce outstanding UUIDs. Routine request/error callbacks do not create an unbounded durable request queue.
- The watchOS scene owns `.backgroundTask(.watchConnectivity)` and yields while activation/content delivery drains and main-actor atomic commits finish. Cancellation leaves durable pending work for a later delivery opportunity.

## Command correctness and persistence

The version-1 envelope has an app identity and exactly one payload. Encoded messages are capped at 60 KiB. Strings, arrays, dates, offsets and input numbers have explicit bounds. The snapshot initially requests up to 80 groceries, 60 inventory rows, 30 recipe summaries and 20 meals. Payload reduction may return fewer rows. Pagination advances by the actual delivered count, so reduced payloads do not skip records; search runs across the entire relevant saved collection. Oversized recipe detail is omitted with an explicit continuation message, never silently truncated as complete steps.

The Watch atomically saves its outbox before any mutation is sent. It retains up to 64 operations, rejects overflow visibly and does not evict pending work. Commands use stable UUIDs, absolute quantities/flags, an entity baseline, a kitchen scope and a seven-day lifetime. Expired or retired-scope changes enter visible rejected history. Only eight pending messages are offered per retry pass; an active pending queue retries on a 30-second pace, activation or foreground resume.

The iPhone saves a preparing receipt before applying an operation. New grocery, inventory and meal rows use the command UUID, so a retry cannot create a second additive row. Existing rows must match the captured revision and current household permission. The iPhone serializes the changed collection to its durable store before saving/sending an accepted receipt. Accepted receipts retain the Watch pending overlay until the corresponding authoritative snapshot revision arrives. A crash between preparation and final receipt returns “review” rather than blindly replaying a possibly completed change. This is conservative at-most-once application with visible interrupted outcomes, not a promise of distributed transactions with household servers.

The phone journal retains all live operation IDs, caps at 1,024 receipts and refuses new work rather than forgetting IDs. Only records older than the command lifetime plus one day can be pruned. Watch receipt history is capped at 30. Both devices use separate private Application Support `StockedWatch-v1` files, atomic replacement, bounded reads and protection until first unlock. Files are excluded from backups and are not added to kitchen exports.

## Privacy, reset and compatibility

Only compact kitchen fields go to the paired Watch. Household join codes, authentication tokens, photos, raw imports, API credentials and original documents are not sent. Transport errors and logs do not include private content. Sharing requires an active permitted iPhone kitchen; disabling sharing, signing out or losing view access produces an empty snapshot when delivery resumes.

A scope combines the phone's locally hashed household/member/account identity, sharing state and an explicit reset epoch. Clear All and native restore/rollback must durably retire the epoch before mutating kitchen records. A failed retirement stops the reset, reports a warning and retains identity/data. `GuestDataStore.clearAll()` now returns a Bool; the two AppSession callers check it. The public `signOut(clearData:)` interface remains unchanged and its internal result also gates account deletion. Backup restore keeps its existing throwing interface and reports the retirement error without applying data.

Same-scope snapshots must increase revision. A different scope is adopted only through a correlated current refresh nonce; delayed pre-reset application context cannot restore the former kitchen. The first empty Watch can accept its initial paired snapshot. Old queued operations fail scope checks after clear/restore, household/account changes or disabled sharing.

The contract is additive and local. Existing iOS kitchen records, household payloads, backups, provider configuration and prior code-pass work remain compatible. A Watch schema mismatch or corrupt private saved file pauses changes instead of treating it as an empty successful load. Recovery instructions are to update both app versions, reconnect/reopen both apps, and review any interrupted receipt on iPhone. Storage corruption that cannot be read requires removal/reinstallation of the companion or explicit future repair tooling; that has not been silently automated. Retained offline copies remain visible until the Watch receives a disabling/reset snapshot, as with any disconnected device.

## Targets, packaging and rollout

- `StockedWatch` is a modern single application target and a shared scheme.
- Watch bundle ID: `com.sowens.Stocked.watchkitapp`; companion ID: `com.sowens.Stocked`.
- watchOS minimum 26.0, family 4; dependent on its iPhone companion.
- iOS embeds `Watch/StockedWatch.app` with a target dependency. Version 5 and QA build stamps align with the iOS app and extensions.
- App icon reuses the approved `Brand/Stocked-AppIcon-Master.png` as the Watch asset catalog's 1024-pixel source.
- Install the matching iOS+Watch package together after device review. There is no Worker/Jarvis deployment or external rollout order.

## Validation

- **87 native checks passed** in `scripts/StockedWatchChecks.swift`: command and date validation; envelope isolation and size; epoch/nonce/revision ordering; queue/journal capacity and no eviction; interrupted intents and idempotency; accepted receipt/snapshot ordering; disk bounds/corruption/failed replacement; failed reset retirement; multibyte payload pagination; localized decimal parsing. Fixtures use isolated temporary directories and never mutate real kitchen data.
- **Generic physical watchOS build succeeded**, followed by the final **generic iOS build 5 (255)**, which rebuilt and embedded the current Watch app and both existing iOS extensions. All four built bundles report version 5/build 255. The companion ID, family 4, watchOS26 minimum, dependency flag, native Watch binary and AppIcon asset catalog were inspected. An earlier standalone Watch scheme build was 5 (254).
- Build artifacts reused `/Volumes/Macintosh SSD/MacStorage/Developer/DerivedData/Stocked-Polish-20260914`. Logs: `/tmp/stocked-watch-build.log` and `/tmp/stocked-watch-ios-build.log`. Both builds used `CODE_SIGNING_ALLOWED=NO`; no simulator was started and no device was installed or controlled.
- Final iOS build retains pre-existing concurrency warnings in `SpotlightIndexer.swift` and `ShelfScanView.swift`; no new Watch source error remains. These warnings are outside this companion implementation and are not described as fixed.
- `QAFeatureCoverage` section 58 adds 15 stable physical-device journeys covering pairing, mutation parity, paging, offline/retry/reset/failure, suspension, timer delivery, accessibility and deferred continuation. These remain **untested blockers**; native checks and compilation do not mark them passed.
- New Watch target's metadata extraction warning says no AppIntents framework dependency was found; this companion does not declare AppIntents or complications. No complication or remote iPhone-timer parity is claimed.
