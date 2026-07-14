// CrowdShareToggle.swift — drop-in Settings row for the shared crowd database.
//
//     Form {
//         CrowdShareToggle()
//         // …your other sections…
//     }

import SwiftUI

struct CrowdShareToggle: View {
    // Defaults to true (opt-out) to match CrowdDB.isEnabled.
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
