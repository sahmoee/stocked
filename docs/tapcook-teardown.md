# TapCook 2.2.0 teardown — what Stocked can take

Source: `6769601354_2.2.0.ipa` (bundle `com.testmaxx.reelchef`, display name TapCook, build 31, iOS 18+, iPhone only, light mode only).

**Evidence limits.** The main binary is FairPlay-encrypted (`cryptid 1`), so code was not disassembled. The findings below come from:
- its 1,042 UI strings (es/fr `Localizable.strings`)
- its bundled data files: `mealplan.json`, `catalog.*.json` and `prices_ca.json`
- Info.plist, its linked frameworks and its privacy manifest

Do not copy its recipes, prices or copy text. Take the ideas and data shapes only.

## What it is

TapCook is a weekly dinner planner. It asks six questions during onboarding:
- household size
- nights to cook
- budget
- diet and allergies
- store (from a ZIP or postal code)
- what's already in the kitchen

From those answers it builds a week of dinners from a fixed catalog of 529 recipes and 203 ingredients. It then turns the week into one grocery list, priced at a real store using whole packs. That is the entire product. Everything else is retention:
- a trial with one free rebuild per week
- household codes
- referral and creator codes
- seasonal themes
- a cancellation offer

Stack: SwiftUI, RevenueCat, Lottie, Sign in with Apple and Google, MapKit and CoreLocation for store search, ATT and AdServices for ad attribution, and a server for sync. Camera is used for "scan your fridge".

## Where Stocked already matches or beats it

Stocked is far broader. It already has:
- inventory with spatial zones
- receipt and barcode scanning
- AI shelf scan
- a manual meal planner (`MealPlannerView`, `WeekMealPlannerView`, `PlanAheadCore`)
- `ThawPlanner` with reminders
- `LeftoversLifecycle`
- community and brand prices
- multi-store lists
- an Instacart handoff (`GroceryCartHandoff`)
- `KitchenEquipment`
- `DietaryGuard`
- household CloudKit sync
- widgets, Live Activities, App Intents and the watch

TapCook has none of the inventory depth.

## What's missing in Stocked (ranked by benefit)

### 1. A one-tap "build my week" planner within a budget — biggest gap

Stocked's planner is manual. TapCook's core loop is: answers → a finished week plus a priced list in about a minute. Its constraint feedback is what makes the planner work:
- "This is the cheapest week we could build — $X. To land under $Y, cook one fewer night."
- "Dropping *dairy* would add 3 dinners."
- "Too few dinners fit in 30 minutes with your other settings, so this limit is off for now."
- When the budget is low, it states how the plan changes ("we'll lean on beans, lentils and eggs … repeat a couple of bases").
- Meatless nights are offered as a budget lever.

**For Stocked:** a `WeekBuilder` that fills planner nights from `RecipeStore` and `MakeabilityEngine`. It would:
- score recipes on what's already in stock (Stocked's advantage: it really knows the pantry)
- respect `DietaryGuard`, `KitchenEquipment` and a time cap
- stay under a weekly budget using `RecipeCost`
- when the plan can't meet every setting, report which constraint is the bottleneck

### 2. Pack-aware costing and carrying leftover packs into later weeks

TapCook charges for whole packs ("we charge you for whole packs, because that is what you carry home"). It then tracks the remainder:
- "You'll have ⅔ of the pack left. Freeze it — that's $2.10 a later week won't spend again."
- Later weeks use up partial packs first: "Frozen from an earlier shop — nothing to buy."
- When a dinner is removed, it reports what that does to the shopping: "everything it needed is used by another dinner, so nothing goes to waste" or "1 ingredient was bought only for it and will be left over."

Its ingredient model is worth mirroring:

```json
{"canonical_id":"chicken_thigh_boneless","pack_size":3.75,"pack_unit":"lb",
 "pack_price_usd":7.14,"premium_price_usd":12.14,"premium_label":"free-range",
 "perish_days":4,"is_pantry":0,"opened_days":0,"freezes_open":0,
 "g_per_count":110,"kcal_100g":209,"protein_100g":18.6}
```

