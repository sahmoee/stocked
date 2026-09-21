// QASearchIndex.swift
// ─────────────────────────────────────────────────────────────────────────────
// IMPROVEMENT 1 (Build 74) — one search box over everything QA knows.
//
// QA had grown five separate searchable piles: 270 checkbook rows across 36
// sections, the ticket list, the invariant results, the event feed, and the list
// of screens visited this session. Each had its own search field, or none, and
// none of them could answer the question testers actually ask, which is never
// "search the ticket list" but "what do we know about the grocery list".
//
// The answer to that lives in four places at once — a checkbook row that covers
// it, a ticket somebody filed about it, an invariant that probes it, a handful of
// events from ten minutes ago — and finding it meant opening four screens and
// typing the same word into each.
//
// So: one field, one ranked list, every result a link to the thing itself. The
// index is rebuilt on each query rather than cached, because the corpus is a few
// thousand short strings and rebuilding it is far cheaper than the bugs that come
// from a cache nobody remembers to invalidate.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

// MARK: - Result model

nonisolated struct QASearchHit: Identifiable {
    enum Kind: String {
        case check, ticket, invariant, event, screen, finding

        var title: String {
            switch self {
            case .check:     return "Checkbook"
            case .ticket:    return "Tickets"
            case .invariant: return "Invariants"
            case .event:     return "Session events"
            case .screen:    return "Screens"
            case .finding:   return "Triage"
            }
        }

        var symbol: String {
            switch self {
            case .check:     return "checklist"
            case .ticket:    return "ticket"
            case .invariant: return "checkmark.shield"
            case .event:     return "list.bullet.rectangle"
            case .screen:    return "rectangle.on.rectangle"
            case .finding:   return "exclamationmark.triangle"
            }
        }

        /// Ordering between kinds when scores tie. A checkbook row and a ticket
        /// are the two things worth acting on; an event mentioning the same word
        /// is context, and sorts below both.
        var rank: Int {
            switch self {
            case .ticket:    return 0
            case .check:     return 1
            case .finding:   return 2
            case .invariant: return 3
            case .screen:    return 4
            case .event:     return 5
            }
        }
    }

    var id = UUID()
    let kind: Kind
    /// Short identifier — "QA-12-03", "STK-74-0007", a screen name.
    let tag: String
    let title: String
    let subtitle: String
    /// Higher is better. See `QASearchIndex.score`.
    let score: Int
    /// Section number for a checkbook hit, so the row can be opened in place.
    let sectionNumber: Int?
    /// Ticket id for a ticket hit.
    let ticketID: UUID?
}

// MARK: - Index

@MainActor
enum QASearchIndex {

