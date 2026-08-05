//
//  AppleOnDeviceIntent.swift
//  Stocked
//
//  On-device natural-language inventory editing, via Apple's Foundation Models
//  framework (Apple Intelligence, iOS 26+, eligible hardware).
//
//  ─────────────────────────────────────────────────────────────────────────
//  Why this feature, and why on-device FIRST rather than as a fallback
//  ─────────────────────────────────────────────────────────────────────────
//  `inventoryIntent` is the one AI route in Stocked where the cloud is the
//  wrong default:
//
//   • It ships the ENTIRE inventory to the Worker on every utterance
//     (InventoryChangeProposal.swift:201 sends id/name/qty/level/zone for every
//     item — tens of KB for a stocked kitchen) purely so the model can resolve
//     "the beans" to an item id. The device already has that list.
//   • The task needs no world knowledge. It is a mapping from one short phrase
//     onto a closed set of items the user owns — exactly what a small local
//     model is good at, and exactly what a large model is wasted on.
//   • It is the most latency-visible AI in the app. The user says "used two
//     cans of beans" and waits. 300ms local beats 2s round trip every time.
//   • It works on a plane, in a basement, and in a shop with no signal — which
//     is where people actually update a pantry.
//   • Grocery habits are personal. Not sending them anywhere is a feature.
//
//  So the policy here is inverted from AIInventoryScan.swift: try on-device
//  first, fall back to the Worker. The existing regex path
//  (`InventoryIntentParser.localFallback`) stays as the last resort for devices
//  without Apple Intelligence.
//
//  ─────────────────────────────────────────────────────────────────────────
//  Shape of this file
//  ─────────────────────────────────────────────────────────────────────────
//  Deliberately self-contained: it depends on Foundation and FoundationModels
//  and nothing else in the app. It returns its own value types, and the
//  "Wiring" section at the bottom shows the exact adapter into
//  InventoryChangeProposal.swift. That means this file compiles the moment it
//  is dropped into Stocked/, before any integration work, and a compile error
//  here can never be a mismatch with a type that moved.
//
//  Availability is checked at runtime, never assumed: Apple Intelligence needs
//  an eligible device (A17 Pro / M-series), the feature enabled in Settings,
//  and the model downloaded. `isAvailable` is safe to call anywhere.
//
//  NOT COMPILED HERE — written against Apple's published Foundation Models API
//  and matched to the conventions already proven in AppleOnDeviceAI.swift.
//  Build in Xcode and run the on-device test in the Verification note at the
//  bottom before shipping.
//

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Public value types

/// One proposed edit to the inventory. Intentionally *not* Stocked's
/// `ProposedChange` — see "Wiring" below for the one-function adapter.
struct OnDeviceInventoryEdit: Sendable, Equatable {
    enum Action: String, Sendable {
        case consume          // used some of it
        case restock          // bought / added more
        case setQuantity      // "I have three left"
        case markOut          // finished it
        case addItem          // something not in the inventory yet
    }

    /// The inventory item id this edit refers to, or nil for `.addItem`.
    let itemID: String?
    /// The item name as the user said it — kept for `.addItem` and for display.
    let itemName: String
    let action: Action
    /// Amount, when the phrasing implied one ("two cans" -> 2). nil = unspecified.
    let amount: Double?
    /// 0...1. Anything the model was unsure about should be surfaced for review,
    /// never auto-applied.
    let confidence: Double
}

/// A minimal projection of an inventory item — the only thing this file needs
/// to know about Stocked's model layer.
struct OnDeviceInventorySnapshotItem: Sendable {
    let id: String
    let name: String
    let quantity: Double?
    let unit: String?
    let zone: String?

    init(id: String, name: String, quantity: Double? = nil, unit: String? = nil, zone: String? = nil) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unit = unit
        self.zone = zone
    }
}

