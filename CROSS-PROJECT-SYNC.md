# CROSS-PROJECT-SYNC — this folder is **Stocked for iOS** (`Documents/Stocked 2`)

> Identification for any chat: this is the **iOS** Xcode project (`Stocked.xcodeproj`,
> with `StockedShareExtension`, `StockedWidgets`, `StockedTests`). The macOS app lives
> in `Documents/Stocked Mac`; the Cloudflare Worker in `Documents/worker`. Every update
> applied to one project must be recorded in the other folders' copies of this file.

## Updates applied elsewhere that concern iOS

### 2026-08-06 — iOS ADOPTS the harvest cache (new `HarvestRecipeSync.swift`)
- **This is the iOS side finally consuming what the Mac has pushed since Build 91.** The
  Worker has stored Mac-approved harvested recipes in CROWD KV since the 2026-08-05 fix and
  exposed `GET /harvest/recipes` + `GET /harvest/img/<id>.jpg`; iOS had never pulled them.
  Now it does.
- **New file `Stocked/HarvestRecipeSync.swift`** — a `@MainActor` singleton that GETs
  `/harvest/recipes` (via `StockedUnifiedWorker.url`, `X-Stocked-Key` through
  `BuildConfig.authorizeWorkerRequest`, `If-None-Match`/304-aware), decodes the Mac's payload
  (`{version, updatedAt, count, recipes:[…]}`), maps each recipe to a `RecipeDatabaseEntry`,
  and calls `RecipeDatabase.shared.upsertAll`. Once ingested, harvested recipes flow into the
  same pool that feeds Discover's offline seed, recipe search, the mood finder and cook ranking.
- **Cadence ("updated frequently"):** pulls once at launch, again on every foreground
  (throttled to ≤1 per 5 min), and on a 15-min repeating timer (the Worker edge-caches the
  route for 10 min, so 15 avoids re-reading an identical body). Pull-to-refresh
  (`StockedRefresh.standard`) also triggers an immediate `syncNow()`.
- **Wiring:** `StockedApp.swift` — `HarvestRecipeSync.shared.start()` in `.onAppear`,
  `HarvestRecipeSync.shared.syncOnForeground()` in the `scenePhase == .active` block.
- **Image resolution:** prefers the recipe's absolute `imageURL`; otherwise resolves the
  Worker's relative `/harvest/img/<id>.jpg` against `StockedUnifiedWorker.baseURLString`.
- **Source name:** uses each recipe's `attribution`, falling back to `"Stocked Kitchen"` —
  deliberately NOT "Sowens"/"kaggle", which `RecipeSourceBlocklist` rejects. Dedup is by title
  through `RecipeDatabase.upsertNoPersist`, and the entry id is derived from the Mac's UUID so
  re-syncs update in place instead of duplicating. Everything degrades silently (offline /
  unconfigured / 304 / decode failure → 0 ingested, no user-facing error).
- **No Worker or Mac code change** — this consumes the existing two GET routes as-is. Version
  numbers move only when the next iOS build is cut.

### 2026-08-01 — Mac Build 91 (Browse) + worker harvest cache
- **No iOS code change required.** The iOS build and version numbers do not move.
- The Mac app now enforces "no recipe without an image" *before* hand-over, so every
  recipe arriving via household sync from the Mac carries image data or a working
  image URL. Blank-placeholder recipes from Mac imports should stop appearing.
- The worker gained `GET /harvest/recipes` and `GET /harvest/img/<id>.jpg`
  (same `X-Stocked-Key`): a cache of Mac-approved recipes with guaranteed images.
  Optional future adoption — e.g. as a Discover/curated feed source alongside
  `/content/recipes`.
- Shared model lineage: Mac's `Models.swift` / `KitchenMetrics.swift` remain
  byte-identical to iOS as of Mac Build 91; if iOS models move, re-run the diff and
  update `MacBuildConfig.sharedModelLineage`.

### 2026-08-01 — note: Mac Build 92
- Mac-only UI/catalog work (multi-select sources, list import/export, self-heal).
  **No iOS change required**; nothing about sync or the worker contract moved.

### 2026-08-01 — note: Mac Build 93
- **No iOS change required.** Recipes arriving from the Mac now always carry honest
  attribution in their notes ("Source: <site or author> — <url>"), never "Sowens" or
  an internal handle. Reddit-found recipes are attributed to the hosting site.

### 2026-08-02 — note: Mac Build 94
- Mac crawler/UI fixes only. **No iOS change required.**

### 2026-08-02 — note: Mac Build 95
- Mac import pipeline overhaul only. **No iOS change required.** Heuristic-parsed
  recipes can never auto-approve, so nothing below standard reaches the household.

### 2026-08-02 — note: Mac Build 96
- Mac browsing/import fixes only. **No iOS change required.**

### 2026-08-02 — note: Mac Build 97
- Mac crawler resilience only. **No iOS change required.**

### 2026-08-02 — note: Mac Build 98
- Mac queue-control only. **No iOS change required.**

### 2026-08-02 — note: Mac Build 99
- Mac bulk-verify/batching only. **No iOS change required.**

### 2026-08-05 — note: Mac Build 100
- Mac-only: Harvest folded into the Browse section (one place to find, import and
  approve), a guided flow with everything advanced collapsed, and discovery that prefers
  direct recipe links over mining category pages (mined recipes, when needed, are
  imported first). **No iOS change required**; nothing about sync, attribution, or the
  worker contract moved. Shared `Models.swift` / `KitchenMetrics.swift` remain
  byte-identical to iOS as of Mac Build 100.

### 2026-08-05 — note: Mac Build 101
- Mac-only: hands-off **Autopilot** (one Start runs discover→mine→import→auto-approve
  across sources) and a **category catalog** — the categories a site publishes become
  cached, organized, browseable tiles whose recipes are mined and ready for one-click
  import. All client-side. **No iOS change required**; sync/attribution/worker contract
  unchanged. Recipes still arrive image-guaranteed and standards-gated, so nothing below
  standard reaches the household. Shared models still byte-identical as of Mac Build 101.

### 2026-08-05 — note: Mac Build 103
- Mac-only fix: nested category/roundup mining now recurses (bounded, up to 4 hops)
  instead of stopping after one hop and dropping the rest — fixes a "stuck in a category
  loop" report on sites that nest collection posts inside other collection posts.
  Activity logging also rolled up to one summary line per pass. All client-side. **No
  iOS change required.**

### 2026-08-05 — worker fix: /harvest/* routes now real (no iOS change)
- Worker-side only: Stocked Mac's `/harvest/cache`, `/harvest/image`, `/harvest/recipes`,
  `/harvest/img/<id>.jpg` were documented since Build 91 but never actually implemented,
  so Mac's cloud sync had been silently failing. Now fixed — see
  `Documents/worker/CROSS-PROJECT-SYNC.md` 2026-08-05. **No iOS change required**; the
  two GET routes (`/harvest/recipes`, `/harvest/img/*`) remain available whenever iOS
  wants to adopt the Mac-approved, image-guaranteed recipe cache, same as before.

### 2026-08-05 — note: Mac Build 102
- Mac-only: a discovery run that hits a rate limit, a network failure, or gets stopped
  now imports whatever it already found instead of discarding it, and a run always keeps
  trying until it finds at least one real recipe rather than ending with only cached,
  unmined category pages. Also added a direct "import from a URL" field to Find & Import.
  All client-side, no persisted-settings change. **No iOS change required**; sync,
  attribution, image-guarantee, and the worker contract are unchanged.
