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
    @State private var gate = QAAccessGate.shared
    @State private var code = ""
    @State private var wrong = false

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
            VStack(spacing: 18) {
                Image(systemName: "checklist")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.stockedGold)
                Text(lockedTitle)
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text(gate.hasEverUnlocked
                     ? "The last unlock has expired. The code opens QA for another ten minutes."
                     : lockedMessage)
                    .font(.system(size: 13))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .multilineTextAlignment(.center)
                SecureField("QA code", text: $code)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(session.themeCardColor))
                    .frame(maxWidth: 240)
                    .multilineTextAlignment(.center)
                    .onSubmit(tryUnlock)
                if wrong {
                    Text("That's not the code.")
                        .font(.system(size: 12)).foregroundStyle(.red)
                }
                Button(action: tryUnlock) {
                    Text("Unlock")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stockedBlack)
                        .padding(.horizontal, 34).padding(.vertical, 11)
                        .background(Capsule().fill(Color.stockedGold))
                }
                .buttonStyle(.plain)
                Text("One unlock lasts ten minutes across every QA screen.")
                    .font(.system(size: 11))
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .navigationTitle("QA")
        .navigationBarTitleDisplayMode(.inline)
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
