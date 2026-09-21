// AppleOnDeviceAI.swift
// Thin wrapper around Apple's on-device Foundation Models framework (Apple
// Intelligence, iOS 26+, eligible hardware only). Everything here runs entirely
// on-device: no network call, no Cloudflare Worker, no Anthropic cost, and it
// keeps working when the Worker is unreachable, misconfigured, or erroring (the
// exact failure mode AI Inventory Scan hit — see stocked-receipt-worker/CHANGES
// for that fix).
//
// This is deliberately a FALLBACK, not a replacement: the cloud Worker runs a
// larger model with fuller world knowledge and stays the primary path. On-device
// only steps in per-chunk, when the Worker attempt for that chunk already failed
// (see AIInventoryScan.scan). Availability is never assumed — every entry point
// checks SystemLanguageModel.default.availability first and reports "unavailable"
// (never crashes) on devices/OS versions/Settings states without Apple Intelligence.
//
// Every public member exists unconditionally (even in a build config where the
// FoundationModels SDK module itself isn't importable) so call sites never need
// their own #if canImport — they just get a permanently-"unavailable" stub there.
import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

enum AppleOnDeviceAI {
    /// True only when Apple Intelligence's on-device model is present, enabled by
    /// the user, and finished downloading — i.e. a request right now would actually
    /// run rather than throw.
    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return true
        default: return false
        }
        #else
        return false
        #endif
    }

    /// Short, user-facing reason on-device AI can't run right now (nil when it can).
    /// Used for Settings/diagnostics copy, not for gating — callers should still
    /// check `isAvailable` before calling into a generation method.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to use on-device AI."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence's on-device model is still downloading."
        case .unavailable:
            return "On-device AI isn't available on this device right now."
        }
        #else
        return "This build doesn't include on-device AI."
        #endif
    }

    /// Scans one chunk of inventory items on-device and returns typed updates ready
    /// to merge into the same review list the cloud path produces. Throws a
    /// `StockedServiceError` on any failure (unavailable model, guardrail, timeout);
    /// callers should catch and fall back to reporting the ORIGINAL cloud error, since
    /// this is itself a fallback path — see `AIInventoryScan.scan`.
    static func scanInventory(items: [LocalInventoryItem], corrections: [String]) async throws -> [InventoryScanUpdate] {
        #if canImport(FoundationModels)
        return try await FoundationModelsInventoryScan.run(items: items, corrections: corrections)
        #else
        throw StockedServiceError.notConfigured(unavailableReason ?? "On-device AI is unavailable.")
        #endif
    }

    /// Cleans retailer/receipt wording before nutrition and aisle matching. The
    /// returned values are advisory lookup keys; user-visible names are untouched.
    static func normalizeFoodNames(_ names: [String]) async -> [String: String] {
        #if canImport(FoundationModels)
        guard isAvailable else { return [:] }
        return (try? await FoundationModelsFoodNames.run(names)) ?? [:]
        #else
        return [:]
        #endif
    }
}

#if canImport(FoundationModels)
/// Everything that actually touches the FoundationModels SDK lives in this private
/// enum, isolated from `AppleOnDeviceAI`'s always-present public surface above.
private enum FoundationModelsInventoryScan {
    /// One item as handed to the on-device model — deliberately smaller/flatter than
    /// the cloud payload (no brand/quantity chatter) since the on-device context
    /// window is tighter than the cloud model's.
    @Generable
    struct ScanItemUpdate {
        @Guide(description: "The exact id string of the inventory item, copied verbatim from the input list. Never invent an id.")
        var id: String
        @Guide(description: "A corrected, cleaned-up item name (fix misspellings/garbled receipt text), or the exact current name if it's already fine.")
        var newName: String
        @Guide(description: "One of exactly: Fridge, Freezer, Pantry, Staples — the correct storage zone. Dried spices and shelf-stable flavored snacks are Staples/Pantry, never Fridge, no matter what the name contains. Repeat the current zone if it is already correct.")
        var newZone: String
        @Guide(description: "true only if a genuinely useful change is being proposed for this item; false if it's already fine and should be skipped.")
        var hasChange: Bool
        @Guide(description: "Estimated calories per serving, only if nutrition is missing and hasChange is true; 0 otherwise.")
        var calories: Int
        @Guide(description: "Estimated grams of protein per serving, only if nutrition is missing and hasChange is true; 0 otherwise.")
        var protein: Double
        @Guide(description: "A short serving size like '1 cup', only if calories/protein were estimated; empty string otherwise.")
        var servingSize: String
        @Guide(description: "Estimated typical shelf life in days from today (1-730), only if the item has no expiry date and hasChange is true; 0 otherwise.", .range(0...730))
        var expiryDays: Int
        @Guide(description: "A short reason for the change, empty string if hasChange is false.")
        var reason: String
    }

    @Generable
    struct ScanResult {
        @Guide(description: "One entry per inventory item passed in, in the same order. Set hasChange to false for items that are already fine — do not omit them.")
        var updates: [ScanItemUpdate]
    }

    static let instructions = """
    You tidy up a home kitchen inventory. You're given a list of items, each with an \
    id, name, and storage zone. For each item, decide whether it needs a genuinely \
    helpful cleanup: a corrected/normalized name, a corrected storage zone, or — only \
    when told nutrition/expiry is missing — a rough nutrition or shelf-life estimate.

    Be careful with food identity. Dried seasonings and spices (cayenne pepper, lemon \
    pepper, black pepper, chili powder, garlic powder, onion powder, paprika) are \
    Staples, never Fridge, even though the name contains a produce word. Flavored or \
    named snacks (cheddar chips, sour cream and onion chips, cheese crackers, ranch \
    crackers) stay Pantry, never Fridge or treated as dairy. Only choose Fridge or \
    Freezer when the item is truly fresh, chilled, or frozen. When unsure, leave the \
    zone unchanged. Do not invent items and do not propose deletions.
    """

