# Stocked — 20 Improvements + 10 Gap-Closers

*Grounded in the current codebase (v4.13, ~341 files). Effort: **S** ≤1 day · **M** a few days · **L** 1–2+ weeks. Verified against the repo where noted.*

---

## Part 1 — 20 ways to improve the app overall

Ordered roughly by impact-to-effort. The first six are the highest-leverage.

**1. Expand Home Screen widgets (they already exist — grow them). [M]**
`StockedWidgets` ships a Live Activity cook timer. Add an "Expiring Soon" widget and a "Days of Food Left" lock-screen widget, and make them interactive (iOS 17 `AppIntent` buttons) so a tap marks an item used or adds it to grocery — no app launch. Widgets are the cheapest daily re-engagement surface and you've already paid the setup cost.

**2. watchOS companion. [L]**
No watch target exists today. The two killer wrist use cases: the grocery list with tap-to-check while pushing a cart, and cook timers/steps on the wrist while your hands are busy. Reuses `GroceryListView` logic and the existing `StepTimerEngine`.

**3. Universal links + graceful web fallback. [M]**
No associated-domains entitlement or AASA file exists. Your QR container labels use a `stocked://` custom scheme, which silently does nothing if the app isn't installed. Move to `https://sowensstudios.com/l/...` universal links (host the AASA on Netlify) so a shared label or invite opens the app when present and a web page otherwise. Prerequisite for shareable labels and household invites.

**4. "Add to Stocked" share extension. [M]**
Let users add an item or import a recipe from Safari, Photos, or Notes via the system share sheet. You already have OCR and a recipe parser; this just exposes them at the OS level and dramatically lowers the friction of getting data in.

**5. Waste-and-savings dashboard. [M]**
You already track harvest value, cost splitting, and shelf life. Aggregate them into one monthly "you saved $X, avoided $Y of waste" view. This is the single strongest retention/word-of-mouth hook a pantry app has — it turns invisible good behavior into a number people screenshot.

**6. Meal-plan calendar that feeds the grocery list. [M]**
You have planned meals and a grocery hub but no weekly calendar tying them together. A drag-a-recipe-onto-a-day planner that auto-builds the week's grocery list closes the loop between "what will we eat" and "what to buy."

**7. Actionable, digest-style notifications. [S–M]**
Add notification actions (Mark Used / Add to List) and collapse per-item expiry pings into one daily digest with quiet hours. Per-item notifications are the fastest route to users disabling notifications entirely.

**8. Recipe import from URL or photo. [M]**
Parse a recipe from a pasted link or a photo of a cookbook page (OCR already exists). Recipe entry is the biggest cold-start chore; automating it makes the Recipes hub worth filling.

**9. Smart reorder / staple cadence. [M]**
Learn repeat-purchase intervals ("you usually buy milk every ~6 days") and proactively surface staples before they run out. You already persist purchase history; this is a model on top of it.

**10. Household activity feed. [S–M]**
`SyncConflictLog` already records overwrites. Extend the same idea into a friendly "who changed what" feed (added, used, bought) with member colors. Makes shared households feel alive and builds trust in sync.

**11. Sync status indicator. [S]**
Show last-synced time and a clear online/offline/failed state. You made the tools offline-capable; now make the sync state legible so users trust it.

**12. Monetization: package "Stocked Plus." [M]**
Today the only IAP is `com.stocked.householdsync`. Define one clear premium tier (AI Worker tools + crowd data + multi-household) with a real paywall and free-tier limits. Right now value is given away with no upgrade path.

**13. Pantry-shelf photo → bulk add (vision). [L]**
Point the camera at a shelf and get a candidate item list to confirm. Ambitious, on-brand, and a genuine differentiator. Build behind Plus.

**14. Accessibility pass. [M]**
Audit Dynamic Type, add VoiceOver labels to icon-only buttons, and verify dark-mode contrast (your theme layer makes this systematic). Also an App Store review smoother.

**15. Localization + units scaffolding. [M]**
Currency is already locale-aware. Extract strings and add a metric/imperial toggle. Opens non-US markets and is far cheaper to do before the string count grows.

