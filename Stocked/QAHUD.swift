// QAHUD.swift
// ─────────────────────────────────────────────────────────────────────────────
// An opt-in, read-only, one-line overlay: memory, worst frame hitch, failures,
// open tickets. Nothing to tap.
//
// WHY READ-ONLY, AND WHY THAT IS THE POINT
// This app used to have a floating QA bubble with controls on it. It was removed
// in Build 70 because a second interactive surface floating over every screen is
// a second thing that can eat a touch, cover the button you were testing, and
// change the behaviour you came to observe. The lesson was not "no overlay" — it
// was "no overlay that participates".
//
// So this one cannot be tapped (`allowsHitTesting(false)`), cannot be dragged,
// and has no buttons. It reports four numbers and gets out of the way. It exists
// because performance problems are the ones you cannot see in a log after the
// fact: watching memory climb 40 MB per screen while you navigate tells you
// something that reading the same numbers ten minutes later never will.
//
// Off by default, even inside QA mode. It goes translucent when everything is
// fine and colours up when something is not, so peripheral vision does the work.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI
// For UIWindow / UIWindowScene, which QAHUDWindow owns directly.
import UIKit

nonisolated enum QAHUDSettings {
    static let enabledKey = "qa.hud.enabled"
    static let positionKey = "qa.hud.top"   // true = top, false = bottom
}

/// Zero-size mount point. The visible HUD is `QAHUDBar`, hosted in a window of
/// its own — see `QAHUDWindow`.
struct QAHUD: View {
    @State private var recorder = QARecorder.shared
    @AppStorage(QAHUDSettings.enabledKey) private var enabled = false

    private var shouldShow: Bool { enabled && recorder.isEnabled }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onAppear { QAHUDWindow.shared.sync(visible: shouldShow) }
            .onDisappear { QAHUDWindow.shared.sync(visible: false) }
            .onChange(of: shouldShow) { _, now in QAHUDWindow.shared.sync(visible: now) }
    }
}

/// Puts the HUD in its own window, above everything the app can present.
///
/// As a plain overlay in RootView's ZStack the HUD vanished the moment a sheet,
/// a cover or an alert came up — which is the worst possible time to lose sight
/// of memory and hitches, because modal screens are where the expensive work
/// usually happens. A window at the alert level is visible over all of it.
///
/// The window is inert: `isUserInteractionEnabled = false` on both the window and
/// the hosting view, and it is never made key. It cannot take a touch, cannot
/// take the keyboard, and cannot change what the app underneath does. That is the
/// same promise the HUD always made — this just keeps it in more places.
@MainActor
final class QAHUDWindow {
    static let shared = QAHUDWindow()
    private init() {}

    private var window: UIWindow?

    func sync(visible: Bool) {
        if visible { show() } else { hide() }
    }

    private func show() {
        guard window == nil else { return }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }

        let host = UIHostingController(rootView: QAHUDBar())
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false

        // `.alert` puts it over sheets, covers and alerts, and one level below
        // the issue reporter's window so the composer is never behind the HUD.
        let w = UIWindow(windowScene: scene)
        w.windowLevel = .alert
        w.backgroundColor = .clear
        w.isUserInteractionEnabled = false
        w.rootViewController = host
        w.isHidden = false        // deliberately not makeKeyAndVisible()
        window = w
    }

    private func hide() {
        guard let w = window else { return }
        window = nil
        w.isHidden = true
        w.windowScene = nil
    }
}

// MARK: - The bar itself

struct QAHUDBar: View {
    @State private var recorder = QARecorder.shared
    @State private var runtime = QARuntimeMonitor.shared
    @State private var tickets = QATicketStore.shared

    @AppStorage(QAHUDSettings.positionKey) private var atTop = false

    var body: some View {
        VStack {
            if !atTop { Spacer() }
            bar
            if atTop { Spacer() }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .allowsHitTesting(false)          // never steals a touch. Ever.
    }

    private var bar: some View {
        HStack(spacing: 10) {
            stat("memorychip", String(format: "%.0f", runtime.currentFootprintMB),
                 tint: runtime.memoryGrowthMB > 250 ? .orange : .secondary)

            stat("bolt.fill",
                 runtime.worstHitchMs > 0 ? String(format: "%.0f", runtime.worstHitchMs) : "—",
                 tint: runtime.severeHitchCount > 0 ? .red
                     : (runtime.worstHitchMs > 250 ? .orange : .secondary))

            stat("xmark.octagon.fill", "\(recorder.failureCount)",
                 tint: recorder.failureCount > 0 ? .red : .secondary)

            stat("ticket.fill", "\(tickets.openCount)",
                 tint: tickets.blockers.isEmpty ? (tickets.openCount > 0 ? .orange : .secondary) : .red)

            if runtime.isThrottled {
                Image(systemName: "thermometer.high")
                    .foregroundStyle(.orange)
            }
            if !runtime.online {
                Image(systemName: "wifi.slash")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2.monospacedDigit())
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(alarmed ? Color.red.opacity(0.5) : Color.clear, lineWidth: 1))
        // Nearly invisible while everything is fine; it should not compete with
        // the app for attention until it has something to say.
        .opacity(alarmed ? 0.95 : 0.55)
        .animation(.easeInOut(duration: 0.25), value: alarmed)
    }

    private var alarmed: Bool {
        recorder.failureCount > 0 || runtime.severeHitchCount > 0 || !tickets.blockers.isEmpty
    }

    private func stat(_ symbol: String, _ value: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9))
            Text(value)
        }
        .foregroundStyle(tint)
    }
}
