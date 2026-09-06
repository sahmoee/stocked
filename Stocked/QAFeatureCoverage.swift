import Foundation

/// Stable appended IDs. These are DEVICE checks, not passes inferred from a build
/// or from the small deterministic contracts below. Never renumber existing rows.
nonisolated enum QAFeatureCoverage {
  static let version = "2026-09-05 · free connections and delivery"
  struct Section: Sendable {
    var number: Int
    var title: String
    var rows: [(String, Bool)]
  }
  static let sections: [Section] = [
    .init(
      number: 37, title: "Find a Recipe · navigation and choices",
      rows: [
        (
          "Landing keeps Collection, Ready to Cook, Past Meals and Coming Soon AI; Find a Recipe replaces the old lower rails",
          true
        ),
        (
          "Header search and Find search open the same direct results flow without requiring quiz answers",
          true
        ),
        (
          "All seven quiz steps have Back, Clear, Skip, Next and correctly announced progress", true
        ),
        (
          "Multi-select uses OR within meal, ingredient, cuisine and mood; different categories use AND",
          true
        ),
        (
          "No preference, No restrictions and Surprise Me clear conflicting selections; time and kitchen are single-select",
          true
        ),
        (
          "Skip works with no answer; Back and temporary navigation preserve the session draft",
          true
        ),
        ("Review shows all seven categories; Edit returns to review after saving that step", true),
        (
          "Clear and Start over confirm before deleting choices; Keep choices changes nothing", true
        ),
        (
          "Search trims spaces, ignores case and matches partial titles, ingredients, cuisine, categories, descriptions and tags",
          false
        ),
        (
          "Selection state and changing result counts are announced with VoiceOver; large text does not clip",
          true
        ),
      ]),
    .init(
      number: 38, title: "Unified recipe results · correctness and loading",
      rows: [
        (
          "One search combines downloaded and website recipes; no Online/Database source picker or separate result sections",
          true
        ),
        (
          "Throttle or block publishers: matching cached cards appear before network discovery completes and remain tappable",
          true
        ),
        (
          "Typing rapidly cancels obsolete work; older results never replace the current query or filters",
          true
        ),
        (
          "Counts and cards deduplicate canonical source URLs, including duplicates outside the first visible page",
          true
        ),
        (
          "Different personal recipes with the same title remain distinct; no false duplicate-identity QA violation",
          true
        ),
        (
          "All nine sorts use real fields; missing ratings, times and history sort last where specified",
          true
        ),
        (
          "Filter chips remove immediately; all seven filter sections and count preview use the shared selector",
          true
        ),
        ("Sort changes only on Apply; closing the sheet discards the draft sort", false),
        (
          "Opening preview, saved detail or browser and returning preserves filters and chosen sort",
          true
        ),
        (
          "Empty, error, retry and offline states preserve choices; dietary restrictions never relax automatically",
          true
        ),
        (
          "Recipe images, source credit, real time/rating and at most useful contextual tags match each source record",
          false
        ),
        (
          "Load more retains prior cards, applies the global sort and can reach matches beyond the 8,000 index",
          true
        ),
      ]),
    .init(
      number: 39, title: "Dietary, history and inventory matching",
      rows: [
        (
          "Diet choices use AND and explicit supported metadata, never an inferred allergen-safety guarantee",
          true
        ),
        (
          "Saved profile allergens remain excluded during web search, fallback and softer-preference alternatives",
          true
        ),
        (
          "Total-time limits include exactly 15, 30, 45 and 60 minutes; over-one-hour means strictly above 60",
          true
        ),
        ("Quick uses total time; missing total time is never guessed from prep time alone", true),
        (
          "Use what I have requires sufficient quantities; zero, expired and unavailable inventory never counts",
          true
        ),
        (
          "Ingredient aliases, pluralization and unit conversions work; repeated lines cannot reuse the same stock twice",
          true
        ),
        ("Mostly uses at least 70 percent; missing and uncertain quantity counts are honest", true),
        (
          "Explicit optional flags are excluded consistently; explicit required flags are not overridden by text guesses",
          true
        ),
        (
          "No preference does not rank by inventory; I can shop does not exclude missing ingredients",
          false
        ),
        (
          "Something new and recent/most-cooked sorts use actual history; missing history does not produce invented claims",
          false
        ),
      ]),
    .init(
      number: 40, title: "Recipe browser · navigation and appearance",
      rows: [
        (
          "Source links from collection, catalogue, web results and sources open the same in-app browser",
          true
        ),
        (
          "Address entry and explicit Paste accept public HTTPS recipes; malformed, local, credential and unsupported URLs are rejected",
          true
        ),
        (
          "Back, Forward and recent-page history work; unrelated SwiftUI updates do not reload the original URL",
          true
        ),
        (
          "Loading progress, Stop, Retry, timeout, offline and content-process termination have actionable states",
          true
        ),
        (
          "Import is disabled during loading, after failure and after Stop; only the currently loaded document can import",
          true
        ),
        (
          "User-tapped new-window links stay in the browser; unsolicited popups and camera/microphone access are denied",
          true
        ),
        (
          "Find on page, Jump to recipe and bounded text zoom work with a useful unavailable message",
          false
        ),
        (
          "Share uses a clean link without stripping functional query parameters; external browser remains available",
          false
        ),
        (
          "Header/footer fit portrait, landscape, iPad and accessibility text with at least 44-point controls",
          true
        ),
        (
          "Browser chrome follows existing light/dark tokens; no forced recoloring of publisher content",
          false
        ),
        (
          "Backgrounding pauses media; dismissal releases observers, delegates, loading tasks and web content",
          true
        ),
      ]),
    .init(
      number: 41, title: "Recipe import · review and recovery",
      rows: [
        (
          "Preview offers View Original and Import; viewing never automatically saves or publishes a recipe",
          true
        ),
        (
          "Import uses bounded rendered Recipe metadata first, including offline when available",
          true
        ),
        (
          "If rendered metadata is unavailable, one bounded fetch feeds structured and visible-text parsers",
          true
        ),
        (
          "Nested JSON-LD, encoded text, relative images, repeated ingredients and short instruction steps import intact",
          true
        ),
        (
          "Non-recipes, oversized pages, unsafe redirects, HTTP errors and incomplete recipes fail without a truncated draft",
          true
        ),
        (
          "Cancel is immediate; close confirmation and late completion cannot reopen or save an abandoned draft",
          true
        ),
        (
          "Navigate during import: an old document never becomes the new page's imported recipe",
          true
        ),
        (
          "Same-source duplicates offer existing recipe or explicit copy review; same-title other publishers are not silently blocked",
          true
        ),
        (
          "Review preserves original source/name, ingredients, instructions, category and image; ambiguous yield asks for review",
          true
        ),
        (
          "Publisher total time is not misrepresented as prep/cook time; no silent AI rewrite occurs",
          true
        ),
        (
          "Saving a reviewed import opens normal detail and appears in My Collection, Inventory matching, Grocery and Cook",
          true
        ),
        (
          "Missing ingredients can be added to Grocery with correct quantities; cooking updates normal past-meal history",
          true
        ),
        (
          "Failed import leaves View Original available; text/screenshot import remains accessible",
          false
        ),
      ]),
    .init(
      number: 42, title: "Catalogue backup and cross-device recipe sharing",
      rows: [
        (
          "Recipe search works offline with downloaded data and states when the catalogue is incomplete",
          true
        ),
        (
          "Full catalogue paging passes 8,000 records without treating the index limit as a total database cap",
          true
        ),
        (
          "Interrupted download resumes from the committed cursor; malformed/repeated cursors fail safely without losing saved recipes",
          true
        ),
        (
          "Pause and retry download work without hiding existing matches or changing filters", false
        ),
        (
          "A completed sync refreshes result counts without duplicate cards or repeated query loops",
          true
        ),
        (
          "Source-attributed iOS and Mac imports reach the same shared catalogue; manual/personal recipes retain their privacy",
          true
        ),
        (
          "Mac total reflects all shared database recipes regardless of household; original publisher rights and attribution remain",
          true
        ),
        (
          "Jamaican and other sparse-category searches remain specific; proposed broader matches require explicit consent",
          true
        ),
      ]),
    .init(
      number: 43, title: "Regression · reported phone issues",
      rows: [
        (
          "iPhone 17 Pro and Pro Max: repeatedly open/cancel/close the Menu drawer; no partial stuck position or freeze",
          true
        ),
        (
          "Open drawer while recipes sync and while filing a QA ticket; sheet dismissal remains responsive",
          true
        ),
        (
          "Cook tab cold launch, repeated tab switching and active cooking avoid main-thread stalls/watchdog kills",
          true
        ),
        (
          "Grocery labels, quantity controls and category text have readable contrast and scale in both themes",
          true
        ),
        (
          "Home illustration next to Stock Level has the shared larger geometry on both phone sizes",
          false
        ),
        (
          "Home/Cook greeting uses the preferences name and equal type size; selected tabs retain gold/tan icon and black fill",
          false
        ),
        (
          "Create with Stocked AI is visibly Coming Soon and cannot launch from either hub or Add Recipe options",
          true
        ),
        (
          "Ten minutes of browser/search/import/drawer use does not retain growing web views or cause memory-pressure crashes",
          true
        ),
      ]),
    .init(
      number: 44, title: "QA recording and release evidence",
      rows: [
        (
          "Changed check definitions require retesting; previous notes and linked ticket numbers survive upgrades",
          true
        ),
        (
          "New and untested blocker checks count as open; compilation never marks device checks passed",
          true
        ),
        (
          "Export includes every check and its actual verdict so companion QA sees all newly added coverage",
          true
        ),
        (
          "Finder step/review/results, filters/sort, preview, browser and import outcomes identify themselves in tickets",
          false
        ),
        (
          "Same-count inventory/recipe edits trigger new invariants; cancelled or changing snapshots do not publish a clean run",
          true
        ),
        ("Burst edits coalesce QA work; disabling/backgrounding cancels queued runs", false),
        (
          "Cross-device ticket sync includes iPhone and iPad reports; fixed is distinct from tester-verified",
          true
        ),
        (
          "QA breadcrumbs contain no recipe HTML, credentials, clipboard contents or full browsing URLs",
          true
        ),
      ]),
    .init(number: 45, title: "QA identity, completion and autonomy", rows: [
      ("Set Key on both of Key's devices and Shalise on both of hers; choices persist locally without changing household Preferences", true),
      ("iPhone 17, 17 Pro, 17 Pro Max and iPad reports show exact hardware model, device family and distinct installation IDs", true),
      ("Changing tester after capture never changes the ticket's captured hardware; old tickets remain unassigned until explicitly attributed", true),
      ("Offline reports with the same build and sequence from two devices retain distinct numbers after sync", true),
      ("Filter tickets by tester and device family; completed tickets are hidden by default but remain searchable in history", false),
      ("Fixed tickets complete linked failures without claiming a device pass; manual-review tickets remain active", true),
      ("A fresh recurrence reopens the same automatic finding on the originating device, preserves its resolution, and restores the linked failed check", true),
      ("Editing a resolved checklist note does not prevent a later regression from returning to active work", true),
      ("Launch with QA off, then enable it: the runner starts without relaunch; fresh diagnostics run periodically and pause during cooking/background/QA lock", true),
      ("Automatic accessibility sweeps respect the frame budget; partial scans never claim a pass and findings require two complete observations", false),
      ("Explicitly disabling Auto-publish stays disabled after restart; enabling it retries reports after connectivity returns", true),
      ("Build twice and archive: app and extensions receive increasing matching build numbers while the manually set version remains unchanged", true),
    ]),
    .init(number: 46, title: "Unified kitchen intelligence and shared cooking", rows: [
      ("Recipe search combines the attributed web, downloaded public catalogue, saved collection and bundled database without duplicate result systems", true),
      ("Web import keeps publisher rights and attribution, supports review, inventory comparison, Grocery handoff and original-site fallback", true),
      ("Meal plans reserve inventory, calculate missing items, sync across the household and transition into Cook without duplicating deductions", true),
      ("Ready-to-cook and missing counts use normalized names, quantities, expiry and confidence rather than title substring guesses", true),
      ("Grocery additions merge equivalent products and quantities, retain store/aisle context and do not duplicate stocked items", true),
      ("Offline household edits replay exactly once after reconnect and retain conflict/receipt evidence", true),
      ("Recipe ranking responds to saved, opened, cooked and dismissed history without weakening dietary restrictions", false),
      ("A cook started by one household member appears on the other device with current progress and claimable helper tasks", true),
      ("Claiming or releasing a cooking task syncs to the other device; completion and cancellation remove the active session", true),
      ("Shared cooking never uploads recipe instructions, ingredient quantities, notes or timers", true),
      ("App Health reports Worker latency, sync health, pending changes, recipe catalogue status, storage and memory footprint", true),
      ("Autonomous QA monitors regressions without reopening completed tickets from cached historical failures", true),
    ]),
    .init(number: 47, title: "Theme surfaces · pages, sheets and cards", rows: [
      ("Switch between light and dark mode on every hub; no page exposes an unthemed white, gray or black host canvas", true),
      ("Open Recipe Finder quiz, results, Filters, Sort, Preview, browser and import review in both themes", true),
      ("Short sheets, popovers and full-screen covers fill through every safe area with the active Stocked canvas", true),
      ("Cards and text fields use semantic theme surfaces; selected controls remain readable without relying on color alone", true),
      ("Camera and media overlays retain intentional black contrast while their controls remain accessible in both appearances", false),
      ("Changing theme while a page or sheet is open updates canvas, cards, text, controls and status bars without reopening", true),
      ("iPad Split View, landscape and accessibility text expose no unfilled edges or clipped card content", true),
      ("StockedMac windows, sidebar, detached recipe, Settings, menu panel, sheets, popovers and cards share the warm adaptive palette", true),
    ]),
    .init(number: 48, title: "Inventory reference design and native workflows", rows: [
      ("Compare Home, Inventory and every inventory sheet with the approved artwork reference in light and dark mode; illustrations retain aspect ratio and presentation margins use the matching canvas", true),
      ("Use iPhone and iPad narrow windows with the largest Dynamic Type: scanner actions, zone controls, quantity inputs, report statuses and leftover actions wrap without clipping or losing scroll access", true),
      ("Search within one inventory zone, recover from no matches, search all zones explicitly, then close search; closing must not leave an invisible active filter", true),
      ("Search the ingredient catalogue with no matches, clear filters and add a result; actual counts and named add controls remain usable with VoiceOver", false),
      ("Choose Freezer manually while adding an item, then continue typing and choose a name suggestion; the explicit storage selection must remain Freezer", true),
      ("Open and save an item with zero quantity or zero fill; editing must not silently restock it or display an invalid slider value", true),
      ("Save edits and undo removal with household permissions changed; a concurrently removed item must not be silently recreated and photo removal must not also open its picker", true),
      ("Partially fill Add Item and Add Leftovers, attempt to close, keep editing, then discard explicitly; meaningful drafts must not disappear through a swipe", true),
      ("Save leftovers cooked on a past date; the displayed reminder and saved expiry use that cooked date, and whitespace-only titles cannot be saved", true),
      ("Open Inventory Details with over ten matching items and over four claims; counts, Show All, every claim, and tap-to-edit remain available", true),
      ("Open Running Low with duplicate names and items already in Grocery; add only the missing unique products, preserve existing quantities, then open the grocery list from the completed action", true),
    ]),
    .init(number: 49, title: "Free recipe portability and planning", rows: [
      ("Import Cooklang and Recipe JSON files; inspect all warnings before saving, cancel without side effects, and recover from malformed or oversized files", true),
      ("Reimport the same recipe, review duplicate choices, export original Cooklang metadata, and confirm source credits survive household sync", true),
      ("Repeat a day from either planner, keep existing meals, skip duplicates, reset cooked state, and undo without removing a later household edit", true),
      ("Export a calendar across daylight-saving changes; inspect dates, Unicode titles and meal slots, and confirm private ingredient/member data is absent", true),
      ("Change member permissions before repeating or exporting a plan; revoked access prevents the action", true),
      ("Look up an unknown barcode and a known barcode; show dated community prices, currency, location and credits without changing personal receipt history", true),
      ("Cancel a price lookup or navigate away during a request; delayed responses cannot replace later results and offline failures preserve saved prices", true),
      ("Try almond flour, cooked rice and an unknown ingredient in conversions; no guessed weight appears, while compatible volume conversions remain usable", true),
      ("Check incomplete nutrition estimates: missing ingredients stay unknown and totals are labelled as a subtotal", true),
      ("Use imports, plan tools, community prices and Sources & Credits on iPhone and iPad with VoiceOver, largest text, narrow windows and both themes", true),
    ]),
    .init(number: 50, title: "Recipe collection migration", rows: [
      ("Choose supported Mealie, Tandoor, Paprika and Recipya exports; review actual ingredients, steps, creator credits, source notes and local pictures before adding", true),
      ("Choose several files containing the same recipe and recipes already saved; duplicate rows start unselected and saving never overwrites existing records", true),
      ("Open a recipe with missing or ambiguous servings; it cannot be selected until reviewed in the existing editor, and Use changes does not save prematurely", true),
      ("Add the same recipe or revoke recipe-edit permission on another household device during import; the next commit skips the duplicate or stops safely", true),
      ("Cancel during parsing and during serial saving, reopen the same export, and confirm completed additions remain while unfinished rows can resume without duplicates", true),
      ("Undo an import after one recipe is edited or cooked elsewhere; remove only unchanged additions and preserve later edits, deleted items and unrelated recipes", true),
      ("Import without public sharing: top-level sourceURL remains empty, private original attribution survives sync, no paid AI or automatic catalogue publication occurs", true),
      ("Import an oversized archive, excessive recipes, malformed ZIP/gzip, unsafe archive path and invalid picture; fail or show bounded warnings without writes outside the chosen import", true),
      ("Export source text after a compressed import and after normalized-only data; clearly distinguish extracted text from an original archive and avoid invented original downloads", true),
      ("Open legacy Paprika import through Kitchen Transfer; it directs to reviewed collection import without replacing recipes; Stocked backup restore remains available", true),
      ("Review large imports on iPhone and iPad with VoiceOver, both themes, largest text and narrow windows; photo sync size limits are disclosed and Stop stays reachable", true),
    ]),
    .init(number: 51, title: "Smart cookbooks", rows: [
      ("Open Smart cookbooks from My Collection and Collections; create, edit, reopen and delete a rule without copying or deleting any saved recipes", true),
      ("Combine text, cuisine, category, required tags and favorites; every filled rule must match, while excluded tags reject only exact saved labels", true),
      ("Set prep and cook limits, including zero and exact boundary values; unclear or missing times are excluded with an honest count and never guessed", true),
      ("Change a saved recipe's labels, times or favorite state; the open cookbook refreshes and routes each match to that actual recipe's detail", true),
      ("Navigate away or change rules rapidly while matching a large saved library; cancelled work cannot replace newer results and browsing never loads the public catalogue", true),
      ("Browse more than 240 matches: counts remain complete, visible rows are bounded and ordered, and a clear refinement message explains the limit", true),
      ("Edit the same cookbook from two household devices; stale editor saves and deletes fail visibly instead of overwriting a later change", true),
      ("Sync rules between household devices, disable recipe sharing, and revoke recipe-edit permission; rules obey the setting and viewers cannot create, edit or delete them", true),
      ("Export and restore a Stocked backup containing cookbook rules, then restore an older backup without them; omitted data must not erase existing cookbooks", true),
      ("Try conflicting tags, an empty name, excessive rules and an oversized rule collection; show actionable validation without losing existing rules", true),
      ("Use Smart cookbooks on iPhone and iPad, both themes, large text and VoiceOver; controls remain reachable and dietary labels never claim verified allergy safety", true),
    ]),
    .init(number: 52, title: "Dated planning and repeat schedules", rows: [
      ("Open Plan ahead from both planners on iPhone and iPad; dates, templates, repeats and every editor remain usable with both themes, large text and VoiceOver", true),
      ("Capture the active week as a template, edit its days and ingredients, and choose a saved recipe without changing the recipe, cooking history or active plan", true),
      ("Preview finite repeat schedules across time zones, daylight-saving changes and month boundaries; dates and counts agree with the template before confirming", true),
      ("Add future dated meals and confirm pantry reservations, groceries, cooking candidates and widgets do not change until an explicit active-week handoff", true),
      ("Preview a repeat again after editing, skipping or activating its dates; existing occurrences remain unchanged and are not duplicated", true),
      ("Change or remove a source meal, template or rule during review, or edit the active plan on another device; stale confirmation stops visibly without overwriting newer work", true),
      ("Review today through six days ahead; past dates and seven days ahead are excluded, and crossing midnight or changing time zone requires a new preview when offsets change", true),
      ("Confirm an active-week handoff on two devices and retry after interruption; stable meal IDs prevent duplicates and cooking, building and cook-ahead states start clean", true),
      ("Skip and restore occurrences, pause and remove repeat rules, and delete dated references; existing dated meals and active-week copies change only as the confirmation describes", true),
      ("Undo after another member edits, cooks or deletes an added meal; remove only unchanged additions and preserve later work on either side of an active-week handoff", true),
      ("Sync dated meals, templates and rules with inventory sharing off; meal-plan sharing and role permissions govern them, while cookbook rules follow recipe sharing", true),
      ("Restore full and older backups, wipe feature data and rejoin a household; omitted legacy fields preserve newer data and temporary undo cannot resurrect erased records", true),
    ]),
    .init(number: 53, title: "Grocy connection", rows: [
      ("Open Free Kitchen Connections from Settings; configure a Grocy HTTPS endpoint and verify credentials stay in device Keychain and never appear in household payloads, backups or errors", true),
      ("Read actual stock and shopping entries into a preview; unknown quantities, units and mappings require review and are never converted into invented container amounts", true),
      ("Confirm selected new entries through inventory and grocery owners; existing local items remain and matching or previously imported entries are identified for manual reconciliation", true),
      ("Import the same source again after a partial completion, relaunch and interrupted request; completed additions are not duplicated or silently replaced", true),
      ("Edit local inventory or revoke household permission during preview; commit rechecks current state and safely keeps later work", true),
      ("Try invalid credentials, foreign-origin redirects, malformed and oversized responses, offline mode and cancellation; fail visibly without sending credentials elsewhere or changing saved items", true),
      ("Disconnect and erase connection data; retained kitchen items stay and a late network response cannot restore the removed connection", true),
      ("Review setup, source rows, warnings and confirmations on iPhone/iPad, both themes, large text and VoiceOver; controls remain reachable and no external Grocy write is implied", true),
    ]),
    .init(number: 54, title: "CalDAV meal calendar", rows: [
      ("Connect a compatible HTTPS calendar account, discover calendars and choose an explicit destination; authentication stays on this device", true),
      ("Review dated or active-week meal copies before publishing; correct dates, time zones and stable event IDs survive daylight-saving and month boundaries", true),
      ("Publish a new event then retry after interruption; conditional creation does not duplicate or overwrite an existing event", true),
      ("Edit a previously published event externally before updating it; a changed ETag or body stops the update and preserves the calendar edit", true),
      ("Encounter an unrelated event, weak or missing ETag, read-only calendar or unsupported server behavior; explain the limitation and retain the ordinary calendar-file export fallback", true),
      ("Reject external-entity XML, unsafe calendar hrefs, foreign-origin redirects and excessive responses without credential disclosure or writes outside the reviewed destination", true),
      ("Cancel midway, change selected calendar, disconnect or revoke meal/export permission while reviewing; keep completed actions visible and do not commit stale remaining work", true),
      ("Use calendar discovery and publication review in both themes, large text, VoiceOver and iPad multitasking; distinguish manual publication from background or bidirectional sync", true),
    ]),
    .init(number: 55, title: "Cooklang recipe discovery", rows: [
      ("Search the documented Cooklang federation service explicitly; show bounded results and source attribution without creating recipes or publishing data", true),
      ("Choose a result, read its exact Cooklang content and inspect a private import preview; original source, supplied author/license and uncertainty warnings survive saving", true),
      ("Add the same recipe on another household device while the editor is open; final commit catches the duplicate or stale permission without overwriting a saved recipe", true),
      ("Try an unavailable/custom endpoint, redirects, malformed metadata, invalid recipe URLs and oversized content; retain recoverable errors and never invent a usable result", true),
      ("Change search or endpoint rapidly and cancel during fetch; late results cannot replace the current query or open an old import", true),
      ("Inspect a recipe with no photo or missing serving information; retain existing private review and Mac image requirements without an AI or paid fallback", true),
      ("Confirm no feed registration, public recipe posting or source-rights claim happens while browsing or importing; supplied credits remain visible and exportable", true),
      ("Use discovery/results/private editor with both themes, largest text and VoiceOver; Mac recipe management and iOS use compatible source data", true),
    ]),
    .init(number: 56, title: "Household delivery and recovery", rows: [
      ("Inspect delivery status when not joined, joined, offline and missing Apple push configuration; unavailable capability is never shown as healthy delivery", true),
      ("Receive a foreground household invalidation and verify the ordinary permission-checked sync reloads actual data; duplicates never duplicate kitchen records", true),
      ("Background, reconnect, lose the socket and change household; connections stop or reconnect appropriately and polling remains a truthful fallback", true),
      ("Enable and disable device push from an explicit action; respect system permission, current preferences, signed environment/topic and registration failures", true),
      ("With properly configured Apple credentials on real devices, receive a silent update and verify completion/retry behavior; a provider acceptance is not marked as confirmed device delivery", true),
      ("Configure an opt-in webhook only with valid owner authority and an allowed HTTPS receiver; legacy missing authority requires the explicit upgrade path without automatic data reset", true),
      ("Review the exact webhook destination before enabling; no event leaves until opt-in and payloads contain only documented invalidation metadata", true),
      ("Verify receiver signatures, timestamps and stable event IDs; reject replay and test bounded retries, failed status, disabling and later recovery without duplicate side effects", true),
      ("Reject unauthorized configuration, foreign redirects and forbidden receiver hosts; server errors and app diagnostics contain no invite codes, tokens or signing secrets", true),
      ("Keep undelivered work durable across response loss/restart; acknowledge only persisted results and distinguish queued, failed, provider-accepted and unconfigured states", true),
      ("Export or inspect recovery guidance and retry failed updates without deleting household data, changing a namespace or requiring a paid account upgrade", true),
      ("Use delivery setup and recovery on iPhone/iPad in both themes with large text and VoiceOver; destructive share changes require their own concrete confirmation", true),
    ]),
    .init(number: 57, title: "Saved community price checks", rows: [
      ("Add, edit, pause and remove saved barcode targets; preferences persist on this device and do not modify receipts, retailer prices or shared household records", true),
      ("Compare only matching currency, unit basis, selected location, age and discount rules; unknown dates, future reports and unclear units are excluded visibly", true),
      ("Refresh one or all checks explicitly; stop and retry safely with bounds and cooldowns, and confirm no monitoring runs while the app is closed", true),
      ("Edit, remove or erase a check during an in-flight lookup; a late result cannot overwrite the changed settings or restore the removed check", true),
      ("Go offline or receive a service limit after a successful result; the dated previous result remains clearly marked as not refreshed", true),
      ("Opt into local alerts, allow or deny iOS permission, repeat an unchanged match and disable alerts; only new matches alert and lock-screen text contains no product or target details", true),
      ("Inspect source links, report dates, location, discount conditions and ODbL/OpenStreetMap credits; results never claim current stock, live prices or currency conversion", true),
      ("Use saved targets and editors on both devices/themes, large text and VoiceOver; clearly disclose device-only storage and exclusion from Kitchen Transfer backups", true),
    ]),
  ]

  static func isOpenBlocker(blocker: Bool, verdict: String) -> Bool { blocker && verdict != "pass" && verdict != "resolved" }
  static func requiresRetest(id: String, storedDefinition: String?, currentDefinition: String)
    -> Bool
  {
    if let storedDefinition { return storedDefinition != currentDefinition }
    return ["QA-01-02", "QA-01-03", "QA-16-01", "QA-16-09", "QA-18-07"].contains(id)
  }
}

