# Stocked — Infrastructure Playbook (Namecheap/cPanel · Netlify · Cloudflare Worker)

State as of July 17, 2026: site live on Netlify from `sahmoee/site-repo`, DNS on
Cloudflare, `api.sowensstudios.com` proxied to the Worker (healthy, v2026-07-17.2),
support@ mail passing SPF/DKIM/DMARC, and the Worker's content origin reading from
GitHub raw (`sahmoee/site-repo@master`). The app already calls the custom domain —
zero references to workers.dev remain in the codebase.

## The data path, layer by layer

Every read the app makes should fall through this chain, cheapest first:

1. **On-device** — AIResultCache (AI responses), URLCache (HTTP), ImageCache,
   SQLite corpus, LocalDatabase. Free, instant, works offline.
2. **Worker edge cache** — Cache API + KV at Cloudflare's edge: barcodes 30d,
   content 6h + stale-on-error, discover 15m SWR, config ETag/304.
3. **Origins** — GitHub raw (recipe catalog), cPanel (bulk assets), third-party
   APIs (OpenFoodFacts, retailerapi), Anthropic. Slowest, rate-limited, or paid —
   the layers above exist to protect these.

Rule of thumb for every future feature: add it at layer 3 only if layers 1–2
can shield it.

## How each platform now feeds the others

**GitHub (site-repo) → everything.** One commit to `site-repo` now updates three
surfaces at once: Netlify redeploys the website (~4s), the Worker's
`/content/recipes` picks it up within its 6-hour cache window, and the app
refreshes on its next catalog fetch. This makes GitHub the single publish button
for recipes AND the site. Practical upgrades:
- Add a `version` and `updated` field bump on every catalog edit (the wrapped
  `{version, recipes:[…]}` format the app already parses) so you can see at a
  glance which build of the catalog users have.
- Put recipe *images* in the repo too and reference them with **absolute URLs**
  in recipes.json. The app resolves relative paths against cdn.sowensstudios.com,
  so absolute URLs are the safe way to serve images from the new GitHub origin
  (or through the Worker's `/content/img/*` 30-day edge cache).
- A JSON-validity check in CI (site-repo GitHub Action: `jq . content/recipes.json`)
  makes a broken publish impossible — Netlify won't deploy a failed build.

**Worker → app (the only backend).** Already the hub: AI, household sync DO,
config kill switches, barcodes, prices, discover, diagnostics, metrics, content
edge cache. Highest-value next steps:
- **Fresher content without hammering origin:** lower `/content/recipes` cache to
  1h but add ETag revalidation against GitHub (raw serves ETags) — users see new
  recipes within the hour, origin still barely touched.
- **Daily brief adoption:** the app still generates briefs on-device; the Worker's
  `/daily-brief/generate` + queue/cron pipeline is deployed and idle. Wiring the
  app to POST its context snapshot buys server-side briefs with zero device wake.
- **Config as the control panel:** you now have kill switches live — start using
  `config:current` for gradual feature rollout (`"rollout": {"multiStore": 50}`)
  so new features can ship dark and turn on server-side.

**cPanel (Namecheap) → bulk storage + jobs.** With the catalog on GitHub, cPanel's
best remaining jobs are the ones GitHub is bad at:
- **Large/binary assets**: recipe photography, video clips, seasonal packs —
  GitHub repos bloat fast; cPanel's unmetered disk doesn't care. Keep them under
  `cdn.sowensstudios.com`, referenced absolutely from recipes.json, optionally
  fronted by the Worker's `/content/img/*` cache for edge speed.
- **Scheduled jobs**: the daily cron validating recipes.json (now: fetch the
  GitHub raw URL instead of a local file) and emailing support@ on failure.
- **AutoBackup**: weekly restore points of the asset folder.
- **Mail is its crown jewel**: support@ is authenticated and deliverable — wire it
  everywhere (Netlify form notifications, cron alerts, GitHub Actions failure
  emails via the repo's notification settings).

**Netlify → the trust layer.** The site is live and featuring Stocked; connect it
back to the app and store:
- `/support` form → email notifications to support@ (Forms → Notifications) with
  the STK- diagnostics-reference field, so app crash reports and human reports
  meet in one inbox.
- `_redirects` smart links: `/app` → App Store listing (fill the id at release),
  `/api-status` → a tiny status page that fetches `api.sowensstudios.com/health`
  client-side — a public health check that costs nothing.
- App Store listing URLs (privacy/terms/support) should point at the Netlify
  pages; BuildConfig already carries them.

## Sync, storage, and import — the next tier of improvements

**Sync.** The Durable Object + offline queue + idempotent pushes are solid. The
remaining wins: (1) adopt the session token as the household identity anchor so
rate limits and future per-user quotas key on accounts, not IPs (worker already
supports it); (2) expose `GET /household/summary` (counts + updatedAt only) so
the app's 6-second poll can become a cheap HEAD-style check that only pulls when
something changed — less battery, less DO traffic.

**Cache.** Three small compounding moves: send `If-None-Match` from the app on
`/content/recipes` (the client already stores ETags for the cdn path — keep that
behavior against the Worker); let `config:current`'s `aiLimits` trim max_tokens
on your two highest-volume AI routes (receipts, import) after checking
`/metrics/today` for real usage; and prefetch the catalog on Wi-Fi only.

**Storage.** When shareable exports or cross-device photo sync become real
features, that's the moment for Cloudflare R2 bound to the Worker (signed URLs,
no egress fees) — not before. Until then cPanel disk + on-device storage cover
everything free.

**Importing / updating recipes.** The full loop is now: Recipe Studio (or you)
commits to site-repo → CI validates JSON → Netlify shows it on the web → Worker
edge-caches it for the app → app merges by recipe `id` (stable ids matter — never
reuse one). Social/web imports flow through the Worker's `recipeImport` route
with the preview UX. The one missing piece worth building: a `removedIds` array
in the catalog so a bad recipe can be *retracted* from Discover, not just
stop appearing — pairs with the kill-switch philosophy.

## Ranked shortlist

1. Absolute image URLs (or Worker-proxied paths) in recipes.json — prevents the
   one real breakage risk of the GitHub-origin move.
2. Netlify Forms → support@ notifications + `/app` redirect filled in at release.
3. CI JSON validation on site-repo; retire the cPanel local-file cron in favor of
   one that fetches the GitHub raw URL.
4. App adoption of server daily briefs.
5. Rollout percentages in `config:current` for the next feature launch.
6. `/household/summary` cheap-poll endpoint.
7. R2 — only when shareable exports ship.
