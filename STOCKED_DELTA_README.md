# Stocked — Build Buddy Delta (2026-07-17)

One cumulative delta. Every file in this package is either **new** or a **full
replacement** for the file at the same repo-relative path. Drop the contents over the
repo root (`Stocked 2/`). New Swift files land in `Stocked/` (synchronized folders —
Xcode picks them up automatically; no `project.pbxproj` edits anywhere in this delta).

Covers: (1) everything beneficial moved to the Worker, (2) 10 app+worker improvements,
(3) 10 worker improvements, (4) the launch lag/freeze root-cause fixes including the
notification popping up and getting stuck at open/install/update, (5) full
implementation of spec items RL-001 through RL-010.

---

## 1 · Lag / freeze root causes found and fixed

**A. Store-load didSet cascade (the big one).** `GuestDataStore.load()` runs at launch
and assigns every collection; each assignment fired its full `didSet` pipeline —
updatedAt stamping, tombstone diffing, household op enqueue + activity events, iCloud
push, debounced re-save of data just read from disk, widget refresh, low-stock→grocery
sync — all on the main actor during first frame. A new `isLoadingFromDisk` guard makes
hydration side-effect free (cache invalidation only). (`GuestDataStore.swift`)

**B. Notification permission dialog over the first frame.** `enterKitchen()` and
`signIn()` called `requestAuthorization` immediately, so on first open after
install/update the iOS dialog popped over the app while sync/migrations/backfills ran
behind it — reads as "frozen with a stuck notification". Now: one deferred ask, ~1.5s
after onboarding completes, exactly once per install (`NotificationPermissionCoordinator.swift`,
`AppSession.swift`). All schedulers (`DailyBriefNotificationManager`) can no longer
trigger the dialog — they run only when already authorized. Explicit Settings toggles
still can, but only when status is `.notDetermined` (never a re-prompt).

**C. "Kitchen Alert" banner over the app ~2s after opening.** Inventory load scheduled a
`lowStock` notification with a 2-second trigger, and the delegate's `willPresent`
answered `[.banner, .sound]` for everything — so it slid over Home on almost every
launch (and daily-brief/expiry reminders bannered mid-use too). Routine reminders are
now silent in the foreground (they land in Notification Center); cook-timer alerts still
banner. (`HouseholdSharingUI.swift`) The launch-time trigger itself is also gone via fix A.

**D. First-frame maintenance work.** Notification rescheduling + widget refresh ran on
the main tab's first frame (`MainTabView.task`) and image/nutrition backfills started in
`RootView.onAppear`. Both deferred 3–4s. Expiry reminders are capped to the 40 soonest
(iOS drops everything past 64 pending — a big pantry silently killed timers/brief).

## 2 · Moved to the Worker (app + worker)

- **AI**: the direct Anthropic path is deleted from the app (`ClaudeAPIKey/URL/Model`
  removed from `BuildConfig.swift`, `Info.plist`, `Secrets.example.xcconfig`). All AI
  goes through the Worker (key server-side, validation, rate limits, fallback model).
- **Barcodes**: scans now hit `POST /barcodes/resolve` first (real product DBs,
  30-day edge cache, 24h negative cache, optional retailer price) with the on-device
  waterfall (OFF → USDA → cache → UPCItemDB → AI) kept as fallback.
  (`WorkerBarcodeResolver.swift`, `BarcodeScannerView.swift`)
- **Curated content off cPanel**: `GET /content/recipes` (+ `/content/img/*`) proxies
  the cdn.sowensstudios.com origin behind Cloudflare's edge (6h cache, ETag/304,
  stale-on-error). App prefers the Worker, falls back to the cdn URL.
  (`stocked-receipt-worker/src/content.js`, `RemoteContentClient.swift`)
- **Remote configuration**: app adopts `GET /configuration` — kill switches (checked
  centrally in `StockedWorkerClient` per route + umbrella `allAI`), disabled recipe
  sources, maintenance banner, min-supported-version banner. ETag-revalidated, 15-min
  foreground throttle, persisted for offline, fails open.
  (`StockedRemoteConfig.swift`, `StockedApp.swift`)
- **Support diagnostics**: privacy-scrubbed snapshot (counts/versions/sync health —
  never item or recipe names) uploads to `POST /support/diagnostics`; the returned
  `STK-…` reference shows in Sync Diagnostics. (`StockedDiagnosticsUploader.swift`,
  `SyncDiagnosticsView.swift`)