/// Fast deterministic production contracts. These do not exercise UIKit, network
/// availability, actual household data or device performance. Their names explicitly
/// distinguish them from the manual checkbook; running them NEVER signs off a row.
nonisolated enum QAFeatureContracts {
  struct Check: Sendable {
    var name: String
    var passed: Bool
    var detail: String
  }
  static func run() -> [Check] {
    var checks: [Check] = []
    func check(_ name: String, _ passed: Bool) {
      checks.append(
        Check(
          name: "Contract: " + name, passed: passed,
          detail: "Deterministic fixture only; device journey still requires testing"))
    }
    var request = FinderRequestState()
    let old = request.begin()
    let current = request.begin()
    check(
      "incremental search generation",
      !request.preview(old, count: 9) && request.preview(current, count: 2)
        && request.phase == .loading && request.count == 2)
    request.cancel()
    check("cancelled search ignores completion", !request.complete(current, count: 5))
    var filters = FinderFilters()
    filters.toggle(.chicken, in: .ingredient)
    filters.toggle(.seafood, in: .ingredient)
    check("ingredient multi-select", filters[.ingredient] == [.chicken, .seafood])
    filters.toggle(.noPreference, in: .ingredient)
    check("neutral choice exclusivity", filters[.ingredient] == [.noPreference])
    filters = FinderFilters()
    filters[.time] = [.under30]
    var record = FinderRecord(id: "fixture", title: "Fixture", searchText: "fixture")
    record.totalMinutes = 30
    let boundary = FinderQuery.matches(record, filters: filters)
    record.totalMinutes = 31
    check("total-time boundary", boundary && !FinderQuery.matches(record, filters: filters))
    filters = FinderFilters()
    filters[.diet] = [.vegan, .vegetarian]
    record.facets[.diet] = [.vegetarian]
    check("dietary AND restriction", !FinderQuery.matches(record, filters: filters))
    check(
      "unified count beyond visible window",
      FinderWebPolicy.mergedCount(
        localCount: 100,
        localIdentities: ["hidden", "visible"], webIdentities: ["hidden", "new"]) == 101)
    check(
      "browser public URL boundary",
      RecipeBrowserPolicy.url("https://example.com/recipe") != nil
        && RecipeBrowserPolicy.url("http://127.0.0.1/recipe") == nil
        && RecipeBrowserPolicy.url("https://user:secret@example.com/recipe") == nil)
    var page = RecipeBrowserPageState()
    page.finished(URL(string: "https://example.com/recipe"))
    page.started()
    check("loading page cannot import", page.importURL == nil)
    var importing = RecipeBrowserImportState()
    let token = importing.begin()
    importing.cancel()
    check("cancelled import rejects late data", !importing.accepts(token) && !importing.isRunning)
    check(
      "untested blockers prevent sign-off",
      QAFeatureCoverage.isOpenBlocker(blocker: true, verdict: "untested"))
    return checks
  }
}
