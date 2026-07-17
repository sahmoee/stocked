// DiagnosticsMonitor.swift — Crash / hang / disk-write diagnostics via MetricKit (#4).
//
// MetricKit is Apple-native (no third-party SDK, no network, privacy-friendly): the system
// hands the app aggregated diagnostic payloads — crash call stacks, hangs, excessive disk
// writes — once per day, plus on next launch after a crash. We persist the most recent ones
// locally so they can be surfaced in a hidden debug view (or attached when a user reports a
// problem), and log a one-line summary. Nothing leaves the device.
//
// Setup: call DiagnosticsMonitor.shared.start() once at launch (e.g. in the App init or the
// app delegate's didFinishLaunching).
//
// CONCURRENCY (same crash class as StockedMetrics, TestFlight 4.13/62): MetricKit calls
// didReceive(_:) on its OWN background queue, so this subscriber must be `nonisolated` —
// under the project's default main-actor isolation the delivery thunk would otherwise trap
// in dispatch_assert_queue_fail. All work here (logging + a small serialized file append)
// is thread-safe; the file writes are funneled through one utility queue.

import Foundation
import MetricKit
import os

nonisolated final class DiagnosticsMonitor: NSObject, MXMetricManagerSubscriber {
    static let shared = DiagnosticsMonitor()

    private let log = Logger(subsystem: "com.sowens.Stocked", category: "diagnostics")
    private let store = URL.documentsDirectory.appendingPathComponent("diagnostics.log")
    private let maxBytes = 256 * 1024  // keep the local log small
    /// Serializes read-modify-write of the log file (didReceive can arrive on
    /// MetricKit's queue while currentLog() is read elsewhere).
    private let io = DispatchQueue(label: "com.sowens.Stocked.diagnostics-io", qos: .utility)

    func start() {
        MXMetricManager.shared.add(self)
    }

    // Daily aggregated metrics — we mostly care about diagnostics, but a hang/launch summary
    // line is handy. Kept minimal on purpose.
    func didReceive(_ payloads: [MXMetricPayload]) {
        for p in payloads {
            if let hang = p.applicationResponsivenessMetrics?.histogrammedApplicationHangTime {
                record("metrics: hang buckets=\(hang.totalBucketCount)")
            }
        }
    }

    // Crashes, hangs, disk-write, CPU exceptions. This is the valuable part.
    func didReceive(_ payloads: [MXDiagnosticPayload]) {
        for p in payloads {
            if let crashes = p.crashDiagnostics, !crashes.isEmpty {
                for c in crashes {
                    let type = c.exceptionType?.stringValue ?? "?"
                    let code = c.exceptionCode?.stringValue ?? "?"
                    let sig  = c.signal?.stringValue ?? "?"
                    record("CRASH type=\(type) code=\(code) signal=\(sig)")
                }
            }
            if let hangs = p.hangDiagnostics, !hangs.isEmpty {
                record("HANG count=\(hangs.count)")
            }
            if let disk = p.diskWriteExceptionDiagnostics, !disk.isEmpty {
                record("DISK_WRITE_EXCEPTION count=\(disk.count)")
            }
        }
    }

    /// The persisted diagnostics text, newest last. Empty if none yet. For a debug view.
    func currentLog() -> String {
        io.sync { (try? String(contentsOf: store, encoding: .utf8)) ?? "" }
    }

    private func record(_ line: String) {
        let stamped = "[\(StockedFormatters.iso8601.string(from: Date()))] \(line)\n"
        log.error("\(line, privacy: .public)")
        io.sync {
            var existing = (try? String(contentsOf: store, encoding: .utf8)) ?? ""
            existing += stamped
            // Trim from the front if it grows too large.
            if existing.utf8.count > maxBytes {
                existing = String(existing.suffix(maxBytes / 2))
            }
            try? existing.data(using: .utf8)?.write(to: store, options: .atomic)
        }
    }
}
