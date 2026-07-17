// OfflineQueueCenter.swift — RL-008 offline hardening: one façade for "what's waiting to sync".
// ─────────────────────────────────────────────────────────────────────────────
// Stocked is local-first, and HouseholdSync already keeps a durable, persisted operation
// queue (LocalDatabase → DBKey.householdOpQueue) with per-op UUIDs + createdAt timestamps
// and LWW merge on the Worker. What was missing:
//
//   1. A single observable place the UI can ask "is anything pending, and will it sync?"
//      (the household queue, plus fire-and-forget Worker posts that used to drop on failure).
//   2. A reconnect trigger: nothing watched connectivity, so offline edits waited for the
//      next 6-second poll tick — or, for one-shot posts like activity events, were lost.
//   3. A durable queue for those one-shot Worker mutations (activity log entries), each with
//      a stable op id + timestamp so a replayed retry can never duplicate server-side.
//
// This type is the façade for all three. It never bypasses HouseholdSync's own single-flight
// syncNow / exponential backoff — it only *requests* a sync at the right moments, coalesced
// and rate-limited (min 10 s between attempts) so a flapping network can't tight-loop us.
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import Observation
import os

// MARK: - Durable worker-bound mutation

/// A one-shot Worker POST that must survive being offline (today: household activity events).
/// `id` doubles as the idempotency key: it rides in the body as `opId`, and the event payload
/// carries its own stable `eventId` + original timestamp, so replaying after a half-completed
/// request (response lost, write applied) cannot duplicate the event in the merged document.
nonisolated struct OfflineWorkerMutation: Codable, Identifiable, Sendable {
    var id = UUID()
    /// Worker path, e.g. "/household/push".
    var path: String
    /// The JSON-encoded request body, captured at enqueue time (timestamps stay original).
    var bodyJSON: Data
    /// Short label for diagnostics ("activity").
    var kind: String
    var createdAt = Date()
    var retryCount = 0
}

// MARK: - The façade

@MainActor
@Observable
final class OfflineQueueCenter {
    static let shared = OfflineQueueCenter()

    // ── Observable pending-sync state (what PendingSyncBadge renders) ──────────

    /// True once a monitor has reported the device offline. Starts false (optimistic) to
    /// match ConnectivityMonitor/NetworkMonitor, so no badge flashes during launch.
    private(set) var isOffline = false

    /// Durable one-shot Worker mutations awaiting replay. Persisted via LocalDatabase so
    /// pending work survives relaunch (acceptance criterion).
    private(set) var queuedWorkerMutations: [OfflineWorkerMutation] = []

    /// Count of queued household operations. Mirrors HouseholdSync so views observing this
    /// façade don't each need to reach into the sync engine.
    var pendingHouseholdOps: Int { HouseholdSync.shared.pendingOps.count }

    /// Everything waiting to reach the Worker.
    var pendingCount: Int { pendingHouseholdOps + queuedWorkerMutations.count }
    var hasPendingWork: Bool { pendingCount > 0 }

    /// Most recent success across the household push/pull and the mutation-queue flush.
    /// Displayed as "last synced" in diagnostics; nil until the first success.
    var lastSyncSuccess: Date? {
        let status = HouseholdSync.shared.syncStatus
        return [status.lastSuccessfulPush, status.lastSuccessfulPull, lastFlushSucceededAt]
            .compactMap { $0 }
            .max()
    }
    /// Last failure of a reconnect-triggered attempt (either path). For diagnostics only —
    /// the UI stays at "will sync" rather than alarming the user about retryable failures.
    private(set) var lastSyncFailure: Date?
    private(set) var lastSyncFailureMessage: String?

    // ── Internals ──────────────────────────────────────────────────────────────

    private(set) var lastFlushSucceededAt: Date?

