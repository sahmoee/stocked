# Stocked major wins

The ten product wins share existing owners instead of creating parallel stores or services.

| Capability | Owner | Producers and consumers | Required invariant |
| --- | --- | --- | --- |
| Recipe intelligence | `FinderService` / `RecipeDatabaseManager` | iOS consumes Mac + Worker catalogue and live publishers | One deterministic selector; bounded pages; strict safety filters |
| Web recipe import | iOS recipe browser/import review | Publishers produce; iOS reviews and publishes; Mac/Worker consume attributed imports | Preview is not import; retain canonical URL, publisher and rights |
| Household meal planning | iOS meal planner + household journal | Household iPhones/iPads | Plans, reservations, Grocery and Cook transitions remain idempotent |
| Inventory confidence | `FoodNameMatcher` and inventory proposal pipeline | All inventory ingress paths | Quantity, expiry, aliases and units determine availability |
| Grocery optimization | Grocery knowledge, routing and proposal owners | Inventory, recipes, stores and household list | Merge equivalents; preserve confirmed quantities and store facts |
| Offline synchronization | iOS protocol v2 + Worker `HouseholdDO` | Current iOS, older iOS and Mac clients | Durable operations, receipts, tombstones and compatible v1 fallback |
| Personalization | `RecipeInterest` | On-device recipe interactions and Finder ranking | Local-only learning never weakens dietary/allergen exclusions |
| Shared household cooking | `HouseholdCookStore` + Worker feature collection | Household iPhones/iPads | Share progress/helper claims only; never instructions, quantities, notes or timers |
| Health/performance | App Health + Worker health/metrics | iOS and Worker | Bounded diagnostics; visible sync, catalogue, memory, cache and latency state |
| Autonomous QA | Stocked QA + Worker QA envelope | Key/Shalise devices and Worker | Fresh observations only; completed tickets reopen only on a real regression |

## Compatibility and rollout

Deploy UnifiedWorker first so `activeCookSessions` is retained by the generic additive feature merge.
Then ship Stocked iOS. Older clients ignore the field; StockedMac remains recipe/catalogue tooling and
does not gain cooking UI. Missing Worker support falls back to the existing local resumable cooking
session. Existing household documents migrate lazily when the first new-client push arrives; no data
rewrite, namespace change, or destructive migration is needed.

## Verification matrix

- UnifiedWorker: household, recipe, QA and route tests plus typecheck.
- Stocked: pure household/privacy contracts and generic iOS-device compilation.
- Physical devices: Key and Shalise each verify cross-device task claims, offline replay, completion,
  cancellation, Dynamic Type and VoiceOver. Compilation is not a physical-device pass.
- StockedMac: unchanged recipe ingestion/publication behavior; no cooking consumer is added.

