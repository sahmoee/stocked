// QARuntimeMonitor.swift
// ─────────────────────────────────────────────────────────────────────────────
// The part of QA that watches the machine rather than the code.
//
// WHY THIS EXISTS
// The bugs that cost the most in this app so far were not logic bugs. Cook Now
// froze; iOS killed the process with signal 9; the report afterwards said
// "it hung". Nothing in the event feed could say *how long* the main thread was
// blocked, whether memory was climbing, or whether the device was thermally
// throttled at the time — because nothing was measuring. A watchdog kill is
// invisible from inside a log that only records intent.
//
// So this samples four things while QA mode is on, and only while QA mode is on:
//
//   FRAME HITCHES  A CADisplayLink ticks once per frame. If the gap between two
//                  ticks is much larger than the display's frame budget, the main
//                  thread was blocked for that long, and we know exactly when and
//                  on which screen. Past ~1s that is watchdog territory, so it
//                  raises a ticket by itself — the freeze reports itself even if
//                  the tester never gets a chance to.
//
//   MEMORY         phys_footprint via task_info, which is what jetsam actually
//                  measures. `resident_size` is the number people usually reach
//                  for and it is not the number that gets you killed.
//
//   ENVIRONMENT    Thermal state, low-power mode, free disk, connectivity. Every
//                  one of these changes app behaviour and none of them are
//                  visible in a screenshot.
//
//   NETWORK        A tiny rollup of QA-instrumented requests: count, failures,
//                  slowest. Enough to answer "was the network involved" without
//                  building a proxy.
//
// COST
// The display link is the only continuous cost and it is a timestamp subtraction
// per frame. Memory and environment sample on a 5s timer, not per frame. Both
// stop dead when QA mode is switched off; `start()` is idempotent.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import UIKit
import Observation
import Darwin

// MARK: - Samples

