# Unified AI, build, and cross-project instructions

This is the single authoritative instruction contract for Codex, Claude, and any other AI or build agent in this repository. Read `README_FIRST.md` first, then read only the sections below that match the current project and task. Legacy instruction filenames link here; do not duplicate rules into them.

## Task routing and updates

1. Identify the current repository and feature boundary before reading or editing code.
2. For UI work, read Product and UI rules; for data/API work, also read Cross-project ownership; for QA tickets, also read QA; for build/release work, also read Validation and publishing.
3. Inspect repository status and preserve unrelated changes. Search for existing implementations and tests before adding another path.
4. Load secrets only from ignored machine-local configuration or Keychain. Never copy values into source, prompts, logs, screenshots, fixtures, or documentation.
5. Default every metered AI request to the lowest-credit supported model and prefer on-device AI when it can satisfy the task. Preserve explicit user/operator model overrides; do not silently promote a default request to a costlier model.
6. When behavior, setup, compatibility, ownership, or validation changes, update the relevant section here and the concise project facts in `README_FIRST.md` in the same verified batch.
7. Shared changes must name an owner, producers, consumers, rollout order, fallback, migration/repair behavior, and verification matrix before publication.
8. Read narrowly to minimize tokens, but never skip a section selected by these routing rules.

## Project and UI rules



Every page, sheet, popover, and cover must fill its presentation with the active Stocked theme, never the stock white host background. Layouts and controls must adapt to available window width, device class, orientation, Split View/Stage Manager, safe areas, and Dynamic Type. Prefer flexible frames, adaptive grids, `ViewThatFits`, and minimum hit targets; fixed dimensions are reserved for intentional artwork/media geometry. Do not force scrolling when content fits or disable scrolling needed by smaller screens or accessibility text.

App-level headers and root tab bars have one shared implementation and one geometry source. Feature pages must not locally override brand placement, chrome height, safe-area spacing, icon slots, labels, or selected-tab geometry.
Inventory destinations reuse InventoryEditorialHeading, InventoryEditorialCard and the session's
inventoryCanvas/inventoryGold tokens; do not create a separate header or store for the redesign.
Home/Inventory artwork uses StockedKitchenArtwork and the shared ImageCache, with aspect-fit
cutouts and off-main preparation. Do not restore atlas stretching or multiply blending.
Use KitchenArtworkCatalog for decorative navigation aliases; never remap publisher/product photos.
Inventory actions must retain the reference calendar/tomato jar, wire milk/tin basket and wooden
grocery crate, including matching Home widget roles. Validate new cutouts with KitchenArtworkAudit.
Inventory edits preserve zero quantities, manually selected storage and untouched newer household
fields. Commit one coherent, permission-checked change; protect meaningful drafts and exact undo IDs.

Home and Cook greetings share `StockedGreeting` and the live Preferences name. Root selected-tab
colors use shared design tokens: tan-on-charcoal in light mode, bright-gold-on-charcoal in dark mode.

## Cross-project ownership and synchronization


- `StockedMac`: creates/edits/imports the shared image-complete recipe library.
- `UnifiedWorker`: AI, household, recipe/harvest content, QA, queues, and compatibility routes.
- `site-repo`: public product pages and content feeds.

Household transport decodes responses off-main, treats cancellation/malformed 2xx as unsent work,
and shares safe Retry-After parsing with NetworkRetry; server cooldowns are minimum deadlines,
never shortened by jitter. GETs stop on cancelled tasks/sleeps and do not retry permanent errors.
Worker brief scheduling pages in bounded batches; acknowledgements follow successful persistence.
See SYNC_RELIABILITY_2026_09_05.md for ownership, provider-first rollout, fallback and tests.

Recipe schemas, images, provenance, categories, household data, QA, or API changes require compatible updates across affected repos. Keep old records and released clients working; make fields additive and repairs retroactive.
Source-attributed, image-complete imports publish to UnifiedWorker's shared harvest catalogue even
when the device is not in a household. Preserve publisher name, canonical URL, and original image
URL; source-less personal recipes may remain household-scoped.

