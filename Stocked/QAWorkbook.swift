// QAWorkbook.swift — hidden in-app QA Workbook (Sowens Studios).
//
// A faithful digital version of the Stocked QA Workbook (Apple Pencil Edition),
// integrated into the app. Hidden until unlocked with a code ("joo") in Settings.
// Presented as an always-accessible floating panel that minimizes to a draggable
// bubble. QA results sync within the household.
//
// Content is bundled as QAWorkbookContent.json (16 sections, 121 tests/workflows,
// 762 checklist items) and loaded at launch. State (marks/tickets/notes/build) is
// persisted locally and serialized for household sync.

import SwiftUI
import Foundation

// ── Bundled content models ────────────────────────────────────────────────────
struct QASectionInfo: Codable, Hashable {
    let name: String
    let description: String
    var eli5: String? = nil       // plain-language "what/why/when to skip" (optional)
}

struct QATest: Codable, Identifiable, Hashable {
    let id: String
    let section: String?
    let title: String
    let purpose: String
    let isWorkflow: Bool
    let steps: [String]
    let checklist: [String]
    let flowExperience: [String]
}

struct QAContent: Codable { let sections: [QASectionInfo]; let tests: [QATest] }

// ── Living Running List (implementation specs) ────────────────────────────────
struct RLEntry: Codable, Identifiable, Hashable {
    let id: String
    let section: String
    let title: String
    let status: String
    let priority: String
    let intent: String
    let vision: String
    let ux: [String]
    let logic: [String]
    let connected: [String]
    let edge: [String]
    let acceptance: [String]
}
struct RLContent: Codable { let entries: [RLEntry] }

struct RLEntryState: Codable, Equatable, Hashable {
    var implemented: Bool = false
    var note: String = ""
}

/// Which workbook the floating panel is showing.
enum QAMode: String { case chooser, qa, runningList, changes, dashboard }

// ── Per-item / per-test state (persisted + synced) ────────────────────────────
enum QAMark: String, Codable, CaseIterable { case none = "", pass, fail, review, na }

struct QAItemState: Codable, Equatable, Hashable {
    var mark: QAMark = .none
    var ticket: String = ""
    var note: String = ""
}

struct QATestState: Codable, Equatable {
    var items: [Int: QAItemState] = [:]
    var notes: String = ""
    var parkingLot: String = ""
    var resumeHere: String = ""
    var severity: String = ""      // Critical | Major | Minor | Idea
    var overall: QAMark = .none    // workflow-level result
    var flowExp: [Int: Bool] = [:] // workflow FLOW EXPERIENCE checks
}

struct QABuildInfo: Codable, Equatable {
    var build = "", version = "", tester = "", date = "", started = "", completed = ""
}

struct QAWorkbookState: Codable, Equatable {
    var tests: [String: QATestState] = [:]
    var rl: [String: RLEntryState] = [:]        // Running List per-entry progress
    var changes: [ChangeItem] = []              // Things to Change (defect/change log)
    var build = QABuildInfo()
    var autoBuildToken = ""                       // last build we auto-filled (to detect manual edits)
    var updatedAt: Double = 0
    var writerID: String = ""

    init() {}
    // Tolerant decoding: missing keys fall back to defaults so adding fields (rl, changes, …)
    // never fails to load an older saved state and wipe existing QA progress.
    enum CodingKeys: String, CodingKey { case tests, rl, changes, build, autoBuildToken, updatedAt, writerID }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tests = (try? c.decode([String: QATestState].self, forKey: .tests)) ?? [:]
        rl = (try? c.decode([String: RLEntryState].self, forKey: .rl)) ?? [:]
        changes = (try? c.decode([ChangeItem].self, forKey: .changes)) ?? []
        build = (try? c.decode(QABuildInfo.self, forKey: .build)) ?? QABuildInfo()
        autoBuildToken = (try? c.decode(String.self, forKey: .autoBuildToken)) ?? ""
        updatedAt = (try? c.decode(Double.self, forKey: .updatedAt)) ?? 0
        writerID = (try? c.decode(String.self, forKey: .writerID)) ?? ""
    }
}

// ── Store ─────────────────────────────────────────────────────────────────────
@MainActor
@Observable
final class QAWorkbookStore {
    static let shared = QAWorkbookStore()

    let content: QAContent
    let rlContent: RLContent
    var state = QAWorkbookState()

