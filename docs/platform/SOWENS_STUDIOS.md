# Sowens Studios — Brand & Contact (memory)

_Last updated: 2026-07-16_

## Identity
- **Company:** Sowens Studios LLC
- **Website:** https://www.sowensstudios.com (already live)
- **Support email:** support@sowensstudios.com (Namecheap Private Email)
- **App:** Stocked (iOS, SwiftUI)
- **Apple bundle ID:** `com.sowens.Stocked` (unrelated to the web domain — leave as-is)
- **App Group:** `group.com.sowens.Stocked`

## Infrastructure (confirmed 2026-07-16)
- **Marketing site:** Netlify, deployed from GitHub → `sowensstudios.com` (project profound-bienenstitch-363448).
- **Namecheap Stellar Plus (cPanel):** shared hosting, ~empty (2.3 MB used, 300k inode cap), MySQL/Postgres,
  cron, Git, SFTP, email. Use for bulk storage / relational archive / batch cron / email — NOT the app hot path.
- **Namecheap Private Email:** `support@sowensstudios.com` (transactional/support sender via SMTP).
- **Cloudflare Worker:** `stocked-receipt-worker` @ `https://stocked-receipt-worker.stocked.workers.dev`
  (session, household DO sync, crowd, barcodes, prices, recipes/discover, daily-brief, configuration, diagnostics).
  Optional custom domain `api.sowensstudios.com` (`BuildConfig.receiptWorkerCustomURL`).

## Where this is wired into the app
Single source of truth: `Stocked/BuildConfig.swift`
- `company`, `websiteURL`, `supportEmail`, `privacyURL`, `termsURL`, `supportPageURL`
Used by:
- Settings → Help & Support: Contact Support (pre-filled mailto), Privacy, Terms, Website.
- Sign-in screen: Privacy Policy · Terms links.
- Settings footer: "Sowens Studios · sowensstudios.com".

## Web paths the app links to (host on the existing site)
- Privacy: https://sowensstudios.com/privacy  ← App Store requires this
- Terms:   https://sowensstudios.com/terms
- Support: https://sowensstudios.com/support
