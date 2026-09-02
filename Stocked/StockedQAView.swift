// StockedQAView.swift — the in-app QA section (Settings → QA).
//
// The full Stocked QA Checkbook v4.13 build 69 (36 sections · 270 checks ·
// 126 blockers) as an interactive, persisted checklist. Every check carries a
// ticket number (QA-<section>-<row>) so bugs file against a stable ID, and
// BLOCKER checks are styled red — a release does not ship with an open one.
//
// Access: the QA row at the bottom of Settings asks for the QA code before
// showing anything (code checked locally; the pane is for testers, not a
// security boundary).
//
// Worker bridge (two-way with the StockedQA companion app):
//   Publish  → POST /qa/reports        source "stocked-app"
//   Fetch    → GET  /qa/reports/latest?source=stocked-qa
// Both directions speak stocked-qa-report/v1 — the same payload the companion
// app publishes and the same JSON you can paste straight into a Claude chat.
// Worker-side routes are specified in the StockedQA repo's WORKER_QA_SPEC.md.

import SwiftUI
import UIKit

// MARK: - Model

enum QAVerdict: String, Codable, CaseIterable {
    case untested, pass, fail, blocked

    var symbol: String {
        switch self {
        case .untested: return "square"
        case .pass: return "checkmark.square.fill"
        case .fail: return "xmark.square.fill"
        case .blocked: return "minus.square.fill"
        }
    }
    var color: Color {
        switch self {
        case .untested: return .gray
        case .pass: return Color.stockedGreen
        case .fail: return .red
        case .blocked: return Color.stockedGold
        }
    }
    var next: QAVerdict {
        switch self {
        case .untested: return .pass
        case .pass: return .fail
        case .fail: return .blocked
        case .blocked: return .untested
        }
    }
}

struct QACheckItemState: Codable {
    var verdict: QAVerdict = .untested
    var note: String = ""
    /// Build 74. Set when a ticket was filed from this row — see
    /// QACheckTickets.swift. Optional rather than defaulted because synthesised
    /// `Codable` throws on a missing key rather than falling back to the default,
    /// and the decode of this dictionary is inside a `try?`. A non-Optional field
    /// here would silently erase every verdict recorded before this build.
    var ticketNumber: String?
}

struct QACheckItem: Identifiable {
    let ticket: String        // "QA-12-03" — stable; persistence key and bug ID
    let text: String
    let blocker: Bool
    var id: String { ticket }
}

struct QAChecklistSection: Identifiable {
    let number: Int
    let title: String
    let note: String
    let items: [QACheckItem]
    var id: Int { number }

    init(_ number: Int, _ title: String, note: String = "", _ rows: [(String, Bool)]) {
        self.number = number
        self.title = title
        self.note = note
        self.items = rows.enumerated().map { idx, row in
            QACheckItem(ticket: String(format: "QA-%02d-%02d", number, idx + 1),
                        text: row.0, blocker: row.1)
        }
    }
}

// MARK: - Checkbook v4.13 build 69 — 36 sections · 270 checks

enum StockedQAChecklist {
    static let version = "4.18 build 74"

