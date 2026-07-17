// QAWorkbookViews.swift — the workbook screens shown inside the floating panel:
// contents (build info + sections), a section's tests, and the test/workflow page.
// Reproduces the PDF layout in the paper theme.

import SwiftUI

// MARK: - Panel (framed container with header + internal navigation)

struct QAWorkbookPanel: View {
    @Environment(AppSession.self) private var session
    private var qa = QAWorkbookStore.shared

    private var panelTitle: (String, String) {
        switch qa.mode {
        case .runningList: return ("RUNNING LIST", "Living implementation specs")
        case .changes:     return ("THINGS TO CHANGE", "Change log & regression")
        case .dashboard:   return ("CORRECTNESS", "Health & self-check")
        default:           return ("STOCKED QA", "Workbook")
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch qa.mode {
                case .chooser:     QAModeChooser()
                case .qa:          QAContentsView()
                case .runningList: RLListView()
                case .changes:     ChangeListView()
                case .dashboard:   ChangeDashboardView()
                }
            }
            .background(QATheme.page)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(panelTitle.0).font(QATheme.serif(15)).foregroundStyle(QATheme.ink)
                        Text(panelTitle.1).font(QATheme.sans(10)).foregroundStyle(QATheme.accent)
                    }
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button { qa.closeAndSync(store: session.guestStore) } label: {
                        Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(QATheme.pass)
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if qa.mode != .chooser {
                        Button { qa.backToChooser() } label: {
                            Image(systemName: "rectangle.2.swap").font(.system(size: 17)).foregroundStyle(QATheme.brown)
                        }
                    }
                    Button { qa.minimize() } label: {
                        Image(systemName: "minus.circle.fill").font(.system(size: 20)).foregroundStyle(QATheme.brown)
                    }
                }
            }
            .toolbarBackground(QATheme.headerTan, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        .tint(QATheme.brown)
    }
}

// MARK: - Chooser (asked after entering the code)

struct QAModeChooser: View {
    private var qa = QAWorkbookStore.shared
    var body: some View {
        VStack(spacing: 16) {
            Text("STOCKED").font(QATheme.serif(30)).foregroundStyle(QATheme.ink).padding(.top, 30)
            Text("Choose a workbook").font(QATheme.sans(14)).foregroundStyle(QATheme.accent).padding(.bottom, 4)
            QAExplainer(text: "This hidden area is for checking the app is correct. QA = a big test checklist. Running List = approved features still to build. Things to Change = the bug/change log (fed automatically when you fail a test or shake to report). Correctness = a health score + auto self-check. Everything syncs to your household and exports for an AI to read.").padding(.horizontal, 4).padding(.bottom, 4)
            choice("Stocked QA", "\(qa.content.tests.count) tests · quality assurance", "checklist") { qa.choose(.qa) }
            choice("Living Running List", "\(qa.rlContent.entries.count) approved implementation specs", "list.bullet.rectangle.portrait") { qa.choose(.runningList) }
            choice("Things to Change", "\(qa.changeCounts().open) open \u{00B7} \(qa.changeCounts().impl) to verify", "wrench.and.screwdriver") { qa.choose(.changes) }
            choice("Correctness Report", "Health score \u{00B7} self-check \u{00B7} risks", "checkmark.seal") { qa.choose(.dashboard) }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .qaScreen()
    }
    private func choice(_ title: String, _ subtitle: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 24)).foregroundStyle(.white)
                    .frame(width: 54, height: 54).background(RoundedRectangle(cornerRadius: 14).fill(QATheme.brown))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(QATheme.serif(18)).foregroundStyle(QATheme.ink)
                    Text(subtitle).font(QATheme.sans(12)).foregroundStyle(QATheme.ink.opacity(0.6))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(QATheme.brown.opacity(0.5))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 18).fill(QATheme.card))
        }.buttonStyle(.plain)
    }
}

// MARK: - Running List (spec browser)

