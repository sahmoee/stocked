// QAModeView.swift
// ─────────────────────────────────────────────────────────────────────────────
// The QA hub. One screen, in one order, with one idea behind the layout:
//
//   VERDICT FIRST. Whatever is worst goes at the top, in a sentence, before any
//   raw data. A QA screen that opens on a wall of counters makes the reader do
//   the triage, and the reader is the person least equipped to do it — they were
//   testing a feature, not auditing a session.
//
//   THEN CONTROLS, THEN EVIDENCE. One switch that means "QA runs itself", the
//   settings that change how it behaves, and only then the six evidence
//   sections, every one collapsed by default. Nothing below the fold is
//   necessary to know whether the build is in trouble.
//
//   EMPTY STATES EXPLAIN THEMSELVES. "No run yet" tells you nothing. Every empty
//   section here says what would put something in it, so a section that stays
//   empty is a fact rather than a mystery.
//
//   ONE EXPORT. There used to be four share buttons producing four partial
//   reports. There is now one that produces everything, and per-section copies
//   for when you want just the one part.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
// Explicit, for `UIPasteboard` in the copy buttons. SwiftUI re-exports UIKit on
// iOS today, so this is belt-and-braces rather than strictly required — but the
// same assumption is exactly what broke QAHUD's `.autoconnect()`, which needed
// Combine imported by name. Naming the module you use costs nothing.
import UIKit

struct QAModeView: View {
    @Environment(AppSession.self) private var session
    @State private var recorder = QARecorder.shared
    @State private var runner = QABackgroundRunner.shared
    @State private var triage = QATriage.shared
    @State private var runtime = QARuntimeMonitor.shared
    @State private var tickets = QATicketStore.shared

    @State private var companion: String = ""
    @State private var loadingCompanion = false
    @State private var eventSearch = ""
    @State private var eventFilter: QAEventKind?
    @State private var showClearConfirm = false
    @State private var copied: String?

    @AppStorage(QAIssueReporterSettings.enabledKey) private var reporterEnabled = true
    @AppStorage(QAIssueReporterSettings.fingerKey) private var reporterFingers = 1
    @AppStorage(QAHUDSettings.enabledKey) private var hudEnabled = false
    @AppStorage(QAHUDSettings.positionKey) private var hudAtTop = false
    @AppStorage(QAShakeSettings.enabledKey) private var shakeEnabled = true

    // Build 74.
    @State private var runLog = QARunLog.shared
    @State private var syncQueue = QASyncQueue.shared
    @State private var sweep = QAAccessibilitySweep.shared
    @State private var memory = QAMemoryWatch.shared
    @State private var runName = ""

    private var store: GuestDataStore { session.guestStore }