    // (text, isBlocker)
    static let sections: [QAChecklistSection] = [
        QAChecklistSection(1, "Pre-flight", note: "Do this before touching the device build.", [
            ("Version and build in the General tab match all three targets: Stocked, StockedWidgets, StockedShareExtension", false),
            ("BuildConfig fallbackVersion and fallbackBuildNumber match the General tab", false),
            ("AppChangelog has exactly ONE entry with isLatest set true, and it is this build", true),
            ("Worker /health reports ok true and every secret flag true (run the QA companion Backend suite)", true),
            ("Worker /version does not report maintenance mode on", true),
            ("Release build compiles with zero new warnings", false),
            ("Swift 6 concurrency guard script passes", false),
        ]),
        QAChecklistSection(2, "First launch and onboarding", note: "Test on a device that has never had the app, then again as an update.", [
            ("Fresh install: onboarding runs start to finish without a dead end", false),
            ("Skipping onboarding still leaves a usable app with no empty required state", false),
            ("Starter meals are present in Cook on a brand new install", false),
            ("Guest mode works with no account: inventory, grocery, and cook all function", false),
            ("Creating an account after using guest mode preserves all guest data", true),
            ("Update over an existing install: no onboarding, no data loss, no duplicate rows", true),
            ("Legacy saved recipes without dishRole or structured amounts still decode and display", true),
            ("Cold launch renders the first frame without a multi-second hang on a large kitchen", false),
        ]),
        QAChecklistSection(3, "Permissions and notifications", note: "Order and timing matter here; they regressed once already.", [
            ("Fresh install: notification permission dialog appears about 1.5s AFTER the main screen, never over the splash", true),
            ("Update or reinstall: no permission dialog reappears", false),
            ("Declining notifications leaves the app fully usable with no nag loop", false),
            ("With low or expiring stock, opening the app shows NO Kitchen Alert banner over the UI", true),
            ("Kitchen Alerts still arrive in Notification Center", false),
            ("Cook timer alerts DO banner in the foreground", true),
            ("Daily Brief notification fires at the scheduled time and deep links to the brief", false),
            ("Expiry reminders name the right items and the right day count", false),
            ("Large pantry does not starve cook timers of pending notification slots (iOS caps at 64)", true),
            ("Camera permission prompt appears only when a scanner is opened", false),
            ("Photo library permission prompt appears only when a photo import is chosen", false),
            ("Revoking a permission in iOS Settings mid-session does not crash the app", true),
        ]),
        QAChecklistSection(4, "Home and Daily Brief", [
            ("Meals-ready count on Home equals the exact count on the Cook tab", true),
            ("Tapping the meals-ready metric opens the matching list, not a different tier", false),
            ("Low-stock count on Home matches the Inventory low-stock filter", true),
            ("Expiring-soon count on Home matches the Inventory expiring filter", true),
            ("Daily Brief generates with an empty kitchen without erroring", false),
            ("Daily Brief low-stock list matches Inventory's low-stock list exactly", true),
            ("Daily Brief expiring list uses the same day window as Inventory", true),
            ("Daily Brief works offline with cached context", false),
            ("Recently viewed recipes populate and open correctly", false),
            ("Empty-state copy on a new install reads correctly and is not a blank panel", false),
        ]),
        QAChecklistSection(5, "Inventory core", [
            ("Add an item manually: name, quantity, unit, zone, expiry all persist across relaunch", false),
            ("Edit an item: change survives a force-quit", false),
            ("Delete an item: it does not return after relaunch or after a household sync", true),
            ("Undo after delete restores the item with its original values", false),
            ("Search inside Inventory finds items by partial name", false),
            ("Sort and filter controls all produce a correct, non-empty result where data exists", false),
            ("Fill level slider updates the displayed level and the low-stock state together", false),
            ("An item scraped to a smear (below 5 percent) is NOT treated as available for cooking", true),
            ("Expired items are visually distinct and excluded from availability", true),
            ("Duplicate detection warns when adding a name that already exists", false),
            ("Large inventory (300+ items) scrolls without stutter", false),
        ]),
        QAChecklistSection(6, "Zones, classification, and details", [
            ("Items land in a sensible default zone when added by each path: manual, barcode, receipt, photo", false),
            ("Moving an item between zones persists and does not duplicate", false),
            ("Snacks are not classified as spices and spices are not classified as snacks", true),
            ("The zone shown in Inventory matches the zone shown in the item detail sheet", true),
            ("Item detail shows Total, Reserved, and Available when a meal plan reserves it", true),
            ("Available equals Total minus Reserved in every case", true),
            ("Low-stock styling in the detail sheet agrees with the list row", true),
            ("Expiry chips use the same day window everywhere they appear", true),
            ("Price history on an item shows past purchases with correct dates", false),
        ]),
        QAChecklistSection(7, "Barcode scanning", [
            ("A known UPC resolves to a correct product name", false),
            ("An unknown barcode offers manual entry rather than failing silently", false),
            ("Correcting a resolved name records the correction and it is reused next time", false),
            ("Scanning in poor light degrades gracefully with guidance, not a freeze", false),
            ("Scanning the same barcode twice offers to increment rather than creating a duplicate", true),
            ("Airplane mode: the scanner explains it needs a connection and queues or exits cleanly", false),
            ("Batch scanning several items in a row produces one row per distinct product", false),
        ]),
        QAChecklistSection(8, "Receipt scanning and purchase import", [
            ("A clear receipt photo produces a reviewable line-item list", false),
            ("Low-confidence lines are visibly flagged for review", false),
            ("Editing a parsed line before import saves the edited version", false),
            ("Importing the same receipt twice triggers duplicate review", true),
            ("Merge on duplicate review keeps quantities and totals correct with no double count", true),
            ("Store name is captured and applied to the imported items", false),
            ("Corrections made during review are recorded and improve later scans", false),
            ("A blurry or non-receipt photo fails with a clear message and no partial import", true),
            ("Importing a long receipt (30+ lines) does not time out or drop rows", false),
        ]),
        QAChecklistSection(9, "AI inventory scan (photo of shelves)", [
            ("A fridge or pantry photo returns a plausible item list", false),
            ("Each detected item can be edited or removed before import", false),
            ("Nothing is written to inventory until the user confirms", true),
            ("Quota or rate limiting surfaces a readable message, not a spinner that never ends", false),
            ("Offline shows a clear unavailable state", false),
        ]),
        QAChecklistSection(10, "Grocery list", [
            ("Add, edit, check, and delete all persist across relaunch", false),
            ("Checking an item off moves it into inventory with the right quantity and zone", true),
            ("Auto-suggested items reflect what is actually running low", true),
            ("An item already in stock is not suggested for the list", true),
            ("Add missing ingredients from a recipe adds exactly the missing ones, once each", true),
            ("Adding the same ingredient from two recipes consolidates instead of duplicating", true),
            ("Usuals reflect real purchase history", false),
            ("Manual reordering persists", false),
            ("Clearing completed items does not remove unchecked ones", true),
        ]),
        QAChecklistSection(11, "Multi-store grocery", [
            ("Grouping by store shows each store with its own items", false),
            ("Completing one store's segment moves only those items into inventory", true),
            ("Other stores' items remain pending after one store completes", true),
            ("Moving an item between stores does not recreate or duplicate it", true),
            ("Store layout ordering, where learned, matches the aisle order for that store", false),
        ]),
        QAChecklistSection(12, "Cook hub and Cook Now", note: "The parity work in this build lands here.", [
            ("Cook Now shows Discover recipes with real photos, not only starter meals", true),
            ("Cook Now shows Discover recipes on a COLD LAUNCH without opening Recipes first", true),
            ("Every row shows a real dish photo, not an emoji placeholder", true),
            ("A recipe at 100 percent genuinely has every required ingredient in stock (spot-check the list)", true),
            ("Ready now, Almost ready, and More possibilities each contain the right tier", false),
            ("Percentages are non-decreasing as you move up the tiers", false),
            ("Missing-item text names exactly as many ingredients as the count claims", true),
            ("Optional garnishes and to-taste seasonings do not count against a recipe", true),
            ("Tapping a Discover recipe opens it and rename, favourite, delete, and cook all work", true),
            ("A recipe opened from Cook Now appears in the user's saved collection afterwards", false),
            ("Emptying the kitchen produces a sensible empty state, not a crash or a stale list", false),
            ("Cook tab first load after a large Discover cache does not stall the UI", true),
            ("Changing inventory and returning to Cook updates the tiers", true),
        ]),
        QAChecklistSection(13, "Cooking flow and sessions", [
            ("Start a cook: steps, timers, and ingredient list all render", false),
            ("Leave mid-cook: Pause, Cancel, and Continue are all offered", false),
            ("Force-quit mid-cook and relaunch: resume lands on the exact step with timers restored", true),
            ("Completing a cook deducts inventory once and records one history entry", true),
            ("Completing the SAME cook twice does not double-deduct or double-record", true),
            ("Cancel clears the session, keeps planned meals, and records nothing", true),
            ("Scaling servings scales ingredient amounts and the deduction correctly", true),
            ("Timers continue correctly when the app is backgrounded", false),
            ("Multiple timers in one cook do not collide or mislabel", false),
            ("Cook history shows the right recipe, date, and servings", false),
        ]),
        QAChecklistSection(14, "Substitutions", [
            ("A recipe missing one item offers an in-stock substitute where a sensible one exists", false),
            ("Confirming a substitution updates readiness and the ingredient list", false),
            ("A confirmed substitution deducts the SUBSTITUTE, not the original", true),
            ("Declining a substitution leaves the recipe in its previous tier", false),
            ("User-defined substitutions are respected", false),
            ("A substitution is never offered that uses a saved allergen", true),
        ]),
        QAChecklistSection(15, "Reservations and conflicts", [
            ("Plan two meals that over-commit one ingredient: a conflict is surfaced", true),
            ("Item detail shows the reservation split for that ingredient", true),
            ("Cook Now does not present a reservation-blocked recipe as fully safe", true),
            ("Cook Anyway shows which planned meals are affected before proceeding", true),
            ("Cook Anyway updates the planner and grocery list without duplicate rows", true),
            ("Resolving the shortage auto-clears the conflict row", false),
            ("Deleting a planned meal releases its reservations", true),
            ("Reservations survive a relaunch", true),
        ]),
        QAChecklistSection(16, "Recipes tab and Discover", [
            ("Rails populate on first open with a connection", false),
            ("Missing-count badges are accurate against current inventory", true),
            ("A badge count matches the ingredients the detail view lists as missing", true),
            ("Pull to refresh fetches without duplicating rows", false),
            ("Offline shows the cached catalog rather than an empty tab", true),
            ("Recipe detail shows real step-by-step instructions, never a bare source link", false),
            ("Images load, and a failure falls back cleanly instead of showing a broken frame", false),
            ("Allergen warnings appear on recipes that hit a saved allergen", true),
            ("Hiding allergens filters the rails correctly", true),
            ("Cuisine and diet filters produce correct, non-empty results where data exists", false),
            ("Saving a Discover recipe adds it once to the collection", true),
            ("Saving the same Discover recipe twice does not duplicate it", true),
        ]),
        QAChecklistSection(17, "Search", [
            ("Global search finds inventory items, recipes, and grocery items", false),
            ("A term that matches an inventory item also matches it in recipe availability", true),
            ("Partial and misspelled terms return sensible results", false),
            ("Empty query shows a useful default rather than a blank screen", false),
            ("Search works offline against cached data", false),
        ]),
        QAChecklistSection(18, "User recipes and the vault", [
            ("Create a recipe by hand: all fields persist", false),
            ("Edit, rename, favourite, and delete all take effect and survive relaunch", false),
            ("Collections group correctly and update on change", false),
            ("Cooked and Favorites lists reflect real state", false),
            ("Ingredient amounts scale correctly when servings change", false),
            ("A recipe with no ingredients does not read as ready to cook", true),
            ("Importing a recipe twice by title does not create a duplicate", true),
        ]),
        QAChecklistSection(19, "AI generation and Surprise Me", note: "Dietary safety is the priority here.", [
            ("AI generator returns a coherent recipe from a plain prompt", false),
            ("The generator REFUSES to build around a saved allergen even when asked directly", true),
            ("Pantry items that hit an allergen are not offered to the generator as ingredients", true),
            ("Surprise Me never suggests a recipe using a saved allergen", true),
            ("Surprise Me results change between runs and stay makeable", false),
            ("A generated recipe's missing-ingredient list reflects CURRENT inventory, not the day it was made", true),
            ("Saving a generated recipe puts it in the collection once", false),
            ("Quota, offline, and error states all show readable messages", false),
        ]),
        QAChecklistSection(20, "Social and web recipe import", [
            ("Pasting a TikTok, Instagram, or YouTube link produces a preview", false),
            ("Uncertain fields are visibly flagged before saving", false),
            ("Saving the same link twice warns about the duplicate source", true),
            ("A junk or non-recipe URL fails cleanly with no partial save", true),
            ("An imported web recipe behaves like any other saved recipe afterwards", false),
        ]),
        QAChecklistSection(21, "Meal planner", [
            ("Add a meal to a day: it persists and appears on the right date", false),
            ("Move a meal between days without duplicating it", true),
            ("Delete a planned meal and its reservations release", true),
            ("Cooking a planned meal marks it done and deducts once", true),
            ("Cook-ahead meals appear where expected and are not double-counted", true),
            ("The planner projection reflects inventory as it will be, not as it is", false),
            ("Planner respects allergens for everyone marked present", true),
        ]),
        QAChecklistSection(22, "Leftovers, preservation, and thaw", [
            ("Log a leftover: portions, storage, and expiry all persist", false),
            ("Leftovers appear with correct time remaining and expire on schedule", false),
            ("Preservation suggestions appear for items about to expire", false),
            ("Thaw planner gives a sane timeline for a frozen item", false),
            ("Consuming a leftover decrements portions and clears at zero", false),
        ]),
        QAChecklistSection(23, "Nutrition and health", [
            ("Nutrition facts display where data exists and are absent, not zeroed, where it does not", false),
            ("Per-serving values change correctly when servings scale", false),
            ("HealthKit write, where enabled, records a completed meal once", true),
            ("Declining HealthKit leaves everything else working", false),
            ("No nutrition claim is shown as certain when the source data is an estimate", false),
        ]),
        QAChecklistSection(24, "Costs, budget, and price history", [
            ("Recipe cost estimate appears where price data exists", false),
            ("Budget status reflects real spend", false),
            ("Price history records per-store prices with dates", false),
            ("Currency and formatting follow the device locale", false),
            ("A missing price shows as unknown rather than as zero", true),
        ]),
        QAChecklistSection(25, "Kitchen health and stats", [
            ("Staple coverage percentage reflects actual stocked staples", true),
            ("Stats screens agree with the underlying inventory and history", true),
            ("Waste and usage figures are plausible and non-negative", false),
            ("Empty history shows an empty state, not zeros presented as facts", false),
        ]),
        QAChecklistSection(26, "Household sync and sharing", note: "Needs two devices.", [
            ("Create a household on device A and join from device B with the code", false),
            ("Inventory edits on A appear on B", true),
            ("Grocery edits on A appear on B", true),
            ("Deleting on A removes on B and the item does not resurrect", true),
            ("Simultaneous edits to one item resolve last-write-wins with no duplicate", true),
            ("Category toggles are respected: an unshared category does not leave the device", true),
            ("Meal plans and recipes sync only when their toggle is on", true),
            ("Activity feed shows the right actor and action", false),
            ("Leaving a household stops sync and keeps local data intact", true),
            ("Household name changes propagate without clobbering", false),
            ("KNOWN GAP: cooking profile, family profiles, substitutions, and staples do NOT sync yet, so allergen rules can differ per device. Confirm this is still the case and is understood.", true),
        ]),
        QAChecklistSection(27, "Widgets", [
            ("Each widget size renders with real data", false),
            ("Widget low-stock count matches Inventory", true),
            ("Widget expiring count matches Inventory", true),
            ("Widget refreshes after an inventory change", false),
            ("Tapping a widget deep links to the right screen", false),
            ("Widget renders sensibly on an empty kitchen", false),
            ("Dark and light appearance both legible", false),
        ]),
        QAChecklistSection(28, "Settings, profiles, and equipment", [
            ("Cooking profile changes persist and take effect", false),
            ("Household size affects serving defaults", false),
            ("Dietary style seeds the Discover diet filter as expected", false),
            ("Adding an allergen immediately affects Cook, Recipes, Surprise Me, and generation", true),
            ("Removing an allergen restores the previously hidden recipes", true),
            ("Dark mode toggle applies everywhere with no unreadable text", false),
            ("Equipment list edits persist", false),
            ("Notification preferences persist and are honoured", false),
            ("Support diagnostics generates and can be shared", false),
        ]),
        QAChecklistSection(29, "Family profiles and dietary safety", note: "Treat every failure here as a release blocker.", [
            ("Add a person with an allergy and mark them present", false),
            ("Recipes using that allergen disappear from Cook Now", true),
            ("They also disappear from Surprise Me and AI generation", true),
            ("Marking that person NOT present restores those recipes", true),
            ("Two people with different allergies both constrain results", true),
            ("Dislikes are treated as soft constraints, not hard blocks, where the UI says so", false),
            ("Servings scale to who is marked present", false),
            ("An allergen recorded on a family profile is honoured even if the main cooking profile has none", true),
        ]),
        QAChecklistSection(30, "Paywall and subscription", [
            ("Paywall presents current pricing from StoreKit, not hardcoded text", false),
            ("Purchase completes in sandbox and unlocks the gated features", false),
            ("Restore purchases works on a clean install", true),
            ("Cancelling the sheet leaves the app usable", false),
            ("Gated features are consistently gated: no free path into a paid feature", true),
            ("Offline paywall shows a readable error rather than an empty sheet", false),
        ]),
        QAChecklistSection(31, "Offline and the sync queue", [
            ("Airplane mode: inventory and grocery edits still save locally", true),
            ("A pending-changes indicator appears while offline", false),
            ("Back online: one sync, no duplicates on the other device", true),
            ("Force-quit while offline with queued changes: they still replay after relaunch", true),
            ("Recipes tab shows cached content offline", false),
            ("AI and scanning features show clear unavailable states offline", false),
            ("Flight-mode toggling mid-sync does not corrupt or duplicate data", true),
        ]),
        QAChecklistSection(32, "Data management", [
            ("Export produces a complete, readable file", false),
            ("Backup and restore round-trips without loss", true),
            ("Reset clears everything and leaves a working first-run state", true),
            ("Migration from the previous build's stored data loses nothing", true),
            ("Corrupt or partial stored data does not prevent launch", true),
            ("Deleting the app and reinstalling with an account restores the account's data", false),
        ]),
        QAChecklistSection(33, "Share extension", [
            ("Share a recipe URL from Safari: the extension appears and accepts it", false),
            ("The shared item arrives in the app after opening it", false),
            ("Sharing an unsupported item fails clearly inside the extension", false),
            ("The extension does not crash on a very long URL or large payload", true),
        ]),
        QAChecklistSection(34, "Accessibility", [
            ("VoiceOver reads every primary screen in a sensible order", false),
            ("All actionable controls have labels; none read as just a button", true),
            ("Largest Dynamic Type size does not clip or overlap text on primary screens", true),
            ("Contrast is adequate in both light and dark mode", false),
            ("Reduce Motion is respected", false),
            ("Percentages and status are never conveyed by colour alone", true),
            ("Tap targets on list rows and checkboxes are reachable one-handed", false),
        ]),
        QAChecklistSection(35, "Performance and stability", [
            ("Cold launch to interactive is acceptable on the oldest supported device", false),
            ("Cook tab classification does not block the UI on a large catalog", true),
            ("Scrolling Inventory, Recipes, and Grocery is smooth at realistic data sizes", false),
            ("Memory does not grow without bound over 10 minutes of mixed use", true),
            ("No main-thread stall over half a second during normal navigation", false),
            ("Rapid tab switching does not produce flicker, stale data, or a crash", true),
            ("Backgrounding and returning after 30 minutes restores state correctly", false),
        ]),
        QAChecklistSection(36, "Security and privacy", [
            ("No secret, key, or token appears in any log or diagnostic output", true),
            ("Support diagnostics contains no credentials", true),
            ("Network calls all use HTTPS", true),
            ("A household code cannot be brute-forced from the UI without rate limiting", false),
            ("Data of an unshared category never leaves the device", true),
            ("Privacy copy matches what the app actually collects", true),
        ]),
    ]

