// QAAccessibilitySweep.swift
// ─────────────────────────────────────────────────────────────────────────────
// IMPROVEMENT 7 (Build 74) — the accessibility problems nobody can see.
//
// Every other QA probe in this app checks something a tester could in principle
// have noticed. Accessibility defects are the opposite: an icon-only button with
// no label reads to VoiceOver as "Button", and to everyone else as a perfectly
// good button. A 30-point tap target works fine for whoever built it and is a
// coin toss for someone with a tremor. Neither shows up in a screenshot, in an
// invariant, or in a bug report — because nobody who can see the screen ever
// experiences them.
//
// So this walks the live view tree and reports the two defects that are
// mechanically detectable and genuinely worth fixing: controls VoiceOver cannot
// name, and controls too small to reliably hit. Apple's own floor is 44×44pt;
// that is what is checked.
//
// WHAT IT DELIBERATELY DOES NOT DO
// It does not check contrast (needs rendered pixels and a colour model, and
// produces false positives on every image), and it does not check reading order
// (the tree order is not the traversal order once `accessibilityElements` is
// set anywhere). Two checks that are right beat six that cry wolf — a sweep that
// reports forty things is a sweep nobody runs twice.
//
// SwiftUI's backing views are what get walked, so labels set with
// `.accessibilityLabel` are found; a plain `Image(systemName:)` in a `Button`
// with no label is what gets reported, which is the actual defect.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import UIKit

// MARK: - Findings

nonisolated struct QAAccessibilityIssue: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case unlabelled, tinyTarget, noHint

        var title: String {
            switch self {
            case .unlabelled: return "No VoiceOver label"
            case .tinyTarget: return "Tap target under 44pt"
            case .noHint:     return "Label is the class name"
            }
        }
        var symbol: String {
            switch self {
            case .unlabelled: return "speaker.slash"
            case .tinyTarget: return "hand.point.up.left"
            case .noHint:     return "questionmark.circle"
            }
        }
    }

    var id = UUID()
    let kind: Kind
    /// `UIButton` / `SwiftUI.ImageLayer` etc — the best name available for a view
    /// that by definition has no readable name.
    let element: String
    /// Where on screen, so the tester can find it without a highlight overlay.
    let frame: CGRect
    let detail: String

    var line: String {
        String(format: "[%@] %@ at %.0f,%.0f (%.0f×%.0f) — %@",
               kind.rawValue, element,
               frame.minX, frame.minY, frame.width, frame.height, detail)
    }
}

// MARK: - Sweep

@MainActor
@Observable
final class QAAccessibilitySweep {
    static let shared = QAAccessibilitySweep()

    private(set) var issues: [QAAccessibilityIssue] = []
    private(set) var lastRun: Date?
    private(set) var lastScreen: String = "—"
    private(set) var viewsWalked = 0
    private(set) var incomplete = false
    @ObservationIgnored private var scheduled: Task<Void, Never>?
    @ObservationIgnored private var deadline = Date.distantFuture
    @ObservationIgnored private var previousFinding = ""

    /// The tree is walked no deeper than this. A SwiftUI hierarchy is genuinely
    /// this deep in places, and an uncapped recursion over a pathological tree is
    /// a hang in the one place a hang is least excusable.
    private let maxDepth = 40
    /// And no more than this many views examined per run, for the same reason.
    private let maxViews = 4000

    private init() {}

    var hasRun: Bool { lastRun != nil }
    var unlabelled: [QAAccessibilityIssue] { issues.filter { $0.kind == .unlabelled } }
    var tinyTargets: [QAAccessibilityIssue] { issues.filter { $0.kind == .tinyTarget } }

    var summary: String {
        guard hasRun else { return "Not run on this screen yet." }
        if incomplete { return "Partial sweep on \(lastScreen) · \(issues.count) possible issues. Manual review remains available." }
        if issues.isEmpty { return "Nothing to fix on \(lastScreen)." }
        var bits: [String] = []
        if !unlabelled.isEmpty { bits.append("\(unlabelled.count) unlabelled") }
        if !tinyTargets.isEmpty { bits.append("\(tinyTargets.count) too small") }
        return bits.joined(separator: " · ") + " on \(lastScreen)"
    }

