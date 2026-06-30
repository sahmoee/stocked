# Stocked. Receipt Worker

Server-side proxy to the Anthropic API. Keeps the `sk-ant-…` key off the device and adds
rate limiting + a shared-secret check so a leaked endpoint can't burn your Anthropic budget.

Deployed URL (matches `BuildConfig.receiptWorkerURL` in the app):
`https://stocked-receipt-worker.stocked.workers.dev`

## What calls it (payload shapes — keep these stable)
- Receipt OCR parse → `{ "receipt": "...", "storeName"?: "...", "corrections"?: {...} }`
- Barcode lookup    → `{ "barcode": "0123456789012" }`
- Recipe import     → `{ "recipeText": "..." }`
- Recipe generate   → `{ "recipeIdea": "...", "haveItems"?: [...], "dietary"?: "...", "maxTime"?: "..." }`
- Inventory intent  → `{ "intent": "...", "inventory": [...] }`

All return Anthropic's response envelope unchanged; the app reads `content[0].text`.

## One-time setup

1. **Install Wrangler & log in**
   ```sh
   npm install -g wrangler
   wrangler login
   ```

2. **Create the KV namespace for rate limiting**, then paste its id into `wrangler.toml`
   (`RATE_KV` → `id`):
   ```sh
   wrangler kv namespace create RATE_KV
   ```

3. **Set the secrets** (these are NOT in any file — they live in Cloudflare):
   ```sh
   wrangler secret put ANTHROPIC_API_KEY     # your sk-ant-… key
   wrangler secret put STOCKED_SHARED_KEY     # a long random string (see below)
   ```
   Generate a strong shared key:
   ```sh
   openssl rand -hex 32
   ```
   Put that SAME value in the app at `BuildConfig.stockedWorkerSharedKey` (via
   `Secrets.xcconfig` / `$(VAR)`, never hard-coded). The app sends it as the
   `X-Stocked-Key` header; the Worker rejects requests that don't match.

4. **Deploy**
   ```sh
   wrangler deploy
   ```

## Tuning the limits
Edit the constants at the top of `index.js`:
- `PER_MINUTE_LIMIT` (default 12) — burst cap per IP.
- `PER_DAY_LIMIT` (default 200) — daily cap per IP (bounds Anthropic spend per abuser).
- `MAX_BODY_BYTES` (default 200 KB) — reject oversized payloads.
- `ANTHROPIC_MODEL` — set in `wrangler.toml` `[vars]` or via the dashboard.

## Notes
- The shared secret ships inside the app, so it's obfuscation, not true authentication — its
  job is to stop drive-by abuse of the public URL. Rate limiting is the real backstop.
- If you rotate `STOCKED_SHARED_KEY`, update it in BOTH places (Worker secret + app) and ship
  an app build, or older app versions will start getting 401s.
- Without `RATE_KV` bound, the Worker still runs but skips rate limiting (logs nothing) — bind
  it before relying on the cap.
- This Worker source belongs in version control (it wasn't before). Keep it here under
  `_worker/stocked-receipt-worker/`.