**16. Onboarding payoff loop. [S]**
The quiz collects household size and diet — make the payoff visible ("serves 4, so we suggested 2 lbs"). Users abandon quizzes whose answers never resurface.

**17. Spotlight donation + more App Intents. [S]**
You have 9 Siri shortcuts; donate index entries so items/recipes appear in system search, and expose the interactive-widget intents from #1.

**18. Cold-start performance. [S–M]**
Every feature store loads on init. Lazy-load the non-Home stores (harvest, events, split, takeout) so launch only pays for what the first screen needs. Measure with a signpost first.

**19. Privacy-first telemetry. [M]**
You have 39 tools and no idea which get used. Add opt-in, on-device-aggregated event counts so roadmap decisions stop being guesses. Ship with a clear toggle.

**20. App Store launch assets. [M]**
Screenshots, a preview video, and ASO keyword research — flagged in launch readiness and still outstanding. No amount of code quality helps if the listing doesn't convert.

---

## Part 2 — 10 ways to close gaps (concrete, in the current code)

These are specific incompletenesses, not new features.

**G1. Surprise Me ignores individual allergens. [S]**
Cook Now excludes allergen ingredients; the template-based Surprise Me only respects diet (veg/vegan), not allergens. A user with a nut allergy can be handed a nut recipe. Unify both surfaces on one allergen filter. *(Flagged in the QA audit; deliberately not shipped blind — needs a device test.)*

**G2. QR labels have no fallback. [M]**
Container labels encode `stocked://` only. Scanned on a phone without the app, nothing happens. Ties to improvement #3 — move to universal links so labels degrade to a web page.

**G3. No StoreKit config file. [S]**
No `.storekit` file exists, so IAP can't be exercised in Xcode/simulator. Also confirm the product ID `com.stocked.householdsync` (different namespace from bundle `com.sowens.Stocked`) matches App Store Connect exactly — a mismatch means purchases silently fail in production.

**G4. Two nutrition-estimate paths. [S]**
Estimates come from both `SmartKitchenView` (tool) and `SmartWorkerClient`. Pick one authority so the number a user sees in the tool matches the number used elsewhere; document which is canonical.

**G5. Household feature-sync isn't live until the Worker deploys. [S]**
The `FEATURE_COLLECTIONS` merge (leftovers, events, harvest, split, layouts, labels, takeout) exists in the Worker source but won't sync across devices until `wrangler deploy` runs. Tests pass locally; production is stale. This is the gap between "coded" and "working."

**G6. Apple name recovery for already-authorized testers. [S]**
Moving the profile vault to Keychain means anyone who authorized Stocked *before* the change still gets a nil name from Apple until they revoke the app in iOS Settings. The name-entry prompt covers the empty case, but add a Settings affordance to re-enter a name anytime, so users aren't stuck with a fallback and no path out.

**G7. Sync-conflict logging isn't proven uniform. [S]**
`SyncConflictLog` notes planned meals were historically excluded from conflict detection. Verify every synced collection routes an LWW overwrite through `SyncConflictLog.record` — otherwise the "nothing disappears silently" promise has holes for exactly the collections users care about most.

**G8. Static-audit false positives. [S]**
`InventoryExporter.swift` and `KitchenTransferManager.swift` report `-2 parens` from raw-string literals — harmless, but they defeat brace-balance checks and will keep costing audit time. Restructure the raw strings or add an ignore marker so future static passes come back clean.

**G9. No CI / test scheme. [M]**
`FeatureEngineTests` and the Worker tests exist but nothing runs them automatically. The build-65 launch crash is exactly the class of regression a CI run catches. Add an Xcode test scheme and a GitHub Action (Swift build/test + `node --test` for the Worker).

**G10. Deployment-target decision is unresolved. [S]**
Pin a minimum iOS version and wrap newer APIs (Live Activities, interactive widgets) in `if #available` guards. Leaving this open risks either shipping features that crash on older OSes or needlessly cutting off reach. Decide, then gate.

---

*Fastest wins first: G5 (deploy the Worker), G3 (StoreKit config), G1 (allergen filter), then improvements #1 and #7 (widgets you already built + Spotlight) for the most retention per hour spent.*
