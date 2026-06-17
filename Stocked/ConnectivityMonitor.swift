// ConnectivityMonitor.swift
// Observes network reachability via NWPathMonitor and publishes a single isOnline flag.
// Used by the root view to show an auto-hiding "No connection" banner, and by network
// clients to skip doomed fetches and serve cached/on-device data when offline (#16).

import Foundation
import Network
import Observation
import os

@Observable
@MainActor
final class ConnectivityMonitor {
    static let shared = ConnectivityMonitor()

    /// True when a usable network path is available. Starts optimistic (true) so we
    /// never flash an offline banner during the first sub-second of launch.
    private(set) var isOnline: Bool = true

    /// Non-isolated snapshot for quick checks from any context (best-effort).
    nonisolated(unsafe) private(set) static var isOnlineFlag: Bool = true

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.stocked.connectivity", qos: .utility)
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            // Runs on a background queue — capture only the Sendable status value, then
            // hop to the main actor and update the shared instance (avoids self-capture).
            let online = path.status == .satisfied
            ConnectivityMonitor.isOnlineFlag = online
            Task { @MainActor in
                let m = ConnectivityMonitor.shared
                if m.isOnline != online {
                    m.isOnline = online
                    Log.net.notice("Connectivity changed: \(online ? "online" : "offline", privacy: .public)")
                }
            }
        }
        monitor.start(queue: queue)
    }
}

