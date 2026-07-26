# Crash fix — launch crash on upgrade (build 65 → 66)

## What you saw
FR-01 failed when installing over an existing version: the app crashed on launch and only a
delete-and-reinstall got you back in. All five TestFlight crash logs are the **same** crash.

## Root cause
`Exception: Thread stack size exceeded due to excessive recursion` — an infinite loop at
`FeatureHouseholdSync.swift:64`, 10,000+ frames of `LeftoversStore.entries.modify`.

It was my bug from the household-sync work (launch-readiness 1.4). The stamping function took the
store's array as `inout` and was handed `&entries` **from inside `entries.didSet`**:

```swift
var entries = [...] { didSet { FeatureSync.shared.didMutate(..., new: &entries) } }   // WRONG
```

Taking an `@Observable` property as `inout` re-enters its `modify` accessor, and that accessor
fires `didSet` **again on resume — unconditionally**, whether or not anything changed. So
`didSet → &entries → didSet → &entries → …` never terminated.

### Why only on upgrade
A **fresh install** starts with empty feature stores — nothing to stamp, so the pass did nothing
and never recursed. An **upgrade** loads the previous build's saved rows, which have `updatedAt == 0`
(the sync fields didn't exist yet). Those zero-stamped rows triggered the stamping pass on first
load → recursion → crash. That's exactly "breaks when installed over an old version."

## The fix (two parts)
1. **No more `inout` into a `didSet`.** `didMutate(…, new: inout [T])` is replaced by a pure
   `stampMutation(…, current: [T]) -> [T]` that returns a fresh array. Each store assigns it **once**,
   behind a `_stamping` re-entrancy guard, so the follow-up `didSet` is a cheap no-op. Recursion is
   now structurally impossible — no observed property is passed by reference anywhere.

2. **Initial load no longer stamps.** Each store's `init()` wraps `store.load()` in the same guard,
   so migrated rows aren't stamped or pushed on launch (which also avoids a startup push storm and a
   cascade of singletons initializing during construction).

## Files changed
- `Stocked/FeatureHouseholdSync.swift` — `didMutate(inout)` → `stampMutation() -> [T]`.
- `Stocked/LeftoversLifecycle.swift`, `FamilyProfiles.swift`, `EventPlanner.swift`,
  `CostSplitting.swift`, `GardenHarvest.swift`, `ContainerLabels.swift`, `TakeoutLog.swift` —
  guarded assignment in `didSet`, guarded initial load.
- `StockedTests/FeatureEngineTests.swift` — 3 regression tests: pre-sync rows decode with
  `updatedAt == 0` (the crash trigger, now handled), money survives migration, `stamped` always
  moves the timestamp off zero.

## Verify after rebuilding (build 66)
- Re-run **FR-01** installing over the crashing build — no delete needed.
- **E-06** (upgrade migration) in the checkbook: create data in all 8 feature tools on the old
  build, upgrade, confirm everything is present and the app launches.
- Add/edit/delete a leftover, an expense, an event — each should save without hanging.

No data migration on your side is required; the fix is code-only. The prior crash did not corrupt
data — the app died before writing anything.
