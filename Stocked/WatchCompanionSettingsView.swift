import SwiftUI

struct WatchCompanionSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var bridge = StockedPhoneWatchBridge.shared
    var body: some View {
        Form {
            Toggle("Share kitchen with Apple Watch", isOn: Binding(get: { bridge.enabled }, set: { bridge.setEnabled($0) }))
            Text(bridge.status).foregroundStyle(session.themeSecondaryText)
            if let date = bridge.lastSync { Text("Snapshot prepared \(date, style: .relative) ago") }
            Button("Refresh Apple Watch") { bridge.publish() }
            Section("Available on your wrist") {
                Text("Grocery checklists and quantities, inventory storage and expiry, saved recipes and steps, a kitchen timer, current-week meal planning and offline kitchen tools.")
                Text("Watch changes use your household permissions. They stay queued until the iPhone confirms a durable save. Older conflicting edits need review; additions are never blindly repeated.")
            }
            Section("Privacy and limits") {
                Text("Only your paired Watch receives compact kitchen data. No account credentials, photos or original imports are sent. Turning sharing off clears the Watch copy when it next connects.")
                Text("Scanners, provider setup, imports, AI, full recipe discovery and cooked-meal stock deductions remain on iPhone. Timers on Watch are independent from iPhone timers.")
            }
        }.navigationTitle("Apple Watch").scrollContentBackground(.hidden).background(session.themeBgColor)
    }
}
