# Free kitchen delivery

This batch builds on Stocked's existing kitchen rather than installing a second recipe server.
No subscription, paid API, hosted AI call, runtime package or new credential was added. Existing
Cloudflare/Apple infrastructure is reused; its existing quotas, account fees and availability still apply.
No account was upgraded or purchase made.

## Try the new tools

1. **iOS: Recipes → Add Recipe → Import or export recipe files.** Choose one `.cook`, `.json`,
   `.html` or `.txt` file (48KiB maximum). Review ingredients, steps, warnings, duplicates and credits
   in the existing editor. Save a private text recipe without requiring a photo. A matching file,
   source or title requires a deliberate separate-copy choice; nothing overwrites an existing recipe.
   Export the current recipe as Cooklang/Schema.org JSON, or its exact original file.
2. **Mac: File → Import Center → Preview portable recipe files.** Review Cooklang or Recipe
   JSON/JSON-LD, skip duplicates and validate photos through the existing library. Imports default
   to private; optional public catalogue sharing requires source and rights confirmation. Undo removes only unchanged additions.
   Export JSON-LD library data, an individual Cooklang recipe, or preserved original files.
3. **Either iOS meal planner → Repeat meals & export calendar.** Preview copying a day's meals
   to another day in the current week. Existing meals stay; same-title/same-slot duplicates skip;
   cooked/prepared state resets. Changed previews require review again. Undo keeps subsequent edits.
   Export `.ics` copies after choosing the first date. Dates handle DST; exports have stable event
   identifiers and include only meal title/type/servings, with private event classification.
4. **Kitchen Toolbox → Price Lookup → Look up free community prices.** Explicit barcode lookup
   displays dated Open Prices observations, currency, location, price basis, discounts and source
   credits. Reports are not live store quotes and never overwrite personal receipt prices.
5. **Settings → Help & Support → Sources & Credits.** Format/data acknowledgements are visible
   in the app; imported author, license and photo credits also appear in recipe details and preview.
6. **Batch 2: Recipe Files → Bring recipes from another app.** Reviewed collection imports now read
   supported Mealie, Tandoor, Paprika and Recipya exports, including ZIP/gzip and multiple JSON files.
   On Mac, Import Center also offers an opt-in recipe drop folder that queues stable files for review
   while the app is running. See RECIPE_MIGRATION.md and KITCHEN_MIGRATION_FORMATS.md for exact limits.
7. **Batch 3: Either planner → Plan ahead.** Add real dated meals, save reusable weekly templates,
   preview finite repeats and explicitly add eligible dates to the active week. **My Collection or
   Collections → Smart cookbooks** saves filters that update as saved recipes change. Existing
   household sharing and iOS backups carry these small records. See PLAN_AHEAD.md and SMART_COOKBOOKS.md.
8. **Batches 4–5: Settings → Data & Storage → Free Kitchen Connections.** Read from your Grocy
   server into a reviewed append-only import, publish reviewed meal copies to a compatible CalDAV
   calendar, discover recipes through Cooklang Federation, check saved community price targets and
   manage optional household delivery. See the dedicated connection and price-check guides. Existing
   servers and Apple push keys must be configured; no new subscription or hosted AI is required.

## Ingredient improvements

App and server refuse to guess an unknown ingredient's weight from its volume. Exact known density
estimates are labelled approximate; same-family conversions continue to work. Almond flour is not
plain flour, and cooked rice is not dry rice. Oversized numeric inputs cannot crash formatting.
Server grocery helpers combine compatible measures, retain original lines and keep unknown amounts
separate. Pantry checks consume available quantities once and identify uncertainty or shortages.
Nutrition explicitly labels known subtotals and never turns a missing ingredient into zero nutrition.

## Existing capabilities reused

| Roadmap area | Existing owner / behavior retained |
| --- | --- |
| URL import, receipts and screenshots | Existing bounded browser/structured parser and on-device import review; no new hosted AI added |
| Pantry and shopping | FoodNameMatcher, inventory proposal/undo, units, aliases, store layout, minimum stock, recurring grocery templates and quantity reservations |
| Leftovers and cooking | Portions, storage/dates, use-first guidance, cooking history, substitutions, timers and coarse household cooking presence |
| Planning | Seven-day meal slots, pantry/conflict checks, meal/grocery handoff, shared plans and App Intents |
| Free food data | Existing Open Food Facts and USDA adapters; USDA enrichment still needs the existing free USDA key if enabled |
| Household and recovery | Existing joining/roles, durable queued edits, conflict handling, tombstones and encrypted Kitchen Transfer backups |

## Privacy, compatibility and rollout

UnifiedWorker owns the new read endpoint and canonical recipe wire contract; iOS/Mac produce reviewed
recipes and consume the public/household library. Fields `author`, `license`, `imageAttribution` and
private `portableSource` are optional. A new private file stores its original URL inside portableSource,
leaving the public sourceURL empty so older clients cannot republish it by their existing URL rule.
Explicit sharing requires a source, image and rights confirmation; raw original text is never public.
Legacy recipe edits retain omitted provenance/credits on the server. No new database, DO namespace,
applied migration, household reset or finance-project change is involved.

Deploy the verified Worker first, then build/install the clients. Old providers show an unavailable
community lookup while personal prices and local recipes remain usable. Older clients ignore additive
fields. New clients read legacy files without a destructive migration. Retain source rights, and
do not assume a web URL grants publication permission. Settings notices link to authoritative terms.

## Verification

- Worker: full test suite, TypeScript and production dry-run; recipe-private/public boundary,
  legacy edit preservation, auth, rates, bounds, discounts and provider failure are covered.
  Final result: 120 tests passed; compatible production update deployed. Live community lookup,
  cached replay, authorization and all five app health routes passed.
- iOS: `scripts/PortableCooklangChecks.swift`, `scripts/FreeKitchenChecks.swift`, generic `Stocked`
  iOS build including widgets/share extension. Section49 adds ten untested device checks.
- Mac: native Cooklang, interchange and model-compatibility checks; generic `StockedMac` build.
- Website: `apps/stocked/sources/index.html` carries public format/data credits.

Simulator testing remains paused by the user's earlier instruction. Compilation/native checks do
not establish iPhone/iPad UI, VoiceOver or live two-device synchronization passes. No TestFlight
upload or release sign-off is implied.

## Remaining roadmap work — not represented as finished

The core tools and batch 2 migrations are recorded in FREE_KITCHEN_BATCHES.md. Supported app recipe
exports now have bounded, tested readers; full database backups and unrecognized formats remain
unsupported. Cooklang supports the documented tested subset; unsupported extensions/complex metadata
survive in the original file and are not executed. Mac folder watching requires the app to be running
and never imports automatically. Batch 3 provides reviewed finite multiweek repeats; autonomous
closed-app scheduling is not provided. Batches 4–5 implement Grocy reads, manual conditional CalDAV
publication, Cooklang Federation search and household invalidation delivery with signed opt-in
webhooks. They are not automatic bidirectional kitchen/calendar synchronization. Outside connections
require the user's compatible endpoint and credentials; Apple push remains unavailable until its
server credentials are configured. Device-only community targets refresh explicitly, not in the
background. Legacy server watch saves and generated daily briefs do not promise monitoring or
push delivery. No paid fallback is silently substituted for unavailable setup.

There are no new keys to supply for this batch. Required user decisions happen on the actual data:
review an import, choose any duplicate copy, confirm a public recipe's rights, or approve planned
meal additions. External account setup and app distribution are separate from these local tools.
