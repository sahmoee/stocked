# Stocked reference restoration and 40-point improvement ledger

Implemented in the local Stocked and UnifiedWorker working trees. The final generic physical-iOS
build-for-testing is **157**, with iPhone/iPad device families and matching app, share-extension,
widget-extension and test-bundle build numbers. No simulator was started. No production deployment,
Git commit/push, TestFlight upload or physical-device installation was performed in this batch.

## 10 code and sync/Worker improvements

1. Streaming request-body limits count real UTF-8 bytes, including chunk boundaries.
2. Brief context validation rejects malformed shapes and preserves a zero-day horizon.
3. Brief assembly tolerates old malformed rows, bounds horizons and handles expired/future facts.
4. Scheduled brief work traverses KV pages with a 100-key page and four-read concurrency limit.
5. Invalid/stale contexts are skipped; healthy siblings continue and enqueue failures are reported.
6. Queue jobs acknowledge only after persistence; storage failures retry without losing work.
7. Brief telemetry excludes household invitation codes and raw exception text.
8. Client GET retries stop on cancellation/offline state and only retry transient failures.
9. Shared Retry-After parsing handles dates/seconds safely and preserves server minimum delays.
10. Household response decoding runs off-main; cancellation/malformed 2xx retains unsent work.

Owners, changed source files, compatibility, provider-first rollout and regression evidence:
[SYNC_RELIABILITY_2026_09_05.md](SYNC_RELIABILITY_2026_09_05.md).

## 10 image improvements

1. Dedicated reference calendar/tomato-jar RGBA artwork restores Expiring Soon.
2. Dedicated reference milk/tins wire-basket RGBA artwork restores Running Low.
3. Dedicated reference oil/pasta/tin wooden-crate RGBA artwork restores Add Items.
4. Matching Home actions use those same three semantic illustrations, preventing tab-to-tab drift.
5. New antique protein-board illustration replaces the photographic category-navigation tile.
6. New edible-leftovers illustration replaces photographic category navigation and the unrelated
   grocery-crate headings on Leftovers/Save a Portion.
7. Cook Now/Later decorative heroes use the natural-edge skillet/planning artwork instead of
   white sticker outlines; shared illustration rendering prepares images asynchronously.
8. Recipe collection/ready/past navigation uses approved book/skillet/planning cutouts through
   KitchenArtworkCatalog, preserving actual recipe photographs.
9. Vegetables and Expiring Soon category cards use approved cutouts in themed native card
   containers instead of white text over saturated photo tiles.
10. Grocery meal-support artwork uses a deterministic planning illustration instead of the
    process-randomized hash choice and inconsistent recipe stickers.

All five generated deliverables are stored in `Stocked/Assets .xcassets`, in the matching
`inventory_expiring_reference`, `inventory_low_reference`, `inventory_add_reference`,
`kitchen_protein_reference`, and `kitchen_leftovers_reference` image sets.
Prompts, tool mode and exact saved paths: [ARTWORK_PROMPTS_2026_09_05.md](ARTWORK_PROMPTS_2026_09_05.md).
Complete file audit with representative visual inspection: [ASSET_AUDIT_2026_09_05.md](ASSET_AUDIT_2026_09_05.md).

## 10 UI improvements

1. Continuous themed parchment sheet hosts, including readable-width margins.
2. Editorial Inventory Details heading, illustration, typography and cards.
3. Wrapping reservation quantities, meal names and dates.
4. Adaptive scanner action layout with adequate touch targets.
5. Consistent, accessible storage-zone filter rail.
6. Theme-aware search field and clear control.
7. Shared adaptive storage picker in add/edit forms.
8. Reflowing quantity/container fields with labelled controls.
9. Readable Add Item wizard header, scan/browse actions and progress.
10. Consistent wrapping Leftovers/Low Stock report cards.

## 10 UX improvements

1. Search closes without leaving hidden filters; no-match recovery is explicit.
2. Ingredient browsing exposes real counts, clear search and no-match reset.
3. Manual storage selection survives subsequent name editing/suggestion selection.
4. Editing preserves zero quantity/fill instead of silently restocking.
5. Atomic permission-checked saves preserve untouched newer household fields and skip no-ops.
6. Permission-checked removal and exact-identity undo avoid duplicate restoration.
7. Meaningful Add Item/Leftover drafts have discard protection.
8. Leftovers record the actual cooked date and preview the resulting reminder date.
9. Inventory details show full counts, expandable rows and all reservation claims.
10. Low Stock grocery handoff counts only missing deduplicated additions and reports true outcomes.

The exact UI/UX source-owner mapping and device journeys are in
[POLISH_UI_UX_2026_09_05.md](POLISH_UI_UX_2026_09_05.md).

## Additional review fixes and guardrails

- Decorative preparation coalesces simultaneous requests in the existing bounded memory cache.
- Memory-warning eviction is distinct from a missing asset; active artwork retries once, with
  cancellation propagation, instead of showing a permanent missing-art placeholder.
- Reference action cards share measured equal height, grow with text and stack at narrow widths.
- Inventory action counts handle singular grammar and have single coherent VoiceOver labels.
- Expiring Soon uses the same Inventory presentation canvas.
- Recipe destination cards have a minimum height, not a clipping fixed maximum.
- Dark-mode gold arrows/pills and the Leftovers empty-state action use charcoal foregrounds.
- Artwork aliases, cache sharing/cancellation, draft/merge behavior and QA coverage have XCTest
  regression cases; the cases compile but are not claimed executed on a device.

## Ownership and compatibility

Stocked owns native layout, draft editing, artwork roles, client retry behavior and QA definitions.
UnifiedWorker owns request bounds, brief contexts, scheduled work, queue handling and persistence.
Existing stores/schemas remain authoritative; artwork aliases affect decorative navigation only.
No household reset, key rotation, data deletion, migration, vendor change or new service is required.
StockedMac and released clients remain compatible with unchanged API/storage shapes. Worker should
be deployed and smoke-tested before releasing the new client. The previous released client/Worker
remains the fallback; local operations stay journaled during errors.

## Verification

| Check | Result |
| --- | --- |
| Generic physical-iOS build-for-testing | Build 157 passed; app, extensions and test bundle |
| Built device families | 1 (iPhone) and 2 (iPad) |
| Worker regression suite | 104 tests passed, zero failures |
| Worker type check and production dry-run bundle | Passed; existing experimental unsafe-binding warning |
| Native Inventory form-policy checks | 19 passed |
| Native client retry checks | 18 passed |
| Native QA feature contracts | 47 passed; 123 appended device checks defined, not passed |
| Five generated cutout catalog/dimension/alpha/content checks | 20 passed |
| Whitespace/diff checks in both repositories | Passed |

The first full app build also passed (156); the final incremental build (157) includes the final
leftover-heading/contrast adjustments. Existing warnings elsewhere in the full project remain;
this is not a claim that the entire historical codebase is warning-free.

## Still requires real-world validation

- Physical iPhone/iPad screenshots in light/dark, large text, rotation and keyboard states, including
  the new QA section-48 journeys. Compilation is not pixel comparison, VoiceOver or frame-time QA.
- Production Worker deployment followed by real queue/cron and two-device household/offline tests.
- The supplied action-card subjects are recreated at high resolution with native live UI; generated
  art is not pixel-identical to the source. The earlier refrigerator's existing cream-appliance
  composition is retained, not falsely described as an exact bronze-appliance reproduction.
- Real publisher/user/product/receipt/QA photos and alternate app icons intentionally retain their
  original identity. The 249 unbundled icons were catalog-audited, not individually visually approved
  or added wholesale to the app. No source images or user data were deleted.
