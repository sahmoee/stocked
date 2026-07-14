// Log.swift
// Lightweight, privacy-safe logging built on Apple's unified logging (os.Logger).
// No third-party dependencies, no PII captured — message strings are static/templated
// and dynamic values default to the private redaction os.Logger applies automatically.
//
// Usage:
//   Log.data.error("Failed to decode inventory: \(error.localizedDescription, privacy: .public)")
//   Log.net.notice("Recipe fetch returned \(count) results")
//   Log.app.debug("Entered cook flow")
//
// View logs in Console.app (filter by subsystem) or `log stream --predicate
// 'subsystem == "com.sowens.Stocked"'` while a device/sim is attached.

import Foundation
import os

enum Log {
    nonisolated private static let subsystem = Bundle.main.bundleIdentifier ?? "com.sowens.Stocked"

    /// Persistence: save/load/migrate, dedup, low-stock sync.
    nonisolated static let data = Logger(subsystem: subsystem, category: "data")
    /// Networking: recipe/image/nutrition API calls and their failures.
    nonisolated static let net = Logger(subsystem: subsystem, category: "network")
    /// General app lifecycle, navigation, feature flows.
    nonisolated static let app = Logger(subsystem: subsystem, category: "app")
    /// Backup / restore / kitchen transfer.
    nonisolated static let transfer = Logger(subsystem: subsystem, category: "transfer")
}
