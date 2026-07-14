// BuildConfigurationGuard.swift
// Non-mutating diagnostics for build-setting/Info.plist drift. Version values remain owned by Xcode.
import Foundation
import os

nonisolated enum BuildConfigurationGuard {
    nonisolated enum Issue: Equatable, Sendable, CustomStringConvertible {
        case unresolved(String)
        case missing(String)
        case wrongSwiftLanguageMode

        var description: String {
            switch self {
            case .unresolved(let key): return "\(key) still contains an unresolved build-setting placeholder"
            case .missing(let key): return "\(key) is missing from the built Info.plist"
            case .wrongSwiftLanguageMode: return "Stocked must compile in Swift 6 language mode"
            }
        }
    }

    static func audit(info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> [Issue] {
        var issues: [Issue] = []
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            guard let value = info[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                issues.append(.missing(key)); continue
            }
            if value.contains("$(") { issues.append(.unresolved(key)) }
        }
        #if swift(>=6.0)
        #else
        issues.append(.wrongSwiftLanguageMode)
        #endif
        return issues
    }

    static func logIssues() {
        for issue in audit() {
            Log.app.error("Build configuration: \(issue.description, privacy: .public)")
        }
    }
}
