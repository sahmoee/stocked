// AIInventoryScan.swift
// #FB4 — AI Inventory Scan: one tap sends the whole inventory to the Worker,
// which audits it and proposes tidy-ups — cleaned-up item names (garbled receipt
// text, misspellings), corrected storage locations (raw chicken doesn't live in
// the Pantry), nutrition estimates for items missing them, and shelf-life
// estimates for perishables with no expiry date. Nothing is applied without the
// user confirming each change in the review sheet (AIInventoryScanView).
//
// Runs off the main thread; only the final apply mutates the store, through the
// same array-reassignment pattern every other mutator uses so persistence and
// household sync fire exactly once.

import SwiftUI

// MARK: - Model

nonisolated struct InventoryScanUpdate: Identifiable, Equatable, Sendable {
    let id = UUID()
    let itemID: UUID
    let currentName: String
    var newName: String?              // nil = keep
    let currentZone: String
    var newZone: StorageCategory?     // nil = keep
    var calories: Int?                // nutrition estimate (only when item has none)
    var protein: Double?
    var servingSize: String?
    var expiryDays: Int?              // shelf-life estimate (only when item has no date)
    var reason: String
    var isConfirmed: Bool = true

    var hasNutrition: Bool { calories != nil || protein != nil }

    /// Short human summary lines for the review card.
    var effectLines: [String] {
        var out: [String] = []
        if let newName { out.append("Rename to \"\(newName)\"") }
        if let newZone { out.append("Move \(currentZone) → \(newZone.rawValue)") }
        if hasNutrition {
            var bits: [String] = []
            if let calories { bits.append("\(calories) cal") }
            if let protein { bits.append("\(protein.clean)g protein") }
            let serving = servingSize.map { " per \($0)" } ?? ""
            out.append("Nutrition: " + bits.joined(separator: ", ") + serving)
        }
        if let expiryDays {
            out.append("Set expiry ~\(expiryDays) day\(expiryDays == 1 ? "" : "s") from today")
        }
        return out
    }
}

// MARK: - Scanner (Worker client)

@Observable
@MainActor
final class AIInventoryScanner {
    var isScanning = false
    var lastError: String?

    nonisolated static var isAvailable: Bool { StockedWorkerClient.isConfigured }

