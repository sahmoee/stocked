# Read me first

Recipe tiles share `RecipeCardStyle` typography/artwork/padding and semantic theme card surfaces;
recipe and grocery supporting text uses the solid secondary-text token in both appearances.
The Recipes hub exposes Find a Recipe (direct search or seven optional quiz steps); Create with Stocked AI is disabled as Coming Soon
without removing its implementation. Cook choices have flexible vertical breathing room on phones
and tablets. Drawer translation is gesture-scoped so interrupted drags cannot strand the panel.
QA publication reads attachments and creates bounded 200-pixel thumbnails off the main actor.

Find a Recipe uses one session-owned `FinderFlow` and `FinderQuery` for review counts, search,
filter edits, and sorting. `FinderService` scans the shared database and SQLite corpus in cancellable
256-row pages, retaining only the requested result window. Never replace this with a full-library
SwiftUI array. Category filters are AND; values within a category are OR; dietary values are AND.
Dietary metadata is not an allergen-safety guarantee; unsupported nutrition/allergen-free options
are intentionally absent. Existing saved allergen exclusions remain active. Full kitchen matches
require confirmed quantities; mostly means 70% of required ingredients. Unknown times/ratings/dates
are not fabricated. Past-meal revisions invalidate results after ratings/history edits.
Jamaican is a canonical cuisine that also matches Caribbean. Historical Caribbean records recover
Jamaican specificity on read only when their title or explicit metadata names it. Empty review/results
offer real, opt-in soft-filter alternatives from the same scan; never invent Comfort tags or relax
dietary/allergen, kitchen or search requirements. Mac/server discovery coverage is only an import
ordering hint and does not determine recipe eligibility or imply every combination has matches.

User validation override (2026-09-02): do not run simulator builds or simulator tests without
asking first. Native `scripts/RecipeFinderCoreChecks.swift` checks and generic iOS-device builds
are permitted. Device UI, VoiceOver, and performance verification remains a separate validation step.

Performance: background QA classifies immutable snapshots off the main actor and discards stale/cancelled
snapshots. Public harvest responses decode on a utility task; import publication coalesces into
20-record batches and stops on failure. Stock Level artwork uses shared width-adaptive geometry.
Cook Hub, results, preparation discovery, and Ready to Cook share this cancellable classification.
Grocery equivalents are indexed once; recipe imports evict once per batch with incremental index removal.
Memory warnings evict classification snapshots alongside decoded image caches. Historical import
backfill waits for initial disk hydration rather than reading empty launch placeholders.

Stocked is a local-first iOS/iPadOS 26 kitchen app with widgets and a share extension. Local inventory and user work are authoritative. Recipes entering or leaving the app require usable images, durable provenance, categories, and backward-compatible repair.

Read `PERFORMANCE_ARCHITECTURE.md` before changing persistence, imports, sync, images, QA, Home metrics, or any potentially unbounded collection. Its protections are required invariants, not optional cleanup.

`Secrets.xcconfig` is local and ignored. Production services use `https://api.sowensstudios.com`; never ship provider keys. Start in the feature named by the task, include extensions when affected, and run the narrowest tests plus the `Stocked` build.

Recipe views prefer publisher-original image URLs, retain exact downloaded bytes in cache, and fall back to embedded data only when offline or the source fails. Keep the thin charcoal image border consistent.

Discover starts with the shared RecipeDatabase populated by StockedMac/UnifiedWorker, refreshes when that database changes even if the UI cache is fresh, and round-robins qualified recipes by canonical publisher before applying the visible cap. MealDB is one fallback provider, never the exclusive or monopolizing feed. Every displayed recipe requires HTTPS imagery and real instructions.

Every Recipes visit and manual refresh also incorporates a bounded rotating sample plus the
highest-quality image-complete rows from the full SQLite RecipeStore corpus. Competing visit
refreshes cancel rather than publish out of order; the complete corpus remains searchable through
FTS and is never loaded wholesale into SwiftUI.

Recipe cards and details use `RecipeRecommendationExplainer` for confirmed, uncertain, missing,
expiring, and allergen facts. Recommendation feedback persists through `RecipeInterest`; do not
add screen-local preference stores. `LocalInventoryItem.confidence` is the shared derived trust
state, and ingredient coverage, grocery handoff, and cook-finish deductions route through
`FoodNameMatcher` rather than substring matching. Recipes always expose updating/current/offline
freshness while making clear that the full catalogue remains searchable.

