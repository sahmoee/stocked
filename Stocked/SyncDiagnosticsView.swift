import SwiftUI

// #18 Sync diagnostics. A plain read-only panel surfacing HouseholdSyncStatus so sync problems
// can be understood in the field: last push/pull, pending count, stuck-op flag, active route, and
// last error. Reachable from Data & Storage (add a NavigationLink to SyncDiagnosticsView).

struct SyncDiagnosticsView: View {
    @Environment(AppSession.self) private var session
    @State private var household = HouseholdSync.shared
    @State private var isSendingReport = false
    @State private var reportResult: String? = nil

    private var s: HouseholdSyncStatus { household.syncStatus }

    private func rel(_ d: Date?) -> String {
        guard let d else { return "Never" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: d, relativeTo: Date())
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Sync Diagnostics") {
            VStack(spacing: 12) {
                card {
                    row("In a household", household.state == .owner || household.state == .member ? "Yes" : "No")
                    row("Role", household.myAccessRole.label)
                    row("Last synced up", rel(s.lastSuccessfulPush))
                    row("Last received", rel(s.lastSuccessfulPull))
                    row("Pending changes", "\(household.pendingOps.count)")
                    row("Active route", s.activeRoute?.rawValue ?? "—")
                    row("Stuck operations", s.hasStuckOperations ? "Yes — needs attention" : "No")
                    if let e = s.lastError, !e.isEmpty { row("Last error", e) }
                }
                Button {
                    Task { await household.syncNow(store: session.guestStore) }
                } label: {
                    Text("Force Sync Now").font(.system(size: 15, weight: .semibold)).foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.stockedGold, in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)

                // POST /support/diagnostics — uploads a privacy-scrubbed snapshot (counts,
                // versions, sync health; never item or recipe names) and shows a reference
                // number the user can quote to support.
                Button {
                    guard !isSendingReport else { return }
                    isSendingReport = true
                    reportResult = nil
                    Task { @MainActor in
                        do {
                            let ref = try await StockedDiagnosticsUploader.upload(session: session)
                            reportResult = "Report sent — reference \(ref). Quote this in your support email."
                        } catch {
                            reportResult = error.localizedDescription
                        }
                        isSendingReport = false
                    }
                } label: {
                    HStack(spacing: 8) {
                        if isSendingReport { ProgressView().tint(Color.stockedWhite) }
                        Text(isSendingReport ? "Sending…" : "Send Diagnostics Report")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.stockedGold.opacity(0.85), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(.plain)

                if let reportResult {
                    Text(reportResult)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(session.themeTextColor.opacity(0.75))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }

                Text("These details help diagnose household sync. Nothing here is shared.")
                    .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20).padding(.top, 8)
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 20))
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.7))
            Spacer()
            Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(session.themeTextColor)
                .multilineTextAlignment(.trailing)
        }
        .padding(.vertical, 8)
    }
}
