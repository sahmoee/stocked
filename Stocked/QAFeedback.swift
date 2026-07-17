// QAFeedback.swift — turns the QA area into a full feedback/correctness system:
//   • auto-context capture (build, device, OS, screen, household, breadcrumbs)
//   • shake-to-report and long-press quick capture (screenshot + context) from anywhere
//   • automated self-diagnostics that scan the app's own data for anomalies
//   • a correctness health score rolling everything up
//
// All gated behind the QA unlock ("joo"), so normal users never see it.

import SwiftUI
import UIKit

// MARK: - Captured context

struct QAContext: Codable, Hashable {
    var build = ""
    var version = ""
    var device = ""
    var os = ""
    var screen = ""
    var household = ""
    var capturedAt = ""
    var breadcrumbs: [String] = []
}

/// A pin the reporter drops on the screenshot to point at the problem area.
/// x/y are normalized (0…1) within the displayed image.
struct QAAnnotation: Codable, Hashable {
    var x: Double
    var y: Double
    var note: String = ""
}

// MARK: - Context / screenshot / quick report

extension QAWorkbookStore {
    func captureContext() -> QAContext {
        var c = QAContext()
        c.version = BuildConfig.version
        c.build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? ""
        c.device = Self.deviceModel()
        c.os = "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        c.screen = currentScreen.isEmpty ? "—" : currentScreen
        c.household = HouseholdSync.shared.householdName
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; c.capturedAt = f.string(from: Date())
        c.breadcrumbs = Array(breadcrumbs.suffix(12))
        return c
    }

    /// Best-guess source files for an app area, so a report points the AI at real code.
    static func codeHints(for area: String) -> [String] {
        switch area.uppercased() {
        case "LAUNCH":                                  return ["SplashView.swift"]
        case "AUTHENTICATION":                          return ["LoginView.swift"]
        case "ONBOARDING":                              return ["OnboardingQuiz.swift"]
        case "DAILY BRIEF":                             return ["DailyBriefView.swift", "DailyBriefOverlay.swift"]
        case "SIDE DRAWER":                             return ["DrawerSettingsContent.swift"]
        case "HOME HUB", "HOME":                        return ["HomeView.swift", "MainHubView.swift"]
        case "COOK HUB", "COOK":                        return ["CookHubView.swift", "CookTabView.swift", "CookRightNowView.swift"]
        case "INVENTORY HUB", "INVENTORY":              return ["InventoryHubView.swift", "InventoryView.swift"]
        case "RECIPES HUB", "RECIPES":                  return ["RecipeVaultViews.swift", "RecipeSourceHub.swift"]
        case "GROCERY HUB", "GROCERY LIST", "GROCERY":  return ["GroceryListView.swift"]
        case "SETTINGS":                                return ["SettingsPageView.swift"]
        default:                                        return []
        }
    }

    static func deviceModel() -> String {
        var sys = utsname(); uname(&sys)
        let id = withUnsafeBytes(of: &sys.machine) { raw -> String in
            let ptr = raw.baseAddress!.assumingMemoryBound(to: CChar.self)
            return String(cString: ptr)
        }
        return id.isEmpty ? UIDevice.current.model : id
    }

    static func keyWindow() -> UIWindow? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }
    }

    func captureScreenshot() -> Data? {
        guard let window = Self.keyWindow() else { return nil }
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        let img = renderer.image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        return img.jpegData(compressionQuality: 0.6)
    }

    /// Shake / long-press entry point: snapshot the current screen + context and open a quick report.
    func startQuickReport() {
        guard unlocked, !showQuickReport else { return }
        var item = ChangeItem()
        item.source = "feedback"
        item.section = currentScreen
        item.context = captureContext()
        item.codeRefs = Self.codeHints(for: currentScreen)
        let created = addChange(item)
        if let data = captureScreenshot() { attachScreenshot(created.id, data) }
        quickReportID = created.id
        showQuickReport = true
        breadcrumb("Filed feedback")
    }
    /// Discard an untouched quick-report draft on cancel.
    func cancelQuickReport() {
        if let id = quickReportID, let it = change(id), it.title.isEmpty, it.detail.isEmpty {
            deleteChange(id)
        }
        quickReportID = nil; showQuickReport = false
    }
}

// MARK: - Shake to report (opt-in, only mounted when unlocked)

