// QATicketStore.swift
// ─────────────────────────────────────────────────────────────────────────────
// Tickets: what a long press turns into.
//
// THE PROBLEM THIS SOLVES
// A tester finds something wrong, and by the time they have switched apps, found
// the notes file, and started typing, the useful part is gone — which screen,
// what they tapped to get there, what was in flight, what the memory looked like,
// whether an invariant was already violated. What survives is "the recipe screen
// was weird". That is not a bug report, it is a rumour.
//
// So the report is captured where the bug is: press and hold anywhere while QA
// mode is on, describe it in a sentence, done. Everything else — screen, the last
// forty steps, running and stalled processes, failing invariants, memory,
// thermal state, connectivity, build, device, and a screenshot of exactly what
// was on screen — is attached automatically, because the app already knows all of
// it and the tester should not have to.
//
// TICKET NUMBERS
// `STK-<build>-<seq>`, e.g. STK-71-0007. The sequence is global and monotonic per
// install (it never rewinds when a ticket is deleted), and the build number is in
// the middle so a number alone tells you which binary produced it. This matches
// the `STK-` shape the support diagnostics uploader already returns, so a tester
// quoting "STK-71-0007" is speaking the same language as the rest of the system.
//
// SYNCING
// Tickets ride the QA bridge that everything else already uses —
// `QAReportTransport.post` to /qa/reports, with its own schema tag. No new route,
// no Worker deploy needed to start collecting them. Each ticket tracks whether it
// has been pushed, and unsynced tickets retry on the next publish, so a ticket
// filed on the tube is not a ticket lost.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
import UIKit
import Observation

// MARK: - Model

nonisolated enum QATicketSeverity: String, Codable, Sendable, CaseIterable, Identifiable {
    case blocker, major, minor, note
    var id: String { rawValue }

    var title: String {
        switch self {
        case .blocker: return "Blocker"
        case .major:   return "Major"
        case .minor:   return "Minor"
        case .note:    return "Note"
        }
    }
    var symbol: String {
        switch self {
        case .blocker: return "octagon.fill"
        case .major:   return "exclamationmark.triangle.fill"
        case .minor:   return "exclamationmark.circle"
        case .note:    return "text.bubble"
        }
    }
    var rank: Int {
        switch self {
        case .blocker: return 0
        case .major:   return 1
        case .minor:   return 2
        case .note:    return 3
        }
    }
}

nonisolated enum QATicketStatus: String, Codable, Sendable, CaseIterable, Identifiable {
    case open, investigating, fixed, verified, wontFix
    var id: String { rawValue }

    var title: String {
        switch self {
        case .open:          return "Open"
        case .investigating: return "Investigating"
        case .fixed:         return "Fixed"
        case .verified:      return "Verified"
        case .wontFix:       return "Won't fix"
        }
    }
    var symbol: String {
        switch self {
        case .open:          return "circle"
        case .investigating: return "magnifyingglass.circle.fill"
        case .fixed:         return "checkmark.circle.fill"
        case .verified:      return "checkmark.seal.fill"
        case .wontFix:       return "slash.circle"
        }
    }
    var isClosed: Bool { self == .verified || self == .wontFix }
}

/// Everything the app knew at the moment the ticket was raised. Captured
/// automatically — the tester types a sentence, this fills in the rest.
nonisolated struct QATicketContext: Codable, Sendable {
    var screen: String = "—"
    var breadcrumbs: [String] = []
    var runningProcesses: [String] = []
    var stalledProcesses: [String] = []
    var recentFailures: [String] = []
    var openViolations: [String] = []
    var appVersion: String = ""
    var build: Int = 0
    var device: String = ""
    var os: String = ""
    var memoryMB: Double = 0
    var thermal: String = ""
    var lowPower: Bool = false
    var online: Bool = true
    var freeDiskMB: Double = 0
    var sessionDuration: String = ""
    var tapsOnScreen: Int = 0
    var worstHitchMs: Double = 0
    /// Where the last few touches landed, as coordinates (Build 73). Optional
    /// for the same reason `QATicket.origin` is — synthesized `Codable` throws
    /// on a missing key rather than using the property's default, so every
    /// field added to a persisted type has to be an Optional or it wipes the
    /// saved list on upgrade.
    ///
    /// Text as well as pixels, deliberately: screenshots live in Caches and iOS
    /// may reclaim them under storage pressure, at which point this line is the
    /// only surviving record of what was pressed.
    var touchTrail: String?

    /// Build 74. Text size, appearance, orientation, screen geometry, the
    /// accessibility switches that are on, battery, locale and uptime — the
    /// settings that decide whether a layout bug reproduces, none of which were
    /// captured before. See QAEnvironmentSnapshot.swift.
    ///
    /// Optional, like `touchTrail` above and for the same reason: synthesised
    /// `Codable` throws on a missing key rather than defaulting, and the decode
    /// of the saved ticket list is inside a `try?`.
    var environment: [String]?

    var summaryLines: [String] {
        var out: [String] = []
        out.append("screen: \(screen)")
        out.append("build: \(appVersion) (\(build)) · \(device) · \(os)")
        out.append(String(format: "memory: %.0f MB · thermal: %@%@ · %@",
                          memoryMB, thermal, lowPower ? " · low power" : "",
                          online ? "online" : "OFFLINE"))
        if freeDiskMB > 0 { out.append(String(format: "free disk: %.0f MB", freeDiskMB)) }
        out.append("session: \(sessionDuration) · taps on this screen: \(tapsOnScreen)")
        if worstHitchMs > 0 { out.append(String(format: "worst frame hitch: %.0f ms", worstHitchMs)) }
        if let t = touchTrail, !t.isEmpty { out.append(t) }
        if let env = environment, !env.isEmpty { out.append(contentsOf: env) }
        return out
    }
}

/// Who raised the ticket. The event feed used to say "reported by tester" for
/// every ticket including the ones the runtime monitor filed by itself, which
/// read as a person having typed something they never typed.
///
/// OPTIONAL ON PURPOSE: synthesized `Codable` does NOT fall back to a property's
/// default when the key is missing — it throws. Tickets written by an earlier
/// build have no `origin` key, and a non-optional property here would fail the
/// whole decode and silently wipe the saved ticket list. An Optional decodes a
/// missing key as nil.
nonisolated enum QATicketOrigin: String, Codable, Sendable {
    case tester
    case automatic

    var phrase: String {
        switch self {
        case .tester:    return "reported by tester"
        case .automatic: return "raised automatically"
        }
    }
}

