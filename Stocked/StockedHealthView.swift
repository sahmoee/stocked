// StockedHealthView.swift — Improvement #20: one place that shows whether the app is actually OK.
//
// Three health signals existed and nobody could look at them together:
//
//   DiagnosticsMonitor  writes crashes/hangs to diagnostics.log — read by exactly one uploader
//   StockedMetrics      receives the same MetricKit payloads and only writes to OSLog
//   Worker /health      a deep health endpoint nothing in the app ever calls
//
// Plus `SyncDiagnosticsView` was fully built and never linked from anywhere — its own header even
// says "Reachable from Data & Storage (add a NavigationLink)", and that link was never added.
//
// The 4.13(62) TestFlight crash was diagnosable from its stack trace in minutes, but only because
// it was reported by hand. This makes the next one visible without a bug report.

import SwiftUI

// MARK: - Worker health probe

nonisolated struct WorkerHealth: Sendable {
    var reachable = false
    var version = ""
    var latencyMs = 0
    var statusCode = 0
    var maintenance = false
    var error = ""
}

nonisolated enum WorkerHealthProbe {
    /// Hits the Worker's own `/health`, which already reports version, uptime and dependency state.
    static func check() async -> WorkerHealth {
        guard let base = StockedWorkerClient.url() else {
            return WorkerHealth(error: "No Worker URL configured")
        }
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 8
        BuildConfig.authorizeWorkerRequest(&req)

        let started = Date()
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            var health = WorkerHealth(reachable: (200..<300).contains(code),
                                      latencyMs: ms, statusCode: code)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                health.version = (json["version"] as? String) ?? ""
                health.maintenance = (json["maintenance"] as? Bool) ?? false
            }
            return health
        } catch {
            return WorkerHealth(latencyMs: Int(Date().timeIntervalSince(started) * 1000),
                                error: error.localizedDescription)
        }
    }
}

// MARK: - View

struct StockedHealthView: View {
    @Environment(AppSession.self) private var session

    @State private var worker: WorkerHealth?
    @State private var checking = false
    @State private var cacheBytes: Int64 = 0
    @State private var cacheEntries = 0
    @State private var showLog = false

    private let conflicts = SyncConflictLog.shared
    private let engagement = NotificationEngagement.shared
    private let receipts = ReceiptLearningIndex.shared