struct RLListView: View {
    private var qa = QAWorkbookStore.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                let p = qa.rlProgress()
                QACard(fill: QATheme.tan) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Living Running List").font(QATheme.serif(20)).foregroundStyle(QATheme.ink)
                        Text("Approved changes & future work").font(QATheme.sans(12)).foregroundStyle(QATheme.ink.opacity(0.6))
                        QAProgressBar(value: p.total == 0 ? 0 : Double(p.done)/Double(p.total)).padding(.top, 4)
                        Text("\(p.done)/\(p.total) implemented").font(QATheme.sans(11)).foregroundStyle(QATheme.ink.opacity(0.6))
                    }.padding(16)
                }
                ForEach(qa.rlSections, id: \.self) { sec in
                    QALabel(text: sec.uppercased()).padding(.top, 4)
                    ForEach(qa.rlEntries(in: sec)) { e in
                        NavigationLink { RLEntryView(entry: e) } label: { rlRow(e) }.buttonStyle(.plain)
                    }
                }
            }.padding(16)
        }
        .qaScreen()
    }
    private func rlRow(_ e: RLEntry) -> some View {
        let done = qa.rlState(e.id).implemented
        return QACard {
            HStack(spacing: 12) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle").font(.system(size: 18))
                    .foregroundStyle(done ? QATheme.pass : QATheme.brown.opacity(0.4))
                VStack(alignment: .leading, spacing: 2) {
                    Text(e.id).font(QATheme.sans(10, .bold)).foregroundStyle(QATheme.accent)
                    Text(e.title).font(QATheme.serif(14)).foregroundStyle(QATheme.ink)
                }
                Spacer()
                Text(e.priority).font(QATheme.sans(10, .semibold)).foregroundStyle(QATheme.brown)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(QATheme.brown.opacity(0.5))
            }.padding(14)
        }
    }
}

