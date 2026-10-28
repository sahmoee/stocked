import Foundation

/// Pure draft rules shared by the native inventory forms and native regression checks.
/// These repair presentation values only; opening an editor never writes to the store.
nonisolated enum InventoryFormPolicy {
    static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func storageSelection(current: String, suggested: String, manuallySelected: Bool) -> String {
        manuallySelected ? current : suggested
    }

    /// Only undo the exact mutation we produced; a newer household edit wins.
    static func permitsUndo<Value: Equatable>(live: Value, expected: Value) -> Bool {
        live == expected
    }

    /// Consuming a container leaves unopened containers full; the final one becomes empty.
    static func consumption(quantity: Int, level: Double, finishAll: Bool) -> (quantity: Int, level: Double)? {
        guard quantity > 0, level > 0, level.isFinite else { return nil }
        if finishAll || quantity == 1 { return (0, 0) }
        return (quantity - 1, 1)
    }

    static func editableQuantity(_ value: Int) -> Int { max(0, value) }

    static func editableFillLevel(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    /// Fields the user did not touch retain newer household values received while the sheet was open.
    static func mergeDraft<Value: Equatable>(live: Value, initial: Value, draft: Value) -> Value {
        draft == initial ? live : draft
    }
}
