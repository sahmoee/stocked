// QAMemoryWatch.swift
// ─────────────────────────────────────────────────────────────────────────────
// IMPROVEMENT 8 (Build 74) — is memory going up, or was it always like that?
//
// The Build 71 field export ended with a line nobody could act on: memory grew
// 128 MB over 14 minutes 39 seconds. That is either a leak that will get the app
// jetsammed on an older phone after an hour, or it is images being cached exactly
// as designed and levelling off at 130 MB. The single number cannot tell you
// which, because a start value and an end value describe a line through two
// points and every curve fits through two points.
//
// The runtime monitor already samples the footprint. What it did not do was keep
// the samples, so the shape — the thing that answers the question — was thrown
// away immediately and only the difference survived.
//
// This keeps a bounded series and reports the two facts that distinguish a leak
// from a cache: the slope in MB per minute, and whether the *recent* slope is
// still as steep as the overall one. Growth that is flattening is a cache
// filling. Growth that is holding its rate is a leak. That is the whole
// diagnosis, and it needs about sixty samples.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

/// One reading in the long-horizon series.
///
/// NAMED `QAMemoryPoint`, NOT `QAMemorySample`, DELIBERATELY.
/// `QARuntimeMonitor` has declared its own `QAMemorySample` since Build 71 —
/// a different type with a different shape (`footprintMB` rather than `mb`, no
/// `Identifiable`) feeding `QARuntimeMonitor.memorySamples`. Both live in the
/// same module, so a second declaration under that name is a redeclaration
/// error, and every use of it in this file resolves ambiguously. Nothing
/// outside this file refers to this type, so it takes the distinct name.
nonisolated struct QAMemoryPoint: Identifiable, Sendable {
    var id: Date { at }
    let at: Date
    let mb: Double
    /// What screen was on when the sample was taken — so a step change can be
    /// blamed on the screen that caused it rather than on the minute it happened.
    let screen: String
}

@MainActor
@Observable
final class QAMemoryWatch {
    static let shared = QAMemoryWatch()

    private(set) var samples: [QAMemoryPoint] = []
    private(set) var isRunning = false
    /// Highest footprint seen this session, and where.
    private(set) var peakMB: Double = 0
    private(set) var peakScreen = "—"

    /// 15 seconds × 240 samples is an hour of history in about 12 KB. Long enough
    /// that a slow leak becomes visible, short enough that the sampler itself
    /// never becomes the thing using the memory.
    private let interval: TimeInterval = 15
    private let cap = 240

    private var task: Task<Void, Never>?

    private init() {}

