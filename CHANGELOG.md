09:05:26 — Reference action artwork, 40-point polish, and sync reliability
Restored the calendar/tomato jar, wire milk basket and wooden grocery crate from the visual direction;
corresponding Home widgets share the same images. Added matching protein/leftover illustrations,
unified decorative Cook/Recipes artwork, and removed random Grocery planning artwork selection.
Inventory pages/sheets gain ten UI and ten interaction improvements, including draft protection,
atomic permission-aware editing, exact undo, clear search recovery and truthful grocery handoff.
Ten client/Worker fixes harden bounded input, retries, context paging and persistence-before-acknowledgement.
See STOCKED_POLISH_40_2026_09_05.md. Production rollout and physical-device visual QA are separate.

09:05:26 — Consistent kitchen artwork and QA blocking-path repairs
Home and Inventory now share watercolor cutouts and a bounded asynchronous artwork renderer.
The fridge is centered and larger, without distorted atlas scaling. Inventory reservation matching
no longer blocks navigation; QA capture avoids synchronous hierarchy/GPU snapshots. Four current
tickets have scoped code resolutions; runtime/device verification remains pending.

09:04:26 — Inventory destination design follow-through
Extended the reference's editorial style to full inventory, shared item/search rows, Expiring Soon,
Running Low, Leftovers, and add/edit/browse presentations. Storage filters now expose All explicitly;
adding from All defaults to Fridge. Low-stock reports react to inventory changes. Existing scanners,
quantity edits, planning actions and grocery transfers remain on their established paths.

09:04:26 — Reference-driven Inventory landing
Rebuilt the Inventory landing around the supplied visual reference with kitchen still-life artwork,
an illustrated appliance/category panel, live counts, three working quick actions and a Coming Soon
AI banner. View All now opens all storage zones; category buttons open their explicit destinations.
Shared app chrome and adaptive dark-mode text remain in place.

09:04:26 — Adaptive app theme and QA performance repair
Recipe cards, older secondary-screen cards and form fields, loading placeholders, and functional
accents now use the shared semantic surface/selection palette in both light and dark mode.
Recipes now uses the same semantic card surface as every Stocked area,
and its three destination cards share one standard height while remaining content-driven at
accessibility sizes. Recipe Results becomes usable after its first real matches instead of appearing
to refresh throughout optional source enrichment, with paced preview publication to avoid repeated
image-grid layout. The Recipes root no longer performs hidden retired-Discover work, and Home reuses
one off-main ready-to-cook snapshot rather than rescanning recipes during SwiftUI layout. Seven current
QA tickets receive shipped resolutions; physical-device verification remains tester-controlled.

09:04:26 — Inventory hero spacing and accessibility QA precision
The Inventory refrigerator now fills the right side of its phone hero instead of leaving an empty
fixed-height gap, with a vertical accessibility-text fallback. Fridge, Pantry, Freezer and Produce
now use matching transparent watercolor category illustrations instead of generic symbols. The automated accessibility sweep now
audits only exposed VoiceOver elements, eliminating repeat reports for window, scroll-host,
passthrough and floating-bar implementation containers. STK-128-0170 receives the shipped fix while
physical-device verification remains tester-controlled.

08:16:26 — v4.13 — Adaptive themed presentation surfaces
Centralized sheets now fill their complete host with the active Stocked theme instead of revealing system white. Sheet content responds to live window width, iPad multitasking, safe areas, and the full accessibility text range without a fixed phone-sized layout or unnecessary forced scrolling. STK-110-0014 receives the precise shipped resolution while verification remains tester-controlled.

08:16:26 — v4.13 (build 92) — Continuous recipe image enforcement
All recipe-database ingestion now requires a usable HTTPS image, including bulk imports. Every persisted database load and shared-recipe migration continuously removes older imported image-less records while preserving personal recipes.

08:16:26 — v4.13 (build 92) — Settings appearance QA resolution batch
Added precise shipped resolutions for the Settings and Cook Button appearance reports. The app now transitions all three related tickets to Fixed while preserving tester-controlled verification.

08:15:26 — v4.13 (build 92) — Expanded widget collection
Reworked the widget extension into five focused choices: Kitchen Status, Use Soon, Grocery List, Today's Meal, and Recipe Library. Added a large kitchen dashboard, more Home and Lock Screen sizes, richer item and meal context, stale-data recovery, realistic previews, reliable deep links, and step progress plus accessibility improvements for the cooking Live Activity.