struct ShakeReporter: UIViewControllerRepresentable {
    let onShake: () -> Void
    func makeUIViewController(context: Context) -> ShakeVC { let vc = ShakeVC(); vc.onShake = onShake; return vc }
    func updateUIViewController(_ vc: ShakeVC, context: Context) { vc.onShake = onShake }
}
final class ShakeVC: UIViewController {
    var onShake: (() -> Void)?
    override var canBecomeFirstResponder: Bool { true }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); becomeFirstResponder() }
    override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
        if motion == .motionShake { onShake?() }
        super.motionEnded(motion, with: event)
    }
}
extension View {
    func qaShakeToReport() -> some View {
        background(ShakeReporter { QAWorkbookStore.shared.startQuickReport() }.frame(width: 0, height: 0).allowsHitTesting(false))
    }
}

// MARK: - Quick report sheet

struct QuickReportSheet: View {
    let changeID: String
    private var qa = QAWorkbookStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAnnotator = false
    init(changeID: String) { self.changeID = changeID }

    private func bind<T>(_ kp: WritableKeyPath<ChangeItem, T>) -> Binding<T> {
        Binding(get: { qa.change(changeID)?[keyPath: kp] ?? ChangeItem()[keyPath: kp] },
                set: { v in qa.updateChange(changeID) { $0[keyPath: kp] = v } })
    }

    var body: some View {
        let item = qa.change(changeID) ?? ChangeItem()
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Report a problem").font(QATheme.serif(22)).foregroundStyle(QATheme.ink)
                    QACard {
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("What went wrong?", text: bind(\.title), axis: .vertical)
                                .font(QATheme.serif(16)).foregroundStyle(QATheme.ink)
                            Divider().background(QATheme.underline)
                            TextField("Details (optional)", text: bind(\.detail), axis: .vertical)
                                .font(QATheme.sans(13)).foregroundStyle(QATheme.ink).lineLimit(2...6)
                        }.padding(14)
                    }
                    QALabel(text: "SEVERITY")
                    QAChips(["Critical", "Major", "Minor", "Idea"], selected: item.severity) { s in
                        qa.updateChange(changeID) { $0.severity = s }
                    } colorFor: { _ in QATheme.brown }

                    if let name = item.screenshots.first, let ui = qa.screenshotImage(name) {
                        HStack { QALabel(text: "SCREENSHOT"); Spacer()
                            Button { showAnnotator = true } label: {
                                HStack(spacing: 4) { Image(systemName: "hand.point.up.left.fill"); Text(item.annotations.isEmpty ? "Point at issue" : "\(item.annotations.count) marked") }
                                    .font(QATheme.sans(12, .semibold)).foregroundStyle(QATheme.brown)
                            }.buttonStyle(.plain)
                        }
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: ui).resizable().scaledToFit()
                                .frame(maxHeight: 260).clipShape(RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(QATheme.brown.opacity(0.25)))
                            // Show pin count marker overlay hint
                            if !item.annotations.isEmpty {
                                Text("\(item.annotations.count) 📍").font(QATheme.sans(11, .bold)).foregroundStyle(.white)
                                    .padding(6).background(Capsule().fill(QATheme.fail)).padding(8)
                            }
                        }
                    }
                    if !item.codeRefs.isEmpty { codeRefCard(item) }
                    if let c = item.context { contextCard(c) }
                }.padding(18)
            }
            .background(QATheme.page.ignoresSafeArea())
            .environment(\.colorScheme, .light)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Discard", role: .destructive) { qa.cancelQuickReport() }.tint(QATheme.fail)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { qa.quickReportID = nil; qa.showQuickReport = false; dismiss() }
                        .font(.body.bold()).tint(QATheme.brown)
                }
            }
        }
        .presentationDetents([.large])
        .sheet(isPresented: $showAnnotator) {
            if let n = qa.change(changeID)?.screenshots.first { ScreenshotAnnotator(changeID: changeID, imageName: n) }
        }
    }

    private func codeRefCard(_ item: ChangeItem) -> some View {
        QACard {
            VStack(alignment: .leading, spacing: 6) {
                QALabel(text: "LIKELY CODE (for the AI)")
                Text(item.codeRefs.joined(separator: ", ")).font(QATheme.sans(12, .semibold)).foregroundStyle(QATheme.brown)
                Text("Auto-suggested from the screen you were on.").font(QATheme.sans(10)).foregroundStyle(QATheme.ink.opacity(0.5))
            }.padding(14)
        }
    }

    private func contextCard(_ c: QAContext) -> some View {
        QACard(fill: QATheme.tan) {
            VStack(alignment: .leading, spacing: 4) {
                QALabel(text: "AUTO-CAPTURED CONTEXT")
                ctx("Screen", c.screen); ctx("Build", "\(c.build) · v\(c.version)")
                ctx("Device", "\(c.device) · \(c.os)")
                if !c.household.isEmpty { ctx("Household", c.household) }
                if !c.breadcrumbs.isEmpty {
                    Text("Trail: \(c.breadcrumbs.suffix(5).joined(separator: " › "))")
                        .font(QATheme.sans(10)).foregroundStyle(QATheme.ink.opacity(0.55)).padding(.top, 2)
                }
            }.padding(14)
        }
    }
    private func ctx(_ k: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(k).font(QATheme.sans(10, .bold)).foregroundStyle(QATheme.ink.opacity(0.6)).frame(width: 74, alignment: .leading)
            Text(v).font(QATheme.sans(11)).foregroundStyle(QATheme.ink.opacity(0.85))
        }
    }
}

