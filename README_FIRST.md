# Read me first

Also apply the ten additive README-first safeguards in `PROJECT_GUIDE_ADDITIONS.md`; they extend this project-specific contract without removing existing functionality.

Stocked is a local-first iOS/iPadOS 26 kitchen app with widgets and a share extension. Local inventory and user work are authoritative. Recipes entering or leaving the app require usable images, durable provenance, categories, and backward-compatible repair.

`Secrets.xcconfig` is local and ignored. Production services use `https://api.sowensstudios.com`; never ship provider keys. Start in the feature named by the task, include extensions when affected, and run the narrowest tests plus the `Stocked` build.

Recipe views prefer publisher-original image URLs, retain exact downloaded bytes in cache, and fall back to embedded data only when offline or the source fails. Keep the thin charcoal image border consistent.

Retail enrichment uses authenticated UnifiedWorker `/retail/*` routes. Kroger and RapidAPI credentials remain server-side. Keep official provider location/product IDs optional, preserve original product images and exact aisle data, and treat price, availability, and inventory as short-lived store-specific metadata rather than household truth.

Kroger is the default store for new or reset installations and grocery-cart handoff. FatSecret is an additive server-side brand/nutrition source; enrichment fills missing or lower-confidence fields across historical repairs and future imports without replacing publisher provenance or stronger nutrition.

iOS uses MapKit for live nearby food-market discovery and merges Kroger catalog locations when
available. Barcode scans, inventory maintenance, grocery suggestions, substitutions, recipe
backfill, and serving calculations share a bounded USDA/FatSecret/publisher reconciliation cache.
Apple Foundation Models may normalize grocery lookup terms on eligible devices, but never changes
a user-visible name without review and always falls back deterministically when unavailable.
Inventory Scan follows the same rule: after a Worker or Foundation Models failure, its local
deterministic audit may propose safe storage-zone and shelf-life corrections but never invents
nutrition or silently renames an item.

Every existing inventory item is revisited in rotating bounded batches, and every future manual,
receipt, barcode, grocery-transfer, sync, or confirmed AI inventory change immediately enters the
same enrichment pipeline. Barcode identity uses Worker/Open Food Facts product data; nutrition is
reconciled by confidence across publisher labels, USDA, FatSecret, and local knowledge. Provider
failure preserves partial results and advances the cursor so one item cannot stall the database.

AI is Apple-first for supported local work. Included cloud AI is only unlocked on Jessie's production/test devices with the local `Joo` gate; public installs use Apple Intelligence or a private UnifiedWorker. Private Workers may select Claude or OpenAI model IDs and keep provider keys in Worker secrets, never in the app.

Public users may alternatively buy consumable managed-AI credits through StoreKit. Credit purchases use localized App Store prices, an iCloud Keychain-synchronized account token, Apple server verification, duplicate-transaction protection, a visible remaining balance, and fixed per-action estimates. Failed requests do not consume credits and credits do not expire. Keep the App Store product IDs and Worker allowlist synchronized.

The AI-credit storefront is currently archived with `AICreditStorefront.isEnabled = false`. Keep its StoreKit and Worker implementation intact, do not create product requests while disabled, and automatically move a previously selected credit backend back to Apple-first automatic mode. Re-enable only after App Store products and server-verification secrets are ready.
