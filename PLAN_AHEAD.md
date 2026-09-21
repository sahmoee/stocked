# Plan ahead

Open either meal planner and choose **Plan ahead · dates, templates & repeats**. These tools work
locally without a new account, paid service or AI request. Household members share them through
the existing household connection when meal-plan sharing is enabled.

## Use it

1. **Dates:** add a meal with a real date, servings and ingredients. Browse earlier or later weeks.
   Choose a saved recipe in the editor to copy its meal details, or enter your own.
2. **Templates:** make a reusable seven-day pattern or capture the active week. Edit each meal's
   day, type, servings and ingredients. Saving a template does not change the active plan.
3. **Repeats:** choose a template, first date, time zone, interval of one to four weeks and one to
   twelve repetitions. Save, preview the exact dates and ingredients, then confirm the additions.
   Repeats are finite, reviewed additions; nothing schedules itself while the app is closed.
4. **Add to the active week:** review dated meals from the displayed dates that fall between today
   and six days ahead. Confirm to copy them into the normal planner. Existing meals stay; the same
   name in the same day/type slot is skipped. This is a snapshot using the active planner's day
   slots, not a live calendar link or a midnight rollover service.

Future dated meals do not reserve pantry food, add groceries, appear as cooking candidates or alter
widgets. The normal active-week copy uses those existing features once confirmed. It starts with
clean cooking/building/cook-ahead state. Its dated reference is marked as used; edit the active meal
in the normal planner. Changing a template or repeat rule never rewrites dates already accepted.
Skip an occurrence to preserve that exception during later previews. Removing a rule keeps its
dated meals. Removing a used dated reference leaves its active-week copy alone.

Editors and previews reject stale versions, including a meal removed before a preview starts.
Stable occurrence and active-meal IDs prevent repeated generation or activation. A preview crossing
midnight needs review again if its day offsets change. During the same visit, Undo removes only
unchanged additions; after a handoff, both the dated reference and active copy must still match.
Later edits, cooking, deletions and unrelated meals are preserved. Undo is temporary, not a backup.

## Storage, sharing and recovery

Stocked iOS owns `PlanAheadCore`, editors and `PlanAheadStore`. The store persists small feature
collections through the existing `FeatureStore` / `LocalDatabase` owner. `GuestDataStore` remains
the sole active-planner owner. Dates use explicit Gregorian civil dates and named time zones.
No recipe database or separate household server is introduced.

UnifiedWorker registers `scheduledMeals`, `mealPlanRules`, `mealPlanTemplates` and `smartCookbooks`
in the existing household feature payload, merge and tombstone registry. The three plan collections
require meal-plan edit permission and follow meal-plan sharing; cookbook rules require recipe edit
permission and follow recipe sharing. Inventory sharing is independent. Server permissions remain
authoritative. Outbound queues and acknowledgements include only the enabled domains actually sent;
disabled, rejected and unacknowledged edits remain queued. Oversized requests fail visibly and retain
work rather than silently dropping accepted records.

Deploy the compatible Worker before installing the client. Older clients omitting new collections
leave them intact; no database migration, household reset, route or namespace change is needed.
Offline edits persist locally and retry through the existing queue. Stable IDs, revision checks and
scoped tombstones provide the retry path. Old providers cannot supply cross-device support for the
new collections; local planning remains usable while the provider is updated.

Full iOS Kitchen Transfer feature backups include the four optional collections. Restoring a backup
from before this feature preserves collections absent from that backup, including during replace.
Explicit feature wipe clears them and temporary undo. Existing encrypted backup/rollback rules still
apply. Mac remains a recipe/content tool: it has no new planning UI and its existing backup does not
include these iOS feature collections. Use iOS Kitchen Transfer to back them up.

## Bounds and verification

- Templates: up to 21 meals each; local growth up to 20 templates / 64 KiB.
- Repeat rules: up to 50 / 16 KiB; each expansion at most 252 candidates and within one year.
- Dated meals: local growth up to 600 / 256 KiB; the active week stays below 201 meals.
- Titles and ingredient lines are bounded; dates, time zones, servings and UTF-8 payloads validate
  before saving. Remote unions/restores are never truncated to local limits. If a merged collection
  exceeds a limit, reduction-only local edits and deletes remain available.
- Cookbook limits and usage are in `SMART_COOKBOOKS.md`. New code is original and uses Apple system
  frameworks. Existing sources and inspiration credits remain in Settings → Sources & Credits and
  `THIRD_PARTY_NOTICES.md`; no third-party application source or new package was copied.

Native commands, run from the iOS repository:

```sh
xcrun swiftc Stocked/PlanAheadCore.swift scripts/PlanAheadChecks.swift -o /tmp/stocked-plan-ahead-checks
/tmp/stocked-plan-ahead-checks
xcrun swiftc Stocked/PlanAheadCore.swift Stocked/MealPlanExchange.swift Stocked/PlanAheadStore.swift scripts/PlanAheadStoreChecks.swift -o /tmp/stocked-plan-store
/tmp/stocked-plan-store
python3 scripts/check-household-features.py /tmp/stocked-household-feature-checks
```

The core checks exercise dates, DST, leap days, bounds and stable IDs. Store checks compile the
production store with in-memory external-owner fixtures and cover stale edits/previews, duplicate
handoffs, skipped dates, permissions, conservative undo and oversized remote preservation. The
household harness compiles production merge/backup code; Worker tests verify both protocol versions,
permissions, omitted legacy fields, restoration and tombstones. A generic iOS build covers the app,
widgets and share extension. These do not prove real disk/network recovery or device UI behavior.
In-app QA sections 51 and 52 retain untested device, accessibility and two-device journeys.
Simulator testing remains paused. No TestFlight upload or release sign-off is implied.

September 5, 2026 verification: 53 core/date checks, 53 planning-store checks, 27 cookbook checks
and 34 sync/backup checks passed. Worker passed 129 tests, typecheck, dry-run and read-only live
health/authentication checks; provider version `be581647-032b-44ef-87c8-33801541c5bc` is deployed.
The final generic iOS build passed, with version 5 / build 186 matched across app and extensions.
Mac was unchanged. Batch 3 is paused before optional free connections in batch 4.
