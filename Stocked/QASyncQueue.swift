// QASyncQueue.swift
// ─────────────────────────────────────────────────────────────────────────────
// IMPROVEMENT 9 (Build 74) — where did it actually go, and what broke.
//
// Syncing a ticket touches up to five destinations: the folder mirror, the
// Worker envelope, the screenshot upload, the mockup upload and cPanel. Each can
// fail on its own and for its own reason. What survived a sync was one line:
//
//     "STK-74-0003 → 2 of 4 destinations"
//
// which says two things went somewhere and refuses to say which two, and is
// overwritten by the next sync. When the Worker started answering 405 because a
// route was registered in the wrong order, the app's honest report of that was
// "2 of 4", every time, with the actual message thrown away at the point it was
// generated. Diagnosing it meant reading the Worker's own logs.
//
// So every attempt at every destination is kept: which ticket, which
// destination, what it said, whether it worked. Two questions become answerable
// that were not before — is one destination failing while the others are fine
// (a configuration problem), and is everything failing since a particular moment
// (a deploy) — and both are answered by looking rather than by guessing.
//
// In memory only, capped, deliberately not persisted. This is for the sync
// happening now; a permanent audit trail of every upload the app has ever made
// is a different and much less useful artefact.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

nonisolated struct QASyncAttempt: Identifiable, Codable, Sendable {
    var id = UUID()
    let at: Date
    let number: String
    let destination: String
    let note: String
    let ok: Bool

    // Build 84 — one formatter, made once. This used to allocate a DateFormatter
    // per line, and `exportText` maps it over every attempt inside a `body` that
    // ShareLink evaluates eagerly — hundreds of formatter allocations per redraw
    // of the Sync queue screen. Same pattern as QAEvent.line.
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var line: String {
        "\(Self.timeFormatter.string(from: at)) \(ok ? "ok  " : "FAIL") \(number) \(destination): \(note)"
    }
}

@MainActor
@Observable
final class QASyncQueue {
    static let shared = QASyncQueue()

    private(set) var attempts: [QASyncAttempt] = []
    private let cap = 300
    private nonisolated static let storageKey = "qa.sync.attempts.v2"

    private init() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let saved = try? JSONDecoder().decode([QASyncAttempt].self, from: data) else { return }
        attempts = Array(saved.prefix(cap))
    }

    /// Called once per destination as `syncEverywhere` finishes. `detail` arrives
    /// as the coordinator already formats it — `"worker: failed"`,
    /// `"folder: written"` — so the split happens here rather than making the
    /// coordinator build the same strings twice.
    func record(number: String, detail: [String]) {
        let now = Date()
        for entry in detail {
            let parts = entry.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            let destination = parts.first ?? "unknown"
            let note = parts.count > 1 ? parts[1] : entry
            let ok = Self.readsAsSuccess(note)
            attempts.insert(QASyncAttempt(at: now, number: number,
                                          destination: destination,
                                          note: note, ok: ok), at: 0)
        }
        if attempts.count > cap { attempts.removeLast(attempts.count - cap) }
        persist()
    }

    /// `QASyncOutcome.note` is prose, and the only reliable markers of failure in
    /// it are the words the failure cases use. Matching on failure rather than on
    /// success is the safer direction: an unrecognised note reads as ok, and a
    /// false "ok" in a log next to four real failures misleads nobody, whereas a
    /// false "FAIL" sends someone to fix a destination that works.
    private static func readsAsSuccess(_ note: String) -> Bool {
        let n = note.lowercased()
        if n.contains("fail") || n.contains("error") || n.contains("refused") { return false }
        if n.contains("404") || n.contains("405") || n.contains("500") || n.contains("403") { return false }
        return true
    }

    func clear() { attempts = []; persist() }

    private func persist() {
        let snapshot = attempts
        let logText = exportText
        Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
        Task { _ = await QAFolderMirror.shared.writeStableLog(logText,
                                                              name: "sync-history.txt") }
    }

    // MARK: Reading it

    var failures: [QASyncAttempt] { attempts.filter { !$0.ok } }

    /// Per destination: how many attempts, how many worked, and the most recent
    /// thing it said. This is the table that identifies a single broken
    /// destination in one glance.
    struct DestinationHealth: Identifiable {
        var id: String { destination }
        let destination: String
        let attempts: Int
        let successes: Int
        let lastNote: String
        let lastAt: Date
        var allFailed: Bool { successes == 0 && attempts > 0 }
        var rate: String { "\(successes)/\(attempts)" }
    }

    var health: [DestinationHealth] {
        var grouped: [String: [QASyncAttempt]] = [:]
        for a in attempts { grouped[a.destination, default: []].append(a) }
        return grouped.map { key, list in
            // `attempts` is newest-first, so each group's first entry is its
            // latest — no sort needed and no chance of reporting a stale note.
            let latest = list[0]
            return DestinationHealth(destination: key,
                                     attempts: list.count,
                                     successes: list.filter(\.ok).count,
                                     lastNote: latest.note,
                                     lastAt: latest.at)
        }
        .sorted { $0.destination < $1.destination }
    }

    var summary: String {
        guard !attempts.isEmpty else { return "Nothing has been synced this session." }
        let broken = health.filter(\.allFailed)
        if broken.isEmpty {
            return "\(attempts.count) attempt\(attempts.count == 1 ? "" : "s") · \(failures.count) failed"
        }
        return "\(broken.map(\.destination).joined(separator: ", ")) failing every time"
    }

    var exportText: String {
        var out = ["── SYNC QUEUE ──", summary, ""]
        out.append("BY DESTINATION")
        if health.isEmpty {
            out.append("  nothing attempted")
        } else {
            for h in health {
                out.append("  \(h.destination): \(h.rate) — last said \"\(h.lastNote)\"")
            }
        }
        out += ["", "ATTEMPTS (\(attempts.count), newest first)"]
        out += attempts.map { "  " + $0.line }
        return out.joined(separator: "\n")
    }
}

