// QARunLog.swift
// ─────────────────────────────────────────────────────────────────────────────
// IMPROVEMENT 10 (Build 74) — named test runs.
//
// Every QA artefact was stamped with a build number and a date and nothing else,
// which is fine until you test the same build three times. "Regression pass
// before submission" and "quick check of the grocery fix" produced one
// indistinguishable pile of tickets, and the only way to tell them apart later
// was to remember roughly what time it was.
//
// A run is a name and two timestamps. Anything filed while it is open carries its
// id, so afterwards you can ask the one question that was previously unanswerable:
// *what came out of that pass* — not what exists, what came out of that pass.
//
// Runs are recorded, not enforced. Filing with no run open is still completely
// normal, and the run id is Optional on the ticket precisely so tickets from
// before this build, and tickets filed outside any run, decode unchanged.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

// MARK: - Model

nonisolated struct QARun: Identifiable, Codable, Sendable {
    var id = UUID()
    var name: String
    var startedAt: Date = Date()
    var endedAt: Date?
    var build: Int
    var version: String
    /// Ticket numbers filed inside the run. Numbers rather than UUIDs so the run
    /// stays readable after a ticket is deleted — a run that produced STK-74-0007
    /// still produced it even if the ticket has since been thrown away.
    var ticketNumbers: [String] = []
    /// Checkbook verdicts recorded during the run, `QA-12-03 → pass`.
    var checkVerdicts: [String: String] = [:]
    var note: String = ""

    var isOpen: Bool { endedAt == nil }

    var durationText: String {
        let end = endedAt ?? Date()
        let secs = Int(end.timeIntervalSince(startedAt))
        let h = secs / 3600, m = (secs % 3600) / 60, s = secs % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    var line: String {
        let when = startedAt.formatted(date: .abbreviated, time: .shortened)
        let checks = checkVerdicts.count
        let fails = checkVerdicts.values.filter { $0 == "fail" || $0 == "blocked" }.count
        var bits = ["\(ticketNumbers.count) ticket\(ticketNumbers.count == 1 ? "" : "s")"]
        if checks > 0 { bits.append("\(checks) check\(checks == 1 ? "" : "s")") }
        if fails > 0 { bits.append("\(fails) not passing") }
        return "\(name) · \(when) · \(durationText) · " + bits.joined(separator: " · ")
    }
}

// MARK: - Store

@MainActor
@Observable
final class QARunLog {
    static let shared = QARunLog()

    private(set) var runs: [QARun] = []
    nonisolated private static let key = "qa.runs.v1"
    private let cap = 40

    private init() { load() }

    var current: QARun? { runs.first(where: \.isOpen) }
    var currentID: String? { current.map { $0.id.uuidString } }
    var currentName: String? { current?.name }
    var isRunning: Bool { current != nil }

    var finished: [QARun] { runs.filter { !$0.isOpen } }

    /// Tickets store the run they were filed in as a `uuidString`, not a `UUID`,
    /// because the field had to be an Optional `String?` on a Codable that already
    /// ships in the field. This turns one back into a name for export, and returns
    /// nil for a run the tester has since deleted rather than printing a raw id.
    func name(forID id: String) -> String? {
        runs.first { $0.id.uuidString == id }?.name
    }

    /// The same lookup, reachable from a `nonisolated` context.
    ///
    /// `QATicket` is a `nonisolated struct` — it has to be: it is `Codable` and
    /// `Sendable` and it crosses to the sync paths. So its `exportText` cannot
    /// touch `QARunLog.shared`, which is `@MainActor`. Swift 6 rejects that
    /// outright rather than letting it race, and `MainActor.assumeIsolated`
    /// cannot rescue it either, because export genuinely can be reached off the
    /// main actor.
    ///
    /// Reading the same `UserDefaults` key the store writes gets the name with
    /// no isolation hop at all. `UserDefaults` is thread-safe, the payload is at
    /// most `cap` (40) small records, and this is only reached from export and
    /// sync — never from a row being drawn.
    nonisolated static func name(forID id: String) -> String? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([QARun].self, from: data)
        else { return nil }
        return decoded.first { $0.id.uuidString == id }?.name
    }

    func run(withID id: String) -> QARun? {
        runs.first { $0.id.uuidString == id }
    }

    // MARK: Lifecycle

    /// Opening a run closes any run already open. Two open runs would make
    /// "which run is this ticket in" ambiguous, and an ambiguous answer here is
    /// worse than no answer at all.
    @discardableResult
    func start(name: String) -> QARun {
        end()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let run = QARun(name: trimmed.isEmpty ? defaultName() : trimmed,
                        build: BuildConfig.buildNumber,
                        version: BuildConfig.version)
        runs.insert(run, at: 0)
        trim()
        save()
        QARecorder.shared.record(.note, label: "QA run started", detail: run.name)
        QAProcessTracker.shared.mark("QA run", detail: run.name)
        return run
    }

    func end() {
        guard let i = runs.firstIndex(where: \.isOpen) else { return }
        runs[i].endedAt = Date()
        save()
        QARecorder.shared.record(.note, label: "QA run finished",
                                 detail: "\(runs[i].name) · \(runs[i].durationText)")
    }

    func rename(_ id: UUID, to name: String) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        runs[i].name = trimmed
        save()
    }

    func note(_ id: UUID, _ text: String) {
        guard let i = runs.firstIndex(where: { $0.id == id }) else { return }
        runs[i].note = text
        save()
    }

    func delete(_ id: UUID) {
        runs.removeAll { $0.id == id }
        save()
    }

    func clear() {
        runs.removeAll()
        save()
    }

    // MARK: Recording into the open run

    /// Called by `QATicketStore.open`. A no-op when nothing is running, which is
    /// the common case and must stay free.
    func recordTicket(_ number: String) {
        guard let i = runs.firstIndex(where: \.isOpen) else { return }
        guard !runs[i].ticketNumbers.contains(number) else { return }
        runs[i].ticketNumbers.append(number)
        save()
    }

    /// Called by the checkbook when a verdict changes. Last write wins: a check
    /// toggled from fail to pass inside one run ended that run as a pass.
    func recordCheck(_ ticket: String, _ verdict: QAVerdict) {
        guard let i = runs.firstIndex(where: \.isOpen) else { return }
        if verdict == .untested {
            runs[i].checkVerdicts.removeValue(forKey: ticket)
        } else {
            runs[i].checkVerdicts[ticket] = verdict.rawValue
        }
        save()
    }

    // MARK: Export

    func exportText(_ run: QARun) -> String {
        var out = ["── QA run: \(run.name) ──",
                   "build \(run.version) (\(run.build))",
                   "started \(run.startedAt.formatted())",
                   run.endedAt.map { "ended   \($0.formatted()) · \(run.durationText)" } ?? "still open · \(run.durationText) so far"]
        if !run.note.isEmpty { out += ["", "note: \(run.note)"] }

        out += ["", "TICKETS (\(run.ticketNumbers.count))"]
        if run.ticketNumbers.isEmpty {
            out.append("  none filed during this run")
        } else {
            let byNumber = Dictionary(uniqueKeysWithValues:
                QATicketStore.shared.tickets.map { ($0.number, $0) })
            for number in run.ticketNumbers {
                if let t = byNumber[number] {
                    out.append("  \(t.line)")
                } else {
                    out.append("  \(number) — deleted since")
                }
            }
        }

        out += ["", "CHECKS (\(run.checkVerdicts.count))"]
        if run.checkVerdicts.isEmpty {
            out.append("  no checkbook rows touched during this run")
        } else {
            let titles = checkTitles()
            for (ticket, verdict) in run.checkVerdicts.sorted(by: { $0.key < $1.key }) {
                out.append("  [\(verdict.uppercased())] \(ticket) \(titles[ticket] ?? "")")
            }
        }
        return out.joined(separator: "\n")
    }

    /// Every finished run, newest first, as one document.
    var allRunsExport: String {
        guard !runs.isEmpty else { return "No QA runs recorded." }
        return runs.map { exportText($0) }.joined(separator: "\n\n")
    }

    private func checkTitles() -> [String: String] {
        var out: [String: String] = [:]
        for section in StockedQAChecklist.sections {
            for item in section.items { out[item.ticket] = item.text }
        }
        return out
    }

    private func defaultName() -> String {
        "Run \(Date().formatted(date: .abbreviated, time: .shortened))"
    }

    // MARK: Persistence

    private func trim() {
        guard runs.count > cap else { return }
        runs = Array(runs.prefix(cap))
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(runs) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([QARun].self, from: data) else { return }
        runs = decoded
    }
}

