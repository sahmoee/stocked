// QAChangeLog.swift — "Things to Change": the third QA workbook.
//
// Funnels defects from the Stocked QA panel (any checklist item marked FAIL or given a
// ticket auto-creates an entry), plus manual entries with screenshot attachments.
// Tracks each item Open → In Progress → Implemented → Regression (pass/fail).
//
// Everything is persisted locally, synced within the household (rides the same qa blob),
// and auto-exported to machine-readable files (things_to_change.json + THINGS_TO_CHANGE.md
// in the app's Documents dir) so Claude — or any AI helping build — can read the current
// change list and regression status.

import SwiftUI
import PhotosUI
import UIKit

// MARK: - Model

enum ChangeStatus: String, Codable, CaseIterable, Hashable {
    case open, inProgress, implemented, regressionPass, regressionFail
    var label: String {
        switch self {
        case .open: return "Open"
        case .inProgress: return "In Progress"
        case .implemented: return "Implemented"
        case .regressionPass: return "Regression \u{2713}"
        case .regressionFail: return "Regression \u{2717}"
        }
    }
    var color: Color {
        switch self {
        case .open: return QATheme.fail
        case .inProgress: return QATheme.review
        case .implemented: return QATheme.accent
        case .regressionPass: return QATheme.pass
        case .regressionFail: return QATheme.fail
        }
    }
}

struct ChangeItem: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String = ""
    var detail: String = ""
    var source: String = "manual"     // "qa" | "manual" | "feedback" | "diagnostic"
    var origin: String = ""           // "COOK-001#3" / "DIAG:key" reference, or "" for manual
    var section: String = ""          // app area
    var severity: String = "Major"    // Critical | Major | Minor | Idea
    var status: ChangeStatus = .open
    var ticket: String = ""
    var screenshots: [String] = []    // local filenames under qa_shots/ (device-local, not synced)
    var regressionNote: String = ""
    // Structured bug report
    var steps: String = ""            // steps to reproduce
    var expected: String = ""         // expected result
    var actual: String = ""           // actual result
    var history: [String] = []        // status-change audit trail
    var verifiedBy: String = ""       // sign-off
    var verifiedAt: String = ""
    var context: QAContext? = nil     // auto-captured app state at report time
    var annotations: [QAAnnotation] = []  // pins pointing at the problem area on the screenshot
    var codeRefs: [String] = []       // likely source files for the marked area (for the AI)
    var createdAt: Double = Date().timeIntervalSince1970 * 1000
    var updatedAt: Double = Date().timeIntervalSince1970 * 1000
}

// MARK: - Store (change-log behaviour)

