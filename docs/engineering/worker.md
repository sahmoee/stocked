# Worker delta — content proxy + ten improvements (2026-07-17)

All changes are inside `stocked-receipt-worker/`. The shipped iOS contract is
preserved exactly: X-Stocked-Key gate, POST "/" legacy AI routes returning the
Anthropic envelope (`content[0].text` + `schemaVersion/route/workerVersion`),
and all `/household/*` + `/crowd/*` shapes. `WORKER_VERSION` bumped to
`2026-07-17.1`.

## Changed / new files

| File | Change |
|---|---|
| `index.js` | Wires everything: /content/* + /metrics/today routes, session-aware rate keys, consistent error envelope via `errJson`, runtime AI config (model + max_tokens), prompt caching flag, `no-store` on session responses, sampled metrics in `finally`, `contentOrigin` in /health. |
| `src/content.js` | **NEW.** GET /content/recipes (6h edge cache, 7-day stale-on-error copy, strong ETag + If-None-Match→304, wrapped or bare-array origin format returned unchanged) and GET /content/img/* (30-day edge cache passthrough). Origin = `env.CONTENT_ORIGIN`, default `https://cdn.sowensstudios.com`. |
| `src/metrics.js` | **NEW.** Sampled (1-in-10, weight ×10) daily per-route + error counters in RATE_KV (`metrics:YYYY-MM-DD`), one waitUntil write per sampled request; GET /metrics/today handler. Failures never touch the request path. |
| `src/util.js` | Centralized CORS (`corsHeadersFor` + optional `CORS_ALLOW_ORIGINS` allowlist), `SECURITY_HEADERS` (nosniff, no-referrer) on every JSON response, `errJson`/`codeForStatus` error envelope, `readBoundedJSON`, `strongETag`/`etagMatches`. |
| `src/config.js` | ETag (SHA-256 of config JSON) + 304 on /configuration; `getRuntimeConfig` (60s edge-cached) and `resolveMaxTokens`/`resolveModel` for config-driven AI tuning; `aiLimits` added to defaults. |
| `src/ai.js` | `systemBlocksFor` — `cache_control: {type:"ephemeral"}` on the static system prompt when `promptCache` is set (threaded through `callAnthropicResilient`/`runValidatedRoute`). |
| `src/validation.js` | New validators: `validateBarcodeResolve` (digits 8–14 + GTIN checksum), `validatePricesCompare` (sizeValue>0, sizeUnit whitelist), `validateDiagnostics` (≤64KB), `validateDailyBrief` (bounded context). All yield stable 422 `{code:"invalidInput", errors}`. |
| `src/barcodes.js` | 24h negative-result cache (`{found:false}` keyed on code+includePrice); 30d positive cache kept; bounded body; new validation; error envelope. |
| `src/prices.js` | New validation, bounded body, error envelope (429 keeps Retry-After). |
| `src/diagnostics.js` | 64KB payload bound, trimmed strings in `scrub`, error envelope. |
| `src/dailybrief.js` | Bounded (256KB) + validated context; invalid-JSON leniency preserved. |
| `src/crowd.js` | 256KB bound on /report; error envelope with code+requestId. |
| `src/household.js` | 2MB body bound; all non-2xx bodies (incl. DO passthroughs) get `{code, requestId}` decoration. |
| `src/household-shared.js` | `stableStringify`, `fnv1a`, `pushBatchHash` + dedupe window/size constants. |
| `src/household-do.js` | Push idempotency: rolling set (last 500, 10-min window) of batch-content+sender hashes persisted in DO storage (`recentPushes`); identical retry skips the merge and returns the same success shape (`{ok, changed:false, household, deduped:true}`). (Inspected the push payload: it carries no op/batch ids, so content-hash dedupe is used per the fallback rule.) |
| `src/discover.js` | Stale-while-revalidate: entries stored 3h with `X-Stored-At`; fresh ≤15 min, after that stale is served immediately and `ctx.waitUntil` refreshes. Cache key uses a normalized (lowercased) query. |
| `src/ratelimit.js` | `rateSubject(session, ip)` — valid non-guest X-Stocked-Session keys limits by subject; guests/no-session fall back to IP. |
| `wrangler.toml` | `[vars] CONTENT_ORIGIN` added (+ commented optional `CORS_ALLOW_ORIGINS`). |
| `tests/improvements.test.mjs` | **NEW.** 23 tests for the pure logic above. |
| `MANUAL_STEPS.md` | §9b content proxy (CONTENT_ORIGIN), §9c metrics, §9d AI tuning via config; test command updated. |

## Improvement checklist (all ten)
1. ETag/304 on GET /configuration + /content ETags — done.
2. 24h negative caching for /barcodes/resolve (30d positive kept) — done.
3. Consistent `{error, code, requestId}` on every non-2xx; Retry-After on every 429 — done.
4. Input validation for barcodes/prices/diagnostics/daily-brief with stable 422 `invalidInput` — done.
5. Household push idempotency via content+sender hash, 10-min window, last-500 rolling set in DO storage — done.
6. /recipes/discover SWR (15-min fresh, serve-stale + waitUntil refresh) — done.
7. Session-aware rate-limit keys (session subject, IP fallback) — done.
8. Sampled daily metrics in KV + GET /metrics/today — done.
9. Anthropic prompt caching, KV-tunable max_tokens (`aiLimits`) + model (`aiModel`), Haiku fallback preserved — done.
10. Security sweep: centralized CORS w/ optional allowlist, nosniff/no-referrer headers, no-store on session responses, bounded non-AI POST bodies, constant-time key compare (already present, verified) — done.

## Tests
`node --test tests/*.mjs` → **52 tests, 52 pass, 0 fail** (contracts 7 + logic 22 + improvements 23).

## Caveats
- `/barcodes/resolve` + `/prices/compare` now require **8–14 digit** barcodes (previously 6–14) and return 422 `code:"invalidInput"` (with detailed `errors[]`) instead of the old top-level `invalidBarcode`/`barcodeChecksum` codes — per the task spec; these are post-ship endpoints, not part of the legacy app contract.
- Metrics are approximate (1-in-10 sampling ×10) and the KV read-modify-write can race under high concurrency; acceptable for ops-glanceable counters.
- The negative barcode cache means a product newly added to OpenFoodFacts can take up to 24h to appear for a code that recently missed.
- Prompt caching only activates upstream for prompts ≥ the model's minimum cacheable length; shorter prompts are processed uncached (marker is harmless).
- /content/img/* passthrough trusts the origin's Content-Type; the 7-day stale copy for /content/recipes is only available after at least one successful origin fetch.
- Deploy: nothing new beyond `wrangler deploy` — `CONTENT_ORIGIN` ships in `[vars]`; no dashboard work.