// MARK: - Screen

struct QASyncQueueView: View {
    @State private var queue = QASyncQueue.shared
    @State private var coordinator = QASyncCoordinator.shared
    @State private var busy = false
    @State private var result = ""

    var body: some View {
        List {
            Section {
                Text(queue.summary)
                    .scaledFont(13)
                    .foregroundStyle(queue.failures.isEmpty ? Color.stockedGreen : Color.stockedWarning)
            } header: {
                Text("Status")
            } footer: {
                Text("Every destination touched by recent ticket syncs, including failures that survived an app relaunch. The history is capped at 300 attempts.")
            }

            if !queue.health.isEmpty {
                Section("By destination") {
                    ForEach(queue.health) { h in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: h.allFailed ? "xmark.circle.fill"
                                  : (h.successes == h.attempts ? "checkmark.circle.fill" : "exclamationmark.circle.fill"))
                                .foregroundStyle(h.allFailed ? .red
                                                 : (h.successes == h.attempts ? Color.stockedGreen : Color.stockedWarning))
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(h.destination).scaledFont(13, weight: .medium)
                                    Spacer()
                                    Text(h.rate)
                                        .scaledFont(12, design: .monospaced)
                                        .foregroundStyle(.secondary)
                                }
                                Text(h.lastNote).font(.stocked(.caption2)).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            Section {
                Button {
                    busy = true
                    result = ""
                    Task {
                        let n = await coordinator.syncAllPending()
                        result = n == 0 ? coordinator.lastOutcome : "Retried \(n)"
                        busy = false
                    }
                } label: {
                    HStack {
                        Label("Retry everything unsynced", systemImage: "arrow.clockwise")
                        if busy { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy)
                if !result.isEmpty {
                    Text(result).font(.stocked(.caption)).foregroundStyle(.secondary)
                }
                ShareLink(item: queue.exportText) {
                    Label("Share the log", systemImage: "square.and.arrow.up")
                }
                Button(role: .destructive) { queue.clear() } label: {
                    Label("Clear the log", systemImage: "trash")
                }
            } footer: {
                Text("Retry walks every ticket that has not reached both the folder and the Worker and sends it again. Destinations that already took it are not re-sent.")
            }

            if !queue.attempts.isEmpty {
                Section("Attempts (\(queue.attempts.count))") {
                    ForEach(queue.attempts.prefix(80)) { a in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: a.ok ? "checkmark" : "xmark")
                                .scaledFont(10, weight: .bold)
                                .foregroundStyle(a.ok ? Color.stockedGreen : .red)
                                .frame(width: 14)
                            Text(a.line)
                                .scaledFont(11, design: .monospaced)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .navigationTitle("Sync queue")
        .navigationBarTitleDisplayMode(.inline)
        .qaScreen("QA > Sync queue")
    }
}
