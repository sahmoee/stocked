import Foundation

/// Parses explicit quantities without treating digits inside a product name as amounts.
nonisolated enum GroceryEntryPolicy {
    struct Draft: Equatable {
        let name: String
        let quantity: Int
        /// QuantityParser-readable container and optional per-container measurement.
        let sizeText: String
    }

    static func draft(_ raw: String) -> Draft? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parsed = QuantityParser.parse(trimmed)
        guard parsed.validationMessage == nil, parsed.count > 0, !parsed.item.isEmpty else { return nil }
        // Non-quantity product names retain their original spelling and capitalization.
        let hasQuantity = parsed.item.caseInsensitiveCompare(trimmed) != .orderedSame
        guard hasQuantity else { return Draft(name: trimmed, quantity: 1, sizeText: "") }
        let measures: Set<String> = ["g", "kg", "ml", "l", "L", "oz", "lb", "cup", "tbsp", "tsp", "fl oz", "gallon", "quart", "pint"]
        if measures.contains(parsed.container) {
            return Draft(name: parsed.item, quantity: 1,
                sizeText: "package \(ParsedAmount.trim(parsed.count)) \(parsed.container)")
        }
        var size = parsed.container == "item" ? "" : parsed.container
        if let amount = parsed.amountEach, let unit = parsed.unitEach {
            size += " \(ParsedAmount.trim(amount)) \(unit)"
        }
        return Draft(name: parsed.item, quantity: max(1, Int(parsed.count.rounded(.up))),
                     sizeText: size.trimmingCharacters(in: .whitespaces))
    }

    static func adding(_ incoming: Int, to existing: Int) -> Int? {
        let (sum, overflow) = existing.addingReportingOverflow(incoming)
        guard !overflow, sum > 0, sum <= Int(QuantityParser.maximumAmount) else { return nil }
        return sum
    }

    static func compatibleSize(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ==
            rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