    // Overlay presentation state (drives the floating panel).
    var isPresented = false
    var isMinimized = false
    var mode: QAMode = .chooser        // chooser → QA → runningList / changes / dashboard
    var currentTestID: String?
    var bubbleOffset: CGSize = .zero

    // Feedback context (not persisted/synced — live session state)
    var breadcrumbs: [String] = []     // recent navigation/actions ring buffer
    var currentScreen = ""             // last opened tab, for auto-context
    var showQuickReport = false        // drives the shake/long-press quick-report sheet
    var quickReportID: String?

    /// Unlocked once the user types the code in Settings. Persisted + synced.
    var unlocked: Bool {
        get { UserDefaults.standard.bool(forKey: "qa_unlocked") }
        set { UserDefaults.standard.set(newValue, forKey: "qa_unlocked"); if newValue { touch() } }
    }

    private var stateURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("qa_workbook_state.json")
    }

    private init() {
        // Load bundled content (fail-soft to an empty workbook so the app never crashes).
        if let url = Bundle.main.url(forResource: "QAWorkbookContent", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode(QAContent.self, from: data) {
            content = parsed
        } else {
            content = QAContent(sections: [], tests: [])
        }
        if let url = Bundle.main.url(forResource: "RunningListContent", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let parsed = try? JSONDecoder().decode(RLContent.self, from: data) {
            rlContent = parsed
        } else {
            rlContent = RLContent(entries: [])
        }
        loadState()
        autofillBuild()
        // Record navigation breadcrumbs for feedback auto-context (tab switches).
        NotificationCenter.default.addObserver(forName: .stockedSwitchTab, object: nil, queue: .main) { [weak self] note in
            guard let self, let tab = note.object as? StockedTab else { return }
            Task { @MainActor in self.currentScreen = tab.rawValue; self.breadcrumb("Opened \(tab.rawValue)") }
        }
    }

    /// Append a navigation/action breadcrumb (kept to the last 40, in-memory only).
    func breadcrumb(_ s: String) {
        breadcrumbs.append("\(QAWorkbookStore.stamp()) \(s)")
        if breadcrumbs.count > 40 { breadcrumbs.removeFirst(breadcrumbs.count - 40) }
    }

    // MARK: Running List
    var rlSections: [String] {
        var seen = Set<String>(); var out: [String] = []
        for e in rlContent.entries where !seen.contains(e.section) { seen.insert(e.section); out.append(e.section) }
        return out
    }
    func rlEntries(in section: String) -> [RLEntry] { rlContent.entries.filter { $0.section == section } }
    func rlState(_ id: String) -> RLEntryState { state.rl[id] ?? RLEntryState() }
    func rlUpdate(_ id: String, _ mutate: (inout RLEntryState) -> Void) {
        var s = rlState(id); mutate(&s); state.rl[id] = s; touch(); save()
    }
    func rlProgress() -> (done: Int, total: Int) {
        (state.rl.values.filter { $0.implemented }.count, rlContent.entries.count)
    }

    // MARK: Build info auto-fill (#4)
    /// Fill BUILD/VERSION/DATE from the app's current build when the tester hasn't typed
    /// their own, and refresh them automatically whenever the build changes — unless the
    /// user manually overrode the value (detected via autoBuildToken).
    func autofillBuild() {
        let version = BuildConfig.version
        let buildNum = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        let token = "\(version) (\(buildNum))"
        guard token != state.autoBuildToken else { return }   // build unchanged
        // Only overwrite fields that are empty or still hold the previous auto value.
        if state.build.build.isEmpty || state.build.build == state.autoBuildToken { state.build.build = token }
        if state.build.version.isEmpty || state.build.version == prevVersion() { state.build.version = version }
        if state.build.date.isEmpty { state.build.date = Self.today() }
        state.autoBuildToken = token
        save()
    }
    private func prevVersion() -> String {
        // version portion of the previous token, e.g. "4.13 (57)" -> "4.13"
        state.autoBuildToken.components(separatedBy: " (").first ?? ""
    }
    private static func today() -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .none; return f.string(from: Date())
    }

    // MARK: Content helpers
    var sections: [QASectionInfo] { content.sections }
    func tests(in section: String) -> [QATest] { content.tests.filter { ($0.section ?? "") == section } }
    func test(_ id: String) -> QATest? { content.tests.first { $0.id == id } }

    // MARK: State access
    func testState(_ id: String) -> QATestState { state.tests[id] ?? QATestState() }
    func itemState(_ id: String, _ idx: Int) -> QAItemState { testState(id).items[idx] ?? QAItemState() }

    func update(_ id: String, _ mutate: (inout QATestState) -> Void) {
        var ts = testState(id); mutate(&ts); state.tests[id] = ts; touch(); save()
    }
    func setMark(_ id: String, _ idx: Int, _ mark: QAMark) {
        update(id) { ts in var it = ts.items[idx] ?? QAItemState(); it.mark = (it.mark == mark ? .none : mark); ts.items[idx] = it }
        if itemState(id, idx).mark == .fail { funnelFromQA(testID: id, idx: idx) }  // Fail → Things to Change
    }
    func setTicket(_ id: String, _ idx: Int, _ v: String) {
        update(id) { ts in var it = ts.items[idx] ?? QAItemState(); it.ticket = v; ts.items[idx] = it }
        if !v.trimmingCharacters(in: .whitespaces).isEmpty { funnelFromQA(testID: id, idx: idx) }  // ticket → Things to Change
    }
    func setNote(_ id: String, _ idx: Int, _ v: String)   { update(id) { ts in var it = ts.items[idx] ?? QAItemState(); it.note = v; ts.items[idx] = it } }

    // MARK: Progress
    /// (marked, total) checklist items for a section — drives the section progress bars.
    func progress(section: String) -> (done: Int, total: Int) {
        var done = 0, total = 0
        for t in tests(in: section) {
            total += max(t.checklist.count, t.isWorkflow ? 1 : 0)
            let ts = testState(t.id)
            if t.isWorkflow { if ts.overall != .none { done += max(t.checklist.count, 1) } }
            else { done += ts.items.values.filter { $0.mark != .none }.count }
        }
        return (done, total)
    }
    func overallProgress() -> Double {
        var d = 0, tt = 0
        for s in sections { let p = progress(section: s.name); d += p.done; tt += p.total }
        return tt == 0 ? 0 : Double(d) / Double(tt)
    }

    // MARK: Persistence
    func touch() { state.updatedAt = Date().timeIntervalSince1970 * 1000; state.writerID = HouseholdSync.shared.memberId }
    func save() { if let data = try? JSONEncoder().encode(state) { try? data.write(to: stateURL) } }
    private func loadState() {
        if let data = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(QAWorkbookState.self, from: data) { state = s }
    }

    // MARK: Sync (household)
    /// Serialize the whole QA state for a household push (LWW by updatedAt).
    func serialized() -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(state),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
    /// Adopt a remote QA blob if it's newer than ours.
    func applyRemote(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj),
              let incoming = try? JSONDecoder().decode(QAWorkbookState.self, from: data) else { return }
        if incoming.updatedAt > state.updatedAt {
            state = incoming
            save()
            if !incoming.tests.isEmpty || incoming.build != QABuildInfo() { UserDefaults.standard.set(true, forKey: "qa_unlocked") }
        }
    }

    // MARK: Presentation
    /// Open from Settings / unlock — always asks which workbook first.
    func open() { autofillBuild(); mode = .chooser; isPresented = true; isMinimized = false }
    func choose(_ m: QAMode) { mode = m; isMinimized = false }
    func backToChooser() { mode = .chooser }
    func minimize() { isMinimized = true }
    func expand() { isMinimized = false }

    /// "Test in App" — navigate the live app to the area this test/section covers, then
    /// minimize the workbook to the bubble so the tester can exercise it in real time and
    /// tap the bubble to return and mark results.
    func testInApp(section: String?) {
        if let tab = QAWorkbookStore.tab(for: section) {
            NotificationCenter.default.post(name: .stockedSwitchTab, object: tab)
        }
        minimize()
    }
    static func tab(for section: String?) -> StockedTab? {
        switch section {
        case "COOK HUB": return .cook
        case "INVENTORY HUB": return .inventory
        case "RECIPES HUB": return .recipes
        case "GROCERY HUB": return .grocery
        case "HOME HUB", "DAILY BRIEF", "SIDE DRAWER": return .home
        default: return nil
        }
    }
    func closeAndSync(store: GuestDataStore?) { save(); isPresented = false; isMinimized = false; if let store { Task { await HouseholdSync.shared.syncNow(store: store) } } }
}
