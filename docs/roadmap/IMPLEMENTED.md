# 16 of 20 improvements — implemented

Everything that could be done purely in code is done. Four need a one-time action from you (listed
at the bottom) and were left alone.

**13 new files, 20 existing files edited.** No new dependencies. Every change is additive or
signature-compatible — existing call sites were preserved rather than migrated.

---

## Done

### #1 One substitution engine — `SubstitutionEngine.swift`
Five sources existed and never spoke to each other: `StockedDatabase` (73 entries, notes),
`IngredientIntel` (12, ratios), `userSubstitutions`, `SmartClient` (Worker), and
`CookLaterCrossCheckEngine` (7). The Substitutions tool was **Worker-only** — it showed nothing
offline. A swap you added yourself only ever applied on the Databases screen.

Now layered: **your swaps → built-in database → ratios → Worker**, deduped, with each result
labelled by source. Rewired `SubstitutionsToolView` (now works offline, results appear as you
type), `IngredientActionsButton`, `IngredientIntel.hasActions`, and
`GuestDataStore.inStockSubstitutes` — which used an *exact* match on user entries, so a swap saved
as "oat milk" never fired for a recipe line reading "milk".

### #2 One measure parser — `MeasureParser.swift`
Six parsers, each knowing a different subset of fractions. `ParsedQuantity` (8 call sites) couldn't
read `"1 1/2 cups"` at all and knew only ½¼¾. And a cup was **240 ml in one parser and 236.588 in
three others** — the same recipe measured differently depending on the screen.

One parser with the union of all six: ⅛…⅞ plus sevenths/ninths, mixed numbers, two-token units
(`fl oz`), European decimals, ranges. `ParsedQuantity.parse` and `IngredientIntel.parseMeasure` now
delegate to it with unchanged signatures, so `RecipeIngredients`, `ParsedIngredient` and
`IngredientMatcher` all improved for free. Cup aligned to 236.588 everywhere.

### #4 Toolbox ranked by use — `ToolboxUsage.swift`
39 tools in five fixed sections meant the 39th was invisible. Opens are counted; **Pinned** and
**Recent** rows sit above the grid; within each category, tools you use float up while untouched
ones keep declaration order so new tools aren't buried. Long-press to pin.

### #5 Undo on destructive actions
`ToastCenter.shared.undo` already existed. Wired into the paths that lacked it: tossing a leftover,
deleting a container label / takeout entry / harvest / event, and — most importantly —
`SplitStore.settleUp()`, which wiped an entire money ledger in one tap with no way back.

### #6 One persistence layer — `FeatureStore.swift`
Eight feature stores each re-encoded their whole array into UserDefaults on every mutation, on the
main thread. Now a generic `FeatureStore<Element>` over `LocalDatabase` (atomic background writes)
with the same 250 ms debouncer `GuestDataStore` uses, and **automatic migration** from the old
UserDefaults blob on first load. The old keys are left in place for one release so a downgrade
doesn't lose data. `StockedFeatureStores.flushAll()` runs on backgrounding.

### #8 Themed screen container — `StockedScreen.swift`
Forty screens each repeat four theme lines; forgetting one produces dark-on-dark. That is precisely
the QA Workbook bug — correct at the root, wrong once pushed. `.stockedScreen()` applies all four
as a unit. **21 screens migrated**, including `FamilyProfilesView`, which applied *no* theming at
all and silently inherited whatever its parent had.

### #9 Derived inventory indexes — `InventoryIndex.swift`
Views filtered the whole pantry inside `body`, re-running on every render pass. One index built per
mutation (keyed off the existing `inventoryRevision`), with `expiring(within:)` walking a presorted
array and stopping early. Adopted in Thaw Planner, Preservation Planner and Kitchen Assistant.

### #10 Global search extended
`GlobalSearchView` couldn't see four whole domains. Added **leftovers, planned meals, container
labels and tools** as first-class result types — 4 new enum cases through all six switches, scored
against the existing ladder (a leftover with a day left outranks a pantry substring match), each
with its own section and tap destination. Tools match fuzzily, so "convert" finds "Unit Converter".

### #11 Cooking consumes inventory — `CookConsumption.swift`
The biggest gap in the app. Four cook-complete paths, and only one touched inventory — behind a
sheet you could skip. Marking a meal cooked **from the planner**, which is how most people do it,
was a complete no-op on stock, so pantry value, low-stock, readiness and waste all drifted.

Now both planner paths build proposed deductions from the meal's ingredients, scaled by servings,
and route them through the existing `ProposedChange` + `applyProposedChanges` primitive. Leftovers
are captured in the same step. Levels are snapshotted *before* the write so undo restores exactly.

### #13 Receipt learning that actually re-fires — `ReceiptLearningIndex.swift`
`translateOCR` did an exact, full-string match, re-decoding the dictionary from UserDefaults **once
per receipt line**. So "ORG CHKN BRST" learned once did nothing for "ORG CHKN BRST 2LB" the
following week — corrections almost never fired again.

Now store-scoped (H-E-B's "GV" and Walmart's "GV" stop overwriting each other) with a token-overlap
fuzzy pass at a deliberately strict 0.7 threshold, built once per scan.

