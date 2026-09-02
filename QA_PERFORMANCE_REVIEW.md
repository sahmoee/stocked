# QA and performance review — 2026-09-02

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