Stocked QA uses the shared `Joo` ten-minute gate. Once unlocked, sync first merges the app-scoped Worker ticket collection from every iPhone/iPad, then publishes local changes. Mac apps do not expose in-app QA.

## QA

`QAIdentityStore` owns the per-installation Key/Shalise choice and random QA device ID; capture exact
hardware family/model with every new report. Never infer a legacy tester or replace captured hardware
with the device editing a ticket. Optional `qaIdentity`, origin/check/run and regression fields remain
backward compatible; UnifiedWorker preserves omitted metadata from released clients.
`fixed` means Completed unless `requiresManualReview` is true. Hide completed tickets from active
work but retain history; `verified` still requires real device/tester evidence. Only a fresh same-origin
automatic observation may reopen an automatic fix. Do not replay cached failures or apply an old
shipped resolution over a refile/regression. Linked failures derive Resolved, never a fabricated Pass.
Preserve that derivation when notes are edited. Keep screenshots attached to the retained ticket.
Autonomous checks stay QA-gated, foreground-only and read-only, defer during cooking, reject stale
snapshots, bound disk walks and accessibility work, and honor explicit Auto-publish preferences.

The user has paused all simulator builds and tests; ask before starting any. Use native pure-logic
checks and generic-device compilation meanwhile, and never describe those as device UI verification.
Find a Recipe discovery owns no backend API or independent user store. RecipeDatabaseManager owns
the additive public catalogue table in GrowthDatabase and HarvestRecipeSync owns its resumable
server-page cursor. Never reconcile that table from a bounded view snapshot or load it all into RAM.
Unified discovery uses bounded publisher requests, no source-count qualification gate, no automatic
catalogue writes, and no new vendor. Search the downloaded database concurrently, publish early
matches, then merge website matches into the SAME sorted/deduplicated list. No Online/Database
picker or separate source sections. Failure/offline retains available matches without relaxing any
filter; disclose incomplete downloads. Import commits only through the existing review form/GuestDataStore and preserves source
rights/links; preview and browsing are not imports. Retain user theme selection and the hub identity.
The browser/importer share URL and response policies, including per-hop redirect validation.
Read only bounded page recipe metadata on explicit import, then fall back to one bounded response
for structured/text parsing. Do not read clipboard contents on appearance, copy browser cookies,
bypass publisher restrictions, or permit stale/cancelled imports to open a draft. Preserve exact-source
duplicate review, source yield and attribution. Keep WebKit find/zoom/history session-local and
remove observers/delegates at dismantle, not when a review sheet is merely presented.
QAFeatureCoverage appends stable checklist IDs for new functionality. Untested blockers remain open;
changed definitions require retesting without deleting notes/ticket links. Manual and automatic QA
exports include the complete current checkbook, not hardcoded counts or empty checklists. Pure fixture
contracts are labelled as such and never mark physical-device checks passed. QA nudges are coalesced,
revision-based, cancellation-aware, and may not publish a clean result from changing inputs.
Reuse the shared selector for every count
and result surface; preserve drafts through detail navigation. Never relax dietary/allergen exclusions
or infer complete inventory coverage from missing amounts. Zero-container inventory is unavailable
app-wide. Keep the Stocked AI entry disabled as requested.
STK-89-0135: retain Jamaican as a specific cuisine with Caribbean as its parent across imports,
legacy read repair and finder facets. Empty-result alternatives must require an explicit tap and use
real counts from the existing scan; never manufacture mood tags or relax safety filters.

Keep QA attachment reads and thumbnail decoding off the main actor. Drawer drag translation must
reset on gesture cancellation. Recipe cards use shared theme surface and sizing tokens; the
Recipes-tab AI creation entry remains disabled and labeled Coming Soon until explicitly enabled.

Background invariant classification uses immutable Sendable snapshots on a cancellable utility task,
with cancellation checks between recipes; interrupted or revision-stale
snapshots must not be reported as a clean QA run. Harvest JSON conversion stays off the main actor,
and bulk publication uses one coalesced, bounded worker rather than per-recipe tasks.

Household cooking coordination is the additive `activeCookSessions` feature collection. Share only
member attribution, recipe title, coarse progress and bounded helper-task claims. Never sync the recipe
instructions, ingredient quantities, cook notes or timers. Throttle unchanged heartbeats, tombstone
completion/cancellation, and retain local-only cooking as the fallback when household sync is unavailable.

