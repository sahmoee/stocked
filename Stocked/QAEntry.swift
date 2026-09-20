// QAEntry.swift
// ─────────────────────────────────────────────────────────────────────────────
// BUILD 74 — QA has one door.
//
// Until this build QA had two doors, and they led to different rooms:
//
//   Settings → QA                                   → the release checkbook
//   Settings → Data & Storage → App Health → QA     → the QA hub
//
// The screen with almost everything on it — recording, tickets, runtime,
// processes, invariants, diagnostics, the crash log, the event feed, the bridge,
// the export — was the one buried four levels deep behind a heading about disk
// usage. The screen with one list on it was the one actually called QA. Anyone
// looking for QA found the smaller half and concluded that was all there was.
//
// Settings → QA is now the hub, and the checkbook is a row inside it. App Health
// has no QA section at all any more: it is back to being exactly what its name
// says, a health readout for the app, with nothing about testing leaking into it.
//
// The gate lives here rather than inside either screen because "is QA unlocked"
// is one fact about the app and should be asked one way wherever it is asked
// from — Settings, the floating button, or a jump straight into the checkbook.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

// MARK: - The gate

/// Wraps any QA surface in the ten-minute passcode window.
///
/// Deliberately has no `NavigationStack` of its own. Some callers already supply
/// one — the floating menu does, so it can hang a Done button in the toolbar —
/// and nesting stacks gives you two navigation bars sitting on top of each other,
/// which is what the QA screens looked like before this build.
struct QAUnlockGate<Content: View>: View {
    var lockedTitle: String = "QA Access"
    var lockedMessage: String = "Enter the QA code to open QA."
    @ViewBuilder var content: () -> Content

    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var gate = QAAccessGate.shared
    @State private var code = ""
    @State private var wrong = false
    @State private var shake = false

    private var appVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—" }
    private var buildNumber: String { Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—" }

    var body: some View {
        Group {
            if gate.isUnlocked {
                content()
            } else {
                lockedPane
            }
        }
        // `isUnlocked` is computed against `Date()`, which observation cannot see
        // change. This tick gives it something it can see: at expiry the gate nils
        // its stored timestamp, and the view flips back to the prompt while the
        // tester is looking at it rather than on next appearance.
        //
        // A `.task` loop rather than a Combine timer — SwiftUI re-exports UIKit
        // but not Combine, and `Timer.publish(…).autoconnect()` would need an
        // import this file does not otherwise want. That exact assumption is what
        // broke QAHUD in Build 71.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                gate.expireIfLapsed()
            }
        }
    }

    private var lockedPane: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView {
            VStack(spacing: 0) {
                Spacer().frame(height: 36)
                Image(systemName: "lock.shield")
                    .scaledFont(48)
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                Text(lockedTitle)
                    .scaledFont(22, weight: .bold)
                    .foregroundStyle(session.themeTextColor)
                    .padding(.top, 18)
                Text("Stocked · \(appVersion) (\(buildNumber))")
                    .scaledFont(13)
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { index in
                        Circle()
                            .fill(index < code.count ? Color.stockedGold : session.themeTextColor.opacity(0.2))
                            .frame(width: 14, height: 14)
                    }
                }
                .padding(.top, 48)
                .offset(x: shake ? -8 : 0)
                .animation(shake ? .default.repeatCount(3, autoreverses: true).speed(4) : .default, value: shake)
                Text("Enter your four-digit access code")
                    .scaledFont(11)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                    .padding(.top, 8)
                if wrong {
                    Text("That's not the code.")
                        .scaledFont(12).foregroundStyle(.red)
                        .padding(.top, 8)
                }
                keypad.padding(.top, 40)
                Button("Cancel") { dismiss() }
                    .scaledFont(16)
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.top, 36)
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationTitle("QA")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var keypad: some View {
        VStack(spacing: 16) {
            ForEach([[1, 2, 3], [4, 5, 6], [7, 8, 9], [0]], id: \.self) { row in
                HStack(spacing: 24) {
                    if row == [0] { Color.clear.frame(width: 72, height: 72) }
                    ForEach(row, id: \.self) { digit in
                        Button {
                            guard code.count < 4 else { return }
                            code.append(String(digit))
                            if code.count == 4 { tryUnlock() }
                        } label: {
                            Text("\(digit)")
                                .scaledFont(28)
                                .frame(width: 72, height: 72)
                                .background(Circle().fill(session.themeCardColor))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(session.themeTextColor)
                    }
                    if row == [0] {
                        Button {
                            if !code.isEmpty { code.removeLast() }
                        } label: {
                            Image(systemName: "delete.left")
                                .scaledFont(20)
                                .frame(width: 72, height: 72)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.stockedGold)
                    }
                }
            }
        }
    }

    private func tryUnlock() {
        if gate.unlock(with: code) {
            wrong = false
            code = ""
            // Unlocking is what makes the floating button available. Sync it
            // immediately so the button is there when this screen is dismissed.
            QAFloatingButtonWindow.shared.syncFromGate()
        } else {
            wrong = true
            code = ""
            shake = true
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                shake = false
            }
        }
    }
}

// MARK: - The one door

/// What Settings → QA opens, and what the floating button opens. Everything QA
/// is reachable from here and from nowhere else.
struct StockedQAEntryView: View {
    var body: some View {
        NavigationStack {
            QAUnlockGate(lockedMessage: "Enter the QA code to open the QA hub.") {
                QAModeView()
            }
        }
    }
}