    /// Persistence key for the mutation queue. Kept as a raw string (LocalDatabase accepts
    /// any key) so this feature does not have to touch the shared DBKey enum.
    private static let queueKey = "offline_worker_mutation_queue_v1"
    /// Bounded queue: activity events are nice-to-have telemetry for the household feed,
    /// so cap count and age rather than grow forever on a long-offline device.
    private static let queueCap = 200
    private static let maxAge: TimeInterval = 14 * 24 * 3600
    /// An op that keeps failing while ONLINE is likely rejected, not delayed — stop
    /// replaying it after this many attempts so one poison event can't wedge the queue.
    private static let maxRetries = 12

    /// Floor between sync attempts. Flapping Wi-Fi can flip online/offline many times a
    /// minute; every restore *requests* a sync, but attempts run at most every 10 s.
    private static let minAttemptGap: TimeInterval = 10

    @ObservationIgnored private var lastAttemptAt: Date = .distantPast
    @ObservationIgnored private var consecutiveFailures = 0
    @ObservationIgnored private var syncTask: Task<Void, Never>? = nil
    @ObservationIgnored private var syncRequestedWhileRunning = false
    @ObservationIgnored private var activated = false

    private init() {
        queuedWorkerMutations = LocalDatabase.shared.loadArray(OfflineWorkerMutation.self,
                                                               key: Self.queueKey) ?? []
        pruneQueue()
    }

    // MARK: - Lifecycle

    /// Called once from HouseholdSync.startAutoSync (which the app runs at launch). Starts
    /// the connectivity monitor (previously never started, so isOnlineFlag stayed frozen at
    /// its optimistic default) and kicks a flush if a previous run left work queued.
    func activate() {
        guard !activated else { return }
        activated = true
        ConnectivityMonitor.shared.start()
        let monitor = NetworkMonitor.shared
        if monitor.hasEvaluated { isOffline = !monitor.isOnline }
        if hasPendingWork && !isOffline {
            requestSync(reason: "launch-with-pending-work")
        }
    }

    /// Fed by ConnectivityMonitor and NetworkMonitor (both report here; requests are
    /// coalesced so double delivery is harmless). Offline→online triggers the recovery sync.
    func connectivityChanged(online: Bool) {
        let wasOffline = isOffline
        isOffline = !online
        guard online else { return }
        if wasOffline {
            // A genuine restore: clear HouseholdSync's persisted backoff (the failures were
            // the dead network's fault, not the server's) so recovery is immediate.
            HouseholdSync.shared.noteConnectivityRestored()
            requestSync(reason: "reconnect")
        } else if hasPendingWork {
            // First evaluation at launch, or a path change (Wi-Fi→cellular) with work queued.
            requestSync(reason: "path-change-with-pending-work")
        }
    }

    // MARK: - Coalesced reconnect sync