## 3 · Ten app + worker improvements (all implemented)

1. Remote kill switches / maintenance / forced-update adoption in-app (change app
   behavior with a KV edit, no App Store release).
2. Worker-first barcode resolution — accurate DB data instead of AI guesses, no
   third-party keys or quota on device.
3. One-tap support diagnostics with reference number.
4. Curated content served from Cloudflare edge with ETag/304 (cPanel origin retired
   from the hot path).
5. Durable offline mutation queue with stable op ids + reconnect replay (app) matched
   by idempotent dedupe in the household Durable Object (worker) — RL-008.
6. Session-keyed rate limiting: valid `X-Stocked-Session` users are limited per
   account, not per shared IP (worker), using the session tokens the app already sends.
7. Household activity events now carry stable `eventId`s; failed posts queue and replay
   instead of dropping (app) and replays dedupe server-side (worker).
8. Social recipe links import through the same Worker `recipeImport` route as web
   imports, with preview + uncertain-field review — RL-009.
9. Purchase/receipt duplicate protection spanning all input methods, with trip
   identifiers automated imports attach — RL-007 (pairs with the worker receipt routes).
10. Prompt caching + KV-tunable models/max-token limits on all AI routes — lower
    latency and Anthropic cost for every AI feature in the app.

## 4 · Ten worker improvements (all implemented, contract-preserving)

1. ETag/If-None-Match 304s on `/configuration` (+ all `/content` routes).
2. 24h negative-result caching on `/barcodes/resolve` (30d positive kept).
3. Consistent error envelope `{error, code, requestId}` on every non-2xx; `Retry-After`
   on every 429.
4. Input validation with stable 422 codes for barcodes/prices/diagnostics/daily-brief.
5. Household push idempotency: content-hash dedupe window in the DO (safe retries
   return the same success without re-merging).
6. `/recipes/discover` stale-while-revalidate edge caching (15-min fresh / 3h stale).
7. Session-subject rate limiting with IP fallback.
8. Sampled daily ops metrics in KV + `GET /metrics/today`.
9. Anthropic prompt caching + config-tunable model/max_tokens (Haiku fallback kept).
10. Security sweep: centralized CORS with optional origin allowlist, security headers,
    `no-store` on session responses, body-size caps on all POST routes, constant-time
    shared-key comparison.

`node --test tests/*.mjs` → **52/52 pass**. Deploy delta: just `wrangler deploy`
(`CONTENT_ORIGIN` ships in `wrangler.toml`; see MANUAL_STEPS.md §9b–9d).

## 5 · Spec items RL-001 … RL-010 (all implemented)

- **RL-001/002 Pause·Resume·Cancel cooking** — durable `ActiveCookSessionStore`
  (write-through persistence; survives force-close/relaunch/offline), three-action
  leave dialog, exact-point resume with wall-clock timer restoration, paused-session
  cards in Cook hub + Cook Now, idempotent completion tokens so inventory deducts and
  history records exactly once; cancel clears everything, keeps planned meals, records
  nothing. (`CookSessionPersistence.swift`, `CookingFlow.swift`, `StepTimerEngine.swift`,
  `CookHubView.swift`)
- **RL-003 Available/Reserved/Total** — pure `ReservationEngine` + cached
  `ReservationLedger` (recalcs off store revision counters); item details show Total
  Owned / Reserved / Available with per-meal claims; Available never negative —
  shortages surface explicitly. (`ReservationEngine.swift`, `ReservationLedger.swift`,
  `InventoryDetailsSheet.swift`, `InventoryHubView.swift`, tests in
  `StockedTests/ReservationEngineTests.swift`)
- **RL-004 Cook Anyway** — reserved-using recipes demoted out of "fully safe" with a
  "Ready if plans change" badge; pre-cook review shows affected meals/dates/amounts
  with Cook Anyway / Choose Another Meal / Add Replacement to Grocery (no duplicate
  grocery rows); overrides logged and reflected in projections.
  (`ReservationOverrideSheet.swift`, `CookNowResultsView.swift`, `MakeabilityEngine.swift`,
  `CookNowEngine.swift`, `CookNowCompute.swift`)
- **RL-005 Conflict/shortage detection** — chronological projection with reservations,
  expiry-before-meal-date, overrides; specific earliest-first warnings with repair
  actions in the meal planner; auto-clear on resolution. (`MealPlannerView.swift`,
  `MealPlannerSubViews.swift`)