    /// Walks whatever is on screen right now.
    func run(automatic: Bool = false) {
        issues = []
        viewsWalked = 0
        incomplete = false
        deadline = Date().addingTimeInterval(automatic ? 0.008 : 0.04)
        lastScreen = QARecorder.shared.currentScreen
        lastRun = Date()

        guard let window = QAScreenshot.appWindow() else {
            incomplete = true
            QARecorder.shared.record(.note, label: "Accessibility sweep",
                                     detail: "no app window to walk")
            return
        }
        var found: [QAAccessibilityIssue] = []
        walk(window, in: window, depth: 0, into: &found)
        if Date() >= deadline { incomplete = true }

        // Two SwiftUI views can back one control and both report the same frame.
        // Reporting it twice makes the list look worse than the screen is.
        var seen = Set<String>()
        issues = found.filter { issue in
            let key = "\(issue.kind.rawValue)|\(Int(issue.frame.minX)),\(Int(issue.frame.minY)),\(Int(issue.frame.width)),\(Int(issue.frame.height))"
            return seen.insert(key).inserted
        }

        QARecorder.shared.record(incomplete ? .note : (issues.isEmpty ? .success : .failure),
                                 label: "Accessibility sweep · \(lastScreen)",
                                 detail: incomplete ? "Partial, bounded sweep; not an accessibility pass" : issues.isEmpty
                                 ? "\(viewsWalked) views, nothing to fix"
                                 : "\(issues.count) issue\(issues.count == 1 ? "" : "s") across \(viewsWalked) views")
    }

    private func walk(_ view: UIView, in window: UIWindow, depth: Int,
                      into out: inout [QAAccessibilityIssue]) {
        guard depth < maxDepth, viewsWalked < maxViews, Date() < deadline else {
            incomplete = true
            return
        }
        viewsWalked += 1

        // Invisible things cannot be tapped and are not read out. Skipping them
        // here is what keeps the report about the screen the tester is looking at
        // rather than about every cached off-screen cell.
        guard !view.isHidden, view.alpha > 0.01 else { return }
        let frame = view.convert(view.bounds, to: window)
        let onScreen = frame.intersects(window.bounds) && frame.width > 0 && frame.height > 0

        if onScreen, isInteractive(view) {
            let label = (view.accessibilityLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = String(describing: type(of: view))

            if label.isEmpty && !hasTextDescendant(view, depth: 0) {
                out.append(QAAccessibilityIssue(
                    kind: .unlabelled, element: name, frame: frame,
                    detail: "VoiceOver reads this as \"\(view.accessibilityTraits.contains(.button) ? "Button" : name)\" and nothing else"))
            } else if !label.isEmpty && label == name {
                out.append(QAAccessibilityIssue(
                    kind: .noHint, element: name, frame: frame,
                    detail: "the label is the type name, which describes nothing"))
            }

            if frame.width < 44 || frame.height < 44 {
                out.append(QAAccessibilityIssue(
                    kind: .tinyTarget, element: name, frame: frame,
                    detail: String(format: "%.0f×%.0f, Apple's floor is 44×44", frame.width, frame.height)))
            }
        }

        for sub in view.subviews {
            walk(sub, in: window, depth: depth + 1, into: &out)
            if Date() >= deadline || viewsWalked >= maxViews { incomplete = true; break }
        }
    }

    /// Something a person is meant to press. Deliberately narrow: a `UIView` with
    /// a tap recognizer attached is included, a decorative image is not.
    private func isInteractive(_ view: UIView) -> Bool {
        let hasGesture = view.gestureRecognizers?.contains {
            $0 is UITapGestureRecognizer || $0 is UILongPressGestureRecognizer
        } ?? false
        return QAAccessibilityAuditPolicy.shouldAudit(
            isAccessibilityElement: view.isAccessibilityElement,
            isControl: view is UIControl,
            hasButtonOrLinkTrait: view.accessibilityTraits.contains(.button) ||
                view.accessibilityTraits.contains(.link),
            isUserInteractionEnabled: view.isUserInteractionEnabled,
            hasTapOrLongPressGesture: hasGesture
        )
    }

    /// A button wrapping a `UILabel` is announced using that label's text, so it
    /// is not unlabelled even with no `accessibilityLabel` of its own. Shallow on
    /// purpose — a text view five levels down is not what is being read out.
    private func hasTextDescendant(_ view: UIView, depth: Int) -> Bool {
        guard depth < 3, Date() < deadline else { return false }
        if let label = view as? UILabel, !(label.text ?? "").isEmpty { return true }
        if let button = view as? UIButton,
           !(button.title(for: .normal) ?? "").isEmpty { return true }
        if let text = view.accessibilityValue, !text.isEmpty { return true }
        for sub in view.subviews where hasTextDescendant(sub, depth: depth + 1) { return true }
        return false
    }

    /// Read-only, debounced and frame-budgeted. Never taps through screens or
    /// claims full SwiftUI/VoiceOver coverage from the backing UIKit tree.
    func schedule(screen: String) {
        scheduled?.cancel()
        guard QARecorder.shared.isEnabled, screen != "—", !screen.lowercased().contains("qa") else { return }
        scheduled = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard let self, !Task.isCancelled, QARecorder.shared.isEnabled,
                  UIApplication.shared.applicationState == .active,
                  !QAReporterPresenter.shared.isPresenting,
                  !QAFloatingMenuPresenter.shared.isPresenting,
                  QARecorder.shared.currentScreen == screen,
                  ActiveCookSessionStore.shared.resumable?.status != .active else { return }
            self.run(automatic: true)
            let fingerprint = screen + "|" + self.issues.map(\.line).sorted().joined(separator: "|")
            // Two fresh complete observations, not an old cached sweep, are
            // required before filing a possible accessibility issue for review.
            if !self.incomplete, !self.issues.isEmpty, fingerprint == self.previousFinding {
                self.fileTicket()
            }
            self.previousFinding = self.incomplete || self.issues.isEmpty ? "" : fingerprint
        }
    }