Short recipe rails fill the live readable width on iPad and other wide containers instead of
leaving a phone-sized three-card strip beside empty space. Accessibility text shows fewer, wider
cards at once and retains horizontal scrolling for the remaining recipes.

RecipeDatabase is the canonical app-wide recipe view. Normalize clearly broken title casing at ingress and load, deduplicate by canonical source URL before normalized title, and preserve the surviving stable identifier. Every screen, widget, search, and suggestion must read this shared view rather than building a parallel recipe cache.
Every HTTPS source-attributed, image-complete recipe imported on iOS publishes through the same
Worker harvest catalogue used by StockedMac and is then re-ingested through the normal ETag sync.
Household membership never gates that publication. Preserve the original publisher name, URL, and
image URL; only source-less personal recipes remain local/household scoped.
Launch runs an idempotent, bounded backfill over existing user recipes so this rule covers old and
new imports rather than only saves made after the upgrade.

Retail enrichment uses authenticated UnifiedWorker `/retail/*` routes. Kroger and RapidAPI credentials remain server-side. Keep official provider location/product IDs optional, preserve original product images and exact aisle data, and treat price, availability, and inventory as short-lived store-specific metadata rather than household truth.

Kroger is the default store for new or reset installations and grocery-cart handoff. FatSecret is an additive server-side brand/nutrition source; enrichment fills missing or lower-confidence fields across historical repairs and future imports without replacing publisher provenance or stronger nutrition.

iOS uses MapKit for live nearby food-market discovery and merges Kroger catalog locations when
available. Barcode scans, inventory maintenance, grocery suggestions, substitutions, recipe
backfill, and serving calculations share a bounded USDA/FatSecret/publisher reconciliation cache.
Apple Foundation Models may normalize grocery lookup terms on eligible devices, but never changes
a user-visible name without review and always falls back deterministically when unavailable.
Inventory Scan follows the same rule: after a Worker or Foundation Models failure, its local
deterministic audit may propose safe storage-zone and shelf-life corrections but never invents
nutrition or silently renames an item.

Every existing inventory item is revisited in rotating bounded batches, and every future manual,
receipt, barcode, grocery-transfer, sync, or confirmed AI inventory change immediately enters the
same enrichment pipeline. Barcode identity uses Worker/Open Food Facts product data; nutrition is
reconciled by confidence across publisher labels, USDA, FatSecret, and local knowledge. Provider
failure preserves partial results and advances the cursor so one item cannot stall the database.

The shared retail reference catalogue refresh is incremental: page zero plus at most four rotating
pages, with at most two page requests active at once and a one-hour throttle. Merge successful
pages into the verified disk mirror; never fan out across the full remote catalogue at launch.

## Product and inventory intelligence contract

Product identity, brands, source reconciliation, aisle routing, and inventory review extend their
existing owners; do not introduce screen-local copies:

- `ProductCatalog` owns `ProductIdentity` and `ProductResolution`. Identity priority is verified
  barcode, provider product id, exact catalog alias, canonical product family, then generic name.
  Keys are durable readable strings, never `hashValue`. `CatalogEntry` may add verified barcodes
  and provider ids without requiring bundled legacy entries to have them.
- `GroceryKnowledgeBase` owns generic canonical keys, retailer/private-label equivalence, and
  `GroceryAisle`. `BrandDatabase` builds `BrandProfile` from the nutrition, catalog, and retailer
  data already present. `BrandPreferences` is a portable profile/settings payload; avoided brands
  remain reviewable and are never silently filtered out. It persists decode-safely on the existing
  `UserCookingProfile` and is passed through every production substitution surface.
- `SourceHealth` owns observed provider success, failure, freshness, and latency. Pure work consumes
  `SourceHealthSnapshot`. `ProductFieldReconciler` in `SourceConfidence` owns field-level winner
  selection and retains `FieldProvenance` plus losing alternatives for explanation and review.
- `StoreLayout` persists canonical item positions and decode-safe learned aisle positions. Exact
  learned products win, followed by learned branch aisle order, then `GroceryAisle.defaultOrder`.
  `StoreRouting.route` and `sections` are the structured walking-order APIs; the string sorter is a
  compatibility adapter.
