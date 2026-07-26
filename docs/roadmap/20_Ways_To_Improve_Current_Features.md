# 20 Ways to Improve Stocked's Current Features

Written after building features 1–15. These are **improvements to what already exists**, not new
features. Several are things this session surfaced directly — duplicated logic, a theme bug that
only showed on pushed screens, a production crash that a test would have caught.

Ordered by **value ÷ effort**. Effort is honest: S = an afternoon, M = a few days, L = a week+.

---

## Tier 1 — Do these first (high value, low effort)

### 1. Collapse the three substitution sources into one
**Now:** Substitutions live in `IngredientIntel.substitutions`, `SubstitutionsToolView`,
`UserSubstitutionEntry` (user-added), and the Worker's `/smart/substitute`. Four answers to one
question, and they disagree.
**Change:** One `SubstitutionEngine` that layers: user entries → built-in table → Worker. First hit
wins, source is labeled in the UI ("your swap" / "Stocked" / "suggested").
**Why:** A user who adds "oat milk → almond milk" expects it everywhere. Right now it only applies
in one screen. This is a correctness bug wearing a duplication costume.
**Effort:** S

### 2. One unit parser, not four
**Now:** `UnitConverter`, `IngredientIntel.parseMeasure`, `MeasurementConverterView`, and the Worker
each parse "1 1/2 cups" separately. They handle fractions, ranges and unicode ½ differently.
**Change:** Extract `MeasureParser.parse(_:) -> Measure?` as the single entry point. Everything else
calls it. Move the density table with it.
**Why:** Every parsing bug currently has to be fixed four times, and the toolbox's quick-actions
(the "4g of sugar" inline converter) is only as good as the weakest parser.
**Effort:** S

### 3. Add a Swift test target for the pure engines
**Now:** 68 Worker tests, zero Swift tests. The MetricKit crash in 4.13(62) shipped to TestFlight.
**Change:** A test target covering the deterministic engines — `TimelinePlanner`, `SplitMath`,
`ReadinessCalculator`, `ThawCalculator`, `EventMath`, `StoreRouting`, `ShelfLifeEstimator`,
`MeasureParser`. All are `nonisolated` and pure, so they need no host app and run in under a second.
**Why:** Every new feature this session put its logic in a pure type specifically so this is cheap.
Take the payoff. Start with `SplitMath.settlements` — money math that's wrong is the worst kind.
**Effort:** S

### 4. Make the Toolbox rank by use, not by hardcoded category
**Now:** 39 tools in five fixed sections. The 39th is functionally invisible.
**Change:** Track open counts. Pin a "Recent" row at the top, sort within each category by frequency,
and let the user star favourites. Keep search as-is — it already works well.
**Why:** The toolbox grew from 20 → 39 this session. Discovery is now the bottleneck, not capability.
**Effort:** S

### 5. Undo for every destructive action
**Now:** Tossing a leftover, deleting an inventory item, clearing a settled ledger — all immediate
and final.
**Change:** A shared `UndoToast` — action runs immediately, a snackbar offers "Undo" for 5 seconds,
backed by a small in-memory stack.
**Why:** Cheap to build, and it converts the scariest interactions in the app into safe ones. The
`SplitStore.settleUp()` I just wrote wipes a whole ledger with one tap; that needs a safety net.
**Effort:** S

---

## Tier 2 — Structural (high value, real work)

### 6. Unify the per-feature `UserDefaults` stores
**Now:** `leftovers_v1`, `familyProfiles_v1`, `kitchenEvents_v1`, `sharedExpenses_v1`,
`storeLayouts_v1`, `takeoutLog_v1`, `gardenHarvests_v1`, `containerLabels_v1`, plus older keys.
Each re-encodes its whole array on every mutation.
**Change:** One `FeatureStore<T>` generic backed by a JSON file in Application Support, with
debounced writes, atomic replace, and a versioned migration hook. Same call sites, one implementation.
**Why:** UserDefaults is the wrong home for growing arrays (it's loaded wholesale at launch and
synced to disk on a timer). It also blocks #7 — none of this data syncs across a household today.
**Effort:** M

