// QABackgroundRunner.swift
// ─────────────────────────────────────────────────────────────────────────────
// Runs the invariant suite automatically, and publishes results to the QA
// bridge so the companion app and the checkbook stay current without anyone
// remembering to press a button.
//
// WHEN IT RUNS
//   • shortly after QA mode is enabled (a baseline)
//   • on a periodic timer while the app is in the foreground
//   • when the app returns to the foreground
//   • immediately after a cook completes, an import lands, or a sync applies —
//     via `runSoon()`, which the callers listed in the delivery notes invoke
//
// It is NOT a BGTaskScheduler background task. That was a deliberate choice:
// the probes read main-actor store state and their whole value is comparing
// what two live surfaces currently compute. A 30-second background window with
// a cold store would either report `blocked` for everything or force the store
// to hydrate off-screen, which is a lot of risk for a report nobody is reading
// at that moment. Foreground-periodic gives the same coverage where it matters.
//
// COST CONTROL
// The suite calls CookNowCompute, which classifies the catalog. That is already
// revision-cached, so a run with no state change is cheap, but the timer is
// still deliberately slow (120s) and every run is skipped when a run is already
// in flight or when nothing has changed since the last one.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import Observation

@MainActor
@Observable
final class QABackgroundRunner {
    static let shared = QABackgroundRunner()

    private(set) var isRunning = false
    private(set) var runCount = 0
    private(set) var lastPublish: Date?
    private(set) var lastPublishOutcome: String = "never published"

    /// Auto-publish to the worker after a run that found something new.
    var autoPublish: Bool {
        didSet { UserDefaults.standard.set(autoPublish, forKey: "qa.autoPublish") }
    }

    private var timer: Task<Void, Never>?
    private var lastSignature: String = ""
    private weak var store: GuestDataStore?
    private var session: CookNowSession?

    private init() {
        autoPublish = UserDefaults.standard.bool(forKey: "qa.autoPublish")
    }

    // MARK: Lifecycle