nonisolated struct QATicket: Identifiable, Codable, Sendable {
    var id = UUID()
    var number: String
    var title: String
    var body: String = ""
    var origin: QATicketOrigin?
    var severity: QATicketSeverity = .major
    var status: QATicketStatus = .open
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var context = QATicketContext()
    /// Filename inside the QA screenshot directory, not a full path — a sandbox
    /// container path is not stable across installs and would rot in defaults.
    var screenshotFile: String?
    var syncedAt: Date?
    var syncError: String = ""

    // ── Build 73 ────────────────────────────────────────────────────────────
    // EVERY ONE OF THESE IS AN OPTIONAL, AND THAT IS NOT STYLE.
    // Synthesized `Codable` throws on a missing key rather than falling back to
    // the property's default. A single non-optional added here would fail the
    // decode of every ticket written by Build 72 or earlier, and `load()`
    // swallows the error — so the whole ticket list would quietly empty itself
    // on first launch after the update. Optionals decode a missing key as nil.

    /// A picture of what it *should* look like, attached after the fact from
    /// Files or Photos. Filename inside the mockup directory, same reasoning as
    /// `screenshotFile`.
    var mockupFile: String?
    /// Set the first time a ticket is edited after filing, so a reader can tell
    /// "this is what the tester typed in the moment" from "this was rewritten
    /// later with hindsight". `updatedAt` cannot carry that — it also moves for
    /// a status change.
    var editedAt: Date?
    var editCount: Int?
    /// Per-destination stamps. Three destinations sync independently and a
    /// single `syncedAt` cannot say "the worker has it but the Mac folder does
    /// not", which is exactly the state to be able to see.
    var shotSyncedAt: Date?
    var mirroredAt: Date?
    var cpanelSyncedAt: Date?

    // ── Build 74 ──────────────────────────────────────────────────────────
    // Every one of these is Optional for the reason spelled out on `origin`
    // above: synthesised `Codable` throws on a missing key instead of falling
    // back to the default, and `load()` swallows that throw. A non-Optional
    // field added here would erase the whole saved ticket list on upgrade.

    /// The checkbook row this was filed from — "QA-12-03". See
    /// QACheckTickets.swift for the other end of the link.
    var checkTicket: String?
    /// The number of the earlier open ticket this appears to repeat.
    var duplicateOf: String?
    /// How many times this ticket has been re-reported since it was filed. The
    /// count is on the *original*, so the original is the row that says "this
    /// keeps happening" — which is the fact worth surfacing.
    var seenAgain: Int?
    var seenAgainAt: Date?
    /// The test run that was open when this was filed. See QARunLog.swift.
    var runID: String?
    /// Agent/developer summary shown to the tester before verification.
    var resolution: String?
    /// Tester-selected when the wording or design intent needs a person to
    /// clarify it before an agent can safely infer a fix. Optional preserves
    /// decoding of tickets created by earlier builds.
    var requiresManualReview: Bool?
    var verifiedAt: Date?
    var refileCount: Int?

    var isSynced: Bool { syncedAt != nil }
    var isFullySynced: Bool {
        guard syncedAt != nil, mirroredAt != nil else { return false }
        if screenshotFile != nil && shotSyncedAt == nil { return false }
        if QACPanelSettings.isConfigured && cpanelSyncedAt == nil { return false }
        return true
    }
    var wasEdited: Bool { editedAt != nil }
    var hasMockup: Bool { mockupFile != nil }
    var isDuplicate: Bool { duplicateOf != nil }
    var recurrenceCount: Int { (seenAgain ?? 0) + 1 }
    var isRecurring: Bool { (seenAgain ?? 0) > 0 }
    var fromCheckbook: Bool { checkTicket != nil }

    /// One line naming which of the three destinations currently hold this
    /// ticket. Shown under the re-sync button so "sync" is not a black box.
    var destinationLine: String {
        var have: [String] = []
        var missing: [String] = []
        if syncedAt   != nil { have.append("worker") } else { missing.append("worker") }
        if mirroredAt != nil { have.append("folder") } else { missing.append("folder") }
        if QACPanelSettings.isConfigured {
            if cpanelSyncedAt != nil { have.append("cPanel") } else { missing.append("cPanel") }
        }
        if missing.isEmpty { return "Everywhere: " + have.joined(separator: ", ") }
        if have.isEmpty { return "Not sent anywhere yet" }
        return "On " + have.joined(separator: ", ") + " · missing " + missing.joined(separator: ", ")
    }

    var line: String {
        "\(number) [\(severity.rawValue)/\(status.rawValue)] \(title) — \(context.screen)"
    }

    /// One line of prose for surfaces that have room for a sentence, not a
    /// report — the triage list, notifications, the HUD.
    ///
    /// WAS: callers took `body.prefix(120)` of a multi-paragraph body, which cut
    /// mid-word in the middle of the *first* paragraph and rendered the rest of
    /// the ticket as a blank gap ("…did not produce a frame for 78661 ms w").
    /// This collapses the whole body to a single spaced line first, then trims
    /// on a word boundary and marks the cut.
    func summary(limit: Int = 140) -> String {
        let flat = body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard flat.count > limit else { return flat }
        let clipped = flat.prefix(limit)
        // Back up to the last space so a word is never sawn in half.
        let trim = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        if let cut = clipped.lastIndex(of: " ") {
            return String(clipped[clipped.startIndex..<cut]).trimmingCharacters(in: trim) + "…"
        }
        return String(clipped) + "…"
    }

    var summaryLine: String { summary() }

    var originPhrase: String { (origin ?? .tester).phrase }

    var exportText: String {
        var out = ["── \(number) ──",
                   "\(severity.title) · \(status.title) · \(originPhrase) · \(createdAt.formatted())",
                   title]
        if requiresManualReview == true { out.append("⚠ REQUIRES MANUAL REVIEW — ask the tester for specifics before changing code") }
        if !body.isEmpty { out.append(""); out.append(body) }
        out.append("")
        out.append(contentsOf: context.summaryLines.map { "  " + $0 })
        if !context.breadcrumbs.isEmpty {
            out.append("")
            out.append("  steps before the report:")
            out.append(contentsOf: context.breadcrumbs.map { "    " + $0 })
        }
        if !context.stalledProcesses.isEmpty {
            out.append("")
            out.append("  stalled at the time:")
            out.append(contentsOf: context.stalledProcesses.map { "    " + $0 })
        }
        if !context.runningProcesses.isEmpty {
            out.append("")
            out.append("  in flight at the time:")
            out.append(contentsOf: context.runningProcesses.map { "    " + $0 })
        }
        if !context.recentFailures.isEmpty {
            out.append("")
            out.append("  recent failures:")
            out.append(contentsOf: context.recentFailures.map { "    " + $0 })
        }
        if !context.openViolations.isEmpty {
            out.append("")
            out.append("  invariants violating:")
            out.append(contentsOf: context.openViolations.map { "    " + $0 })
        }
        out.append("")
        if let check = checkTicket { out.append("  from checkbook row: \(check)") }
        if let dup = duplicateOf { out.append("  looks like a repeat of: \(dup)") }
        if let again = seenAgain, again > 0 {
            out.append("  reported \(again + 1) times" +
                       (seenAgainAt.map { ", most recently \($0.formatted())" } ?? ""))
        }
        if let run = runID, let name = QARunLog.name(forID: run) {
            out.append("  test run: \(name)")
        }
        out.append("  screenshot: \(screenshotFile == nil ? "none" : "attached")")
        out.append("  synced: \(syncedAt.map { $0.formatted() } ?? (syncError.isEmpty ? "not yet" : "failed — \(syncError)"))")
        return out.joined(separator: "\n")
    }
}

// MARK: - Store

@MainActor
@Observable
final class QATicketStore {
    static let shared = QATicketStore()

    private(set) var tickets: [QATicket] = []
    private let cap = 200

    private nonisolated static let ticketsKey = "qa.tickets.v1"
    private nonisolated static let seqKey     = "qa.ticket.sequence.v1"

    // Build 84 - see save(): the encode-and-write is coalesced and off-main.
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    // Build 84 - see saveScreenshot(): the pixels land on disk off-main; anyone
    // about to read them awaits the write first.
    @ObservationIgnored private var pendingShotWrites: [UUID: Task<Void, Never>] = [:]

    private init() {
        load()
        applyShippedResolutions()
    }

    // MARK: Numbering

    /// Monotonic per install. Deleting a ticket does not free its number: two
    /// different bugs sharing "STK-71-0004" across a week of testing is worse
    /// than a gap in the sequence.
    private func nextNumber() -> String {
        let d = UserDefaults.standard
        let next = d.integer(forKey: Self.seqKey) + 1
        d.set(next, forKey: Self.seqKey)
        return String(format: "STK-%d-%04d", BuildConfig.buildNumber, next)
    }

    // MARK: Creating