    var body: some View {
        Form {
            if !QARecorder.isAvailable { unavailableSection }

            verdictSection
            searchSection
            controlSection

            if recorder.isEnabled {
                reporterSection
                sessionSection
                ticketSection
                runtimeSection
                processSection
                invariantSection
                diagnosticsSection
                crashSection
                eventSection
                bridgeSection
                toolSection
                runSection
                exportSection
            } else if QARecorder.isAvailable {
                Section {
                    Text("Turn on QA mode and use the app normally. It records what you open and what you try, times every flow, watches memory and frame timing, and checks that surfaces which must agree still do.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if recorder.previousSessionReport != nil { previousSessionSection }
            }

            checklistSection
        }
        .navigationTitle("QA")
        .qaScreen("Settings > QA")
        .onAppear {
            if recorder.isEnabled { runner.start(store: store, session: nil) }
        }
        .overlay(alignment: .bottom) { copiedToast }
        .confirmationDialog("Clear the whole session?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("Clear events, taps, processes and runtime", role: .destructive) {
                recorder.clear()
                QAProcessTracker.shared.clear()
                runtime.clear()
            }
        } message: {
            Text("Tickets are kept — they are the part worth keeping. Everything else resets.")
        }
    }

    // MARK: Search
    //
    // BUILD 74. Above everything, including the controls, because it is the only
    // control on this screen that answers a question rather than changing a
    // setting. The QA hub holds six kinds of record in six places — checks,
    // tickets, invariants, events, screens, findings — and the tester arriving
    // here already knows the word they are looking for. Making them remember
    // which of the six holds it is a filing-cabinet problem the app can solve.
    private var searchSection: some View {
        Section {
            NavigationLink {
                QASearchView()
            } label: {
                Label("Search all of QA", systemImage: "magnifyingglass")
            }
        } footer: {
            Text("One box across checks, tickets, invariants, screens, recorded events and published findings.")
        }
    }

    // MARK: Verdict

    private var unavailableSection: some View {
        Section {
            Label("QA is unavailable in this build", systemImage: "lock.fill")
                .font(.subheadline.weight(.medium))
            Text("It is on in debug and TestFlight builds only, so a shipped App Store binary cannot sit recording because a toggle was left on.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// The headline. Worst-first, in a sentence, above everything else.
    private var verdictSection: some View {
        Section {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: triage.verdictSymbol)
                    .font(.title2)
                    .foregroundStyle(triage.verdictTint)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(triage.verdict)
                        .font(.headline)
                        .foregroundStyle(triage.verdictTint)
                    Text(recorder.isEnabled ? recorder.headlineLine : "Not recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if recorder.isEnabled && !runtime.headline.isEmpty {
                        Text(runtime.headline)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 2)

            ForEach(triage.findings.prefix(6)) { f in
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: f.symbol)
                        .font(.caption)
                        .foregroundStyle(f.level.tint)
                        .frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.title)
                            .font(.subheadline.weight(.medium))
                        Text(f.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(f.source.uppercased())
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 1)
            }

            if triage.findings.count > 6 {
                NavigationLink {
                    QAFindingListView()
                } label: {
                    Label("All \(triage.findings.count) findings", systemImage: "list.bullet.rectangle")
                }
            }

            if recorder.isEnabled && triage.findings.isEmpty {
                Text("Nothing to report. No violated invariants, no failures, no freezes, no open tickets.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Verdict")
        } footer: {
            Text("Everything QA knows, ranked worst-first. Blockers are things that should stop a release; warnings cost someone time; notes are context. This is a reading of the sections below — it can never disagree with them.")
        }
    }

    // MARK: Controls

    private var controlSection: some View {
        Section {
            Toggle("Automate QA", isOn: Binding(
                get: { recorder.isEnabled && runner.autoPublish },
                set: { on in
                    recorder.isEnabled = on
                    runner.autoPublish = on
                    if on { runner.start(store: store, session: nil) }
                }))
            .disabled(!QARecorder.isAvailable)
            .tint(.green)

            Toggle("Record this session", isOn: Binding(
                get: { recorder.isEnabled },
                set: { on in
                    recorder.isEnabled = on
                    if on { runner.start(store: store, session: nil) }
                }))
            .disabled(!QARecorder.isAvailable)

            if recorder.isEnabled {
                Toggle("Publish findings automatically", isOn: Binding(
                    get: { runner.autoPublish },
                    set: { runner.autoPublish = $0 }))

                Picker("Stop recording after", selection: Binding(
                    get: { recorder.autoOffMinutes },
                    set: { recorder.autoOffMinutes = $0 })) {
                    Text("Never").tag(0)
                    Text("30 minutes").tag(30)
                    Text("2 hours").tag(120)
                    Text("8 hours").tag(480)
                }
                if let off = recorder.autoOffAt {
                    Text("Stops at \(off.formatted(date: .omitted, time: .shortened)).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Recording")
        } footer: {
            Text("Automate QA is the single switch: record, run the invariant suite on its own (launch, foreground, every two minutes, and after cooks, imports and syncs), and publish findings to the bridge. Survives relaunch until turned off. Nothing leaves the device unless publishing is on.")
        }
    }

    // MARK: Reporter + HUD

    private var reporterSection: some View {
        Section {
            Toggle("Press and hold to report", isOn: $reporterEnabled)
            if reporterEnabled {
                Picker("Fingers", selection: $reporterFingers) {
                    Text("One finger").tag(1)
                    Text("Two fingers").tag(2)
                }
                .pickerStyle(.segmented)
                Text(reporterFingers == 2
                     ? "Two fingers never collides with context menus or text selection. The safer choice on iPad and on menu-heavy screens."
                     : "One finger is quicker, but screens with context menus or selectable text will show those as well as the report sheet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("Shake to report", isOn: $shakeEnabled)
            if shakeEnabled {
                Text(QAShakeDetector.shared.isRunning
                     ? "Listening. Shake twice, quickly — \(QAShakeDetector.shared.shakeCount) so far this session."
                     : "Idle. The accelerometer only runs while QA mode is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Toggle("On-screen HUD", isOn: $hudEnabled)
            if hudEnabled {
                Picker("Position", selection: $hudAtTop) {
                    Text("Bottom").tag(false)
                    Text("Top").tag(true)
                }
                .pickerStyle(.segmented)
            }
        } header: {
            Text("Reporting")
        } footer: {
            Text("Press and hold anywhere in the app to file a ticket. The screen, your last forty steps, whatever was running or stalled, recent failures, violated invariants, memory, thermal state, connectivity and a screenshot are attached automatically — you type one sentence. The HUD is read-only: memory, worst frame hitch, failures and open tickets. It cannot be tapped and never takes a touch from the app. Shake to report covers the places press-and-hold cannot reach — inside a scroll, a drag, or a text field, where the gesture is already taken.")
        }
    }

    // MARK: Session

    private var sessionSection: some View {
        let tracker = QAProcessTracker.shared
        return Section {
            row("Running for", recorder.sessionDurationText)
            row("Screens visited", "\(recorder.screenCount)")
            row("Taps recorded", "\(recorder.tapTotal)")
            row("Actions attempted", "\(recorder.attemptCount)")
            row("Succeeded", "\(recorder.successCount)")
            row("Failures", "\(recorder.failureCount)", tint: recorder.failureCount > 0 ? .red : nil)
            row("Invariant violations", "\(recorder.violationCount)",
                tint: recorder.violationCount > 0 ? .red : nil)
            row("Invariant suite runs", "\(runner.runCount)",
                tint: runner.runCount == 0 ? .orange : nil)
            let stalled = tracker.stalled
            if !stalled.isEmpty {
                row("Stalled processes", "\(stalled.count)", tint: .orange)
            }
            let netTotal = runtime.networkCallCount
            if netTotal > 0 {
                let netFail = runtime.networkFailureCount
                let pct = Int(Double(netTotal - netFail) / Double(netTotal) * 100)
                row("Worker calls", "\(netTotal) · \(pct)% ok",
                    tint: netFail > 0 ? .orange : nil)
            }
            if recorder.attemptCount > 0 {
                row("Success rate", String(format: "%.0f%%", recorder.successRate * 100),
                    tint: recorder.successRate < 0.9 ? .orange : nil)
            }

            let dangling = recorder.danglingAttempts
            if !dangling.isEmpty {
                DisclosureGroup("\(dangling.count) unresolved · \(dangling.filter(\.isHung).count) hung") {
                    Text("Started and never reported success or failure. A spinner that never stops looks exactly like this.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(dangling.prefix(10)) { d in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.label).font(.caption)
                                Text(d.screen).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(d.ageText)
                                .font(.caption2.monospaced())
                                .foregroundStyle(d.isHung ? .red : .secondary)
                        }
                    }
                }
            }

            let dead = recorder.deadScreens
            if !dead.isEmpty {
                DisclosureGroup("\(dead.count) screen\(dead.count == 1 ? "" : "s") never tapped") {
                    Text("Visited but received no interaction. Either untested, or nothing on them responds to touch.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(dead, id: \.self) { s in
                        Text(s).font(.caption.monospaced())
                    }
                }
            }

            if !recorder.breadcrumbs.isEmpty {
                DisclosureGroup("Breadcrumb trail") {
                    Text("The last \(recorder.breadcrumbs.count) things that happened, newest first. This is what gets attached to a ticket.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(recorder.breadcrumbs.reversed(), id: \.self) { c in
                        Text(c).font(.caption2.monospaced())
                    }
                    copyButton("Copy trail", recorder.breadcrumbTrail)
                }
            }

            if recorder.previousSessionReport != nil { previousSessionRows }

            Button("Clear session", role: .destructive) { showClearConfirm = true }
        } header: {
            Text("This session")
        } footer: {
            Text("Taps are counted per screen, not logged individually — a twenty-minute session is thousands of taps and per-tap rows would flush the log. The counts are what prove a screen actually received interaction.")
        }
    }

    private var previousSessionSection: some View {
        Section {
            previousSessionRows
        } header: {
            Text("Previous session")
        } footer: {
            Text("Saved automatically whenever something failed and whenever QA was switched off, so a session that ended in a crash still has a report.")
        }
    }

    @ViewBuilder
    private var previousSessionRows: some View {
        if let snapshot = recorder.previousSessionReport {
            NavigationLink {
                QATextReportView(title: "Previous session", text: snapshot)
            } label: {
                Label("Previous session snapshot", systemImage: "clock.arrow.circlepath")
            }
            Button("Discard previous snapshot", role: .destructive) {
                recorder.clearPreviousSessionReport()
            }
        }
    }

    // MARK: Tickets

    private var ticketSection: some View {
        Section {
            NavigationLink {
                QATicketListView()
            } label: {
                HStack {
                    Label("Tickets", systemImage: "ticket")
                    Spacer()
                    if tickets.openCount > 0 {
                        Text("\(tickets.openCount) open")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(tickets.blockers.isEmpty ? .orange : .red)
                    } else {
                        Text("none").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            if !tickets.blockers.isEmpty {
                ForEach(tickets.blockers.prefix(3)) { t in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(t.number) \(t.title)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.red)
                        Text(t.context.screen).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            if !tickets.recurring.isEmpty {
                NavigationLink {
                    QARecurringTicketsView()
                } label: {
                    HStack {
                        Label("Seen more than once", systemImage: "repeat")
                        Spacer()
                        Text("\(tickets.recurring.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.orange)
                    }
                }
            }

            if !tickets.unsynced.isEmpty {
                Button {
                    Task { await tickets.publishUnsynced() }
                } label: {
                    Label("Sync \(tickets.unsynced.count) unsynced", systemImage: "arrow.up.circle")
                }
                .disabled(tickets.isSyncing)
            }
        } header: {
            Text("Tickets")
        } footer: {
            Text(tickets.tickets.isEmpty
                 ? "Nothing filed yet. Press and hold anywhere in the app to file one — it gets a number like STK-\(BuildConfig.buildNumber)-0001 and syncs with every other QA report."
                 : "\(tickets.tickets.count) filed this install · \(tickets.lastSyncOutcome)")
        }
    }

    // MARK: Runtime

    private var runtimeSection: some View {
        Section {
            row("Memory now", String(format: "%.0f MB", runtime.currentFootprintMB))
            row("Peak", String(format: "%.0f MB", runtime.peakFootprintMB),
                tint: runtime.peakFootprintMB > 800 ? .orange : nil)
            row("Growth this session", String(format: "%+.0f MB", runtime.memoryGrowthMB),
                tint: runtime.memoryGrowthMB > 250 ? .orange : nil)
            row("Thermal state", runtime.thermalName + (runtime.lowPower ? " · low power" : ""),
                tint: runtime.isThrottled ? .orange : nil)
            row("Free disk", String(format: "%.0f MB", runtime.freeDiskMB),
                tint: runtime.freeDiskMB < 500 && runtime.freeDiskMB > 0 ? .orange : nil)
            row("Network", runtime.online ? "online" : "offline",
                tint: runtime.online ? nil : .orange)

            if runtime.hitches.isEmpty {
                Text("No frame hitches over 120 ms. The main thread has not been blocked long enough to be visible.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                row("Worst frame hitch", String(format: "%.0f ms", runtime.worstHitchMs),
                    tint: runtime.severeHitchCount > 0 ? .red : .orange)
                DisclosureGroup("\(runtime.hitches.count) hitches · \(runtime.severeHitchCount) over a second") {
                    Text("A hitch is the gap between two frames. Over a second is watchdog range — iOS terminates apps for blocks like that, and those file their own ticket.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(runtime.hitchesByScreen.prefix(6))) { h in
                        HStack {
                            Text(h.screen).font(.caption)
                            Spacer()
                            Text("\(h.count)×").font(.caption2.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                    ForEach(runtime.hitches.suffix(12).reversed()) { h in
                        Text(h.line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(h.isSevere ? .red : .secondary)
                    }
                }
            }

            if !runtime.networkStats.isEmpty {
                DisclosureGroup("Network — \(runtime.networkCallCount) calls, \(runtime.networkFailureCount) failed") {
                    ForEach(runtime.networkStats.prefix(12)) { s in
                        Text(s.line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(s.failures > 0 ? .red : .secondary)
                    }
                }
            }

            copyButton("Copy runtime", runtime.exportText)
        } header: {
            Text("Runtime")
        } footer: {
            Text("Memory is phys_footprint — the number jetsam actually judges you on, not resident size. Sampled every five seconds; frame timing is watched continuously by a display link. All of it stops when recording stops.")
        }
    }

    // MARK: Processes

    private var processSection: some View {
        Section {
            let tracker = QAProcessTracker.shared
            row("Processes tracked", "\(tracker.records.count)")
            row("Running now", "\(tracker.running.count)")
            row("Failed", "\(tracker.failed.count)", tint: tracker.failed.isEmpty ? nil : .red)

            if tracker.records.isEmpty {
                Text("Nothing tracked yet. Network calls, Cook Now classification passes and any flow that opts in with one line appear here as soon as they run.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !tracker.stalled.isEmpty {
                DisclosureGroup("\(tracker.stalled.count) stalled") {
                    Text("Still running past two seconds. This is what a freeze looks like from the inside.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(tracker.stalled.prefix(8)) { r in
                        HStack {
                            Text(r.name).font(.caption)
                            Spacer()
                            Text(r.durationText).font(.caption2.monospaced()).foregroundStyle(.orange)
                        }
                    }
                }
            }

            let roll = tracker.rollups
            if !roll.isEmpty {
                let grand = roll.reduce(0.0) { $0 + $1.total }
                DisclosureGroup("Time by process") {
                    Text("Where the session's time went. The percentage is of all tracked time, which is the number that tells you what to optimise.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(roll.prefix(15)) { r in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(r.name).font(.caption)
                                Spacer()
                                Text("\(r.count)× · \(Int(r.averageMs)) ms avg")
                                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            if grand > 0 {
                                let share = r.total / grand
                                ProgressView(value: share)
                                    .tint(share > 0.4 ? .orange : .accentColor)
                                Text(String(format: "%.0f%% of tracked time", share * 100))
                                    .font(.system(size: 9)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }

            if !tracker.records.isEmpty {
                DisclosureGroup("Recent processes") {
                    ForEach(tracker.records.prefix(25)) { r in
                        Text(r.line)
                            .font(.caption2.monospaced())
                            .foregroundStyle(r.state == .failed ? .red : .secondary)
                    }
                }
                copyButton("Copy process log", tracker.exportText)
                Button("Clear processes", role: .destructive) { tracker.clear() }
            }
        } header: {
            Text("Processes & flows")
        } footer: {
            Text("Automatic. A process that begins and never ends is a spinner that never stops — those show as stalled, and they are the single most useful row on this screen.")
        }
    }

    // MARK: Invariants

    private var invariantSection: some View {
        Section {
            if recorder.invariantResults.isEmpty {
                Text(runner.isRunning
                     ? "Running…"
                     : "No run yet. They run at launch, on foreground, every two minutes, and after cooks, imports and syncs — or press the button below.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let newOnes = recorder.newViolations
            if !newOnes.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("\(newOnes.count) new since the last run", systemImage: "arrow.up.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.red)
                    ForEach(newOnes) { r in
                        Text(r.name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            let fixed = recorder.fixedSinceLastRun
            if !fixed.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Label("\(fixed.count) cleared since the last run", systemImage: "arrow.down.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                    ForEach(fixed, id: \.self) { name in
                        Text(name).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(recorder.invariantResults) { r in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Image(systemName: symbol(r.status))
                            .foregroundStyle(color(r.status))
                        Text(r.name).font(.subheadline.weight(.medium))
                        if r.critical && r.status == .violation {
                            Text("BLOCKER")
                                .font(.caption2.bold())
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.red.opacity(0.18), in: Capsule())
                                .foregroundStyle(.red)
                        }
                    }
                    Text(r.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
                Task { await runner.runNow(force: true) }
            } label: {
                Label(runner.isRunning ? "Running…" : "Run checks now", systemImage: "arrow.clockwise")
            }
            .disabled(runner.isRunning)

            if let last = recorder.lastInvariantRun {
                Text("Last run \(last.formatted(date: .omitted, time: .standard)) · \(runner.runCount) run\(runner.runCount == 1 ? "" : "s") this session")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } header: {
            Text("Invariants")
        } footer: {
            Text("These compare two surfaces that must agree. A violation is a bug in the app, not a test failure. Blocked means there was not enough data to judge — the message says what to add.")
        }
    }

    // MARK: Full diagnostics

    @State private var diagReport: QADiagnosticsReport?
    @State private var diagRunning = false
    @State private var diagUploadResult: String?

    private var diagnosticsSection: some View {
        Section {
            Button {
                guard !diagRunning else { return }
                diagRunning = true
                diagUploadResult = nil
                Task { @MainActor in
                    let report = await QAFullDiagnostics.run(store: store, session: nil)
                    diagReport = report
                    let stamp = ISO8601DateFormatter().string(from: report.startedAt)
                        .replacingOccurrences(of: ":", with: "-")
                    _ = await QASyncCoordinator.shared.mirrorLog(
                        report.exportText, name: "full-diagnostics-\(stamp).txt")
                    diagRunning = false
                }
            } label: {
                Label(diagRunning ? "Running full sweep…" : "Run full diagnostics",
                      systemImage: "stethoscope")
            }
            .disabled(diagRunning)

            if let report = diagReport {
                VStack(alignment: .leading, spacing: 3) {
                    Text(report.verdict)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(report.violationCount == 0 ? .green : .red)
                    Text("\(report.sections.count) areas · \(report.sections.flatMap(\.rows).count) checks · \(String(format: "%.1f", report.duration))s")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(report.sections) { sec in
                    DisclosureGroup {
                        ForEach(sec.rows) { r in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 7) {
                                    Image(systemName: symbol(r.status)).foregroundStyle(color(r.status))
                                    Text(r.name).font(.caption.weight(.medium))
                                }
                                Text(r.detail).font(.caption2).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    } label: {
                        HStack {
                            Text(sec.title).font(.subheadline)
                            Spacer()
                            let bad = sec.rows.filter { $0.status == .violation }.count
                            if bad > 0 {
                                Text("\(bad)").font(.caption2.bold()).foregroundStyle(.red)
                            } else {
                                Image(systemName: "checkmark").font(.caption2).foregroundStyle(.green)
                            }
                        }
                    }
                }
                copyButton("Copy report", report.exportText)
                Button {
                    Task { @MainActor in
                        do {
                            let ref = try await StockedDiagnosticsUploader.upload(session: session)
                            diagUploadResult = "Uploaded — reference \(ref)"
                        } catch { diagUploadResult = error.localizedDescription }
                    }
                } label: {
                    Label("Upload to support (STK- reference)", systemImage: "paperplane")
                }
                if let diagUploadResult {
                    Text(diagUploadResult).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Full diagnostics")
        } footer: {
            Text("One tap sweeps every layer: the invariant suite plus live Worker health, remote config, connectivity, sync, notification budget, data integrity, storage, and the cook-session record.")
        }
    }

    // MARK: Crashes

    private var crashSection: some View {
        Section {
            let log = DiagnosticsMonitor.shared.currentLog()
            let crashes = log.split(separator: "\n").filter { $0.contains("CRASH") }.count
            let hangs   = log.split(separator: "\n").filter { $0.contains("HANG") || $0.contains("hang") }.count
            row("Crashes recorded", "\(crashes)", tint: crashes > 0 ? .red : nil)
            row("Hang reports", "\(hangs)", tint: hangs > 0 ? .orange : nil)
            if log.isEmpty {
                Text("No MetricKit diagnostics on this device — that is the good outcome, not a missing feature.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                NavigationLink {
                    QATextReportView(title: "Device log", text: log)
                } label: {
                    Label("View device log", systemImage: "doc.text.magnifyingglass")
                }
            }
        } header: {
            Text("Crashes & device log")
        } footer: {
            Text("MetricKit crash and hang diagnostics, delivered by iOS up to a day after the event. New entries appear automatically as failures in the event feed and ride along in every exported or published report.")
        }
    }

    // MARK: Events

    private var eventSection: some View {
        Section {
            if recorder.events.isEmpty {
                Text("Nothing recorded yet. Move around the app — screens report themselves, and anything that can fail reports both the attempt and the outcome.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                TextField("Search events", text: $eventSearch)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()

                Picker("Kind", selection: $eventFilter) {
                    Text("All \(recorder.events.count)").tag(QAEventKind?.none)
                    ForEach(QAEventKind.allCases, id: \.self) { k in
                        Text("\(k.title) \(recorder.count(of: k))").tag(QAEventKind?.some(k))
                    }
                }
                .pickerStyle(.menu)

                let shown = recorder.events(kind: eventFilter, search: eventSearch)
                if shown.isEmpty {
                    Text("No events match.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(shown.suffix(60).reversed()) { e in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: e.kind.symbol)
                            .font(.caption)
                            .foregroundStyle(color(for: e.kind))
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.label).font(.caption)
                            Text(e.detail.isEmpty ? e.screen : "\(e.screen) — \(e.detail)")
                                .font(.caption2).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if shown.count > 60 {
                    Text("Showing the last 60 of \(shown.count).")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Event feed")
        } footer: {
            Text("Capped at 600 events — a session running for hours with an unbounded log is a memory leak with a friendly name.")
        }
    }

    // MARK: Bridge

    private var bridgeSection: some View {
        Section {
            Button {
                Task {
                    await runner.publish()
                    await tickets.publishUnsynced()
                }
            } label: {
                Label("Publish everything now", systemImage: "arrow.up.circle")
            }
            row("Last publish", runner.lastPublishOutcome)
            row("Tickets", tickets.lastSyncOutcome)

            Button {
                Task { await loadCompanion() }
            } label: {
                Label(loadingCompanion ? "Loading…" : "View QA app findings",
                      systemImage: "arrow.down.circle")
            }
            .disabled(loadingCompanion)
            if !companion.isEmpty {
                Text(companion).font(.caption.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        } header: {
            Text("QA bridge")
        } footer: {
            Text("Publishes this device's health report and every unsynced ticket to the Worker, and reads the companion app's latest suite results back. Requires the /qa routes deployed and a Worker key in this build.")
        }
    }

    // MARK: Tools
    //
    // BUILD 74. Four probes that each answer a question the rest of the hub
    // cannot, kept together rather than scattered so the hub does not grow a
    // seventh evidence section every build. Each is a NavigationLink with its
    // headline verdict on the row, so the section is readable without opening
    // anything.
    private var toolSection: some View {
        Section {
            NavigationLink {
                QAMemoryWatchView()
            } label: {
                HStack {
                    Label("Memory over time", systemImage: "chart.line.uptrend.xyaxis")
                    Spacer()
                    Text(memory.shape.title)
                        .font(.caption)
                        .foregroundStyle(memory.shape.tint)
                }
            }

            NavigationLink {
                QAAccessibilitySweepView()
            } label: {
                HStack {
                    Label("Accessibility sweep", systemImage: "figure.walk.circle")
                    Spacer()
                    if sweep.hasRun {
                        Text(sweep.issues.isEmpty ? "clean" : "\(sweep.issues.count)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(sweep.issues.isEmpty ? Color.stockedGreen : Color.stockedWarning)
                    } else {
                        Text("not run").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            NavigationLink {
                QASyncQueueView()
            } label: {
                HStack {
                    Label("Sync queue", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if syncQueue.attempts.isEmpty {
                        Text("idle").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("\(syncQueue.failures.count) failed")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(syncQueue.failures.isEmpty ? Color.stockedGreen : .red)
                    }
                }
            }
        } header: {
            Text("Tools")
        } footer: {
            Text("Memory over time answers whether a session grows and which screens grow it. The sweep walks the live view tree for controls VoiceOver cannot name and tap targets under 44pt. The sync queue keeps every destination's reply instead of the one line the last sync left behind.")
        }
    }

    // MARK: Test runs
    //
    // BUILD 74. Everything else in the hub is scoped to "this install" or "this
    // session", neither of which is what a tester actually does. A tester does a
    // pass: half an hour against one build with one thing in mind. Naming that
    // span turns "STK-74-0007" into "the seventh thing found during the shopping
    // list pass on 4.18", which is the sentence someone reading it later needs.
    private var runSection: some View {
        Section {
            if let run = runLog.current {
                VStack(alignment: .leading, spacing: 3) {
                    Text(run.name).font(.system(size: 14, weight: .semibold))
                    Text(run.line).font(.caption).foregroundStyle(.secondary)
                }
                Button(role: .destructive) {
                    runLog.end()
                } label: {
                    Label("Finish this run", systemImage: "stop.circle")
                }
            } else {
                HStack {
                    TextField("What are you testing?", text: $runName)
                    Button("Start") {
                        runLog.start(name: runName)
                        runName = ""
                    }
                    .buttonStyle(.borderless)
                }
            }

            NavigationLink {
                QARunLogView()
            } label: {
                HStack {
                    Label("Test runs", systemImage: "list.bullet.rectangle")
                    Spacer()
                    Text(runLog.runs.isEmpty ? "none" : "\(runLog.runs.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Test runs")
        } footer: {
            Text(runLog.isRunning
                 ? "Every ticket filed and every check verdict changed from now until you finish is attached to this run."
                 : "Optional. Start one before a pass and every ticket and verdict that follows is grouped under it, with its own export.")
        }
    }

    // MARK: Export

    private var exportSection: some View {
        Section {
            ShareLink(item: recorder.fullExportText) {
                Label("Share full QA report", systemImage: "square.and.arrow.up")
            }
            copyButton("Copy full QA report", recorder.fullExportText)
            NavigationLink {
                QATextReportView(title: "Full QA report", text: recorder.fullExportText)
            } label: {
                Label("Read it here", systemImage: "doc.text.magnifyingglass")
            }
        } header: {
            Text("Export")
        } footer: {
            Text("One report with everything: triage, tickets, runtime, processes, invariants, taps, crashes, breadcrumbs, the event log, and the previous session's snapshot if there is one. The per-section copy buttons above are for when you only want one part.")
        }
    }

    private var checklistSection: some View {
        Section {
            // Build 74: `StockedQAHomeView`, not `StockedQAGateView`. The gate has
            // already been passed to be standing here, and the gated variant
            // carries its own NavigationStack — pushing it produced a stack inside
            // a stack and a second passcode pane for a session already unlocked.
            NavigationLink { StockedQAHomeView() } label: {
                Label("Release checklist", systemImage: "checklist")
            }
        } footer: {
            Text("The code-gated manual checkbook. Publishes to the same QA bridge as everything above.")
        }
    }

    // MARK: Helpers

    private func loadCompanion() async {
        loadingCompanion = true
        defer { loadingCompanion = false }
        do {
            guard let report = try await QAReportTransport.fetchCompanionFindings() else {
                companion = "Bridge is live but has no companion report stored yet."
                return
            }
            var lines: [String] = []
            if let app = report["app"] as? [String: Any] {
                lines.append("QA app \(app["version"] ?? "?")")
            }
            if let suites = report["suites"] as? [String: Any] {
                for (name, raw) in suites.sorted(by: { $0.key < $1.key }) {
                    guard let s = raw as? [String: Any] else { continue }
                    lines.append("\(name): pass \(s["pass"] ?? 0) · warn \(s["warn"] ?? 0) · fail \(s["fail"] ?? 0) · skipped \(s["skipped"] ?? 0)")
                }
            }
            if let at = report["generatedAt"] as? String { lines.append("generated \(at)") }
            companion = lines.isEmpty ? "Report received but empty." : lines.joined(separator: "\n")
        } catch {
            companion = "Could not reach the bridge: \(error.localizedDescription)"
        }
    }

    private func copyButton(_ label: String, _ text: String) -> some View {
        Button {
            UIPasteboard.general.string = text
            withAnimation { copied = label }
            Task {
                try? await Task.sleep(for: .seconds(1.6))
                withAnimation { copied = nil }
            }
        } label: {
            Label(label, systemImage: "doc.on.doc")
        }
    }

    @ViewBuilder
    private var copiedToast: some View {
        if let copied {
            Text("\(copied) — copied")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.bottom, 24)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func row(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(tint ?? .secondary)
        }
    }

    private func symbol(_ s: QAInvariantStatus) -> String {
        switch s {
        case .ok: return "checkmark.circle.fill"
        case .violation: return "xmark.octagon.fill"
        case .blocked: return "minus.circle"
        }
    }
    private func color(_ s: QAInvariantStatus) -> Color {
        switch s {
        case .ok: return .green
        case .violation: return .red
        case .blocked: return .gray
        }
    }
    private func color(for k: QAEventKind) -> Color {
        switch k {
        case .screen: return .secondary
        case .attempt: return .blue
        case .success: return .green
        case .failure: return .orange
        case .violation: return .red
        case .note: return .secondary
        }
    }
}

// MARK: - Findings list

struct QAFindingListView: View {
    @State private var triage = QATriage.shared

    var body: some View {
        List {
            ForEach(triage.findings) { f in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Image(systemName: f.symbol).foregroundStyle(f.level.tint)
                        Text(f.title).font(.subheadline.weight(.medium))
                    }
                    Text(f.detail)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(f.source.uppercased())
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.vertical, 2)
            }
            if triage.findings.isEmpty {
                ContentUnavailableView("Nothing flagged", systemImage: "checkmark.seal.fill",
                                       description: Text("No violated invariants, no failures, no freezes, no open tickets."))
            }
        }
        .navigationTitle(triage.verdict)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: triage.exportText) { Image(systemName: "square.and.arrow.up") }
        }
    }
}

// MARK: - Plain text report viewer

/// Shared by the device log, the previous-session snapshot and the full export,
/// so all three scroll, select, share and read the same way.
struct QATextReportView: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Empty." : text)
                .font(.system(size: 11, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(16)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                ShareLink(item: text) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
}
