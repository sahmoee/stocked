import SwiftUI

// #15 Offline-first indicator. A slim banner that appears when the device is offline and any
// household changes are queued, so users know their edits are saved and will sync later. Drop
// `.offlineBanner()` onto a top-level container (e.g. the shell) to surface it app-wide.

struct OfflineBanner: View {
    @Environment(AppSession.self) private var session
    @State private var monitor = ConnectivityMonitor.shared
    @State private var household = HouseholdSync.shared

    private var shouldShow: Bool {
        !monitor.isOnline && (household.state == .owner || household.state == .member)
    }

    var body: some View {
        if shouldShow {
            HStack(spacing: 8) {
                Image(systemName: "wifi.slash").font(.system(size: 12, weight: .semibold))
                let n = household.pendingOps.count
                Text(n > 0 ? "Offline — \(n) change\(n == 1 ? "" : "s") saved, will sync later"
                           : "Offline — changes will sync when you reconnect")
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(Color.stockedWhite)
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(Color.stockedCharcoal.opacity(0.92))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

extension View {
    /// Overlays the offline banner at the top safe-area edge.
    func offlineBanner() -> some View {
        safeAreaInset(edge: .top, spacing: 0) { OfflineBanner() }
    }
}
