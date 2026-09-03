# QA and performance review — 2026-09-02

## Follow-up: theme, drawer, and QA attachment handling

The latest shared collection contains 158 tickets: four new open reports plus the
two previously open reports below. This working-tree patch addresses:

- STK-89-0006: Create with Stocked AI is visibly Coming Soon and disabled; implementation retained.
- STK-89-0007: the new Find a Recipe entry provides shared search, seven filter categories,
  removable filter chips, a complete filter sheet, and nine sorting options.
- STK-89-0008: Grocery secondary text now uses solid semantic contrast tokens; tiny item
  metadata grows to 12 points. Recipe surfaces use the active theme instead of fixed pale fills.
- STK-89-0009: drawer offsets reset when a gesture is cancelled; only the panel background
  casts a shadow, and the drawer contents do not animate their layout during the slide.

The user clarified that the drawer partially opened and stalled briefly, not that it crashed.
The Grocery ticket records 1,790 MB footprint, but does not establish an allocation root cause.
QA sync now reads attachment bytes and creates capped 200-pixel thumbnails on a utility task,
with per-image autorelease pools, avoiding full image decoding on the UI thread.
Cook choices have vertical spacing on phones as well as tablets; recipe tiles share size tokens.
No new ticket is marked shipped or verified by these source changes alone.

## QA collection

Read the shared `stocked-app` collection: 154 tickets, including 126 iPhone,
26 iPad, and two unspecified-device records. 152 were already marked fixed.
No ticket status was changed by this review.

- **STK-89-0130 — Small image:** enlarged the Stock Level gauge and its square
  container through shared width-adaptive geometry. Added phone/tablet and
  accessibility geometry regression coverage. Device visual validation remains pending.
- **STK-3-0002 — Main thread blocked 4.4s on —:** breadcrumbs identify slow
  Cook Now classification near launch. QA and primary Cook surfaces now classify
  eight recipes between yields, cancel superseded work, and discard mixed-revision
  results. This addresses an identified blocking path, not proof that every launch
  hitch or the reported 936 MB spike has been eliminated.

## Changes

- iOS: utility-task harvest decoding, one coalesced publication worker with batches
  of 20, stop-on-failure behavior, and historical backfill after local hydration.
- iOS: classification cache keys include actual profile/override content and catalogue
  revision; memory warnings discard retained classifier snapshots.
- Mac: indexed household merges tolerate duplicate legacy UUIDs; image-validation
  failures no longer classify attributed imports as personal records for deletion.
- Worker: normalize KV reads within batches of 100; stable data-derived catalogue
  timestamps preserve ETags across cache expiry; failed index reads return 503.

## Validation and rollout

- Mac Debug build passed.
- iOS generic-device Debug build passed. The full simulator test bundle also compiled
  successfully for arm64 and x86_64, including the new regression tests. Neither
  compilation nor a device build substitutes for executing tests.
- Worker `npm run verify` passed: 82 tests, TypeScript checking, and deployment dry run.
- iPhone/iPad execution, visual checks, and memory/launch profiling are blocked:
  `xcrun simctl list runtimes` reports no installed runtime.
- Nothing deployed. Both open QA tickets remain open pending device validation.
  Worker owns the unchanged harvest schema; Mac/iOS remain its producers and consumers.
  The server cache changes can roll out before either client; older clients remain
  compatible. No database migration or production deletion was executed.

## Remaining architectural findings

These improvements do **not** establish the earlier requested complete shared-database
guarantee: the harvest index still has a 2,000-record cap, and Mac's local library is
not a demonstrated complete pull of the public catalogue. Historical repair and
concurrent index writes need a separately validated durable indexing/sync solution.
Also, some secondary recommendation paths still call the synchronous classifier.
Do not claim all recipes are globally synchronized or all bottlenecks removed on the
basis of this batch.
# Find a Recipe and interrupted-change audit — 2026-09-02

The Recipe Hub lower discovery sections now route through the seven-step finder and a shared
direct-search/results interface. The AI banner remains disabled as Coming Soon. The obsolete
rail snapshot listener no longer classifies hidden content. Finder queries use cancellable
256-row SQLite keyset pages, 300 ms search debounce, bounded displayed results, and revision-keyed
reuse after detail navigation. Shared recipe tiles use the same light/dark surface token.

Inventory matching excludes zero containers app-wide. Finder full matches require sufficient
known quantities; compatible containers pool, repeated lines consume that pool, incompatible or
unknown amounts remain uncertain, and expired items are excluded. History edits now have a scalar
revision. Source metadata cannot reliably support nutrition/allergen-free filter options, so those
options remain absent rather than guessed. Saved allergen exclusions remain enforced.

Validation: 108 native finder core checks, 15 Worker harvest/shared-catalogue/recipe-contract tests,
and the Mac public-catalogue decoder/pagination smoke harness passed. The final generic iOS app
and StockedTests bundle build passed (`/tmp/stocked-finder-final-verification.log`, TEST BUILD
SUCCEEDED). Integration tests compiled; their iOS runtime execution has not been performed.
No simulator builds or tests were started for this feature. Device layout, VoiceOver, real-device
memory, and the drawer pause remain unverified; no QA ticket is marked resolved or deployed here.
