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

struct InventoryScanUpdate: Identifiable, Equatable {
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
        guard ConnectivityMonitor.isOnlineFlag else {
            lastError = "You're offline — try again with a connection."; return nil
        }
        let urlString = BuildConfig.receiptWorkerURL
        guard !urlString.contains("REPLACE-WITH-YOUR-WORKER"), let url = URL(string: urlString) else {
            lastError = "The AI scan needs the recipe service configured."; return nil
        }

        // Cap the snapshot so huge inventories stay under the model's output budget;
        // the scan can be run again to cover the rest (we send least-recently-clean first
        // is overkill — a simple cap is fine at kitchen scale).
        let snapshot = items.prefix(120).map { item -> [String: Any] in
            [
                "id": item.id.uuidString,
                "name": item.name,
                "zone": item.zone,
                "quantity": item.quantity,
                "brand": item.brand ?? "",
                "hasNutrition": item.nutrition != nil,
                "hasExpiry": item.expirationDate != nil,
            ]
        }
        let payload: [String: Any] = ["inventoryScan": true, "inventory": snapshot]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            lastError = "Couldn't build the request."; return nil
        }

        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&req)
        req.httpBody = body; req.timeoutInterval = 45

        isScanning = true
        defer { isScanning = false }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
                lastError = "The scan couldn't complete (HTTP \(status)). Try again in a moment."
                return nil
            }
            return Self.decode(data, items: items)
        } catch {
            lastError = "The scan couldn't reach the server. Check your connection and try again."
            return nil
        }
    }

    /// Parses the Worker's response ({updates:[…]} — possibly inside an Anthropic
    /// content envelope, possibly fenced) into typed updates, dropping anything that
    /// no longer matches an inventory row or that proposes nothing.
    static func decode(_ data: Data, items: [LocalInventoryItem]) -> [InventoryScanUpdate] {
        var jsonText = String(data: data, encoding: .utf8) ?? ""
        if let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = env["content"] as? [[String: Any]] {
            jsonText = content.compactMap { $0["text"] as? String }.joined()
        }
        let clean = jsonText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let obj = try? JSONSerialization.jsonObject(with: Data(clean.utf8)) as? [String: Any],
              let arr = obj["updates"] as? [[String: Any]] else { return [] }

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
                // Cross-reference the on-device classifier before trusting the model's zone.
                // ZoneClassifier.classify already knows that dried seasonings ("cayenne
                // pepper", "lemon pepper") are Staples and flavored snacks ("cheddar chips")
                // are Pantry — NOT Fridge. If the model wants to move an item INTO Fridge or
                // Freezer but the local classifier keeps it shelf-stable (Pantry/Staples),
                // distrust the model and drop the zone change. This stops the classic
                // misfires (cayenne pepper -> Fridge, cheddar chips -> dairy/Fridge).
                let localZone = ZoneClassifier.classify(item.name)
                let modelWantsCold = (cat == .fridge || cat == .freezer)
                let localSaysShelfStable = (localZone == .pantry || localZone == .staples)
                if modelWantsCold && localSaysShelfStable {
                    newZone = nil   // reject the naive cold-storage move
                } else {
                    newZone = cat
                }
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
