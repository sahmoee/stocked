// GroceryUsuals.swift
// Round 2 (Reducing friction): tracks how often each grocery item is added/bought so the
// list can offer one-tap re-add of your "usuals." Pure local persistence (UserDefaults),
// no network. Names are normalized so "Milk", "milk", and "MILK " all count together.

import Foundation
import os

@MainActor
final class GroceryUsuals {
    nonisolated deinit {}
    static let shared = GroceryUsuals()

    private struct Entry: Codable {
        var displayName: String
        var count: Int
        var lastAdded: Date
    }

    private var entries: [String: Entry] = [:]   // normalized name → entry
    private let key = "groceryUsuals_v1"

    private init() { load() }

    private func normalize(_ name: String) -> String {
        name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = decoded
        }
    }
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    struct InventoryDefaults: Codable {
        var name: String
        var container: String
        var zone: String
        var recordedAt: Date
        var sizeAmount: Double?
        var sizeUnit: String?
        var subZone: String?
    }
    private let inventoryDefaultsKey = "stocked.inventoryEntryDefaults.v1"

    /// Local, bounded entry preferences survive finishing/removing a pantry row.
    func inventoryDefaults(for name: String) -> InventoryDefaults? {
        guard let data = UserDefaults.standard.data(forKey: inventoryDefaultsKey),
              let entries = try? JSONDecoder().decode([InventoryDefaults].self, from: data) else { return nil }
        return entries.last { normalize($0.name) == normalize(name) }
    }

    func recordInventoryDefaults(name: String, container: String, zone: String,
                                 sizeAmount: Double? = nil, sizeUnit: String? = nil, subZone: String? = nil) {
        let normalized = normalize(name)
        guard !normalized.isEmpty else { return }
        var entries: [InventoryDefaults] = []
        if let data = UserDefaults.standard.data(forKey: inventoryDefaultsKey) {
            entries = (try? JSONDecoder().decode([InventoryDefaults].self, from: data)) ?? []
        }
        entries.removeAll { normalize($0.name) == normalized }
        entries.append(InventoryDefaults(name: name, container: container, zone: zone, recordedAt: Date(),
            sizeAmount: sizeAmount, sizeUnit: sizeUnit, subZone: subZone))
        if let data = try? JSONEncoder().encode(Array(entries.suffix(100))) {
            UserDefaults.standard.set(data, forKey: inventoryDefaultsKey)
        }
    }

    /// Record that an item was added to the list (or bought). Call on add and on check-off.
    func record(_ name: String) {
        let n = normalize(name)
        guard !n.isEmpty else { return }
        if var e = entries[n] {
            e.count += 1; e.lastAdded = Date(); e.displayName = name.prefix(1).uppercased() + name.dropFirst()
            entries[n] = e
        } else {
            entries[n] = Entry(displayName: name.prefix(1).uppercased() + name.dropFirst(), count: 1, lastAdded: Date())
        }
        persist()
    }

    /// Top "usuals" by a blend of frequency and recency, excluding anything already on the
    /// current list. Returns display names.
    func suggestions(excluding current: [String], limit: Int = 8) -> [String] {
        let onList = Set(current.map { normalize($0) })
        let now = Date()
        return entries.values
            .filter { !onList.contains(normalize($0.displayName)) && $0.count >= 2 }
            .sorted { a, b in
                // frequency, with a gentle recency boost
                func score(_ e: Entry) -> Double {
                    let days = max(now.timeIntervalSince(e.lastAdded) / 86400, 0)
                    let recency = max(0, 30 - days) / 30   // 0…1 over the last month
                    return Double(e.count) + recency * 2
                }
                return score(a) > score(b)
            }
            .prefix(limit)
            .map { $0.displayName }
    }

    func forget(_ name: String) {
        entries[normalize(name)] = nil; persist()
    }
}
