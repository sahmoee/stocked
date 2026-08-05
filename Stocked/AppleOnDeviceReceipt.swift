//
//  AppleOnDeviceReceipt.swift
//  Stocked
//
//  Turns the text Vision already extracted from a receipt into structured line
//  items, on-device, with no network.
//
//  ─────────────────────────────────────────────────────────────────────────
//  What this replaces
//  ─────────────────────────────────────────────────────────────────────────
//  ReceiptScannerView.swift has two stages:
//
//      photo ──Vision OCR (on-device)──▶ text ──Worker /receiptText──▶ items
//                                              └─fails──▶ fallbackParse (regex)
//
//  The first stage is already local — the app's own design deliberately keeps
//  photos on the device. Only the *text* leaves. But when the Worker is
//  unreachable, the second stage collapses to a regex, and a supermarket
//  receipt full of "GV WHL MLK 1G" and "***SAVINGS***" is precisely what a
//  regex is worst at.
//
//  Foundation Models slots into that gap: same input (text the device already
//  has), no world knowledge required, and it turns "offline means a bad scan"
//  into "offline means a good scan by a smaller model".
//
//  Why the photo path still goes to the cloud: Foundation Models on iOS 26.0 is
//  text-only, and receipt photos are the case where a vision-capable cloud
//  model is genuinely better. This file is for the text stage only.
//
//  Why not make this the default even when online: a long receipt is a lot of
//  noisy tokens, and the cloud model resolves abbreviated retailer SKUs
//  ("GV" -> Great Value) meaningfully better. Cloud first, this second — the
//  inverse of AppleOnDeviceIntent.swift, for the opposite reasons.
//
//  Self-contained: depends only on Foundation and FoundationModels. See
//  "Wiring" at the bottom.
//
//  NOT COMPILED HERE. Build in Xcode; see the Verification note.
//

import Foundation
import os

#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Public value types

struct OnDeviceReceiptLine: Sendable, Equatable {
    /// Cleaned, human-readable product name ("Whole Milk", not "GV WHL MLK 1G").
    let name: String
    /// The raw text this line came from — kept so the review UI can show the
    /// user what was interpreted, and so a wrong guess is obvious.
    let rawText: String
    let quantity: Double
    let unitPrice: Double?
    let totalPrice: Double?
    /// 0...1. Anything below ~0.5 should land in the review sheet unchecked.
    let confidence: Double
}

struct OnDeviceReceiptResult: Sendable {
    let store: String?
    let lines: [OnDeviceReceiptLine]
}

enum OnDeviceReceiptError: LocalizedError {
    case unavailable(String)
    case emptyInput
    case contextTooLarge
    case guardrail
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let why): return why
        case .emptyInput: return "There was no text to read."
        case .contextTooLarge: return "That receipt is longer than the on-device model can read at once."
        case .guardrail: return "The on-device model declined that receipt."
        case .failed(let message): return message
        }
    }
}

// MARK: - Entry point

enum AppleOnDeviceReceipt {

    private static let log = Logger(subsystem: "com.sowens.Stocked", category: "OnDeviceReceipt")

