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

Validation requires a successful generic-device build plus the `StockedTests` unit, migration,
logic, and performance suites on both an iPhone and iPad simulator. CI discovers available
simulators dynamically, builds the test bundle once, then executes it on both device families.