    /// Everything, ranked. Returns at most `limit` hits so a one-letter query
    /// does not try to render three thousand rows.
    static func search(_ raw: String, limit: Int = 120) -> [QASearchHit] {
        let query = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        let terms = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        guard !terms.isEmpty else { return [] }

        var hits: [QASearchHit] = []
        hits += checkHits(terms)
        hits += ticketHits(terms)
        hits += findingHits(terms)
        hits += invariantHits(terms)
        hits += screenHits(terms)
        hits += eventHits(terms)

        hits.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.kind.rank < $1.kind.rank
        }
        return Array(hits.prefix(limit))
    }

    /// Grouped for a sectioned list, kinds in `rank` order, groups preserved in
    /// the order the ranked list first mentions them.
    static func grouped(_ raw: String) -> [(kind: QASearchHit.Kind, hits: [QASearchHit])] {
        let all = search(raw)
        var order: [QASearchHit.Kind] = []
        var buckets: [String: [QASearchHit]] = [:]
        for hit in all {
            if buckets[hit.kind.rawValue] == nil { order.append(hit.kind) }
            buckets[hit.kind.rawValue, default: []].append(hit)
        }
        return order.map { (kind: $0, hits: buckets[$0.rawValue] ?? []) }
    }

    // MARK: Scoring

    /// Every term must appear somewhere in the haystack — an AND search, because
    /// an OR search over six corpora returns everything for any two-word query.
    ///
    /// Score is: 10 per term found in the title, 4 per term found anywhere else,
    /// plus 6 if the whole query appears as one run of characters in the title.
    /// Blunt, but it reliably puts "Grocery list" above a session event that
    /// happens to mention groceries.
    private static func score(terms: [String], title: String, body: String) -> Int {
        let t = title.lowercased()
        let b = body.lowercased()
        var total = 0
        for term in terms {
            if t.contains(term) { total += 10 }
            else if b.contains(term) { total += 4 }
            else { return 0 }
        }
        if terms.count > 1, t.contains(terms.joined(separator: " ")) { total += 6 }
        return total
    }

    // MARK: Corpora

    private static func checkHits(_ terms: [String]) -> [QASearchHit] {
        let store = StockedQAStore.shared
        var out: [QASearchHit] = []
        for section in StockedQAChecklist.sections {
            for item in section.items {
                let state = store.state(item)
                let body = "\(item.ticket) \(section.title) \(state.note)"
                let s = score(terms: terms, title: item.text, body: body)
                guard s > 0 else { continue }
                var bits = ["\(section.number). \(section.title)", state.verdict.rawValue]
                if item.blocker { bits.append("blocker") }
                if !state.note.isEmpty { bits.append("note: \(state.note)") }
                out.append(QASearchHit(kind: .check,
                                       tag: item.ticket,
                                       title: item.text,
                                       subtitle: bits.joined(separator: " · "),
                                       // A failing check ranks above a passing
                                       // one on an equal text match: it is the
                                       // one that still needs someone.
                                       score: s + (state.verdict == .pass ? 0 : 3),
                                       sectionNumber: section.number,
                                       ticketID: nil))
            }
        }
        return out
    }

    private static func ticketHits(_ terms: [String]) -> [QASearchHit] {
        QATicketStore.shared.tickets.compactMap { t in
            let body = "\(t.number) \(t.body) \(t.context.screen) \(t.status.rawValue) \(t.severity.rawValue)"
            let s = score(terms: terms, title: t.title, body: body)
            guard s > 0 else { return nil }
            var bits = [t.statusLabel, t.severity.title, t.context.screen, t.context.identity?.label ?? "Unassigned tester"]
            if let dup = t.duplicateOf { bits.append("dup of \(dup)") }
            if let again = t.seenAgain, again > 0 { bits.append("seen \(again + 1)×") }
            return QASearchHit(kind: .ticket,
                               tag: t.number,
                               title: t.title,
                               subtitle: bits.joined(separator: " · "),
                               // An open ticket outranks a closed one.
                               score: s + (t.needsAttention ? 4 : 0),
                               sectionNumber: nil,
                               ticketID: t.id)
        }
    }

    private static func findingHits(_ terms: [String]) -> [QASearchHit] {
        QATriage.shared.findings.compactMap { f in
            let s = score(terms: terms, title: f.title, body: "\(f.detail) \(f.source)")
            guard s > 0 else { return nil }
            return QASearchHit(kind: .finding,
                               tag: f.level.title.uppercased(),
                               title: f.title,
                               subtitle: f.detail,
                               score: s,
                               sectionNumber: nil,
                               ticketID: nil)
        }
    }

    private static func invariantHits(_ terms: [String]) -> [QASearchHit] {
        QARecorder.shared.invariantResults.compactMap { r in
            let s = score(terms: terms, title: r.name, body: r.detail)
            guard s > 0 else { return nil }
            return QASearchHit(kind: .invariant,
                               tag: r.critical ? "CRITICAL" : "probe",
                               title: r.name,
                               subtitle: r.detail,
                               score: s,
                               sectionNumber: nil,
                               ticketID: nil)
        }
    }

    private static func screenHits(_ terms: [String]) -> [QASearchHit] {
        let recorder = QARecorder.shared
        return recorder.visitedScreens.compactMap { screen in
            let s = score(terms: terms, title: screen, body: "")
            guard s > 0 else { return nil }
            let taps = recorder.tapCounts[screen] ?? 0
            return QASearchHit(kind: .screen,
                               tag: "screen",
                               title: screen,
                               subtitle: taps == 0 ? "visited, never tapped" : "\(taps) tap\(taps == 1 ? "" : "s") this session",
                               score: s,
                               sectionNumber: nil,
                               ticketID: nil)
        }
    }

    private static func eventHits(_ terms: [String]) -> [QASearchHit] {
        // Newest first, and capped: the recorder holds 600 events and a broad
        // query would otherwise bury every actionable hit under session noise.
        QARecorder.shared.events.reversed().prefix(200).compactMap { e in
            let s = score(terms: terms, title: e.label, body: "\(e.screen) \(e.detail)")
            guard s > 0 else { return nil }
            return QASearchHit(kind: .event,
                               tag: e.kind.rawValue,
                               title: e.label,
                               subtitle: e.line,
                               score: s,
                               sectionNumber: nil,
                               ticketID: nil)
        }
    }
}

// MARK: - Screen

struct QASearchView: View {
    @State private var query = ""
    @State private var tickets = QATicketStore.shared

    private var groups: [(kind: QASearchHit.Kind, hits: [QASearchHit])] {
        QASearchIndex.grouped(query)
    }

    var body: some View {
        List {
            if query.trimmingCharacters(in: .whitespaces).count < 2 {
                Section {
                    Text("Type two characters or more. This searches all 270 checkbook rows, every ticket, the triage findings, the invariant results, the screens visited this session and the last 200 session events at once.")
                        .font(.stocked(.caption)).foregroundStyle(.secondary)
                }
            } else if groups.isEmpty {
                Section {
                    Label("Nothing matches \"\(query)\"", systemImage: "magnifyingglass")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(groups, id: \.kind.rawValue) { group in
                    Section("\(group.kind.title) (\(group.hits.count))") {
                        ForEach(group.hits) { hit in
                            row(hit)
                        }
                    }
                }
            }
        }
        .searchable(text: $query, prompt: "Search all of QA")
        .navigationTitle("Search QA")
        .navigationBarTitleDisplayMode(.inline)
        .qaScreen("QA > Search")
    }

    @ViewBuilder
    private func row(_ hit: QASearchHit) -> some View {
        switch hit.kind {
        case .check:
            if let number = hit.sectionNumber,
               let section = StockedQAChecklist.sections.first(where: { $0.number == number }) {
                NavigationLink { StockedQASectionView(section: section) } label: { label(hit) }
            } else {
                label(hit)
            }
        case .ticket:
            if let id = hit.ticketID, let ticket = tickets.tickets.first(where: { $0.id == id }) {
                NavigationLink {
                    QATextReportView(title: ticket.number, text: ticket.exportText)
                } label: { label(hit) }
            } else {
                label(hit)
            }
        default:
            label(hit)
        }
    }

    private func label(_ hit: QASearchHit) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: hit.kind.symbol)
                .font(.stocked(.caption))
                .foregroundStyle(Color.stockedGold)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(hit.title)
                    .scaledFont(13)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(hit.tag)
                        .scaledFont(9, weight: .bold, design: .monospaced)
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(Capsule().fill(Color.gray.opacity(0.15)))
                        .foregroundStyle(.secondary)
                    Text(hit.subtitle)
                        .font(.stocked(.caption2)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.vertical, 2)
    }
}