    /// Request one sync pass. Multiple requests while a pass is running (or inside the
    /// rate-limit window) collapse into a single follow-up — never a loop of attempts.
    func requestSync(reason: String) {
        if syncTask != nil {
            syncRequestedWhileRunning = true
            return
        }
        syncTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.syncTask = nil
                if self.syncRequestedWhileRunning {
                    self.syncRequestedWhileRunning = false
                    if self.hasPendingWork { self.requestSync(reason: "coalesced-follow-up") }
                }
            }
            // Rate-limit floor + exponential backoff after repeated failures (10 s, 20 s,
            // 40 s … capped at 5 min). Sleeping here — inside the single task — is what
            // makes bursts of connectivity flaps coalesce instead of stacking attempts.
            let backoff = min(Self.minAttemptGap * pow(2.0, Double(self.consecutiveFailures)), 300)
            let earliest = self.lastAttemptAt.addingTimeInterval(max(Self.minAttemptGap, backoff))
            let wait = earliest.timeIntervalSinceNow
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
            guard !Task.isCancelled, !self.isOffline else { return }
            self.lastAttemptAt = Date()
            Log.net.log("OfflineQueueCenter: sync pass (\(reason, privacy: .public))")
            await self.performSyncPass()
        }
    }

    private func performSyncPass() async {
        var allSucceeded = true

        // 1) Household queue → one coalesced syncNow (HouseholdSync is single-flight and
        //    acknowledges only the ops captured in the request, so this is idempotent).
        let sync = HouseholdSync.shared
        if !sync.pendingOps.isEmpty {
            await sync.reconnectSync()
            if !sync.pendingOps.isEmpty { allSucceeded = false }
        }

        // 2) Durable one-shot mutations → FIFO replay.
        if !queuedWorkerMutations.isEmpty {
            let flushed = await flushWorkerQueue()
            if !flushed { allSucceeded = false }
        }

        if allSucceeded {
            consecutiveFailures = 0
            lastSyncFailure = nil
            lastSyncFailureMessage = nil
            // No success banner/notification on purpose: the pending badge simply
            // disappears. Repeated "synced!" toasts on a flapping network would be noise.
        } else {
            consecutiveFailures += 1
            lastSyncFailure = Date()
            lastSyncFailureMessage = sync.syncStatus.lastError ?? "Sync didn't finish."
        }
    }

    // MARK: - Durable worker-mutation queue

    /// Queue a one-shot Worker POST for replay on reconnect. The body should already carry
    /// its own stable ids/timestamps (see HouseholdSync.logActivity) — this method only
    /// adds the transport-level opId envelope.
    func enqueueWorkerMutation(kind: String, path: String, body: [String: Any]) {
        var enriched = body
        let mutation = OfflineWorkerMutation(path: path, bodyJSON: Data(), kind: kind)
        // opId = the mutation's own UUID, so the Worker (or a future dedupe layer) can
        // recognize an exact replay of a request whose response was lost.
        enriched["opId"] = mutation.id.uuidString
        guard JSONSerialization.isValidJSONObject(enriched),
              let data = try? JSONSerialization.data(withJSONObject: enriched) else {
            Log.net.error("OfflineQueueCenter: dropped unencodable \(kind, privacy: .public) mutation")
            return
        }
        var stamped = mutation
        stamped.bodyJSON = data
        queuedWorkerMutations.append(stamped)
        pruneQueue()
        persistQueue()
    }

    /// Replay queued mutations in order. Stops at the first failure (likely still a bad
    /// connection) so retryCounts don't inflate across the whole queue. Returns true when
    /// the queue drained.
    private func flushWorkerQueue() async -> Bool {
        while let next = queuedWorkerMutations.first {
            guard let body = (try? JSONSerialization.jsonObject(with: next.bodyJSON)) as? [String: Any] else {
                queuedWorkerMutations.removeFirst()   // unreadable — never silently loop on it
                persistQueue()
                continue
            }
            let ok = await HouseholdSync.shared.replayPost(next.path, body)
            if ok {
                queuedWorkerMutations.removeFirst()
                lastFlushSucceededAt = Date()
                persistQueue()
            } else {
                if var head = queuedWorkerMutations.first {
                    head.retryCount += 1
                    if head.retryCount >= Self.maxRetries {
                        Log.net.error("OfflineQueueCenter: giving up on \(head.kind, privacy: .public) op after \(head.retryCount) attempts")
                        queuedWorkerMutations.removeFirst()
                    } else {
                        queuedWorkerMutations[0] = head
                    }
                    persistQueue()
                }
                return false
            }
        }
        return true
    }

    private func pruneQueue() {
        let cutoff = Date().addingTimeInterval(-Self.maxAge)
        queuedWorkerMutations.removeAll { $0.createdAt < cutoff }
        while queuedWorkerMutations.count > Self.queueCap {
            queuedWorkerMutations.removeFirst()
        }
    }

    private func persistQueue() {
        LocalDatabase.shared.save(queuedWorkerMutations, key: Self.queueKey)
    }
}
