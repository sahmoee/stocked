# Performance architecture

Stocked's loading work must stay bounded as household, recipe, grocery, QA, and history data grow.
The following protections are the implementation checklist for every future feature and repair.

1. `GuestDataStore` restores scalar preferences synchronously and hydrates large collections from an immutable disk snapshot off the main actor.
2. `LocalDatabase` performs JSON encoding and coalesced file replacement on its serialized utility queue.
3. Price and consumption histories use row-addressable SQLite storage through `GrowthDatabase`, with legacy JSON migration.
4. The recipe corpus uses SQLite/FTS rather than decoding the complete bundled catalog into view state;
   discovery samples rotate through capped, indexed primary-key windows, require validated remote
   artwork, and never sort the corpus with `ORDER BY RANDOM()`.
5. Recipe screens request bounded summaries and resolve full recipe details only for visible or selected content.
6. Recipe lookup structures are incrementally updated during batch upserts instead of being rebuilt for every row.
7. Large household domains persist independently so a small preference edit does not rewrite unrelated recipe history.
8. Household writes use a durable operation queue and bounded push payloads instead of repeatedly uploading the entire local database.
9. `InventoryIndex` owns normalized names, identifiers, tokens, and reserved quantities used by matching and lookup.
10. Recipe-match results are revision keyed and invalidated only when input domains that affect matching change.
11. View refreshes use domain revisions so unrelated persistence and sync activity does not invalidate every screen.
12. `KitchenMetrics` materializes Home counts; all inventory health counts are computed in one pass.
13. Large lists use limits, prefixes, search result caps, and lazy containers rather than eager unbounded view trees.
14. Imports commit bounded batches and advance durable cursors so cancellation and relaunch do not repeat completed work.
15. Provider and household queues enforce concurrency limits, exponential backoff, and circuit breakers.
16. All remote artwork uses the shared `ImageCache`; views must not create private image caches or raw duplicate downloads.
17. Images retain original bytes on disk while display decoding is downsampled to the requested target size.
18. Disk-cache pruning is gated, modification-date driven, size bounded, and never enumerated from a SwiftUI body.
19. Household JSON serialization and payload trimming run at utility priority away from the main actor.
20. QA persistence is disk backed, hitch summaries are maintained incrementally, display-link sampling is capped, and memory alerts are band/rate limited.
    Home/Inventory bundled cutouts use StockedKitchenArtwork: layout only reads prepared memory
    hits; utility tasks load and prepare aspect-preserving thumbnails capped at 720 pixels in
    ImageCache's existing bounded local-image cache. No full-atlas decode or multiply compositing.
    Simultaneous decorative asset requests coalesce into one preparation task; eviction cancels
    pending preparation, and missing-asset presentation must distinguish eviction from a missing file.
    Keep KitchenArtworkCatalog aliases semantic and stable across Home, Inventory, Cook and Recipes.
    Inventory navigation uses ReservationLedger.refreshForPresentation with immutable utility
    inputs and cancellation/revision guards; authoritative mutation checks retain the synchronous API.
    QA gesture captures use the 1x committed layer tree, never drawHierarchy GPU readback; video,
    Metal and live blur fidelity remain a disclosed capture limitation, not an empty-state assertion.
21. Cook Now async classification snapshots live state once and runs substitution lookup and classification
    off the main actor, checking cancellation between recipes and rejecting stale results before caching.
    Grocery equivalents use an immutable canonical-key index and pre-normalized brand names.
22. RecipeDatabase batch ingestion trims once per batch and removes only evicted rows from search indexes;
    manual recipes remain protected even when their count exceeds the automatic-cache budget.
23. GET retry loops honor cancellation/offline state and server Retry-After minimums without retrying
    permanent transport errors. Household response decoding stays off-main; invalid 2xx responses
    cannot acknowledge pending local work. Worker JSON limits count streaming UTF-8 bytes, scheduled
    brief reads page by 100 with concurrency four, and queue acknowledgement follows persistence.
24. Inventory editors assemble one change from a draft baseline and the current item, preserving
    untouched concurrent fields and skipping no-op writes rather than syncing each edited property.

Find a Recipe scans keyset pages on a cancellable utility task, never eagerly materializes the full
corpus in view state, and reuses completed results by recipe/inventory/history/database revision.
Counts cover the union of matching downloaded records and discovered website recipes; card windows
start at 30 and grow only on request. Keep all matched identities, not full models, for union counts.
Coalesce early result snapshots to at most one per 200 ms; generation-gate partial and final updates.

Web-first Find a Recipe is explicitly user-triggered. Reuse the publisher registry/parser,
limit concurrency to two publishers and six search pages per pass, cap each HTML body at 3 MB,
and stop starting work after 18 seconds. Propagate cancellation through downloads and parsing.
Close the underlying streamed URLSession task even on oversized/status-rejected responses.
The older source browser and page-text import fallback reuse these limits and candidate policy.
Session candidates are bounded (at most 18), reused for filter/sort changes for ten minutes,
and never auto-published or persisted as collection imports. Downloaded search runs concurrently and
shows usable matches before publisher work finishes. Both sources merge through the same selector;
neither merging nor fallback can weaken dietary/allergen/kitchen constraints. Do not hide available
cards behind a skeleton while remaining sources are loading.

QA background nudges cancel their predecessors, use scalar data revisions rather than array counts,
and reject cancelled/stale snapshots. Manual and automatic exports share the live checkbook;
small deterministic feature contracts do not trigger web requests or sign off UI/device checks.
Full read-only diagnostics reuse the invariant snapshot on a ten-minute foreground cadence. Folder
size walks run off-main with a 2,000-file/250 ms cap. Accessibility sweeps debounce navigation, use
an 8 ms automatic (40 ms manual) budget and never label a truncated scan clean. Two fresh complete
observations are needed before auto-filing a possible accessibility defect for manual review.
Recurring tickets retain one screenshot path; never encode a screenshot for a discarded duplicate.

The shared browser observes WebKit progress/title/URL/history rather than polling or reloading
on redraw. Its 30-second watchdog is cancellable; backgrounding pauses media and pending work,
and dismantling removes every observer/delegate. User-triggered rendered imports read at most
16 bounded JSON-LD blocks (512 Ki UTF-16 code units in aggregate), never the entire page DOM.
Network imports reuse one HTML body for structured and visible-text parsing, off the main actor;
redirect policy is checked before following each hop. Import-generation guards reject late
progress/results after cancellation or a new request. Parsing and history remain bounded.

RecipeDatabaseManager's public catalogue tier lives in the existing GrowthDatabase SQLite file.
Harvest reads 100 rows per server page, commits before advancing the resumable cursor, and only
warms the small writable snapshot from the first page. A complete download has no total/index cap.
Reads use 256-row keyset pages; filtering never materializes the whole corpus in SwiftUI. In-progress
archive revisions do not continuously cancel/restart visible queries; completion invalidates the
results once. No bulk image downloads, no household/private rows, and no destructive reconciliation.
Source-attributed, image-complete imports from Stocked Mac, Stocked server, and import caches
contribute automatically to that public catalogue. Source-less personal creations remain in My
Collection. Catalogue ingestion still rejects incomplete pages and preserves publisher attribution.

The user currently requires approval before any simulator build/test. Native finder checks and
generic-device compilation are allowed; UI/runtime verification must not be claimed from them.
Normal validation requires a successful generic-device build plus the `StockedTests` unit, migration,
logic, and performance suites on both an iPhone and iPad simulator. CI discovers available
simulators dynamically, builds the test bundle once, then executes it on both device families.
