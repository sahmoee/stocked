// HouseholdActivityView.swift — Overall improvements #10 (activity feed) + #11 (sync status).
//
// Combines two things a shared kitchen needs but Stocked didn't surface: a plain "sync status"
// (are we connected, when did we last pull, sync now) and a recent-activity timeline stitched from
// data the app already keeps — items used up / thrown away (ConsumptionRecord), purchases
// (PriceRecord), and edits replaced by another device (SyncConflictLog). Read-only over existing
// data plus a manual Sync Now.

import SwiftUI

struct KitchenActivityView: View {
    @Environment(AppSession.self) private var session
    private let conflicts = SyncConflictLog.shared
    @State private var syncing = false
    @State private var syncedJustNow = false

    private var inHousehold: Bool { !session.householdCode.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                syncCard
                if !events.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Recent activity").scaledFont(12, weight: .bold)
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                            .padding(.bottom, 8)
                        ForEach(events) { e in
                            HStack(spacing: 12) {
                                Image(systemName: e.icon).scaledFont(13)
                                    .foregroundStyle(e.tint).frame(width: 22)
                                Text(e.text).scaledFont(14).foregroundStyle(session.themeTextColor)
                                Spacer(minLength: 8)
                                Text(e.date, format: .relative(presentation: .named))
                                    .scaledFont(11).foregroundStyle(session.themeSecondaryText)
                            }
                            .padding(.vertical, 7)
                            Divider().opacity(0.25)
                        }
                    }
                    .padding(14)
                    .background(session.themeTextColor.opacity(0.04))
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                } else {
                    Text("No recent activity yet. As you and your household use things up, shop, and sync, it'll show here.")
                        .scaledFont(13).foregroundStyle(session.themeSecondaryText)
                        .multilineTextAlignment(.center).padding(.horizontal, 20).padding(.top, 30)
                }
            }
            .padding(18)
        }
        .stockedScreen()
        .navigationTitle("Household Activity")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var syncCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: inHousehold ? "person.2.circle.fill" : "person.circle")
                    .scaledFont(22).foregroundStyle(session.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text(inHousehold ? "Connected household" : "Just this device")
                        .scaledFont(15, weight: .semibold).foregroundStyle(session.themeTextColor)
                    Text(inHousehold ? "Code \(session.householdCode) · you're \(session.householdMemberName)"
                                     : "Not sharing with anyone yet")
                        .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                }
                Spacer()
            }
            if inHousehold {
                Button {
                    guard !syncing else { return }
                    syncing = true
                    Task {
                        await HouseholdSync.shared.syncNow(store: session.guestStore)
                        syncing = false
                        syncedJustNow = true
                        HapticManager.success()
                    }
                } label: {
                    HStack(spacing: 8) {
                        if syncing { ProgressView().controlSize(.small) }
                        Text(syncing ? "Syncing…" : (syncedJustNow ? "Synced" : "Sync now"))
                            .scaledFont(14, weight: .semibold)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 11)
                    .background(session.accentColor.opacity(0.14))
                    .foregroundStyle(session.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain).disabled(syncing)

                if conflicts.hasRecentUnreviewed {
                    Text("\(conflicts.unreviewed.count) of your edits were replaced by another device — see the banner on Home to review.")
                        .scaledFont(12).foregroundStyle(.orange)
                }
            }
        }
        .padding(16)
        .background(session.accentColor.opacity(0.07))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Stitched timeline

    private struct ActivityEvent: Identifiable {
        let id = UUID()
        let date: Date
        let text: String
        let icon: String
        let tint: Color
    }

    private var events: [ActivityEvent] {
        var out: [ActivityEvent] = []
        for r in session.guestStore.consumptionLog {
            out.append(ActivityEvent(
                date: r.depletedAt,
                text: r.wasted ? "Threw away \(r.itemName)" : "Used up \(r.itemName)",
                icon: r.wasted ? "trash" : "checkmark.circle",
                tint: r.wasted ? .red : .green))
        }
        for p in session.guestStore.priceHistory {
            out.append(ActivityEvent(date: p.date, text: "Bought \(p.itemName)",
                                     icon: "cart", tint: session.accentColor))
        }
        for c in conflicts.recent {
            out.append(ActivityEvent(date: c.occurredAt, text: c.summary,
                                     icon: "arrow.triangle.2.circlepath", tint: .orange))
        }
        return out.sorted { $0.date > $1.date }.prefix(40).map { $0 }
    }
}