enum OnDeviceIntentError: LocalizedError {
    case unavailable(String)
    case emptyInput
    case contextTooLarge
    case guardrail
    case unsupportedLanguage
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why
        case .emptyInput: return "Nothing to interpret."
        case .contextTooLarge: return "That inventory is too large for the on-device model."
        case .guardrail: return "The on-device model declined that request."
        case .unsupportedLanguage: return "Apple Intelligence doesn't support that language yet."
        case .failed(let message): return message
        }
    }
}

// MARK: - Entry point

enum AppleOnDeviceIntent {

    private static let log = Logger(subsystem: "com.sowens.Stocked", category: "OnDeviceIntent")

    /// Safe to call on any device, any OS, any build configuration.
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

    /// User-presentable reason, or nil when it *is* available. Use it to explain
    /// why the fast local path isn't being taken — never to block the feature,
    /// which still has the Worker and the regex parser behind it.
    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence in Settings to edit your pantry offline."
        case .unavailable(.modelNotReady):
            return "Apple Intelligence is still downloading its model."
        case .unavailable:
            return "Apple Intelligence isn't available right now."
        }
        #else
        return "This build wasn't compiled with Apple Intelligence support."
        #endif
    }

    /// Interpret one utterance against the current inventory, entirely on-device.
    ///
    /// - Parameters:
    ///   - utterance: what the user typed or said, e.g. "used two cans of beans
    ///     and we're out of oat milk".
    ///   - inventory: the current items. Pass everything; this method trims to
    ///     the most plausible candidates itself (see `narrow`).
    /// - Returns: proposed edits, for the SAME review-and-apply UI the cloud
    ///   path feeds. Nothing here is auto-applied.
    static func parse(
        utterance: String,
        inventory: [OnDeviceInventorySnapshotItem]
    ) async throws -> [OnDeviceInventoryEdit] {
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw OnDeviceIntentError.emptyInput }
        guard isAvailable else {
            throw OnDeviceIntentError.unavailable(unavailableReason ?? "Apple Intelligence is unavailable.")
        }

        #if canImport(FoundationModels)
        let candidates = narrow(inventory, for: trimmed)
        log.debug("on-device intent: \(candidates.count, privacy: .public) candidates of \(inventory.count, privacy: .public)")
        return try await FoundationModelsIntent.run(utterance: trimmed, candidates: candidates)
        #else
        throw OnDeviceIntentError.unavailable("Apple Intelligence isn't available in this build.")
        #endif
    }

    // MARK: Candidate narrowing

    /// The on-device context window is a fraction of the cloud model's, so the
    /// whole inventory can't go in the prompt for a large pantry. Rather than
    /// truncating arbitrarily, score items by lexical overlap with the utterance
    /// and keep the best ones — a plain, debuggable heuristic that runs in
    /// microseconds and puts the item the user is talking about in the prompt
    /// far more reliably than "the first 60 items" would.
    ///
    /// Deliberately generous: recall matters much more than precision here,
    /// because a missed candidate is a wrong answer while an extra candidate is
    /// just a few tokens.
    static func narrow(
        _ inventory: [OnDeviceInventorySnapshotItem],
        for utterance: String,
        limit: Int = 60
    ) -> [OnDeviceInventorySnapshotItem] {
        guard inventory.count > limit else { return inventory }

        let words = Set(
            utterance.lowercased()
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .filter { $0.count > 2 }
                .map(String.init)
        )
        guard !words.isEmpty else { return Array(inventory.prefix(limit)) }

        func score(_ item: OnDeviceInventorySnapshotItem) -> Int {
            let name = item.name.lowercased()
            var total = 0
            for word in words {
                if name == word { total += 6 }
                else if name.contains(word) { total += 3 }
                // Cheap stem tolerance: "beans" should still match "bean".
                else if word.count > 4, name.contains(word.dropLast()) { total += 2 }
            }
            return total
        }

        let scored = inventory.map { (item: $0, score: score($0)) }
        let hits = scored.filter { $0.score > 0 }.sorted { $0.score > $1.score }
        if hits.count >= limit { return hits.prefix(limit).map(\.item) }

        // Pad with the rest so a phrase with no lexical overlap ("finished the
        // last of it") still has something to resolve against.
        let hitIDs = Set(hits.map(\.item.id))
        let filler = inventory.filter { !hitIDs.contains($0.id) }.prefix(limit - hits.count)
        return hits.map(\.item) + filler
    }
}

