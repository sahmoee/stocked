// QACheckTickets.swift
// ─────────────────────────────────────────────────────────────────────────────
// IMPROVEMENT 3 (Build 74) — a failed check becomes a ticket in one tap.
//
// The checkbook could record that QA-12-03 failed and hold a sentence about why.
// That sentence then sat inside a UserDefaults dictionary keyed by check id,
// went to no destination, had no number, synced nowhere, and was invisible to
// everyone who was not looking at that exact row of that exact section.
//
// Meanwhile the ticket system had numbers, screenshots, context capture, a
// Worker bridge, a folder mirror and a cPanel drop — and no way at all to say
// "this came from a checkbook row".
//
// So the two halves are joined. Marking a check failed or blocked offers to file
// it, prefilled with the check's own wording; the ticket carries the check id and
// the check carries the ticket number. Afterwards either end answers the other's
// question: what did this pass produce, and is anyone actually working on it.
//
// The link is two Optionals — `QATicket.checkTicket` and
// `QACheckItemState.ticketNumber`. Both sides had to be Optional rather than
// defaulted, because synthesised `Codable` throws on a missing key rather than
// falling back, and `QATicketStore.load()` swallows that throw. A non-Optional
// field here would silently erase every ticket filed before this build.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

@MainActor
enum QACheckTickets {

    /// Files a ticket for a checkbook row and links the two together.
    ///
    /// Severity follows the check's own judgement: a row flagged BLOCKER in the
    /// checkbook is a blocker in the ticket list too. Nobody should have to
    /// re-decide something the checkbook already decided.
    @discardableResult
    static func file(item: QACheckItem,
                     section: QAChecklistSection,
                     verdict: QAVerdict,
                     note: String) -> QATicket {
        var context = QAContextCapture.current()
        // The tester is standing in the checkbook, so the automatically captured
        // screen would say "QA > Checkbook" — true and useless. Name the area the
        // check is about instead.
        context.screen = "Checkbook · \(section.number). \(section.title)"

        var body = ["Filed from checkbook row \(item.ticket).",
                    "",
                    "CHECK",
                    item.text,
                    "",
                    "VERDICT",
                    verdict.rawValue.uppercased() + (item.blocker ? " · marked BLOCKER in the checkbook" : "")]
        if !note.isEmpty {
            body += ["", "WHAT THE TESTER SAW", note]
        }
        body += ["", "SECTION", "\(section.number). \(section.title)"]
        if !section.note.isEmpty { body.append(section.note) }

        let ticket = QATicketStore.shared.open(
            title: shortTitle(item.text),
            body: body.joined(separator: "\n"),
            severity: item.blocker ? .blocker : .major,
            context: context,
            origin: .tester,
            screenshot: nil)

        // Stamp both ends.
        QATicketStore.shared.linkCheck(ticket.id, check: item.ticket)
        var state = StockedQAStore.shared.state(item)
        state.ticketNumber = ticket.number
        if state.note.isEmpty { state.note = note }
        StockedQAStore.shared.set(item, state)

        QARecorder.shared.record(.note, screen: "QA > Checkbook",
                                 label: "Filed \(ticket.number) from \(item.ticket)",
                                 detail: item.text)
        return ticket
    }

    /// A checkbook row is a full sentence — sometimes three. A ticket title is a
    /// list row. Cut at the first sentence boundary and fall back to a word-aware
    /// clip, so titles read as titles rather than as truncated paragraphs.
    static func shortTitle(_ text: String, limit: Int = 64) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let stop = flat.firstIndex(where: { $0 == ":" || $0 == "—" }), stop > flat.startIndex {
            let head = String(flat[flat.startIndex..<stop]).trimmingCharacters(in: .whitespaces)
            if head.count >= 12, head.count <= limit { return head }
        }
        guard flat.count > limit else { return flat }
        var clipped = String(flat.prefix(limit))
        if let space = clipped.lastIndex(of: " "), clipped.distance(from: clipped.startIndex, to: space) > 20 {
            clipped = String(clipped[clipped.startIndex..<space])
        }
        return clipped.trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - The prompt

/// Sheet shown when a check is marked failed or blocked. Deliberately a prompt
/// and not an automatic action: a tester flipping through rows to see what a
/// verdict button does should not leave a trail of tickets behind them.
struct QACheckTicketSheet: View {
    let item: QACheckItem
    let section: QAChecklistSection
    let verdict: QAVerdict
    var onDone: (QATicket?) -> Void

    @State private var note: String = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(item.text)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    HStack(spacing: 6) {
                        Text(item.ticket)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                        if item.blocker {
                            Text("BLOCKER").font(.system(size: 9, weight: .bold)).foregroundStyle(.red)
                        }
                        Text("· \(verdict.rawValue.uppercased())")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(verdict.color)
                    }
                }

                Section {
                    TextField("What you did, what you expected, what happened",
                              text: $note, axis: .vertical)
                        .lineLimit(4...10)
                } header: {
                    Text("Detail")
                } footer: {
                    Text("This becomes both the note on the check and the body of the ticket. Everything else — screen, build, device, memory, thermal state, breadcrumbs, the touch trail — is attached automatically.")
                }

                Section {
                    Button {
                        let t = QACheckTickets.file(item: item, section: section,
                                                    verdict: verdict, note: note)
                        onDone(t)
                        dismiss()
                    } label: {
                        Label("File ticket", systemImage: "ticket")
                    }
                    Button {
                        // Keep the note on the check without opening a ticket.
                        var s = StockedQAStore.shared.state(item)
                        s.note = note
                        StockedQAStore.shared.set(item, s)
                        onDone(nil)
                        dismiss()
                    } label: {
                        Label("Just note it", systemImage: "note.text")
                    }
                } footer: {
                    Text("A ticket gets a number, syncs to every destination that is set up, and shows in the run log. A note stays in the checkbook.")
                }
            }
            .navigationTitle("Failed check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onDone(nil); dismiss() }
                }
            }
        }
        .onAppear { note = StockedQAStore.shared.state(item).note }
    }
}
