# Smart cookbooks

Open **Recipes → My Collection → Smart cookbooks**, or **Collections → Smart cookbooks**. Create a named set of rules, then open it to see matching recipes. Adding, editing, favoriting or deleting a saved recipe updates the matches. Deleting the cookbook removes its rules; every recipe stays saved.

Rules can match words in a title, description or ingredients; saved cuisine and category labels; all required tags; excluded tags; favorites; recorded prep and cook time limits; and name, recently saved or shortest cook-time ordering. Filled rules combine with AND. Tags and categories match exact labels, ignoring case, accents and extra whitespace. Cuisine also accepts its existing taxonomy parent. Empty criteria allow any value.

Missing or unclear times are excluded only when the corresponding limit is on. Results explain how many otherwise matching recipes were excluded for missing time. A cook-time limit is not a total-time estimate. A tag is not proof of dietary or allergy suitability; users must check ingredients.

Only recipes already saved in the current library are searched. This does not load or download the public catalogue. Rules are small household records that follow recipe sharing and recipe-edit permissions. Different devices can briefly show different results until their saved recipes finish syncing. Rules and their deletions use the existing household merge and tombstone owner, and optional cookbook data travels in Stocked backups. Restoring a backup that predates cookbooks preserves existing rules.

## Implementation and limits

- `SmartCookbookCore.swift`: independent deterministic matching, rule validation and bounded result ordering. Original implementation, no paid service, external parser or AI.
- `SmartCookbookStore.swift`: `FeatureStore` persists rules only; the shared `GuestDataStore` remains the sole saved-recipe owner. Mutations require recipe-edit permission, detect an editor's stale baseline and use `FeatureSync` stamps.
- `SmartCookbookViews.swift`: create/edit/delete and actual recipe-detail navigation. Query work runs off the main actor, cancels when replaced, and returns compact visible rows. It never stores a second recipe library.
- Local additions are limited to 50 concise rules and 32 KiB encoded rules. Preflight includes mutation stamps. Concurrent offline household additions can temporarily exceed those limits; existing rules are preserved and reduction-only edits/deletes remain available until the collection is back under them.
- Results initially show 60 rows, increasing to a maximum of 240. Counts cover every matching saved recipe; larger groups ask the user to narrow the rules.
- No timer, background polling, automatic recipe rewrite, hosted AI call, subscription or new dependency.

## Verification

Native checks, without a simulator:

```sh
xcrun swiftc Stocked/SmartCookbookCore.swift scripts/SmartCookbookChecks.swift -o /tmp/stocked-smart-cookbooks
/tmp/stocked-smart-cookbooks
```

The 27 checks cover matching logic, unknown times and exact boundaries, stable ordering, bounded windows with full counts, invalid/contradictory rules, count/UTF-8 byte limits, reducing merged oversized collections, sync-field round trips and cancellation. In-app **QA section 51** records the separate device, accessibility, backup and household journeys. Native checks and a successful build do not mark these device checks passed.
