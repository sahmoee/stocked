// HouseholdSyncProgress.swift
// ─────────────────────────────────────────────────────────────────────────────
// A modal progress prompt for household sync. Observes HouseholdCloudKit.syncStage
// and shows each step (checking account → joining → finding kitchen → downloading →
// uploading → done/failed) so the user — and we, when debugging — can see exactly
// where a sync succeeds or stops. Dismisses on tap once a terminal stage is reached.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

struct HouseholdSyncProgress: View {
    @Environment(AppSession.self) var session
    var cloud = HouseholdCloudKit.shared

    private var stage: HouseholdCloudKit.SyncStage? { cloud.syncStage }

    var body: some View {
        if let stage {
            ZStack {
                Color.black.opacity(0.45).ignoresSafeArea()
                    .onTapGesture { if stage.isTerminal { cloud.clearStage() } }
                VStack(spacing: 16) {
                    icon(for: stage)
                    Text(title(for: stage))
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .multilineTextAlignment(.center)
                    if let sub = subtitle(for: stage) {
                        Text(sub)
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeTextColor.opacity(0.6))
                            .multilineTextAlignment(.center)
                    }
                    if stage.isTerminal {
                        Button {
                            cloud.clearStage()
                        } label: {
                            Text("Done")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color.stockedWhite)
                                .padding(.horizontal, 28).padding(.vertical, 10)
                                .background(session.themeButtonColor)
                                .clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(28)
                .frame(maxWidth: 320)
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite)
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
            }
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private func icon(for stage: HouseholdCloudKit.SyncStage) -> some View {
        switch stage {
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44)).foregroundStyle(Color.stockedGreen)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44)).foregroundStyle(.red.opacity(0.8))
        default:
            ProgressView().scaleEffect(1.4)
        }
    }

    private func title(for stage: HouseholdCloudKit.SyncStage) -> String {
        switch stage {
        case .checkingAccount: return "Checking iCloud…"
        case .creating:        return "Creating household…"
        case .joining:         return "Joining household…"
        case .findingZone:     return "Finding the shared kitchen…"
        case .uploading:       return "Uploading your pantry…"
        case .downloading:     return "Downloading shared pantry…"
        case .done:            return "Synced!"
        case .failed:          return "Sync didn't finish"
        }
    }

    private func subtitle(for stage: HouseholdCloudKit.SyncStage) -> String? {
        switch stage {
        case .uploading(let n):    return "Sending \(n) item\(n == 1 ? "" : "s")…"
        case .downloading(let n):  return n == 0 ? "Looking for shared items…" : "Received \(n) item\(n == 1 ? "" : "s") so far…"
        case .done(let inv, let gro):
            if inv == 0 && gro == 0 { return "Everything is up to date." }
            var parts: [String] = []
            if inv > 0 { parts.append("\(inv) pantry item\(inv == 1 ? "" : "s")") }
            if gro > 0 { parts.append("\(gro) grocery item\(gro == 1 ? "" : "s")") }
            return "Added " + parts.joined(separator: " and ") + "."
        case .failed(let msg):   return msg
        default:                 return nil
        }
    }
}