    func start(store: GuestDataStore, session: CookNowSession?) {
        self.store = store
        self.session = session
        guard QARecorder.shared.isEnabled else { return }
        guard timer == nil else { return }
        timer = Task { [weak self] in
            // Let launch hydration and the first visible transition settle before
            // the expensive baseline. Running this on the first Home frame was a
            // major contributor to the build 68/77 launch-stall tickets.
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            await self?.runNow(force: false)
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(120))
                if Task.isCancelled { return }
                await self?.runNow(force: false)
            }
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// Nudge a run after a meaningful state change. Debounced by the signature
    /// check inside `runNow`, so calling it liberally is safe.
    func runSoon() {
        guard QARecorder.shared.isEnabled else { return }
        // Small debounce so a burst of mutations (finishing a cook fires several)
        // becomes one run, and it never lands on the exact frame of a transition.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            await runNow(force: false)
        }
    }

    // MARK: Running

    /// A cheap fingerprint of everything the probes depend on. When it has not
    /// changed, a re-run would produce identical results, so we skip.
    private func signature(_ store: GuestDataStore) -> String {
        let allergens = (store.cookingProfile.allergens + FamilyProfileStore.shared.activeAllergens).sorted()
        return [
            "i\(store.inventoryItems.count)",
            "r\(store.userRecipes.count)",
            "g\(store.savedGeneratedRecipes.count)",
            "p\(store.plannedMeals.count)",
            "d\(OnlineRecipesLoader.shared.recipes.count)",
            "a\(allergens.joined(separator: "|"))",
            "l\(store.inventoryItems.reduce(0.0) { $0 + $1.effectiveLevel }.rounded())",
        ].joined(separator: ",")
    }

    func runNow(force: Bool) async {
        guard QARecorder.shared.isEnabled, !isRunning, let store else { return }
        // WATCHDOG FIX: never auto-run while the user is actively mid-cook — the
        // classification probes are the heaviest main-actor work in the app, and
        // stacking them on live timer ticks froze Cook Now badly enough for iOS
        // to SIGKILL the app. Manual runs (force) are still allowed.
        if !force, let snap = ActiveCookSessionStore.shared.resumable, snap.status == .active { return }
        let sig = signature(store)
        if !force && sig == lastSignature { return }

        isRunning = true
        surfaceNewCrashes()
        let results = await QAInvariants.runAllYielding(store: store, session: session)
        QARecorder.shared.setInvariantResults(results)
        lastSignature = sig
        runCount += 1
        isRunning = false

        let violations = results.filter { $0.status == .violation }
        // Publish when the invariant suite found something, OR when a tester filed
        // a ticket that has not reached the bridge yet. Before tickets existed a
        // clean invariant run meant there was nothing to say; now a run can be
        // spotless while three hand-written blockers sit unsynced on the device.
        let ticketsWaiting = !QATicketStore.shared.unsynced.isEmpty
        if autoPublish && (!violations.isEmpty || ticketsWaiting) {
            await publish()
        }
    }

    // MARK: Crash surfacing

    /// MetricKit delivers crash/hang diagnostics up to a day after they happen.
    /// Each run, diff the persisted device log and turn NEW crash/hang lines into
    /// QA failure events — so a watchdog kill from yesterday is impossible to miss
    /// in today's session feed and in every exported/published report.
    private func surfaceNewCrashes() {
        let log = DiagnosticsMonitor.shared.currentLog()
        let lines = log.split(separator: "\n").map(String.init)
            .filter { $0.contains("CRASH") || $0.contains("HANG") }
        let seenKey = "qa.crashLinesSeen_v1"
        let seen = UserDefaults.standard.integer(forKey: seenKey)
        guard lines.count > seen else { return }
        for line in lines.suffix(lines.count - seen) {
            QARecorder.shared.record(.failure, screen: "Device",
                                     label: line.contains("CRASH") ? "Crash detected (MetricKit)" : "Hang detected (MetricKit)",
                                     detail: line)
        }
        UserDefaults.standard.set(lines.count, forKey: seenKey)
    }

    // MARK: Publishing

    /// Build the `stocked-qa-report/v1` envelope and POST it to /qa/reports.
    ///
    /// The envelope includes the `health` object the bridge spec asks the main
    /// app for and which the first exported report was missing entirely.
    @discardableResult
    func publish() async -> Bool {
        let recorder = QARecorder.shared
        let results = recorder.invariantResults

        var health: [String: Any] = [
            "qaMode": recorder.isEnabled,
            "invariantRuns": runCount,
            "screensVisited": recorder.screenCount,
            "attempts": recorder.attemptCount,
            "failures": recorder.failureCount,
            "violations": recorder.violationCount,
            "unresolvedAttempts": recorder.unresolvedAttempts.count,
            "taps": recorder.tapTotal,
        ]
        let crashLines = DiagnosticsMonitor.shared.currentLog()
            .split(separator: "\n").map(String.init)
            .filter { $0.contains("CRASH") || $0.contains("HANG") }
        health["recentCrashes"] = Array(crashLines.suffix(10))
        if let store {
            health["inventoryItems"] = store.inventoryItems.count
            health["savedRecipes"] = store.userRecipes.count
            health["discoverCached"] = OnlineRecipesLoader.shared.recipes.count
            health["mealsReady"] = store.availableMeals
        }
        health["invariants"] = results.map { r in
            ["name": r.name, "status": r.status.rawValue,
             "detail": r.detail, "critical": r.critical]
        }

        // Tester-filed tickets and live runtime measurements ride along in the same
        // envelope. A report that says "0 violations" while the device is thermally
        // throttled at 900 MB with two open blockers is a misleading report, and the
        // bridge had no way to know any of that.
        let tickets = QATicketStore.shared
        health["tickets"] = tickets.healthSummary
        let runtime = QARuntimeMonitor.shared
        health["runtime"] = [
            "footprintMB": Int(runtime.currentFootprintMB.rounded()),
            "peakFootprintMB": Int(runtime.peakFootprintMB.rounded()),
            "growthMB": Int(runtime.memoryGrowthMB.rounded()),
            "worstHitchMs": Int(runtime.worstHitchMs.rounded()),
            "severeHitches": runtime.severeHitchCount,
            "thermal": runtime.thermalName,
            "lowPower": runtime.lowPower,
            "freeDiskMB": Int(runtime.freeDiskMB.rounded()),
            "networkCalls": runtime.networkCallCount,
            "networkFailures": runtime.networkFailureCount,
        ]
        health["triage"] = [
            "verdict": QATriage.shared.verdict,
            "blockers": QATriage.shared.blockers.count,
            "warnings": QATriage.shared.warnings.count,
            "findings": QATriage.shared.findings.prefix(20).map { f in
                ["level": f.level.title, "title": f.title,
                 "detail": f.detail, "source": f.source]
            },
        ]
        health["deadScreens"] = recorder.deadScreens

        let openBlockers = results.filter { $0.status == .violation && $0.critical }.count
            + tickets.blockers.count
        let payload: [String: Any] = [
            "schema": "stocked-qa-report/v1",
            "source": "stocked-app",
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "app": ["name": "Stocked",
                    "version": BuildConfig.version,
                    "build": BuildConfig.buildNumber],
            "device": ["model": UIDevice.current.model, "os": "iOS " + UIDevice.current.systemVersion],
            "worker": ["baseURL": BuildConfig.receiptWorkerURL],
            "checkbook": ["version": "\(BuildConfig.version) build \(BuildConfig.buildNumber)",
                          "checks": 270, "blockers": 126],
            "signOff": ["passed": results.filter { $0.status == .ok }.count,
                        "failed": results.filter { $0.status == .violation }.count,
                        "blocked": results.filter { $0.status == .blocked }.count,
                        "openBlockers": openBlockers],
            "checklists": [],
            "health": health,
        ]

        let attempt = recorder.attempt("Publish QA report", detail: "POST /qa/reports")
        do {
            let ok = try await QAReportTransport.post(payload)
            lastPublish = Date()
            lastPublishOutcome = ok ? "published" : "worker rejected the report"
            if ok { recorder.succeeded(attempt) } else { recorder.failed(attempt, detail: lastPublishOutcome) }
            // Tickets go up as their own envelope right after, not folded into this
            // one. The summary above is a count; the ticket envelope carries the
            // tester's actual words, the breadcrumb trail, and the screenshot name.
            // Sending them separately also means a rejected report does not silently
            // take three bug reports down with it.
            // Tickets are independent evidence. A temporary rejection of the
            // aggregate health report must never strand bug reports behind it.
            await pushTickets()
            // Mirror to the Logs folder so every successful worker publish has a
            // local archive on the Mac without the tester pressing anything.
            if ok {
                let snap = recorder.fullExportText
                Task { await QASyncCoordinator.shared.mirrorLog(snap, name: "qa-report-auto.txt") }
            }
            return ok
        } catch {
            lastPublish = Date()
            lastPublishOutcome = error.localizedDescription
            recorder.failed(attempt, error: error)
            await pushTickets()
            return false
        }
    }

    /// Flush anything the tester filed that has not reached the bridge yet.
    /// Safe to call repeatedly — the store skips tickets it has already synced.
    func pushTickets() async {
        let store = QATicketStore.shared
        guard !store.unsynced.isEmpty else { return }
        await store.publishUnsynced()
    }
}