**For Stocked:** add `packSize`, `openedDays` and `freezesOpen` to `IngredientDatabase` / `KitchenMathCore`. After a recipe is cooked, write the remainder back to inventory as an opened item with its own expiry. Stocked's inventory makes this real rather than estimated.

### 3. Per-ingredient shelf life after opening

TapCook stores `opened_days` per ingredient:
- "keeps 3 days once opened — freeze the rest"
- "Last good day — worth using tonight"
- a reminder: "when an opened tin or bag is down to its last day"

`ShelfLifeEstimator` currently multiplies by 0.65 when an item is opened, and nothing in Stocked tracks shelf life once opened. Per-ingredient opened shelf life with a freeze suggestion would sharpen Stocked's expiry alerts and its "use it up" lists.

### 4. Shopping-day freshness planning

The user sets a shopping day, and TapCook checks every dinner against how long its ingredients keep:
- "1 dinner won't keep — 2 days past its ingredients"
- "Cuts it fine — one dinner sits right on its last good day"
- It offers to move a dinner earlier in the week ("Moved to Tue to keep it fresh").
- Items for late in the week get a "freeze them today" list.
- When fresh items won't last, it splits shopping into two trips.

Stocked has neither a shopping-day concept nor a freshness check on the meal plan.

### 5. Staples separated from the real cost

TapCook splits the total into food and pantry staples: "$X of that is pantry staples like oil, spices and rice." Ticking off what the user already owns removes those items from the bill for good. It also states the price spread between store-brand and premium options ("IF YOU BUY THE NICER VERSION"). In Stocked, both could be driven from inventory automatically.

### 6. Swaps that show what changes

- Swapping a dinner shows the change on the list (`+$1.40 on your list`) and the rest of the week stays put.
- Each dinner offers "Show this less often" or "Never show it", with a Hidden recipes list where the user can restore them.
- Adding an allergy rebuilds only the affected dinners, explains why ("3 of your 5 dinners used peanuts"), and offers Undo.

Nothing in Stocked handles "show less" or hidden recipes.

### 7. Recipe display details

- Directions are grouped into **phases** (Prep / Cook / Finish), each with its own minutes.
- Steps start with a bolded verb.
- Ingredient amounts appear inline in the step text and scale with servings.
- Recipes carry a **Cleanup score** (Minimal / Light / Moderate / Heavy), defined by cookware rather than effort, along with appliance filters (air fryer, slow cooker).
- Each recipe gets a "Was this recipe good?" thumbs rating.

### 8. Pasting the list into a delivery app

"Copy your list" puts the list on the clipboard so it pastes into the Instacart or DoorDash AI chat, with no account linking. Stocked's handoff currently opens a search per item. A plain-text "copy whole list" export is a cheap complement. TapCook also offers "Save Image" to Photos for the list.

### 9. Smaller retention ideas, lower priority

- A past-weeks archive with cost per week, kept for three weeks.
- A daily "Tonight's dinner" notification timed for late afternoon.
- Seasonal themes (Halloween, Fall), which fit Stocked's ThemeEngine and AltIcons.
- A "Help shape" feedback inbox (Stocked already has QA reporting).

## What not to copy

- **ATT and ad attribution.** It adds a tracking prompt for little benefit to Stocked.
- **The trial gate on rebuilds.** The paywall copy is hostile ("Bottom of the barrel. That's all you get").
- **Store-specific scraped price files.** TapCook prices one store per region by hand, with "checked" dates. Stocked's community, Kroger and receipt-learned prices are a sturdier source.
- **The light-only, iPhone-only limits.**

## Suggested order

1. Per-ingredient opened shelf life and pack size data (2, 3), which everything else depends on.
2. Writing pack remainders back to inventory after cooking (2).
3. WeekBuilder with budget and constraint explanations (1), plus show-less and hidden recipes (6).
4. Shopping day and a freshness check on the plan (4).
5. Phases, cleanup score and ratings in recipes (7), plus copying the whole list (8).