“Check tickets” means pull the complete cross-device Stocked QA collection, fix every actionable open ticket in the same task, validate the affected iPhone and iPad targets, add a shipped resolution, and publish the fixed ticket state. A read-only summary is not completion. Never mark a ticket fixed when validation fails; `verified` remains a tester/device action after the corrected build is exercised.

UnifiedWorker owns Kroger OAuth and RapidAPI host allowlisting. StockedMac discovers and publishes normalized grocery catalog records; Stocked iOS finds provider-backed stores and consumes normalized product data. Never add provider secrets to iOS, and keep store-specific price/availability/aisle caches bounded so stale data cannot replace user-confirmed inventory.

## Shared safety, validation, and publishing contract


### Project intake

1. Begin with the named entry point and expand scope only when evidence requires it.
2. State the feature boundary before editing so adjacent shipped behavior is preserved.
3. Identify the authoritative local, server, and generated data sources before changing models.
4. Keep credentials, signing material, user data, and machine-local configuration outside commits.
5. Treat released schemas, URLs, deep links, persistence formats, and extension contracts as compatibility surfaces.
6. Preserve offline/local-first behavior and provide a recoverable failure path for optional services.
7. Apply the complete product theme, adaptive layout, Dynamic Type, accessibility, and device-size contract to UI work.
8. Prefer migrations and retroactive repair over destructive replacement of existing records.
9. Run the narrowest meaningful validation first, then every affected target or consumer.
10. Finish only when behavior, setup, verification, documentation, and cross-project impact agree.

### Implementation and verification

QA-enabled Xcode projects use the shared `qa_build_number.py` contract: one locked reservation per
shared-scheme build, project-wide integer build settings, a DerivedData-scoped reservation, and an
always-running post-Info.plist/pre-signing stamp for each app, extension and test bundle. The generated
plist is an input, not a declared output, to avoid an Xcode dependency-graph cycle. User-script sandboxing
is disabled only for this repo-owned, local-only phase; signing entitlements and app sandboxing are unchanged.
Never auto-edit MARKETING_VERSION or double-bump it/builds in deployment wrappers. Validate actual
bundle metadata, including embedded extensions, not only pbxproj settings. Stocked owns the script;
Atlas/Nova/The-Sesh/ReelPromo-iOS vendor identical copies. Failed builds may leave reservation gaps.

1. Inspect repository status first and preserve unrelated user or agent work.
2. Make the smallest coherent batch that resolves the root cause without silently dropping features.
3. Search for existing abstractions, tests, and generated sources before adding parallel implementations.
4. Never expose secrets in code, logs, screenshots, fixtures, commits, or implementation briefs.
5. Keep public and persisted changes additive unless an explicit, tested migration removes the old path.
6. Update all affected app, widget, extension, Worker, site, and tooling consumers in the same coordinated task.
7. Test empty, loading, failure, offline, cancellation, retry, duplicate, and accessibility states when relevant.
8. Do not publish, deploy, migrate production data, or mark QA resolved after failed validation.
9. Record material decisions and new invariants in the existing short guides without duplicating large documentation.
10. Hand off with changed files, validation evidence, deferred risks, and any required operator action.

### Cross-project delivery

1. Name one owning repository for every shared schema, route, asset, or generated artifact.
2. List every producer and consumer before modifying a shared contract.
3. Preserve older clients with additive fields, tolerant decoding, stable URLs, and routing shims where required.
4. Define rollout order so providers remain compatible before consumers adopt new behavior.
5. Make migrations idempotent, resumable, observable, and safe to retry after interruption.
6. Keep secrets server-side or machine-local and synchronize only names, requirements, and validation—not values.
7. Propagate fixes retroactively to stored records when the invariant applies to old and new data.
8. Validate a matrix covering the owner, direct consumers, extensions/widgets, public content, and fallback paths.
9. Update README-first, AI instructions, cross-project sync, and public documentation in the same verified batch.
10. Retain a rollback or compatibility path until deployed clients and persisted data confirm the new contract.