struct RLEntryView: View {
    let entry: RLEntry
    private var qa = QAWorkbookStore.shared
    init(entry: RLEntry) { self.entry = entry }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                QACard(fill: QATheme.headerTan) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(entry.id).font(QATheme.sans(11, .bold)).foregroundStyle(QATheme.accent)
                        Text(entry.title).font(QATheme.serif(20)).foregroundStyle(QATheme.ink)
                        HStack(spacing: 8) { tag(entry.status); if !entry.priority.isEmpty { tag("Priority: \(entry.priority)") } }
                    }.padding(16)
                }
                QACard {
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(get: { qa.rlState(entry.id).implemented }, set: { v in qa.rlUpdate(entry.id) { $0.implemented = v } })) {
                            Text("Implemented").font(QATheme.sans(14, .semibold)).foregroundStyle(QATheme.ink)
                        }.tint(QATheme.pass)
                        QALabel(text: "NOTE")
                        TextField("Implementation notes", text: Binding(get: { qa.rlState(entry.id).note }, set: { v in qa.rlUpdate(entry.id) { $0.note = v } }), axis: .vertical)
                            .font(QATheme.sans(13)).foregroundStyle(QATheme.ink).lineLimit(2...5)
                    }.padding(14)
                }
                para("INTENT", entry.intent)
                para("PRODUCT VISION", entry.vision)
                bulletList("USER EXPERIENCE", entry.ux)
                bulletList("FUNCTIONAL & BUSINESS LOGIC", entry.logic)
                bulletList("CONNECTED SYSTEMS", entry.connected)
                bulletList("EDGE CASES & RECOVERY", entry.edge)
                bulletList("ACCEPTANCE CRITERIA", entry.acceptance)
            }.padding(16)
        }
        .navigationTitle(entry.id).navigationBarTitleDisplayMode(.inline)
        .qaScreen()
    }

    private func tag(_ t: String) -> some View {
        Text(t).font(QATheme.sans(11, .semibold)).foregroundStyle(.white)
            .padding(.horizontal, 9).padding(.vertical, 4).background(Capsule().fill(QATheme.brown))
    }
    @ViewBuilder private func para(_ label: String, _ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                QALabel(text: label)
                Text(text).font(QATheme.sans(13)).foregroundStyle(QATheme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private func bulletList(_ label: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                QALabel(text: label)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(QATheme.brown.opacity(0.6)).frame(width: 5, height: 5).padding(.top, 6)
                        Text(item).font(QATheme.sans(13)).foregroundStyle(QATheme.ink.opacity(0.85)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - Contents (build info + section map with progress)

struct QAContentsView: View {
    private var qa = QAWorkbookStore.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                buildInfoCard
                QALabel(text: "WORKBOOK MAP").padding(.top, 4)
                ForEach(qa.sections, id: \.name) { s in
                    NavigationLink { QASectionView(section: s) } label: { sectionRow(s) }.buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .qaScreen()
    }

    private var buildInfoCard: some View {
        QACard(fill: QATheme.tan) {
            VStack(alignment: .leading, spacing: 10) {
                Text("STOCKED").font(QATheme.serif(26)).foregroundStyle(QATheme.ink)
                Text("Quality Assurance Workbook").font(QATheme.serif(14)).foregroundStyle(QATheme.accent)
                field("BUILD", \.build); field("VERSION", \.version); field("TESTER", \.tester)
                field("DATE", \.date); field("TESTING STARTED", \.started); field("TESTING COMPLETED", \.completed)
                QAProgressBar(value: qa.overallProgress()).padding(.top, 6)
                Text("\(Int(qa.overallProgress() * 100))% complete").font(QATheme.sans(11)).foregroundStyle(QATheme.ink.opacity(0.6))
            }
            .padding(16)
        }
    }
    private func field(_ label: String, _ key: WritableKeyPath<QABuildInfo, String>) -> some View {
        HStack(spacing: 10) {
            Text(label).font(QATheme.sans(10, .bold)).foregroundStyle(QATheme.ink.opacity(0.7)).frame(width: 120, alignment: .leading)
            QAUnderlineField(placeholder: "", text: Binding(get: { qa.state.build[keyPath: key] }, set: { qa.state.build[keyPath: key] = $0; qa.save() }))
        }
    }

    private func sectionRow(_ s: QASectionInfo) -> some View {
        let p = qa.progress(section: s.name)
        return QACard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(s.name).font(QATheme.serif(15)).foregroundStyle(QATheme.ink)
                    Text(s.description).font(QATheme.sans(11)).foregroundStyle(QATheme.ink.opacity(0.55)).lineLimit(2)
                    QAProgressBar(value: p.total == 0 ? 0 : Double(p.done)/Double(p.total)).frame(width: 160).padding(.top, 2)
                }
                Spacer()
                Text("\(p.done)/\(p.total)").font(QATheme.sans(12, .semibold)).foregroundStyle(QATheme.brown)
                Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(QATheme.brown.opacity(0.5))
            }
            .padding(14)
        }
    }
}

// MARK: - Section (list of tests)

struct QASectionView: View {
    let section: QASectionInfo
    private var qa = QAWorkbookStore.shared
    init(section: QASectionInfo) { self.section = section }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                QACard(fill: QATheme.headerTan) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(section.name).font(QATheme.serif(20)).foregroundStyle(QATheme.ink)
                        Text(section.description).font(QATheme.sans(12)).foregroundStyle(QATheme.ink.opacity(0.6))
                        if let e = section.eli5 { QAExplainer(text: e) }
                    }.padding(16)
                }
                ForEach(qa.tests(in: section.name)) { t in
                    NavigationLink { QATestView(test: t) } label: { testRow(t) }.buttonStyle(.plain)
                }
            }.padding(16)
        }
        .navigationTitle(section.name).navigationBarTitleDisplayMode(.inline)
        .qaScreen()
    }
    private func testRow(_ t: QATest) -> some View {
        let ts = qa.testState(t.id)
        let marked = t.isWorkflow ? (ts.overall != .none ? 1 : 0) : ts.items.values.filter { $0.mark != .none }.count
        let total = t.isWorkflow ? 1 : t.checklist.count
        return QACard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.id).font(QATheme.sans(10, .bold)).foregroundStyle(QATheme.accent)
                    Text(t.title).font(QATheme.serif(14)).foregroundStyle(QATheme.ink)
                }
                Spacer()
                Text("\(marked)/\(total)").font(QATheme.sans(11, .semibold)).foregroundStyle(QATheme.brown)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(QATheme.brown.opacity(0.5))
            }.padding(14)
        }
    }
}