- `InventoryProposalBatch` extends `ProposedChange`; it is the reviewable transaction boundary for
  manual, receipt, barcode, assistant, reconciliation, grocery-transfer, household, and import
  additions. Canonicalization merges duplicate additions and turns already-stocked products into
  quantity changes. `GuestDataStore.applyProposalBatch` still delegates to the established
  mutators, and adds one app-wide undo entry and inventory activity record for the transaction.
  Applied additions persist the winning field provenance on `LocalInventoryItem`; older rows decode
  without it and continue using their existing `SourceBadge` confidence behavior.
- `ReceiptNormalizedItem.proposedChange` is the receipt adapter. `SubstitutionEngine` consumes the
  same canonical equivalents and optional brand-preference snapshot. `LocalInventoryItem` derives
  its identity and explainable confidence assessment so legacy rows require no storage migration.

Migration is additive. New producers should create a reviewable add, collect it in one batch,
canonicalize against the current inventory, show the established review UI, then call
`applyProposalBatch`. Existing `ProposedChange` and `applyProposedChanges` callers remain supported.
The receipt pantry commit already copies resolved identity metadata and provenance while retaining
the reviewed name, quantity, zone, price, expiry, store, dedup, and analytics behavior. Manual Add
Item, barcode confirmation, grocery-to-inventory transfer, receipt-history re-import,
purchase-dedup metadata refresh, and CookConsumption now use `InventoryProposalBatch`; compatibility
merge policy preserves the established `GuestDataStore.isSameItem` behavior on those adopted flows.
The live receipt transaction retains its established per-line dedup/analytics commit but uses the
receipt proposal adapter for identity and provenance. Central Worker barcode, Open Food Facts,
USDA, and retail/FatSecret paths record latency and health; nutrition reconciliation consumes one
health snapshot set per batch. Remaining legacy add/import producers should migrate only when their
special metadata and user-facing undo behavior can be carried losslessly through the same adapter.
The themed brand editor in the existing Dietary & Brand Profile settings searches
`BrandDatabase.profiles` and mutates `UserCookingProfile.brandPreferences` directly; do not add a
second preference store or hide avoided brands from review.

The Cook hub has one approved primary-action treatment: the large cream illustrated Cook Now and
Cook Later cards. Do not reintroduce circle, pill, compact-row, or photo-tile alternatives for
these two controls; adapt the card contents for width and Dynamic Type without changing its shape.
On tall iPad and landscape canvases, center the complete Cook decision group vertically with a
flexible minimum height; when content grows, it must expand and scroll rather than clip.

Every post-login page uses `StockedShell` for app chrome. The centered `Stocked.` wordmark,
chevron, header height, safe-area spacing, and top position are fixed by `StockedChrome`; pages may
not override them. Root navigation uses the single `StockedTabBar` implementation so icon slots,
labels, selected shapes, hit targets, and placement remain identical while content changes.
Home and Cook use `StockedGreeting` with the live Preferences name and identical linked headline
typography. Selected root tabs retain charcoal fill with tan content in light mode and brighter
gold content in dark mode; use the shared selected-tab color tokens.