    static var totalChecks: Int { sections.reduce(0) { $0 + $1.items.count } }
    static var totalBlockers: Int { sections.reduce(0) { $0 + $1.items.filter(\.blocker).count } }
}

// MARK: - Persistence

@MainActor
@Observable
final class StockedQAStore {
    static let shared = StockedQAStore()
    private(set) var states: [String: QACheckItemState] = [:]   // keyed by ticket

    private init() { load() }

    func state(_ item: QACheckItem) -> QACheckItemState {
        states[item.ticket] ?? QACheckItemState()
    }
    func set(_ item: QACheckItem, _ state: QACheckItemState) {
        let previous = states[item.ticket]?.verdict
        states[item.ticket] = state
        save()
        // Build 74: a verdict set while a test run is open belongs to that run.
        // Guarded on an actual change so re-saving a note does not re-stamp it.
        if previous != state.verdict {
            QARunLog.shared.recordCheck(item.ticket, state.verdict)
        }
    }
    func reset(_ section: QAChecklistSection) {
        for item in section.items { states.removeValue(forKey: item.ticket) }
        save()
    }

    func progress(_ section: QAChecklistSection) -> (pass: Int, fail: Int, blocked: Int, total: Int) {
        var p = 0, f = 0, b = 0
        for item in section.items {
            switch state(item).verdict {
            case .pass: p += 1
            case .fail: f += 1
            case .blocked: b += 1
            case .untested: break
            }
        }
        return (p, f, b, section.items.count)
    }