    func cancel() { scheduled?.cancel(); scheduled = nil; previousFinding = "" }

    // MARK: Export

    var exportText: String {
        var out = ["── ACCESSIBILITY SWEEP ──",
                   "screen: \(lastScreen)",
                   "run: \(lastRun?.formatted() ?? "never")",
                   "views walked: \(viewsWalked)",
                   "coverage: \(incomplete ? "partial (budget/window limit)" : "visible UIKit controls only; manual VoiceOver review still required")",
                   ""]
        if issues.isEmpty {
            out.append(hasRun ? (incomplete ? "Incomplete; not a pass." : "No issues found in inspected controls.") : "Not run.")
        } else {
            out += issues.map { "  " + $0.line }
        }
        return out.joined(separator: "\n")
    }

    /// Turns the current findings into a ticket. Severity is `minor` on purpose:
    /// these are real and they are worth fixing, and they are not what stops a
    /// release. Filing them as blockers would train everyone to ignore them.
    @discardableResult
    func fileTicket() -> QATicket? {
        guard !issues.isEmpty else { return nil }
        var context = QAContextCapture.current()
        context.screen = lastScreen
        return QATicketStore.shared.open(
            title: "Accessibility: \(issues.count) issue\(issues.count == 1 ? "" : "s") on \(lastScreen)",
            body: exportText,
            severity: .minor,
            requiresManualReview: true,
            context: context,
            origin: .automatic,
            automaticCheckID: "accessibility:\(lastScreen)",
            screenshot: QAScreenshot.capture())
    }
}

// MARK: - Screen

struct QAAccessibilitySweepView: View {
    @State private var sweep = QAAccessibilitySweep.shared
    @State private var filed = ""

    var body: some View {
        List {
            Section {
                Button {
                    sweep.run()
                } label: {
                    Label("Sweep this screen", systemImage: "figure.walk.circle")
                }
                if sweep.hasRun {
                    Text(sweep.summary)
                        .font(.stocked(.caption))
                        .foregroundStyle(sweep.issues.isEmpty ? Color.stockedGreen : Color.stockedWarning)
                }
            } header: {
                Text("Run")
            } footer: {
                Text("Walks the live view tree of whatever the app was showing when you opened QA, looking for controls VoiceOver cannot name and tap targets under 44×44pt. Open the screen you want checked first, then come here — it can only see what is currently mounted.")
            }

            if !sweep.issues.isEmpty {
                Section("Findings (\(sweep.issues.count))") {
                    ForEach(sweep.issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: issue.kind.symbol)
                                .font(.stocked(.caption))
                                .foregroundStyle(Color.stockedWarning)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(issue.kind.title).scaledFont(13, weight: .medium)
                                Text(issue.element)
                                    .scaledFont(10, design: .monospaced)
                                    .foregroundStyle(.secondary)
                                Text(issue.detail).font(.stocked(.caption2)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(String(format: "at %.0f, %.0f · %.0f×%.0f",
                                            issue.frame.minX, issue.frame.minY,
                                            issue.frame.width, issue.frame.height))
                                    .scaledFont(10, design: .monospaced)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }

                Section {
                    Button {
                        if let t = sweep.fileTicket() { filed = "Filed \(t.number)" }
                    } label: {
                        Label("File these as a ticket", systemImage: "ticket")
                    }
                    ShareLink(item: sweep.exportText) {
                        Label("Share findings", systemImage: "square.and.arrow.up")
                    }
                    if !filed.isEmpty {
                        Text(filed).font(.stocked(.caption)).foregroundStyle(Color.stockedGreen)
                    }
                } footer: {
                    Text("Filed as minor. These are worth fixing and none of them stop a release — filing them as blockers is how a team learns to ignore accessibility tickets.")
                }
            }
        }
        .navigationTitle("Accessibility")
        .navigationBarTitleDisplayMode(.inline)
        .qaScreen("QA > Accessibility sweep")
    }
}