Home always uses its adaptive widget geometry, including on ordinary Pro-sized iPhones. Do not
restore the retired 393-point compact branch with 8–11 point labels or fixed card heights; widget
order stays stable while every illustrated widget uses one locked horizontal image-and-copy row,
atomic values select the largest linked font that fits, and controls grow vertically. All Home
widget artwork, icon shapes, spacing, and padding derive from available width through the shared
widget geometry; text size may increase card height but never reorder or detach paired content.
The Home board uses four stable logical tracks: widgets occupy 2x2, 2x4, 4x2, or 4x4 footprints,
with automatic extra vertical rows whenever Dynamic Type needs them. Each widget declares only the
sizes its current content can use: concise cards may become wider but not unnecessarily taller,
list cards may grow when they have more rows, and purpose-built cards stay fixed. In Edit Widgets
mode, the bottom-trailing handle commits one magnetic resize on release and persists it; unsupported
legacy sizes repair to the widget default. One occupancy map preserves order, fills safe openings,
and never permits overlap—repacking is atomic rather than animating frames through one another.
Home grid gutters stay compact (6 points on phones and 8 on regular-width canvases), and section
widgets reserve only their measured content height rather than an oversized decorative footprint.
The vertical packing lattice stays fine-grained (20 points on phones and 24 on regular-width
canvases) so intrinsic card heights do not leave a large rounded-off band before the next widget.
Dragging shows magnetic target outlines and reflows neighboring widgets before drop. Every move,
resize, add, removal, preset, and reset is persisted once and offers a reversible undo toast.
The layout menu provides Minimal, Daily Planning, Inventory Focus, and Cooking Focus presets plus
Reset Home; presets replace the board intentionally and never silently overwrite customization.
The widget gallery previews every permitted footprint and its content density. Kitchen-based
recommendations are opt-in, rank useful widgets without auto-adding them, and remain entirely local.
Expanded list widgets expose additional rows, while sparse list widgets temporarily collapse to
their useful 4x2 size and automatically expand when content returns. Empty widgets must provide a
relevant action. Live controls may mutate only their own underlying item and must offer undo.
Illustrations use per-widget minimum/maximum visual budgets and shrink before displacing text.
All widget content uses shared padding, corner radii, alignment, and accessory geometry; the custom
layout measures intrinsic Dynamic Type height and allocates additional rows before packing. Keep the
structural layout snapshot matrix and all-device/text-scale tests passing when this system changes.
Widget colors must use the semantic widget roles in `DesignTokens`—surface, primary/secondary text,
divider, focus, pressed, success, warning, and failure—rather than literal colors or arbitrary
opacity. Pantry, Cooking, Shopping, Planning, and Tools may use their family accent, but typography,
surface geometry, contrast, and interaction remain shared. Comfortable/Standard/Compact widget
density changes spacing only; it never changes typography or logical footprints. Edit mode must
retain visible menus and VoiceOver actions for move, resize, and remove alongside drag gestures.
Loading, empty, stale, failure, and content states are maintained in the Widget Theme Gallery;
every new widget and permitted footprint must appear there before release.
The illustrated primary Scan control is the single receipt/barcode entry point in the Home action
section; its menu branches to Receipt and Barcode. Do not add a second compact Scan control beside
Add and Log. Its paired grocery-bag artwork uses the same approximate vertical footprint as the
primary card while width-aware scaling keeps it from crowding the card on narrow canvases.
Stock Level is pinned as a compact vertical card in the hero's left column, with the still-life
artwork locked in the right column. It is never rendered below or on the right of that artwork;
text growth expands the left card vertically without changing the two-column relationship.

All app typography routes through the one Stocked text scale without category caps, one-line
truncation, or minimum-scale shrinking. The in-app preference and system Dynamic Type update every
page, sheet, control label, QA surface, generated label, and widget together. Text containers,
buttons, fields, list rows, sheets, and custom cards grow vertically at accessibility sizes; font
size alone must not change grid columns, move paired buttons to another row, or swap control types.
Only available width may change placement. New UI must use linked scalable font constructors,
flexible minimum dimensions, and multi-line labels rather than raw fonts, fixed text heights, or
ellipses.

Text entry uses the shared borderless `StockedThemedTextFieldStyle` at app and presentation
boundaries. Fields grow with text and use the active theme surface; page-local plain styling is
reserved for fields already hosted inside a custom themed input container.

Visual presentation styling is inherited from `stockedThemeEnvironment()`: Lists, Forms, row
heights, fields, tint, text, and scroll backgrounds use the same Stocked language on iPhone, iPad,
Split View, sheets, and covers. Screen canvases use `stockedScreen()` and modal canvases use
`stockedPresentationSurface()`/`StockedSheet`; form presentations default to the adaptive 760-point
maximum while readable and full-width variants must be chosen explicitly. Multiline input pairs
`stockedTextEditorContent` with `stockedInputSurface`, and shared cards use live layout metrics.
These boundaries may change horizontal placement only for available width; Dynamic Type grows row,
button, card, and editor height while vertical scrolling keeps native continuous behavior.

Onboarding hydrates and persists the single `UserCookingProfile`, including when the user skips
after answering only part of the quiz. Quiz content scrolls within its stable card at large text
sizes, and recipe filtering/ranking consumes saved cuisines and allergen exclusions. First-run
setup is intentionally limited to the six answers that immediately change recommendation safety
or ranking; schedule and equipment remain editable profile fields after onboarding.

Every corrective change must be evaluated as a cross-app invariant before it is implemented. If a
fix for one page would benefit another page, sheet, popover, widget, or flow, implement it at the
lowest shared layer (`DeviceAdaptiveRoot`, `StockedShell`, presentation surface, design-system
component, store, or service) and migrate existing call sites in the same change. Page-local fixes
are reserved for genuinely feature-specific behavior; copying the same remedy into isolated views
is not an acceptable substitute for a shared policy.