extension QAWorkbookStore {
    private var docsDir: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    var shotsDir: URL {
        let u = docsDir.appendingPathComponent("qa_shots", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    // Grouped access
    var changesOpen: [ChangeItem] { state.changes.filter { $0.status == .open || $0.status == .inProgress }.sorted { $0.updatedAt > $1.updatedAt } }
    var changesImplemented: [ChangeItem] { state.changes.filter { $0.status == .implemented }.sorted { $0.updatedAt > $1.updatedAt } }
    var changesRegression: [ChangeItem] { state.changes.filter { $0.status == .regressionPass || $0.status == .regressionFail }.sorted { $0.updatedAt > $1.updatedAt } }
    func changeCounts() -> (open: Int, impl: Int, reg: Int) { (changesOpen.count, changesImplemented.count, changesRegression.count) }
    func change(_ id: String) -> ChangeItem? { state.changes.first { $0.id == id } }

    @discardableResult
    func addChange(_ item: ChangeItem = ChangeItem()) -> ChangeItem {
        var it = item; it.updatedAt = Date().timeIntervalSince1970 * 1000
        if it.context == nil { it.context = captureContext() }   // auto-context on every entry
        state.changes.insert(it, at: 0); touch(); save(); writeChangeExport(); return it
    }
    func updateChange(_ id: String, _ mutate: (inout ChangeItem) -> Void) {
        guard let i = state.changes.firstIndex(where: { $0.id == id }) else { return }
        let before = state.changes[i].status
        mutate(&state.changes[i])
        if state.changes[i].status != before {   // record status changes in the audit trail
            state.changes[i].history.append("\(QAWorkbookStore.stamp()) \(before.label) → \(state.changes[i].status.label)")
        }
        state.changes[i].updatedAt = Date().timeIntervalSince1970 * 1000
        touch(); save(); writeChangeExport()
    }
    static func stamp() -> String {
        let f = DateFormatter(); f.dateFormat = "MMM d, HH:mm"; return f.string(from: Date())
    }
    func deleteChange(_ id: String) {
        if let it = state.changes.first(where: { $0.id == id }) {
            for f in it.screenshots { try? FileManager.default.removeItem(at: shotsDir.appendingPathComponent(f)) }
        }
        state.changes.removeAll { $0.id == id }; touch(); save(); writeChangeExport()
    }

    /// Funnel a QA checklist item (marked FAIL or given a ticket) into the change list.
    /// De-duplicated by origin so re-marking the same item updates rather than duplicates.
    func funnelFromQA(testID: String, idx: Int) {
        let origin = "\(testID)#\(idx)"
        let t = test(testID)
        let itemText = (t?.checklist.indices.contains(idx) == true) ? t!.checklist[idx] : (t?.title ?? testID)
        let ticket = itemState(testID, idx).ticket
        let sev = testState(testID).severity.isEmpty ? "Major" : testState(testID).severity
        if let i = state.changes.firstIndex(where: { $0.origin == origin }) {
            state.changes[i].ticket = ticket
            if !itemState(testID, idx).note.isEmpty { state.changes[i].detail = itemState(testID, idx).note }
            state.changes[i].updatedAt = Date().timeIntervalSince1970 * 1000
        } else {
            var it = ChangeItem()
            it.title = itemText
            it.detail = itemState(testID, idx).note
            it.source = "qa"
            it.origin = origin
            it.section = t?.section ?? ""
            it.ticket = ticket
            it.severity = sev
            it.context = captureContext()
            it.codeRefs = Self.codeHints(for: t?.section ?? "")
            state.changes.insert(it, at: 0)
        }
        touch(); save(); writeChangeExport()
    }

    // Screenshots (device-local; metadata syncs, image bytes stay on device)
    @discardableResult
    func attachScreenshot(_ changeID: String, _ data: Data) -> Bool {
        let name = "\(UUID().uuidString).jpg"
        let out: Data = (UIImage(data: data)?.jpegData(compressionQuality: 0.6)) ?? data
        do { try out.write(to: shotsDir.appendingPathComponent(name)) } catch { return false }
        updateChange(changeID) { $0.screenshots.append(name) }
        return true
    }
    func removeScreenshot(_ changeID: String, _ name: String) {
        try? FileManager.default.removeItem(at: shotsDir.appendingPathComponent(name))
        updateChange(changeID) { $0.screenshots.removeAll { $0 == name } }
    }
    func screenshotImage(_ name: String) -> UIImage? { UIImage(contentsOfFile: shotsDir.appendingPathComponent(name).path) }

    // Auto-export (read by AI assisting the build)
    func writeChangeExport() {
        if let data = try? JSONEncoder().encode(state.changes) {
            try? data.write(to: docsDir.appendingPathComponent("things_to_change.json"))
        }
        try? changeMarkdown().data(using: .utf8)?.write(to: docsDir.appendingPathComponent("THINGS_TO_CHANGE.md"))
    }
    func changeMarkdown() -> String {
        var s = "# Stocked — Things to Change\n\n_Auto-generated from the QA workbook. Build \(state.build.build.isEmpty ? "—" : state.build.build)._\n\n"
        func group(_ title: String, _ items: [ChangeItem]) {
            guard !items.isEmpty else { return }
            s += "## \(title)\n\n"
            for it in items {
                s += "### \(it.title.isEmpty ? "(untitled)" : it.title)\n"
                s += "- Status: \(it.status.label)\n"
                if !it.section.isEmpty { s += "- Area: \(it.section)\n" }
                s += "- Severity: \(it.severity)\n"
                s += "- Source: \(it.origin.isEmpty ? it.source : "QA \(it.origin)")\n"
                if !it.ticket.isEmpty { s += "- Ticket: \(it.ticket)\n" }
                if !it.detail.isEmpty { s += "- Detail: \(it.detail)\n" }
                if !it.steps.isEmpty { s += "- Steps to reproduce: \(it.steps)\n" }
                if !it.expected.isEmpty { s += "- Expected: \(it.expected)\n" }
                if !it.actual.isEmpty { s += "- Actual: \(it.actual)\n" }
                if !it.regressionNote.isEmpty { s += "- Regression: \(it.regressionNote)\n" }
                if let c = it.context {
                    s += "- Context: \(c.screen) · build \(c.build) v\(c.version) · \(c.device) · \(c.os)\n"
                    if !c.breadcrumbs.isEmpty { s += "- Breadcrumbs: \(c.breadcrumbs.joined(separator: " › "))\n" }
                }
                if !it.codeRefs.isEmpty { s += "- Likely code: \(it.codeRefs.joined(separator: ", "))\n" }
                if !it.annotations.isEmpty {
                    let pins = it.annotations.enumerated().map { i, a in
                        "#\(i + 1) at \(Int(a.x * 100))%,\(Int(a.y * 100))%\(a.note.isEmpty ? "" : " – \(a.note)")"
                    }
                    s += "- Marked spots: \(pins.joined(separator: "; "))\n"
                }
                if !it.verifiedBy.isEmpty { s += "- Verified: \(it.verifiedBy) \(it.verifiedAt)\n" }
                if !it.screenshots.isEmpty { s += "- Screenshots: \(it.screenshots.joined(separator: ", "))\n" }
                s += "\n"
            }
        }
        group("Open", changesOpen)
        group("Implemented — needs regression check", changesImplemented)
        group("Regression", changesRegression)
        if state.changes.isEmpty { s += "_No entries yet._\n" }
        return s
    }
}

// MARK: - List

struct ChangeListView: View {
    private var qa = QAWorkbookStore.shared
    @State private var search = ""
    @State private var filter = "All"          // All | Open | Implemented | Regression | Diagnostics
    @State private var sevFilter = "Any"       // Any | Critical | Major | Minor | Idea

    private func match(_ it: ChangeItem) -> Bool {
        if sevFilter != "Any", it.severity != sevFilter { return false }
        if !search.isEmpty {
            let q = search.lowercased()
            let hay = "\(it.title) \(it.detail) \(it.section) \(it.ticket) \(it.origin)".lowercased()
            if !hay.contains(q) { return false }
        }
        return true
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                headerCard
                HStack(spacing: 10) {
                    Button { _ = qa.addChange() } label: {
                        HStack(spacing: 6) { Image(systemName: "plus.circle.fill"); Text("New").font(QATheme.sans(14, .bold)) }
                            .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 12)
                            .frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 13).fill(QATheme.brown))
                    }.buttonStyle(.plain)
                    ShareLink(item: qa.changeMarkdown()) {
                        HStack(spacing: 6) { Image(systemName: "square.and.arrow.up"); Text("Share for AI").font(QATheme.sans(14, .bold)) }
                            .foregroundStyle(QATheme.brown).padding(.horizontal, 14).padding(.vertical, 12)
                            .frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 13).fill(QATheme.card))
                    }
                }
                searchBar
                filterChips

                if filter == "All" || filter == "Open"          { group("OPEN", qa.changesOpen.filter(match)) }
                if filter == "All" || filter == "Implemented"    { group("IMPLEMENTED \u{00B7} NEEDS REGRESSION", qa.changesImplemented.filter(match)) }
                if filter == "All" || filter == "Regression"     { group("REGRESSION", qa.changesRegression.filter(match)) }
                if filter == "Diagnostics"                       { group("SELF-CHECK FINDINGS", qa.state.changes.filter { $0.source == "diagnostic" }.filter(match)) }

                if qa.state.changes.isEmpty {
                    Text("No changes yet.\nMark a QA item Fail or add a ticket and it lands here automatically — add one manually, or shake to report from anywhere.")
                        .font(QATheme.sans(13)).foregroundStyle(QATheme.ink.opacity(0.5))
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity).padding(.top, 30)
                }
            }.padding(16)
        }
        .qaScreen()
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(QATheme.brown.opacity(0.6))
            TextField("Search changes", text: $search).font(QATheme.sans(13)).foregroundStyle(QATheme.ink)
            if !search.isEmpty { Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(QATheme.brown.opacity(0.4)) }.buttonStyle(.plain) }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11).fill(QATheme.card))
    }
    private var filterChips: some View {
        VStack(spacing: 6) {
            QAChips(["All", "Open", "Implemented", "Regression", "Diagnostics"], selected: filter) { filter = $0 } colorFor: { _ in QATheme.brown }
            QAChips(["Any", "Critical", "Major", "Minor", "Idea"], selected: sevFilter) { sevFilter = $0 } colorFor: { _ in QATheme.accent }
        }
    }

    private var headerCard: some View {
        let c = qa.changeCounts()
        return QACard(fill: QATheme.tan) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Things to Change").font(QATheme.serif(20)).foregroundStyle(QATheme.ink)
                Text("Fed by QA tickets \u{00B7} manual entries \u{00B7} regression").font(QATheme.sans(12)).foregroundStyle(QATheme.ink.opacity(0.6))
                HStack(spacing: 14) {
                    stat("\(c.open)", "open"); stat("\(c.impl)", "to verify"); stat("\(c.reg)", "regressed")
                }.padding(.top, 4)
                Text("Auto-saved to THINGS_TO_CHANGE.md for AI pickup").font(QATheme.sans(10)).foregroundStyle(QATheme.accent).padding(.top, 2)
            }.padding(16)
        }
    }
    private func stat(_ n: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(n).font(QATheme.serif(20)).foregroundStyle(QATheme.brown)
            Text(label).font(QATheme.sans(10)).foregroundStyle(QATheme.ink.opacity(0.55))
        }
    }

    @ViewBuilder private func group(_ title: String, _ items: [ChangeItem]) -> some View {
        if !items.isEmpty {
            QALabel(text: title).padding(.top, 6)
            ForEach(items) { it in
                NavigationLink { ChangeEntryView(changeID: it.id) } label: { row(it) }.buttonStyle(.plain)
            }
        }
    }
    private func row(_ it: ChangeItem) -> some View {
        QACard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(it.status.label).font(QATheme.sans(9, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 2).background(Capsule().fill(it.status.color))
                        if !it.origin.isEmpty { Text("QA \(it.origin)").font(QATheme.sans(9, .bold)).foregroundStyle(QATheme.accent) }
                    }
                    Text(it.title.isEmpty ? "(untitled)" : it.title).font(QATheme.serif(14)).foregroundStyle(QATheme.ink).lineLimit(2)
                    HStack(spacing: 8) {
                        if !it.section.isEmpty { Text(it.section).font(QATheme.sans(10)).foregroundStyle(QATheme.ink.opacity(0.5)) }
                        Text(it.severity).font(QATheme.sans(10, .semibold)).foregroundStyle(QATheme.brown)
                        if !it.screenshots.isEmpty { Image(systemName: "paperclip").font(.system(size: 10)).foregroundStyle(QATheme.accent) }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(QATheme.brown.opacity(0.5))
            }.padding(14)
        }
    }
}