    // MARK: Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        take()
        task = Task { [interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled else { return }
                QAMemoryWatch.shared.take()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    func reset() {
        samples = []
        peakMB = 0
        peakScreen = "—"
    }

    private func take() {
        let mb = QARuntimeMonitor.footprintMB()
        guard mb > 0 else { return }
        let screen = QARecorder.shared.currentScreen
        samples.append(QAMemoryPoint(at: Date(), mb: mb, screen: screen))
        if samples.count > cap { samples.removeFirst(samples.count - cap) }
        if mb > peakMB { peakMB = mb; peakScreen = screen }
    }

    // MARK: Reading the shape

    var currentMB: Double { samples.last?.mb ?? QARuntimeMonitor.footprintMB() }
    var firstMB: Double { samples.first?.mb ?? 0 }
    var growthMB: Double { currentMB - firstMB }

    var spanText: String {
        guard let first = samples.first, let last = samples.last, samples.count > 1 else {
            return "not enough samples yet"
        }
        let secs = Int(last.at.timeIntervalSince(first.at))
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m)m \(s)s of history" : "\(s)s of history"
    }

    /// Least-squares slope over a slice of the series, in MB per minute.
    ///
    /// Least squares rather than (last − first) ÷ time because the footprint
    /// jumps by tens of megabytes when a screen with images appears and drops
    /// again when it goes; two endpoints landing either side of one of those
    /// jumps gives a slope that is entirely an artefact of when you looked.
    private func slope(_ slice: ArraySlice<QAMemoryPoint>) -> Double {
        guard slice.count >= 3, let base = slice.first?.at else { return 0 }
        var sx = 0.0, sy = 0.0, sxy = 0.0, sxx = 0.0
        let n = Double(slice.count)
        for s in slice {
            let x = s.at.timeIntervalSince(base) / 60   // minutes
            let y = s.mb
            sx += x; sy += y; sxy += x * y; sxx += x * x
        }
        let denom = n * sxx - sx * sx
        guard abs(denom) > 0.000_1 else { return 0 }
        return (n * sxy - sx * sy) / denom
    }

    var overallSlope: Double { slope(samples[...]) }

    /// The last quarter of the series, minimum eight samples. This is the number
    /// that says whether whatever was happening is still happening.
    var recentSlope: Double {
        guard samples.count >= 8 else { return 0 }
        let take = max(8, samples.count / 4)
        return slope(samples.suffix(take))
    }

    /// Above this, sustained, is worth someone's afternoon. 2 MB/min is 120 MB an
    /// hour — enough to reach a jetsam limit inside a long cooking session on an
    /// older phone, which is exactly the session this app is used for.
    static let concerningSlope: Double = 2.0

    enum Shape {
        case tooEarly, flat, settling, growing

        var title: String {
            switch self {
            case .tooEarly:  return "Not enough history"
            case .flat:      return "Flat"
            case .settling:  return "Growing, but levelling off"
            case .growing:   return "Growing steadily"
            }
        }
        var symbol: String {
            switch self {
            case .tooEarly:  return "clock"
            case .flat:      return "checkmark.circle"
            case .settling:  return "arrow.down.right.circle"
            case .growing:   return "exclamationmark.triangle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .tooEarly:  return .secondary
            case .flat:      return Color.stockedGreen
            case .settling:  return Color.stockedInfo
            case .growing:   return Color.stockedWarning
            }
        }
    }

    var shape: Shape {
        guard samples.count >= 8 else { return .tooEarly }
        let overall = overallSlope
        guard overall > 0.5 else { return .flat }
        // Still climbing at more than half the original rate? Nothing is being
        // released, and it is a leak until proven otherwise.
        if recentSlope > overall * 0.5 && recentSlope > 0.5 { return .growing }
        return .settling
    }

    var verdict: String {
        switch shape {
        case .tooEarly:
            return "Leave QA on for a couple of minutes and come back — the shape of the curve is the diagnosis, and there isn't a curve yet."
        case .flat:
            return String(format: "Footprint is steady around %.0f MB. Nothing to chase.", currentMB)
        case .settling:
            return String(format: "Up %.0f MB overall at %.1f MB/min, but the recent rate is %.1f MB/min. That is a cache filling and then holding, not a leak.",
                          growthMB, overallSlope, recentSlope)
        case .growing:
            return String(format: "Up %.0f MB at %.1f MB/min, and still climbing at %.1f MB/min. Nothing is being released. At this rate that is %.0f MB an hour.",
                          growthMB, overallSlope, recentSlope, recentSlope * 60)
        }
    }

    /// Screens where the footprint stepped up by more than 8 MB and did not come
    /// back down within the next four samples. This is the closest thing to
    /// naming the culprit that a sampler can honestly do.
    var suspects: [QAScreenCount] {
        guard samples.count > 6 else { return [] }
        var counts: [String: Int] = [:]
        for i in 1..<samples.count {
            let jump = samples[i].mb - samples[i - 1].mb
            guard jump > 8 else { continue }
            let horizon = min(i + 4, samples.count - 1)
            let recovered = samples[(i + 1)...horizon].contains { $0.mb < samples[i - 1].mb + 2 }
            guard !recovered else { continue }
            counts[samples[i].screen, default: 0] += 1
        }
        return counts.sorted { $0.value > $1.value }
            .map { QAScreenCount(screen: $0.key, count: $0.value) }
    }

    // MARK: Export

    var exportText: String {
        var out = ["── MEMORY WATCH ──",
                   shape.title,
                   verdict,
                   "",
                   String(format: "now %.0f MB · peak %.0f MB on %@ · %@",
                          currentMB, peakMB, peakScreen, spanText),
                   String(format: "overall %.2f MB/min · recent %.2f MB/min", overallSlope, recentSlope)]
        if !suspects.isEmpty {
            out += ["", "STEPS THAT DID NOT COME BACK"]
            out += suspects.map { "  \($0.screen) — \($0.count)×" }
        }
        out += ["", "SAMPLES (\(samples.count))"]
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        for s in samples {
            out.append(String(format: "  %@  %6.1f MB  %@", f.string(from: s.at), s.mb, s.screen))
        }
        return out.joined(separator: "\n")
    }

    @discardableResult
    func fileTicket() -> QATicket? {
        guard shape == .growing else { return nil }
        return QATicketStore.shared.open(
            title: String(format: "Memory growing at %.1f MB/min", recentSlope),
            body: exportText,
            severity: .major,
            context: QAContextCapture.current(),
            origin: .automatic,
            screenshot: nil)
    }
}

// MARK: - Screen

struct QAMemoryWatchView: View {
    @State private var watch = QAMemoryWatch.shared
    @State private var filed = ""

