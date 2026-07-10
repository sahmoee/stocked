# Stocked — crowd DB merged into your existing worker

One worker now does everything. The shared "crowd" database (item intelligence for all users)
lives inside your already-deployed **stocked-receipt-worker** under new `/crowd/*` routes. No
second worker, no new URL, no new key, no new KV namespace.

## What changed
- `stocked-receipt-worker/index.js` — added a `/crowd` dispatch + `handleCrowd()` handler.
  Reuses the existing `X-Stocked-Key` auth and the existing `RATE_KV` namespace (keys are
  prefixed `crowd:`, so it can't collide with receipt rate-limit or `hh:` household data).
- `Stocked/CrowdDB.swift` — client that calls `BuildConfig.receiptWorkerURL` with the existing
  `BuildConfig.stockedWorkerKey`. Zero new config.
- `Stocked/CrowdShareToggle.swift` — Settings toggle (contribution ON by default, opt-out).

## Deploy (one command)
```sh
cd stocked-receipt-worker
wrangler deploy
```
That's it — same worker, same secrets (`STOCKED_SHARED_KEY`, `ANTHROPIC_API_KEY`), same KV.

Sanity check (replace KEY with your STOCKED_SHARED_KEY):
```sh
curl -X POST -H "X-Stocked-Key: KEY" -H "Content-Type: application/json" \
  -d '{"name":"milk"}' \
  https://stocked-receipt-worker.stocked.workers.dev/crowd/suggest
# -> {"count":0,"topUnit":null,...}  (empty until reports arrive — correct)
```

## Add to the app
1. Add `CrowdDB.swift` and `CrowdShareToggle.swift` to the Stocked target.
2. Drop `CrowdShareToggle()` into your Settings `Form`.
3. After a scan / add / receipt review:
```swift
// Prefill from the crowd (read):
if let s = await CrowdDB.suggest(name: itemName) {
    if amount.container == "item", let c = s.topContainer { amount.container = c }
    if amount.unitEach == nil, let u = s.topUnit { amount.unitEach = u }
    if let q = s.avgQuantity, amount.count == 1 { amount.count = q }
}
let options = await CrowdDB.autocomplete(prefix: typed)
let pairs   = await CrowdDB.pairings(name: itemName)

// Report on save (respects the toggle; pass the basket for pairings):
await CrowdDB.report(
    items: savedItems.map { ($0.name, $0.category, $0.unitEach ?? "", $0.container, $0.count) },
    basket: savedItems.map { $0.name }
)
```

## Endpoints added (all POST, all require X-Stocked-Key)
```
POST /crowd/report        { items:[{name,category,unit,container,quantity}], basket?:[names] }
POST /crowd/suggest       { name }         -> { count, topUnit, topContainer, topCategory, avgQuantity }
POST /crowd/autocomplete  { prefix, limit? } -> { items:[...] }
POST /crowd/pairings      { name }         -> { pairings:[["tomato",210],...] }
```

## Privacy line for your listing / privacy page
> Stocked shares anonymized item facts (product name, category, typical size/quantity) so the app
> can suggest better defaults for everyone. It never shares your name, account, contacts, photos,
> or location, and you can turn this off in Settings.
