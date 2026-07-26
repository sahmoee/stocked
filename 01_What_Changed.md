# Stocked — Improvements batch (20 + 10), implementation notes

Scope: everything requested **except #2 (watchOS)** and **#12 (Stocked Plus monetization)**. Worker/AI is deployed (per you), so G5 needs nothing. Min iOS set to the true floor.

All code changes are in your project in place. No compiler is available here, so each file was verified by brace/paren balance and symbol/collision checks — but everything still needs a real Xcode build to confirm. The project uses Xcode 16+ synchronized file groups (`objectVersion = 77`), so the **new `.swift` files auto-compile** with no project edits.

---

## The 20 improvements

**#1 Widgets expanded — DONE.** Added two widgets to the existing `StockedWidgets` target: *Expiring Soon* (small/medium/rectangular) and *Grocery* (small/circular/inline), both reading the existing shared snapshot and registered in `StockedWidgetBundle`. `StockedWidgets/StockedWidgets.swift`.

**#3 Universal links — DONE.** Added the `associated-domains` entitlement (`applinks:sowensstudios.com`), an AASA file for Netlify, web-URL routing via `.onContinueUserActivity(NSUserActivityTypeBrowsingWeb)`, and switched container-label QR payloads to `https://sowensstudios.com/l/<uuid>`. `Stocked.entitlements`, `StockedApp.swift`, `ContainerLabels.swift`, `site/.well-known/apple-app-site-association`, `site/netlify.toml`. *(One manual step: put your Team ID in the AASA — see 04_Xcode_Steps.)*

**#4 Share extension / add-from-anywhere — ALREADY DONE (verified).** `StockedShareExtension` accepts URL/text/image and hands off via the app group; `SharedRecipeImporter` ingests it. No change needed.

**#5 Waste-and-savings dashboard — DONE.** New "Money Saved" toolbox tool totals value used vs. wasted plus home-grown produce value, with a savings rate and most-wasted list. `MoneySavedView.swift`.

**#6 Meal-plan → grocery loop — DONE.** `generateGroceryFromMealPlan()` existed but had no caller; added a "Build Grocery List" button to the planner footer. `MealPlannerSubViews.swift`.

**#7 Actionable digest notifications — DONE.** The daily brief set a `DAILY_BRIEF` category that was never registered (so it had no buttons); registered it with an "Open Kitchen" action. `NotificationActions.swift`.

**#8 Recipe import from URL/photo — ALREADY DONE (verified).** `WebRecipeManager` + `RecipeTextParser` + `RecipeOCR` handle web, social, text, and image imports end to end.

**#9 Smart reorder / staple cadence — DONE.** New "Reorder Soon" tool predicts each staple's run-out date from its historical lifespan (`ConsumptionRecord.daysLasted`) and surfaces due items with one-tap add. Pure engine `ReorderEngine`. `ReorderSoonView.swift`.

**#10 + #11 Household activity feed + sync status — DONE.** New "Household Activity" tool: a sync-status card (household code, member, Sync Now) plus a timeline stitched from items used/wasted, purchases, and sync overwrites. `KitchenActivityView.swift`. *(Renamed from the collision with the existing `HouseholdActivityView`.)*

**#13 Pantry-shelf photo → bulk add — DONE.** New "Scan a Shelf" tool: pick a photo, on-device OCR (`RecipeOCR`) extracts label lines, you confirm which to add, they go into inventory. `ShelfScanView.swift`.

**#14 Accessibility — audited, see 03_Accessibility_Audit.md.** Delivered as a targeted findings list rather than blind edits across 341 files.

**#15 Localization + units — units toggle already exists (`UnitSystem`); localization scaffolding added.** `Stocked/en.lproj/Localizable.strings` + migration approach in 04_Xcode_Steps. Full string extraction is a follow-on.

**#16 Onboarding payoff — ALREADY WIRED.** `cookingProfile.householdSize` from the quiz already drives serving defaults across Cook, Cook-Later, recipe import/scaling, and App Intents. The one genuine gap (grocery *quantities* don't scale to household size) is listed as a future item.

**#17 Spotlight — DONE.** New `SpotlightIndexer` indexes recipes + inventory into CoreSpotlight on a deferred launch pass; tapped results route to the right hub. `SpotlightIndexer.swift`, `StockedApp.swift`.

