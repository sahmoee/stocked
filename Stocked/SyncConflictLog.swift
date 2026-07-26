// SyncConflictLog.swift — Improvement #19: stop losing edits silently.
//
// `HouseholdSync.applyHousehold` resolves every collision with last-write-wins. When the incoming
// record wins and the local one wasn't locally edited, the local value is overwritten with no
// record and no notice — it simply vanishes. `pendingConflicts` exists, but it only catches the
// narrow case where the entity is in the pending-op queue AND the pull path is running, it lives
// in memory only, and planned meals are excluded from the check entirely.
//
// Silent data loss is the fastest way to lose trust in a shared app, and the metadata needed to
// detect it (`updatedAt`, `lastWriterID`) is already on every synced model. This records what got
// replaced, persists it across launches, and gives the user a way to see it.
//
// It deliberately does NOT change the merge outcome — LWW still wins, so sync behaviour is
// unchanged and this can't introduce a regression. It just makes the loss visible.

import SwiftUI

// MARK: - Model

nonisolated struct SyncConflictRecord: Codable, Identifiable, Sendable, Hashable {
    var id: UUID = UUID()
    var entityType: String       // "Inventory" | "Grocery" | "Planned meal" | …
    var entityName: String       // what the user calls it
    var replacedValue: String    // a readable summary of what was lost
    var winningValue: String     // what replaced it
    var winningWriter: String    // household member name, or "" when unknown
    var occurredAt: Date = Date()
    var reviewed: Bool = false

    var summary: String {
        winningWriter.isEmpty
            ? "\(entityName) was replaced by another device's version"
            : "\(winningWriter)'s change to \(entityName) replaced yours"
    }
}

// MARK: - Log

@MainActor
@Observable
final class SyncConflictLog {
    static let shared = SyncConflictLog()

    private let persistence = FeatureStore<SyncConflictRecord>(key: FeatureStoreKeys.syncConflicts)
    private(set) var records: [SyncConflictRecord] = []

    /// Keep this bounded — a badly-behaved sync loop must not fill the disk with conflict rows.
    private let maxRecords = 100

    private init() { records = persistence.load() }

    func flush() { persistence.flush() }

    // MARK: Recording

    /// Called from the merge path when a local value is discarded.
    func record(entityType: String,
                entityName: String,
                replaced: String,
                winning: String,
                writer: String = "") {
        // Nothing was actually lost if the two sides agree.
        guard replaced != winning else { return }
        records.append(SyncConflictRecord(entityType: entityType,
                                          entityName: entityName,
                                          replacedValue: replaced,
                                          winningValue: winning,
                                          winningWriter: writer))
        if records.count > maxRecords { records = Array(records.suffix(maxRecords)) }
        persistence.save(records)
    }

    // MARK: Reading

    var unreviewed: [SyncConflictRecord] {
        records.filter { !$0.reviewed }.sorted { $0.occurredAt > $1.occurredAt }
    }
    var recent: [SyncConflictRecord] {
        records.sorted { $0.occurredAt > $1.occurredAt }
    }
    /// Only surface a banner for things that happened while the user was plausibly around.
    var hasRecentUnreviewed: Bool {
        unreviewed.contains { $0.occurredAt > Date().addingTimeInterval(-7 * 86_400) }
    }

    func markAllReviewed() {
        for i in records.indices { records[i].reviewed = true }
        persistence.save(records)
    }
    func clear() {
        records = []
        persistence.save(records)
    }
}

// MARK: - Banner

/// A quiet, dismissible strip. Not an alert: nothing is broken and nothing needs an immediate
/// decision — the user just deserves to know an edit of theirs was replaced.
struct SyncConflictBanner: View {
    @Environment(AppSession.self) private var session
    private let log = SyncConflictLog.shared
    @State private var showDetail = false

    var body: some View {
        if log.hasRecentUnreviewed {
            Button { showDetail = true } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.2.circlepath.circle")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(log.unreviewed.count) change\(log.unreviewed.count == 1 ? "" : "s") replaced by sync")
                            .stockedFont(.rowTitle)
                            .foregroundStyle(session.themeTextColor)
                        Text("Tap to see what changed")
                            .stockedFont(.caption)
                            .foregroundStyle(session.themeSecondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(session.themeSecondaryText)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.orange.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .sheet(isPresented: $showDetail) { SyncConflictReviewView() }
        }
    }
}

// MARK: - Review screen

struct SyncConflictReviewView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    private let log = SyncConflictLog.shared

    var body: some View {
        NavigationStack {
            List {
                if log.records.isEmpty {
                    Text("No sync conflicts recorded.")
                        .foregroundStyle(session.themeSecondaryText)
                } else {
                    Section {
                        ForEach(log.recent) { r in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(r.summary).stockedFont(.rowTitle)
                                HStack(spacing: 6) {
                                    Text(r.replacedValue)
                                        .strikethrough()
                                        .foregroundStyle(session.themeSecondaryText)
                                    Image(systemName: "arrow.right").font(.system(size: 9))
                                        .foregroundStyle(session.themeSecondaryText)
                                    Text(r.winningValue).foregroundStyle(session.themeTextColor)
                                }
                                .stockedFont(.rowDetail)
                                Text("\(r.entityType) · \(r.occurredAt.formatted(date: .abbreviated, time: .shortened))")
                                    .stockedFont(.caption)
                                    .foregroundStyle(session.themeSecondaryText)
                            }
                            .padding(.vertical, 3)
                        }
                    } footer: {
                        Text("Stocked keeps the most recent edit when two devices change the same thing. This is a record of what the newer edit replaced, so a change of yours never disappears without you knowing.")
                    }
                    Section {
                        Button(role: .destructive) { log.clear() } label: { Text("Clear log") }
                    }
                }
            }
            .stockedScreen()
            .navigationTitle("Replaced by sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { log.markAllReviewed(); dismiss() }.font(.body.bold())
                }
            }
        }
    }
}
