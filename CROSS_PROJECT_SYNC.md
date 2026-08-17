# Cross-project sync

Also apply the ten additive cross-project safeguards in `PROJECT_GUIDE_ADDITIONS.md`; existing ownership and compatibility rules remain authoritative.

- `StockedMac`: creates/edits/imports the shared image-complete recipe library.
- `UnifiedWorker`: AI, household, recipe/harvest content, QA, queues, and compatibility routes.
- `site-repo`: public product pages and content feeds.

Recipe schemas, images, provenance, categories, household data, QA, or API changes require compatible updates across affected repos. Keep old records and released clients working; make fields additive and repairs retroactive.

Stocked QA uses the shared `Joo` ten-minute gate. Once unlocked, sync first merges the app-scoped Worker ticket collection from every iPhone/iPad, then publishes local changes. Mac apps do not expose in-app QA.

UnifiedWorker owns Kroger OAuth and RapidAPI host allowlisting. StockedMac discovers and publishes normalized grocery catalog records; Stocked iOS finds provider-backed stores and consumes normalized product data. Never add provider secrets to iOS, and keep store-specific price/availability/aisle caches bounded so stale data cannot replace user-confirmed inventory.