    /// Raise a ticket. `context` is captured by the caller (the reporter overlay
    /// grabs it at gesture time, before the sheet animates in and the screen
    /// underneath starts changing).
    @discardableResult
    func open(title: String,
              body: String = "",
              severity: QATicketSeverity = .major,
              requiresManualReview: Bool = false,
              context: QATicketContext,
              origin: QATicketOrigin = .tester,
              screenshot: UIImage? = nil) -> QATicket {
        // Build 73: attach the touch trail here rather than in `QAContextCapture`,
        // so it lands on tickets the runtime monitor raises by itself as well as
        // on ones a tester types — those are precisely the tickets where nobody
        // remembers what was pressed. `??` rather than an overwrite, so a caller
        // that captured its own trail at gesture time (before the sheet animated
        // in and started collecting taps of its own) keeps it.
        var context = context
        if context.touchTrail == nil {
            let trail = QATouchTrail.shared.summaryLine()
            if !trail.isEmpty { context.touchTrail = trail }
        }

        // Build 74: the environment snapshot is attached here rather than in
        // `QAContextCapture` for the same reason the touch trail is — so tickets
        // the runtime monitor raises by itself carry it too, and those are the
        // tickets where nobody can be asked afterwards what their text size was.
        if context.environment == nil {
            context.environment = QAEnvironmentSnapshot.lines()
        }

        var ticket = QATicket(number: nextNumber(),
                              title: title.isEmpty ? "Untitled report" : title,
                              body: body,
                              origin: origin,
                              severity: severity,
                              context: context)
        ticket.requiresManualReview = requiresManualReview
        if let screenshot { ticket.screenshotFile = saveScreenshot(screenshot, for: ticket.id) }

        // Build 74: does this repeat something already open? The new ticket is
        // filed either way — a report a tester typed is never silently swallowed,
        // because they may have added the one detail that cracks it — but it is
        // stamped, and the original's counter goes up so the *original* is what
        // says "this keeps happening".
        if let original = QADuplicateFinder.match(title: ticket.title,
                                                  body: ticket.body,
                                                  screen: context.screen,
                                                  among: tickets) {
            ticket.duplicateOf = original.number
            if let i = tickets.firstIndex(where: { $0.id == original.id }) {
                tickets[i].seenAgain = (tickets[i].seenAgain ?? 0) + 1
                tickets[i].seenAgainAt = Date()
                tickets[i].updatedAt = Date()
                // The original's copies at every destination are now out of date
                // — they say this happened once.
                tickets[i].syncedAt = nil
                tickets[i].mirroredAt = nil
                tickets[i].cpanelSyncedAt = nil
                scheduleLocalMirror(tickets[i].id)

                // Automatic monitors describe recurrence, not a new human
                // report. Retain one durable root ticket and increment it rather
                // than flooding every device and Worker history with a new row
                // for the same screen-level freeze every minute. Tester-authored
                // reports are still always preserved separately.
                if origin == .automatic && original.origin == .automatic {
                    tickets[i].context = context
                    if severity.rank < tickets[i].severity.rank {
                        tickets[i].severity = severity
                    }
                    let recurring = tickets[i]
                    save()
                    if QABackgroundRunner.shared.autoPublish {
                        Task { await QASyncCoordinator.shared.syncEverywhere(recurring.id) }
                    }
                    return recurring
                }
            }
        }

        // Build 74: whatever test run is open owns this ticket.
        ticket.runID = QARunLog.shared.currentID

        tickets.insert(ticket, at: 0)
        if tickets.count > cap { trim() }
        save()
        scheduleLocalMirror(ticket.id)

        // A ticket is a first-class QA signal, not a note on the side: it lands in
        // the event feed, the breadcrumb trail, and the process log, so every
        // other QA surface updates itself the moment one is raised.
        QARecorder.shared.record(severity == .note ? .note : .failure,
                                 screen: context.screen,
                                 label: "\(ticket.number) \(ticket.title)",
                                 detail: "\(origin.phrase) · \(severity.title)")
        QAProcessTracker.shared.mark("Ticket \(ticket.number)", detail: ticket.title)
        QARecorder.shared.persistSnapshot(reason: "ticket \(ticket.number)")
        QARunLog.shared.recordTicket(ticket.number)
        if let dup = ticket.duplicateOf {
            QARecorder.shared.record(.note, screen: context.screen,
                                     label: "\(ticket.number) repeats \(dup)",
                                     detail: "same wording, same screen, still open")
        }

        // Push immediately when auto-publish is on; otherwise it waits for the
        // next manual publish and is listed as unsynced until then.
        //
        // Build 73: the full fan-out, not just the worker. The folder write is
        // local and near-instant, so the common case — a tester filing a ticket
        // with no signal — now still ends with a complete ticket folder sitting
        // in iCloud waiting to upload, instead of nothing at all.
        if QABackgroundRunner.shared.autoPublish {
            let id = ticket.id
            Task {
                // Build 84 - the screenshot write is asynchronous now; let it
                // land before the fan-out reads the bytes back for upload.
                await QATicketStore.shared.awaitScreenshotWrite(id)
                await QASyncCoordinator.shared.syncEverywhere(id)
            }
        }
        return ticket
    }

    // MARK: Mutating

    func update(_ id: UUID, _ mutate: (inout QATicket) -> Void) {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        mutate(&tickets[i])
        tickets[i].updatedAt = Date()
        // Any edit invalidates the pushed copy, so it re-syncs rather than
        // leaving a destination holding a stale version of a ticket that
        // changed. All three stamps clear, not just the worker's — a Mac folder
        // holding last week's wording is exactly as wrong as a KV entry doing
        // the same.
        tickets[i].syncedAt = nil
        tickets[i].shotSyncedAt = nil
        tickets[i].mirroredAt = nil
        tickets[i].cpanelSyncedAt = nil
        save()
        scheduleLocalMirror(id)
        if QABackgroundRunner.shared.autoPublish {
            Task { await QASyncCoordinator.shared.syncEverywhere(id) }
        }
    }

    /// Edit the text of a filed ticket.
    ///
    /// Separate from `update` because it means something different: `update` is
    /// used for triage (status, severity), which is metadata about the ticket,
    /// while this rewrites the report itself. Only this path stamps `editedAt`,
    /// so a reader can tell a re-worded report from a re-triaged one, and only
    /// this path appends to the body's history.
    ///
    /// The original wording is preserved rather than overwritten. A tester who
    /// tidies up "it broke" into a clean repro three days later has, without
    /// meaning to, destroyed the evidence of what they thought at the time —
    /// which is often the part that says where to look.
    func edit(_ id: UUID,
              title newTitle: String,
              body newBody: String,
              severity newSeverity: QATicketSeverity,
              requiresManualReview newRequiresManualReview: Bool,
              keepHistory: Bool = true) {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        let old = tickets[i]
        let titleChanged = old.title != newTitle
        let bodyChanged  = old.body  != newBody
        guard titleChanged || bodyChanged || old.severity != newSeverity ||
                (old.requiresManualReview ?? false) != newRequiresManualReview else { return }

        var body = newBody
        if keepHistory, bodyChanged || titleChanged {
            let stamp = ISO8601DateFormatter().string(from: Date())
            var note = ["", "── edited \(stamp) ──"]
            if titleChanged { note.append("was titled: \(old.title)") }
            if bodyChanged, !old.body.isEmpty {
                note.append("was:")
                note.append(contentsOf: old.body
                    .split(whereSeparator: \.isNewline)
                    .map { "  " + String($0) })
            }
            body += "\n" + note.joined(separator: "\n")
        }

        update(id) {
            $0.title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? old.title : newTitle
            $0.body = body
            $0.severity = newSeverity
            $0.requiresManualReview = newRequiresManualReview
            $0.editedAt = Date()
            $0.editCount = ($0.editCount ?? 0) + 1
        }

        QARecorder.shared.record(.note, screen: "QA",
                                 label: "\(old.number) edited",
                                 detail: "now \(newSeverity.title)")
    }

    func setStatus(_ id: UUID, _ status: QATicketStatus) {
        update(id) { $0.status = status }
        if let t = tickets.first(where: { $0.id == id }) {
            QARecorder.shared.record(.note, screen: "QA",
                                     label: "\(t.number) → \(status.title)")
            if QABackgroundRunner.shared.autoPublish {
                Task { await QASyncCoordinator.shared.syncEverywhere(id) }
            }
        }
    }

    func markFixed(_ id: UUID, resolution: String) {
        let text = resolution.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        update(id) { $0.status = .fixed; $0.resolution = text; $0.verifiedAt = nil }
    }

    func verifyFix(_ id: UUID) {
        update(id) { $0.status = .verified; $0.verifiedAt = Date() }
    }

