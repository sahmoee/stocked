// CrashSafety.swift — Reusable guards against the most common runtime traps.
// Build 129 hardening pass. Everything here is additive and dependency-free.
//
// Covers:
//   • Collection[safe:]              — out-of-bounds-proof element access (#1)
//   • Int(finite:) / Double.safe…    — NaN / infinity-proof numeric conversions (#2, #4)
//   • safeDivide(_:by:)              — divide-by-zero-proof ratio with a caller default (#2)
//   • FailableDecodable / decode…    — one corrupt element no longer nukes the whole array (#6)

import Foundation

// MARK: - Safe collection access (#1)

extension Collection {
    /// Returns the element at `index` only if it is in bounds — otherwise nil.
    /// Use anywhere the index is computed rather than produced by `firstIndex`/`indices`.
    /// `if let item = items[safe: idx] { … }`
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Finite-safe numeric conversions (#2, #4)
// `Int(Double.nan)` and `Int(.infinity)` are hard crashes. Division by zero in Double
// yields nan/inf, which then crashes the moment it's turned into an Int (e.g. percentages,
// progress, scaled nutrition). These helpers make that conversion impossible to crash.

extension Int {
    /// Crash-proof Int from a Double. Non-finite values (nan/±inf) map to `fallback`.
    init(finite value: Double, fallback: Int = 0) {
        self = value.isFinite ? Int(value) : fallback
    }
}

extension Double {
    /// Self if finite, otherwise the supplied fallback (default 0).
    func orZeroIfNotFinite(_ fallback: Double = 0) -> Double {
        isFinite ? self : fallback
    }
}

/// Divide-by-zero-proof ratio. Returns `fallback` when the denominator is zero or the
/// result is non-finite. Keeps percentage / average / progress math from producing nan.
func safeDivide(_ numerator: Double, by denominator: Double, fallback: Double = 0) -> Double {
    guard denominator != 0 else { return fallback }
    let result = numerator / denominator
    return result.isFinite ? result : fallback
}

// MARK: - Corruption-tolerant array decoding (#6)
// A single malformed element in a stored JSON array makes `decode([T].self)` throw, which
// (with our `try?` call sites) silently discards the ENTIRE array — i.e. the user's whole
// pantry/grocery list/recipe set vanishes. FailableDecodable decodes each element
// independently so one bad record costs one record, not the collection.

/// Wraps a Decodable so a per-element decode failure yields `value == nil` instead of
/// throwing out of the array decode.
struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try? container.decode(Wrapped.self)
    }
}

enum SafeDecode {
    /// Decode an array, skipping any element that fails to decode. Returns nil only when the
    /// top-level data is not a JSON array at all (so callers can distinguish "absent/garbage
    /// file" from "array with some bad rows").
    static func array<Element: Decodable>(_ type: Element.Type, from data: Data,
                                          decoder: JSONDecoder = JSONDecoder()) -> [Element]? {
        guard let wrapped = try? decoder.decode([FailableDecodable<Element>].self, from: data) else {
            return nil
        }
        return wrapped.compactMap(\.value)
    }
}
