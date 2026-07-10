// CrowdShareToggle.swift — drop-in Settings row for the shared crowd database.
//
// Add this Section anywhere in your Settings form. Contribution is ON by default; this lets a
// user opt out. Reads (smarter defaults) keep working regardless.
//
//     Form {
//         CrowdShareToggle()
//         // …your other sections…
//     }

import SwiftUI

struct CrowdShareToggle: View {
    // Defaults to true (opt-out model) to match CrowdDB.isEnabled.
    @AppStorage("crowdShareEnabled") private var enabled: Bool = true

    var body: some View {
        Section {
            Toggle("Improve Stocked for everyone", isOn: $enabled)
        } footer: {
            Text("Shares anonymized item facts (name, category, typical unit/container/quantity) "
               + "so the app can suggest smarter defaults for all users. Never shares your name, "
               + "account, or location. Turn off anytime — you still get everyone else's suggestions.")
        }
    }
}