    var body: some View {
        List {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: watch.shape.symbol)
                        .font(.stocked(.title3))
                        .foregroundStyle(watch.shape.tint)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(watch.shape.title).scaledFont(15, weight: .semibold)
                        Text(watch.spanText).font(.stocked(.caption2)).foregroundStyle(.secondary)
                    }
                }
                Text(watch.verdict)
                    .font(.stocked(.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Verdict")
            }

            Section("Numbers") {
                numberRow("Now", String(format: "%.0f MB", watch.currentMB))
                numberRow("Peak", String(format: "%.0f MB · %@", watch.peakMB, watch.peakScreen))
                numberRow("Growth", String(format: "%+.0f MB", watch.growthMB))
                numberRow("Overall rate", String(format: "%.2f MB/min", watch.overallSlope))
                numberRow("Recent rate", String(format: "%.2f MB/min", watch.recentSlope))
                numberRow("Samples", "\(watch.samples.count)")
            }

            if !watch.samples.isEmpty {
                Section {
                    QAMemorySparkline(samples: watch.samples)
                        .frame(height: 90)
                        .padding(.vertical, 6)
                } header: {
                    Text("Shape")
                } footer: {
                    Text("Every sample since QA mode came on, oldest on the left. A staircase that never comes down is a leak; a ramp that flattens is a cache.")
                }
            }

            if !watch.suspects.isEmpty {
                Section {
                    ForEach(watch.suspects) { s in
                        HStack {
                            Text(s.screen).scaledFont(13)
                            Spacer()
                            Text("\(s.count)×").font(.stocked(.caption)).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Steps that did not come back")
                } footer: {
                    Text("Screens where the footprint jumped more than 8 MB and had not returned four samples later. Not proof — a starting point.")
                }
            }

            Section {
                if watch.shape == .growing {
                    Button {
                        if let t = watch.fileTicket() { filed = "Filed \(t.number)" }
                    } label: {
                        Label("File this as a ticket", systemImage: "ticket")
                    }
                }
                ShareLink(item: watch.exportText) {
                    Label("Share full series", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) { watch.reset() } label: {
                    Label("Reset series", systemImage: "arrow.counterclockwise")
                }
                if !filed.isEmpty {
                    Text(filed).font(.stocked(.caption)).foregroundStyle(Color.stockedGreen)
                }
            }
        }
        .navigationTitle("Memory")
        .navigationBarTitleDisplayMode(.inline)
        .qaScreen("QA > Memory watch")
    }

    private func numberRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).scaledFont(13)
            Spacer()
            Text(value)
                .scaledFont(13, design: .monospaced)
                .foregroundStyle(.secondary)
        }
    }
}

/// Deliberately hand-drawn rather than a Swift Charts import: this is one series
/// of Doubles with no axes, no legend and no interaction, and a whole charting
/// framework linked into the app for it would be paid for by every user of a
/// build where QA never runs.
private struct QAMemorySparkline: View {
    let samples: [QAMemoryPoint]

    var body: some View {
        GeometryReader { geo in
            let values = samples.map(\.mb)
            let lo = (values.min() ?? 0)
            let hi = (values.max() ?? 1)
            let span = max(hi - lo, 1)
            let stepX = samples.count > 1 ? geo.size.width / CGFloat(samples.count - 1) : 0

            ZStack(alignment: .topLeading) {
                Path { p in
                    for (i, v) in values.enumerated() {
                        let x = CGFloat(i) * stepX
                        let y = geo.size.height * (1 - CGFloat((v - lo) / span))
                        if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                        else { p.addLine(to: CGPoint(x: x, y: y)) }
                    }
                }
                .stroke(Color.stockedGold, lineWidth: 1.5)

                VStack(alignment: .leading) {
                    Text(String(format: "%.0f MB", hi))
                    Spacer()
                    Text(String(format: "%.0f MB", lo))
                }
                .scaledFont(9, design: .monospaced)
                .foregroundStyle(.tertiary)
            }
        }
    }
}
