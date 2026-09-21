# Free kitchen batches

The user has now requested all remaining batches in one run, superseding the earlier pause between
batches. Complete and verify batches 4 and 5 together, then report actual scope. No new paid subscription, API,
hosted AI call, infrastructure purchase or account upgrade is authorized. Existing Apple/Cloudflare
accounts and their limits still apply. Preserve all current kitchen and household data.

| Batch | Scope | State |
| --- | --- | --- |
| 1 — Core tools | Reviewed portable recipe files; credits; safer quantities, matching and nutrition; meal copies/calendar export; free community prices | Built and verified. Worker deployed; physical-device QA and app distribution remain separate. |
| 2 — Bring your recipes | Bounded recipe export archives and multiple-file review; duplicates, private provenance and safe undo; Mac watched-folder queue | Built. Native checks and final generic iOS/Mac builds passed. |
| 3 — Plan ahead | Multiweek dated meals, reviewed finite repeats, reusable planning templates and smart cookbooks using existing storage | Built. 167 native checks, 129 Worker tests and final generic iOS build passed. Worker deployed. Paused before batch 4. |
| 4 — Optional free connections | User-configured Grocy, Cooklang recipe discovery/federation and CalDAV integration where a free existing endpoint supports them | Built and verified. iOS/Mac builds passed; real Cooklang API probe passed. Grocy/CalDAV need user configuration and device QA. |
| 5 — Reliable delivery and recovery | Signed opt-in outbound webhooks, notification/realtime delivery where existing infrastructure permits, explicit price-watch refresh and recovery/diagnostics | Built and verified; Worker deployed. Apple push and optional receivers need configuration. Device delivery QA remains untested. |

## Batch 2 contract

Stocked owns original `KitchenArchive.swift` / `KitchenMigration.swift` implementations, vendored
identically by StockedMac. iOS and Mac produce normal reviewed UserRecipe records; the existing
Worker consumes the unchanged optional provenance and credit fields. No backend deployment,
database migration or household reset is needed. Older clients retain the private envelope; original
URLs stay nested until catalogue-sharing permission is explicit. Raw files are never public data.

Read locally, preview first, and commit through the existing permission-checked recipe store.
Default to private imports. Do not replace saved recipes. Recheck duplicates at commit and keep
completed additions after interruption; retry skips them. Undo may remove only unchanged additions.
The Mac watcher queues files for review while the app is running; it is not a server, automatic
publisher or closed-app background service. Folder selection and publication remain separate actions.

Limits and supported producer formats must be displayed honestly. Full server/database backups,
encrypted archives and unknown schemas are not generic recipe exports. A normalized recipe snapshot
must never be labelled an exact original file. Keep original photo bytes and source credits; do not
invent missing source or photo URLs. Any unsupported fields or photos need an import-review warning.

## Verification and pause

Each batch runs relevant native logic checks and generic iOS/Mac builds. Simulator testing remains
paused. Native tests do not sign off on physical-device UI, VoiceOver, two-device sync or TestFlight.
For the remaining run, finish both batches before reporting build results, supported behavior and limits.
Record later batches here as they are actually completed.

Batch 2 verification: 41 archive checks, 44 shared migration checks and 10 iOS review safety checks
passed. Mac folder and adapter checks passed; final generic iOS and Mac builds passed. The shared
reader files match across both apps. No Worker deploy, simulator run, TestFlight upload or public
website publication was performed. iOS QA section 50 has eleven explicitly untested device checks.

## Batch 3 contract

Stocked iOS owns the dated planning models/store/editors and cookbook filters. Dated records are
feature collections in the existing local database; the active planner remains GuestDataStore-owned.
Only reviewed copies dated today through six days ahead enter its relative slots. Stable IDs,
stale-source checks, skipped exceptions and unchanged-pair undo preserve existing work. Templates
and finite repeats never run while the app is closed or rewrite accepted dates. Saved cookbook
rules scan the current saved library off-main; no second recipe library or public-catalogue scan.

UnifiedWorker registers additive plan/cookbook collections, permission domains and tombstones.
Meal-plan sharing governs plans; recipe sharing governs cookbooks. Queued disabled/unacknowledged
domains remain pending. Old clients and backups preserve omitted collections. Full iOS feature
backups include them; Mac remains recipe/content only, with no planning UI or backup claim.
Read PLAN_AHEAD.md and SMART_COOKBOOKS.md for explicit bounds, rollout and verification commands.

Batch 3 verification: 53 date/core checks, 53 production planning-store boundary checks, 27 cookbook
checks and 34 production sync/backup checks passed. Worker passed 129 tests, typecheck and production
dry-run; deployed version be581647-032b-44ef-87c8-33801541c5bc passed live health/authenticated read
smoke without changing household user data. Final generic iOS build passed; app, share extension
and widgets all report version 5, build 186. No simulator, Mac change, TestFlight upload or public
site publication. QA sections 51–52 add 23 explicitly untested device checks. Paused before batch 4.

## Batches 4 and 5 completion

Completed together on 2026-09-05. iOS entry: Settings → Data & Storage → Free Kitchen Connections.
Mac adds reviewed Cooklang discovery through File → Import Center. Grocy imports reviewed new
items only; CalDAV publishes reviewed calendar copies with conditional writes. Neither is an
automatic two-way mirror. Cooklang imports keep source credits, private provenance and commit-time
duplicate checks. Read FREE_CONNECTIONS.md and COOKLANG_CONNECTIONS.md for setup and limits.

Household delivery uses authenticated foreground WebSocket invalidations with normal polling
fallback. Signed receiver delivery is explicitly opt-in, capability-protected, encrypted and retried
through the existing durable store. Apple push is implemented but no Apple signing credentials are
configured. Older shares need an explicitly created fresh share to obtain secure delivery ownership;
there is no automatic household reset. Daily briefs remain generated/stored with local reminders.
Saved community price checks refresh on request, remain device-only, and do not claim live retail
quotes or unattended monitoring. See FREE_KITCHEN_DELIVERY.md, COMMUNITY_PRICE_CHECKS.md and
UnifiedWorker's docs/HOUSEHOLD_DELIVERY.md.

Verification: 57 native connection checks, 29 Cooklang protocol checks, one real official Cooklang
API probe, six import-commit checks and 31 community-price checks passed. Connection regressions
cover intervening calendar edits and credential removal blocking subsequent requests. Worker passed
150 tests, typecheck and production dry-run. Native workerd exercised real authenticated WebSockets,
membership rejection, chunk storage without a KV mirror, receipt replay and durable receiver alarms.
The native storage check found and repaired a record/Map API mismatch before rollout.

Worker version 1bd3a787-e37f-4ff0-9662-37035efc2b9d deployed successfully; read-only production health,
community-price and delivery-auth smoke passed. Final generic iOS and Mac builds passed; iOS app,
share extension and widgets all report version 5, build 189. Shared Cooklang core/panel files match.
Source credits and the website sources page were updated; HTML/local-link and repository diff checks
passed. No new paid services, resources, migrations or user-household changes were introduced.

QA sections 53–57 contain 44 explicitly untested device checks. Physical-device UI/VoiceOver,
real Grocy/CalDAV accounts, Apple push and two-device journeys still need QA. No simulator run,
TestFlight upload, public site publication, live receiver enrollment or user push was performed.
All planned batches are implemented; remaining work is optional service configuration, device QA
and separately authorized app/site distribution.
