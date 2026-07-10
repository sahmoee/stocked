# Stocked — new features (batch 1)

Two self-contained pieces you can apply now. The rest of your list (5,6,7,8,9,10) are
app-internal and need the current Stocked repo to wire without breaking the build — upload
Stocked 2.zip and I'll deliver them as focused BuildBuddy drops (plan below).

## 1) Smart quantity / unit entry  (Stocked/QuantityParser.swift, Stocked/QuantityInputView.swift)
Parses natural amounts and lets users adjust:
  "4 bags of chips" -> 4 × bag · "6 poptarts" -> 6 items · "half a bag of cheese" -> 0.5 bag
  "6 cans of 8 oz" -> 6 cans, 8 oz each · "a dozen eggs" -> 12 · "2 1/2 lbs chicken" -> 2.5 lb
Drop `QuantityInputView(quantity: $qty)` into AddItemSheet, the barcode confirm sheet, and
receipt review. It shows a natural-language field plus a Qty stepper, container picker, and
"each amount" (for packs like 6 × 8 oz). Store `ParsedQuantity` on the inventory item.

## 2) Crowd database  (crowd-worker/ + Stocked/CrowdDB.swift)
A shared, ANONYMIZED, opt-in database so all users' items make the app smarter for everyone.
- Deploy the worker:
    cd crowd-worker
    npx wrangler kv namespace create CROWD      # paste id into wrangler.toml
    npx wrangler secret put CROWD_KEY           # the shared key
    npx wrangler deploy
- In the app, set CrowdWorkerURL + CrowdWorkerKey (Info.plist/Secrets.xcconfig) and add a
  Settings toggle writing UserDefaults "crowdShareEnabled" ("Improve Stocked for everyone").
- Use it:
    await CrowdDB.report(items: [...], basket: [names])   // opt-in, on add/scan/receipt
    let s = await CrowdDB.suggest(name: "milk")            // prefill unit/container/qty
    let names = await CrowdDB.autocomplete(prefix: "ch")   // item autocomplete
    let pairs = await CrowdDB.pairings(name: "pasta")      // "goes well with…"
Privacy: only item facts (name, category, unit, container, quantity) are sent — never account,
name, email, or location. Reflect this in the Privacy Policy before shipping.

## Plan for 5,6,7,8,9,10 (needs the Stocked repo)
- 5 Substitutions/pairings: wire pairings.json + CrowdDB.pairings into IngredientPairingsSheet;
  add "missing ingredient → swap" suggestions in the cook flow.
- 6 Cost & budget: per-item price (grocery API) + per-recipe cost + weekly spend view.
- 7 Personalized recs: taste profile from ratings/cook history to rank Discover; diet/allergen
  filters applied app-wide.
- 8 Nutrition dashboard: weekly macros from cooked meals via HealthKit + healthy-swap hints.
- 9 Live cooking mode: guided steps with parsed timers (auto-detect "10 minutes" → tappable
  timer / Live Activity) and a Dynamic Type–driven font-size setting so all recipe text scales.
- 10 Ecosystem: WidgetKit widgets (expiring, today's plan, low stock), Apple Watch grocery
  list, Siri Shortcuts, and a Share Extension to save web recipes into your feed.