    /// Sign-off math per the checkbook: an open BLOCKER is a failed or blocked
    /// check that is marked as a blocker. Do not ship with one.
    var signOff: (passed: Int, failed: Int, blocked: Int, openBlockers: Int) {
        var p = 0, f = 0, b = 0, open = 0
        for section in StockedQAChecklist.sections {
            for item in section.items {
                let v = state(item).verdict
                switch v {
                case .pass: p += 1
                case .fail: f += 1
                case .blocked: b += 1
                case .untested: break
                }
                if item.blocker && (v == .fail || v == .blocked) { open += 1 }
            }
        }
        return (p, f, b, open)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(states) {
            UserDefaults.standard.set(data, forKey: "stocked.qa.checklist.v1")
        }
    }
    private func load() {
        guard let data = UserDefaults.standard.data(forKey: "stocked.qa.checklist.v1"),
              let decoded = try? JSONDecoder().decode([String: QACheckItemState].self, from: data) else { return }
        states = decoded
    }
}

// MARK: - Worker bridge (two-way with the StockedQA companion app)

@MainActor
enum StockedQABridge {
    static let schema = "stocked-qa-report/v1"
    static let sourceID = "stocked-app"

    static func buildReport() -> [String: Any] {
        let store = StockedQAStore.shared
        var checklists: [[String: Any]] = []
        for section in StockedQAChecklist.sections {
            var items: [[String: Any]] = []
            for item in section.items {
                let st = store.state(item)
                guard st.verdict != .untested || !st.note.isEmpty else { continue }
                var row: [String: Any] = ["ticket": item.ticket, "item": item.text,
                                          "verdict": st.verdict.rawValue, "blocker": item.blocker]
                if !st.note.isEmpty { row["note"] = st.note }
                items.append(row)
            }
            guard !items.isEmpty else { continue }
            let prog = store.progress(section)
            checklists.append(["id": "checkbook69.\(section.number)",
                               "title": "\(section.number). \(section.title)",
                               "progress": ["pass": prog.pass, "fail": prog.fail,
                                            "blocked": prog.blocked, "total": prog.total],
                               "items": items])
        }
        let sign = StockedQAStore.shared.signOff
        return [
            "schema": schema,
            "source": sourceID,
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "app": ["name": "Stocked", "version": BuildConfig.version, "build": BuildConfig.buildNumber],
            "device": ["model": UIDevice.current.model, "os": "iOS \(UIDevice.current.systemVersion)"],
            "worker": ["baseURL": BuildConfig.receiptWorkerURL],
            "checkbook": ["version": StockedQAChecklist.version,
                          "checks": StockedQAChecklist.totalChecks,
                          "blockers": StockedQAChecklist.totalBlockers],
            "signOff": ["passed": sign.passed, "failed": sign.failed,
                        "blocked": sign.blocked, "openBlockers": sign.openBlockers],
            "checklists": checklists,
        ]
    }

