# Stocked — 15 More Big Features (round 2)

Written **after** auditing the actual codebase (334 Swift files), not from assumptions.

---

## First: corrections to round 1

Auditing the zip showed several of my earlier suggestions **already exist**. Owning that up front so
you don't spend time on them:

| Round-1 suggestion | Reality |
|---|---|
| #5 Weekly Meal Planner | **Exists** — `WeekMealPlannerView`, `MealPlannerView`, `MealPlannerSubViews`, `MealPrepView` |
| #6 Hands-Free Cook Mode | **Largely exists** — `VoiceCookControl`, `SpeechReader`, `CookTimerLiveActivity`, `StepTimerEngine`, `FullScreenCookView` |
| #7 Nutrition + HealthKit | **Exists** — `HealthKitManager`, `NutritionDatabase`, `USDANutritionClient`, `LogMealClient`, `NutritionBackfill` |
| #14 Spend & Budget | **Largely exists** — `RecipeCost`, `RecipeBudgetStatus`, `BrandPriceView`, `ReceiptProcessingService`, `BudgetTrackerView` |
| #4 Waste Coach | **Partly exists** — `ToolboxInsights` (waste insights), `KitchenHealthScore`, `KitchenWrappedView` |
| #2 Auto-Replenishment | **Partly exists** — `StockGoalsSetupView`, `KitchenStock`, `InventoryConsumptionCoordinator`, `consumptionLog` |

**Still genuinely missing** from round 1: Apple Watch (no watchOS target at all), real-time
WebSocket collaboration, multi-item shelf scan, CRDT offline sync, multi-location kitchens,
cookbook sharing via Universal Links.

### Duplication I introduced — worth cleaning up
- **Substitutions now has 3 sources of truth**: your existing `SubstitutionDatabase` +
  `SubstitutionReviewSheet`, my Worker `/ingredients/substitute`, and my local table in
  `IngredientIntel`. Consolidate on `SubstitutionDatabase` and have the others defer to it.
- **Quantity parsing / unit conversion has 4**: `QuantityParser`, `UnitMath`, `UnitConverter`, and
  my `IngredientIntel.parseMeasure`. `IngredientIntel` should call the existing ones.
- **Nutrition estimate**: my Toolbox tool duplicates `USDANutritionClient` + `NutritionDatabase`,
  which are more accurate. Point the tool at those instead of the Worker heuristic.

---

## The 15 new features

### 1. Conversational Kitchen Assistant
Ask in plain language — "what can I make with chicken and rice in 30 minutes, no dairy?" — and get a
real answer that knows your pantry, diet, and equipment.
**Builds on:** `NLQueryParser`, `StockedIntelligence`, `RecipeIntelligence`, the Worker's AI routes,
`SpeechReader`. You have every part except the conversation layer.
**First slice:** text-only Q&A over pantry + recipes on the Home tab. **Size: L**

### 2. Grocery Delivery / Cart Handoff
One tap sends your list into an Instacart / Walmart / Kroger cart instead of being read off a screen.
**Why:** the only feature here with direct revenue (affiliate/referral), and it closes the loop from
"list" to "food in the house."
**Builds on:** `GroceryStoreFinderView`, `GroceryListView`, `ProductCatalog`, `/prices/compare`.
**First slice:** deep-link handoff to one retailer with the list pre-filled. **Size: M**

### 3. Per-Person Family Profiles
Household members become *eaters*, not just accounts: per-person allergies, dislikes, portion sizes,
and goals — so meal suggestions satisfy everyone at the table.
**Builds on:** `HouseholdModels` (roles exist), `DietaryProfileView`, `ServingSizeView`.
**First slice:** per-member allergy list that filters recipe suggestions. **Size: M**

### 4. Leftovers Lifecycle
Cooked meals become tracked items with their own (short) expiry, portion count, and second-life
suggestions — "turn Sunday's chicken into tacos before Wednesday."
**Why:** leftovers are where most household food waste actually happens.
**Builds on:** `pastMeals`, `LeftoverIdeasView`, `ShelfLifeEstimator`, `CookAheadAndFinish`.
**First slice:** "save as leftovers" at cook completion → dated entry in inventory. **Size: M**

### 5. Freezer & Thaw Planner
Freeze dates, freezer-burn warnings, and thaw-time math with a "take it out tonight" reminder tied to
tomorrow's meal plan.
**Builds on:** zones + `ZoneDecisionEngine`, `ShelfLifeEstimator`, `plannedMeals`, notifications.
**First slice:** thaw reminder generated from tomorrow's planned meal. **Size: M**

