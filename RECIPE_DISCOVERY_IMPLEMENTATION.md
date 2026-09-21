# Web-first Recipes with a full database backup

Implementation date: 2026-09-03. Applies to the Stocked iPhone/iPad app; the existing
StockedMac/Worker public catalogue protocol is reused unchanged.

## What changed

- `RecipeVaultViews` retains the existing landing, collection, ready-to-cook, past-meals,
  AI Coming Soon, header and tab-bar infrastructure. The established theme preference
  and semantic palette are retained, not replaced by a Recipes-only scheme.
- `RecipeFinderSession` now searches downloaded recipes concurrently with publisher
  discovery, publishes early matches, then merges both into one globally sorted list.
  There is no source picker; offline/unavailable websites retain downloaded matches. Seven-step
  drafts, review, removable filters, sort and navigation remain session owned.
- `WebRecipeFetcher` reuses the publisher registry and JSON-LD/microdata parser. Search
  does not import or publish results. It uses two concurrent publishers, six search
  pages per pass, four candidate pages per source and at most 18 retained recipes.
  No new provider/vendor/credential. HTML is streamed with a 3 MB limit; starting new
  work stops after 18 seconds (an in-flight request may finish its short timeout).
- `FinderPublisherLinks` excludes navigation/feed/account/category links and prioritizes
  relevant publisher recipe anchors. Query hints are not eligibility claims. The shared
  selector enforces AND between categories, OR within ordinary categories, AND for diets,
  total-time boundaries and existing allergen/inventory rules. Kitchen opt-in can supply
  up to three available, non-expired pantry ingredient names as retrieval hints; quantities,
  household identifiers and personal history are not sent to publishers.
- Results show source credits, real available ratings/times, inventory facts, and at
  most one supported fact/style tag. Sort & Filter and removable chips remain available.
  Unsaved results open `RecipeFinderPreview`: View Original Recipe or Import to STOCKED.
- `RecipeBrowserView` is shared by preview, URL import, Add a Recipe, source browsing,
  and saved/web recipe source actions. It has address/back/forward/reload/share controls,
  transient website storage, no autoplay, navigation policy and process-termination recovery.
  SwiftUI redraws never reset navigation. Only the finished displayed page can be imported.
- `CreateRecipeView` preserves original source URL/name, source categories/tags and notes.
  Browser/preview imports bypass automatic AI rewriting and retain repeated ingredient
  lines. Explicit Save creates the existing UserRecipe; existing detail/Cook/Grocery/
  Inventory/Collection integrations remain owners of subsequent actions. Similar titles
  warn rather than silently substituting another publisher. A matching saved source URL
  opens the existing saved recipe. Source-less personal recipes stay scoped as before.
- `SharedRecipeImporter` also preserves these source fields; its page-text fallback uses
  the bounded downloader and performs text parsing off the main actor. Cancellation is
  propagated rather than shielding abandoned downloads.

Follow-up: `BROWSER_IMPROVEMENTS.md` records the subsequent 20 browser/import improvements,
including displayed-page metadata import, a one-response URL/text fallback, source-duplicate
choices and current validation. Those changes supersede the basic browser-control description
above without changing Finder/database ownership or the full-catalogue backup.

## Full database fallback contract

Owner: `RecipeDatabaseManager`. Producer: `HarvestRecipeSync`, using the deployed
`GET /harvest/recipes?pageSize=100&cursor=…` route. Persistence: additive public catalogue
table in the existing `GrowthDatabase` SQLite file. Consumers: shared Finder selector
and app-wide database suggestions. No independent household or personal recipe store.

Each page commits before the cursor advances. Replaying a page is idempotent by canonical
source URL. Full download has no 2,000/8,000/index or total-page limit. It is resumable,
pausable and retryable; failure/partial completion stays visible. Only the first page warms
the small in-memory recipe snapshot, avoiding repeated eviction and historical activity
spam. Existing source blocklists remain enforced. No records are deleted/reconciled from
a view's limited window, and no bulk recipe-image download is started.

Finder scans 256-row keyset pages from the full downloaded public tier and bundled corpus,
plus saved/local records, keeping only its requested result window. Partial download is
never presented as an exhaustive server count. Completed archive refresh invalidates
results without restarting the query for every incoming page. Pause/error does not enter
an automatic restart loop. Offline search uses the portion already available locally.

Rollout: no Worker/Mac schema change or deployment. Install the updated iOS client, allow
the backup download to finish, and then verify airplane-mode matches. Old clients continue
to use their existing routes and records. Existing saved data is untouched.

## Validation

- 126 existing native finder checks passed: state/navigation, selections, matching,
  boundaries, sorting, missing data, loading/error/retry/cancellation and alternatives.
- 73 new native checks passed: browser URL/navigation safety, stale import invalidation,
  deterministic retrieval hints, opt-in inventory hints, fact tags, publisher candidate
  selection, cursor validation, SQLite paging/replay/reopen and search beyond 8,000 rows.
  The fixture writes 8,105 records and finds the final record after reopening.
- Two live publisher checks passed: search HTTP response and a selected real recipe page
  containing ingredient/instruction metadata. The production link selector found
  `https://www.budgetbytes.com/chicken-broccoli-casserole/`.
- Added `RecipeWebDiscoveryTests` for real metadata/ratings, strict dietary/kitchen
  eligibility, saved-source deduplication, parser rating scale/diet declarations, browser
  import state, host-boundary attribution and preview field preservation. Final generic
  iOS `build-for-testing` passed, including the app, extensions and test bundle; log:
  `/tmp/stocked-web-first-ios-final-validation.log`. iOS XCTest execution is not claimed
  from compilation. Earlier build/test-isolation issues were corrected before this pass.
- Native lightweight SQLite fixture measurement: about 0.21 seconds and 11.3 MB maximum
  RSS for 8,105 short fixture rows. This is not an iPhone performance measurement and is
  not representative of full HTML/image payloads.
- No simulator build/test, physical-device install, production deployment or QA-ticket
  closure was performed in this change. The user's pre-existing project-file edit is kept.

## Remaining limits / release checks

- Discovery searches supported publisher endpoints, not a licensed exhaustive web-search
  index. Blocking, paywalls, JS-only pages and missing structured data can limit results;
  View Original and the database fallback remain available. No bypass of publisher access.
- Unknown source ratings/times/nutrition are not invented. Allergen-free/nutrition filters
  unsupported by reliable metadata remain unavailable. Publisher diet labels are not an
  allergen-safety guarantee. No dietary or allergen restriction is relaxed automatically.
- The saved UserRecipe model has separate prep/cook fields but no independent total-time
  field. Source-only total time is retained in import notes, not mislabeled as cook time;
  after saving, strict time filters require the known prep/cook fields. Review missing
  timing in the editor. Web previews retain the publisher's explicit total time.
- Verify actual iPhone/iPad light/dark layout, large text, VoiceOver, modal transitions,
  WebKit memory recovery, interrupted backup resume, offline recovery, and import → grocery
  → cook on device before release. Builds do not substitute for those checks.

Native checks use `scripts/RecipeFinderCoreChecks.swift` and `scripts/RecipeWebCoreChecks.swift`.
The latter accepts a temporary SQLite directory and optional `--live` flag.