**#18 Cold-start — improved.** Feature stores are already lazy singletons and backfills are deferred 4s; moved Spotlight indexing into that same deferred block so it never competes with first render. `StockedApp.swift`.

**#19 Telemetry — DONE.** `AppAnalytics` already existed; added an on-device opt-out (`isEnabled`, honored in `log`) and surfaced a usage summary + toggle + clear in App Health. `AppAnalytics.swift`, `StockedHealthView.swift`.

**#20 App Store launch assets — delivered as a checklist.** See 02_Launch_Assets_Checklist.md.

---

## The 10 gap-closers

**G1 Surprise Me allergens — DONE.** Allergen filtering added to the template generator (`OnDeviceRecipeGenerator.generateWithProfile`: drops in-stock allergen ingredients and allergen-centric templates) and to `surpriseRecipeTuned` (excludes saved recipes containing an allergen). `SurpriseRecipeEngine.swift`, `GuestDataStore.swift`.

**G2 QR label fallback — DONE.** Covered by #3: labels are now HTTPS universal links that open the app or the web page. `ContainerLabels.swift`.

**G3 StoreKit config — DONE.** `Stocked.storekit` created for the existing `com.stocked.householdsync` non-consumable so IAP can be tested in Xcode. Note the product-ID namespace differs from the bundle (`com.sowens.Stocked`) — confirm it matches App Store Connect exactly.

**G4 Nutrition sources — already consolidated (verified).** Both the tool and the client funnel through `SmartClient.estimateNutrition`; there is no second computation. No change needed.

**G5 Worker deploy — done by you.** No action.

**G6 Apple name recovery — covered.** `EditProfileView` already lets a user re-enter their name any time, and the name-entry prompt handles the empty case. Documented for already-authorized testers (revoke in iOS Settings to get Apple's name back).

**G7 Uniform conflict logging — DONE.** Every previously-silent LWW overwrite now routes through `SyncConflictLog`: grocery, user recipes, and generated recipes in `HouseholdSync`, plus all eight feature collections (leftovers, family, events, split, harvest, labels, takeout) in `FeatureHouseholdSync`. Self-guards when values match, so no noise.

**G8 Raw-string audit false positives — documented, not changed.** `InventoryExporter.swift` and `KitchenTransferManager.swift` report `-2 parens` purely from balanced-looking-but-not raw string literals; they are not bugs and neither was touched. Restructuring them risks changing exported output for zero functional gain — left as-is with this note.

**G9 CI / test scheme — DONE (scaffolding).** `.github/workflows/ci.yml` builds+tests the app and runs the Worker tests. Requires a shared `Stocked` scheme with a test target attached (see 04_Xcode_Steps).

**G10 Min iOS — DONE.** Lowered `IPHONEOS_DEPLOYMENT_TARGET` from 26.0 to **17.0** across all 8 build configs. 17.0 is the true floor: the entire state layer uses the `@Observable` macro (iOS 17), reinforced by `ContentUnavailableView`, `.scrollTargetBehavior`, and two-parameter `.onChange`. Nothing in the code needs iOS 18/26.

---

## Files touched

Edited: `SurpriseRecipeEngine.swift`, `GuestDataStore.swift`, `MealPlannerSubViews.swift`, `NotificationActions.swift`, `Stocked.entitlements`, `ContainerLabels.swift`, `StockedApp.swift`, `FeatureHouseholdSync.swift`, `HouseholdSync.swift`, `KitchenToolboxView.swift`, `AppAnalytics.swift`, `StockedHealthView.swift`, `StockedWidgets/StockedWidgets.swift`, `site/netlify.toml`, `Stocked.xcodeproj/project.pbxproj`.

New: `MoneySavedView.swift`, `ReorderSoonView.swift`, `KitchenActivityView.swift`, `ShelfScanView.swift`, `SpotlightIndexer.swift`, `en.lproj/Localizable.strings`, `Stocked.storekit`, `site/.well-known/apple-app-site-association`, `.github/workflows/ci.yml`.

Verification: all edited/new Swift files brace- and paren-balanced; new public symbols checked for collisions (one found and fixed — `HouseholdActivityView` → `KitchenActivityView`); the changed `merge<T>` signature confirmed updated at all 7 call sites.