// MARK: - Entry editor

struct AnnotTarget: Identifiable { let id = UUID(); let name: String }

struct ChangeEntryView: View {
    let changeID: String
    private var qa = QAWorkbookStore.shared
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var annotTarget: AnnotTarget?
    @Environment(\.dismiss) private var dismiss
    init(changeID: String) { self.changeID = changeID }

    private func bind<T>(_ kp: WritableKeyPath<ChangeItem, T>) -> Binding<T> {
        Binding(get: { qa.change(changeID)?[keyPath: kp] ?? ChangeItem()[keyPath: kp] },
                set: { v in qa.updateChange(changeID) { $0[keyPath: kp] = v } })
    }

    var body: some View {
        let item = qa.change(changeID) ?? ChangeItem()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                QACard(fill: QATheme.headerTan) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.origin.isEmpty ? "Manual entry" : "From QA \u{00B7} \(item.origin)")
                            .font(QATheme.sans(11, .bold)).foregroundStyle(QATheme.accent)
                        TextField("What needs to change?", text: bind(\.title), axis: .vertical)
                            .font(QATheme.serif(18)).foregroundStyle(QATheme.ink)
                    }.padding(16)
                }

                QALabel(text: "STATUS"); statusChips(item)
                QALabel(text: "SEVERITY"); severityChips(item)

                QACard {
                    VStack(alignment: .leading, spacing: 6) {
                        QALabel(text: "DETAIL")
                        TextField("Describe the change / bug / fix needed", text: bind(\.detail), axis: .vertical)
                            .font(QATheme.sans(13)).foregroundStyle(QATheme.ink).lineLimit(3...8)
                    }.padding(14)
                }
                HStack(spacing: 10) { Text("TICKET").font(QATheme.sans(10, .bold)).foregroundStyle(QATheme.ink.opacity(0.7)); QAUnderlineField(placeholder: "", text: bind(\.ticket)) }
                HStack(spacing: 10) { Text("AREA").font(QATheme.sans(10, .bold)).foregroundStyle(QATheme.ink.opacity(0.7)); QAUnderlineField(placeholder: "App area", text: bind(\.section)) }

                codeRefCard(item)
                reproCard

                screenshotsSection(item)

                if let c = item.context { contextCard(c) }
                if !item.history.isEmpty { historyCard(item) }

                if item.status == .implemented || item.status == .regressionPass || item.status == .regressionFail {
                    QACard(fill: QATheme.tan) {
                        VStack(alignment: .leading, spacing: 8) {
                            QALabel(text: "REGRESSION CHECK")
                            HStack(spacing: 8) { regBtn("Pass \u{2713}", .regressionPass, item); regBtn("Fail \u{2717}", .regressionFail, item) }
                            TextField("What did you re-test after the fix?", text: bind(\.regressionNote), axis: .vertical)
                                .font(QATheme.sans(13)).foregroundStyle(QATheme.ink).lineLimit(2...5)
                            if item.verifiedBy.isEmpty {
                                Button {
                                    qa.updateChange(changeID) { $0.verifiedBy = HouseholdSync.shared.myDisplayName; $0.verifiedAt = QAWorkbookStore.stamp() }
                                } label: {
                                    HStack(spacing: 6) { Image(systemName: "checkmark.seal.fill"); Text("Verify & sign off") }
                                        .font(QATheme.sans(13, .bold)).foregroundStyle(.white)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(Capsule().fill(QATheme.pass))
                                }.buttonStyle(.plain)
                            } else {
                                Text("Verified by \(item.verifiedBy) · \(item.verifiedAt)")
                                    .font(QATheme.sans(11, .semibold)).foregroundStyle(QATheme.pass)
                            }
                        }.padding(14)
                    }
                }

                Button(role: .destructive) { qa.deleteChange(changeID); dismiss() } label: {
                    HStack(spacing: 6) { Image(systemName: "trash"); Text("Delete entry") }
                        .font(QATheme.sans(13, .semibold)).foregroundStyle(QATheme.fail)
                }.padding(.top, 6)
            }.padding(16)
        }
        .navigationTitle("Change").navigationBarTitleDisplayMode(.inline)
        .qaScreen()
        .sheet(item: $annotTarget) { t in ScreenshotAnnotator(changeID: changeID, imageName: t.name) }
    }

    private func codeRefCard(_ item: ChangeItem) -> some View {
        QACard {
            VStack(alignment: .leading, spacing: 6) {
                HStack { QALabel(text: "LIKELY CODE (for the AI)"); Spacer()
                    Button("Suggest from area") { qa.updateChange(changeID) { $0.codeRefs = QAWorkbookStore.codeHints(for: $0.section) } }
                        .font(QATheme.sans(11, .semibold)).tint(QATheme.brown)
                }
                if item.codeRefs.isEmpty {
                    Text("None yet — tap Suggest, or type the area above.").font(QATheme.sans(11)).foregroundStyle(QATheme.ink.opacity(0.5))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(item.codeRefs, id: \.self) { f in
                                HStack(spacing: 4) {
                                    Text(f).font(QATheme.sans(11, .semibold)).foregroundStyle(QATheme.brown)
                                    Button { qa.updateChange(changeID) { $0.codeRefs.removeAll { $0 == f } } } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(QATheme.brown.opacity(0.5)) }.buttonStyle(.plain)
                                }
                                .padding(.horizontal, 9).padding(.vertical, 5).background(Capsule().fill(QATheme.card))
                            }
                        }
                    }
                }
            }.padding(14)
        }
    }

    private var reproCard: some View {
        QACard {
            VStack(alignment: .leading, spacing: 10) {
                QALabel(text: "STEPS TO REPRODUCE")
                TextField("1. …\n2. …", text: bind(\.steps), axis: .vertical).font(QATheme.sans(13)).foregroundStyle(QATheme.ink).lineLimit(2...8)
                Divider().background(QATheme.underline.opacity(0.5))
                QALabel(text: "EXPECTED")
                TextField("What should happen", text: bind(\.expected), axis: .vertical).font(QATheme.sans(13)).foregroundStyle(QATheme.ink).lineLimit(1...4)
                QALabel(text: "ACTUAL")
                TextField("What actually happened", text: bind(\.actual), axis: .vertical).font(QATheme.sans(13)).foregroundStyle(QATheme.ink).lineLimit(1...4)
            }.padding(14)
        }
    }
    private func contextCard(_ c: QAContext) -> some View {
        QACard(fill: QATheme.tan) {
            VStack(alignment: .leading, spacing: 4) {
                QALabel(text: "CAPTURED CONTEXT")
                row("Screen", c.screen); row("Build", "\(c.build) · v\(c.version)"); row("Device", "\(c.device) · \(c.os)")
                if !c.household.isEmpty { row("Household", c.household) }
                if !c.capturedAt.isEmpty { row("When", c.capturedAt) }
                if !c.breadcrumbs.isEmpty {
                    Text("Trail: \(c.breadcrumbs.suffix(6).joined(separator: " › "))").font(QATheme.sans(10)).foregroundStyle(QATheme.ink.opacity(0.55)).padding(.top, 2)
                }
            }.padding(14)
        }
    }
    private func historyCard(_ item: ChangeItem) -> some View {
        QACard(outlined: true) {
            VStack(alignment: .leading, spacing: 4) {
                QALabel(text: "HISTORY")
                ForEach(Array(item.history.enumerated()), id: \.offset) { _, h in
                    Text(h).font(QATheme.sans(11)).foregroundStyle(QATheme.ink.opacity(0.7))
                }
            }.padding(14)
        }
    }
    private func row(_ k: String, _ v: String) -> some View {
        HStack(spacing: 8) {
            Text(k).font(QATheme.sans(10, .bold)).foregroundStyle(QATheme.ink.opacity(0.6)).frame(width: 74, alignment: .leading)
            Text(v).font(QATheme.sans(11)).foregroundStyle(QATheme.ink.opacity(0.85))
        }
    }

    private func statusChips(_ item: ChangeItem) -> some View {
        QAChips(ChangeStatus.allCases.map { $0.label }, selected: item.status.label) { label in
            if let s = ChangeStatus.allCases.first(where: { $0.label == label }) { qa.updateChange(changeID) { $0.status = s } }
        } colorFor: { label in ChangeStatus.allCases.first { $0.label == label }?.color ?? QATheme.brown }
    }
    private func severityChips(_ item: ChangeItem) -> some View {
        QAChips(["Critical", "Major", "Minor", "Idea"], selected: item.severity) { sev in
            qa.updateChange(changeID) { $0.severity = sev }
        } colorFor: { _ in QATheme.brown }
    }
    private func regBtn(_ title: String, _ status: ChangeStatus, _ item: ChangeItem) -> some View {
        Button { qa.updateChange(changeID) { $0.status = status } } label: {
            Text(title).font(QATheme.sans(13, .bold))
                .foregroundStyle(item.status == status ? Color.white : QATheme.ink.opacity(0.7))
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Capsule().fill(item.status == status ? status.color : QATheme.card))
        }.buttonStyle(.plain)
    }

    private func screenshotsSection(_ item: ChangeItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                QALabel(text: "SCREENSHOTS"); Spacer()
                PhotosPicker(selection: $pickerItems, maxSelectionCount: 6, matching: .images) {
                    HStack(spacing: 4) { Image(systemName: "paperclip"); Text("Attach") }
                        .font(QATheme.sans(12, .semibold)).foregroundStyle(QATheme.brown)
                }
            }
            if !item.screenshots.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(item.screenshots, id: \.self) { name in
                            if let ui = qa.screenshotImage(name) {
                                Button { annotTarget = AnnotTarget(name: name) } label: {
                                    Image(uiImage: ui).resizable().scaledToFill().frame(width: 92, height: 122)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                        .overlay(alignment: .bottomLeading) {
                                            let count = (qa.change(changeID)?.annotations.count ?? 0)
                                            if count > 0 { Text("\(count) 📍").font(QATheme.sans(9, .bold)).foregroundStyle(.white).padding(4).background(Capsule().fill(QATheme.fail)).padding(4) }
                                            else { Text("tap to mark").font(QATheme.sans(8, .semibold)).foregroundStyle(.white).padding(3).background(Capsule().fill(.black.opacity(0.4))).padding(4) }
                                        }
                                }.buttonStyle(.plain)
                                .overlay(alignment: .topTrailing) {
                                    Button { qa.removeScreenshot(changeID, name) } label: {
                                        Image(systemName: "xmark.circle.fill").font(.system(size: 18))
                                            .foregroundStyle(.white).shadow(radius: 2)
                                    }.buttonStyle(.plain).padding(4)
                                }
                            }
                        }
                    }
                }
            }
        }
        .onChange(of: pickerItems) { _, items in
            Task {
                for it in items { if let data = try? await it.loadTransferable(type: Data.self) { qa.attachScreenshot(changeID, data) } }
                pickerItems = []
            }
        }
    }
}