### #14 Adaptive notification timing — `NotificationEngagement.swift`
Five recurring reminder types plus 40 expiry alerts all firing at a time set once during setup.
Now learns when you actually open the app (app opens weighted 1, acting on a notification weighted
3) and shifts delivery toward it — **never more than three hours from the time you set, never
outside 7am–9pm**, and never at all until there's real evidence. User-toggleable.

### #15 Stale-while-revalidate cache — `SmartResponseCache.swift`
`SmartClient` — 16 endpoints backing substitutions, nutrition, expiry, seasonal — had **no caching
at all**. Every call was a live 12-second-timeout request; offline meant an empty screen.

Now cached answers render immediately (fresh under 1 hour, still served up to 14 days) with a
background refresh behind them. Applied to substitutions, nutrition, expiry and seasonal —
`expiryEstimate` alone is called once per line of every receipt.

### #16 Type roles and accessibility — in `StockedScreen.swift`
The app already had Dynamic Type scaling (`StockedType.scaled`) that most screens bypassed with
raw `.font(.system(size: 13))`. Rather than add a second scale, `StockedTextRole` names the seven
sizes actually in use and routes them through the existing one. Plus
`.stockedRowAccessibility()` for compound rows that otherwise read as three unlabelled VoiceOver
stops, and `.stockedTouchTarget()` for the 44pt minimum.

### #17 Four new App Intents — `StockedAppIntentsPlus.swift`
"What leftovers do I have", "What should I thaw", "How many days of food do I have", "What should I
use up". Thin wrappers over engines that were already deterministic and offline. Reads go through a
nonisolated storage-level reader so they work **with the app closed**. Follows the existing file's
`nonisolated static var` convention exactly — the thing that broke the build last time.

### #19 Sync no longer loses edits silently — `SyncConflictLog.swift`
Last-write-wins discarded the losing value with no record. Planned meals had **no conflict check at
all**, so a meal you moved could be silently reverted. The merge outcome is unchanged (so this
can't regress sync) — but what got replaced is now recorded, persisted, and reviewable, with a
dismissible banner.

### #20 One health view — `StockedHealthView.swift`
Three signals nobody could see together: `DiagnosticsMonitor`'s log (read by one uploader),
`StockedMetrics` (OSLog only), and the Worker's `/health` (never called by the app). Plus
`SyncDiagnosticsView`, fully built and **referenced from nowhere** since it was written.

One screen: Worker status/version/latency, crash and hang counts with the raw log, sync conflicts,
cache and storage sizes, notification timing, build info. Linked from Settings → Data & Storage.

---

## Verification

- **Brace/paren/bracket balance**: all 43 touched files pass a string- and comment-aware check.
  (5 untouched files report false positives — parentheses inside string literals.)
- **Symbol collisions**: 31 new top-level declarations, each in exactly one file, zero collisions
  across 341 Swift files. Caught one real collision — my `StockedType` clashed with the existing
  one in `DesignTokens.swift`; renamed to `StockedTextRole` and made it delegate to the existing
  scaler rather than duplicate it.
- **Exhaustiveness**: `ToolboxTool` — 39 cases across all 5 switches. `SearchResult` — 11 cases
  across all 6 switches plus the tap handler.
- **Signature compatibility**: every changed signature verified against its call sites.
  `translateOCR`, `learnOCRCorrection` and `ingredientQuickMenu` gained defaulted parameters, so
  all existing callers compile unchanged.

Not verified: **it has not been compiled.** There's no Swift toolchain here. The concurrency rules
this codebase enforces (`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`) were applied deliberately —
pure engines are `nonisolated`, stores are `@MainActor @Observable`, the one thread-safe legacy
type (`CIContext`) is `nonisolated(unsafe)` with justification — but only the compiler settles that.

---

## The four that need you

| # | Why it needs you |
|---|---|
| **#3** Swift test target | Adding a target is an Xcode UI operation. Everything else is ready: `TimelinePlanner`, `SplitMath`, `ReadinessCalculator`, `MeasureParser`, `EventMath`, `StoreRouting` are all pure and `nonisolated`, so tests need no host app. Start with `SplitMath.settlements` — money math that's wrong is the worst kind. |
| **#7** Sync the new feature data | Needs Worker-side schema changes and a `wrangler deploy`. #6 was the prerequisite and is done. |
| **#12** Crowd shelf-life data | Needs a new Worker endpoint and a deploy. `ShelfLifeEstimator` already takes a `crowdDays` parameter that nothing populates — the seam is waiting. |
| **#18** Widgets / Live Activities | Requires a new app extension target in Xcode. |

---

## One thing worth knowing

Two changes alter behaviour rather than just adding to it, and are worth watching on first run:

1. **The cup constant moved** from 240 ml to 236.588 in `ParsedQuantity`. Correct, but volume
   merges in the grocery consolidator will differ by ~1.4% from before.
2. **`ParsedQuantity.parse` is a new implementation.** It handles strictly more input than the old
   regex, but "strictly more" is a claim the compiler can't check. Its 8 call sites run through
   recipe matching and grocery consolidation, so that's where to look first if something reads
   oddly.