// MARK: - Screenshot annotator (tap to point at the problem area)

struct ScreenshotAnnotator: View {
    let changeID: String
    let imageName: String
    private var qa = QAWorkbookStore.shared
    @Environment(\.dismiss) private var dismiss
    init(changeID: String, imageName: String) { self.changeID = changeID; self.imageName = imageName }

    private func annotations() -> [QAAnnotation] { qa.change(changeID)?.annotations ?? [] }

    private func imageRect(_ container: CGSize, _ img: CGSize) -> CGRect {
        guard img.width > 0, img.height > 0 else { return .zero }
        let s = min(container.width / img.width, container.height / img.height)
        let w = img.width * s, h = img.height * s
        return CGRect(x: (container.width - w) / 2, y: (container.height - h) / 2, width: w, height: h)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let ui = qa.screenshotImage(imageName) {
                    GeometryReader { geo in
                        let r = imageRect(geo.size, ui.size)
                        ZStack(alignment: .topLeading) {
                            Image(uiImage: ui).resizable().scaledToFit()
                            ForEach(Array(annotations().enumerated()), id: \.offset) { i, a in
                                pin(i + 1)
                                    .position(x: r.minX + a.x * r.width, y: r.minY + a.y * r.height)
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(SpatialTapGesture().onEnded { v in
                            guard r.contains(v.location) else { return }
                            let nx = (v.location.x - r.minX) / r.width
                            let ny = (v.location.y - r.minY) / r.height
                            qa.updateChange(changeID) { $0.annotations.append(QAAnnotation(x: Double(nx), y: Double(ny))) }
                        })
                    }
                    .background(Color.black.opacity(0.05))
                } else {
                    Text("Screenshot unavailable").font(QATheme.sans(13)).foregroundStyle(QATheme.ink.opacity(0.5)).frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Notes for each pin
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Tap the image to drop a pin on the problem area.").font(QATheme.sans(12)).foregroundStyle(QATheme.ink.opacity(0.6))
                        ForEach(Array(annotations().enumerated()), id: \.offset) { i, _ in
                            HStack(spacing: 10) {
                                pin(i + 1)
                                TextField("What's wrong here?", text: Binding(
                                    get: { qa.change(changeID)?.annotations[safeQA: i]?.note ?? "" },
                                    set: { v in qa.updateChange(changeID) { if $0.annotations.indices.contains(i) { $0.annotations[i].note = v } } }))
                                    .font(QATheme.sans(13)).foregroundStyle(QATheme.ink)
                                Button { qa.updateChange(changeID) { if $0.annotations.indices.contains(i) { $0.annotations.remove(at: i) } } } label: {
                                    Image(systemName: "trash").foregroundStyle(QATheme.fail)
                                }.buttonStyle(.plain)
                            }
                            Divider().background(QATheme.underline.opacity(0.4))
                        }
                    }.padding(16)
                }
                .frame(maxHeight: 220)
            }
            .background(QATheme.page.ignoresSafeArea())
            .environment(\.colorScheme, .light)
            .navigationTitle("Point at the issue").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.font(.body.bold()).tint(QATheme.brown) } }
        }
    }

    private func pin(_ n: Int) -> some View {
        Text("\(n)").font(QATheme.sans(12, .bold)).foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(QATheme.fail))
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 2)
    }
}

