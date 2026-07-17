# Stocked — Delta Fix 1 (2026-07-17)

Two full-file replacements resolving all 5 Swift 6 compile errors. Drop over the repo
root as before. (The blank screen was confirmed as an install-over-old-app artifact,
not a code issue — a delete + reinstall or a normal versioned update resolves it.)

## Fixes

1. **PurchaseDedupEngine — 4× "Call to main actor-isolated static method 'fold'"**
   `Stocked/SearchNormalization.swift` — the enum was unannotated, so the project's
   default main-actor isolation made `fold` main-actor-only; the nonisolated
   PurchaseDedupEngine couldn't call it. It's a pure string utility, now declared
   `nonisolated`. All existing main-actor callers are unaffected.

2. **ProfileAvatar — "Non-Sendable 'some View' returned from main actor-isolated
   'optionRow' to nonisolated context"**
   `Stocked/ProfileAvatar.swift` — the `PhotosPicker { label }` initializer's label
   closure is nonisolated in the current SDK, so it couldn't call the main-actor
   `optionRow` helper (which reads session theme state). The photo option is now a
   plain Button (main-actor label, same look) presenting the picker via the
   `.photosPicker(isPresented:selection:matching:)` modifier. Behavior identical.

## Audit
Every nonisolated engine added in the main delta was re-checked against every helper it
calls (FoodNameMatcher, IngredientMatcher, UnitMath, RecipeIngredients, ZoneDecisionEngine,
CookLaterCrossCheckEngine, ConnectivityMonitor.isOnlineFlag, StockedWorkerClient, Log):
all are nonisolated or nonisolated-safe statics. No other call sites of this pattern exist.
