// ReceiptProcessingService.swift
// Deterministic receipt normalization independent of SwiftUI and networking.
import Foundation

nonisolated struct ReceiptNormalizedItem: Sendable, Equatable {
    let raw: String
    let resolved: String
    let brand: String?
    let quantity: Int
    let sizeAmount: Double?
    let sizeUnit: String?
    let identity: ProductIdentity
    let aisle: GroceryAisle
    let resolutionConfidence: Double
    let provenance: FieldProvenance

    /// Compatibility adapter into the one review/apply contract. Receipt screens can migrate one
    /// call site at a time without changing their OCR and grouping UI in the same release.
    func proposedChange(containerType: String? = nil) -> ProposedChange {
        var change = InventoryProposalBatch.reviewableAdd(
            name: resolved,
            quantity: quantity,
            containerType: containerType,
            sizeAmount: sizeAmount,
            sizeUnit: sizeUnit,
            brand: brand,
            barcode: identity.namespace == .barcode ? identity.key : nil,
            origin: .receipt,
            sourceID: provenance.sourceID,
            badge: provenance.badge,
            reason: "Found on your receipt"
        )
        let resolvedStorage = change.product?.storageCategory
        change.product = InventoryProposalProduct(
            identity: identity,
            displayName: resolved,
            brand: brand,
            storageCategory: resolvedStorage,
            aisle: aisle,
            barcode: identity.namespace == .barcode ? identity.key : nil,
            resolutionConfidence: resolutionConfidence
        )
        change.fieldProvenance[.name] = provenance
        change.fieldProvenance[.brand] = provenance
        change.fieldProvenance[.quantity] = provenance
        change.fieldProvenance[.size] = provenance
        if resolutionConfidence < 0.72,
           !change.reviewIssues.contains(where: { $0.code == "low-receipt-match" }) {
            change.reviewIssues.append(InventoryProposalIssue(
                code: "low-receipt-match",
                message: "Receipt text did not confidently match a known product.",
                field: .name
            ))
        }
        return change
    }
}