    /// Pretty JSON — paste into a Claude chat or attach to a bug.
    static func exportJSON() -> String {
        (try? JSONSerialization.data(withJSONObject: buildReport(),
                                     options: [.prettyPrinted, .sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) }
            ?? "{\"schema\":\"\(schema)\",\"error\":\"serialization failed\"}"
    }

    enum BridgeError: LocalizedError {
        case notConfigured, routeMissing, nothingPublished, keyRejected, http(Int)
        var errorDescription: String? {
            switch self {
            case .notConfigured: return "Worker isn't configured in this build."
            case .routeMissing: return "The Worker has no /qa routes yet — deploy WORKER_QA_SPEC.md (StockedQA repo)."
            case .nothingPublished: return "Bridge is live but the companion app hasn't published yet."
            case .keyRejected: return "401 — the shared key was rejected."
            case .http(let s): return "Worker returned HTTP \(s)."
            }
        }
    }

    static func publish() async throws -> String {
        guard let base = StockedWorkerClient.url() else { throw BridgeError.notConfigured }
        var request = URLRequest(url: base.appendingPathComponent("qa/reports"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&request)
        request.timeoutInterval = 20
        request.httpBody = try JSONSerialization.data(withJSONObject: buildReport())
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        switch status {
        case 200, 201:
            let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["id"] as? String
            return "Published (\(id ?? "stored"))"
        case 401: throw BridgeError.keyRejected
        case 404: throw BridgeError.routeMissing
        default: throw BridgeError.http(status)
        }
    }

    /// Pull the QA companion app's latest findings.
    static func fetchCompanionReport() async throws -> (summary: String, json: String) {
        guard let base = StockedWorkerClient.url() else { throw BridgeError.notConfigured }
        var comps = URLComponents(url: base.appendingPathComponent("qa/reports/latest"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "source", value: "stocked-qa")]
        guard let url = comps?.url else { throw BridgeError.notConfigured }
        var request = URLRequest(url: url)
        BuildConfig.authorizeWorkerRequest(&request)
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        switch status {
        case 200:
            let at = obj?["generatedAt"] as? String ?? "?"
            let suites = (obj?["suites"] as? [String: Any])?.count ?? 0
            let lists = (obj?["checklists"] as? [[String: Any]])?.count ?? 0
            let pretty = obj.flatMap {
                (try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]))
                    .flatMap { String(data: $0, encoding: .utf8) }
            } ?? String(data: data, encoding: .utf8) ?? ""
            return ("Companion report \(at) · \(suites) suite summaries · \(lists) checklists", pretty)
        case 401: throw BridgeError.keyRejected
        case 404 where obj?["code"] as? String == "no_reports": throw BridgeError.nothingPublished
        case 404: throw BridgeError.routeMissing
        default: throw BridgeError.http(status)
        }
    }
}

