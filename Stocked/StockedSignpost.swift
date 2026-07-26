// StockedSignpost.swift — performance instrumentation (#9).
//
// Two layers, both additive and low-overhead:
//  • StockedSignpost — OSSignposter spans you wrap around hot operations (app
//    launch, recipe first render, DB reads, JSON/image decode, source requests).
//    They show up live in Instruments' os_signpost track and log a duration line.
//  • StockedMetrics — a MetricKit subscriber that records Apple's daily aggregated
//    launch time, hang rate, memory, and disk metrics from the FIELD, plus crash/
//    hang diagnostics — so regressions are caught before users report freezing.
//
// CONCURRENCY (crash fix, TestFlight 4.13/62): MetricKit calls didReceive(_:) on its
// OWN background queue. Under the project's default main-actor isolation these types
// were implicitly @MainActor, so the delivery thunk failed the runtime executor check
// (EXC_BREAKPOINT in dispatch_assert_queue_fail → @objc StockedMetrics.didReceive).
// Everything here is therefore explicitly `nonisolated`: it only logs and emits
// signposts (Logger/OSSignposter are Sendable and thread-safe), so it is safe from
// any queue and must never assume the main actor.

import Foundation
import os
import MetricKit

nonisolated enum StockedSignpost {
    static let subsystem = "com.sowens.Stocked"

    // Separate categories keep Instruments tracks readable.
    static let launch  = OSSignposter(subsystem: subsystem, category: "launch")
    static let ui      = OSSignposter(subsystem: subsystem, category: "ui")
    static let data    = OSSignposter(subsystem: subsystem, category: "data")
    static let network = OSSignposter(subsystem: subsystem, category: "network")

    private static let log = Logger(subsystem: subsystem, category: "perf")

    /// Measure an async operation: a signpost interval + a duration log line.
    @discardableResult
    static func measure<T>(_ name: StaticString,
                           _ poster: OSSignposter = ui,
                           _ body: () async throws -> T) async rethrows -> T {
        let id = poster.makeSignpostID()
        let state = poster.beginInterval(name, id: id)
        let start = DispatchTime.now().uptimeNanoseconds
        defer {
            poster.endInterval(name, state)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            log.log("\(name, privacy: .public): \(String(format: "%.1f", ms), privacy: .public) ms")
        }
        return try await body()
    }

    /// Synchronous variant.
    @discardableResult
    static func measureSync<T>(_ name: StaticString,
                               _ poster: OSSignposter = ui,
                               _ body: () throws -> T) rethrows -> T {
        let id = poster.makeSignpostID()
        let state = poster.beginInterval(name, id: id)
        defer { poster.endInterval(name, state) }
        return try body()
    }

    /// A one-shot marker (e.g. "recipeTabSelected").
    static func event(_ name: StaticString, _ poster: OSSignposter = ui) {
        poster.emitEvent(name, id: poster.makeSignpostID())
    }
}

/// MetricKit subscriber. Register once at launch via `StockedMetrics.shared.start()`.
/// nonisolated: MetricKit delivers payloads on a background queue (see header comment).
/// @unchecked Sendable: the only mutable state is `started`, written once from start() on the
/// main thread at launch (see its note); every other stored property is an immutable Sendable
/// `let`. This is what makes `static let shared` concurrency-safe on a nonisolated class.
nonisolated final class StockedMetrics: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = StockedMetrics()
    private let log = Logger(subsystem: StockedSignpost.subsystem, category: "metrics")
    // Written only from start(), which the app calls exactly once from StockedApp.init
    // on the main thread before any other use — hence the unchecked marker is safe.
    nonisolated(unsafe) private var started = false

    func start() {
        guard !started else { return }
        started = true
        MXMetricManager.shared.add(self)
    }

    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            if let ttfd = p.applicationLaunchMetrics?.histogrammedTimeToFirstDraw {
                log.log("launchTimeToFirstDraw buckets=\(ttfd.totalBucketCount, privacy: .public)")
            }
            if let hang = p.applicationResponsivenessMetrics?.histogrammedApplicationHangTime {
                log.log("hangTime buckets=\(hang.totalBucketCount, privacy: .public)")
            }
            if let json = String(data: p.jsonRepresentation(), encoding: .utf8) {
                log.log("metricPayload=\(json, privacy: .public)")
            }
        }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            if let json = String(data: p.jsonRepresentation(), encoding: .utf8) {
                log.log("diagnosticPayload=\(json, privacy: .public)")
            }
        }
    }
}