### 6. Event & Dinner-Party Mode
Plan for guests: headcount, per-guest dietary constraints, scaled shopping list, and a run-of-show
timeline so everything lands on the table together.
**Builds on:** `ServingSizeView`, `RecipePortionsEditSheet`, `CompoundingPrepEngine`, `MealPrepView`.
**First slice:** guest count + constraints → scaled, consolidated shopping list. **Size: L**

### 7. Shared-Cost Households (roommates)
Track who bought what, split shared groceries, and settle up — a ledger on top of the pantry.
**Why:** roommate households are a large, underserved segment no kitchen app handles well.
**Builds on:** household sync, `priceHistory`, `ReceiptProcessingService` (receipts already itemize).
**First slice:** mark items "shared vs mine" + a running who-owes-whom balance. **Size: M**

### 8. Per-Store Layout Learning
Learn *your* store's aisle order from how you actually check items off, then sort the list to match —
so shopping becomes one pass, no backtracking.
**Builds on:** `itemStoreHistory`, `GroceryDedup`, aisle categorization already in `/grocery/optimize`.
**First slice:** remember check-off order per store and reuse it next visit. **Size: M**

### 9. Preservation & Bulk-Buy Planner
Bought 10 lbs of tomatoes or joined a CSA? Get a plan: what to freeze, can, dry, or cook now — with
resulting yields written back into inventory.
**Builds on:** `ShelfLifeEstimator`, `CookingMethodCatalog`, `KitchenEquipment`.
**First slice:** "I have a surplus of X" → ranked preservation options with shelf-life gained. **Size: M**

### 10. Emergency Preparedness Pantry
A "days of food and water on hand" readout, shelf-stable rotation reminders, and a preparedness goal
you can actually maintain instead of forgetting a bin in the garage.
**Why:** distinctive, seasonally viral (hurricane/winter), and a genuinely useful reason to keep
inventory accurate.
**Builds on:** inventory + `ShelfLifeEstimator` + `KitchenHealthScore` scoring patterns.
**First slice:** "you have ~6 days of food" card + expiring-stock rotation nudges. **Size: M**

### 11. Multi-Recipe Timeline Orchestration
Cooking three dishes for one meal: merge their steps into a single timeline so everything finishes at
the same moment, with interleaved timers.
**Why:** the hardest part of real cooking, and almost no app does it well.
**Builds on:** `StepTimerEngine`, `CookAheadAndFinish`, `HandsOffOpportunityView`,
`CompoundingPrepEngine`, `CookingSessionModel` — the primitives are all there.
**First slice:** two recipes → merged step list with a shared countdown. **Size: L**

### 12. Localization & Regional Food Data
Real multi-language support plus regional ingredient names, units, and store data — the unlock for
markets outside the US.
**Builds on:** `Localization` (scaffolding exists), `UnitConverter` (metric already), `IngredientDatabase`.
**First slice:** Spanish + metric-first, with localized ingredient synonyms in matching. **Size: L**

### 13. Restaurant & Takeout Logging
Log meals you didn't cook so spend, nutrition, and habits reflect reality instead of only home cooking.
**Why:** without it, every insight the app gives is measuring half the picture.
**Builds on:** `LogMealClient`, `pastMeals`, receipt scanning (restaurant receipts too), budget views.
**First slice:** quick "ate out" entry with cost + rough calories. **Size: S**

### 14. Garden-to-Pantry
Log harvests straight into inventory, track what your garden produces over a season, and plan
plantings from what you actually cook.
**Why:** small but passionate segment; nothing else connects a garden to a real pantry.
**Builds on:** inventory + `seasonProduce` (already on the Worker) + `IngredientDatabase`.
**First slice:** "harvested" entry source + a seasonal yield summary. **Size: M**

### 15. Container Labeling (NFC / QR)
Stick a tag on a container or bin; tap to see or update what's inside — no typing, no barcode on
decanted or homemade food.
**Why:** solves the hardest inventory case (leftovers, bulk bins, prepped food), which is exactly
where inventory accuracy dies.
**Builds on:** Core NFC, `ItemIcon`, `InventorySpatialView`, `KitchenTransferManager`.
**First slice:** QR labels you print/scan that map to an inventory item. **Size: M**

---

## If you only pick three
**#2 Cart Handoff** (revenue + closes the loop), **#4 Leftovers Lifecycle** (attacks the real source
of waste with parts you already have), and **#11 Multi-Recipe Orchestration** (a genuine competitive
moat — everyone else does one recipe at a time).

**Cheapest wins:** #13 Restaurant Logging (S), #8 Store Layout Learning (uses data you already
collect), #5 Thaw Planner (notifications + meal plan you already have).

**Do first regardless:** the three consolidations at the top — you're carrying duplicate
substitution, unit-parsing, and nutrition logic right now.