// MARK: - Correctness dashboard

struct ChangeDashboardView: View {
    @Environment(AppSession.self) private var session
    private var qa = QAWorkbookStore.shared
    @State private var lastRun = ""

    var body: some View {
        let h = qa.healthScore()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                scoreCard(h)
                QAExplainer(text: "One number for 'is the app in good shape?' It blends four things: how much you've tested (coverage), how much of that passed (pass quality), how many approved specs are built (spec completion), and how few serious bugs are open (stability). Higher is better; aim for 90+ before shipping.")
                bar("Testing coverage", h.coverage, "QA items marked")
                bar("Pass quality", h.passQuality, "of marked items passing")
                bar("Spec completion", h.specDone, "Running List implemented")
                bar("Stability", h.stability, "inverse of open criticals & regressions")

                QALabel(text: "TOP RISKS").padding(.top, 4)
                QAExplainer(text: "The things most likely to hurt a release. 'Self-check findings' come from an automatic scan of your saved data (blank names, duplicate IDs, etc.) — tap 'Run self-check' to refresh. Zero across the board is the goal before sign-off.")
                risk("Open criticals", h.openCriticals, QATheme.fail)
                risk("Regression failures", h.regressionFails, QATheme.fail)
                risk("Self-check findings", h.diagnosticsOpen, QATheme.review)

                Button { runCheck() } label: {
                    HStack(spacing: 8) { Image(systemName: "stethoscope"); Text("Run self-check now").font(QATheme.sans(14, .bold)); Spacer()
                        if !lastRun.isEmpty { Text(lastRun).font(QATheme.sans(11)).foregroundStyle(.white.opacity(0.8)) } }
                        .foregroundStyle(.white).padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 13).fill(QATheme.brown))
                }.buttonStyle(.plain)

                ShareLink(item: qa.changeMarkdown()) {
                    HStack(spacing: 8) { Image(systemName: "square.and.arrow.up"); Text("Share report for AI").font(QATheme.sans(14, .bold)); Spacer() }
                        .foregroundStyle(QATheme.brown).padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity).background(RoundedRectangle(cornerRadius: 13).fill(QATheme.card))
                }
            }.padding(16)
        }
        .qaScreen()
        .onAppear { qa.runDiagnostics(store: session.guestStore) }
    }

    private func runCheck() {
        let n = qa.runDiagnostics(store: session.guestStore)
        lastRun = n == 0 ? "no issues" : "\(n) found"
    }

    private func scoreCard(_ h: HealthScore) -> some View {
        QACard(fill: QATheme.tan) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle().stroke(QATheme.brown.opacity(0.2), lineWidth: 10).frame(width: 92, height: 92)
                    Circle().trim(from: 0, to: CGFloat(h.composite) / 100)
                        .stroke(scoreColor(h.composite), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 92, height: 92)
                    VStack(spacing: 0) {
                        Text("\(h.composite)").font(QATheme.serif(30)).foregroundStyle(QATheme.ink)
                        Text("/100").font(QATheme.sans(9)).foregroundStyle(QATheme.ink.opacity(0.5))
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("App Correctness").font(QATheme.serif(18)).foregroundStyle(QATheme.ink)
                    Text(h.grade).font(QATheme.sans(13, .bold)).foregroundStyle(scoreColor(h.composite))
                    Text("QA · Running List · defects · self-check").font(QATheme.sans(10)).foregroundStyle(QATheme.ink.opacity(0.55))
                }
                Spacer()
            }.padding(16)
        }
    }
    private func scoreColor(_ s: Int) -> Color { s >= 90 ? QATheme.pass : (s >= 75 ? QATheme.review : (s >= 55 ? QATheme.accent : QATheme.fail)) }

    private func bar(_ title: String, _ value: Double, _ sub: String) -> some View {
        QACard {
            VStack(alignment: .leading, spacing: 6) {
                HStack { Text(title).font(QATheme.sans(13, .semibold)).foregroundStyle(QATheme.ink); Spacer(); Text("\(Int(value * 100))%").font(QATheme.sans(13, .bold)).foregroundStyle(QATheme.brown) }
                QAProgressBar(value: value)
                Text(sub).font(QATheme.sans(10)).foregroundStyle(QATheme.ink.opacity(0.5))
            }.padding(14)
        }
    }
    private func risk(_ title: String, _ n: Int, _ color: Color) -> some View {
        QACard {
            HStack(spacing: 12) {
                Image(systemName: n == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill").foregroundStyle(n == 0 ? QATheme.pass : color)
                Text(title).font(QATheme.sans(13)).foregroundStyle(QATheme.ink)
                Spacer()
                Text("\(n)").font(QATheme.serif(17)).foregroundStyle(n == 0 ? QATheme.pass : color)
            }.padding(14)
        }
    }
}

// Simple horizontal chip row (QA-scoped; distinct from other views' FlowChips).
struct QAChips: View {
    let items: [String]
    let selected: String
    let onPick: (String) -> Void
    let colorFor: (String) -> Color
    init(_ items: [String], selected: String, onPick: @escaping (String) -> Void, colorFor: @escaping (String) -> Color) {
        self.items = items; self.selected = selected; self.onPick = onPick; self.colorFor = colorFor
    }
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(items, id: \.self) { label in
                    Button { onPick(label) } label: {
                        Text(label).font(QATheme.sans(12, .semibold))
                            .foregroundStyle(selected == label ? Color.white : QATheme.ink.opacity(0.65))
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Capsule().fill(selected == label ? colorFor(label) : QATheme.card))
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}