`AppWideExperience` is the shared contract for content states, route restoration, commands, undo
history, background activity, performance budgets, provenance, recommendation explanations,
adaptive setup, contextual help, notification preferences, household activity, form validation,
autosave feedback, privacy, pseudolocalization, accessibility matrices, and autonomous QA journeys.
The App Experience settings surface exposes controls and diagnostics without creating feature-local
preference stores. New screens reuse these types and the semantic design system; local-first data,
existing deep-link URLs, and older persisted settings remain compatible.

While Stocked QA is active, every touch-down displays a numbered, non-interactive ripple above all
app presentations without participating in hit testing. QA screenshots independently render the
recent numbered tap sequence, so evidence retains touch order without double-compositing the live
overlay. Turning QA off removes the overlay and touch observer.

Gesture ownership is fixed: Home widget editing uses a one-finger long press and exits with Done or
a tap on the page background; QA reporting uses a two-finger short press or device shake. Coach
marks and QA help must describe this same mapping, and neither recognizer may cancel app controls.

Recoverable household storage failures retry automatically with capped 0.5, 1, and 2 second
backoff while UI diagnostics report `Repairing household storage…`. Exhausted repair uses ordinary
queue backoff rather than the hour-long quota pause, and later polling continues automatically.

App-wide motion, scrolling, and alignment use `AppMotionSystem` rather than page-local springs or
scroll behaviors. Interaction roles map to the shared press, selection, standard, navigation, and
settle tokens; Reduce Motion removes spatial/decorative/repeating movement while retaining only a
brief opacity fallback. Custom drag releases use the predicted endpoint and
`StockedVelocitySnapPolicy`; live finger movement is never implicitly animated.

Vertical pages use native continuous deceleration with size-aware bounce; registered section targets
are reserved for programmatic navigation and must never capture a slow manual scroll. Compact filter
rails use chip snapping; visual card rails use one-card centered snapping, stable item identifiers,
position restoration, and enough edge margin to center the first and last card. Nested image rails
and standalone image lists track their own scroll phase and inject it into descendants. Never mark
every small row as a vertical target or mix chip and card settling behavior.

Visible images display memory hits immediately, postpone disk/network/decode work during direct
manipulation, resume visible work during deceleration, and retry after connectivity returns.
Speculative recipe prefetch is bounded, directional, cache-first, canceled when another gesture
begins, and debounced after idle. Embedded inventory photos use `CachedLocalDataImage`; do not call
`UIImage(data:)` from a SwiftUI body or lazy row. UIKit collection bridges must report phase to
hosted cells, animate diffs only while settled, and bounce only when their content exceeds the
viewport.

Controls that share a row use the shared equal-height and aligned-label primitives. Width—not text
size—decides column placement; larger text grows controls vertically. Short empty content centers
within the available canvas, long content remains top-aligned and scrollable, and every animation,
rail, grid, sheet, and custom gesture change must keep the motion/alignment regression matrix green.

## Inter-hub contract

`InterHubSystem` owns app-wide routes, durable pending intents, handoff context, reusable actions,
canonical recipe boundaries, grocery mutation outcomes and provenance, ingredient availability,
dependency declarations, background-work coalescing, and cross-hub search. The Stocked iOS app is
the owner. Producers are Home actions, widgets, notifications, Spotlight, deep links, Siri, the
share extension, imports, scans, QA, and background services. Consumers are MainTabView plus the
Home, Cook, Inventory, Recipes, and Grocery hubs. Recipe storage remains owned by `RecipeDatabase`
and `GuestDataStore`; the contract adapts those stores and does not create a competing recipe cache.

Rollout is additive: producers may migrate individually to `InterHubCoordinator.open`, while the
shell continues accepting the established notification names. Exact-item notifications are a
temporary hub-local delivery shim after a durable typed route switches the owning tab. Fallback is
the former NotificationCenter path; do not remove it until cold launch, queued delivery, exact-item
routing, and three-attempt dead-letter behavior are verified in production. Persisted intents older
than seven days and duplicate intents are repaired at startup, and the queue is bounded to 50.

Any new recipe model must provide a `CanonicalRecipeDescriptor` adapter before adding independent
save/shop/plan/cook logic. Any grocery producer must submit a `GroceryMutationRequest` and inspect
its structured result rather than append blindly. New hub-derived UI must declare its dependencies
in `HubDependencyGraph`; refresh from store/database revisions, not timers. Background producers
must use the coalescing coordinator with bounded retry and cancellation. Verification requires the
inter-hub contract tests, the existing logic and adaptive UI suites, a serial simulator build, and
a serial build-for-testing. The release smoke matrix covers cold-launch notification delivery,
widget and Spotlight routes, share import deduplication, recipe-to-grocery provenance, inventory
confidence propagation into Recipes/Cook, search result routing, and retry after offline recovery.