### 7. Extend household sync to the new feature data
**Now:** Inventory, grocery and meal plan sync. Leftovers, events, shared costs, store layouts and
container labels are device-local.
**Change:** Once #6 lands, every `FeatureStore` gets the same last-write-wins envelope the inventory
already uses (`updatedAt` + `lastWriterID`).
**Why:** Shared costs that only one roommate can see is a broken feature. Same for leftovers in a
shared fridge. These are inherently multi-person.
**Effort:** M

### 8. One themed container instead of per-view theme plumbing
**Now:** Every view repeats `.background(session.themeBgColor.ignoresSafeArea())` and reaches for
`themeTextColor` individually. The QA Workbook bug (dark text on dark background on pushed screens)
was exactly this — a screen that forgot one of the calls.
**Change:** A `.stockedScreen()` modifier that applies background, foreground style, tint and
`preferredColorScheme` in one place. Convert screens incrementally.
**Why:** The bug class disappears rather than being fixed one screen at a time. ~40 views currently
repeat the same four lines.
**Effort:** M

### 9. Derived inventory indexes instead of re-filtering in every body
**Now:** Views compute things like `inventoryItems.filter { $0.storageCategory == .freezer }` inside
`body`, so it re-runs on every render. `ThawPlannerView`, `PreservationPlannerView` and
`EmergencyPantryView` all do this over the full list.
**Change:** Maintain `byZone`, `expiringSoon`, and a lowercased name index on `GuestDataStore`,
recomputed on mutation rather than on read.
**Why:** Fine at 80 items, visibly janky at 800. Users who scan receipts hit 800.
**Effort:** M

### 10. Global search
**Now:** Search exists per-screen (toolbox, recipes, inventory) with different behaviour in each.
**Change:** One search surface that spans inventory, recipes, tools, leftovers, labels and planned
meals, with typed result sections. `FuzzyMatch` already exists and is good.
**Why:** As surface area grows, "where was that thing" becomes the dominant navigation cost.
**Effort:** M

---

## Tier 3 — Make existing features actually smart

### 11. Close the loop: cooking a planned meal should consume inventory
**Now:** Marking a meal cooked sets `isCooked`. The chicken is still in the pantry.
**Change:** On cook, match ingredients against inventory, show a confirmation sheet with proposed
deductions, apply on accept. Offer "save leftovers" in the same sheet — it feeds the leftovers
queue I just built.
**Why:** This is the single biggest gap between what the app models and what happened in the kitchen.
Every downstream number (pantry value, readiness, low stock, waste) is wrong without it.
**Effort:** M

### 12. Feed learned shelf life back to the Worker as crowd data
**Now:** `ShelfLifeEstimator` already accepts `learnedDays`, `crowdDays` and `aiDays` — but only
`learnedDays` (this device) is ever populated.
**Change:** Post anonymised `(normalized name, zone, actual days before used/tossed)` to the Worker;
serve back a median per name/zone. The parameter is already in the signature.
**Why:** The seam was deliberately built. Filling it turns a single-user guess into a real dataset,
and it's the app's most defensible long-term advantage.
**Effort:** M

### 13. Teach receipt scanning per-store line formats
**Now:** One general parser for every receipt. Corrections the user makes are discarded.
**Change:** Key learned corrections by store name (`storePurchasedAt` is already captured):
abbreviations → real names, column positions, which lines are tax/discount. Apply on the next
receipt from that store.
**Why:** Receipt scanning is the highest-friction, highest-value input path. It gets better with use
or it stays mediocre forever. Pairs naturally with the store-layout learning from feature 8.
**Effort:** M

### 14. Adaptive notification timing
**Now:** Expiry and daily-brief notifications fire on a fixed schedule.
**Change:** Learn when the user actually opens the app and engages with notifications; shift delivery
into that window. Cap total notifications per day and merge related ones into a single digest.
**Why:** Notification fatigue kills pantry apps. Fewer, better-timed nudges beat more of them, and
the thaw/leftover/expiry reminders now all compete for the same attention.
**Effort:** M

