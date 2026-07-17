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
// Nothing here changes behavior; call sites opt in by wrapping work in `measure`.

import Foundation
import os
import MetricKit

enum StockedSignpost {
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
final class StockedMetrics: NSObject, MXMetricManagerSubscriber {
    static let shared = StockedMetrics()
    private let log = Logger(subsystem: StockedSignpost.subsystem, category: "metrics")
    private var started = false

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
