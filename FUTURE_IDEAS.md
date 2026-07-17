# Stocked — Future Ideas (weighed, parked for later)

Assessment of the proposed Worker endpoints + app-side performance work, grounded
in what already exists in the codebase. Tiers = my recommendation, not yours to
follow blindly. "Already built" notes are the highest-signal part.

## Worker endpoints

### Build — high value, feasible
- **GET /configuration** — remote feature flags, min-version gate, disabled recipe
  sources, maintenance messages, model selection, rollout %, **kill switches**.
  Change app behavior without an App Store update. Low effort (signed JSON from KV,
  short cache). *Best item on the list for a solo dev.*
- **POST /support/diagnostics** — accept a scrubbed diagnostic blob, store in KV
  with TTL, return a reference number. Cheap, low-risk; `DiagnosticsMonitor` already
  exists to feed it.
- **POST /barcodes/resolve** — really a *correctness fix*: the current `barcode`
  route asks the LLM to guess a product from a UPC (it hallucinates). Real DBs
  (OpenFoodFacts, free) are far more accurate. `OpenFoodFactsClient` /
  `GroceryProductClient` / `USDANutritionClient` already exist on-device — centralize
  + cache them server-side.

### Build with caution
- **POST /food-safety/check** — useful but liability-sensitive. Do it as conservative
  USDA-rules logic with clear disclaimers, NOT free-form AI judgment. A wrong
  "likelySafe" can make someone sick.

### Skip — already built or redundant
- **POST /household/activity-feed** — the household DO already stores an `activity[]`
  timeline; `HouseholdActivityView` renders it. Group noisy events on-device.
- **POST /sync/conflicts/resolve** — already done: the DO does LWW + tombstones +
  revisions and serializes writes; `SyncConflictResolver` exists.
- **POST /exports/create** — `DataExport` + `InventoryExporter` already export
  on-device (offline, free). R2+Queues only worth it for shareable links.
- **POST /images/process** — `ImageCache` already downsamples + coalesces. If more
  offload is needed, use the Cloudflare Images product, not a hand-built endpoint.

### Defer — needs infra / big lift
- **POST /notifications/dispatch** — good for households (avoid double-notify) but
  requires a full APNs pipeline (push key, device-token registry). Defer.

### Skip — not feasible
- **POST /prices/compare** — no broad, reliable per-store grocery price API exists.
  Without real store APIs this becomes AI-invented prices — harmful for a purchase
  decision. Only revisit with specific store API access.

## App-side performance

### Do — high value, low risk
- **#9 Performance instrumentation** — OSSignposter + MetricKit for launch/render/DB/
  decode/image spans. Best item here given the freeze history; catches regressions
  before users do.
- **#2 Cancel obsolete tasks** — mostly done (OnlineRecipesView, RecipeVaultViews)
  but **GlobalSearchView has zero cancellation** — close that gap.
- **#8 Memory-aware images** — downsampling/coalescing/concurrency limits already
  exist (delta). Missing piece: **evict on memory warnings**
  (`didReceiveMemoryWarningNotification`, currently 0 hooks). Small add.
- **#3 Prepared view models** — proven by `DiscoverSnapshot`. Extend to remaining
  heavy `body` computations (e.g. hub counts still filtered in RecipeVaultViews.body).

### Worth it, incremental
- **#6 Batch state updates** and **#7 stable IDs** — partly in place (models use
  stable UUIDs; delta removed animated large-array publishes). Audit for stragglers.

### Defer — big refactors of working code
- **#1 RecipeLoadCoordinator** and **#5 DB-work-off-MainActor** — real merit but
  refactor central working systems (OnlineRecipesLoader, GuestDataStore).
  RecipeDatabase is already an actor; /recipes/discover already moved fan-out
  server-side. Do incrementally.

### Likely premature
- **#4 Pagination** — personal-scale data (dozens–hundreds of items) doesn't need it;
  the 98k-recipe corpus is already SQLite-paginated. Add only to a genuinely large list.

## Recommended shortlist when we return
Worker: **/configuration + /support/diagnostics + /barcodes/resolve**.
App: **instrumentation (#9) + memory-warning eviction (#8) + GlobalSearchView
cancellation (#2) + prepared view models (#3).**
