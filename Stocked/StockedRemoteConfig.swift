// StockedRemoteConfig.swift — app adoption of the Worker's GET /configuration endpoint.
//
// The Worker serves a small signed-by-transport (HTTPS + X-Stocked-Key) configuration blob
// from KV: kill switches, disabled recipe sources, maintenance messages, and a minimum
// supported version. This lets a broken feature be turned off — or a maintenance notice
// shown — WITHOUT an App Store release (see FUTURE_IDEAS.md "Best item on the list").
//
// Design:
//   • Fetch is deferred a few seconds after launch (never competes with first render) and
//     refreshed on foreground at most every 15 minutes, with ETag/If-None-Match so an
//     unchanged config costs a 304 and no body.
//   • The last good config is persisted, so kill switches keep working offline.
//   • Everything fails open: no config (or any error) means "nothing disabled".
//   • StockedWorkerClient consults `isRouteKilled` before each AI route, so a runaway
//     or broken AI feature can be stopped server-side within a minute.

import Foundation
import SwiftUI
import os

// Wire format of GET /configuration (see stocked-receipt-worker/src/config.js).
nonisolated struct RemoteAppConfig: Codable, Sendable, Equatable {
    struct Maintenance: Codable, Sendable, Equatable {
        var active: Bool = false
        var message: String = ""
    }
    var minSupportedVersion: String = "0.0.0"
    var maintenance: Maintenance = Maintenance()
    var disabledRecipeSources: [String] = []
    var killSwitches: [String: Bool] = [:]

    static let empty = RemoteAppConfig()
}

@MainActor
@Observable
final class StockedRemoteConfig {
    static let shared = StockedRemoteConfig()

    private(set) var config: RemoteAppConfig = .empty
    private(set) var lastFetched: Date? = nil

    @ObservationIgnored private var etag: String? = nil
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private let minRefreshInterval: TimeInterval = 15 * 60

    private static let cacheKey = "remoteConfig_v1"
    private static let etagKey  = "remoteConfigETag_v1"

    private init() {
        // Serve the persisted config immediately so offline launches keep prior switches.
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let saved = try? JSONDecoder().decode(RemoteAppConfig.self, from: data) {
            config = saved
        }
        etag = UserDefaults.standard.string(forKey: Self.etagKey)
    }

    // MARK: - Reads

    /// True when the named kill switch is flipped on server-side.
    func isKilled(_ feature: String) -> Bool { config.killSwitches[feature] == true }

    /// Route-level gate used by StockedWorkerClient. Switch names mirror route raw values,
    /// plus the umbrella "allAI" that stops every AI route at once.
    func isRouteKilled(_ route: String) -> Bool {
        if config.killSwitches["allAI"] == true { return true }
        return config.killSwitches[route] == true
    }

    /// True when a recipe source (e.g. "Spoonacular") has been remotely disabled.
    func isSourceDisabled(_ source: String) -> Bool {
        config.disabledRecipeSources.contains { $0.caseInsensitiveCompare(source) == .orderedSame }
    }

    var maintenanceMessage: String? {
        guard config.maintenance.active else { return nil }
        let msg = config.maintenance.message.trimmingCharacters(in: .whitespacesAndNewlines)
        return msg.isEmpty ? "Stocked is undergoing brief maintenance. Some features may pause." : msg
    }

    /// True when this build is older than the server's minimum supported version.
    var updateRequired: Bool {
        Self.versionIsOlder(BuildConfig.version, than: config.minSupportedVersion)
    }

    static func versionIsOlder(_ lhs: String, than rhs: String) -> Bool {
        let a = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let b = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let l = i < a.count ? a[i] : 0
            let r = i < b.count ? b[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    // MARK: - Fetch

    /// Kick off the deferred launch fetch. Call once from RootView; safe to call again.
    func startDeferredLaunchFetch() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await refreshIfStale()
        }
    }

    /// Refresh on foreground, throttled to `minRefreshInterval`.
    func refreshIfStale() async {
        if let last = lastFetched, Date().timeIntervalSince(last) < minRefreshInterval { return }
        await refresh()
    }

    func refresh() async {
        guard !inFlight, StockedWorkerClient.isConfigured,
              let base = StockedWorkerClient.url() else { return }
        inFlight = true
        defer { inFlight = false }

        var request = URLRequest(url: base.appendingPathComponent("configuration"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        BuildConfig.authorizeWorkerRequest(&request)
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 304 { lastFetched = Date(); return }
            guard http.statusCode == 200 else { return }
            let decoded = try JSONDecoder().decode(RemoteAppConfig.self, from: data)
            config = decoded
            lastFetched = Date()
            if let tag = http.value(forHTTPHeaderField: "ETag") {
                etag = tag
                UserDefaults.standard.set(tag, forKey: Self.etagKey)
            }
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        } catch {
            // Fail open — keep whatever config we already have.
            Log.app.debug("RemoteConfig fetch failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

// MARK: - Maintenance / update banner

/// Slim banner surfaced from RootView when the server flags maintenance or a required
/// update. Informative, dismissible for the session (maintenance only), never blocking.
struct RemoteConfigBanner: View {
    @Environment(AppSession.self) private var session
    @State private var remote = StockedRemoteConfig.shared
    @State private var dismissed = false

    var body: some View {
        if remote.updateRequired {
            banner(icon: "arrow.down.circle.fill",
                   text: "This version of Stocked is out of date. Please update from the App Store.",
                   dismissible: false)
        } else if let msg = remote.maintenanceMessage, !dismissed {
            banner(icon: "wrench.and.screwdriver.fill", text: msg, dismissible: true)
        }
    }

    private func banner(icon: String, text: String, dismissible: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold))
            Text(text).font(.system(size: 13, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if dismissible {
                Button { dismissed = true } label: {
                    Image(systemName: "xmark").font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .foregroundStyle(Color.stockedWhite)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.stockedGold, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}
