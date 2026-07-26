// QAFloatingBubble.swift — the always-reachable QA bubble, factored back in from the
// retired QA Workbook (its most-missed feature). Renders NOTHING unless QA mode is
// enabled, so production users never see it. While enabled, a small floating chip sits
// above every screen showing live violation/failure counts; tapping it opens the QA
// hub without digging through Settings → App Health.

import SwiftUI

struct QAFloatingBubble: View {
    @Environment(AppSession.self) private var session
    @State private var recorder = QARecorder.shared
    @State private var showHub = false

    private var issueCount: Int { recorder.violationCount + recorder.failureCount }

    var body: some View {
        if recorder.isEnabled {
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button { showHub = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 14, weight: .semibold))
                            Text(issueCount == 0 ? "QA" : "QA · \(issueCount)")
                                .font(.system(size: 12, weight: .bold))
                        }
                        .foregroundStyle(Color.stockedWhite)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(
                            Capsule().fill(issueCount == 0 ? Color.stockedGold.opacity(0.92) : Color.red.opacity(0.92))
                        )
                        .shadow(radius: 4, y: 2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(issueCount == 0 ? "QA, no issues" : "QA, \(issueCount) issues")
                    .padding(.trailing, 14)
                    .padding(.bottom, 96)   // clear of the tab bar
                }
            }
            .allowsHitTesting(true)
            .sheet(isPresented: $showHub) {
                NavigationStack { QAModeView().environment(session) }
            }
        }
    }
}