    func refile(_ id: UUID) {
        update(id) {
            $0.status = .open; $0.verifiedAt = nil
            $0.refileCount = ($0.refileCount ?? 0) + 1
            $0.body += "\n\nRefiled after fix verification on \(Date().formatted())."
        }
    }

    func delete(_ id: UUID) {
        if let t = tickets.first(where: { $0.id == id }) {
            discardFiles(t)
            Task { await QAFolderMirror.shared.removeTicket(number: t.number, build: t.context.build) }
        }
        tickets.removeAll { $0.id == id }
        save()
    }

    func clear() {
        for t in tickets { discardFiles(t) }
        tickets = []
        save()
    }

    private func trim() {
        let overflow = tickets.count - cap
        guard overflow > 0 else { return }
        for t in tickets.suffix(overflow) { discardFiles(t) }
        tickets.removeLast(overflow)
    }

    // MARK: Derived

    var open: [QATicket] { tickets.filter { !$0.status.isClosed } }
    var blockers: [QATicket] { tickets.filter { $0.severity == .blocker && !$0.status.isClosed } }
    /// Missing any required/configured destination, not merely the Worker.
    var unsynced: [QATicket] { tickets.filter { !$0.isFullySynced } }

    var openCount: Int { open.count }

    /// Screens with more than one open ticket. A single report is an incident;
    /// three on the same screen is a pattern, and the pattern is the finding.
    var hotspots: [QAScreenCount] {
        var byScreen: [String: Int] = [:]
        for t in open { byScreen[t.context.screen, default: 0] += 1 }
        return byScreen.filter { $0.value > 1 }
            .map { QAScreenCount(screen: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    func sorted(status: QATicketStatus?, severity: QATicketSeverity?, search: String) -> [QATicket] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return tickets.filter { t in
            (status == nil || t.status == status!)
                && (severity == nil || t.severity == severity!)
                && (q.isEmpty
                    || t.title.lowercased().contains(q)
                    || t.body.lowercased().contains(q)
                    || t.number.lowercased().contains(q)
                    || t.context.screen.lowercased().contains(q))
        }
        .sorted {
            if $0.status.isClosed != $1.status.isClosed { return !$0.status.isClosed }
            if $0.severity.rank != $1.severity.rank { return $0.severity.rank < $1.severity.rank }
            return $0.createdAt > $1.createdAt
        }
    }

    // MARK: Persistence

    private func save() {
        // Build 84 (STK-77-0003/-0006) - this encoded every ticket, each carrying
        // forty breadcrumbs and an environment block, synchronously on the main
        // actor - and it runs inside open(), which is exactly the moment the
        // runtime monitor files a freeze ticket. Filing a freeze report was
        // itself part of the freeze, which is why the field sessions show them
        // arriving in cascades. Coalesced (a burst of saves encodes once) and
        // encoded off the main thread; QATicket is Sendable. The rare loss case
        // - a kill between scheduling and the utility task running - costs one
        // save, and the next persistSnapshot still tells the story.
        let snapshot = tickets
        saveTask?.cancel()
        saveTask = Task.detached(priority: .utility) {
            guard !Task.isCancelled else { return }
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            guard !Task.isCancelled else { return }
            UserDefaults.standard.set(data, forKey: Self.ticketsKey)
        }
    }

    private func scheduleLocalMirror(_ id: UUID) {
        Task { @MainActor in
            // Coalesce the mutation and allow asynchronous image writes to begin.
            try? await Task.sleep(for: .milliseconds(150))
            _ = await QASyncCoordinator.shared.mirrorTicket(id)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.ticketsKey),
              let decoded = try? JSONDecoder().decode([QATicket].self, from: data) else { return }
        tickets = decoded
    }

    /// Resolution registry compiled into the build. This is how an agent's fix
    /// reaches the phone without rewriting generated report artifacts: after the
    /// updated build is installed, matching local tickets become Fixed (never
    /// Verified), show exactly what changed, and enter the normal sync queue.
    private func applyShippedResolutions() {
        var changed = false
        for index in tickets.indices where tickets[index].status != .verified {
            guard let text = Self.shippedResolution(for: tickets[index]) else { continue }
            guard tickets[index].status != .fixed || tickets[index].resolution != text else { continue }
            tickets[index].status = .fixed
            tickets[index].resolution = text
            tickets[index].verifiedAt = nil
            tickets[index].updatedAt = Date()
            tickets[index].syncedAt = nil
            tickets[index].mirroredAt = nil
            tickets[index].cpanelSyncedAt = nil
            changed = true
        }
        if changed { save() }
    }

    nonisolated static func shippedResolution(for ticket: QATicket) -> String? {
        let historicalRuntimeFreezeTickets: Set<String> = [
            "STK-78-0001", "STK-80-0015", "STK-80-0024", "STK-93-0012",
            "STK-93-0013", "STK-93-0014", "STK-93-0015", "STK-93-0016",
            "STK-93-0017", "STK-96-0004", "STK-98-0013", "STK-98-0014",
            "STK-98-0015", "STK-98-0016", "STK-107-0018"
        ]
        if historicalRuntimeFreezeTickets.contains(ticket.number) {
            return "Moved persisted ticket/image work and heavy Home/Recipes classification off repeated render paths, added a stable-frame warm-up after launch/foreground restoration, and collapsed recurring automatic screen freezes into one cumulative ticket instead of refiling duplicates."
        }
        let repeatedRootTabFreezeTickets: [String: String] = [
            "STK-68-0001": "Home",
            "STK-68-0002": "Home",
            "STK-68-0008": "Cook",
            "STK-68-0009": "Cook",
            "STK-78-0005": "Recipes",
            "STK-78-0008": "Recipes"
        ]
        if let tab = repeatedRootTabFreezeTickets[ticket.number] {
            return "Coalesced rapid taps on the already-selected \(tab) tab so one tap still pops to root while repeated taps during the transition no longer rebuild the complete \(tab) NavigationStack and screen tree multiple times on the main actor."
        }
        let uniformRecipeImageTickets: Set<String> = [
            "STK-68-0004",
            "STK-78-0014",
            "STK-80-0020",
            "STK-80-0022"
        ]
        if uniformRecipeImageTickets.contains(ticket.number) {
            return "Standardized compact recipe collections on one reusable fork-and-knife thumbnail across Cook Now, Based on Inventory, and Drinks, eliminating mixed remote photos, emoji, and empty Meal Photo placeholders while retaining real photography on recipe detail and hero screens."
        }
        let settingsPresentationResolutions: [String: String] = [
            "STK-68-0006": "Consolidated every QA control and tool behind the single Settings > QA entry; App Health now contains health information only and no duplicate QA menu.",
            "STK-78-0011": "Removed the inactive Theme and Background appearance controls so Settings presents only appearance choices that change the current app.",
            "STK-80-0025": "Settings labels, segmented controls, and supporting text now use adaptive app text colors instead of fixed black foregrounds in dark mode.",
            "STK-80-0026": "Removed the inactive Home Buttons orientation selector; Home uses its supported adaptive layout rather than offering a control with no visible effect.",
            "STK-86-0001": "Made recipe Ingredients and Instructions independently collapsible, collapsed by default, with animated disclosure controls and VoiceOver expand/collapse labels.",
            "STK-86-0002": "Connected each ingredient substitution button to the recipe detail scroll view so it expands Substitutions, scrolls the section into view after layout, and highlights the matching ingredient.",
            "STK-107-0019": "Settings now fills its complete sheet with the same adaptive Stocked background, card, text, and accent colors as the rest of the app in both light and dark mode.",
            "STK-110-0014": "Moved Cook Button controls into the themed Preferences card and added a reusable presentation surface that fills centralized sheets with the active Stocked background, colors, Dynamic Type, and live width-class layout instead of the system-white host."
        ]
        if let resolution = settingsPresentationResolutions[ticket.number] {
            return resolution
        }
        let currentTicketResolutions: [String: String] = [
            "STK-92-0001": "Home now renders its first frame before deriving the kitchen snapshot and computes that snapshot once per store revision, eliminating repeated inventory and recipe passes during a single body update.",
            "STK-92-0002": "Home cards and buttons now use the live container width with smaller edge insets, a comfortable default control scale, and an Interface Size preference for Standard, Comfortable, or Large controls.",
            "STK-92-0003": "All shell pages now use up to 1,180 points of live window width instead of the old narrow reading-column cap, while compact windows retain safe edge padding.",
            "STK-93-0015": "Added an app-wide Interface Size preference and container-driven sizing so iPad controls default to Comfortable and can be enlarged without changing the device's system text size.",
            "STK-93-0018": "Inventory Scan now falls back from a failed cloud provider to Apple Foundation Models and then to Stocked's deterministic on-device zone and shelf-life audit, so exhausted provider credit no longer blocks inventory correction.",
            "STK-92-0004": "Required image-backed recipes in every recipe collection and routed Drinks through the same original-image resolver and cache as the rest of the library.",
            "STK-92-0009": "Cook Now now excludes recipes without usable images and renders publisher-original photography through the shared lossless image cache.",
            "STK-107-0001": "Applied the active Stocked theme to the complete popover and sheet presentation surface instead of leaving a stock system background.",
            "STK-107-0002": "Centralized themed presentation styling across pages, sheets, popovers, alerts, text fields, and controls in light and dark mode.",
            "STK-107-0003": "Replaced narrow fixed sheet geometry with container-driven sizing, adaptive detents, and scrolling only when the available iPad window actually requires it.",
            "STK-107-0005": "Filtered every Recipes collection through the shared image-completeness gate and continuously removes historical recipes whose image cannot be recovered.",
            "STK-107-0007": "Made recipe controls and cards use the live window metrics, accessible minimum targets, and the app-wide Interface Size preference on iPhone and iPad.",
            "STK-107-0008": "Cook Now now hydrates and classifies the full shared recipe library before rendering tiers, with persisted results available while remote refreshes run.",
            "STK-107-0009": "Cook Now results now use adaptive columns and the available iPad width in portrait, landscape, Split View, and Stage Manager instead of retaining a narrow phone column.",
            "STK-107-0010": "Applied the required-image gate and publisher-original image resolver to every Cook Now result tier, including historical imported recipes.",
            "STK-90-0001": "Preserved and displayed each recipe's original publisher attribution across StockedMac import, Worker sync, historical repair, and Stocked iOS instead of labeling the source StockedMac.",
            "STK-96-0006": "Repaired legacy StockedMac attribution from durable source URLs and made future sync payloads retain the publisher name and URL.",
            "STK-92-0011": "Unified Create with AI across entry points: it can scan the complete inventory, recommend existing or generated recipes, and carries substitution choices into the result flow.",
            "STK-92-0010": "Cook Now now prioritizes recipes whose primary protein is in inventory and keeps useful near-matches visible through the ten-missing-item tier.",
            "STK-92-0008": "Reduced Grocery to the shared Stocked background, surface, text, urgency, and gold accent tokens instead of stacking unrelated shades for each section.",
            "STK-92-0007": "Cook button shape and size now persist locally, participate in kitchen preference transfer and household sync, and restore across updates, reinstalls, and devices.",
            "STK-92-0006": "Settings now uses the high-contrast primary text token in light mode and reserves muted colors for secondary descriptions.",
            "STK-92-0005": "Settings text now follows the active semantic foreground color, including white primary copy on dark surfaces.",
            "STK-107-0013": "Inventory recommendations now hydrate from the same complete persisted and online recipe catalog used by Recipes and Cook, then apply the shared matching algorithm.",
            "STK-107-0012": "Inventory's iPad presentation now uses the live window width and a comfortable regular-width baseline instead of starting at a compressed phone-sized height.",
            "STK-107-0011": "Household activity sync now publishes and merges recipe additions/removals and inventory/grocery changes in addition to member profile changes.",
            "STK-107-0006": "Expanded Recipes with shared-catalog discovery, inventory matching, source browsing, substitutions, category filters, grocery actions, and retailer aisle/price enrichment where providers supply it.",
            "STK-107-0004": "Replaced the dense option picker with adaptive themed selections, readable spacing, clear selected states, and regular-width presentation on iPad.",
            "STK-96-0012": "Consolidated Settings into themed Appearance, Cooking, Kitchen, Interaction, Notifications, Household, Data, and QA groups; removed duplicate and inactive controls.",
            "STK-96-0011": "Cook choices now render the selected circle, pill/row, or rounded-card shape at the saved live size and remain centered across orientation and width changes.",
            "STK-96-0010": "Removed the duplicate allergen editor from general Settings; dietary safety remains available in the dedicated cooking profile where it affects recipes.",
            "STK-96-0009": "Removed cuisine preferences from general Settings; cuisine discovery and filtering remain in Recipes where the choice has immediate context."
        ]
        if let resolution = currentTicketResolutions[ticket.number] {
            return resolution
        }
        let previouslyAudited = ticket.number.hasPrefix("STK-68-")
            || ticket.number.hasPrefix("STK-69-")
            || ticket.number.hasPrefix("STK-77-")
            || ticket.number.hasPrefix("STK-78-")
            || (ticket.number.hasPrefix("STK-80-")
                && (Int(ticket.number.split(separator: "-").last ?? "") ?? .max) <= 24)
        guard previouslyAudited else { return nil }
        let value = (ticket.title + " " + ticket.body).lowercased()
        if value.contains("main thread blocked") {
            return "Moved ticket/image persistence off the main actor, delayed background QA startup, memoized classification, capped the Discover classification pool, and removed repeated render-path catalog work."
        }
        if value.contains("image") || value.contains("photo") {
            return "Unified recipe imagery through the cached image loader with name/category fallback, retained real remote photos where available, and prevented blank image tiles while network images load or fail."
        }
        if value.contains("nothing showing") || value.contains("all showing 0") || value.contains("no recipe") {
            return "Cook and cuisine screens now hydrate the persisted recipe cache before classifying, use cached cuisine recipes when the live request fails, and count the shared online catalog instead of saved recipes only."
        }
        if value.contains("hard to read") {
            return "Replaced low-contrast orange expiry copy in light mode with adaptive theme text while retaining a high-contrast urgency indicator."
        }
        if value.contains("h-e-b") || value.contains("heb") {
            return "Normalized H-E-B variants to the standard HEB display name during inventory presentation and classification."
        }
        if value.contains("beef broth") || value.contains("categorized") {
            return "Broth, stock, bouillon, and consommé now classify as pantry cooking bases before produce/protein keyword matching."
        }
        if value.contains("qa menu") || value.contains("accessibility") || value.contains("dead items") {
            return "Restored the complete QA entry in Settings, consolidated QA-only tools there, filtered framework accessibility false positives, and removed inactive appearance controls."
        }
        if value.contains("wrong options") || value.contains("not enough") {
            return "Rebuilt Recipes navigation around one destination router, qualified complete sources from the shared catalog, and added in-app WebKit source browsing."
        }
        if value.contains("rounded square") || value.contains("icon") || value.contains("generic recipes") {
            return "Standardized Cook card geometry and imagery, filtered incomplete/generic catalog labels, and unified recommendation presentation across Cook surfaces."
        }
        if value.contains("ew") || value.contains("smushed") {
            return "Reworked the affected adaptive layout with scrolling, readable spacing, consistent preference controls, and device-size-safe presentation."
        }
        if value.contains("test") {
            return "Validated the QA ticket creation, local artifact, automatic sync, edit, resolution, verification, and refile lifecycle."
        }
        return "Audited against the current implementation and corrected through the consolidated Recipes, Cook, Inventory, Settings, and QA reliability update."
    }

    // MARK: Screenshots
    // Stored in Caches, deliberately. A QA screenshot is reproducible evidence,
    // not user data — if iOS reclaims the directory under storage pressure the
    // ticket text still stands on its own, and we have not spent the user's
    // backup quota on a picture of a bug.

    private var screenshotDirectory: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("qa-tickets", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func saveScreenshot(_ image: UIImage, for id: UUID) -> String? {
        guard let dir = screenshotDirectory else { return nil }
        let name = "\(id.uuidString).jpg"
        let url = dir.appendingPathComponent(name)
        // Build 84 (STK-77-0003) - the downscale, JPEG encode and disk write all
        // ran right here, on the main actor, inside open(). The name is decided
        // synchronously so the ticket can reference it; the pixels are produced
        // and written on a utility thread. Readers that need the bytes await
        // awaitScreenshotWrite(_:) first. UIImage is immutable and documented
        // thread-safe; the annotation says so where the compiler can read it.
        nonisolated(unsafe) let source = image
        pendingShotWrites[id] = Task.detached(priority: .utility) {
            // Downscale before encoding: a full-resolution screenshot is
            // megabytes and nothing in a bug report needs that. Explicit 1x
            // format - the default renderer format is the device's 3x, which
            // silently re-inflated a 900-point target to 2700 pixels.
            let maxEdge: CGFloat = 900
            let scale = min(1, maxEdge / max(source.size.width, source.size.height))
            let target = CGSize(width: source.size.width * scale,
                                height: source.size.height * scale)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let shrunk = scale < 1
                ? UIGraphicsImageRenderer(size: target, format: format).image { _ in
                    source.draw(in: CGRect(origin: .zero, size: target))
                  }
                : source
            guard let data = shrunk.jpegData(compressionQuality: 0.6) else { return }
            try? data.write(to: url, options: .atomic)
        }
        return name
    }

    /// Waits for a ticket's screenshot bytes to reach disk, if a write is still
    /// in flight. Sync paths call this before reading screenshotData, so the
    /// upload never races the write and quietly sends nothing.
    func awaitScreenshotWrite(_ id: UUID) async {
        if let task = pendingShotWrites[id] {
            await task.value
            pendingShotWrites[id] = nil
        }
    }

    func screenshot(for ticket: QATicket) -> UIImage? {
        guard let file = ticket.screenshotFile, let dir = screenshotDirectory else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(file).path)
    }

    private func removeScreenshot(_ ticket: QATicket) {
        guard let file = ticket.screenshotFile, let dir = screenshotDirectory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
    }

    /// JPEG bytes for a ticket's screenshot, as stored. Read straight off disk
    /// rather than re-encoding a decoded `UIImage`, so a ticket that is synced
    /// four times uploads four byte-identical files instead of four slightly
    /// different generation-loss copies.
    func screenshotData(for ticket: QATicket) -> Data? {
        guard let file = ticket.screenshotFile, let dir = screenshotDirectory else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(file))
    }

    // MARK: Mockups (Build 73)
    //
    // A mockup is what the screen *should* look like, attached after the fact
    // from Files or Photos. Stored in Application Support rather than Caches,
    // unlike screenshots: a screenshot is reproducible evidence that the app
    // captured itself and can afford to lose, whereas a mockup is something a
    // person made, possibly the only copy, and iOS reclaiming it under storage
    // pressure would be data loss.

    private var mockupDirectory: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first
        else { return nil }
        let dir = base.appendingPathComponent("qa-mockups", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Attach (or replace) a mockup. Returns false when it could not be stored,
    /// so the caller can say so rather than showing a success that left nothing
    /// behind.
    @discardableResult
    func attachMockup(_ image: UIImage, to id: UUID) -> Bool {
        guard let dir = mockupDirectory,
              let i = tickets.firstIndex(where: { $0.id == id }) else { return false }

        // Mockups get a longer edge than screenshots (1400 vs 900) because they
        // are the reference someone builds against — text inside a mockup has
        // to stay legible, where a screenshot only has to be recognisable.
        let maxEdge: CGFloat = 1400
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let shrunk = scale < 1
            ? UIGraphicsImageRenderer(size: target).image { _ in
                image.draw(in: CGRect(origin: .zero, size: target))
              }
            : image
        guard let data = shrunk.jpegData(compressionQuality: 0.75) else { return false }

        let name = "\(id.uuidString)-mockup.jpg"
        do {
            try data.write(to: dir.appendingPathComponent(name), options: .atomic)
        } catch {
            return false
        }

        // Not routed through `update`: attaching a mockup is neither triage nor
        // a rewrite of the report, but it *does* change what the destinations
        // should be holding — so the sync stamps clear the same way.
        tickets[i].mockupFile = name
        tickets[i].updatedAt = Date()
        tickets[i].syncedAt = nil
        tickets[i].shotSyncedAt = nil
        tickets[i].mirroredAt = nil
        tickets[i].cpanelSyncedAt = nil
        save()
        scheduleLocalMirror(id)

        QARecorder.shared.record(.note, screen: "QA",
                                 label: "\(tickets[i].number) mockup attached",
                                 detail: "\(data.count / 1024) KB")
        return true
    }

    func mockup(for ticket: QATicket) -> UIImage? {
        guard let file = ticket.mockupFile, let dir = mockupDirectory else { return nil }
        return UIImage(contentsOfFile: dir.appendingPathComponent(file).path)
    }

    func mockupData(for ticket: QATicket) -> Data? {
        guard let file = ticket.mockupFile, let dir = mockupDirectory else { return nil }
        return try? Data(contentsOf: dir.appendingPathComponent(file))
    }

    func removeMockup(from id: UUID) {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        removeMockupFile(tickets[i])
        tickets[i].mockupFile = nil
        tickets[i].updatedAt = Date()
        save()
        scheduleLocalMirror(id)
    }

    private func removeMockupFile(_ ticket: QATicket) {
        guard let file = ticket.mockupFile, let dir = mockupDirectory else { return }
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(file))
    }

    /// Everything on disk that belongs to a ticket about to stop existing.
    /// One call site for deletion, trimming and clearing, because Build 72 had
    /// three and the mockup would have been added to two of them.
    private func discardFiles(_ ticket: QATicket) {
        removeScreenshot(ticket)
        removeMockupFile(ticket)
    }

    // MARK: Handoff blocks (Build 73)

    func chatGPTPrompt(for ticket: QATicket) -> String {
        QAMockupHandoff.chatGPTPrompt(for: ticket, hasMockup: ticket.hasMockup)
    }

    func claudeHandback(for ticket: QATicket) -> String {
        QAMockupHandoff.claudeHandback(for: ticket)
    }

    // MARK: Fan-out support (Build 73)

    /// Snapshot everything one ticket needs to be written to any destination.
    /// Assembled here, once, on the main actor — the destinations themselves are
    /// off-actor and must not be reaching back into the store for pieces.
    func bundle(for id: UUID) -> QASyncBundle? {
        guard let t = tickets.first(where: { $0.id == id }) else { return nil }
        return QASyncBundle(ticket: t,
                            reportText: markdown(for: t),
                            promptText: QAMockupHandoff.chatGPTPrompt(for: t, hasMockup: t.hasMockup),
                            handbackText: QAMockupHandoff.claudeHandback(for: t),
                            shot: screenshotData(for: t),
                            mockup: mockupData(for: t))
    }

    /// The ticket as Markdown, for the folder on the Mac.
    ///
    /// Not `exportText`: that is a fixed-width plain-text block designed to be
    /// pasted into a message, and it renders as one unbroken preformatted lump
    /// in anything that understands Markdown. This is the same information
    /// shaped for a reader in Finder — headings that collapse, tables that
    /// align, image references that preview inline.
    func markdown(for t: QATicket) -> String {
        var out: [String] = []
        out.append("# \(t.number) — \(t.title)")
        out.append("")
        out.append("**\(t.severity.title)** · \(t.status.title) · \(t.originPhrase) · \(t.createdAt.formatted())")
        if t.requiresManualReview == true {
            out.append("")
            out.append("> **REQUIRES MANUAL REVIEW:** Ask the tester for specifics before changing code.")
        }
        if t.wasEdited {
            out.append("")
            out.append("> Edited \(t.editCount ?? 1)× — last on \(t.editedAt?.formatted() ?? "—"). The original wording is preserved at the end of the report below.")
        }
        out.append("")

        if !t.body.isEmpty {
            out.append("## Report")
            out.append("")
            out.append(t.body)
            out.append("")
        }

        if t.screenshotFile != nil {
            out.append("## What it looked like")
            out.append("")
            out.append("![screenshot](\(QAMockupHandoff.shotFileName))")
            out.append("")
        }
        if t.hasMockup {
            out.append("## What it should look like")
            out.append("")
            out.append("![mockup](\(QAMockupHandoff.mockupFileName))")
            out.append("")
        }

        out.append("## Environment")
        out.append("")
        out.append(t.context.summaryLines.map { "- \($0)" }.joined(separator: "\n"))
        out.append("")

        func section(_ title: String, _ items: [String]) {
            guard !items.isEmpty else { return }
            out.append("## \(title)")
            out.append("")
            out.append(items.map { "- \($0)" }.joined(separator: "\n"))
            out.append("")
        }
        section("Steps before the report", t.context.breadcrumbs)
        section("Stalled at the time", t.context.stalledProcesses)
        section("In flight at the time", t.context.runningProcesses)
        section("Recent failures", t.context.recentFailures)
        section("Invariants violating", t.context.openViolations)

        out.append("---")
        out.append("")
        out.append("Destinations: \(t.destinationLine)")
        out.append("")
        out.append("_Written by Stocked QA \(BuildConfig.version) (\(BuildConfig.buildNumber))._")
        return out.joined(separator: "\n")
    }

    /// One line per ticket for a build's `index.md`, newest first.
    func indexLines(forBuild build: Int) -> (lines: [String], summary: String) {
        let inBuild = tickets.filter { $0.context.build == build }
        let lines = inBuild.map { t -> String in
            let folder = QASyncBundle(ticket: t, reportText: "", promptText: "",
                                      handbackText: "", shot: nil, mockup: nil).folderName
            var marks: [String] = [t.severity.title, t.status.title]
            if t.hasMockup { marks.append("mockup") }
            if t.wasEdited { marks.append("edited") }
            return "[\(t.number)](<\(folder)/\(QAMockupHandoff.reportFileName)>) — \(t.title) · \(marks.joined(separator: " · ")) · `\(t.context.screen)`"
        }
        let open = inBuild.filter { !$0.status.isClosed }.count
        let blockers = inBuild.filter { $0.severity == .blocker && !$0.status.isClosed }.count
        let summary = "\(inBuild.count) ticket\(inBuild.count == 1 ? "" : "s") · \(open) open · \(blockers) blocker\(blockers == 1 ? "" : "s")"
        return (lines, summary)
    }

    // Per-destination stamps.
    //
    // These deliberately do NOT go through `update`, which clears every sync
    // stamp on the grounds that the ticket changed. Recording that a
    // destination now holds the ticket is not a change to the ticket, and
    // routing it through `update` would erase the stamp it had just written —
    // the sync would report success forever and never show progress.

    /// Build 74. Stamps the checkbook row a ticket came from. Separate from
    /// `update` because `update` deliberately clears every sync stamp, and this
    /// runs microseconds after the ticket was filed — clearing stamps that were
    /// never set would make a brand-new ticket look like it had been edited.
    func linkCheck(_ id: UUID, check: String) {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        tickets[i].checkTicket = check
        save()
        scheduleLocalMirror(id)
    }

    /// Every ticket filed inside one test run, newest first.
    func tickets(inRun runID: String) -> [QATicket] {
        tickets.filter { $0.runID == runID }
    }

    /// Open tickets that have been reported more than once, worst first. The
    /// list nobody could produce before Build 74.
    var recurring: [QATicket] {
        // Deliberately NOT filtered to open tickets. A ticket marked fixed that
        // has been filed again since is the most informative row the QA hub
        // produces — it says a fix did not hold — and filtering closed ones out
        // would hide exactly that.
        tickets.filter(\.isRecurring)
            .sorted { ($0.seenAgain ?? 0) > ($1.seenAgain ?? 0) }
    }

    func stampMirrored(_ id: UUID) {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        tickets[i].mirroredAt = Date()
        save()
    }

    func stampShotSynced(_ id: UUID) {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        tickets[i].shotSyncedAt = Date()
        save()
    }

    func stampCPanelSynced(_ id: UUID) {
        guard let i = tickets.firstIndex(where: { $0.id == id }) else { return }
        tickets[i].cpanelSyncedAt = Date()
        save()
    }

    // MARK: Syncing

    private(set) var lastSyncOutcome: String = "never published"
    private(set) var isSyncing = false

    /// Merge the Worker collection from every Stocked device. Ticket numbers are
    /// the cross-device identity; the newest `updatedAt` wins while any local
    /// screenshot path is retained because screenshots travel on their own route.
    @discardableResult
    func pullDeviceTickets() async -> Int {
        guard QAAccessGate.shared.isUnlocked else { return 0 }
        do {
            let rows = try await QAReportTransport.fetchDeviceTickets()
            var imported = 0
            for row in rows {
                guard let number = row["number"] as? String, !number.isEmpty,
                      let title = row["title"] as? String else { continue }
                let updated = Self.remoteDate(row["updatedAt"]) ?? .distantPast
                if let index = tickets.firstIndex(where: { $0.number == number }) {
                    guard updated >= tickets[index].updatedAt else { continue }
                    let localShot = tickets[index].screenshotFile
                    let localMockup = tickets[index].mockupFile
                    tickets[index] = Self.remoteTicket(row, number: number, title: title)
                    tickets[index].screenshotFile = localShot
                    tickets[index].mockupFile = localMockup
                } else {
                    tickets.append(Self.remoteTicket(row, number: number, title: title))
                    imported += 1
                }
            }
            tickets.sort { $0.updatedAt > $1.updatedAt }
            if tickets.count > cap { trim() }
            save()
            return imported
        } catch {
            lastSyncOutcome = "device pull failed: \(error.localizedDescription)"
            return 0
        }
    }

    private nonisolated static func remoteDate(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        return ISO8601DateFormatter().date(from: text)
    }

    private nonisolated static func remoteTicket(_ row: [String: Any], number: String, title: String) -> QATicket {
        let env = row["environment"] as? [String: Any] ?? [:]
        var context = QATicketContext()
        context.screen = row["screen"] as? String ?? "—"
        context.breadcrumbs = row["breadcrumbs"] as? [String] ?? []
        context.runningProcesses = row["runningProcesses"] as? [String] ?? []
        context.stalledProcesses = row["stalledProcesses"] as? [String] ?? []
        context.recentFailures = row["recentFailures"] as? [String] ?? []
        context.openViolations = row["openViolations"] as? [String] ?? []
        context.appVersion = env["appVersion"] as? String ?? ""
        context.build = env["build"] as? Int ?? 0
        context.device = env["device"] as? String ?? ""
        context.os = env["os"] as? String ?? ""
        context.memoryMB = Double(env["memoryMB"] as? Int ?? 0)
        context.thermal = env["thermal"] as? String ?? ""
        context.lowPower = env["lowPower"] as? Bool ?? false
        context.online = env["online"] as? Bool ?? true
        context.freeDiskMB = Double(env["freeDiskMB"] as? Int ?? 0)
        context.sessionDuration = env["sessionDuration"] as? String ?? ""
        context.tapsOnScreen = env["tapsOnScreen"] as? Int ?? 0
        context.worstHitchMs = Double(env["worstHitchMs"] as? Int ?? 0)
        context.touchTrail = row["touchTrail"] as? String
        var ticket = QATicket(number: number, title: title)
        ticket.body = row["body"] as? String ?? ""
        ticket.severity = QATicketSeverity(rawValue: row["severity"] as? String ?? "") ?? .major
        ticket.status = QATicketStatus(rawValue: row["status"] as? String ?? "") ?? .open
        ticket.createdAt = remoteDate(row["createdAt"]) ?? Date()
        ticket.updatedAt = remoteDate(row["updatedAt"]) ?? ticket.createdAt
        ticket.context = context
        ticket.resolution = row["resolution"] as? String
        ticket.verifiedAt = remoteDate(row["verifiedAt"])
        ticket.duplicateOf = row["duplicateOf"] as? String
        ticket.seenAgain = row["seenAgain"] as? Int
        ticket.refileCount = row["refileCount"] as? Int
        ticket.requiresManualReview = row["requiresManualReview"] as? Bool
        ticket.syncedAt = Date()
        return ticket
    }

    /// Push one ticket to the QA bridge.
    @discardableResult
    func publish(_ id: UUID) async -> Bool {
        guard let ticket = tickets.first(where: { $0.id == id }) else { return false }
        return await push([ticket])
    }

    /// Push everything that has not landed yet. Called by the background runner
    /// alongside its own report, so a normal publish carries the tickets too.
    @discardableResult
    func publishUnsynced() async -> Bool {
        guard !unsynced.isEmpty else { return true }
        let pendingCount = unsynced.count
        let landed = await QASyncCoordinator.shared.syncAllPending()
        lastSyncOutcome = QASyncCoordinator.shared.lastOutcome
        return landed == pendingCount
    }

    private func push(_ batch: [QATicket]) async -> Bool {
        guard !batch.isEmpty else { return true }
        isSyncing = true
        defer { isSyncing = false }

        // SCHEMA: the bridge validates exactly one tag — `stocked-qa-report/v1` —
        // and 400s anything else as `bad_report`. Build 71 sent
        // `stocked-qa-tickets/v1` from here, which is why every ticket in the
        // field export read "synced: failed — bridge rejected the ticket" while
        // the report envelope posted seconds later succeeded four times running.
        // Tickets now ride the same envelope and are told apart by `kind`, which
        // the bridge is deliberately permissive about. No route change, and no
        // dependency on the worker being redeployed first.
        // Build 73: a base64 thumbnail rides inside the envelope, within a
        // strict budget. Not a replacement for /qa/shots — a 200px JPEG is not
        // evidence — but it is the difference between reading a report and
        // *seeing* which screen it came from, and it arrives even when the
        // full-size upload fails or the route has not been deployed yet.
        let thumbs = thumbnails(for: batch)

        let payload: [String: Any] = [
            "schema": "stocked-qa-report/v1",
            "kind": "tickets",
            "source": "stocked-app",
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "app": ["name": "Stocked",
                    "version": BuildConfig.version,
                    "build": BuildConfig.buildNumber],
            "tickets": batch.map { Self.dictionary(for: $0, thumbnail: thumbs[$0.id]) },
        ]

        do {
            let ok = try await QAReportTransport.post(payload)
            let stamp = Date()
            for t in batch {
                guard let i = tickets.firstIndex(where: { $0.id == t.id }) else { continue }
                if ok {
                    tickets[i].syncedAt = stamp
                    tickets[i].syncError = ""
                } else {
                    tickets[i].syncError = "bridge rejected the ticket"
                }
            }
            lastSyncOutcome = ok
                ? "synced \(batch.count) ticket\(batch.count == 1 ? "" : "s") at \(stamp.formatted(date: .omitted, time: .shortened))"
                : "bridge rejected the batch"
            save()
            return ok
        } catch {
            for t in batch {
                guard let i = tickets.firstIndex(where: { $0.id == t.id }) else { continue }
                tickets[i].syncError = error.localizedDescription
            }
            lastSyncOutcome = error.localizedDescription
            save()
            return false
        }
    }

    /// JSON shape for the bridge. Kept here rather than on `Codable` because the
    /// wire format and the on-disk format should be free to diverge.
    // `nonisolated` so it can be passed as a bare function value to `map`
    // without dragging @MainActor through the conversion. It only reads a
    // Sendable QATicket and a locally-created formatter, so it needs nothing
    // from the actor.
    /// Base64 thumbnails for as much of a batch as fits the envelope.
    ///
    /// THE BUDGET IS THE WHOLE POINT. The bridge rejects anything over 256 KB
    /// outright, so an unbounded "attach a thumbnail to every ticket" would work
    /// beautifully for three tickets and then silently start failing the entire
    /// batch — including the text — at around fifteen. Newest first, stop at the
    /// budget, and the tickets that miss out still sync with everything except
    /// the picture.
    private func thumbnails(for batch: [QATicket]) -> [UUID: String] {
        // ~96 KB of base64 across the batch, leaving well over half the 256 KB
        // envelope for the text of even a very talkative batch.
        let budget = 96 * 1024
        var spent = 0
        var out: [UUID: String] = [:]

        for t in batch.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard spent < budget,
                  let image = screenshot(for: t),
                  let encoded = Self.thumbnailBase64(image) else { continue }
            guard spent + encoded.count <= budget else { continue }
            out[t.id] = encoded
            spent += encoded.count
        }
        return out
    }