    static func run(items: [LocalInventoryItem], corrections: [String]) async throws -> [InventoryScanUpdate] {
        guard AppleOnDeviceAI.isAvailable else {
            throw StockedServiceError.notConfigured(AppleOnDeviceAI.unavailableReason ?? "On-device AI is unavailable.")
        }
        guard !items.isEmpty else { return [] }

        let rows = items.map { item -> String in
            let flags = [item.nutrition != nil ? "hasNutrition" : nil, item.expirationDate != nil ? "hasExpiry" : nil]
                .compactMap { $0 }.joined(separator: ",")
            return "- id=\(item.id.uuidString) name=\(item.name) zone=\(item.zone)" + (flags.isEmpty ? "" : " (\(flags))")
        }.joined(separator: "\n")
        let correctionsNote = corrections.isEmpty ? "" : "\nKnown name corrections: \(corrections.joined(separator: "; "))"

        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: "Inventory to review:\n\(rows)\(correctionsNote)",
                generating: ScanResult.self
            )
            return mapScanResult(response.content, items: items)
        } catch {
            throw mapError(error)
        }
    }

    /// Mirrors `AIInventoryScanner.decode`'s safety rules (zone-change confirmation via
    /// `ZoneDecisionEngine`, never touching nutrition/expiry that already exists) so an
    /// on-device result is exactly as safe to auto-apply as a cloud one.
    private static func mapScanResult(_ result: ScanResult, items: [LocalInventoryItem]) -> [InventoryScanUpdate] {
        let byID = Dictionary(keepingLastValues: items.map { ($0.id, $0) })
        return result.updates.compactMap { u -> InventoryScanUpdate? in
            guard u.hasChange, let itemID = UUID(uuidString: u.id), let item = byID[itemID] else { return nil }

            var newName: String? = u.newName.trimmingCharacters(in: .whitespacesAndNewlines)
            if newName?.isEmpty == true || newName?.caseInsensitiveCompare(item.name) == .orderedSame { newName = nil }

            var newZone: StorageCategory? = nil
            if let cat = StorageCategory(rawValue: u.newZone), cat.rawValue != item.zone {
                let decision = ZoneDecisionEngine.decide(name: item.name, current: item.storageCategory, aiZone: cat)
                newZone = (decision.needsConfirmation || decision.zone == item.storageCategory) ? nil : decision.zone
            }

            var calories: Int? = nil
            var protein: Double? = nil
            var servingSize: String? = nil
            if item.nutrition == nil, u.calories > 0 {
                calories = u.calories
                protein = u.protein > 0 ? u.protein : nil
                let s = u.servingSize.trimmingCharacters(in: .whitespaces)
                servingSize = s.isEmpty ? nil : s
            }

            var expiryDays: Int? = nil
            if item.expirationDate == nil, u.expiryDays > 0, u.expiryDays <= 730 {
                expiryDays = u.expiryDays
            }

            guard newName != nil || newZone != nil || calories != nil || expiryDays != nil else { return nil }

            return InventoryScanUpdate(
                itemID: itemID, currentName: item.name, newName: newName,
                currentZone: item.zone, newZone: newZone,
                calories: calories, protein: protein, servingSize: servingSize,
                expiryDays: expiryDays,
                reason: u.reason.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
    }

    /// Maps a Foundation Models failure onto the app's shared `StockedServiceError`
    /// vocabulary so an on-device failure surfaces through the exact same UI paths as
    /// a Worker failure — callers don't need a second error type.
    private static func mapError(_ error: Error) -> StockedServiceError {
        if let genError = error as? LanguageModelSession.GenerationError {
            switch genError {
            case .guardrailViolation:
                return .invalidRequest("On-device AI declined this request (safety guardrail).")
            case .exceededContextWindowSize:
                return .invalidRequest("Too much inventory for one on-device pass.")
            case .unsupportedLanguageOrLocale:
                return .invalidRequest("On-device AI doesn't support this language yet.")
            case .assetsUnavailable:
                return .notConfigured("Apple Intelligence's model assets aren't available yet.")
            default:
                return .transport("On-device AI error: \(error.localizedDescription)")
            }
        }
        return .transport(error.localizedDescription)
    }
}

private enum FoundationModelsFoodNames {
    @Generable struct FoodName {
        @Guide(description: "Exact original input string") var original: String
        @Guide(description: "Short food identity retaining a meaningful brand, with receipt codes, prices, sizes and aisle numbers removed") var normalized: String
    }
    @Generable struct Result { var foods: [FoodName] }

    static func run(_ names: [String]) async throws -> [String: String] {
        let bounded = Array(names.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.prefix(30))
        guard !bounded.isEmpty else { return [:] }
        let session = LanguageModelSession(instructions: "Normalize grocery food names for catalog matching. Never invent a different product and never include non-food goods.")
        let response = try await session.respond(to: bounded.map { "- \($0)" }.joined(separator: "\n"), generating: Result.self)
        return Dictionary(keepingLastValues: response.content.foods.compactMap {
            let clean = $0.normalized.trimmingCharacters(in: .whitespacesAndNewlines)
            return clean.isEmpty ? nil : ($0.original, clean)
        })
    }
}
#endif