// MARK: - Gate (asks for the QA code, at most once every ten minutes)
//
// The unlock is not held here any more. It lives in `QAAccessGate`, which
// persists one timestamp and treats it as good for ten minutes — so pushing
// into QA, backing out to look at something, and pushing in again does not
// re-prompt. See QAAccessGate.swift for why the window is fixed rather than
// sliding.

struct StockedQAGateView: View {
    @Environment(AppSession.self) private var session
    var body: some View {
        // BUILD 74: this used to carry its own copy of the passcode pane, the
        // expiry tick and the unlock handler — a second implementation of the
        // same gate that guards `QAModeView`. There is one now, in QAEntry.swift,
        // and this is a thin alias so the call sites that jump straight to the
        // checkbook keep working unchanged.
        //
        // The `NavigationStack` stays here because those call sites present this
        // as a sheet with nothing above it. `QAUnlockGate` deliberately does not
        // bring one of its own.
        NavigationStack {
            QAUnlockGate(lockedMessage: "Enter the QA code to open the release checklist.") {
                StockedQAHomeView()
            }
        }
        .background(session.themeBgColor.ignoresSafeArea())
        .presentationBackground(session.themeBgColor)
    }
}

// MARK: - QA home (sections + sign-off + worker bridge)

struct StockedQAHomeView: View {
    @Environment(AppSession.self) private var session
    @State private var store = StockedQAStore.shared
    @State private var bridgeBusy = false
    @State private var bridgeStatus: String?
    @State private var companionJSON: String?

    // Build 73. These mirror `nonisolated` UserDefaults-backed statics, which
    // cannot vend a Binding. The mirrors are seeded in `.task` rather than in an
    // initialiser so the toggles reflect a change made from the floating menu in
    // a different window while this screen was already on screen.
    @State private var gate = QAAccessGate.shared
    @State private var showTouchesLive = QATouchTrailSettings.overlayEnabled
    @State private var ringTapsInShots = QATouchTrailSettings.annotateShots
    @State private var floatingButton = QAFloatingButtonSettings.isEnabled