// MARK: - Foundation Models

#if canImport(FoundationModels)

private enum FoundationModelsIntent {

    @Generable
    struct Edit {
        @Guide(description: "The id of the matching inventory item, copied exactly from the CANDIDATES list. Use an empty string only when the user is adding something that is not in the list.")
        var itemID: String

        @Guide(description: "The item name in plain words, as the user referred to it.")
        var itemName: String

        @Guide(description: "One of: consume, restock, setQuantity, markOut, addItem.")
        var action: String

        @Guide(description: "How many units the user mentioned. Use 0 when they did not say a number.", .range(0...999))
        var amount: Double

        @Guide(description: "How confident you are that this is what the user meant, from 0 to 100.", .range(0...100))
        var confidence: Int
    }

    @Generable
    struct Result {
        @Guide(description: "One entry per distinct change the user described. Empty if the message is not about changing inventory.")
        var edits: [Edit]
    }

    static let instructions = """
    You turn short spoken or typed sentences about a home kitchen into structured \
    inventory changes.

    Rules:
    - Only use item ids that appear in the CANDIDATES list. Never invent an id.
    - If the user mentions something that is not in CANDIDATES, use action \
    "addItem" and leave itemID empty.
    - "used", "ate", "drank", "finished some" -> consume.
    - "bought", "picked up", "restocked" -> restock.
    - "I have three left", "there are two" -> setQuantity.
    - "out of", "all gone", "finished it" -> markOut.
    - One entry per distinct item. "used beans and we're out of milk" is two entries.
    - When a number is stated in units the item is not measured in ("two cans" \
    for an item measured in grams), still record the number the user said.
    - Lower your confidence when the match is a guess. Do not guess silently.
    - If the message is not about inventory at all, return no edits.
    """

    static func run(
        utterance: String,
        candidates: [OnDeviceInventorySnapshotItem]
    ) async throws -> [OnDeviceInventoryEdit] {
        let session = LanguageModelSession(instructions: instructions)

        var prompt = "CANDIDATES:\n"
        for item in candidates {
            var line = "- id=\(item.id) name=\(item.name)"
            if let quantity = item.quantity { line += " qty=\(formatted(quantity))" }
            if let unit = item.unit, !unit.isEmpty { line += " unit=\(unit)" }
            if let zone = item.zone, !zone.isEmpty { line += " zone=\(zone)" }
            prompt += line + "\n"
        }
        prompt += "\nUSER SAID:\n\(utterance)\n"

        do {
            let response = try await session.respond(to: prompt, generating: Result.self)
            return map(response.content, candidates: candidates)
        } catch let error as LanguageModelSession.GenerationError {
            throw mapError(error)
        } catch {
            throw OnDeviceIntentError.failed(error.localizedDescription)
        }
    }

