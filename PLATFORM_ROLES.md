# Sowens Studios — Best Use of Each Platform

One job per platform, no overlap. The app talks to exactly one backend (the Worker);
everything else supports that.

## Cloudflare Worker — the entire live backend
Already its best self after the July delta; keep it the ONLY thing the app calls.
- All AI (Anthropic key server-side, validation, rate limits, prompt caching, fallback model)
- Household sync (Durable Object, idempotent pushes), crowd DB
- `/configuration` kill switches + maintenance + min-version — your no-App-Store-release lever
- `/barcodes/resolve`, `/prices/compare`, `/recipes/discover`, `/daily-brief`, `/support/diagnostics`, `/metrics/today`
- `/content/*` edge cache in front of the cPanel origin
- Next step: finish the `api.sowensstudios.com` custom domain (requires the domain's DNS
  zone on Cloudflare — see Namecheap section), then flip `receiptWorkerURL` to it. Both
  URLs hit the same Worker, so this is a zero-risk switch.

## GitHub — source of truth + automation
- Private repo for app + worker (already in place). Commit BEFORE and AFTER applying each
  Build Buddy delta — that turns every delta into a one-command rollback (`git revert`).
- Tag every TestFlight build (`build-54` etc.) so any shipped binary maps to exact source.
- **GitHub Actions (free tier is plenty):** on push to `stocked-receipt-worker/**`, run
  `node --test tests/*.mjs` and then `wrangler deploy` with a `CLOUDFLARE_API_TOKEN`
  secret — the Worker deploys itself; no laptop needed. A second workflow can run
  SwiftLint/`swift build` checks on PRs if you ever want app CI (macOS runners cost more;
  optional).
- Releases: attach each delta zip + the archived .ipa notes → permanent, searchable history.
- Free extras worth switching on: Dependabot alerts (worker deps), secret scanning
  (catches an accidentally committed key), branch protection on `main`.

## Netlify — the public face (apex sowensstudios.com)
Static marketing + the pages Apple requires, deployed from GitHub.
- Marketing/landing page, `/privacy`, `/terms`, `/support` (App Store links point here)
- Netlify Forms for the support/contact form (no server needed; forwards to your email)
- `_redirects` for smart links (`/app` → App Store URL, short links in notifications/emails)
- Deploy Previews: every site PR gets its own URL before going live
- Keep it OUT of the app's hot path — no app-critical JSON on Netlify, so a site redeploy
  can never break the app.

## Namecheap — registrar, mail, and the content origin (Stellar Plus)
Get full value from what the paid plan includes, and nothing app-critical beyond that:
- **Domain registration stays here** (cheap renewals). Recommended: move the DNS zone
  (nameservers) to Cloudflare Free — that's what unlocks `api.sowensstudios.com` for the
  Worker and gives cdn/apex records Cloudflare's edge. Apex keeps pointing at Netlify,
  `cdn` keeps pointing at cPanel; only the nameservers change. (Namecheap PremiumDNS
  becomes unnecessary at that point.)
- **cPanel (Stellar Plus) = the content ORIGIN**: Recipe Studio publishes
  `content/recipes.json` + images to `cdn.sowensstudios.com`; the Worker's `/content/*`
  edge cache serves users, so shared hosting speed stops mattering. Use cPanel cron jobs
  to regenerate/validate the catalog on a schedule.
- **Private Email** (included/cheap): `support@sowensstudios.com` — the address BuildConfig,
  the App Store listing, and diagnostics reports already reference.
- **AutoBackup + staging** (included on Stellar Plus): weekly restore points for the
  content folder; a staging subdomain (`cdn-staging`) to preview a new catalog before the
  Worker cache picks it up.
- Don't run PHP apps/databases there for the product — anything dynamic belongs in the
  Worker.

## Build Buddy — the change-delivery workflow
- Best for what it's doing now: focused, single-purpose delta zips of full-file
  replacements + notes, applied over the repo, sandwiched between two git commits.
- Keep deltas SMALL from here on (one feature or fix per zip) — the giant catch-up delta
  is done; small deltas make Xcode errors instantly attributable.
- Include a `docs/` note + test list in every delta (already the pattern); file deletions
  ship as a `.command` script like this package does.

## The flow, end to end
GitHub holds the truth → Actions deploys the Worker → the app talks only to the Worker →
the Worker fronts cPanel content and third-party data → Netlify carries the public site
and support pages → Namecheap holds the domain, mailboxes, and the content origin →
Build Buddy moves code changes into the repo between commits.

## Quick wins, in order
1. Move DNS to Cloudflare, verify `api.sowensstudios.com`, flip `receiptWorkerURL`.
2. Add the GitHub Action for worker test + deploy.
3. Put `/privacy`, `/terms`, `/support` + a Netlify Form live on the apex.
4. Set up `support@` on Private Email and turn on cPanel AutoBackup for `content/`.
5. Tag the next TestFlight build in git and attach its delta zip to a GitHub Release.
