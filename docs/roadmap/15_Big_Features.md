# Stocked — 15 Big Features

Each one is scoped against what's already in the codebase, so these are extensions of real
infrastructure rather than greenfield. Every entry lists a **first slice** — the smallest version
worth shipping — so none of them has to be all-or-nothing.

---

## 1. Live Household Collaboration
**What:** Real-time shared state — two people see the same grocery list update as it's checked off,
with presence ("Sam is at H‑E‑B", "Alex is cooking Chicken & Rice").
**Why it wins:** Turns Stocked from a personal tracker into the family's shared kitchen. The single
biggest driver of daily multi-user engagement.
**Builds on:** `HouseholdDO` (Durable Object) already serializes push/pull; the Worker has a
`/realtime/household` scaffold. Swap 6‑second polling in `HouseholdSync` for hibernatable WebSockets.
**First slice:** Live grocery list only — items check off across devices instantly. **Size: L**

## 2. Auto-Replenishment Engine
**What:** Learn each item's real consumption rate and predict run-out dates, then quietly add things
to the grocery list *before* you run out ("Milk — you'll be out Thursday").
**Why it wins:** This is the feature people tell friends about. It makes the app proactive instead of
a place you have to remember to visit.
**Builds on:** `consumptionLog` + `ConsumptionRecord` in `GuestDataStore` already record usage;
crowd shelf-life data exists in the Worker (`/expiry/estimate`).
**First slice:** Staples only (`stockStaples`) with a simple rolling-average rate + a "predicted"
badge the user can confirm/dismiss (which trains it). **Size: M**

## 3. Shelf Scan — multi-item capture
**What:** Point the camera at a fridge shelf or pantry row and add *everything* in one pass, with
bounding boxes and a confirm-all review, instead of one barcode at a time.
**Why it wins:** Onboarding is the #1 drop-off for inventory apps — nobody wants to type 60 items.
This collapses setup from an hour to a minute.
**Builds on:** `AIInventoryScan` + `AIInventoryScanView` + Vision; `/barcodes/batch` on the Worker
already resolves up to 25 codes per call.
**First slice:** Multi-barcode burst mode (detect several barcodes in one frame → batch resolve).
**Size: L**

## 4. Waste & Savings Coach
**What:** Log what actually gets thrown out, quantify it in dollars, and surface patterns —
"cilantro expires unused 8 of 10 times; buy the small bunch" — plus use-it-up recipes.
**Why it wins:** Gives the app a measurable ROI the user can feel. "Stocked saved me $340 this year"
is the retention story.
**Builds on:** the `wasteInsights` Toolbox tool, `expiredItems`/`expiringSoonItems`, `priceHistory`.
**First slice:** One-tap "tossed" on expiring items + a monthly "wasted vs saved" number. **Size: M**

## 5. Weekly Meal Planner
**What:** A real week view — drag recipes onto days, auto-generate one consolidated shopping list,
and get a prep schedule (what to batch on Sunday, what thaws Wednesday).
**Why it wins:** Planning is the habit that pulls everything else — inventory, grocery, cooking —
into one weekly loop.
**Builds on:** `plannedMeals` + `PlannedMeal`, Cook Later, `BatchCookPlannerView`, and the Worker's
`/grocery/from-recipes` (already merges + aisle-sorts across recipes).
**First slice:** 7-day grid + "build shopping list from this week." **Size: L**

## 6. Hands-Free Cook Mode
**What:** A cooking screen you never touch — voice "next step" / "repeat," multi-timer on the
Dynamic Island and Lock Screen, screen stays awake, big wet-hands-friendly type.
**Why it wins:** Solves the actual moment of use. Cooking is the one time a phone is least usable.
**Builds on:** `VoiceCookControl`, `MultiTimerView`, `LiveActivityManager`, `CookingFlow`,
`FullScreenCookView`, `RecipeTextPrefs` (text scaling already exists).
**First slice:** Live Activity timer + voice "next/back" during an active cook. **Size: M**

## 7. Nutrition Goals + HealthKit
**What:** Log meals you actually cooked, track macros against goals, and read/write HealthKit so
Stocked participates in the user's health picture.
**Why it wins:** Converts a kitchen utility into a daily health habit, and opens a credible
subscription tier.
**Builds on:** `NutritionFacts`, `NutritionBackfill`, the Worker's `/nutrition/estimate`,
`pastMeals` history.
**First slice:** "I ate this" on a cooked meal → daily calorie/macro total. **Size: M**