    var body: some View {
        List {
            Section {
                signOffCard
            } footer: {
                Text("Checkbook v\(StockedQAChecklist.version) · \(StockedQAChecklist.totalChecks) checks · \(StockedQAChecklist.totalBlockers) blockers. Do not sign off with an open BLOCKER — if one is knowingly shipped, put the reason and follow-up plan in its note.")
            }

            qaAccessSection

            Section("Stocked QA bridge (via Worker)") {
                Button {
                    runBridge { try await StockedQABridge.publish() }
                } label: {
                    Label("Publish findings to QA companion", systemImage: "arrow.up.circle")
                }
                .disabled(bridgeBusy)
                Button {
                    runBridge {
                        let (summary, json) = try await StockedQABridge.fetchCompanionReport()
                        companionJSON = json
                        return summary
                    }
                } label: {
                    Label("Fetch companion app findings", systemImage: "arrow.down.circle")
                }
                .disabled(bridgeBusy)
                ShareLink(item: StockedQABridge.exportJSON(),
                          preview: SharePreview("Stocked QA report (JSON)")) {
                    Label("Export for Claude (JSON)", systemImage: "doc.badge.gearshape")
                }
                if let companionJSON {
                    ShareLink(item: companionJSON,
                              preview: SharePreview("Companion QA report")) {
                        Label("Share fetched companion report", systemImage: "square.and.arrow.up")
                    }
                }
                if bridgeBusy {
                    HStack(spacing: 10) { ProgressView(); Text("Talking to the Worker…").foregroundStyle(.secondary) }
                } else if let bridgeStatus {
                    Text(bridgeStatus).font(.stocked(.caption)).foregroundStyle(.secondary)
                }
            }

            Section("Sections") {
                ForEach(StockedQAChecklist.sections) { section in
                    NavigationLink {
                        StockedQASectionView(section: section)
                    } label: {
                        sectionRow(section)
                    }
                }
            }
        }
        .navigationTitle("QA Checkbook")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden)
        .background(session.themeBgColor.ignoresSafeArea())
        .presentationBackground(session.themeBgColor)
        .task {
            showTouchesLive = QATouchTrailSettings.overlayEnabled
            ringTapsInShots = QATouchTrailSettings.annotateShots
            floatingButton  = QAFloatingButtonSettings.isEnabled
        }
    }

    // MARK: - Access, touches, destinations (Build 73)

    @ViewBuilder
    private var qaAccessSection: some View {
        Section {
            HStack {
                Label("Access", systemImage: gate.isUnlocked ? "lock.open.fill" : "lock.fill")
                Spacer()
                Text(gate.remainingText)
                    .font(.stocked(.caption).monospaced())
                    .foregroundStyle(gate.isUnlocked ? Color.stockedGreen : .secondary)
            }
            if gate.isUnlocked {
                Button(role: .destructive) { gate.lock() } label: {
                    Label("Lock QA now", systemImage: "lock.rotation")
                }
            }

            Toggle(isOn: $floatingButton) {
                Label("Floating QA button", systemImage: "circle.circle")
            }
            .onChange(of: floatingButton) { _, on in
                QAFloatingButtonSettings.isEnabled = on
                QAFloatingButtonWindow.shared.syncFromGate()
            }

            Toggle(isOn: $ringTapsInShots) {
                Label("Ring taps in screenshots", systemImage: "hand.tap")
            }
            .onChange(of: ringTapsInShots) { _, on in
                QATouchTrailSettings.annotateShots = on
            }

            Toggle(isOn: $showTouchesLive) {
                Label("Show touches on screen", systemImage: "hand.point.up.left")
            }
            .onChange(of: showTouchesLive) { _, on in
                QATouchTrailSettings.overlayEnabled = on
            }

            NavigationLink {
                QASyncSettingsView()
            } label: {
                Label("Reports, logs and where they go", systemImage: "externaldrive.badge.icloud")
            }
            QAAIOverrideView(app: "stocked")
        } header: {
            Text("QA access & capture")
        } footer: {
            Text("One unlock lasts ten minutes across every QA screen. The floating button stays available afterwards and re-prompts only when the ten minutes have run out. Ringed taps are drawn into the screenshot itself; the live overlay is for recording a screen capture and is never photographed.")
        }
    }

    private var signOffCard: some View {
        let sign = store.signOff
        return VStack(alignment: .leading, spacing: 10) {
            Text("Sign-off").scaledFont(16, weight: .bold, design: .serif)
            HStack(spacing: 14) {
                signStat("\(sign.passed)", "Passed", Color.stockedGreen)
                signStat("\(sign.failed)", "Failed", .red)
                signStat("\(sign.blocked)", "Blocked", Color.stockedGold)
                signStat("\(sign.openBlockers)", "Open BLOCKERS", sign.openBlockers == 0 ? Color.stockedGreen : .red)
            }
            Label(sign.openBlockers == 0 ? "SHIP-eligible — no open blockers"
                                         : "HOLD — \(sign.openBlockers) open blocker\(sign.openBlockers == 1 ? "" : "s")",
                  systemImage: sign.openBlockers == 0 ? "checkmark.seal.fill" : "xmark.seal.fill")
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(sign.openBlockers == 0 ? Color.stockedGreen : .red)
        }
        .padding(.vertical, 4)
    }

    private func signStat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).scaledFont(18, weight: .bold, design: .monospaced).foregroundStyle(color)
            Text(label).scaledFont(9).foregroundStyle(.secondary)
        }
    }

    private func sectionRow(_ section: QAChecklistSection) -> some View {
        let prog = store.progress(section)
        let blockers = section.items.filter(\.blocker).count
        return VStack(alignment: .leading, spacing: 3) {
            Text("\(section.number). \(section.title)")
                .scaledFont(14, weight: .medium)
            HStack(spacing: 10) {
                Label("\(prog.pass)", systemImage: "checkmark.circle").foregroundStyle(Color.stockedGreen)
                if prog.fail > 0 { Label("\(prog.fail)", systemImage: "xmark.circle").foregroundStyle(.red) }
                if prog.blocked > 0 { Label("\(prog.blocked)", systemImage: "minus.circle").foregroundStyle(Color.stockedGold) }
                Text("of \(prog.total)").foregroundStyle(.secondary)
                if blockers > 0 {
                    Text("\(blockers) blocker\(blockers == 1 ? "" : "s")")
                        .scaledFont(9, weight: .bold)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.15)))
                        .foregroundStyle(.red)
                }
            }
            .font(.stocked(.caption))
        }
    }

    private func runBridge(_ op: @escaping () async throws -> String) {
        bridgeBusy = true
        bridgeStatus = nil
        Task { @MainActor in
            do { bridgeStatus = try await op() }
            catch { bridgeStatus = "⚠️ \(error.localizedDescription)" }
            bridgeBusy = false
        }
    }
}

// MARK: - Section detail

/// IMPROVEMENT 2 (Build 74) — a 270-row checkbook needs a way to see less of it.
///
/// The longest section is 14 rows and the checkbook is 36 sections. Halfway
/// through a pass the only question that matters is "what have I not done yet",
/// and answering it meant scrolling every section looking for empty squares —
/// which is exactly the task a person does badly and skips rows on.
nonisolated enum QACheckFilter: String, CaseIterable, Identifiable {
    case all, untested, notPassing, blockers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all:        return "All"
        case .untested:   return "Untested"
        case .notPassing: return "Not passing"
        case .blockers:   return "Blockers"
        }
    }

    func matches(_ item: QACheckItem, _ state: QACheckItemState) -> Bool {
        switch self {
        case .all:        return true
        case .untested:   return state.verdict == .untested
        case .notPassing: return state.verdict == .fail || state.verdict == .blocked
        case .blockers:   return item.blocker
        }
    }
}

struct StockedQASectionView: View {
    let section: QAChecklistSection
    @Environment(AppSession.self) private var session
    @State private var store = StockedQAStore.shared
    @State private var noteEditing: QACheckItem? = nil
    @State private var noteDraft = ""
    @State private var filter: QACheckFilter = .all
    // Build 74: set when a row is marked fail or blocked, which offers to turn
    // the failure into a real ticket rather than a note nobody will ever see.
    @State private var ticketPrompt: QACheckItem? = nil
    @State private var ticketVerdict: QAVerdict = .fail
    @State private var justFiled = ""

