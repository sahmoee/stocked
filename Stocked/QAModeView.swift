// QAModeView.swift
// The QA section's screen: toggle QA mode, see live invariant results, watch the
// event feed, publish to the bridge, and read the companion app's findings.

import SwiftUI

struct QAModeView: View {
    @Environment(AppSession.self) private var session
    @State private var recorder = QARecorder.shared
    @State private var runner = QABackgroundRunner.shared
    @State private var companion: String = ""
    @State private var loadingCompanion = false

    private var store: GuestDataStore { session.guestStore }

    var body: some View {
        Form {
            if !QARecorder.isAvailable {
                Section {
                    Text("QA mode is unavailable in this build. It is enabled in debug and TestFlight builds so a shipped App Store binary cannot sit recording because a toggle was left on.")
                        .font(.footnote)
                }
            }

            Section {
                Toggle("QA mode", isOn: Binding(
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
                }
            } header: { Text("Recording") } footer: {
                Text("QA mode records the screens you open and the actions you attempt, and runs invariant checks that compare what two surfaces compute from the same data. Nothing is sent anywhere unless you publish.")
            }

            if recorder.isEnabled {
                sessionSection
                invariantSection
                eventSection
                bridgeSection
            }
        }
        .navigationTitle("QA mode")
        .qaScreen("Settings > QA mode")
        .onAppear {
            if recorder.isEnabled { runner.start(store: store, session: nil) }
        }
    }

    // MARK: Sections

    private var sessionSection: some View {
        Section("This session") {
            row("Screens visited", "\(recorder.screenCount)")
            row("Actions attempted", "\(recorder.attemptCount)")
            row("Failures", "\(recorder.failureCount)", tint: recorder.failureCount > 0 ? .red : nil)
            row("Invariant violations", "\(recorder.violationCount)",
                tint: recorder.violationCount > 0 ? .red : nil)
            let dangling = recorder.unresolvedAttempts
            if !dangling.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(dangling.count) unresolved attempt(s)")
                        .font(.subheadline).foregroundStyle(.orange)
                    Text("Started and never completed — a spinner that never ends looks like this.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(dangling.prefix(5), id: \.self) { d in
                        Text(d).font(.caption2.monospaced()).foregroundStyle(.secondary)
                    }
                }
            }
            ShareLink(item: recorder.exportText) {
                Label("Export session log", systemImage: "square.and.arrow.up")
            }
            Button("Clear session", role: .destructive) { recorder.clear() }
        }
    }

    private var invariantSection: some View {
        Section {
            if recorder.invariantResults.isEmpty {
                Text(runner.isRunning ? "Running…" : "No run yet.")
                    .foregroundStyle(.secondary)
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
        } header: {
            Text("Invariants")
        } footer: {
            Text("These compare two surfaces that must agree. A violation is a bug in the app, not a test failure. Blocked means there was not enough data to judge — the message says what to add. Runs automatically every two minutes and after meaningful changes.")
        }
    }

    private var eventSection: some View {
        Section("Event feed") {
            if recorder.events.isEmpty {
                Text("Move around the app to populate this.").foregroundStyle(.secondary)
            }
            ForEach(recorder.events.suffix(40).reversed()) { e in
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: symbol(for: e.kind))
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
        }
    }

    private var bridgeSection: some View {
        Section {
            Button {
                Task { await runner.publish() }
            } label: {
                Label("Publish health report", systemImage: "arrow.up.circle")
            }
            row("Last publish", runner.lastPublishOutcome)

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
            }
        } header: {
            Text("QA bridge")
        } footer: {
            Text("Publishes this device's health report to the Worker, and reads the companion app's latest suite results back. Requires the /qa routes to be deployed and a Worker key configured in this build.")
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

    private func row(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(tint ?? .secondary)
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
    private func symbol(for k: QAEventKind) -> String {
        switch k {
        case .screen: return "rectangle.on.rectangle"
        case .attempt: return "hand.tap"
        case .success: return "checkmark"
        case .failure: return "exclamationmark.triangle.fill"
        case .violation: return "xmark.octagon.fill"
        case .note: return "text.bubble"
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
