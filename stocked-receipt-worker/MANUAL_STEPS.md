# Stocked Worker — Manual Deployment Steps

Everything in `index.js` + `src/` is code-complete and tested. The steps below are
the parts I can't do from code (Cloudflare dashboard/CLI config, secrets, Apple
setup). Do them in order. Nothing here breaks the shipped app: all existing
routes, shapes, and the `X-Stocked-Key` gate are preserved.

Prereqs: `npm i -g wrangler`, then `wrangler login`.

---

## 0. Upgrade to the Workers Paid plan ($5/mo)
Durable Objects (household sync) and Queues (daily brief) require it.
Dashboard → Workers & Pages → Plans → **Workers Paid**.
*(Everything else — rate limiting, cron, crypto codes, validation, timeouts — works on Free. If you stay on Free, delete the `[[durable_objects.*]]`, `[[migrations]]`, and `[[queues.*]]` blocks from `wrangler.toml`; household then falls back only if you also restore the old KV handler, so paid is recommended.)*

## 1. Set secrets (once per Worker)
```bash
wrangler secret put ANTHROPIC_API_KEY      # your sk-ant-… key
wrangler secret put STOCKED_SHARED_KEY     # long random; must equal the app's value
wrangler secret put SESSION_SIGNING_KEY    # NEW: long random (e.g. `openssl rand -hex 32`)
```
`SESSION_SIGNING_KEY` signs the short-lived session tokens (improvement #3). Generate it fresh; it never leaves Cloudflare.

## 2. Confirm KV namespace ids
`wrangler.toml` already has `RATE_KV` and `CROWD` ids. If deploying to a new account:
```bash
wrangler kv namespace create RATE_KV
wrangler kv namespace create CROWD
```
Paste the returned ids into `wrangler.toml`.

## 3. Durable Object (household sync — improvement #1)
No dashboard step needed — the binding + migration are in `wrangler.toml`
(`HOUSEHOLD_DO` → class `HouseholdDO`, migration tag `v1` / **`new_sqlite_classes`**).
It's created automatically on first `wrangler deploy`. Note: Cloudflare no longer
allows the old KV-backed DO storage for new classes, so the migration uses
`new_sqlite_classes` (SQLite backend). HouseholdDO uses only the key-value storage
API (`storage.get/put/deleteAll`), which works unchanged on that backend. Households are keyed by code
(`idFromName(code)`); the KV `hh:` mirror is kept as a cheap snapshot/backup.
**Verify after deploy:** `GET /health` should show `"hasHouseholdDO": true`.

## 4. Native Rate Limiting (improvement #2)
The five `[[unsafe.bindings]]` limiters (`RL_AI`, `RL_RECEIPT`, `RL_HOUSEHOLD`,
`RL_CROWD`, `RL_DEFAULT`) are in `wrangler.toml`. `namespace_id` is any unique
integer per limiter (1001–1005 chosen); `period` must be `10` or `60`. Tune the
`limit` values to taste. If a binding name is wrong/absent the Worker
automatically falls back to the coarse Cache-API counter, so you can't lock
yourself out during rollout. **Verify current syntax** against
`https://developers.cloudflare.com/workers/runtime-apis/bindings/rate-limit/`
(this binding's TOML shape has changed once before).

## 5. Queues + Cron (daily brief — new function #10)
```bash
wrangler queues create stocked-briefs
wrangler queues create stocked-briefs-dlq     # dead-letter for failed jobs
```
The producer/consumer bindings and the cron (`0 13 * * *`, 13:00 UTC daily) are
already in `wrangler.toml`. To opt a household into scheduled briefs, the app (or
a job) writes a context snapshot to KV under `briefctx:<code>`; the cron enqueues
one job per snapshot, the consumer generates the brief and stores it at
`brief:<code>`. On-demand generation works immediately via `POST /daily-brief/generate`.

## 6. Deploy (improvement #10)
```bash
wrangler deploy --dry-run            # bundles all src/ modules, catches config errors
wrangler deploy                      # FIRST deploy must be a normal deploy — it applies
                                     # the Durable Object migration (see note below)
```
**Durable Object migration = first deploy must be `wrangler deploy`, not `versions upload`.**
Cloudflare rejects a DO migration via a versioned/gradual upload
(`error 10211: migrations must be fully applied via a non-versioned deployment`).
So the very first deploy of this Worker uses `wrangler deploy`. **After** the
migration is applied, `wrangler versions upload` works normally for gradual
rollouts of later changes:
```bash
# later changes only (migration already applied):
wrangler versions upload             # versioned preview URL to smoke-test
wrangler versions deploy             # promote the version
```
`GET /health` on the deployed URL should return:
`{ ok, version, hasAnthropicKey:true, hasSharedKey:true, hasSessionKey:true, hasHouseholdDO:true }`.
Structured logs (route, requestId, duration, model, status) stream in
**Workers → your worker → Logs** (`[observability] enabled = true` is set).

## 7. Auth hardening — Apple side (improvement #3)
The Worker verifies Apple identity tokens and issues session tokens **today**; the
app must start sending them.

1. Set your real bundle id in `wrangler.toml` → `[vars] APPLE_BUNDLE_ID`.
2. **App change:** after Sign in with Apple, POST the `identityToken` to
   `/session/apple` (with `X-Stocked-Key`). Store the returned `session` and send
   it as `X-Stocked-Session` on subsequent calls. Guests: `POST /session/guest`.
   Refresh when it expires (1h). *(The Worker already accepts these; wiring the
   app to send them is the remaining app-side task.)*
3. **App Attest (optional, for expensive AI routes):** set `[vars] APP_ATTEST_ENABLED = "1"`
   only after the app performs App Attest and sends `X-Stocked-Attest*` headers.
   Full attestation-chain validation (CBOR → X.509 to Apple's App Attest root)
   needs your Team ID + App ID and a careful review pass — the current
   `verifyAttestation` implements the per-call **assertion** signature check and
   is a no-op until you flip the flag, so it can't lock anyone out prematurely.
   Apple ref: `https://developer.apple.com/documentation/devicecheck`.

## 8. Run the tests
```bash
node --test tests/*.mjs   # contracts + logic + improvements, all green
```

---

## 9. New endpoints (config / barcodes / diagnostics)
- **GET /configuration** — serves defaults (nothing disabled) until you set a config.
  Edit it live, no redeploy:
  ```bash
  wrangler kv key put --binding=RATE_KV config:current \
    '{"maintenance":{"active":false,"message":""},"killSwitches":{"aiRecipeGeneration":false},"disabledRecipeSources":[],"minSupportedVersion":"4.10"}'
  ```
  The app fetches this (with X-Stocked-Key) to flip flags / show maintenance / kill a
  broken feature without an App Store update. Cached ~60s at the edge.
- **POST /barcodes/resolve** — `{ "barcode": "0036000291452" }` → OpenFoodFacts lookup,
  normalized + cached 30 days. Returns `{found:false}` when the DB has no match (app
  falls back to its AI/manual path). No config needed.
- **POST /support/diagnostics** — accepts a scrubbed payload, returns `{reference}`.
  Read a report the user quotes:
  ```bash
  wrangler kv key get --binding=RATE_KV diag:STK-XXXXXXXXXX
  ```

## 9b. Curated content proxy (GET /content/*)
The worker now fronts the cPanel-hosted curated content:
- `[vars] CONTENT_ORIGIN` in `wrangler.toml` is preset to
  `https://cdn.sowensstudios.com` — **change it only if the content host moves**.
  No secret, no dashboard step; it deploys with the worker.
- **GET /content/recipes** (X-Stocked-Key gated) proxies
  `<CONTENT_ORIGIN>/content/recipes.json`, cached 6 h at the edge with a 7-day
  stale copy served if the origin is down. Sends a strong ETag and answers
  `If-None-Match` with 304. Accepts either the wrapped `{version,recipes:[…]}`
  or bare-array origin format and returns it unchanged.
- **GET /content/img/*** passthrough-proxies images with a 30-day edge cache, so
  image URLs can move behind the worker's domain later with no origin change.
- `GET /health` now also reports `contentOrigin` so you can confirm the var took.

## 9c. Ops metrics (GET /metrics/today)
Sampled (1-in-10) daily per-route request/error counters live in `RATE_KV` under
`metrics:YYYY-MM-DD`. Nothing to configure. Read today's rollup (shared-key gated):
```bash
curl -H "X-Stocked-Key: …" https://<worker>/metrics/today
```
Counts are approximate (sampled ×10). Metrics failures never affect requests.

## 9d. AI tuning via config (no redeploy)
`config:current` in RATE_KV now also supports:
- `"aiModel": "claude-…"` — overrides the primary model (Haiku fallback preserved).
- `"aiLimits": { "recipeGeneration": 3000, … }` — per-route `max_tokens` override
  (bounded 100–16000; unknown routes ignored).
Example:
```bash
wrangler kv key put --binding=RATE_KV config:current '{"aiModel":null,"aiLimits":{"recipeGeneration":3500}}'
```

## 10. retailerapi (price data — optional, key-gated)
Adds real cross-retailer prices (Walmart, Amazon, Target, Best Buy, …) by UPC.
```bash
wrangler secret put RETAILERAPI_KEY      # rk_live_… from app.retailerapi.com (free 1,000/mo)
```
- **`/barcodes/resolve`** now merges retailerapi **price + where-to-buy** onto the
  OpenFoodFacts food data. Split cache: food data 30 days, price 12 h. The app can
  send `includePrice:false` to skip the retailer call and conserve quota.
- **`POST /prices/compare`** `{ "barcode":"…", "sizeValue":16, "sizeUnit":"oz" }` →
  ranked per-retailer prices (cheapest first) + unit pricing (per-oz/per-lb). Cached 12 h.
- **Honest limits:** packaged/UPC goods only (no fresh produce), major retailers not
  local chains. Without the key both paths simply skip retailerapi (barcodes still
  return OpenFoodFacts). Free tier is 1,000 lookups/mo — caching keeps you well under.

### Rollback
`wrangler rollback` reverts to the previous version. The old single-file worker is
in git history if you need it. Because the app-facing contract is unchanged, you
can redeploy the old worker at any time without an app update.

### What changed vs. the old worker (app impact: none)
- Single `index.js` → `index.js` + `src/*.js` (wrangler bundles automatically).
- Household KV get→merge→put → serialized Durable Object (same request/response).
- `Math.random()` codes → `crypto.getRandomValues`.
- `fetch(request, env)` → `fetch(request, env, ctx)` with `waitUntil`.
- Anthropic call → timeout + circuit breaker + Haiku fallback + output validation.
- New endpoints added; none change existing routes.