    /// 200px longest edge at quality 0.4 — legible enough to recognise a screen,
    /// small enough that a dozen of them fit in the envelope.
    nonisolated private static func thumbnailBase64(_ image: UIImage) -> String? {
        let maxEdge: CGFloat = 200
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let target = CGSize(width: max(1, image.size.width * scale),
                            height: max(1, image.size.height * scale))
        let small = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        guard let data = small.jpegData(compressionQuality: 0.4) else { return nil }
        return data.base64EncodedString()
    }

    nonisolated private static func dictionary(for t: QATicket,
                                               thumbnail: String? = nil) -> [String: Any] {
        var out: [String: Any] = [
            "number": t.number,
            "title": t.title,
            "body": t.body,
            "severity": t.severity.rawValue,
            "status": t.status.rawValue,
            "createdAt": ISO8601DateFormatter().string(from: t.createdAt),
            "updatedAt": ISO8601DateFormatter().string(from: t.updatedAt),
            "screen": t.context.screen,
            "breadcrumbs": t.context.breadcrumbs,
            "runningProcesses": t.context.runningProcesses,
            "stalledProcesses": t.context.stalledProcesses,
            "recentFailures": t.context.recentFailures,
            "openViolations": t.context.openViolations,
            "hasScreenshot": t.screenshotFile != nil,
            "hasMockup": t.mockupFile != nil,
            "edited": t.wasEdited,
            "editCount": t.editCount ?? 0,
            "destinations": [
                "worker": t.syncedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "shot": t.shotSyncedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "folder": t.mirroredAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "cpanel": t.cpanelSyncedAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
            ],
            "environment": [
                "appVersion": t.context.appVersion,
                "build": t.context.build,
                "device": t.context.device,
                "os": t.context.os,
                "memoryMB": Int(t.context.memoryMB),
                "thermal": t.context.thermal,
                "lowPower": t.context.lowPower,
                "online": t.context.online,
                "freeDiskMB": Int(t.context.freeDiskMB),
                "sessionDuration": t.context.sessionDuration,
                "tapsOnScreen": t.context.tapsOnScreen,
                "worstHitchMs": Int(t.context.worstHitchMs),
            ],
        ]
        if let trail = t.context.touchTrail, !trail.isEmpty { out["touchTrail"] = trail }
        if let resolution = t.resolution, !resolution.isEmpty { out["resolution"] = resolution }
        if let verifiedAt = t.verifiedAt {
            out["verifiedAt"] = ISO8601DateFormatter().string(from: verifiedAt)
        }
        if let duplicateOf = t.duplicateOf { out["duplicateOf"] = duplicateOf }
        if let seenAgain = t.seenAgain { out["seenAgain"] = seenAgain }
        if let refileCount = t.refileCount { out["refileCount"] = refileCount }
        if let requiresManualReview = t.requiresManualReview {
            out["requiresManualReview"] = requiresManualReview
        }
        if let thumbnail { out["thumbnail"] = thumbnail }
        return out
    }

    /// Ticket summary for the health envelope the background runner publishes.
    var healthSummary: [String: Any] {
        [
            "total": tickets.count,
            "open": openCount,
            "blockers": blockers.count,
            "unsynced": unsynced.count,
            "numbers": open.prefix(20).map(\.number),
        ]
    }

    var exportText: String {
        guard !tickets.isEmpty else { return "" }
        var out = ["TICKETS",
                   "\(tickets.count) total · \(openCount) open · \(blockers.count) blocker(s) · \(unsynced.count) unsynced",
                   ""]
        for t in sorted(status: nil, severity: nil, search: "") {
            out.append(t.exportText)
            out.append("")
        }
        return out.joined(separator: "\n")
    }
}