### 15. Stale-while-revalidate caching for Worker calls
**Now:** `SmartWorkerClient` calls go out live. Offline means an empty screen; a slow network means a
spinner.
**Change:** Cache each response keyed by request hash. Render cached content immediately, refresh in
the background, show a subtle "updated" indicator. The Worker already sets `Server-Timing` and has
Cache API in front of it — mirror that policy client-side.
**Why:** Kitchens have bad Wi-Fi. The app should never look broken because the network is.
**Effort:** M

---

## Tier 4 — Polish and reach

### 16. Accessibility pass on Dynamic Type and VoiceOver
**Now:** Heavy use of fixed `.font(.system(size: 11…15))`. At larger accessibility sizes, stat rows
and tool tiles will clip or truncate. The toolbox tiles have good labels; most newer screens don't.
**Change:** Move to relative sizing (`.font(.system(.caption, design: .default))`), verify at
AX3, add `accessibilityElement(children: .combine)` to compound rows.
**Why:** Food and health apps skew older. Fixed 11pt type is a real exclusion, and it's a cheap fix
caught early.
**Effort:** M

### 17. Expand App Intents / Siri to the new surfaces
**Now:** `MarkItemUsedIntent` and `AddItemIntent` exist.
**Change:** Add "What's expiring?", "Log leftovers", "What should I thaw?", "How many days of food do
I have?" — each maps to an engine that already returns a plain-text answer
(`KitchenAssistantEngine`, `ReadinessCalculator`, `ThawCalculator`).
**Why:** The hard part (deterministic offline answers) is already done. The intents are thin wrappers.
Hands-free matters specifically in a kitchen.
**Effort:** S–M

### 18. Widgets and Live Activities
**Change:** A home-screen widget for "expiring in 3 days" and today's meal; a Live Activity for
kitchen timers and for a thaw countdown once one is scheduled.
**Why:** These are glanceable-by-nature features currently buried two taps deep. The thaw reminder in
particular is worth more on the lock screen than in a notification that gets swiped away.
**Effort:** M

### 19. Surface household sync conflicts instead of resolving silently
**Now:** Last-write-wins with `updatedAt` + `lastWriterID`. The loser's edit vanishes with no trace.
**Change:** When a merge discards a conflicting field, record it and show a small "2 changes from
Sam were replaced" banner with a way to review.
**Why:** Silent data loss is the fastest way to lose trust in a shared app. The metadata to detect
this is already in the model — it's just not surfaced.
**Effort:** M

### 20. One health view over diagnostics, metrics and the Worker
**Now:** `DiagnosticsMonitor` writes local logs, `StockedMetrics` receives MetricKit payloads, and
the Worker has a deep `/health` — three signals nobody looks at together.
**Change:** A single internal screen: last crash, hang rate, Worker version and latency, sync status,
cache hit rate, storage used. Ship it behind the existing debug gate.
**Why:** The 4.13(62) crash was diagnosable from its stack trace in minutes, but only because it was
reported by hand. This makes the next one visible without a bug report.
**Effort:** M

---

## Cross-cutting notes

**The pattern worth keeping.** Features 1–15 all put logic in `nonisolated` pure types
(`TimelinePlanner`, `SplitMath`, `ReadinessCalculator`, `EventMath`, `StoreRouting`,
`HarvestMath`, `TakeoutMath`, `PreservationGuide`) with the SwiftUI view as a thin shell. That's why
#3 is cheap and why any of these can move to the Worker later without a rewrite. Hold the line on it.

**The concurrency tax is now understood.** Every compile error this session traced back to
`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. The rules that resolve it: pure utilities and value
models get `nonisolated`; framework delegates that fire off-main get `nonisolated` on the callback;
thread-safe legacy types get `nonisolated(unsafe)` with a written justification. Worth putting in a
CONTRIBUTING note so it isn't rediscovered each time.

**Deferred decisions still open.** Three duplicate substitution sources (#1) and four unit parsers
(#2) are called out above. Also outstanding: whether to keep the `content/` and `site/` folders, and
whether `HOMEBASE_URL` should fold into `Secrets.example.xcconfig`. The QA Workbook remains deleted —
git history is the only recovery path.