- **RL-006 Planning integrity** — every plan/inventory mutation drives one idempotent
  recalculation through the ledger; repeated recalcs create no duplicates; manual data
  preserved.
- **RL-007 Purchase duplicate protection** — `PurchaseDedupEngine` (12h window, store +
  normalized name + barcode + package-size evidence, trip/transaction keys), persisted
  import log, Merge / Keep Both / Skip review with plain-language evidence before
  anything enters inventory; wired into receipt accept and shopping-mode transfer.
- **RL-008 Offline queue** — see improvement #5; plus `PendingSyncBadge` ("Pending N
  changes · will sync") in the offline banner, coalesced reconnect sync, backoff,
  10s flap floor, queue survives relaunch.
- **RL-009 Social recipe import** — TikTok/Instagram/YouTube/Pinterest (incl. short
  links) detected in the same import entry points; public og-metadata fetch, Worker
  parse, preview with "Needs review" chips, duplicate-source gate, manual/AI-drafted
  completion explicitly labeled; source link preserved.
  (`SocialImportDetector/Fetcher/View.swift`, `SharedRecipeImporter.swift`, `WebRecipesView.swift`)
- **RL-010 Multi-store grocery** — per-item store assignment (side-table; no model
  migration), Group-by-Store mode with per-store sections/completion and per-segment
  transfer to inventory sharing one trip id (so RL-007 understands multi-store trips),
  move-item-between-stores without recreating, unified view remains default.
  (`MultiStoreAssignments.swift`, `MultiStoreViews.swift`, `GroceryListView.swift`)

Detailed per-area notes: `docs/` folder in this package.

## 6 · Manual steps

**Worker** (one deploy): `cd stocked-receipt-worker && wrangler deploy`. Optional:
set `config:current` in KV to use kill switches (`MANUAL_STEPS.md` §9). No dashboard
changes required for this delta.

**App**: build all three targets in Xcode (Swift 6). No new Info.plist keys required;
three Claude keys were *removed* from `Stocked/Info.plist` (full replacement included).
You may delete `CLAUDE_API_KEY` from your local `Secrets.xcconfig`.

## 7 · What to test (delta)

1. Fresh install → onboarding → the notification permission dialog appears once,
   ~1.5s AFTER the main screen renders — never over the splash, never again on later
   launches. Update/reinstall: no dialog, no banner popping over Home.
2. With low/out-of-stock items, open the app: no "Kitchen Alert" banner over the UI
   (it appears in Notification Center instead). Cook-timer alerts still banner.
3. Cold launch with a large kitchen: first frame should render noticeably faster; no
   multi-second hang before Home appears.
4. Scan a known UPC → product resolves via Worker (fast, with brand/nutrition); scan in
   airplane mode → local fallbacks still work.
5. Start cooking → leave → Pause / Cancel / Continue all behave per spec; force-quit
   mid-cook → relaunch → resume lands on the exact step; Finish twice → single
   deduction and single history entry.
6. Plan two meals over-committing one ingredient → item detail shows Total/Reserved/
   Available; Cook Now shows "Ready if plans change"; Cook Anyway flow updates the
   planner and grocery; conflict rows appear/clear in the planner.
7. Import the same receipt twice → duplicate review appears; Merge keeps totals right.
8. Group grocery by store, complete one store's segment → those items land in
   inventory; other stores stay pending.
9. Paste a TikTok/YouTube recipe link in Web Recipes → preview with uncertain-field
   chips; saving twice warns about the duplicate source.
10. Airplane mode: edit inventory/grocery → "Pending changes · will sync" badge; back
    online → one sync, no duplicates on the other household device.
11. Worker: `GET /health` shows `contentOrigin`; `node --test tests/*.mjs` green.

---
## Addendum — Fix 1 (applied) & repo cleanup (2026-07-17)
- Fix 1: SearchNormalization made `nonisolated`; ProfileAvatar photo option moved to
  `.photosPicker` — resolved all 5 Swift 6 compile errors.
- QA Workbook fully removed; its 7 source files moved to `_to_delete/QA/`.
- Removed duplicates: root `stocked_recipes.sqlite` and root `Nutrition/` (byte-identical
  to the copies inside `Stocked/`), the empty `Stocked_Runtime_Log_Fixes` husk
  (AppleDouble metadata only), and stray `._*` files. All parked in `_to_delete/` —
  delete that folder in Finder when convenient.