    private var visibleItems: [QACheckItem] {
        section.items.filter { filter.matches($0, store.state($0)) }
    }

    private var firstUntested: QACheckItem? {
        section.items.first { store.state($0).verdict == .untested }
    }

    var body: some View {
        List {
            if !section.note.isEmpty {
                Text(section.note).font(.stocked(.caption)).foregroundStyle(.secondary)
            }

            filterBar

            if !justFiled.isEmpty {
                Text(justFiled).font(.stocked(.caption)).foregroundStyle(Color.stockedGreen)
            }

            if visibleItems.isEmpty {
                Label(filter == .untested ? "Every row in this section has a verdict."
                      : "Nothing here matches \"\(filter.title)\".",
                      systemImage: "checkmark.circle")
                    .font(.stocked(.caption))
                    .foregroundStyle(Color.stockedGreen)
            }

            ForEach(visibleItems) { item in
                itemRow(item)
                    .id(item.ticket)
            }
        }
        .scrollContentBackground(.hidden)
        .background(session.themeBgColor)
        .navigationTitle("\(section.number). \(section.title)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: exportText()) { Image(systemName: "square.and.arrow.up") }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("Reset") { store.reset(section) }.foregroundStyle(.red)
            }
        }
        .alert("Note on failure", isPresented: Binding(get: { noteEditing != nil },
                                                       set: { if !$0 { noteEditing = nil } })) {
            TextField("What you did, expected, and what happened", text: $noteDraft)
            Button("Save") {
                if let item = noteEditing {
                    var s = store.state(item)
                    s.note = noteDraft
                    store.set(item, s)
                }
                noteEditing = nil
            }
            Button("Cancel", role: .cancel) { noteEditing = nil }
        }
        .sheet(item: $ticketPrompt) { item in
            QACheckTicketSheet(item: item, section: section, verdict: ticketVerdict) { filed in
                justFiled = filed.map { "Filed \($0.number) from \(item.ticket)." } ?? ""
            }
        }
        .qaScreen("QA > Checkbook > \(section.number)")
        .presentationBackground(session.themeBgColor)
    }

    // MARK: Filtering

    private var filterBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(QACheckFilter.allCases) { f in
                        let n = section.items.filter { f.matches($0, store.state($0)) }.count
                        Button {
                            filter = f
                        } label: {
                            Text("\(f.title) \(n)")
                                .scaledFont(11, weight: .semibold)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Capsule().fill(filter == f
                                                           ? Color.stockedGold
                                                           : Color.gray.opacity(0.15)))
                                .foregroundStyle(filter == f ? Color.stockedBlack : .secondary)
                        }
                        .buttonStyle(.plain)
                        .disabled(n == 0 && f != .all)
                        .opacity(n == 0 && f != .all ? 0.4 : 1)
                    }
                }
                .stockedScrollTargetLayout()
                .padding(.vertical, 2)
            }
            .stockedHorizontalSnap()
            if let next = firstUntested, filter != .untested {
                Button {
                    // Switching the filter is the jump: the untested rows become
                    // the only rows, so the next one is at the top of the screen.
                    // Cheaper and steadier than a ScrollViewReader scroll, which
                    // fights the List's own cell reuse on a long section.
                    filter = .untested
                } label: {
                    Label("Jump to next untested — \(next.ticket)", systemImage: "arrow.down.to.line")
                        .scaledFont(11, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                }
                .buttonStyle(.plain)
            }
        }
        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
    }

    private func itemRow(_ item: QACheckItem) -> some View {
        let state = store.state(item)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                Button {
                    var s = state
                    s.verdict = s.verdict.next
                    store.set(item, s)
                    // Build 74: landing on fail or blocked offers a ticket. A
                    // prompt rather than an automatic file — someone tapping
                    // through the cycle to see what the button does should not
                    // leave a trail of tickets behind them.
                    if (s.verdict == .fail || s.verdict == .blocked),
                       s.ticketNumber == nil {
                        ticketVerdict = s.verdict
                        ticketPrompt = item
                    }
                } label: {
                    Image(systemName: state.verdict.symbol)
                        .font(.stocked(.title3))
                        .foregroundStyle(state.verdict.color)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(item.ticket)
                            .scaledFont(9, weight: .bold, design: .monospaced)
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.gray.opacity(0.15)))
                            .foregroundStyle(.secondary)
                        if item.blocker {
                            Text("BLOCKER")
                                .scaledFont(9, weight: .bold)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(Capsule().fill(Color.red.opacity(0.15)))
                                .foregroundStyle(.red)
                        }
                    }
                    Text(item.text)
                        .scaledFont(13)
                        .foregroundStyle(item.blocker ? .red : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button {
                    noteDraft = state.note
                    noteEditing = item
                } label: {
                    Image(systemName: state.note.isEmpty ? "note.text" : "note.text.badge.plus")
                        .foregroundStyle(state.note.isEmpty ? .gray : Color.stockedGold)
                }
                .buttonStyle(.plain)
            }
            if !state.note.isEmpty {
                Text(state.note).font(.stocked(.caption)).foregroundStyle(Color.stockedGold)
            }
            if let number = state.ticketNumber {
                Label(number, systemImage: "ticket")
                    .scaledFont(10, weight: .semibold, design: .monospaced)
                    .foregroundStyle(Color.stockedInfo)
            }
        }
        .padding(.vertical, 2)
    }

    private func exportText() -> String {
        var lines = ["Stocked QA — \(section.number). \(section.title) — \(Date().formatted())", ""]
        for item in section.items {
            let s = store.state(item)
            let tag = item.blocker ? " [BLOCKER]" : ""
            lines.append("[\(s.verdict.rawValue.uppercased())] \(item.ticket)\(tag) \(item.text)")
            if !s.note.isEmpty { lines.append("        note: \(s.note)") }
            if let number = s.ticketNumber { lines.append("        ticket: \(number)") }
        }
        return lines.joined(separator: "\n")
    }
}