    var body: some View {
        List {
            // ── Worker ───────────────────────────────────────────────────────
            Section {
                if let w = worker {
                    row("Status",
                        w.maintenance ? "Maintenance" : (w.reachable ? "Reachable" : "Unreachable"),
                        tint: w.maintenance ? .orange : (w.reachable ? .green : .red))
                    if !w.version.isEmpty { row("Version", w.version) }
                    row("Latency", "\(w.latencyMs) ms",
                        tint: w.latencyMs > 2000 ? .orange : session.themeTextColor)
                    if w.statusCode > 0 { row("HTTP", "\(w.statusCode)") }
                    if !w.error.isEmpty {
                        Text(w.error).stockedFont(.caption).foregroundStyle(.red)
                    }
                } else {
                    row("Status", checking ? "Checking…" : "Not checked yet")
                }
                Button { probe() } label: {
                    Label("Check now", systemImage: "arrow.clockwise")
                }.disabled(checking)
            } header: { Text("Worker") } footer: {
                Text(StockedWorkerClient.isConfigured
                     ? "Every AI feature — receipt parsing, barcode lookup, recipe import — goes through this."
                     : "No Worker URL is configured, so AI features fall back to offline parsing.")
            }

            // ── Crashes and hangs ────────────────────────────────────────────
            Section {
                let log = DiagnosticsMonitor.shared.currentLog()
                if log.isEmpty {
                    row("Recent events", "None", tint: .green)
                } else {
                    let lines = log.split(separator: "\n")
                    row("Logged events", "\(lines.count)")
                    row("Crashes", "\(lines.filter { $0.contains("CRASH") }.count)",
                        tint: lines.contains { $0.contains("CRASH") } ? .red : session.themeTextColor)
                    row("Hangs", "\(lines.filter { $0.contains("HANG") }.count)")
                    Button { showLog = true } label: {
                        Label("View log", systemImage: "doc.text.magnifyingglass")
                    }
                }
            } header: { Text("Stability") } footer: {
                Text("Collected by MetricKit after a crash or hang. Delivered by the system on its own schedule, usually once a day, so this can lag a real crash by up to 24 hours.")
            }

            // ── Sync ─────────────────────────────────────────────────────────
            Section {
                row("Household", session.householdCode.isEmpty ? "Not joined" : session.householdCode)
                row("Edits replaced by sync", "\(conflicts.records.count)",
                    tint: conflicts.hasRecentUnreviewed ? .orange : session.themeTextColor)
                if !conflicts.records.isEmpty {
                    NavigationLink { SyncConflictReviewView() } label: {
                        Label("Review what changed", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                // SyncDiagnosticsView has existed, complete and unreferenced, since it was written.
                NavigationLink { SyncDiagnosticsView() } label: {
                    Label("Sync diagnostics", systemImage: "stethoscope")
                }
            } header: { Text("Sync") }

            // ── Storage ──────────────────────────────────────────────────────
            Section {
                row("Feature data", byteLabel(FeatureStoreKeys.diskBytes()))
                row("Smart cache", "\(byteLabel(cacheBytes)) · \(cacheEntries) entries")
                row("Inventory items", "\(session.guestStore.inventoryItems.count)")
                row("Learned receipt names", "\(receipts.learnedCount)")
                row("Store-specific corrections", "\(receipts.storeScopedCount)")
                Button(role: .destructive) {
                    Task {
                        await SmartResponseCache.shared.clear()
                        await refreshCacheStats()
                    }
                } label: { Label("Clear smart cache", systemImage: "trash") }
            } header: { Text("Storage") } footer: {
                Text("Clearing the cache only removes saved answers from the Worker. Nothing of yours is deleted, and everything refetches on next use.")
            }

            // ── Notifications ────────────────────────────────────────────────
            Section {
                row("Daily brief", DailyBriefNotificationManager.shared.isEnabled ? "On" : "Off")
                row("Scheduled for", DailyBriefNotificationManager.shared.timeLabel)
                if DailyBriefNotificationManager.shared.adaptiveTimingEnabled {
                    row("Actually delivering at", "\(DailyBriefNotificationManager.shared.adaptiveHour):00")
                }
                Toggle("Adapt timing to my routine", isOn: Binding(
                    get: { DailyBriefNotificationManager.shared.adaptiveTimingEnabled },
                    set: { DailyBriefNotificationManager.shared.adaptiveTimingEnabled = $0 }))
                Text(engagement.confidenceLabel)
                    .stockedFont(.caption)
                    .foregroundStyle(session.themeSecondaryText)
            } header: { Text("Notifications") } footer: {
                Text("Stocked shifts reminders toward the time you actually open the app, never by more than three hours from the time you set, and never outside 7am–9pm.")
            }

            // ── Usage insights (#19) ─────────────────────────────────────────
            Section {
                Toggle("Record usage on this device", isOn: Binding(
                    get: { AppAnalytics.shared.isEnabled },
                    set: { AppAnalytics.shared.isEnabled = $0 }))
                if AppAnalytics.shared.isEnabled {
                    row("Items added", "\(AppAnalytics.shared.count(.itemAdded))")
                    row("Recipes saved", "\(AppAnalytics.shared.count(.recipeSaved))")
                    row("Cooks finished", "\(AppAnalytics.shared.count(.cookCompleted))")
                    row("Receipts scanned", "\(AppAnalytics.shared.count(.receiptScanned))")
                    Button("Clear usage data", role: .destructive) { AppAnalytics.shared.reset() }
                }
            } header: { Text("Usage insights") } footer: {
                Text("Counts stay on this device to help you see how you use Stocked. Nothing is ever sent anywhere. Turn it off any time.")
            }

            // ── QA ───────────────────────────────────────────────────────────
            Section {
                NavigationLink { QAModeView() } label: {
                    Label("QA mode", systemImage: "checkmark.seal")
                }
                NavigationLink { StockedQAGateView() } label: {
                    Label("Release checklist", systemImage: "checklist")
                }
            } header: { Text("QA") } footer: {
                Text("QA mode records screens and attempted actions and runs invariant checks automatically. The release checklist is the code-gated manual checkbook; both publish to the same QA bridge.")
            }

            // ── Build ────────────────────────────────────────────────────────
            Section("Build") {
                row("Version", BuildConfig.version)
                row("Build", "\(BuildConfig.buildNumber)")   // buildNumber is Int, not String
                row("Environment", environmentLabel)
            }
        }
        .listStyle(.insetGrouped)
        .qaScreen("Settings > App Health")
        .stockedScreen()
        .navigationTitle("App Health")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await refreshCacheStats()
            probe()
        }
        .sheet(isPresented: $showLog) { DiagnosticsLogSheet() }
    }

    // MARK: Helpers

    private func probe() {
        guard !checking else { return }
        checking = true
        Task {
            worker = await WorkerHealthProbe.check()
            checking = false
        }
    }

    private func refreshCacheStats() async {
        cacheBytes = await SmartResponseCache.shared.sizeBytes()
        cacheEntries = await SmartResponseCache.shared.entryCount()
    }

    private func row(_ label: String, _ value: String, tint: Color? = nil) -> some View {
        HStack {
            Text(label).stockedFont(.rowDetail)
            Spacer()
            Text(value)
                .stockedFont(.rowTitle)
                .foregroundStyle(tint ?? session.themeTextColor)
        }
    }

    /// `BuildConfig.Environment` is a plain enum with no raw value.
    private var environmentLabel: String {
        switch BuildConfig.environment {
        case .debug:   return "Debug"
        case .staging: return "Staging"
        case .release: return "Release"
        }
    }

    private func byteLabel(_ bytes: Int64) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.0f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / (1024 * 1024))
    }
}

// MARK: - Raw log

private struct DiagnosticsLogSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(DiagnosticsMonitor.shared.currentLog())
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(16)
            }
            .stockedScreen()
            .navigationTitle("Diagnostics log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    ShareLink(item: DiagnosticsMonitor.shared.currentLog()) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }
}