nonisolated enum ReceiptProcessingService {
    static func normalize(raw: String,
                          aiResolved: String?,
                          storeName: String,
                          learnedTranslation: String?,
                          abbreviationTranslation: String?) -> ReceiptNormalizedItem? {
        let cleanedRaw = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedRaw.isEmpty, !isNonItemLine(cleanedRaw) else { return nil }
        let seed = learnedTranslation ?? abbreviationTranslation ?? aiResolved ?? cleanedRaw
        let quantity = parseQuantity(cleanedRaw)
        let size = parseSize(cleanedRaw)
        let displaySeed = stripReceiptMetadata(from: seed)
        let display = displaySeed.isEmpty ? seed : displaySeed
        let catalogMatch = ProductCatalog.bestMatch(for: display)
        let separated = separateBrand(from: catalogMatch?.name ?? display, storeName: storeName)
        let name = normalizeName(separated.name)
        guard name.count >= 2 else { return nil }
        let retailerID = GroceryKnowledgeBase.retailer(matching: storeName)?.id
        let resolution = ProductCatalog.resolve(ProductResolutionContext(
            rawName: name,
            brand: separated.brand,
            retailerID: retailerID
        ))
        let sourceID = retailerID.map { "receipt:\($0)" } ?? "receipt"
        let provenance = FieldProvenance(sourceID: sourceID, sourceName: "Receipt scan",
                                         badge: .aiParsed)
        return ReceiptNormalizedItem(raw: cleanedRaw, resolved: name, brand: separated.brand,
                                     quantity: max(1, quantity), sizeAmount: size?.0, sizeUnit: size?.1,
                                     identity: resolution.identity, aisle: resolution.aisle,
                                     resolutionConfidence: resolution.confidence,
                                     provenance: provenance)
    }

    static func consolidate<T>(_ items: [T], key: (T) -> String, quantity: (T) -> Int,
                               merging: (T, Int) -> T) -> [T] {
        var order: [String] = []
        var rows: [String: T] = [:]
        var totals: [String: Int] = [:]
        for item in items {
            let normalized = FoodNameMatcher.normalized(key(item))
            guard !normalized.isEmpty else { continue }
            if rows[normalized] == nil { rows[normalized] = item; order.append(normalized) }
            totals[normalized, default: 0] += max(1, quantity(item))
        }
        return order.compactMap { k in rows[k].map { merging($0, totals[k] ?? 1) } }
    }

    static func normalizeName(_ raw: String) -> String {
        let words = raw.components(separatedBy: CharacterSet.alphanumerics.union(.whitespaces).inverted)
            .joined(separator: " ")
            .split(separator: " ").map(String.init)
            .filter { !$0.isEmpty }
        return words.map { word in
            let lower = word.lowercased()
            if ["oz", "lb", "lbs", "ct", "pk", "g", "kg", "ml"].contains(lower) { return lower }
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }.joined(separator: " ")
    }

    private static func isNonItemLine(_ raw: String) -> Bool {
        let text = FoodNameMatcher.normalized(raw)
        let blocked = ["subtotal", "sales tax", "tax", "total", "change", "cash", "credit", "debit",
                       "balance", "receipt", "thank you", "visa", "mastercard", "amex"]
        return blocked.contains { FoodNameMatcher.containsPhrase($0, in: text) }
    }

    private static func parseQuantity(_ raw: String) -> Int {
        let patterns: [(String, NSRegularExpression.Options)] = [
            (#"\b(\d{1,3})\s*(?:x|ct|count|pk|pack)\b"#, [.caseInsensitive]),
            // Receipt exports often prefix repeated items as "2 MILK". Requiring an uppercase
            // item token avoids interpreting product names such as "7 UP" as seven units.
            (#"^\s*(\d{1,2})\s+(?=[A-Z]{3,}\b)"#, [])
        ]
        for (pattern, options) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
                  let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
                  let range = Range(match.range(at: 1), in: raw),
                  let value = Int(raw[range]), value > 0 else { continue }
            return value
        }
        return 1
    }

    private static func stripReceiptMetadata(from raw: String) -> String {
        var value = raw
        let patterns = [
            // Leading receipt line-item or PLU numbers: "52 H-E-B SALT" → "H-E-B SALT"
            // Matches 2-4 digit numbers at the start followed by a letter (avoids single-digit
            // quantities like "2 MILK" which are handled separately by parseQuantity).
            #"^\s*\d{2,4}\s+(?=[A-Za-z])"#,
            // Quantity × unit prefix: "3 x ", "2 ct "
            #"^\s*\d{1,3}\s*(?:x|ct|count|pk|pack)\s+"#,
            // Embedded weight/volume measurements
            #"\b\d+(?:\.\d+)?\s*(?:fl\s*oz|oz|lb|lbs|g|kg|ml|l)\b"#,
            // Trailing prices
            #"\s+\$?\d+\.\d{2}\s*$"#
        ]
        for pattern in patterns {
            value = value.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        return value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseSize(_ raw: String) -> (Double, String)? {
        guard let regex = try? NSRegularExpression(pattern: #"\b(\d+(?:\.\d+)?)\s*(fl\s*oz|oz|lb|lbs|g|kg|ml|l)\b"#, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
              let amountRange = Range(match.range(at: 1), in: raw),
              let unitRange = Range(match.range(at: 2), in: raw),
              let amount = Double(raw[amountRange]) else { return nil }
        return (amount, String(raw[unitRange]).lowercased().replacingOccurrences(of: " ", with: ""))
    }

    private static func separateBrand(from raw: String, storeName: String) -> (name: String, brand: String?) {
        guard let brand = GroceryKnowledgeBase.brand(in: raw, storeName: storeName) else { return (raw, nil) }
        let pieces = brand.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        let pattern = #"\b"# + pieces.map(NSRegularExpression.escapedPattern(for:)).joined(separator: #"[\s&'’-]*"#) + #"\b"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            let range = NSRange(raw.startIndex..., in: raw)
            let remaining = regex.stringByReplacingMatches(in: raw, range: range, withTemplate: " ")
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (remaining.isEmpty ? raw : remaining, brand)
        }
        return (raw, nil)
    }
}
