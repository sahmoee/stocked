# Read me first

Also apply the ten additive README-first safeguards in `PROJECT_GUIDE_ADDITIONS.md`; they extend this project-specific contract without removing existing functionality.

Stocked is a local-first iOS/iPadOS 26 kitchen app with widgets and a share extension. Local inventory and user work are authoritative. Recipes entering or leaving the app require usable images, durable provenance, categories, and backward-compatible repair.

`Secrets.xcconfig` is local and ignored. Production services use `https://api.sowensstudios.com`; never ship provider keys. Start in the feature named by the task, include extensions when affected, and run the narrowest tests plus the `Stocked` build.

Recipe views prefer publisher-original image URLs, retain exact downloaded bytes in cache, and fall back to embedded data only when offline or the source fails. Keep the thin charcoal image border consistent.

Retail enrichment uses authenticated UnifiedWorker `/retail/*` routes. Kroger and RapidAPI credentials remain server-side. Keep official provider location/product IDs optional, preserve original product images and exact aisle data, and treat price, availability, and inventory as short-lived store-specific metadata rather than household truth.
