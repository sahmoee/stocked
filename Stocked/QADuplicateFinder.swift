// QADuplicateFinder.swift
// ─────────────────────────────────────────────────────────────────────────────
// IMPROVEMENT 5 (Build 74) — the same bug, filed six times, counted once.
//
// A recurring bug and a one-off bug arrived in the ticket list looking identical:
// six separate rows, each saying "photo not loading", each with a different
// number, none of them saying *this keeps happening*. The most useful fact about
// a bug — how often it happens — was the one fact the system was throwing away,
// because each report overwrote nothing and referenced nothing.
//
// So: when a ticket is filed, look for an open ticket on the same screen whose
// wording overlaps enough to be the same complaint. If there is one, the new
// ticket still gets filed (a report a tester wrote is never silently swallowed —
// they may have typed a crucial extra detail) but it is stamped with the
// original's number, and the original's `seenAgain` count goes up.
//
// The comparison is deliberately dumb: lowercase, strip punctuation, drop stop
// words, Jaccard overlap on the remaining tokens. A cleverer matcher would
// occasionally merge two different bugs, and a false merge is much more expensive
// than a missed one — a missed duplicate costs a duplicate row, a false one loses
// a bug.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

nonisolated enum QADuplicateFinder {

    /// Overlap at or above this counts as the same complaint. Tuned against the
    /// real Build 71 field export: "Photo not loading" vs "photo doesn't load on
    /// recipes" scores 0.5 and should match; "photo not loading" vs "photo picker
    /// crashes" scores 0.25 and must not.
    static let threshold = 0.45

    /// Only look back this far. A bug that reappears five weeks after it was
    /// filed is worth its own ticket — that is a regression, not a repeat.
    static let window: TimeInterval = 21 * 24 * 60 * 60

    /// The best open match for a candidate report, if any.
    ///
    /// `existing` is passed in rather than read from the store so this stays
    /// nonisolated and testable, and so the caller controls which tickets are in
    /// scope (open ones only — a fixed ticket recurring is a reopen, and the
    /// tester should see it as a new report).
    static func match(title: String,
                      body: String,
                      screen: String,
                      among existing: [QATicket],
                      now: Date = Date()) -> QATicket? {
        let candidate = tokens(title + " " + body)
        guard candidate.count >= 2 else { return nil }

        var best: (ticket: QATicket, score: Double)?
        for t in existing {
            guard !t.status.isClosed else { continue }
            guard now.timeIntervalSince(t.createdAt) <= window else { continue }
            // Same screen, or one of them never recorded a screen. Two reports
            // with identical wording on different screens are two bugs.
            let a = t.context.screen, b = screen
            guard a == b || a == "—" || b == "—" || a.isEmpty || b.isEmpty else { continue }

            let score = similarity(candidate, tokens(t.title + " " + t.body))
            guard score >= threshold else { continue }
            if best == nil || score > best!.score { best = (t, score) }
        }
        return best?.ticket
    }

    // MARK: Similarity

    static func similarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }

    /// Words that appear in nearly every bug report and therefore distinguish
    /// nothing. Without this list every report matches every other report at
    /// about 0.3 purely on "the", "app", "when" and "not".
    private static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "but", "if", "then", "than", "that", "this",
        "these", "those", "is", "it", "its", "was", "are", "be", "been", "being",
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "as", "into",
        "i", "me", "my", "we", "you", "your", "he", "she", "they", "them",
        "when", "where", "while", "after", "before", "again", "still", "just",
        "app", "stocked", "screen", "page", "view", "tap", "tapped", "tapping",
        "press", "pressed", "click", "clicked", "does", "did", "do", "doesnt",
        "dont", "cant", "wont", "isnt", "not", "no", "yes", "some", "any", "all",
        "get", "got", "goes", "went", "see", "saw", "seen", "show", "shows",
        "showing", "should", "would", "could", "will", "can", "there", "here",
        "up", "down", "out", "off", "over", "back", "one", "two", "very", "too"
    ]

    /// Lowercase, split on anything that is not a letter or digit, drop stop
    /// words and anything under three characters, and strip a trailing "s" so
    /// "photos" and "photo" are the same token.
    static func tokens(_ text: String) -> Set<String> {
        var out: Set<String> = []
        let pieces = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        for piece in pieces {
            var word = String(piece)
            guard word.count >= 3 else { continue }
            if word.count > 4, word.hasSuffix("s"), !word.hasSuffix("ss") {
                word.removeLast()
            }
            guard !stopWords.contains(word) else { continue }
            out.insert(word)
        }
        return out
    }
}

// MARK: - Screen

/// The list of things that came back. A ticket somebody closed and that was then
/// filed again is the single most informative row in the whole QA hub — it says a
/// fix did not hold, which no counter anywhere else reports. It earns its own
/// screen rather than a badge on the ticket list, because the useful column here
/// is "how many times", and that column exists nowhere else.
struct QARecurringTicketsView: View {
    @State private var store = QATicketStore.shared

    var body: some View {
        List {
            if store.recurring.isEmpty {
                ContentUnavailableView {
                    Label("Nothing has come back", systemImage: "repeat")
                } description: {
                    Text("When a ticket is filed that closely matches one already on file, the original is stamped as seen again instead of a near-duplicate being opened. Nothing has matched yet.")
                }
            } else {
                Section {
                    ForEach(store.recurring) { t in
                        NavigationLink { QATicketDetailView(ticketID: t.id) } label: {
                            HStack(alignment: .top, spacing: 10) {
                                VStack(spacing: 1) {
                                    Text("\(t.recurrenceCount + 1)")
                                        .scaledFont(15, weight: .bold, design: .rounded)
                                        .foregroundStyle(t.recurrenceCount >= 2 ? Color.stockedError : Color.stockedWarning)
                                    Text("times").scaledFont(8).foregroundStyle(.secondary)
                                }
                                .frame(width: 34)

                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(t.number) \(t.title)")
                                        .scaledFont(13, weight: .medium)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(t.context.screen)
                                        .font(.stocked(.caption2))
                                        .foregroundStyle(.secondary)
                                    if let again = t.seenAgainAt {
                                        Text("last seen \(again.formatted(date: .abbreviated, time: .shortened))")
                                            .scaledFont(10)
                                            .foregroundStyle(.tertiary)
                                    }
                                    if t.status.isClosed {
                                        Text("\(t.status.title.uppercased()) — and filed again since")
                                            .scaledFont(9, weight: .bold)
                                            .foregroundStyle(Color.stockedError)
                                    }
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                } footer: {
                    Text("Sorted by how often each has come back. A closed ticket in this list is a fix that did not hold — the strongest signal the QA hub produces, and the only one that says a change made things worse rather than that something is still wrong.")
                }
            }
        }
        .navigationTitle("Seen again")
        .navigationBarTitleDisplayMode(.inline)
        .qaScreen("QA > Recurring")
    }
}
