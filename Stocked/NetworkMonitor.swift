// NetworkMonitor.swift
// ─────────────────────────────────────────────────────────────────────────────
// Lightweight reachability monitor. Stocked is local-first: every change is written
// to the on-device store immediately, and CloudKit sync happens opportunistically.
// This monitor lets the UI *show* when the device is offline, so the user understands
// their edits are saved locally and will sync once a connection returns — instead of
// a silent failure looking like lost data.
//
// It does NOT gate writes or change sync behavior; it only observes connectivity and
// publishes an `isOnline` flag (plus a coarse connection type) for display.
// ─────────────────────────────────────────────────────────────────────────────
import Foundation
import Network
import SwiftUI

@Observable
@MainActor
final class NetworkMonitor {

    static let shared = NetworkMonitor()

    /// True when the device has a usable network path. Defaults to `true` so the UI
    /// never flashes an offline badge before the first path evaluation arrives.
    private(set) var isOnline: Bool = true

    /// Coarse description of the active interface, for diagnostics or future UI.
    enum ConnectionType: String { case wifi, cellular, wired, other, none }
    private(set) var connection: ConnectionType = .other

    /// Set true once the first path update has been received, so callers can avoid
    /// reacting to the optimistic default before real data exists.
    private(set) var hasEvaluated: Bool = false

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.sowens.Stocked.network-monitor")

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            // NWPathMonitor delivers on its own queue; hop to the main actor to mutate
            // observable state safely.
            let online = path.status == .satisfied
            let type = NetworkMonitor.classify(path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = !self.hasEvaluated || self.isOnline != online
                self.isOnline = online
                self.connection = type
                self.hasEvaluated = true
                // RL-008: tell the offline queue center about real transitions so queued
                // work syncs promptly on reconnect (the center coalesces duplicate reports
                // from ConnectivityMonitor and rate-limits attempts to one per 10 s).
                if changed { OfflineQueueCenter.shared.connectivityChanged(online: online) }
            }
        }
        monitor.start(queue: queue)
    }

    private nonisolated static func classify(_ path: NWPath) -> ConnectionType {
        guard path.status == .satisfied else { return .none }
        if path.usesInterfaceType(.wifi)          { return .wifi }
        if path.usesInterfaceType(.cellular)      { return .cellular }
        if path.usesInterfaceType(.wiredEthernet) { return .wired }
        return .other
    }
}

// MARK: - Offline banner
// A slim, unobtrusive strip the shell shows under the header when offline. Tappable
// targets aren't needed — it's purely informational and auto-hides when back online.

struct OfflineBanner: View {
    @Environment(AppSession.self) private var session
    // Reading the shared monitor's observable properties inside `body` registers this
    // view for updates when connectivity changes.
    @State private var monitor = NetworkMonitor.shared

    private var isOffline: Bool { monitor.hasEvaluated && !monitor.isOnline }

    var body: some View {
        VStack(spacing: 0) {
            if isOffline {
                HStack(spacing: 7) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Offline — changes save here and sync when you reconnect")
                        .font(.system(size: 11.5, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .foregroundStyle(session.themeTextColor.opacity(0.7))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 14)
                .background(session.themeTextColor.opacity(0.08))
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            // RL-008: pending-sync strip rides directly under the offline banner, so it
            // appears everywhere the banner does (StockedShell) with no extra wiring. It
            // handles its own visibility — hidden unless queued work is actually waiting.
            PendingSyncBadge()
        }
        .animation(.easeInOut(duration: 0.25), value: isOffline)
    }
}
