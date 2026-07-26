(See the full guide in the Stocked_Platform_Setup zip / Claude project. This repo copy tracks the checklist.)

- [ ] 1. Add sowensstudios.com to Cloudflare (copy ALL DNS records incl. MX/TXT mail records), switch nameservers at Namecheap
- [ ] 2. Workers & Pages → stocked-receipt-worker → Settings → Domains & Routes → Custom domain api.sowensstudios.com → then flip receiptWorkerURL in BuildConfig.swift next build
- [x] 3b-i. .github/workflows/worker-deploy.yml committed (done by Claude)
- [ ] 3b-ii. Add repo secrets CLOUDFLARE_API_TOKEN + CLOUDFLARE_ACCOUNT_ID on GitHub, push, confirm green Actions run
- [ ] 3c. Create first GitHub Release with latest delta zip
- [ ] 4a. Private Email: support@ mailbox + MX/SPF/DKIM records (in Cloudflare DNS once moved)
- [ ] 4b. cPanel AutoBackup verified with a test restore
- [ ] 4c. Daily catalog-validation cron in cPanel emailing support@
- [ ] 4d. cdn-staging subdomain (cPanel Domains + Cloudflare DNS record)
- [x] 5-i. site/ folder with index/privacy/terms/support + Netlify form + _redirects (done by Claude — fill in real policy text and App Store id)
- [ ] 5-ii. Netlify: link repo (base dir site/), add domains, SSL, enable Forms email → support@
- [ ] 6. Follow the delta loop: commit → apply → build → commit → push → Release
