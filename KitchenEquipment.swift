// KitchenEquipment.swift
// ─────────────────────────────────────────────────────────────────
// The Kitchen Equipment Profile and its availability state.
//
// OWNERSHIP already exists: UserCookingProfile.cookingEquipment is a [String]
// of labels the user picks in onboarding ("Instant Pot", "Air Fryer",
// "Grill / BBQ", …). This file does NOT duplicate that — it maps those labels
// to a typed enum and layers a SESSION-SCOPED availability state on top, so the
// app can honor "I own an Instant Pot but it's dirty right now" without ever
// mutating the permanent profile.
//
//   Owned            → from the profile (permanent)
//   Availability     → per-session ("available" / "dirty" / "in use" / …)
//
// The availability service holds today's states in memory (and a light
// snapshot) so recommendations can recalculate the moment the user marks a
// device unavailable. Marking availability is never a purchase/ownership edit.
// ─────────────────────────────────────────────────────────────────

import Foundation

// MARK: - Equipment type

/// Canonical kitchen equipment. `rawValue` matches the profile label strings
/// exactly so we can round-trip with UserCookingProfile.cookingEquipment
/// without a migration.
nonisolated enum KitchenEquipment: String, Codable, Sendable, CaseIterable, Identifiable {
    case stovetop        = "Stovetop"
    case oven            = "Oven"
    case microwave       = "Microwave"
    case airFryer        = "Air Fryer"
    case slowCooker      = "Slow Cooker"
    case instantPot      = "Instant Pot"
    case grill           = "Grill / BBQ"
    case blender         = "Blender"
    case foodProcessor   = "Food Processor"
    case toasterOven     = "Toaster Oven"
    // Extended set the workspace understands even if onboarding doesn't list them.
    case castIron        = "Cast-Iron Skillet"
    case dutchOven       = "Dutch Oven"
    case riceCooker      = "Rice Cooker"
    case standMixer      = "Stand Mixer"

    var id: String { rawValue }

    var emoji: String {
        switch self {
        case .stovetop:      return "🍳"
        case .oven:          return "🔥"
        case .microwave:     return "🔌"
        case .airFryer:      return "💨"
        case .slowCooker:    return "🫕"
        case .instantPot:    return "🫙"
        case .grill:         return "♨️"
        case .blender:       return "🥗"
        case .foodProcessor: return "🍹"
        case .toasterOven:   return "🎛️"
        case .castIron:      return "🍳"
        case .dutchOven:     return "🍲"
        case .riceCooker:    return "🍚"
        case .standMixer:    return "🎚️"
        }
    }

    /// Best-effort parse of a stored profile label (tolerant of minor variants).
    static func from(label: String) -> KitchenEquipment? {
        let t = label.lowercased().trimmingCharacters(in: .whitespaces)
        if let exact = allCases.first(where: { $0.rawValue.lowercased() == t }) { return exact }
        // Tolerant aliases.
        switch t {
        case "grill", "bbq", "grill/bbq":            return .grill
        case "pressure cooker", "instapot":          return .instantPot
        case "cast iron", "cast-iron", "skillet":    return .castIron
        case "toaster oven", "toaster":              return .toasterOven
        default:                                     return nil
        }
    }
}

// MARK: - Availability state (session-scoped)

/// Whether a device can be used right now. Owning it does not mean it's ready.
nonisolated enum EquipmentAvailability: String, Codable, Sendable, CaseIterable {
    case available
    case dirty
    case inUse
    case missingComponent
    case broken
    case storedAway
    case unavailable
    case notToday         // user simply doesn't want to use it today

    var isUsable: Bool { self == .available }

    var label: String {
        switch self {
        case .available:        return "Ready"
        case .dirty:            return "Needs cleaning"
        case .inUse:            return "In use"
        case .missingComponent: return "Missing a part"
        case .broken:           return "Broken"
        case .storedAway:       return "Stored away"
        case .unavailable:      return "Unavailable"
        case .notToday:         return "Not today"
        }
    }
    var icon: String {
        switch self {
        case .available:        return "checkmark.circle.fill"
        case .dirty:            return "drop.circle"
        case .inUse:            return "hourglass"
        case .missingComponent: return "puzzlepiece"
        case .broken:           return "wrench.and.screwdriver"
        case .storedAway:       return "archivebox"
        case .unavailable:      return "xmark.circle"
        case .notToday:         return "moon.zzz"
        }
    }
}

// MARK: - Availability service

/// Holds this session's equipment availability. Ownership is read from the
/// profile; availability defaults to `.available` for owned devices and is
/// overridden per session. Snapshot is light and resets daily by design.
@MainActor
@Observable
final class EquipmentAvailabilityService {

    private static let storageKey = "equipmentAvailability_v1"
    private static let dayKey = "equipmentAvailabilityDay_v1"

    /// Overrides keyed by equipment rawValue. Absent = `.available` (if owned).
    private(set) var overrides: [String: EquipmentAvailability] = [:]

    init() { loadIfToday() }

    /// Owned equipment, typed, from the profile labels.
    func owned(from profile: UserCookingProfile) -> [KitchenEquipment] {
        var out: [KitchenEquipment] = []
        for label in profile.cookingEquipment {
            if let eq = KitchenEquipment.from(label: label), !out.contains(eq) { out.append(eq) }
        }
        return out
    }

    func availability(of eq: KitchenEquipment) -> EquipmentAvailability {
        overrides[eq.rawValue] ?? .available
    }

    func isUsable(_ eq: KitchenEquipment, profile: UserCookingProfile) -> Bool {
        owned(from: profile).contains(eq) && availability(of: eq).isUsable
    }

    func setAvailability(_ state: EquipmentAvailability, for eq: KitchenEquipment) {
        if state == .available { overrides.removeValue(forKey: eq.rawValue) }
        else { overrides[eq.rawValue] = state }
        persist()
    }

    /// Usable owned equipment right now.
    func usableEquipment(profile: UserCookingProfile) -> [KitchenEquipment] {
        owned(from: profile).filter { availability(of: $0).isUsable }
    }

    // MARK: Persistence (day-scoped)

    private func todayStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    private func persist() {
        UserDefaults.standard.set(todayStamp(), forKey: Self.dayKey)
        if let data = try? JSONEncoder().encode(overrides) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    /// Availability is a "today" concept — a device marked dirty yesterday
    /// shouldn't stay dirty forever. Clear on a new day.
    private func loadIfToday() {
        guard UserDefaults.standard.string(forKey: Self.dayKey) == todayStamp(),
              let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([String: EquipmentAvailability].self, from: data)
        else {
            overrides = [:]
            return
        }
        overrides = decoded
    }
}
