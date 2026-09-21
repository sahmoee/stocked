# In-app recipe browser: 20 improvements

Owner: Stocked iOS. Scope: the shared browser, URL/share import pipeline, publisher
parser, and existing recipe review form. All existing browser entry points inherit
the changes; no new database, publisher service, backend contract or deployment.

| # | Implemented improvement | Primary implementation |
|---|---|---|
| 1 | Shared bounded URL validation for browsing, pasting and imports; preserve recipe-identifying query parameters while removing known trackers. | RecipeBrowserPolicy / RecipeImportCoordinator |
| 2 | Explicit system Paste controls in the browser and URL importer; no automatic clipboard read on opening the import sheet. | RecipeBrowserView / RecipeCreateOptions |
| 3 | Current page title and publisher hostname above the page; editing the address no longer changes the reload/import target. | RecipeBrowserController / addressBar |
| 4 | Real WebKit loading progress with an accessible percentage and distinct Stop/Reload controls. | RecipeBrowserController / controls |
| 5 | Live back/forward availability and a bounded recent-page menu using WebKit's existing history. | RecipeBrowserController / pageMenu |
| 6 | Stocked light/dark browser surfaces, rounded address field, and useful themed empty/error views instead of a blank white canvas. Publisher page styling is not rewritten. | RecipeBrowserWebContent / pageStateCard |
| 7 | Actionable HTTP, timeout, offline, certificate and file-type failures, with retry; error documents and downloads cannot become importable recipes. | RecipePageResponsePolicy |
| 8 | Native Find on Page for long publisher pages. | RecipeBrowserController / pageMenu |
| 9 | Jump to Recipe for existing publisher recipe-card anchors, with a clear fallback when none exists and no animated scrolling. | RecipePageMarkup.jumpScript |
| 10 | Session-scoped page zoom from 80–160%, plus reset, without reloading the page. | RecipeBrowserController / pageMenu |
| 11 | External-browser fallback and sharing from the current URL, including when an in-app page cannot load. | RecipeBrowserView / pageMenu |
| 12 | A cancellable 30-second loading deadline, background media pause, and explicit observer/task/delegate teardown. | RecipeBrowserController lifecycle |
| 13 | Per-redirect validation before network navigation, user-activated new-window links kept in one view, scripted popups blocked, and website camera/microphone requests denied. | RecipePageRedirectGuard / WebKit delegates |
| 14 | Anchor/history URL changes tracked; snapshot and completion checks prevent a different or abandoned page from opening an import draft. | RecipeBrowserController / sameDocument |
| 15 | Import structured metadata from the displayed page first, including metadata inserted by the publisher's JavaScript. No re-download is needed when that snapshot succeeds; this path can work offline. | renderedPage / parsePage |
| 16 | A single bounded network response supplies both structured and visible-text import parsing. Browser, direct URL and incoming share imports reuse the same pipeline and do not save on extraction. | RecipeImportCoordinator / SharedRecipeImporter |
| 17 | Immediate, generation-guarded import cancellation; old progress/completions cannot interfere with a new request. Closing during a browser import asks for confirmation. | RecipeBrowserImportState / import views |
| 18 | Exact-source duplicate choices: open the existing saved recipe, explicitly review another copy, or keep browsing. Similar titles remain warnings, not automatic substitutions. | RecipeImportQuality / browser confirmation |
| 19 | A visible import-quality/source-yield review panel; after saving from the browser, open the normal recipe detail with existing Inventory/Grocery/Cook actions. | CreateRecipeView / browser onSaved |
| 20 | More faithful bounded extraction: relative publisher images, HTML/numeric entities, short instructions, string-array/single-object instructions, explicit serving counts, and guarded structured-data traversal. | RecipePageMarkup / JSONLDRecipeParser |

## Validation

Executed successfully on 2026-09-03:

- 129 native browser/discovery/SQLite checks, including unsafe redirects, cancellation
  generations, response types/status/size, query identity, serving-count ambiguity,
  and persistent keyset reading of 8,105 database recipes.
- 126 existing Find a Recipe native regression checks.
- 15 JavaScript checks executing the production metadata-snapshot and Jump to Recipe
  scripts against fixture DOMs, including the 16-block/32-node/size bounds.
- Two live publisher checks: Budget Bytes search and its real Chicken Broccoli
  Casserole recipe page. These verify reachability/metadata, not WebKit UI rendering.
- Generic iOS-device `Stocked` build-for-testing: app, extensions and test bundle.
  Added nine integration tests in RecipeWebDiscoveryTests; compiled, not executed on iOS.
  Final log: `/tmp/stocked-browser-20-delivery-build.log` (`TEST BUILD SUCCEEDED`).
- `git diff --check`.

Total executed checks: 270 local/native/script checks plus two live publisher checks.
The native archive/network harness used approximately 25.3 MiB maximum RSS during
its 2.40-second live run. This is a synthetic Mac harness measurement, not a claim
about iPhone browser memory or a before/after app-speed benchmark.

No simulator build/test, phone installation, deployment or publishing was performed.
The user prohibits simulator builds/tests without approval. Generic-device compilation
does not verify WebKit rendering, VoiceOver, modal transitions or phone memory. On-device
checks remain: small/landscape/iPad windows, largest text sizes, keyboard dismissal,
history/redirect navigation, Find/Jump/zoom, process termination, source websites with
heavy media, offline metadata import, duplicate choices, review-save-detail-back, and
camera/microphone denial. App-only integration tests still require a device/test runner.

Changed production files: RecipeBrowserView, RecipeBrowserPolicy, RecipePageMarkup,
RecipeCreateOptions, SharedRecipeImporter, WebRecipeDatabase and CreateRecipeView.
The Xcode string catalogue was updated during compilation. Prior Finder/database
changes and the unrelated project configuration edit were preserved.

Native regression commands (from the Stocked repository):

```sh
xcrun swiftc Stocked/RecipeFinderCore.swift Stocked/RecipeDiscoveryCore.swift \
  Stocked/RecipeBrowserPolicy.swift Stocked/RecipePageMarkup.swift \
  Stocked/GrowthDatabase.swift scripts/RecipeWebCoreChecks.swift \
  -o /tmp/stocked-browser-core-checks
browser_check_dir=$(mktemp -d /tmp/stocked-browser-checks.XXXXXX)
/tmp/stocked-browser-core-checks "$browser_check_dir"
node scripts/RecipeBrowserScriptChecks.mjs
```

## Compatibility and remaining boundaries

Producers: browser, direct URL import, share handoff and recipe previews. Consumers:
the existing AddRecipeForm/CreateRecipeView, GuestDataStore, RecipeDatabase, normal
recipe detail and source-attributed publication. No schema changes or destructive
repair. The existing parser/network fallback supports older pages and records.

Rendered-page extraction is limited to public page recipe metadata; it does not
copy cookies, hidden form values or storage, bypass paywalls, or rewrite recipes
with AI. If a page has no usable metadata, the bounded network/text fallback or
View Original remains available. A source that blocks imports may still not import.
The URL policy is not a DNS-rebinding firewall. Browsing state stays transient;
publisher HTML, page media, and network conditions still affect device performance.

Unsupported/ambiguous yield descriptions remain visible for review rather than
being guessed as servings. The saved model still has separate prep/cook fields;
source-only total time remains credited in notes (existing model limitation).
The full recipe-database backup and web-first Finder remain unchanged.
