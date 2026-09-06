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

    static func editableQuantity(_ value: Int) -> Int { max(0, value) }

    static func editableFillLevel(_ value: Double) -> Double {
        value.isFinite ? min(1, max(0, value)) : 0
    }

    /// Fields the user did not touch retain newer household values received while the sheet was open.
    static func mergeDraft<Value: Equatable>(live: Value, initial: Value, draft: Value) -> Value {
        draft == initial ? live : draft
    }
}