// MARK: - Transport

/// Minimal POST to the QA bridge. Deliberately separate from
/// StockedWorkerClient: that client enriches payloads with `route` and
/// `schemaVersion`, consults the AI kill-switch, and is shaped for the AI
/// routes. The QA bridge takes a verbatim body, so borrowing that client would
/// mean either corrupting the envelope or special-casing it.
nonisolated enum QAReportTransport {

    static func fetchDeviceTickets(source: String = "stocked-app") async throws -> [[String: Any]] {
        guard let base = URL(string: BuildConfig.receiptWorkerURL) else {
            throw StockedServiceError.notConfigured("QA bridge")
        }
        var components = URLComponents(url: base.appendingPathComponent("_unified/qa/tickets/sync"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "source", value: source), URLQueryItem(name: "limit", value: "1000")]
        var request = URLRequest(url: components.url!, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("Joo", forHTTPHeaderField: "X-QA-Passcode")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200...299).contains(code) else { throw StockedServiceError.httpStatus(code, "QA device sync was rejected") }
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return object?["tickets"] as? [[String: Any]] ?? []
    }

    static func post(_ payload: [String: Any]) async throws -> Bool {
        guard let base = URL(string: BuildConfig.receiptWorkerURL) else {
            throw StockedServiceError.notConfigured("QA bridge")
        }
        guard ConnectivityMonitor.isOnlineFlag else { throw StockedServiceError.offline }

        var req = URLRequest(url: base.appendingPathComponent("qa/reports"),
                             timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Centralized header stamping, so this stays consistent with every other
        // Worker caller if the header name or key source ever changes.
        BuildConfig.authorizeWorkerRequest(&req)
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (_, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        return (200...299).contains(code)
    }

    /// Fetch the most recent report this app published to /qa/reports.
    /// Returns nil when the bridge has no report yet.
    static func fetchOwnReport() async throws -> [String: Any]? {
        guard let base = URL(string: BuildConfig.receiptWorkerURL) else {
            throw StockedServiceError.notConfigured("QA bridge")
        }
        var comps = URLComponents(url: base.appendingPathComponent("qa/reports/latest"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "source", value: "stocked-app")]
        guard let url = comps?.url else { throw StockedServiceError.notConfigured("QA bridge") }
        var req = URLRequest(url: url, timeoutInterval: 20)
        BuildConfig.authorizeWorkerRequest(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 404 { return nil }
        guard (200...299).contains(code) else {
            let hint: String
            switch code {
            case 401, 403: hint = "the shared key was rejected"
            case 405:      hint = "the QA routes are not deployed yet — run wrangler deploy"
            case 500...599: hint = "the Worker failed"
            default:       hint = "unexpected reply from the QA bridge"
            }
            throw StockedServiceError.httpStatus(code, hint)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// Fetch the companion app's latest findings so the main app can show them.
    /// Returns nil when the bridge is reachable but empty (code `no_reports`).
    static func fetchCompanionFindings() async throws -> [String: Any]? {
        guard let base = URL(string: BuildConfig.receiptWorkerURL) else {
            throw StockedServiceError.notConfigured("QA bridge")
        }
        var comps = URLComponents(url: base.appendingPathComponent("qa/reports/latest"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [URLQueryItem(name: "source", value: "stocked-qa")]
        guard let url = comps?.url else { throw StockedServiceError.notConfigured("QA bridge") }

        var req = URLRequest(url: url, timeoutInterval: 20)
        BuildConfig.authorizeWorkerRequest(&req)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        if code == 404 { return nil }
        guard (200...299).contains(code) else {
            // NOT `.notConfigured`. That case interpolates into "<x> is not
            // configured.", so a status code passed to it produced the sentence
            // "QA bridge returned 405 is not configured." — which reads like the
            // app is missing a setting when the truth is the server answered and
            // said no. `.httpStatus` is the case that exists for exactly this.
            //
            // 405 in particular has one cause worth naming: the Worker's QA
            // routes sat below a blanket POST-only gate, so every GET was
            // refused before the QA handler ran. Fixed on the Worker side in
            // Build 73 — but the fix only takes effect once it is deployed, and
            // an unhelpful error message is what sent someone looking in the app
            // for a problem that was never there.
            let hint: String
            switch code {
            case 401, 403: hint = "the shared key was rejected"
            case 405:      hint = "the QA routes are not deployed on the Worker yet — run wrangler deploy"
            case 500...599: hint = "the Worker failed"
            default:       hint = "unexpected reply from the QA bridge"
            }
            throw StockedServiceError.httpStatus(code, hint)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
