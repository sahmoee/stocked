import Foundation

/// Stable appended IDs. These are DEVICE checks, not passes inferred from a build
/// or from the small deterministic contracts below. Never renumber existing rows.
nonisolated enum QAFeatureCoverage {
  static let version = "2026-09-03 · recipes, browser and autonomous QA identity"
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
