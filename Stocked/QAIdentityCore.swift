import Foundation

nonisolated enum QATester: String, CaseIterable, Identifiable, Sendable {
    case unassigned, key, shalise
    var id: String { rawValue }
    var name: String {
        switch self { case .unassigned: "Not selected"; case .key: "Key"; case .shalise: "Shalise" }
    }
}

/// A capture-time snapshot, not a reference to whichever device later edits a ticket.
/// Optional on legacy ticket/run records; old reports are NEVER attributed by guessing.
nonisolated struct QAReportIdentity: Codable, Equatable, Sendable {
    var testerID: String?
    var testerName: String?
    var deviceFamily: String
    var deviceModel: String
    var modelIdentifier: String
    var installationID: String
    var isSimulator: Bool

    var testerLabel: String { testerName ?? "Unassigned tester" }
    var label: String { "\(testerLabel) · \(deviceModel)" + (isSimulator ? " · Simulator" : "") }
    var deviceLabel: String {
        deviceModel + (installationID.isEmpty ? "" : " · " + installationID.prefix(8))
    }
    func assigning(_ tester: QATester) -> Self {
        var value = self
        value.testerID = tester == .unassigned ? nil : tester.rawValue
        value.testerName = tester == .unassigned ? nil : tester.name
        return value
    }
    static func legacy(device: String) -> Self {
        Self(deviceFamily: QADeviceModels.family(identifier: device, fallback: "Unknown"),
             deviceModel: device.isEmpty ? "Unknown device" : device,
             modelIdentifier: "", installationID: "", isSimulator: false)
    }
    static func sameOrigin(_ lhs: Self?, _ rhs: Self?) -> Bool {
        guard let lhs, let rhs, !lhs.installationID.isEmpty, !rhs.installationID.isEmpty else { return false }
        return lhs.installationID == rhs.installationID && lhs.testerID == rhs.testerID
    }
    static func ticketNumber(build: Int, sequence: Int, installationID: String) -> String {
        let suffix = installationID.replacingOccurrences(of: "-", with: "").prefix(16).uppercased()
        return String(format: "STK-%d-%04d", build, sequence) + "-" + suffix
    }
    var dictionary: [String: Any] {
        var value: [String: Any] = ["deviceFamily": deviceFamily, "deviceModel": deviceModel,
            "modelIdentifier": modelIdentifier, "installationID": installationID, "isSimulator": isSimulator]
        if let testerID { value["testerID"] = testerID }
        if let testerName { value["testerName"] = testerName }
        return value
    }
    static func decode(_ value: Any?) -> Self? {
        guard let value, JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}

nonisolated enum QATicketLifecycle {
    static func shouldReopen(status: String, manualReview: Bool, automatic: Bool,
                             sameOrigin: Bool, sameCheck: Bool) -> Bool {
        automatic && sameOrigin && sameCheck && status != "wontFix"
            && !needsAttention(status: status, manualReview: manualReview)
    }
    static func completedCheck(verdict: String, status: String, manualReview: Bool) -> Bool {
        ["fail", "blocked"].contains(verdict) && ["fixed", "verified"].contains(status)
            && !needsAttention(status: status, manualReview: manualReview)
    }
    static func needsAttention(status: String, manualReview: Bool) -> Bool {
        switch status {
        case "verified", "wontFix": false
        case "fixed": manualReview
        default: true
        }
    }
}

/// Hardware facts verified against DeviceKit's device identifier table on 2026-09-03.
/// https://github.com/devicekit/DeviceKit/blob/master/Source/Device.generated.swift
/// No library dependency, device-name entitlement, serial number or screen-size guess.
nonisolated enum QADeviceModels {
    static func family(identifier: String, fallback: String) -> String {
        if identifier.hasPrefix("iPhone") { return "iPhone" }
        if identifier.hasPrefix("iPad") { return "iPad" }
        if identifier.hasPrefix("iPod") { return "iPod" }
        return fallback
    }
    static func name(identifier: String, fallback: String) -> String {
        names[identifier] ?? "\(family(identifier: identifier, fallback: fallback)) (\(identifier.isEmpty ? "model unavailable" : identifier))"
    }
    private static let groups: [(String, [String])] = [
        ("iPhone 11", ["iPhone12,1"]), ("iPhone 11 Pro", ["iPhone12,3"]), ("iPhone 11 Pro Max", ["iPhone12,5"]),
        ("iPhone SE (2nd generation)", ["iPhone12,8"]), ("iPhone SE (3rd generation)", ["iPhone14,6"]),
        ("iPhone 12", ["iPhone13,2"]), ("iPhone 12 mini", ["iPhone13,1"]),
        ("iPhone 12 Pro", ["iPhone13,3"]), ("iPhone 12 Pro Max", ["iPhone13,4"]),
        ("iPhone 13", ["iPhone14,5"]), ("iPhone 13 mini", ["iPhone14,4"]),
        ("iPhone 13 Pro", ["iPhone14,2"]), ("iPhone 13 Pro Max", ["iPhone14,3"]),
        ("iPhone 14", ["iPhone14,7"]), ("iPhone 14 Plus", ["iPhone14,8"]),
        ("iPhone 14 Pro", ["iPhone15,2"]), ("iPhone 14 Pro Max", ["iPhone15,3"]),
        ("iPhone 15", ["iPhone15,4"]), ("iPhone 15 Plus", ["iPhone15,5"]),
        ("iPhone 15 Pro", ["iPhone16,1"]), ("iPhone 15 Pro Max", ["iPhone16,2"]),
        ("iPhone 16", ["iPhone17,3"]), ("iPhone 16 Plus", ["iPhone17,4"]),
        ("iPhone 16 Pro", ["iPhone17,1"]), ("iPhone 16 Pro Max", ["iPhone17,2"]), ("iPhone 16e", ["iPhone17,5"]),
        ("iPhone 17", ["iPhone18,3"]), ("iPhone 17 Pro", ["iPhone18,1"]),
        ("iPhone 17 Pro Max", ["iPhone18,2"]), ("iPhone Air", ["iPhone18,4"]), ("iPhone 17e", ["iPhone18,5"]),
        ("iPad (8th generation)", ["iPad11,6", "iPad11,7"]), ("iPad (9th generation)", ["iPad12,1", "iPad12,2"]),
        ("iPad (10th generation)", ["iPad13,18", "iPad13,19"]), ("iPad (A16)", ["iPad15,7", "iPad15,8"]),
        ("iPad Air (3rd generation)", ["iPad11,3", "iPad11,4"]), ("iPad Air (4th generation)", ["iPad13,1", "iPad13,2"]),
        ("iPad Air (5th generation)", ["iPad13,16", "iPad13,17"]),
        ("iPad Air 11-inch (M2)", ["iPad14,8", "iPad14,9"]), ("iPad Air 13-inch (M2)", ["iPad14,10", "iPad14,11"]),
        ("iPad Air 11-inch (M3)", ["iPad15,3", "iPad15,4"]), ("iPad Air 13-inch (M3)", ["iPad15,5", "iPad15,6"]),
        ("iPad Air 11-inch (M4)", ["iPad16,8", "iPad16,9"]), ("iPad Air 13-inch (M4)", ["iPad16,10", "iPad16,11"]),
        ("iPad mini (5th generation)", ["iPad11,1", "iPad11,2"]), ("iPad mini (6th generation)", ["iPad14,1", "iPad14,2"]),
        ("iPad mini (A17 Pro)", ["iPad16,1", "iPad16,2"]),
        ("iPad Pro 11-inch (1st generation)", ["iPad8,1", "iPad8,2", "iPad8,3", "iPad8,4"]),
        ("iPad Pro 12.9-inch (3rd generation)", ["iPad8,5", "iPad8,6", "iPad8,7", "iPad8,8"]),
        ("iPad Pro 11-inch (2nd generation)", ["iPad8,9", "iPad8,10"]),
        ("iPad Pro 12.9-inch (4th generation)", ["iPad8,11", "iPad8,12"]),
        ("iPad Pro 11-inch (M1)", ["iPad13,4", "iPad13,5", "iPad13,6", "iPad13,7"]),
        ("iPad Pro 12.9-inch (M1)", ["iPad13,8", "iPad13,9", "iPad13,10", "iPad13,11"]),
        ("iPad Pro 11-inch (M2)", ["iPad14,3", "iPad14,4"]), ("iPad Pro 12.9-inch (M2)", ["iPad14,5", "iPad14,6"]),
        ("iPad Pro 11-inch (M4)", ["iPad16,3", "iPad16,4"]), ("iPad Pro 13-inch (M4)", ["iPad16,5", "iPad16,6"]),
        ("iPad Pro 11-inch (M5)", ["iPad17,1", "iPad17,2"]), ("iPad Pro 13-inch (M5)", ["iPad17,3", "iPad17,4"]),
    ]
    private static let names = Dictionary(uniqueKeysWithValues: groups.flatMap { name, ids in ids.map { ($0, name) } })
}