private extension Array {
    subscript(safeQA index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

// MARK: - Automated self-diagnostics

struct DiagnosticFinding { let key: String; let title: String; let section: String; let severity: String }

extension QAWorkbookStore {
    /// Scan the app's own data for anomalies and reconcile them into the change list.
    /// Returns the number of open diagnostic findings.
    @discardableResult
    func runDiagnostics(store: GuestDataStore?) -> Int {
        guard let store else { return 0 }
        var findings: [DiagnosticFinding] = []

        let blankInv = store.inventoryItems.filter { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if blankInv > 0 { findings.append(.init(key: "inv_blank_name", title: "\(blankInv) inventory item(s) with no name", section: "INVENTORY HUB", severity: "Major")) }

        let blankGro = store.groceryItems.filter { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if blankGro > 0 { findings.append(.init(key: "gro_blank_name", title: "\(blankGro) grocery item(s) with no name", section: "GROCERY HUB", severity: "Major")) }

        let dupInv = Dictionary(grouping: store.inventoryItems, by: { $0.id }).filter { $0.value.count > 1 }.count
        if dupInv > 0 { findings.append(.init(key: "inv_dup_id", title: "\(dupInv) duplicate inventory ID(s)", section: "INVENTORY HUB", severity: "Critical")) }

        let dupGro = Dictionary(grouping: store.groceryItems, by: { $0.id }).filter { $0.value.count > 1 }.count
        if dupGro > 0 { findings.append(.init(key: "gro_dup_id", title: "\(dupGro) duplicate grocery ID(s)", section: "GROCERY HUB", severity: "Critical")) }

        let negQty = store.inventoryItems.filter { $0.quantity < 0 }.count
        if negQty > 0 { findings.append(.init(key: "inv_neg_qty", title: "\(negQty) inventory item(s) with negative quantity", section: "INVENTORY HUB", severity: "Major")) }

        let blankMeal = store.plannedMeals.filter { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }.count
        if blankMeal > 0 { findings.append(.init(key: "meal_blank_title", title: "\(blankMeal) planned meal(s) with no title", section: "COOK HUB", severity: "Minor")) }

        reconcileDiagnostics(findings)
        return findings.count
    }

    /// Upsert current findings and clear diagnostic entries that no longer apply.
    private func reconcileDiagnostics(_ findings: [DiagnosticFinding]) {
        let now = Date().timeIntervalSince1970 * 1000
        var present = Set<String>()
        for f in findings {
            let origin = "DIAG:\(f.key)"
            present.insert(origin)
            if let i = state.changes.firstIndex(where: { $0.origin == origin }) {
                state.changes[i].title = f.title
                state.changes[i].updatedAt = now
                if state.changes[i].status == .implemented || state.changes[i].status == .regressionPass {
                    state.changes[i].status = .open   // reappeared → reopen
                }
            } else {
                var it = ChangeItem()
                it.title = f.title; it.source = "diagnostic"; it.origin = origin
                it.section = f.section; it.severity = f.severity
                it.detail = "Auto-detected by self-check."
                state.changes.insert(it, at: 0)
            }
        }
        // Auto-clear diagnostics that no longer reproduce (mark verified, keep for record).
        for i in state.changes.indices where state.changes[i].source == "diagnostic" && !present.contains(state.changes[i].origin) {
            if state.changes[i].status != .regressionPass {
                state.changes[i].status = .regressionPass
                state.changes[i].regressionNote = "No longer detected by self-check."
                state.changes[i].history.append("\(QAWorkbookStore.stamp()) auto-cleared")
                state.changes[i].updatedAt = now
            }
        }
        touch(); save(); writeChangeExport()
    }
}

// MARK: - Correctness health score

struct HealthScore {
    var coverage: Double = 0      // fraction of QA items marked
    var passQuality: Double = 0   // of marked items, fraction passing
    var specDone: Double = 0      // RL implemented %
    var stability: Double = 1     // 1 - penalty from open criticals / regressions
    var openCriticals = 0
    var regressionFails = 0
    var diagnosticsOpen = 0
    var composite: Int {
        Int(round(100 * (0.40 * coverage + 0.25 * passQuality + 0.15 * specDone + 0.20 * stability)))
    }
    var grade: String {
        switch composite { case 90...: return "Excellent"; case 75..<90: return "Good"; case 55..<75: return "Fair"; default: return "Needs work" }
    }
}

extension QAWorkbookStore {
    func healthScore() -> HealthScore {
        var h = HealthScore()
        h.coverage = overallProgress()

        var marked = 0, passed = 0
        for t in content.tests where !t.isWorkflow {
            let ts = testState(t.id)
            for st in ts.items.values where st.mark != .none { marked += 1; if st.mark == .pass { passed += 1 } }
        }
        h.passQuality = marked == 0 ? 0 : Double(passed) / Double(marked)

        let rl = rlProgress(); h.specDone = rl.total == 0 ? 0 : Double(rl.done) / Double(rl.total)

        h.openCriticals = changesOpen.filter { $0.severity == "Critical" }.count
        h.regressionFails = changesRegression.filter { $0.status == .regressionFail }.count
        h.diagnosticsOpen = state.changes.filter { $0.source == "diagnostic" && ($0.status == .open || $0.status == .inProgress) }.count
        let openMajors = changesOpen.filter { $0.severity == "Major" }.count
        let penalty = Double(h.openCriticals) * 0.34 + Double(h.regressionFails) * 0.34 + Double(openMajors) * 0.08
        h.stability = max(0, 1 - min(1, penalty))
        return h
    }
}