// MARK: - Screen

struct QARunLogView: View {
    @State private var log = QARunLog.shared
    @State private var newName = ""
    @State private var renaming: QARun?
    @State private var renameDraft = ""

    var body: some View {
        List {
            Section {
                if let run = log.current {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Image(systemName: "record.circle").foregroundStyle(.red)
                            Text(run.name).font(.subheadline.weight(.semibold))
                        }
                        Text("Running for \(run.durationText) · \(run.ticketNumbers.count) ticket\(run.ticketNumbers.count == 1 ? "" : "s") · \(run.checkVerdicts.count) check\(run.checkVerdicts.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button(role: .destructive) { log.end() } label: {
                        Label("Finish this run", systemImage: "stop.circle")
                    }
                } else {
                    TextField("Name this run — what are you testing?", text: $newName)
                        .textInputAutocapitalization(.sentences)
                    Button {
                        log.start(name: newName)
                        newName = ""
                    } label: {
                        Label("Start run", systemImage: "play.circle")
                    }
                }
            } header: {
                Text("Current run")
            } footer: {
                Text("Every ticket you file and every checkbook row you set while a run is open is tagged with it. Nothing is blocked when no run is open — this only exists so you can ask what came out of one pass rather than what exists overall.")
            }

            if !log.finished.isEmpty {
                Section("Previous runs") {
                    ForEach(log.finished) { run in
                        NavigationLink {
                            QATextReportView(title: run.name, text: log.exportText(run))
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(run.name).font(.subheadline.weight(.medium))
                                Text(run.line).font(.caption2).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { log.delete(run.id) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button {
                                renameDraft = run.name
                                renaming = run
                            } label: { Label("Rename", systemImage: "pencil") }
                        }
                    }
                }
            }

            if !log.runs.isEmpty {
                Section {
                    ShareLink(item: log.allRunsExport) {
                        Label("Share every run", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) { log.clear() } label: {
                        Label("Delete all runs", systemImage: "trash")
                    }
                }
            }
        }
        .navigationTitle("Test runs")
        .navigationBarTitleDisplayMode(.inline)
        .qaScreen("QA > Test runs")
        .alert("Rename run", isPresented: Binding(get: { renaming != nil },
                                                  set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameDraft)
            Button("Save") {
                if let r = renaming { log.rename(r.id, to: renameDraft) }
                renaming = nil
            }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }
}