## Household sync and backup contract

The Stocked iOS app owns the local-first household contract. `GuestDataStore` and the feature
stores remain authoritative local data owners; `HouseholdSync` owns the durable outbound operation
journal, record/field clocks, checkpoints, receipts, health, tombstones, and Worker transport.
`HouseholdCloudKit` remains the same-Apple-ID mirror and nudge path, not a second source of truth.
Do not add a parallel queue, conflict database, feature store, or backup store.

Producers are GuestDataStore mutations, feature-store mutations, household membership changes,
foreground/background/manual refresh, imports, restores, and CloudKit change callbacks. Consumers
are the Worker push/pull routes, Household diagnostics and conflict review, Household/Settings UI,
CloudKit mirrors, and widget/derived-store refresh. Every outbound logical mutation has a stable
idempotency key and monotonic client sequence. Quantity changes additionally carry commutative
delta operations, while state records carry record and field revisions. Delete tombstones survive
relaunch and are removed only after the exact captured batch is acknowledged.

Roles provide defaults; explicit permission grants are additive and explicit denials win last.
The client gates UI with `HouseholdMember.can(_:)`, but the Worker must enforce the same permission
raw values for every mutation. Pull/push checkpoints are monotonic. A response receipt may
acknowledge all or only named idempotency keys; unacknowledged work stays queued. Health derives
from persisted receipts, failure counts, pending work, and stuck retry state so relaunch never
turns a degraded sync into a false healthy state.

`KitchenTransferManager` owns backup/export/restore. Format 3 `.stocked`, device, rollback, and
iCloud packages use AES-GCM encryption plus HMAC-SHA256 authentication with a synchronizable
Keychain key. Their readable manifest is versioned and includes payload/ciphertext checksums,
per-section counts/checksums, and an embedded-media identity/checksum manifest. Human-readable
`.json`, CSV, and text exports intentionally remain plaintext interoperability formats. New iCloud
backups use `CKAsset` (`backupAsset`) so photos do not hit the inline Bytes limit; restore continues
to accept legacy `backupData` and every schema-1/2 plaintext snapshot. Each iCloud record also puts
that package's 256-bit recovery key in CloudKit's end-to-end encrypted `encryptedValues` dictionary
and keeps only its non-secret key ID in ordinary metadata. Restore verifies the key ID against the
authenticated manifest and adds a recovered key to a key-ID ring; recovering one historical backup
therefore never invalidates newer or older keys.

Restore rollout is additive: preview and authenticate the whole package first, select any subset
of profile, inventory, grocery, meal history, recipes, plans, preferences, and feature data, then
persist an encrypted `kitchen_restore_rollback_v1` recovery point before applying any mutation.
Restore applies under household/feature remote guards, flushes through the existing persistence
owners, and exposes an explicit last-restore rollback. If a new envelope cannot be authenticated,
the fallback is to leave local data untouched and retain the prior rollback; permissive legacy
decoding is allowed only for files that do not advertise an encrypted envelope.

Roll out Worker protocol 2 before relying on partial acknowledgement or quantity-operation merge.
The Worker must persist recently seen idempotency keys per household, return request receipts,
advance checkpoints monotonically, merge quantity deltas once, retain field revisions, enforce
permissions, and preserve revisioned tombstones. Deploy the CloudKit `backupAsset`, `formatVersion`,
`encrypted`, `backupKeyID`, and encrypted `backupRecoveryKey` fields before switching production
backups; old records remain the fallback. Same-account/new-device recovery uses the encrypted
CloudKit field when the synchronizable Keychain item is missing or mismatched. A manually exported
encrypted `.stocked` file still requires a matching key-ring entry; plaintext JSON is the explicit
cross-account recovery format. Any unlock failure must leave local data untouched.

Verification requires `HouseholdDurabilityTests`, `HouseholdLogicTests`, merge/conflict tests,
legacy queue/status/tombstone fixtures, encrypted package round-trip and tamper tests, a photo-heavy
CKAsset restore, partial-ack replay after response loss, concurrent offline quantity edits, denied
role mutations, selective restore, forced rollback, schema-1/2 import, and a serial simulator build.