    /// The model's output is treated as untrusted, exactly as the cloud path's
    /// is: ids must exist, actions must be known, amounts must be sane. Anything
    /// that fails validation is dropped rather than surfaced as a bad proposal.
    private static func map(
        _ result: Result,
        candidates: [OnDeviceInventorySnapshotItem]
    ) -> [OnDeviceInventoryEdit] {
        let byID = Dictionary(uniqueKeysWithValues: candidates.map { ($0.id, $0) })

        return result.edits.compactMap { edit -> OnDeviceInventoryEdit? in
            guard let action = OnDeviceInventoryEdit.Action(rawValue: edit.action.trimmingCharacters(in: .whitespaces))
            else { return nil }

            let rawID = edit.itemID.trimmingCharacters(in: .whitespaces)
            let resolved = rawID.isEmpty ? nil : byID[rawID]

            // A non-empty id that matches nothing is a hallucination. For an
            // .addItem that's harmless (drop the id); for anything else the edit
            // is meaningless and gets discarded.
            if resolved == nil, !rawID.isEmpty, action != .addItem { return nil }

            let name = resolved?.name ?? edit.itemName.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }

            return OnDeviceInventoryEdit(
                itemID: resolved?.id,
                itemName: name,
                action: action,
                amount: edit.amount > 0 ? edit.amount : nil,
                confidence: min(max(Double(edit.confidence) / 100.0, 0), 1)
            )
        }
    }

    private static func mapError(_ error: LanguageModelSession.GenerationError) -> OnDeviceIntentError {
        switch error {
        case .exceededContextWindowSize:
            return .contextTooLarge
        case .guardrailViolation:
            return .guardrail
        case .unsupportedLanguageOrLocale:
            return .unsupportedLanguage
        case .assetsUnavailable:
            return .unavailable("Apple Intelligence is still preparing.")
        default:
            return .failed(error.localizedDescription)
        }
    }

    private static func formatted(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.2f", value)
    }
}

#endif

// MARK: - Wiring
//
// In InventoryChangeProposal.swift, `InventoryIntentParser.parse` currently
// goes straight to the Worker. Make the on-device model the first choice:
//
//     static func parse(_ utterance: String, inventory: [InventoryItem]) async -> [ProposedChange] {
//         if AppleOnDeviceIntent.isAvailable {
//             do {
//                 let snapshot = inventory.map {
//                     OnDeviceInventorySnapshotItem(id: $0.id.uuidString, name: $0.name,
//                                                   quantity: $0.quantity, unit: $0.unit,
//                                                   zone: $0.zone?.rawValue)
//                 }
//                 let edits = try await AppleOnDeviceIntent.parse(utterance: utterance, inventory: snapshot)
//                 if !edits.isEmpty { return edits.compactMap { adapt($0, inventory: inventory) } }
//             } catch {
//                 // fall through — the cloud path is still there
//             }
//         }
//         return await parseViaWorker(utterance, inventory: inventory) ?? localFallback(utterance, inventory)
//     }
//
// `adapt` is the only glue that touches Stocked's own types: match `itemID`
// back to an `InventoryItem`, translate `.action` to the matching
// `ProposedChange` case, and pass `confidence` through so low-confidence edits
// land in the review sheet pre-unchecked rather than pre-checked.
//
// Keep three things:
//   1. `localFallback` — devices without Apple Intelligence are still the
//      majority of the install base.
//   2. The review-and-apply sheet. On-device output is not more trustworthy
//      than cloud output; it's just closer.
//   3. The Worker path, for the two cases the local model genuinely loses:
//      unusually long utterances, and pantries so large that `narrow` might
//      drop the right candidate.
//
// MARK: - Verification
//
// Brace/paren balance checked programmatically. The Foundation Models API used
// here — `SystemLanguageModel.default.availability`, `LanguageModelSession`,
// `@Generable` / `@Guide`, `session.respond(to:generating:)` and the
// `LanguageModelSession.GenerationError` cases — matches what
// AppleOnDeviceAI.swift already uses in this app, which was itself checked
// against Apple's documentation.
//
// NOT COMPILED and NOT run on hardware from where this was written. The real
// tests are: (1) a clean Xcode build, and (2) on an Apple Intelligence-capable
// device with Airplane Mode ON, say "used two cans of black beans" and confirm
// a correct proposal appears. If Xcode reports a signature mismatch, the design
// (narrow → generate → validate → review) doesn't depend on getting every API
// detail right the first time.