08:13:26 — v4.13 (build 91) — Working ingredient substitution shortcuts
Tapping Sub beside a recipe ingredient now expands Substitutions, scrolls it into view, and highlights the matching ingredient instead of changing hidden state below the viewport.

08:13:26 — v4.13 (build 90) — Cleaner Settings and collapsible recipes
Removed inactive appearance and Home layout choices, kept dark-mode text adaptive, retained one complete QA destination, and made long Ingredients and Instructions cards independently collapsible from recipe detail.

08:13:26 — v4.13 (build 89) — Uniform recipe collection imagery
Cook Now, Based on Inventory, and Drinks now use one cohesive recipe thumbnail in compact collections instead of mixing loaded photos, emoji, and empty Meal Photo placeholders. Full recipe details and heroes retain real photography.

08:13:26 — v4.13 (build 88) — Batched root-tab freeze repair
Six QA reports with the same repeated-selected-tab evidence now receive precise shipped resolutions. Home, Cook, and Recipes tap storms coalesce to one pop-to-root rebuild, with expanded regression coverage for all three recorded surfaces.

08:13:26 — v4.13 (build 87) — Home tab freeze protection
Repeated taps on the selected Home tab now coalesce into one pop-to-root transition instead of rebuilding the complete Home navigation and widget tree several times on the main thread. Added regression coverage for the reselection gate.

08:13:26 — v4.13 (build 86) — AI action on Meals Ready Now
The Meals Ready Now results screen now has a prominent inventory-based AI recipe button with progress and result feedback. Its actual recipe rows now use the same consistent icon treatment instead of mixed photos and emoji.

08:13:26 — v4.13 (build 85) — Consistent Ready Now recipe icons
Ready to Cook rows now use one cohesive recipe symbol instead of mixing food photos with ingredient emoji fallbacks.

08:13:26 — v4.13 (build 84) — Correct Ready Now threshold
Meals Ready Now now means every safe recipe with five or fewer unresolved ingredients after substitutions. Meals Almost Ready now means six or more, and the dashboard and result lists use that same split.

08:13:26 — v4.13 (build 83) — Five-item Cook Now range and substitutions
Meals Ready Now and Cook Now now classify saved, generated, newly synced and Discover recipes through one catalog. In-stock substitutes are applied before missing counts, and recipes missing five or fewer items remain actionable Cook Now options.

08:13:26 — v4.13 (build 82) — Complete recipe sync and Meals Ready Now AI
Stocked now receives the full Mac recipe catalog beyond the old 500-recipe ceiling. Meals Ready Now can create and save an inventory-aware recipe on demand and automatically makes one generation pass after inventory additions settle.

08:13:26 — v4.13 (build 81) — Stocked Mac recipe sharing
Approved Stocked Mac imports now enter the shared recipe database for every Stocked installation and create one deduplicated household activity row identifying Stocked Mac as the importer.

08:12:26 — v4.13 — Complete project documentation
Expanded GitHub documentation to cover the full Stocked product, architecture, inventory, shopping, recipe importing, meal planning, cooking, household and cloud behavior, configuration, testing, backend contracts, release procedure, troubleshooting, privacy, and support resources.

08:12:26 06:52 — v4.13 (build 80) — QA backlog repair
Fixed empty recipe categories, unwanted My Recipes tabs, sparse source browsing, HEB naming, broth categorization, Cook card proportions, incomplete recommendations, mixed image fallbacks, launch-time QA stalls, and accessibility false positives. Added in-app source webpages and restored automatic report intake.

08:04:26 20:06 — v4.13 (build 78) — Build
Big change
08:12:26 — v4.13 (build 80) — Unified QA lifecycle and documentation
Added required fix resolutions, tester verification and history-preserving refiles; shipped resolution mappings for the current QA backlog; reduced Cook classification work; restored cached cuisine counts/results; improved light-mode inventory contrast; and documented setup, architecture, security, contribution, and QA workflows.
08:15:26 — Shared recipe provenance and categories
Stocked iOS now preserves source publisher, source URL, and mined categories sent by the Mac recipe manager. Harvest imports use their original publisher instead of StockedMac attribution, and category labels populate the shared recipe database.
08:15:26 — Required recipe images and repeatable backfill
Mac-harvest and household recipes without an image are rejected at iOS intake and sync boundaries, recipe creation requires an image, and the database image backfill now retries older recipes on future launches instead of permanently marking one partial batch complete.
# 08:16:26 — Full-quality recipe images

- Recipe photos now prefer the publisher's original image over compact embedded sync data, including recipes already in the library.
- Added a thin charcoal border to loaded recipe and food images for clearer separation from cards and backgrounds.