## 8. Diet & Allergy Guardrails
**What:** Household-wide dietary rules (allergies, vegan, low-sodium, diabetic, renal) that filter
recipes, flag ingredients, and warn *at the shelf* when you scan a barcode.
**Why it wins:** For allergy households this moves the app from convenient to essential — and it's a
genuine safety feature, which drives word of mouth.
**Builds on:** `DietaryProfileView`, `allergens` on `OpenFoodProduct`, `FoodWhitelist`,
`/ingredients/substitute` (already supports `?diet=vegan`).
**First slice:** Scan-time allergen warning from Open Food Facts allergen tags. **Size: M**

## 9. Store & Price Intelligence
**What:** Track what you pay where, then answer "which store should I shop at this week for *this*
list?" — with unit-price comparison and deal alerts on watched items.
**Why it wins:** Direct, provable money saved, and it's defensible: it gets better the longer you use it.
**Builds on:** `/prices/compare` + retailerapi, `priceHistory`, `itemStoreHistory`, `PriceLookupView`,
and the Worker's `/prices/watch`.
**First slice:** Per-item best-price-seen + "cheapest store for this list." **Size: L**

## 10. Universal Recipe Capture
**What:** Paste *anything* — a URL, a screenshot, a photo of a cookbook page, a TikTok/Reels link —
and get a clean structured recipe.
**Why it wins:** Removes the biggest friction to filling the recipe vault, and it's the most common
"how do I get my recipes in?" request.
**Builds on:** `RecipeImportAI`, `SocialImportView`, `SharedRecipeImporter`, OCR, the Share Extension,
and the Worker's `/recipes/fetch` (JSON-LD extraction already live).
**First slice:** Share-sheet → URL → JSON-LD via Worker → saved recipe. **Size: M**

## 11. Apple Watch Companion
**What:** Grocery list on the wrist (check off while pushing a cart), expiring-items glance, and
cooking timers with haptics.
**Why it wins:** The shopping cart and the stove are both places you don't want to hold a phone.
**Builds on:** existing widget/data layer (`WidgetBridge`), timers, App Group sharing.
**First slice:** Read-only grocery list + check-off syncing back. **Size: L**

## 12. Household Cookbook & Sharing
**What:** Curated collections you can share by link — a family cookbook, "Thanksgiving 2026," or a
recipe sent to a friend that opens directly in their app.
**Why it wins:** The only feature here with built-in viral distribution: shared links bring new users.
**Builds on:** Universal Links (AASA endpoint is live on the Worker), `SharedRecipeImporter`,
`userRecipes`, household roles.
**First slice:** Share a single recipe via `sowensstudios.com/r/<id>` that deep-links into the app.
**Size: M**

## 13. Offline-First Sync (CRDT)
**What:** Replace last-write-wins with conflict-free merging, plus a queue so every edit made offline
lands correctly when you reconnect.
**Why it wins:** Grocery stores and basements have terrible signal. Today, two people editing at once
can silently lose an edit — that's the kind of bug that makes people stop trusting an app.
**Builds on:** `HouseholdDO` merge logic (already LWW + tombstones + `lastWriterID`).
**First slice:** CRDT for the grocery list only (add/remove/check are naturally commutative). **Size: L**

## 14. Spend & Budget Analytics
**What:** Receipts become a real spending picture — by store, category, and month — with a budget you
can set and a forecast of where you'll land.
**Why it wins:** Pairs with #4 and #9 to make Stocked a household *money* tool, not just a food tool.
**Builds on:** `ReceiptScannerView` + `ReceiptArchiveEntry`, `priceHistory`, `BudgetTrackerView`,
`MealCostView`.
**First slice:** Monthly spend by store/category from archived receipts. **Size: M**

## 15. Multi-Location Kitchens
**What:** More than one place that holds food — second fridge, garage freezer, vacation house, dorm —
each with its own inventory, and transfers between them.
**Why it wins:** Unlocks power users and families with two homes; also the natural shape for
small-business/pro use later.
**Builds on:** existing zones (Fridge/Freezer/Pantry/Staples), `KitchenTransferManager` (transfer
plumbing already exists), household roles.
**First slice:** A second named location + move-item-between-locations. **Size: M**

---

## If you only pick three
**#2 Auto-Replenishment** (makes the app proactive), **#4 Waste & Savings Coach** (proves ROI), and
**#12 Cookbook Sharing** (brings new users in). Together they cover retention, perceived value, and
growth — and each has a genuinely small first slice.

**Fastest wins:** #10 (the Worker's `/recipes/fetch` is already live), #8 (allergen tags already come
back from Open Food Facts), and #6 (voice + Live Activity classes already exist).
