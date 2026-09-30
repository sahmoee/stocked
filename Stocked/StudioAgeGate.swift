// StudioAgeGate.swift
// One-time, neutral age confirmation shown on first launch. Nothing is stored except the
// confirmed minimum age (no birth date). Policies live at sowensstudios.com.

import SwiftUI
import Foundation

enum StudioAgeGateProfile {
    static let appName = "Stocked"
    static let minimumAge = 13
    static let email = "support@sowensstudios.com"
    static let termsURL = "https://sowensstudios.com/terms/"
    static let privacyURL = "https://sowensstudios.com/privacy/"
}

extension View {
    /// Presents the age confirmation until the user confirms the minimum age.
    func studioAgeGate() -> some View { modifier(StudioAgeGate()) }
}

struct StudioAgeGate: ViewModifier {
    @AppStorage("studio.age.confirmed.v1") private var confirmedAge = 0
    @AppStorage("studio.age.blocked.v1") private var blocked = false

    private var bypass: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil || env["STUDIO_SKIP_AGE_GATE"] == "1"
            || ProcessInfo.processInfo.arguments.contains("-StudioSkipAgeGate")
    }
    private var needsGate: Bool { !bypass && (blocked || confirmedAge < StudioAgeGateProfile.minimumAge) }

    func body(content: Content) -> some View {
        #if os(macOS)
        content.sheet(isPresented: .constant(needsGate)) {
            gate.frame(minWidth: 460, minHeight: 420).interactiveDismissDisabled()
        }
        #else
        content.fullScreenCover(isPresented: .constant(needsGate)) { gate }
        #endif
    }

    private var gate: some View {
        let n = StudioAgeGateProfile.minimumAge
        let name = StudioAgeGateProfile.appName
        return VStack(spacing: 20) {
            Spacer(minLength: 0)
            Image(systemName: "person.badge.shield.checkmark").font(.system(size: 52)).accessibilityHidden(true)
            Text(blocked ? "Not available" : "Before you start").font(.title.bold()).multilineTextAlignment(.center)
            if blocked {
                Text("\(name) is for people \(n) or older, so we can’t continue. A parent or guardian can contact \(StudioAgeGateProfile.email) to ask us to delete any information.")
                    .multilineTextAlignment(.center)
            } else {
                Text("\(name) is for people \(n) or older. Please tell us which applies to you. We don’t ask for or store your birth date.")
                    .multilineTextAlignment(.center)
                VStack(spacing: 12) {
                    Button { confirmedAge = n; blocked = false } label: {
                        Text("I am \(n) or older").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    Button { blocked = true } label: {
                        Text("I am under \(n)").frame(maxWidth: .infinity, minHeight: 44)
                    }.buttonStyle(.bordered)
                }
                Text("By continuing you agree to the [Terms](\(StudioAgeGateProfile.termsURL)) and acknowledge the [Privacy Policy](\(StudioAgeGateProfile.privacyURL)).")
                    .font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(28)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