    /// Long receipts are chunked rather than truncated, so nothing is silently
    /// dropped. Tuned well under the on-device context window to leave room for
    /// the instructions and the generated output.
    private static let maxLinesPerChunk = 45

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
        #else
        return false
        #endif
    }

    static var unavailableReason: String? {
        #if canImport(FoundationModels)
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This device doesn't support Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings to scan receipts offline."
        case .unavailable(.modelNotReady): return "Apple Intelligence is still downloading its model."
        case .unavailable: return "Apple Intelligence isn't available right now."
        }
        #else
        return "This build wasn't compiled with Apple Intelligence support."
        #endif
    }

    /// Structure OCR'd receipt text into line items, entirely on-device.
    ///
    /// - Parameters:
    ///   - text: the Vision output, newline-separated, unmodified.
    ///   - storeHint: what the app already believes the store is, if anything.
    ///     Passed as a hint only; the model may correct it from the header.
    static func parse(text: String, storeHint: String?) async throws -> OnDeviceReceiptResult {
        let lines = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !lines.isEmpty else { throw OnDeviceReceiptError.emptyInput }
        guard isAvailable else {
            throw OnDeviceReceiptError.unavailable(unavailableReason ?? "Apple Intelligence is unavailable.")
        }

        #if canImport(FoundationModels)
        let chunks = stride(from: 0, to: lines.count, by: maxLinesPerChunk).map {
            Array(lines[$0 ..< min($0 + maxLinesPerChunk, lines.count)])
        }
        log.debug("on-device receipt: \(lines.count, privacy: .public) lines in \(chunks.count, privacy: .public) chunk(s)")

        var collected: [OnDeviceReceiptLine] = []
        var store = storeHint
        var lastError: Error?

        // Per-chunk failure loses one chunk, not the whole scan — the same
        // partial-results policy AIInventoryScan.swift uses.
        for (index, chunk) in chunks.enumerated() {
            do {
                let result = try await FoundationModelsReceipt.run(
                    lines: chunk,
                    storeHint: store,
                    isFirstChunk: index == 0
                )
                if index == 0, let detected = result.store, !detected.isEmpty { store = detected }
                collected.append(contentsOf: result.lines)
            } catch {
                lastError = error
                log.error("on-device receipt chunk \(index, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        if collected.isEmpty, let lastError { throw lastError }
        return OnDeviceReceiptResult(store: store, lines: dedupe(collected))
        #else
        throw OnDeviceReceiptError.unavailable("Apple Intelligence isn't available in this build.")
        #endif
    }

    /// Chunk boundaries can land mid-item and produce a near-duplicate. Collapse
    /// exact repeats of (name, total) that came from the same raw text.
    private static func dedupe(_ lines: [OnDeviceReceiptLine]) -> [OnDeviceReceiptLine] {
        var seen = Set<String>()
        return lines.filter { line in
            let key = "\(line.name.lowercased())|\(line.rawText.lowercased())|\(line.totalPrice ?? -1)"
            return seen.insert(key).inserted
        }
    }
}

// MARK: - Foundation Models

#if canImport(FoundationModels)

private enum FoundationModelsReceipt {

    @Generable
    struct Line {
        @Guide(description: "The product in plain English, expanded from any abbreviation. For example 'GV WHL MLK 1G' becomes 'Whole Milk'.")
        var name: String

        @Guide(description: "The receipt line this came from, copied exactly.")
        var rawText: String

        @Guide(description: "How many of this item were bought. Use 1 when the receipt does not say.", .range(0...99))
        var quantity: Double

        @Guide(description: "Price for one unit, in the receipt's currency. Use 0 if it is not printed.", .range(0...9999))
        var unitPrice: Double

        @Guide(description: "Total charged for this line. Use 0 if it is not printed.", .range(0...9999))
        var totalPrice: Double

        @Guide(description: "How confident you are that this is a real purchased product, 0 to 100.", .range(0...100))
        var confidence: Int
    }

    @Generable
    struct Result {
        @Guide(description: "The shop's name if it appears in the header, otherwise an empty string.")
        var store: String

        @Guide(description: "One entry per purchased product. Skip subtotals, tax, discounts, loyalty lines and payment details.")
        var lines: [Line]
    }

    static let instructions = """
    You read text captured from a shop receipt and list what was actually bought.

    Rules:
    - One entry per purchased product.
    - Expand retailer abbreviations into normal product names. Keep the original \
    line in rawText so a person can check you.
    - Never include: subtotal, total, tax, change, tender, card numbers, loyalty \
    points, coupons, savings lines, store address, phone numbers, dates, \
    cashier names, or survey invitations.
    - A weighed item ("BANANAS 1.24 lb @ 0.59") is one entry: quantity is the \
    weight, unitPrice is the per-unit price.
    - Do not invent prices. If a number is not printed, use 0.
    - If a line is unreadable or you are unsure it is a product, lower the \
    confidence rather than dropping it.
    - Return no lines if the text is not a receipt.
    """

    static func run(
        lines: [String],
        storeHint: String?,
        isFirstChunk: Bool
    ) async throws -> OnDeviceReceiptResult {
        let session = LanguageModelSession(instructions: instructions)

        var prompt = ""
        if let storeHint, !storeHint.isEmpty { prompt += "The shop is probably: \(storeHint)\n\n" }
        if !isFirstChunk { prompt += "This is a continuation of the same receipt; the header is not repeated.\n\n" }
        prompt += "RECEIPT TEXT:\n" + lines.joined(separator: "\n") + "\n"

        do {
            let response = try await session.respond(to: prompt, generating: Result.self)
            return map(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            throw mapError(error)
        } catch {
            throw OnDeviceReceiptError.failed(error.localizedDescription)
        }
    }

    private static func map(_ result: Result) -> OnDeviceReceiptResult {
        let store = result.store.trimmingCharacters(in: .whitespaces)

        let lines: [OnDeviceReceiptLine] = result.lines.compactMap { line in
            let name = line.name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            // A model that echoes a total line despite the instructions is a
            // known failure mode; catch the obvious ones rather than trusting.
            let lowered = name.lowercased()
            let banned = ["subtotal", "total", "tax", "change", "balance", "tender", "savings", "coupon", "loyalty"]
            guard !banned.contains(where: { lowered == $0 || lowered.hasPrefix("\($0) ") }) else { return nil }

            return OnDeviceReceiptLine(
                name: name,
                rawText: line.rawText.trimmingCharacters(in: .whitespaces),
                quantity: line.quantity > 0 ? line.quantity : 1,
                unitPrice: line.unitPrice > 0 ? line.unitPrice : nil,
                totalPrice: line.totalPrice > 0 ? line.totalPrice : nil,
                confidence: min(max(Double(line.confidence) / 100.0, 0), 1)
            )
        }

        return OnDeviceReceiptResult(store: store.isEmpty ? nil : store, lines: lines)
    }

    private static func mapError(_ error: LanguageModelSession.GenerationError) -> OnDeviceReceiptError {
        switch error {
        case .exceededContextWindowSize: return .contextTooLarge
        case .guardrailViolation: return .guardrail
        case .assetsUnavailable: return .unavailable("Apple Intelligence is still preparing.")
        default: return .failed(error.localizedDescription)
        }
    }
}

#endif

// MARK: - Wiring
//
// In ReceiptScannerView.swift, the text stage currently reads roughly:
//
//     let items = (try? await StockedWorkerClient.requestData(route: .receiptText, ...))
//                 .flatMap(decode) ?? fallbackParse(text)
//
// Insert the on-device model between those two, so it becomes the *second*
// choice rather than the last:
//
//     if let cloud = try? await worker(.receiptText, text) { return cloud }
//     if AppleOnDeviceReceipt.isAvailable,
//        let local = try? await AppleOnDeviceReceipt.parse(text: text, storeHint: store) {
//         return local.lines.map(adapt)          // mark the scan as on-device in the UI
//     }
//     return fallbackParse(text)                 // regex, unchanged
//
// Keep `fallbackParse`. Devices without Apple Intelligence still need it, and it
// costs nothing to leave in place.
//
// Surface the source in the review sheet the same way AIInventoryScan.swift
// surfaces `usedOnDeviceFallback` — users notice when results change quality and
// deserve to know why.
//
// MARK: - Verification
//
// Brace/paren balance checked programmatically; API surface matches the
// framework usage already proven in AppleOnDeviceAI.swift in this app.
//
// NOT COMPILED and NOT exercised on hardware. Real test: on an Apple
// Intelligence-capable device, put it in Airplane Mode, scan a real grocery
// receipt, and confirm the item list is materially better than what
// `fallbackParse` produces for the same photo. Long receipts are the case to
// check — the chunking path is where a bug would hide.