nonisolated struct QAHitch: Identifiable, Sendable {
    var id = UUID()
    var at: Date = Date()
    var milliseconds: Double
    var screen: String

    /// Anything over a third of a second reads as a stutter to a human; over a
    /// second and iOS starts considering whether to kill you.
    var isSevere: Bool { milliseconds >= 1000 }

    var line: String {
        String(format: "%@  %.0f ms on %@", QAHitch.formatter.string(from: at), milliseconds, screen)
    }

    // See the note on QAEvent.formatter: a `nonisolated` struct's statics are
    // nonisolated too, and Swift 6 wants those Sendable. Write-once, read-only.
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

nonisolated struct QAMemorySample: Sendable {
    var at: Date = Date()
    var footprintMB: Double
    var screen: String
}

nonisolated struct QANetworkStat: Identifiable, Sendable {
    var id: String { name }
    var name: String
    var count: Int
    var failures: Int
    var totalSeconds: TimeInterval
    var worstSeconds: TimeInterval

    var averageMs: Double { count == 0 ? 0 : totalSeconds / Double(count) * 1000 }
    var line: String {
        String(format: "%@ — %d call%@, %d failed, avg %.0f ms, worst %.0f ms",
               name, count, count == 1 ? "" : "s", failures, averageMs, worstSeconds * 1000)
    }
}

// MARK: - Monitor

@MainActor
@Observable
final class QARuntimeMonitor {
    static let shared = QARuntimeMonitor()

    private init() {}

    // MARK: State

    private(set) var isRunning = false
    private(set) var hitches: [QAHitch] = []
    private(set) var memorySamples: [QAMemorySample] = []
    private(set) var peakFootprintMB: Double = 0
    private(set) var startFootprintMB: Double = 0
    private(set) var currentFootprintMB: Double = 0
    private(set) var thermal: ProcessInfo.ThermalState = .nominal
    private(set) var lowPower = false
    private(set) var freeDiskMB: Double = 0
    private(set) var online = true
    // Diagnostic-only counter. Publishing it at display refresh rate invalidated
    // every QA view observing this monitor (up to 120 times/second on iPad Pro).
    @ObservationIgnored private(set) var frameCount = 0

    /// Frame gaps thrown away because the clock jumped rather than the main
    /// thread blocking. Surfaced so a suspiciously high number is visible
    /// instead of silently swallowed.
    private(set) var discardedGaps = 0

    private let hitchCap = 120
    private let memoryCap = 240

    /// A frame that runs this much longer than budget counts as a hitch. Chosen
    /// so ordinary 60/120 Hz jitter and a single dropped frame stay quiet: at
    /// 120 Hz that is ~14 dropped frames, which is a visible stall, not noise.
    private let hitchThresholdMs: Double = 120

    /// A gap longer than this cannot be a main-thread stall the app lived
    /// through — iOS kills an unresponsive foreground app well before ten
    /// seconds. Anything above it is a clock discontinuity: the display link
    /// stopped ticking because the app was suspended, the device locked, or a
    /// system alert took over the screen. Build 71 had no such guard and duly
    /// filed two blockers for a 22.6s and a 78.7s "freeze" that were really the
    /// tester putting the phone down mid-session.
    private let implausibleGapMs: Double = 10_000

    private var link: CADisplayLink?
    private var linkTarget: DisplayLinkTarget?
    private var lastFrameAt: CFTimeInterval = 0
    /// QA startup, foreground restoration, and the first SwiftUI root render can
    /// legitimately monopolize the main run loop while iOS restores system state.
    /// Measuring that launch work created blocker tickets five seconds into a
    /// session with no screen or touch context. Begin measuring only after the
    /// UI has produced stable frames; actual stalls after that window remain visible.
    private var measureAfter: CFTimeInterval = 0
    private var sampler: Task<Void, Never>?
    private var lastAutoTicketAt: Date?
    private var lastMemoryAlertAt: Date?
    private var lastMemoryAlertBand = 0

    /// False from the moment the app resigns active until it is active again.
    /// Frames are still counted while false, but never measured.
    private var isForeground = true

    /// Set whenever the frame clock is known to be untrustworthy — at start, and
    /// on every return to the foreground. The first interval after it is set is
    /// spent re-establishing `lastFrameAt` and is not measured.
    private var frameClockDirty = true

    private var lifecycleObservers: [NSObjectProtocol] = []

    // MARK: Lifecycle

    /// Idempotent — QARecorder calls this whenever the master switch flips on,
    /// which can happen more than once per launch.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        // Build 74: the long-horizon memory trend runs alongside the 5s sampler.
        // Different question, different resolution — this one answers "is it
        // growing across a session", which a 5s window cannot see.
        QAMemoryWatch.shared.start()
        startFootprintMB = Self.footprintMB()
        currentFootprintMB = startFootprintMB
        peakFootprintMB = startFootprintMB
        sampleEnvironment()

        let target = DisplayLinkTarget()
        let l = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        // Instrumentation only needs enough cadence to identify a visible stall.
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
        // Explicitly low priority for the runtime range: this is instrumentation
        // and it must never be the reason a frame is late.
        l.add(to: .main, forMode: .common)
        link = l
        linkTarget = target
        lastFrameAt = 0
        measureAfter = CACurrentMediaTime() + 5
        isForeground = UIApplication.shared.applicationState == .active
        frameClockDirty = true
        observeLifecycle()

        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                self?.sampleMemory()
                self?.sampleEnvironment()
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        QAMemoryWatch.shared.stop()
        link?.invalidate()
        link = nil
        linkTarget = nil
        sampler?.cancel()
        sampler = nil
        for o in lifecycleObservers { NotificationCenter.default.removeObserver(o) }
        lifecycleObservers = []
    }

    // MARK: Lifecycle awareness
    //
    // WHY: CADisplayLink does not tick while the app is suspended, and the
    // timestamp it hands back on the first tick after resuming is real wall
    // clock — so the naive `timestamp - lastFrameAt` reads the entire time the
    // phone spent in someone's pocket as a main-thread block. That is not a
    // subtle failure mode: it produced the two worst "blockers" in the Build 71
    // field report, buried the genuine 1.2s Cook Now stalls underneath them, and
    // made the triage verdict wrong. The monitor now knows when it was asleep.

    private func observeLifecycle() {
        guard lifecycleObservers.isEmpty else { return }
        let center = NotificationCenter.default

        // resignActive rather than didEnterBackground: the clock is already
        // unreliable during the app switcher and under a system alert, neither
        // of which reaches the background notification.
        let sleep = center.addObserver(forName: UIApplication.willResignActiveNotification,
                                       object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QARuntimeMonitor.shared.enterSleep() }
        }
        let wake = center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                      object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QARuntimeMonitor.shared.enterWake() }
        }
        lifecycleObservers = [sleep, wake]
    }

    private func enterSleep() {
        isForeground = false
        frameClockDirty = true
    }

    private func enterWake() {
        isForeground = true
        frameClockDirty = true
        lastFrameAt = 0
        measureAfter = CACurrentMediaTime() + 3
        // Memory and thermal state can move a long way while suspended; take a
        // fresh reading rather than letting the 5s sampler show a stale one.
        sampleMemory()
        sampleEnvironment()
    }

    func clear() {
        hitches = []
        memorySamples = []
        network = [:]
        frameCount = 0
        discardedGaps = 0
        peakFootprintMB = currentFootprintMB
        startFootprintMB = currentFootprintMB
        lastMemoryAlertAt = nil
        lastMemoryAlertBand = 0
    }

    // MARK: Frames

    fileprivate func frame(at timestamp: CFTimeInterval) {
        guard isRunning else { return }
        frameCount += 1
        defer { lastFrameAt = timestamp }

        // Not active: keep the clock moving, measure nothing. A frame delivered
        // while resigning or resuming is not a frame the user was waiting on.
        guard isForeground else { return }

        // First interval after start or after a return to the foreground: it
        // spans the gap, not a stall. Spend it re-establishing the baseline.
        if frameClockDirty {
            frameClockDirty = false
            return
        }

        guard lastFrameAt > 0 else { return }

        // Instrumentation must not file a bug about the instrumentation/app
        // bootstrap itself. Keep advancing the clock during this short warm-up
        // so the first measured interval cannot include the ignored work.
        guard timestamp >= measureAfter else { return }

        let deltaMs = (timestamp - lastFrameAt) * 1000
        guard deltaMs >= hitchThresholdMs else { return }

        // Belt and braces for the transitions no notification covers (a hard
        // device lock, a springboard takeover): a foreground app does not
        // survive a ten-second block, so a gap this big is the clock, not us.
        if deltaMs >= implausibleGapMs {
            discardedGaps += 1
            QARecorder.shared.record(.note,
                                     screen: QARecorder.shared.currentScreen,
                                     label: "Frame clock jumped",
                                     detail: String(format: "%.0f ms with no frames — app was suspended or the screen locked, not blocked", deltaMs))
            return
        }

        let screen = QARecorder.shared.currentScreen
        let hitch = QAHitch(milliseconds: deltaMs, screen: screen)
        hitches.append(hitch)
        worstHitchCache = max(worstHitchCache, hitch.milliseconds)
        if hitch.isSevere { severeHitchCache += 1 }
        hitchScreenCounts[screen, default: 0] += 1
        if hitches.count > hitchCap { hitches.removeFirst(hitches.count - hitchCap) }

        QARecorder.shared.record(hitch.isSevere ? .failure : .violation,
                                 screen: screen,
                                 label: hitch.isSevere ? "Main thread froze" : "Frame hitch",
                                 detail: String(format: "%.0f ms blocked", deltaMs))

        if hitch.isSevere { raiseFreezeTicket(hitch) }
    }

    /// A freeze long enough to be a watchdog risk files its own ticket, because
    /// the person who saw it is usually busy deciding whether the app is dead.
    /// Rate-limited to one per minute so a pathological screen that hitches
    /// twenty times does not produce twenty identical tickets.
    private func raiseFreezeTicket(_ hitch: QAHitch) {
        if let last = lastAutoTicketAt, Date().timeIntervalSince(last) < 60 { return }
        lastAutoTicketAt = Date()

        var context = QAContextCapture.current()
        context.worstHitchMs = max(context.worstHitchMs, hitch.milliseconds)

        QATicketStore.shared.open(
            title: String(format: "Main thread blocked %.1fs on %@", hitch.milliseconds / 1000, hitch.screen),
            body: """
            Raised automatically by the runtime monitor — no one typed this.

            The main thread did not produce a frame for \(Int(hitch.milliseconds)) ms while \
            \(hitch.screen) was on screen. A block over one second is inside the range where \
            iOS terminates the app for being unresponsive (signal 9), so this is worth treating \
            as a freeze even if the app recovered.

            The steps below are the last things that happened before it stopped.
            """,
            severity: hitch.milliseconds >= 2000 ? .blocker : .major,
            context: context,
            origin: .automatic)
    }

    @ObservationIgnored private var worstHitchCache: Double = 0
    @ObservationIgnored private var severeHitchCache: Int = 0
    @ObservationIgnored private var hitchScreenCounts: [String: Int] = [:]

    var worstHitchMs: Double { worstHitchCache }
    var severeHitchCount: Int { severeHitchCache }
    var hitchesByScreen: [QAScreenCount] {
        hitchScreenCounts.map { QAScreenCount(screen: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    // MARK: Memory

    private func sampleMemory() {
        guard isRunning else { return }
        let mb = Self.footprintMB()
        currentFootprintMB = mb
        peakFootprintMB = max(peakFootprintMB, mb)
        memorySamples.append(QAMemorySample(footprintMB: mb, screen: QARecorder.shared.currentScreen))
        if memorySamples.count > memoryCap { memorySamples.removeFirst(memorySamples.count - memoryCap) }

        // Jetsam limits vary by device and iOS version; there is no API that
        // reports yours. These thresholds are where a phone-class app starts
        // being a candidate rather than a bystander.
        let band = mb > 900 ? 2 : (mb > 600 && mb > startFootprintMB * 2.5 ? 1 : 0)
        // A threshold breach is one diagnostic event, not a new failure every five
        // seconds. The old loop persisted and mirrored a complete QA report on every
        // sample, amplifying memory pressure and making the QA sheet itself hitch.
        let shouldAlert = band > 0 && (band > lastMemoryAlertBand ||
            lastMemoryAlertAt.map { Date().timeIntervalSince($0) >= 300 } != false)
        if shouldAlert && band == 2 {
            QARecorder.shared.record(.failure, label: "Memory very high",
                                     detail: String(format: "%.0f MB footprint — jetsam range", mb))
        } else if shouldAlert && band == 1 {
            QARecorder.shared.record(.violation, label: "Memory climbing",
                                     detail: String(format: "%.0f MB, started at %.0f MB", mb, startFootprintMB))
        }
        if shouldAlert { lastMemoryAlertAt = Date() }
        lastMemoryAlertBand = band
    }

    /// `phys_footprint` is the figure jetsam judges you on. Reading it is a
    /// single Mach call, cheap enough for a 5-second cadence.
    nonisolated static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    var memoryGrowthMB: Double { currentFootprintMB - startFootprintMB }

    // MARK: Environment

    private func sampleEnvironment() {
        let previousThermal = thermal
        thermal = ProcessInfo.processInfo.thermalState
        lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        online = ConnectivityMonitor.isOnlineFlag
        freeDiskMB = Self.freeDiskMB()

        if thermal != previousThermal && (thermal == .serious || thermal == .critical) {
            QARecorder.shared.record(.violation, label: "Device thermal state \(Self.thermalName(thermal))",
                                     detail: "the OS is throttling — timings from here are not representative")
        }
        if freeDiskMB > 0 && freeDiskMB < 250 {
            QARecorder.shared.record(.violation, label: "Very low disk",
                                     detail: String(format: "%.0f MB free — writes may start failing", freeDiskMB))
        }
    }

    nonisolated static func freeDiskMB() -> Double {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let bytes = values.volumeAvailableCapacityForImportantUsage else { return 0 }
        return Double(bytes) / 1_048_576
    }

    nonisolated static func thermalName(_ s: ProcessInfo.ThermalState) -> String {
        switch s {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }

    var thermalName: String { Self.thermalName(thermal) }
    var isThrottled: Bool { thermal == .serious || thermal == .critical || lowPower }

    // MARK: Network rollup

    private var network: [String: QANetworkStat] = [:]

    /// Record one network call. Called from the QA-instrumented request paths;
    /// absent instrumentation this section is simply empty rather than wrong.
    func recordRequest(_ name: String, seconds: TimeInterval, failed: Bool) {
        guard QARecorder.shared.isEnabled else { return }
        var stat = network[name] ?? QANetworkStat(name: name, count: 0, failures: 0,
                                                  totalSeconds: 0, worstSeconds: 0)
        stat.count += 1
        stat.failures += failed ? 1 : 0
        stat.totalSeconds += seconds
        stat.worstSeconds = max(stat.worstSeconds, seconds)
        network[name] = stat
    }

    var networkStats: [QANetworkStat] {
        network.values.sorted { $0.totalSeconds > $1.totalSeconds }
    }
    var networkCallCount: Int { network.values.reduce(0) { $0 + $1.count } }
    var networkFailureCount: Int { network.values.reduce(0) { $0 + $1.failures } }

    // MARK: Export

    var headline: String {
        var parts = [String(format: "%.0f MB", currentFootprintMB)]
        if worstHitchMs > 0 { parts.append(String(format: "worst hitch %.0f ms", worstHitchMs)) }
        if isThrottled { parts.append(thermalName + (lowPower ? " · low power" : "")) }
        if !online { parts.append("offline") }
        return parts.joined(separator: " · ")
    }

    var exportText: String {
        var out = ["RUNTIME"]
        out.append(String(format: "  memory: %.0f MB now · %.0f MB peak · %+.0f MB since start",
                          currentFootprintMB, peakFootprintMB, memoryGrowthMB))
        out.append("  thermal: \(thermalName)\(lowPower ? " · low power mode" : "")")
        out.append(String(format: "  free disk: %.0f MB · %@", freeDiskMB, online ? "online" : "OFFLINE"))
        out.append("  frames observed: \(frameCount)")
        if hitches.isEmpty {
            out.append("  no frame hitches over \(Int(hitchThresholdMs)) ms")
        } else {
            out.append(String(format: "  hitches: %d (%d severe) · worst %.0f ms",
                              hitches.count, severeHitchCount, worstHitchMs))
            for h in hitches.suffix(15) { out.append("    " + h.line) }
        }
        if !network.isEmpty {
            out.append("  network: \(networkCallCount) calls, \(networkFailureCount) failed")
            for s in networkStats.prefix(10) { out.append("    " + s.line) }
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Display link target

/// CADisplayLink retains its target and needs an `@objc` selector, so it cannot
/// take a Swift closure or a struct. This is the smallest possible NSObject that
/// satisfies it. `MainActor.assumeIsolated` is safe here for the same reason it
/// is in QATapTracker: CADisplayLink added to `.main` only ever fires on the main
/// run loop, so the isolation is real even though the signature cannot say so.
private final class DisplayLinkTarget: NSObject {
    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            QARuntimeMonitor.shared.frame(at: link.timestamp)
        }
    }
}

// MARK: - Context capture

/// Builds a `QATicketContext` from every QA surface at once. Lives here because
/// it is mostly runtime numbers, and it is a free function so both the long-press
/// reporter and the automatic freeze ticket produce identical context — a bug
/// report filed by a human and one filed by the monitor should be comparable.
@MainActor
enum QAContextCapture {
    static func current() -> QATicketContext {
        let recorder = QARecorder.shared
        let tracker = QAProcessTracker.shared
        let runtime = QARuntimeMonitor.shared

        var c = QATicketContext()
        c.screen = recorder.currentScreen
        c.breadcrumbs = Array(recorder.breadcrumbs.suffix(40))
        c.runningProcesses = tracker.running.prefix(10).map(\.line)
        c.stalledProcesses = tracker.stalled.prefix(10).map(\.line)
        c.recentFailures = recorder.events
            .filter { $0.kind == .failure }
            .suffix(8)
            .map(\.line)
        c.openViolations = recorder.invariantResults
            .filter { $0.status == .violation }
            .map { "\($0.name) — \($0.detail)" }
        c.appVersion = BuildConfig.version
        c.build = BuildConfig.buildNumber
        c.identity = QAIdentityStore.shared.capture()
        c.device = c.identity?.deviceModel ?? UIDevice.current.model
        c.os = (c.identity?.deviceFamily == "iPad" ? "iPadOS " : "iOS ") + UIDevice.current.systemVersion
        c.memoryMB = runtime.isRunning ? runtime.currentFootprintMB : QARuntimeMonitor.footprintMB()
        c.thermal = QARuntimeMonitor.thermalName(ProcessInfo.processInfo.thermalState)
        c.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        c.online = ConnectivityMonitor.isOnlineFlag
        c.freeDiskMB = runtime.freeDiskMB > 0 ? runtime.freeDiskMB : QARuntimeMonitor.freeDiskMB()
        c.sessionDuration = recorder.sessionDurationText
        c.tapsOnScreen = recorder.tapCounts[recorder.currentScreen] ?? 0
        c.worstHitchMs = runtime.worstHitchMs
        // Build 74: the rendering environment — text size, appearance, rotation,
        // which accessibility switches are on. Half the bug reports that read as
        // "layout is broken" are a screen at AX5 or in landscape, and that was
        // the one thing the context never said.
        c.environment = QAEnvironmentSnapshot.lines()
        return c
    }
}
