# Stocked cumulative Build Buddy delta

This package replaces the previous unified Cook Later package. It includes the earlier engineering, source-quality, cache, nutrition, intelligence, sync, and unified-planning changes, then pairs the Cook Later implementation with the supplied Plan / Shop / Prep command-center mockup.

## Cook Later command center

- Keeps `GuestDataStore.plannedMeals` as the single source of truth for future meals.
- Presents one workspace with **Plan**, **Shop**, and **Prep** modes instead of separate planning systems.
- Retains all contextual entry points from Cook, Inventory, Recipes, Grocery, and related flows.
- Uses item-backed sheets and explicitly identifiable payloads rather than Bool-plus-optional presentation state.

## Plan

- Seven-day meal workspace with breakfast, lunch, dinner, and snack slots.
- Readiness ring and counts for planned meals, missing groceries, prep work, and allocation conflicts.
- Add-meal flow for saved recipes, current inventory, expiring food, cached online suggestions, recent meals, and custom meals.
- Meal-detail ingredient check showing on-hand, running-low, and needed states.
- Serving adjustment, shortage-to-grocery actions, and cross-meal planning-impact warnings.
- Inventory context shows available, already planned, and unallocated quantity.
- Calendar overview visualizes planned, cooked, prep, and shopping activity for the persisted planning horizon.

The current data model stores planned meals as a seven-day `dayIndex` horizon. The calendar deliberately edits only those persisted days instead of inventing multi-month persistence. Extending storage beyond seven days should be a separate model migration.

## Shop

- Combines shortages across planned meals rather than generating isolated lists per recipe.
- Performs compatible quantity and unit aggregation when inventory data permits it.
- Shows which planned meals caused each need.
- Supports quantity adjustment and one batched **Add All to Grocery List** action.
- Avoids repeated store mutations by assigning the completed grocery array once.
- Offers narrowly scoped ingredient substitutions and highlights substitutes already available in inventory.
- Applies an accepted substitution to every affected planned meal.

## Prep

- Generates preparation opportunities from meal timing, storage zone, and ingredient type.
- Includes thawing, marinating, chopping, and batch-component suggestions.
- Groups work by day and persists completion through the existing prep-completion store.

## Cross-check engine

`CookLaterCrossCheckEngine` is a pure, explicitly `nonisolated` helper. It parses ingredient quantities, normalizes common units, estimates inventory availability, detects cross-meal over-allocation, aggregates shortages, evaluates substitutions, and generates prep actions. Its DTOs are immutable and `Sendable`, so calculations can remain actor-safe under Swift 6 default main-actor isolation.

## Scope and project safety

- Additive, targeted Swift changes only.
- New Swift files rely on Xcode synchronized folders; no project-file registration is included.
- No `project.pbxproj` edits.
- No version/build-number scripting.
- No secrets or API keys.
- No SwiftData unique constraints.
- No automatic SwiftData CloudKit configuration.
- No per-request Workers KV writes.
- Existing Worker Cache API and household-sync protections from the earlier cumulative batch remain included.

## Tests

`CookLaterPlanningTests.swift` now covers:

- Pantry-aware plan suggestions.
- Grocery candidate generation.
- Cross-meal inventory over-allocation.
- Aggregated shopping shortages.
- Substitute availability from inventory.
- Thaw and chopping prep intelligence.