    /// Sends the inventory snapshot to the Worker; returns proposed updates
    /// (empty array = inventory already tidy), or nil on failure with lastError set.
    func scan(store: GuestDataStore) async -> [InventoryScanUpdate]? {
        lastError = nil
        let items = store.inventoryItems
        guard !items.isEmpty else { lastError = "Your inventory is empty — nothing to scan."; return nil }
        guard StockedWorkerClient.isConfigured else { lastError = "The AI scan needs the Stocked Worker configured."; return nil }
        guard ConnectivityMonitor.isOnlineFlag else { lastError = "You're offline — try again with a connection."; return nil }

        // Chunking prevents max-token truncation on large pantries and lets each result be cached
        // against the exact inventory revision + item subset.
        let chunks = stride(from: 0, to: items.count, by: 40).map {
            Array(items[$0..<min($0 + 40, items.count)])
        }
        isScanning = true
        defer { isScanning = false }
        var allUpdates: [InventoryScanUpdate] = []
        do {
            for (index, chunk) in chunks.enumerated() {
                let snapshot = chunk.map { item -> [String: Any] in
                    ["id": item.id.uuidString, "name": item.name, "zone": item.zone,
                     "quantity": item.quantity, "brand": item.brand ?? "",
                     "hasNutrition": item.nutrition != nil, "hasExpiry": item.expirationDate != nil]
                }
                let payload: [String: Any] = [
                    "inventoryScan": true, "inventory": snapshot,
                    "inventoryRevision": store.inventoryRevision, "chunk": index,
                    "corrections": AICorrectionStore.shared.promptCorrections()
                ]
                let data = try await StockedWorkerClient.requestData(route: .inventoryScan,
                                                                     payload: payload,
                                                                     timeout: 50)
                allUpdates.append(contentsOf: Self.decode(data, items: chunk))
            }
            return allUpdates
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Parses the Worker's response ({updates:[…]} — possibly inside an Anthropic
    /// content envelope, possibly fenced) into typed updates, dropping anything that
    /// no longer matches an inventory row or that proposes nothing.
    nonisolated static func decode(_ data: Data, items: [LocalInventoryItem]) -> [InventoryScanUpdate] {
        guard let response = try? AIResponseDecoder.textResponse(from: data),
              let json = try? AIResponseDecoder.jsonData(from: response.text),
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let arr = obj["updates"] as? [[String: Any]] else { return [] }
        if let schema = obj["schemaVersion"] as? Int,
           schema != StockedWorkerRoute.inventoryScan.schemaVersion { return [] }

        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })

        return arr.compactMap { u -> InventoryScanUpdate? in
            guard let idStr = u["id"] as? String,
                  let itemID = UUID(uuidString: idStr),
                  let item = byID[itemID] else { return nil }

            var newName = (u["newName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let n = newName, n.isEmpty || n.caseInsensitiveCompare(item.name) == .orderedSame {
                newName = nil
            }
            var newZone: StorageCategory? = nil
            if let z = u["newZone"] as? String, let cat = StorageCategory(rawValue: z),
               cat.rawValue != item.zone {
                let decision = ZoneDecisionEngine.decide(name: item.name,
                                                         current: item.storageCategory,
                                                         aiZone: cat)
                newZone = decision.needsConfirmation || decision.zone == item.storageCategory
                    ? nil : decision.zone
            }
            // Nutrition only when the item genuinely has none (the model is told this,
            // but enforce it here too).
            var calories: Int? = nil
            var protein: Double? = nil
            var servingSize: String? = nil
            if item.nutrition == nil {
                calories = (u["calories"] as? NSNumber)?.intValue
                protein  = (u["protein"] as? NSNumber)?.doubleValue
                servingSize = (u["servingSize"] as? String)?.trimmingCharacters(in: .whitespaces)
                if servingSize?.isEmpty == true { servingSize = nil }
            }
            var expiryDays: Int? = nil
            if item.expirationDate == nil, let d = (u["expiryDays"] as? NSNumber)?.intValue,
               d > 0, d <= 730 {
                expiryDays = d
            }

            let update = InventoryScanUpdate(
                itemID: itemID,
                currentName: item.name,
                newName: newName,
                currentZone: item.zone,
                newZone: newZone,
                calories: calories,
                protein: protein,
                servingSize: servingSize,
                expiryDays: expiryDays,
                reason: (u["reason"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            )
            // Drop no-op entries the model emitted anyway.
            guard update.newName != nil || update.newZone != nil
                    || update.hasNutrition || update.expiryDays != nil else { return nil }
            return update
        }
    }
}

// MARK: - Apply

extension GuestDataStore {
    /// Applies confirmed scan updates in ONE array reassignment so persistence and
    /// household sync fire once, not once per field. Returns the number of items touched.
    @discardableResult
    func applyScanUpdates(_ updates: [InventoryScanUpdate]) -> Int {
        var list = inventoryItems
        var touched = 0
        for u in updates where u.isConfirmed {
            guard let i = list.firstIndex(where: { $0.id == u.itemID }) else { continue }
            var changed = false
            if let name = u.newName, !name.isEmpty { list[i].name = name; changed = true }
            if let zone = u.newZone { list[i].storageCategory = zone; changed = true }
            if u.hasNutrition {
                var facts = NutritionFacts()
                facts.calories = u.calories ?? 0
                facts.protein  = u.protein ?? 0
                facts.servingSize = u.servingSize ?? ""
                list[i].nutrition = facts
                changed = true
            }
            if let days = u.expiryDays {
                list[i].expirationDate = Calendar.current.date(byAdding: .day, value: days, to: Date())
                changed = true
            }
            if changed {
                if list[i].sourceBadge == nil { list[i].sourceBadge = .aiParsed }
                touched += 1
            }
        }
        if touched > 0 {
            withAnimation { inventoryItems = list }
        }
        return touched
    }
}
