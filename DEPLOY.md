# Stocked — shared cloud backend (+ how it sits next to CloudKit)

You now have **two servers**, each doing the job it's good at:

| Layer | What it stores | Who runs it | User setup |
|---|---|---|---|
| **CloudKit** (already in the app) | Each user's OWN pantry/grocery/household data, synced across THEIR devices; multi-Apple-ID household sharing via `HouseholdCloudKit`. | Apple, on each user's iCloud | none — automatic |
| **Shared crowd backend** (this package) | Cross-user AGGREGATES only — typical unit/container/quantity per item, autocomplete, pairings. No personal data. | You (one Cloudflare Worker) | none — baked in |

CloudKit = "my stuff, everywhere." Crowd backend = "everyone's stuff makes the app smarter for all." They don't overlap.

---

## Deploy the shared backend (one time, ~5 min)

Prereq: a free Cloudflare account and Node installed.

```sh
cd crowd-worker
npm i -g wrangler          # or: npx wrangler ...
wrangler login

# 1) Create the KV store, then paste the printed id into wrangler.toml (id = "...")
wrangler kv namespace create CROWD

# 2) Set the shared app key (any long random string). Use the SAME value in CrowdDB.defaultKey.
wrangler secret put CROWD_KEY

# 3) Ship it
wrangler deploy
```

`wrangler deploy` prints your URL, e.g. `https://stocked-crowd.<your-subdomain>.workers.dev`.

Quick check (replace KEY):

```sh
curl -H "X-Stocked-Key: KEY" \
  "https://stocked-crowd.<your-subdomain>.workers.dev/suggest?name=milk"
# -> {"count":0,"topUnit":null,...}  (empty until reports arrive — that's correct)
```

---

## Point the app at it (developer, one time — not per user)

In `Stocked/CrowdDB.swift` set the two baked-in defaults to your real values:

```swift
static let defaultURL = "https://stocked-crowd.<your-subdomain>.workers.dev"
static let defaultKey = "the-same-key-you-put-with-wrangler-secret"
```

(Optional, cleaner: leave those as-is and instead add `CrowdWorkerURL` / `CrowdWorkerKey`
to `Secrets.xcconfig` → Info.plist. Info.plist wins over the baked default.)

That's it. Every downloaded copy now uses the shared backend automatically.

---

## Wire it into the app (3 files in this package)

1. **Add** `CrowdDB.swift` and `CrowdShareToggle.swift` to the Stocked target.
2. **Settings:** drop `CrowdShareToggle()` into your Settings `Form`. Contribution is ON by
   default (opt-out); reads always work.
3. **After a scan / add / receipt review**, prefill the quantity editor with crowd defaults and
   report what the user kept:

```swift
// Prefill (read — no opt-in needed):
if let s = await CrowdDB.suggest(name: itemName) {
    if amount.container == "item", let c = s.topContainer { amount.container = c }
    if amount.unitEach == nil, let u = s.topUnit { amount.unitEach = u }
    if let q = s.avgQuantity, amount.count == 1 { amount.count = q }
}

// Autocomplete while typing a name:
let options = await CrowdDB.autocomplete(prefix: typed)

// "Goes well with…" on a recipe/ingredient:
let pairs = await CrowdDB.pairings(name: itemName)   // [(name, count)]

// Report on save (respects the toggle automatically; pass the whole basket for pairings):
await CrowdDB.report(
    items: savedItems.map { ($0.name, $0.category, $0.unitEach ?? "", $0.container, $0.count) },
    basket: savedItems.map { $0.name }
)
```

Nothing is sent unless `CrowdDB.isEnabled` (the toggle) is true, and only the fields above ever
leave the device.

---

## Privacy note for the App Store listing / privacy page

> Stocked shares anonymized item facts (product name, category, and typical
> size/quantity) with a shared database so the app can suggest better defaults for
> everyone. It never shares your name, account, contacts, photos, or location, and
> you can turn this off in Settings.

Add "Product interaction / anonymized" to your App Privacy questionnaire; it is **not** linked to
identity.
