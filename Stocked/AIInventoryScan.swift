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
import os

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

    /// Either path being usable is enough to offer the scan: the cloud Worker (richer
    /// model), or on-device Apple Intelligence (works offline, and covers the Worker
    /// being unreachable/misconfigured/erroring).
    static var isAvailable: Bool { StockedWorkerClient.isConfigured || AppleOnDeviceAI.isAvailable }

    /// True if the most recent completed scan produced at least one update via the
    /// on-device fallback rather than the cloud Worker (surfaced so the review sheet
    /// can note it, if it wants to — purely informational).
    private(set) var usedOnDeviceFallback = false

    /// Sends the inventory snapshot to the Worker; returns proposed updates
    /// (empty array = inventory already tidy), or nil on failure with lastError set.
    /// Each chunk tries the cloud Worker first (bigger model, richer world knowledge);
    /// if that chunk's request fails for any reason — Worker down, misconfigured,
    /// offline, upstream error — it falls back to Apple's on-device model for just
    /// that chunk when this device supports it, instead of failing the whole scan.
    func scan(store: GuestDataStore) async -> [InventoryScanUpdate]? {
        lastError = nil
        usedOnDeviceFallback = false
        let items = store.inventoryItems
        guard !items.isEmpty else { lastError = "Your inventory is empty — nothing to scan."; return nil }
        guard Self.isAvailable else {
            lastError = "The AI scan needs the Stocked Worker configured, or Apple Intelligence enabled on this device."
            return nil
        }

        // Chunking prevents max-token truncation on large pantries and lets each result be cached
        // against the exact inventory revision + item subset.
        let chunks = stride(from: 0, to: items.count, by: 40).map {
            Array(items[$0..<min($0 + 40, items.count)])
        }
        isScanning = true
        defer { isScanning = false }
        var allUpdates: [InventoryScanUpdate] = []
        var lastChunkError: Error?
        var completedLocalAudit = false
        let corrections = AICorrectionStore.shared.promptCorrections()
        let cloudReachable = StockedWorkerClient.isConfigured && ConnectivityMonitor.isOnlineFlag

        for (index, chunk) in chunks.enumerated() {
            if cloudReachable {
                do {
                    let snapshot = chunk.map { item -> [String: Any] in
                        ["id": item.id.uuidString, "name": item.name, "zone": item.zone,
                         "quantity": item.quantity, "brand": item.brand ?? "",
                         "hasNutrition": item.nutrition != nil, "hasExpiry": item.expirationDate != nil]
                    }
                    let payload: [String: Any] = [
                        "inventoryScan": true, "inventory": snapshot,
                        "inventoryRevision": store.inventoryRevision, "chunk": index,
                        "corrections": corrections
                    ]
                    let data = try await StockedWorkerClient.requestData(route: .inventoryScan,
                                                                         payload: payload,
                                                                         timeout: 90)
                    allUpdates.append(contentsOf: Self.decode(data, items: chunk))
                    continue
                } catch {
                    lastChunkError = error
                    Log.app.notice("AIInventoryScan: Worker failed for chunk \(index, privacy: .public), trying on-device — \(error.localizedDescription, privacy: .public)")
                }
            }

            if AppleOnDeviceAI.isAvailable {
                let correctionsList = corrections.map { "\($0.key) → \($0.value)" }
                // Foundation Models has no built-in timeout; 35 s per chunk prevents
                // the spinner from running for minutes when the model is slow or overloaded.
                let onDevice: [InventoryScanUpdate]? = await withTaskGroup(of: [InventoryScanUpdate]?.self) { group in
                    group.addTask { try? await AppleOnDeviceAI.scanInventory(items: chunk, corrections: correctionsList) }
                    group.addTask { try? await Task.sleep(nanoseconds: 35_000_000_000); return nil }
                    let result = await group.next() ?? nil
                    group.cancelAll()
                    return result
                }
                if let onDevice {
                    allUpdates.append(contentsOf: onDevice)
                    usedOnDeviceFallback = true
                    continue
                }
                // nil = timed out; fall through keeping prior lastChunkError
            }

            // Foundation Models is not present on every supported device, and a cloud
            // provider can be unavailable for billing, quota, or network reasons. The
            // deterministic audit still corrects safe zone and shelf-life metadata from
            // Stocked's local knowledge. It deliberately does not invent nutrition or
            // rename products, and an empty result means "already tidy", not failure.
            allUpdates.append(contentsOf: Self.deterministicAudit(items: chunk))
            completedLocalAudit = true
            usedOnDeviceFallback = true
        }

        if allUpdates.isEmpty, let lastChunkError, !completedLocalAudit {
            lastError = lastChunkError.localizedDescription
            return nil
        }
        return allUpdates
    }

    nonisolated private static func deterministicAudit(items: [LocalInventoryItem]) -> [InventoryScanUpdate] {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.startOfDay(for: Date())
        return items.compactMap { item in
            let zoneDecision = ZoneDecisionEngine.decide(name: item.name, current: item.storageCategory)
            let newZone: StorageCategory? = !zoneDecision.needsConfirmation && zoneDecision.zone != item.storageCategory
                ? zoneDecision.zone : nil

            var expiryDays: Int?
            var reasons: [String] = []
            if let newZone { reasons.append("Move to \(newZone.rawValue) using on-device food classification") }
            if item.expirationDate == nil,
               let estimate = ShelfLifeEstimator.estimate(name: item.name, zone: newZone ?? item.storageCategory).date {
                let days = calendar.dateComponents([.day], from: today, to: calendar.startOfDay(for: estimate)).day ?? 0
                if (1...730).contains(days) {
                    expiryDays = days
                    reasons.append("Add shelf life from Stocked's on-device food table")
                }
            }
            guard newZone != nil || expiryDays != nil else { return nil }
            return InventoryScanUpdate(
                itemID: item.id,
                currentName: item.name,
                newName: nil,
                currentZone: item.zone,
                newZone: newZone,
                calories: nil,
                protein: nil,
                servingSize: nil,
                expiryDays: expiryDays,
                reason: reasons.joined(separator: ". ")
            )
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

        let byID = Dictionary(keepingLastValues: items.map { ($0.id, $0) })

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
            RetailEnrichmentMaintenance.enqueueInventoryItems(
                ids: updates.filter(\.isConfirmed).map(\.itemID), store: self)
        }
        return touched
    }
}
