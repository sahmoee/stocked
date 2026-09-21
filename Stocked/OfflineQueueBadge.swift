// OfflineQueueBadge.swift — RL-008 pending-sync surface.
// ─────────────────────────────────────────────────────────────────────────────
// A slim, OfflineBanner-style strip that appears whenever local work is queued for the
// Worker (household operations or replayable one-shot mutations). It answers the quiet
// worry behind offline editing — "did my change stick?" — with "Pending changes · will
// sync", and disappears on its own once the queue drains. Deliberately no success state:
// the badge vanishing IS the success signal, so a flapping network never spams the user.
//
// Wiring: OfflineBanner (NetworkMonitor.swift) embeds this directly, so it already shows
// everywhere the offline strip shows (StockedShell renders OfflineBanner under the header).
// It can also be dropped standalone into any screen that wants the indicator.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

struct PendingSyncBadge: View {
    @Environment(AppSession.self) private var session
    // Reading the shared center's observable state inside `body` registers this view for
    // updates as ops queue/drain and connectivity changes.
    @State private var center = OfflineQueueCenter.shared
    @State private var sync = HouseholdSync.shared

    /// Bumped by a short timer so the "waited long enough to matter" check re-evaluates
    /// even though op age isn't itself observable.
    @State private var ageTick = 0

    private var pendingCount: Int { center.pendingCount }

    /// Online with a healthy poller, ops clear within seconds — flashing a badge for every
    /// edit would be noise. Show only when the queue is actually *waiting*: offline, stuck,
    /// or older than one poll cycle without draining.
    private var shouldShow: Bool {
        _ = ageTick   // re-evaluate when the timer fires
        guard pendingCount > 0 else { return false }
        if center.isOffline { return true }
        if sync.syncStatus.hasStuckOperations { return true }
        let oldest = sync.pendingOps.map(\.createdAt).min()
            ?? center.queuedWorkerMutations.map(\.createdAt).min()
        if let oldest, Date().timeIntervalSince(oldest) > 15 { return true }
        return false
    }

    private var label: String {
        let count = pendingCount
        let changes = count == 1 ? "1 change" : "\(count) changes"
        if center.isOffline {
            // The offline strip above already says "changes save here" — this adds the count.
            return "\(changes) waiting · will sync when you're back online"
        }
        return "Pending \(changes) · will sync"
    }

    var body: some View {
        VStack(spacing: 0) {
            if shouldShow {
                HStack(spacing: 7) {
                    Image(systemName: center.isOffline
                          ? "tray.and.arrow.down"
                          : "arrow.triangle.2.circlepath")
                        .scaledFont(11, weight: .semibold)
                    Text(label)
                        .scaledFont(11.5, weight: .medium)
                        .fixedSize(horizontal: false, vertical: true)

                    // An op stuck through 8+ retries while online deserves a visible hint
                    // rather than an eternally-spinning promise (never silently discard).
                    if sync.syncStatus.hasStuckOperations {
                        Text("· having trouble syncing")
                            .scaledFont(11.5, weight: .medium)
                            .foregroundStyle(Color.stockedError.opacity(0.85))
                    }
                }
                .foregroundStyle(session.themeTextColor.opacity(0.65))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .padding(.horizontal, 14)
                .background(Color.stockedGold.opacity(0.14))
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Pending changes will sync automatically")
                .onTapGesture {
                    // Manual nudge — harmless: requests are coalesced and rate-limited.
                    center.requestSync(reason: "badge-tap")
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: shouldShow)
        // Re-check the age threshold shortly after work queues, so a badge that *should*
        // appear (ops still pending after a poll cycle) does — op age isn't observable.
        .task(id: pendingCount) {
            guard pendingCount > 0 else { return }
            try? await Task.sleep(nanoseconds: 16_000_000_000)
            ageTick &+= 1
        }
    }
}