// MARK: - Test page (checklist) / Workflow page

struct QATestView: View {
    let test: QATest
    private var qa = QAWorkbookStore.shared
    init(test: QATest) { self.test = test }

    private func binding<T>(_ key: WritableKeyPath<QATestState, T>) -> Binding<T> {
        Binding(get: { qa.testState(test.id)[keyPath: key] },
                set: { v in qa.update(test.id) { $0[keyPath: key] = v } })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                QACard(fill: QATheme.headerTan) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(test.id).font(QATheme.sans(11, .bold)).foregroundStyle(QATheme.accent)
                        Text(test.title).font(QATheme.serif(20)).foregroundStyle(QATheme.ink)
                    }.padding(16)
                }

                testInAppButton

                if !test.purpose.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        QALabel(text: "PURPOSE"); Text(test.purpose).font(QATheme.sans(13)).foregroundStyle(QATheme.ink.opacity(0.85))
                    }
                }

                if test.isWorkflow { workflowBody } else { checklistBody }

                notesFooter
            }.padding(16)
        }
        .navigationTitle(test.id).navigationBarTitleDisplayMode(.inline)
        .qaScreen()
    }

    // "Test in App" — jump to the live area this test covers (or just minimize),
    // exercise it in real time, then tap the bubble to return and mark results.
    private var testInAppButton: some View {
        let mapsToTab = QAWorkbookStore.tab(for: test.section) != nil
        return Button { qa.testInApp(section: test.section) } label: {
            HStack(spacing: 8) {
                Image(systemName: "arrow.up.forward.app.fill").font(.system(size: 15, weight: .semibold))
                Text(mapsToTab ? "Test in App" : "Minimize to Test")
                    .font(QATheme.sans(14, .bold))
                Spacer()
                Text(mapsToTab ? "opens \((test.section ?? "").capitalized)" : "tap bubble to return")
                    .font(QATheme.sans(11)).foregroundStyle(.white.opacity(0.8))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 13).fill(QATheme.brown))
        }
        .buttonStyle(.plain)
    }

    private var checklistBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            QALabel(text: "CHECKLIST").padding(.bottom, 4)
            QAExplainer(text: "Mark each line as you test it. P = Pass (works). F = Fail (broken — this auto-creates a 'Things to Change' entry). R = Review (unsure, needs a second look). N = N/A (doesn't apply to this build). Add a ticket # or quick note when something's off. You can skip lines that clearly don't apply by marking N.", label: "ELI5: how to mark")
                .padding(.bottom, 8)
            ForEach(Array(test.checklist.enumerated()), id: \.offset) { idx, item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(item).font(QATheme.sans(14)).foregroundStyle(QATheme.ink).frame(maxWidth: .infinity, alignment: .leading)
                        QAMarkPicker(mark: qa.itemState(test.id, idx).mark) { qa.setMark(test.id, idx, $0) }
                    }
                    HStack(spacing: 12) {
                        QAUnderlineField(placeholder: "Ticket", text: Binding(get: { qa.itemState(test.id, idx).ticket }, set: { qa.setTicket(test.id, idx, $0) }), width: 90)
                        QAUnderlineField(placeholder: "Quick note", text: Binding(get: { qa.itemState(test.id, idx).note }, set: { qa.setNote(test.id, idx, $0) }))
                    }
                }
                .padding(.vertical, 10)
                Divider().background(QATheme.underline.opacity(0.5))
            }
        }
    }

    private var workflowBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !test.steps.isEmpty {
                QALabel(text: "FLOW PATH")
                Text(test.steps.joined(separator: "  →  ")).font(QATheme.sans(13, .medium)).foregroundStyle(QATheme.brown)
            }
            if !test.checklist.isEmpty {
                QALabel(text: "CERTIFICATION CHECKLIST")
                ForEach(Array(test.checklist.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 10) {
                        Button { qa.setMark(test.id, idx, .pass) } label: {
                            Image(systemName: qa.itemState(test.id, idx).mark == .pass ? "checkmark.square.fill" : "square")
                                .font(.system(size: 18)).foregroundStyle(qa.itemState(test.id, idx).mark == .pass ? QATheme.pass : QATheme.brown.opacity(0.5))
                        }.buttonStyle(.plain)
                        Text(item).font(QATheme.sans(14)).foregroundStyle(QATheme.ink)
                    }.padding(.vertical, 3)
                }
            }
            if !test.flowExperience.isEmpty {
                QALabel(text: "FLOW EXPERIENCE").padding(.top, 4)
                QAExplainer(text: "Beyond 'does it work' — does it feel good? Smooth, fast, clear, no dead-ends or confusing moments. Check these while walking the whole flow. Skip if: you're only verifying it functions, not polishing feel.")
                ForEach(Array(test.flowExperience.enumerated()), id: \.offset) { idx, item in
                    HStack(spacing: 10) {
                        Button { qa.update(test.id) { $0.flowExp[idx] = !($0.flowExp[idx] ?? false) } } label: {
                            Image(systemName: (qa.testState(test.id).flowExp[idx] ?? false) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 17)).foregroundStyle((qa.testState(test.id).flowExp[idx] ?? false) ? QATheme.pass : QATheme.brown.opacity(0.5))
                        }.buttonStyle(.plain)
                        Text(item).font(QATheme.sans(14)).foregroundStyle(QATheme.ink)
                    }.padding(.vertical, 2)
                }
            }
            HStack(spacing: 8) {
                QALabel(text: "OVERALL")
                QAMarkPicker(mark: qa.testState(test.id).overall) { m in qa.update(test.id) { $0.overall = ($0.overall == m ? .none : m) } }
            }.padding(.top, 6)
        }
    }

    private var notesFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            QACard(outlined: true) {
                VStack(alignment: .leading, spacing: 6) {
                    QALabel(text: "NOTES")
                    TextField("", text: binding(\.notes), axis: .vertical).font(QATheme.sans(13)).foregroundStyle(QATheme.ink).lineLimit(3...6)
                }.padding(14)
            }
            QACard(fill: QATheme.tan) {
                VStack(alignment: .leading, spacing: 6) {
                    QALabel(text: "PARKING LOT")
                    TextField("Park unrelated ideas here", text: binding(\.parkingLot), axis: .vertical).font(QATheme.sans(13)).foregroundStyle(QATheme.ink).lineLimit(2...5)
                    QAExplainer(text: "A place to jot ideas or bugs that pop into your head mid-test but aren't about this screen — so you don't lose them or go down a rabbit hole. Skip if: nothing unrelated came up.")
                }.padding(14)
            }
            HStack(spacing: 10) {
                Text("RESUME HERE").font(QATheme.sans(10, .bold)).foregroundStyle(QATheme.ink.opacity(0.7))
                QAUnderlineField(placeholder: "", text: binding(\.resumeHere))
            }
            QAExplainer(text: "A bookmark for where you stopped, so you (or a teammate) can pick testing back up later without redoing it. Skip if: you finished this section in one sitting.")
            HStack(spacing: 10) {
                Text("SEVERITY").font(QATheme.sans(10, .bold)).foregroundStyle(QATheme.ink.opacity(0.7))
                ForEach(["Critical", "Major", "Minor", "Idea"], id: \.self) { sev in
                    Button { qa.update(test.id) { $0.severity = ($0.severity == sev ? "" : sev) } } label: {
                        Text(sev).font(QATheme.sans(12, .semibold))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .foregroundStyle(qa.testState(test.id).severity == sev ? Color.white : QATheme.ink.opacity(0.6))
                            .background(Capsule().fill(qa.testState(test.id).severity == sev ? QATheme.brown : QATheme.tan.opacity(0.5)))
                    }.buttonStyle(.plain)
                }
            }
            QAExplainer(text: "Severity = how bad it is if this breaks. Critical = blocks release or loses data. Major = an important feature is broken. Minor = cosmetic or rare. Idea = not a bug, a suggestion. This decides what gets fixed first.")
        }
    }
}
