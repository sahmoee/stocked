# Cook Now discovery regression — September 24, 2026

## Ownership and compatibility

Stocked iOS owns this change. Preparation discovery consumes the existing FinderService paged
readers and CookNowCompute classification. Saved recipes, downloaded catalogue and bundled corpus
remain authoritative; there is no new backend, schema, migration, automatic collection import or
inventory mutation. Existing FinderService callers retain their default behavior. Rollback is a
code revert; stored household data is unchanged.

## Findings and changes

- Build a Full Meal excluded every inferred entrée. The old fallback always assigned a role,
  so the filter's `unspecified` escape could never retain legacy wings recipes.
- Preparation discovery only saw the current Cook catalogue, while recipe search could find
  additional downloaded records. It now uses the same paged FinderService readers with an early
  intent predicate and a bounded 80-candidate window, then classifies that window off-main.
- Multiword anchors use normalized whole-word membership, including case, hyphens, common
  plurals and aliases through the shared FoodNameMatcher. This is discovery matching, not a relaxation of inventory availability.
- Add Something no longer requires accompaniments to contain the main ingredient. Sauce scope
  selects components; side scopes select sides, with fresh/filling/use-soon preferences ranked.
- Inferred roles respect explicit metadata and no longer classify a chicken main as sauce merely
  because its title mentions sauce. Full meals lead the meal intent, with mains and vegetable/starch preparations as foundations.
- Mood's downloaded lookup checks both writable and bundled sources. All four fallback sources
  validate complete instructions/ingredients and household restrictions. A 15/30-minute limit
  requires known prep plus cook time. Missing durations are shown as unknown, never invented.
  If no qualifying recipe exists, the flow reports failure instead of selecting an unrelated one.
- Single-recipe classification now applies the same household dislikes as the batch classifier.

## Cook Now route audit and verification matrix

| Area | Source coverage / evidence | Device acceptance |
| --- | --- | --- |
| Start With Something → all seven intents | 46 native policy checks, including wings and all seven addition scopes | Pending |
| Build Around Food / Expiring Soon / Leftovers | Traced shared StarIngredientRecipesView database/corpus lookup and ranking; generic compilation | Pending |
| Match My Mood | Time-boundary/unknown-time fixtures; reviewed all four source fallback branches; generic compilation | Pending |
| Ready / Almost / More / Makeable Now | Shared CookNowCompute pooling and cancellation checks; source tier/filter review | Pending |
| Use Something Up | Traced expiring anchor into corrected intent discovery | Pending |
| Surprise Me | Existing independent generation route identified; no paid generation or household writes performed | Pending |
| Cooking methods / Finish & Serve / timers | Existing 89 native cooking reliability checks; source navigation review | Pending |
| Recipe search shared consumer | 144 native Finder core checks and 3 refresh-contract checks passed | Pending |

No available iOS simulator devices/runtimes were listed. iPhone Mirroring timed out after restart.
Native fixtures and compilation do not constitute a screen-by-screen device pass or establish
measured latency. No QA ticket was marked verified.

Release Xcode 27.0 (27A266a) generic iOS build 333 passed. Strict deep code-signature verification passed. The app, widget, share extension and Watch app all carry build 333. Installation on the paired iPhone 17 Pro Max succeeded. Command-line launch was denied because the phone was locked; Mirroring screen acceptance remains outstanding. An initial compiler error (wrong FinderService type name) was fixed before these successful builds.
