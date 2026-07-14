// KitchenTransferManager.swift
// Handles all kitchen data export, import, backup, and transfer operations.
import SwiftUI
import Combine
import CloudKit
import CoreImage.CIFilterBuiltins
import os

// MARK: - Kitchen Preferences (settings carried in a backup)
// Optional in the snapshot so older backups without it still decode cleanly.
// nonisolated: pure value type; its Codable conformance is used by JSONDecoder off the main
// actor during import, so it must not infer main-actor isolation.
nonisolated struct KitchenPreferences: Codable, Sendable {
    // Theme (light/dark + font only — custom color channels removed)
    var appTheme: String          = ""
    var appFont: String           = ""
    var isDarkMode: Bool          = false
    // Behavior / shopping
    var preferredStore: String    = ""
    var autoAddMissingToGrocery: Bool = true
    var notificationsEnabled: Bool = true
    var homeButtonLayout: String  = ""
    var cookButtonShape: String   = ""
    var cookButtonSize: Double    = 0
    var preferredRecipeTab: Int   = 0
    // Streaks / history
    var cookStreak: Int           = 0
    var longestStreak: Int        = 0
}

// MARK: - Kitchen Snapshot
// nonisolated: decoded by JSONDecoder off the main actor; pure value type.
nonisolated struct KitchenSnapshot: Codable, Sendable {
    var schemaVersion:   Int    = 2
    var exportedAt:      String
    var displayName:     String
    var inventoryItems:  [LocalInventoryItem]
    var groceryItems:    [LocalGroceryItem]
    var pastMeals:       [LocalPastMeal]
    var savedRecipes:    [LocalRecipe]
    var userRecipes:     [UserRecipe]?      = nil   // optional → old backups still decode
    var preferences:     KitchenPreferences? = nil   // optional → old backups still decode

    init(displayName: String, inventoryItems: [LocalInventoryItem],
         groceryItems: [LocalGroceryItem], pastMeals: [LocalPastMeal],
         userRecipes: [UserRecipe]? = nil, preferences: KitchenPreferences? = nil) {
        self.exportedAt     = ISO8601DateFormatter().string(from: Date())
        self.displayName    = displayName
        self.inventoryItems = inventoryItems
        self.groceryItems   = groceryItems
        self.pastMeals      = pastMeals
        self.savedRecipes   = []
        self.userRecipes    = userRecipes
        self.preferences    = preferences
    }
}

// MARK: - Transfer Manager
@Observable
@MainActor
class KitchenTransferManager {
    // Explicit container ID — must match the single entry in Stocked.entitlements
    private let cloudContainer = CKContainer(identifier: "iCloud.Stocked")

    // #5: Normalized dedup key — trims, lowercases, and collapses internal whitespace so
    // "Whole Milk", "whole milk ", and "whole  milk" all dedupe as the same item.
    private func normKey(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // Set by the presenting view so backups can include + restore app preferences
    // (theme, colors, preferred store, etc.) which live on AppSession, not the store.
    weak var session: AppSession?

    var isExporting      = false
    var isImporting      = false
    var isBacking        = false
    var statusMessage    = ""
    var errorMessage     = ""

    /// True while the first-launch iCloud restore check is running. RootView watches this so a
    /// returning user briefly sees the splash instead of the onboarding quiz, until we know
    /// whether their Apple ID has an existing Stocked backup to restore.
    var isCheckingForExistingAccount = false
    var qrCodeImage:     UIImage?
    var shareURL:        URL?
    var exportedFileURL: URL?
    var iCloudStatus     = "Not checked"

    // MARK: - Snapshot builder (always on main thread via caller)
    private func makeSnapshot(store: GuestDataStore) -> KitchenSnapshot {
        KitchenSnapshot(
            displayName:    store.displayName,
            inventoryItems: store.inventoryItems,
            groceryItems:   store.groceryItems,
            pastMeals:      store.pastMeals,
            userRecipes:    store.userRecipes,
            preferences:    session?.capturePreferences()
        )
    }

    // MARK: - Export to JSON file
    func exportToFile(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        isExporting = true; statusMessage = ""; errorMessage = ""
        let snapshot = makeSnapshot(store: store)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            isExporting = false; errorMessage = "Export failed: encode error"
            completion(nil); return
        }
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stocked-Kitchen-\(dateStr).stocked")
        Task(priority: .userInitiated) {
            do {
                try data.write(to: url)
                Task { @MainActor in
                    self.isExporting = false; self.exportedFileURL = url
                    self.statusMessage = "Kitchen exported successfully!"
                    completion(url)
                }
            } catch {
                Task { @MainActor in
                    self.isExporting = false
                    self.errorMessage = "Export failed: \(error.localizedDescription)"
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Export as .json (same data, .json extension)
    func exportToJSON(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        isExporting = true; statusMessage = ""; errorMessage = ""
        let snapshot = makeSnapshot(store: store)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(snapshot) else {
            isExporting = false; errorMessage = "Export failed: encode error"
            completion(nil); return
        }
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Stocked-Kitchen-\(dateStr).json")
        Task(priority: .userInitiated) {
            do {
                try data.write(to: url)
                Task { @MainActor in
                    self.isExporting = false; self.exportedFileURL = url
                    self.statusMessage = "Kitchen exported as JSON!"
                    completion(url)
                }
            } catch {
                Task { @MainActor in
                    self.isExporting = false
                    self.errorMessage = "Export failed: \(error.localizedDescription)"
                    completion(nil)
                }
            }
        }
    }

    // MARK: - Export: CSV (inventory + grocery), plain text, PDF
    // These are human-friendly / interoperable formats. CSV and TXT round-trip back via
    // importFromData; PDF is a printable snapshot (export-only).

    private func writeTempFile(_ string: String, name: String, completion: @escaping (URL?) -> Void) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try string.data(using: .utf8)?.write(to: url, options: .atomic)
            exportedFileURL = url
            completion(url)
        } catch {
            errorMessage = "Export failed: \(error.localizedDescription)"
            completion(nil)
        }
    }

    private func csvEscape(_ s: String) -> String {
        // Quote fields containing comma, quote, or newline; double internal quotes.
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    func exportToCSV(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        isExporting = true; statusMessage = ""; errorMessage = ""
        let inv = store.inventoryItems
        let gro = store.groceryItems
        var lines: [String] = []
        // A single CSV with a "Section" column so inventory + grocery both round-trip.
        lines.append("Section,Name,Quantity,ContainerType,SizeAmount,SizeUnit,Zone,ExpirationDate,Brand,Checked")
        let iso = ISO8601DateFormatter()
        for i in inv {
            let exp = i.expirationDate.map { iso.string(from: $0) } ?? ""
            lines.append([
                "Inventory", csvEscape(i.name), String(i.quantity), csvEscape(i.containerType),
                i.sizeAmount.map { String($0) } ?? "", csvEscape(i.sizeUnit ?? ""),
                csvEscape(i.zone), exp, csvEscape(i.brand ?? ""), ""
            ].joined(separator: ","))
        }
        for g in gro {
            lines.append([
                "Grocery", csvEscape(g.name), String(g.quantity), "", "", "", "", "", "",
                g.isChecked ? "yes" : "no"
            ].joined(separator: ","))
        }
        isExporting = false
        statusMessage = "Exported as CSV"
        Log.transfer.notice("Exported CSV: \(inv.count, privacy: .public) inventory, \(gro.count, privacy: .public) grocery")
        let dateStr = dateStamp()
        writeTempFile(lines.joined(separator: "\n"), name: "Stocked-Kitchen-\(dateStr).csv", completion: completion)
    }

    func exportToText(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        isExporting = true; statusMessage = ""; errorMessage = ""
        var out = "STOCKED KITCHEN — \(store.displayName)\nExported \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short))\n"
        out += "\n== PANTRY (\(store.inventoryItems.count)) ==\n"
        for i in store.inventoryItems {
            var line = "• \(i.name)"
            if let amt = i.sizeAmount, let unit = i.sizeUnit { line += " — \(i.quantity) × \(amt.clean) \(unit)" }
            else if i.quantity != 1 { line += " ×\(i.quantity)" }
            line += "  [\(i.zone)]"
            out += line + "\n"
        }
        out += "\n== GROCERY LIST (\(store.groceryItems.count)) ==\n"
        for g in store.groceryItems {
            out += "\(g.isChecked ? "[x]" : "[ ]") \(g.name)\(g.quantity != 1 ? " ×\(g.quantity)" : "")\n"
        }
        isExporting = false
        statusMessage = "Exported as text"
        writeTempFile(out, name: "Stocked-Kitchen-\(dateStamp()).txt", completion: completion)
    }

    func exportToPDF(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        isExporting = true; statusMessage = ""; errorMessage = ""
        // US Letter, simple typeset list with pagination.
        let pageW: CGFloat = 612, pageH: CGFloat = 792, margin: CGFloat = 48
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Stocked-Kitchen-\(dateStamp()).pdf")
        let titleAttr: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 22)]
        let headAttr:  [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 14)]
        let bodyAttr:  [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 12)]
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: pageW, height: pageH))
        do {
            try renderer.writePDF(to: url) { ctx in
                ctx.beginPage()
                var y: CGFloat = margin
                func draw(_ s: String, _ attr: [NSAttributedString.Key: Any], indent: CGFloat = 0) {
                    if y > pageH - margin { ctx.beginPage(); y = margin }
                    (s as NSString).draw(at: CGPoint(x: margin + indent, y: y), withAttributes: attr)
                    y += (attr[.font] as? UIFont).map { $0.lineHeight + 4 } ?? 18
                }
                draw("Stocked Kitchen — \(store.displayName)", titleAttr); y += 6
                draw("Pantry (\(store.inventoryItems.count))", headAttr)
                for i in store.inventoryItems {
                    var line = i.name
                    if let amt = i.sizeAmount, let unit = i.sizeUnit { line += " — \(i.quantity) × \(amt.clean) \(unit)" }
                    else if i.quantity != 1 { line += " ×\(i.quantity)" }
                    line += "  [\(i.zone)]"
                    draw(line, bodyAttr, indent: 12)
                }
                y += 8
                draw("Grocery List (\(store.groceryItems.count))", headAttr)
                for g in store.groceryItems {
                    draw("\(g.isChecked ? "☑" : "☐") \(g.name)\(g.quantity != 1 ? " ×\(g.quantity)" : "")", bodyAttr, indent: 12)
                }
            }
            exportedFileURL = url
            isExporting = false
            statusMessage = "Exported as PDF"
            completion(url)
        } catch {
            isExporting = false
            errorMessage = "PDF export failed: \(error.localizedDescription)"
            completion(nil)
        }
    }

    private func dateStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    // MARK: - Import from data (auto-detects format)
    func importFromData(_ data: Data, into store: GuestDataStore, merge: Bool = false) -> Bool {
        // CSV/plain-text first (content sniff), else JSON formats.
        if let text = String(data: data, encoding: .utf8) {
            let head = text.prefix(2000).lowercased()
            let looksJSON = head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("{")
                         || head.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("[")
            if !looksJSON {
                // Our CSV starts with "section,name,..."; generic CSV has commas + line breaks.
                if head.contains("section,name") || head.hasPrefix("name,") || head.contains("\"name\"") {
                    return importCSV(text, into: store, merge: merge)
                }
                if text.contains(",") && text.contains("\n") {
                    return importCSV(text, into: store, merge: merge)   // best-effort generic CSV
                }
                if text.contains("\n") {
                    return importPlainText(text, into: store, merge: merge)
                }
            }
        }
        let format = ImportFormat.detect(from: data)
        switch format {
        case .stocked:   return importStocked(data, into: store, merge: merge)
        case .anyList:   return importAnyList(data, into: store, merge: merge)
        case .paprika:   return importPaprika(data, into: store, merge: merge)
        case .mealime:   return importMealime(data, into: store, merge: merge)
        case .unknown:   return importStocked(data, into: store, merge: merge) // try native anyway
        }
    }

    // MARK: CSV import (round-trips our export; tolerant of generic name/quantity CSVs)
    private func importCSV(_ text: String, into store: GuestDataStore, merge: Bool) -> Bool {
        let rows = parseCSVRows(text)
        guard !rows.isEmpty else { errorMessage = "Could not read CSV file."; return false }

        // Map header → column index (case-insensitive). Supports our export schema and
        // simple "Name,Quantity[,Zone]" files.
        let header = rows[0].map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ names: [String]) -> Int? { for n in names { if let i = header.firstIndex(of: n) { return i } }; return nil }
        let secIdx  = col(["section"])
        let nameIdx = col(["name", "item", "product"])
        let qtyIdx  = col(["quantity", "qty", "count"])
        let contIdx = col(["containertype", "container"])
        let sizeAIdx = col(["sizeamount", "size", "amount"])
        let sizeUIdx = col(["sizeunit", "unit"])
        let zoneIdx = col(["zone", "storage", "category", "location"])
        let expIdx  = col(["expirationdate", "expires", "expiry"])
        let brandIdx = col(["brand"])
        let checkIdx = col(["checked", "ischecked", "done"])
        guard nameIdx != nil else { errorMessage = "CSV needs at least a Name column."; return false }

        var inv: [LocalInventoryItem] = []
        var gro: [LocalGroceryItem] = []
        let iso = ISO8601DateFormatter()
        for r in rows.dropFirst() {
            func cell(_ i: Int?) -> String { guard let i, i < r.count else { return "" }; return r[i].trimmingCharacters(in: .whitespaces) }
            let name = cell(nameIdx); if name.isEmpty { continue }
            let section = cell(secIdx).lowercased()
            if section == "grocery" {
                var g = LocalGroceryItem(name: name, isChecked: ["yes","true","1","x"].contains(cell(checkIdx).lowercased()))
                g.quantity = Int(cell(qtyIdx)) ?? 1
                gro.append(g)
            } else {
                var item = LocalInventoryItem(
                    name: name,
                    zone: cell(zoneIdx).isEmpty ? "Pantry" : cell(zoneIdx),
                    quantity: Int(cell(qtyIdx)) ?? 1,
                    containerType: cell(contIdx).isEmpty ? "item" : cell(contIdx),
                    sizeAmount: Double(cell(sizeAIdx)),
                    sizeUnit: cell(sizeUIdx).isEmpty ? nil : cell(sizeUIdx)
                )
                let exp = cell(expIdx)
                if !exp.isEmpty { item.expirationDate = iso.date(from: exp) }
                let brand = cell(brandIdx); if !brand.isEmpty { item.brand = brand }
                inv.append(item)
            }
        }

        Task { @MainActor in
            if merge {
                let existing = Set(store.inventoryItems.map { self.normKey($0.name) })
                store.inventoryItems += inv.filter { !existing.contains(self.normKey($0.name)) }
                let existingG = Set(store.groceryItems.map { self.normKey($0.name) })
                store.groceryItems += gro.filter { !existingG.contains(self.normKey($0.name)) }
            } else {
                if !inv.isEmpty { store.inventoryItems = inv }
                if !gro.isEmpty { store.groceryItems = gro }
            }
            self.statusMessage = "Imported \(inv.count) items, \(gro.count) grocery from CSV."
            Log.transfer.notice("CSV import: \(inv.count, privacy: .public) inventory, \(gro.count, privacy: .public) grocery")
        }
        return true
    }

    // Minimal RFC-4180-ish CSV parser (handles quoted fields, embedded commas/newlines).
    private func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []; var field = ""; var row: [String] = []
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i+1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r":
                    if c == "\r" && i + 1 < chars.count && chars[i+1] == "\n" { i += 1 }
                    row.append(field); field = ""
                    if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); if row.contains(where: { !$0.isEmpty }) { rows.append(row) } }
        return rows
    }

    // MARK: Plain-text import (one item per line; checkbox + ×qty + [zone] tolerated)
    private func importPlainText(_ text: String, into store: GuestDataStore, merge: Bool) -> Bool {
        var inv: [LocalInventoryItem] = []
        for raw in text.split(separator: "\n") {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            // Skip headers / section markers.
            let lower = line.lowercased()
            if lower.hasPrefix("==") || lower.hasPrefix("stocked kitchen") || lower.hasPrefix("exported") { continue }
            // Strip leading bullets/checkboxes.
            for prefix in ["• ", "- ", "[ ] ", "[x] ", "[X] ", "☐ ", "☑ ", "* "] {
                if line.hasPrefix(prefix) { line = String(line.dropFirst(prefix.count)); break }
            }
            // Pull a trailing [zone] if present.
            var zone = "Pantry"
            if let open = line.lastIndex(of: "["), let close = line.lastIndex(of: "]"), open < close {
                zone = String(line[line.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                line = String(line[..<open]).trimmingCharacters(in: .whitespaces)
            }
            // Pull a trailing ×N quantity.
            var qty = 1
            if let r = line.range(of: #"[×x]\s*(\d+)\s*$"#, options: .regularExpression) {
                qty = Int(line[r].filter(\.isNumber)) ?? 1
                line = String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            }
            // Drop a trailing " — size" descriptor for the name.
            if let dash = line.range(of: " — ") { line = String(line[..<dash.lowerBound]).trimmingCharacters(in: .whitespaces) }
            guard !line.isEmpty else { continue }
            inv.append(LocalInventoryItem(name: line, zone: ["fridge","freezer","pantry","staples"].contains(zone.lowercased()) ? zone.capitalized : "Pantry", quantity: qty))
        }
        guard !inv.isEmpty else { errorMessage = "No items found in text file."; return false }
        Task { @MainActor in
            if merge {
                let existing = Set(store.inventoryItems.map { self.normKey($0.name) })
                store.inventoryItems += inv.filter { !existing.contains(self.normKey($0.name)) }
            } else {
                store.inventoryItems = inv
            }
            self.statusMessage = "Imported \(inv.count) items from text."
            Log.transfer.notice("Text import: \(inv.count, privacy: .public) items")
        }
        return true
    }


    // MARK: Native .stocked / .json
    private func importStocked(_ data: Data, into store: GuestDataStore, merge: Bool) -> Bool {
        // Try the strict decode first (current-format backups). If that throws — which
        // happens when an OLDER backup is missing fields that are now required — fall back
        // to a lenient, field-by-field reconstruction so ANY past backup still restores.
        let snapshot: KitchenSnapshot
        if let strict = try? JSONDecoder().decode(KitchenSnapshot.self, from: data) {
            snapshot = strict
        } else if let lenient = Self.lenientSnapshot(from: data) {
            Log.transfer.notice("Backup restored via lenient decoder (older format)")
            snapshot = lenient
        } else {
            Task { @MainActor in self.errorMessage = "Import failed: unreadable backup file." }
            Log.transfer.error("Backup import failed: could not decode strictly or leniently")
            return false
        }

        Task { @MainActor in
            var addedCount = snapshot.inventoryItems.count   // full-restore default
            if merge {
                let existingNames = Set(store.inventoryItems.map { self.normKey($0.name) })
                let newInv = snapshot.inventoryItems.filter {
                    !existingNames.contains(self.normKey($0.name))
                }
                store.inventoryItems += newInv
                addedCount = newInv.count
                let existingGrocery = Set(store.groceryItems.map { self.normKey($0.name) })
                store.groceryItems += snapshot.groceryItems.filter {
                    !existingGrocery.contains(self.normKey($0.name))
                }
                if let recipes = snapshot.userRecipes {
                    let existingR = Set(store.userRecipes.map { self.normKey($0.title) })
                    store.userRecipes += recipes.filter { !existingR.contains(self.normKey($0.title)) }
                }
            } else {
                store.displayName    = snapshot.displayName
                store.inventoryItems = snapshot.inventoryItems
                store.groceryItems   = snapshot.groceryItems
                store.pastMeals      = snapshot.pastMeals
                if let recipes = snapshot.userRecipes { store.userRecipes = recipes }
            }
            // Restore preferences (theme, font, preferred store, etc.). Applied on both
            // merge and full restore — settings are the user's own, so bringing them back
            // is always the intent (e.g. auto-restore on sign-in).
            if let prefs = snapshot.preferences {
                self.session?.applyPreferences(prefs)
            }
            let total = snapshot.inventoryItems.count
            if merge && addedCount == 0 {
                self.statusMessage = "Already up to date — all \(total) items were already in your pantry."
            } else if merge {
                self.statusMessage = "Added \(addedCount) new item\(addedCount == 1 ? "" : "s") (\(total - addedCount) already present)."
            } else {
                self.statusMessage = "Imported \(total) item\(total == 1 ? "" : "s")."
            }
            self.isImporting = false
            // #10 — the apply above is a set of non-throwing assignments (full restore replaces
            // wholesale; merge is additive), so it's effectively all-or-nothing. Flush the
            // coalesced saves once here so the imported state lands as a single write pass
            // rather than trickling out via the debounce timer.
            store.flushPendingSaves()
            Log.transfer.notice("Backup imported: added=\(addedCount, privacy: .public)/\(total, privacy: .public), merge=\(merge, privacy: .public)")
        }
        return true
    }

    // MARK: AnyList JSON export
    // AnyList exports { "categories": [...], "items": [{ "name", "category", "quantity" }] }
    private func importAnyList(_ data: Data, into store: GuestDataStore, merge: Bool) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["items"] as? [[String: Any]]
        else { errorMessage = "Could not read AnyList file."; return false }

        let newItems = items.compactMap { obj -> LocalInventoryItem? in
            guard let name = obj["name"] as? String, !name.isEmpty else { return nil }
            let qty = obj["quantity"] as? Int ?? 1
            var item = LocalInventoryItem(name: name, quantity: qty)
            // AnyList stores category name — map to zone
            if let cat = obj["category"] as? String {
                item.storageCategory = ZoneClassifier.classify(cat)
            }
            return item
        }

        Task { @MainActor in
            if merge {
                let existing = Set(store.inventoryItems.map { self.normKey($0.name) })
                store.inventoryItems += newItems.filter { !existing.contains(self.normKey($0.name)) }
            } else {
                store.inventoryItems = newItems
            }
            self.statusMessage = "Imported \(newItems.count) items from AnyList."
        }
        return true
    }

    // MARK: Paprika Recipe Manager export
    // Paprika exports { "recipes": [{ "name", "ingredients", "directions", "prepTime", "cookTime", "servings" }] }
    private func importPaprika(_ data: Data, into store: GuestDataStore, merge: Bool) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let recipes = json["recipes"] as? [[String: Any]]
        else { errorMessage = "Could not read Paprika file."; return false }

        let newRecipes = recipes.compactMap { obj -> UserRecipe? in
            guard let name = obj["name"] as? String, !name.isEmpty else { return nil }
            let ingredients = (obj["ingredients"] as? String ?? "")
                .components(separatedBy: "\n")
                .compactMap { line -> RecipeIngredient? in
                    let t = line.trimmingCharacters(in: .whitespaces)
                    guard !t.isEmpty else { return nil }
                    return RecipeIngredient(name: t, amount: "")
                }
            let steps = (obj["directions"] as? String ?? "")
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var recipe = UserRecipe(title: name)
            recipe.ingredients  = ingredients
            recipe.instructions = steps
            recipe.cookTime     = obj["cookTime"]  as? String ?? ""
            recipe.prepTime     = obj["prepTime"]  as? String ?? ""
            let servingsRaw     = obj["servings"]  as? String ?? ""
            recipe.servings     = Int(servingsRaw.components(separatedBy: CharacterSet.decimalDigits.inverted).joined()) ?? 4
            recipe.notes        = obj["notes"] as? String ?? ""
            return recipe
        }

        Task { @MainActor in
            if merge {
                let existing = Set(store.userRecipes.map { self.normKey($0.title) })
                store.userRecipes += newRecipes.filter { !existing.contains(self.normKey($0.title)) }
            } else {
                store.userRecipes = newRecipes
            }
            self.statusMessage = "Imported \(newRecipes.count) recipes from Paprika."
        }
        return true
    }

    // MARK: Mealime meal plan export
    // Mealime exports { "mealPlan": [{ "title", "ingredients": [{ "name", "quantity" }] }] }
    private func importMealime(_ data: Data, into store: GuestDataStore, merge: Bool) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = (json["mealPlan"] ?? json["meal_plan"]) as? [[String: Any]]
        else { errorMessage = "Could not read Mealime file."; return false }

        var groceryItems: [LocalGroceryItem] = []
        var recipes: [UserRecipe] = []

        for meal in meals {
            let title = meal["title"] as? String ?? "Imported Meal"
            let ings  = meal["ingredients"] as? [[String: Any]] ?? []
            let ingredientItems = ings.compactMap { i -> RecipeIngredient? in
                guard let name = i["name"] as? String, !name.isEmpty else { return nil }
                let qty = i["quantity"] as? String ?? ""
                return RecipeIngredient(name: name, amount: qty)
            }
            // Add missing ingredients to grocery list
            let pantry = Set(store.inventoryItems.map { self.normKey($0.name) })
            for ing in ingredientItems where !pantry.contains(self.normKey(ing.name)) {
                groceryItems.append(LocalGroceryItem(name: ing.name, isChecked: false, recipeSource: title))
            }
            var recipe = UserRecipe(title: title)
            recipe.ingredients = ingredientItems
            recipes.append(recipe)
        }

        Task { @MainActor in
            if merge {
                let existing = Set(store.groceryItems.map { self.normKey($0.name) })
                store.groceryItems += groceryItems.filter { !existing.contains(self.normKey($0.name)) }
                let existingR = Set(store.userRecipes.map { self.normKey($0.title) })
                store.userRecipes += recipes.filter { !existingR.contains(self.normKey($0.title)) }
            } else {
                store.groceryItems = groceryItems
                store.userRecipes  = recipes
            }
            self.statusMessage = "Imported \(recipes.count) meals from Mealime. \(groceryItems.count) items added to grocery list."
        }
        return true
    }

    @discardableResult
    func importFromURL(_ url: URL, into store: GuestDataStore, merge: Bool = false) -> Bool {
        // Files picked from iCloud Drive / Files are security-scoped, and an iCloud file
        // saved on another day or device may still be a non-downloaded placeholder. The
        // download-wait + read can block, so we do it on a background task and apply the
        // result on the main actor. Returns true (work scheduled); status/errors surface
        // via statusMessage / errorMessage like the other importers.
        isImporting = true; errorMessage = ""
        let captured = url
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let scoped = captured.startAccessingSecurityScopedResource()
            defer { if scoped { captured.stopAccessingSecurityScopedResource() } }

            await self.ensureDownloaded(captured)

            var readData: Data?
            var coordError: NSError?
            NSFileCoordinator().coordinate(readingItemAt: captured, options: [], error: &coordError) { readURL in
                readData = try? Data(contentsOf: readURL)
            }

            guard let data = readData, !data.isEmpty else {
                let reason = coordError?.localizedDescription ?? "the file may still be downloading from iCloud"
                Log.transfer.error("Could not read backup file: \(reason, privacy: .public)")
                await MainActor.run {
                    self.isImporting = false
                    self.errorMessage = "Could not read file — \(reason). Try again once it finishes downloading."
                }
                return
            }
            await MainActor.run {
                self.isImporting = false
                _ = self.importFromData(data, into: store, merge: merge)
            }
        }
        return true
    }

    // Ask the system to download an iCloud file if it's only a placeholder locally,
    // then wait briefly (bounded) for it to materialize. Runs off the main thread.
    private nonisolated func ensureDownloaded(_ url: URL) async {
        let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
        if let status = values?.ubiquitousItemDownloadingStatus, status == .current { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            let v = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            if v?.ubiquitousItemDownloadingStatus == .current { return }
            if v?.ubiquitousItemDownloadingStatus == nil,
               FileManager.default.fileExists(atPath: url.path) { return }
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
    }

    // Import from a stocked://import?data=<base64url> deep link (Share Link feature).
    @discardableResult
    func importFromDeepLink(_ url: URL, into store: GuestDataStore, merge: Bool = false) -> Bool {
        guard url.scheme == "stocked",
              url.host == "import",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let raw   = comps.queryItems?.first(where: { $0.name == "data" })?.value else {
            errorMessage = "Invalid share link."; return false
        }
        // Reverse URL-safe base64 (base64url) and restore = padding.
        var b64 = raw.replacingOccurrences(of: "-", with: "+")
                     .replacingOccurrences(of: "_", with: "/")
        let pad = b64.count % 4
        if pad > 0 { b64 += String(repeating: "=", count: 4 - pad) }
        guard let data = Data(base64Encoded: b64) else {
            errorMessage = "Invalid share link."; return false
        }
        return importFromData(data, into: store, merge: merge)
    }

    // MARK: - QR Code Generation
    func generateQRCode(for store: GuestDataStore) {
        statusMessage = "Generating QR code…"; qrCodeImage = nil
        let snapshot = makeSnapshot(store: store)
        let encodedData = try? JSONEncoder().encode(snapshot)
        Task(priority: .userInitiated) {
            var jsonData: Data?
            if let data = encodedData, data.count < 2900 { jsonData = data }
            let qrString: String
            if let data = jsonData, let str = String(data: data, encoding: .utf8) {
                qrString = str
            } else {
                let items = snapshot.inventoryItems.prefix(20)
                    .map { "\($0.name):\(Int($0.level*100))%:\($0.zone)" }.joined(separator: "|")
                qrString = "STOCKED-KITCHEN|v1|\(snapshot.displayName)|\(items)"
            }
            let context = CIContext(); let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(qrString.utf8); filter.correctionLevel = "M"
            if let out = filter.outputImage {
                let scaled = out.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
                if let cg = context.createCGImage(scaled, from: scaled.extent) {
                    Task { @MainActor in
                        self.qrCodeImage   = UIImage(cgImage: cg)
                        self.statusMessage = "QR code ready"
                    }
                    return
                }
            }
            Task { @MainActor in self.errorMessage = "QR generation failed." }
        }
    }

    // MARK: - Share Link
    func generateShareLink(for store: GuestDataStore) -> URL? {
        let snapshot = makeSnapshot(store: store)
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        // URL-safe base64 (base64url): +→-, /→_, drop = padding. Reversed on import.
        let b64 = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return URL(string: "stocked://import?data=\(b64)")
    }

    // MARK: - iCloud Backup (MainActor — all state access is on main thread)
    func backupToiCloud(store: GuestDataStore) {
        guard !isBacking else { return }
        isBacking = true; statusMessage = "Backing up to iCloud…"; errorMessage = ""

        let snapshot   = makeSnapshot(store: store)
        let name       = store.displayName
        let deviceName = UIDevice.current.name
        guard let data = try? JSONEncoder().encode(snapshot) else {
            isBacking = false; errorMessage = "Backup encode failed."; return
        }

        Task { @MainActor in
            do {
                // Check iCloud availability before attempting save
                let status = try await cloudContainer.accountStatus()
                guard status == .available else {
                    isBacking = false
                    errorMessage = status == .noAccount
                        ? "No iCloud account signed in. Go to Settings → Sign in to your Apple ID."
                        : "iCloud not available."
                    return
                }
                // Build and save the record (stays on MainActor — record never crosses actors)
                let record = CKRecord(recordType: "KitchenBackup")
                record["displayName"] = name       as CKRecordValue
                record["backupData"]  = data       as CKRecordValue
                record["backedUpAt"]  = Date()      as CKRecordValue
                record["deviceName"]  = deviceName  as CKRecordValue

                _ = try await cloudContainer.privateCloudDatabase.save(record)
                isBacking = false
                statusMessage = "Backed up to iCloud ✓"
                iCloudStatus  = "Backed up \(DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .short))"
                UserDefaults.standard.set(Date(), forKey: "lastICloudBackup")
                // This device clearly holds current data — suppress the one-time new-device
                // auto-restore here so it won't re-pull what we just sent.
                UserDefaults.standard.set(true, forKey: "didAutoRestoreFromiCloud_v1")
            } catch {
                isBacking = false
                errorMessage = "iCloud backup failed: \(error.localizedDescription)"
            }
        }
    }

    // MARK: - iCloud Restore
    func restoreFromiCloud(into store: GuestDataStore, merge: Bool = false) {
        statusMessage = "Fetching from iCloud…"; errorMessage = ""

        Task { @MainActor in
            // Confirm the account is available first — a fresh device may not have finished
            // signing into iCloud yet, which otherwise looks like "no backup found."
            if let status = try? await cloudContainer.accountStatus(), status != .available {
                errorMessage = status == .noAccount
                    ? "No iCloud account signed in. Sign in to iCloud to restore your kitchen."
                    : "iCloud not available yet — try again in a moment."
                Log.transfer.notice("iCloud restore skipped: account not available")
                return
            }
            switch await fetchLatestICloudBackupResult() {
            case .failure(let error):
                let ck = error as? CKError
                errorMessage = ck?.code == .networkUnavailable || ck?.code == .networkFailure
                    ? "Network unavailable — connect to the internet and try again."
                    : "iCloud restore couldn't read your backups: \(error.localizedDescription)"
                Log.transfer.notice("iCloud restore: query FAILED — \(error.localizedDescription, privacy: .public)")
                return
            case .success(nil):
                errorMessage = "No iCloud backup found yet. Make a backup on your other device first, then try again here."
                Log.transfer.notice("iCloud restore: query succeeded but zero backups in this account/environment")
                return
            case .success(.some(let data)):
                let ok = importFromData(data, into: store, merge: merge)
                statusMessage = ok ? "Restored from iCloud ✓" : statusMessage
                Log.transfer.notice("iCloud restore \(ok ? "succeeded" : "failed", privacy: .public)")
            }
        }
    }

    /// Most-recent KitchenBackup data, resilient to CloudKit schema/sort limitations.
    /// Returns .success(data?) on a clean query (data may be nil = genuinely no backups),
    /// or .failure(error) when CloudKit itself errored — so callers can tell "no backups
    /// exist" apart from "the query failed", which previously both looked identical.
    private func fetchLatestICloudBackupResult() async -> Result<Data?, Error> {
        let db = cloudContainer.privateCloudDatabase

        // Attempt 1: sorted query (fast path when the field is sortable).
        let sorted = CKQuery(recordType: "KitchenBackup", predicate: NSPredicate(value: true))
        sorted.sortDescriptors = [NSSortDescriptor(key: "backedUpAt", ascending: false)]
        do {
            let (results, _) = try await db.records(matching: sorted, inZoneWith: nil,
                                                    desiredKeys: ["backupData"], resultsLimit: 1)
            if let first = results.first, case .success(let record) = first.1,
               let data = record["backupData"] as? Data {
                return .success(data)
            }
            // Sorted query succeeded but returned nothing — fall through to the broad fetch
            // before concluding there are genuinely no backups.
        } catch {
            // Sorted query errored (often: field not sortable in this environment). Don't
            // give up — try the unsorted fetch, and only report THIS error if that fails too.
            Log.transfer.notice("iCloud restore: sorted query failed (\(error.localizedDescription, privacy: .public)) — trying unsorted")
        }

        // Attempt 2: unsorted fetch, choose newest by backedUpAt in code.
        let plain = CKQuery(recordType: "KitchenBackup", predicate: NSPredicate(value: true))
        do {
            let (results, _) = try await db.records(matching: plain, inZoneWith: nil,
                                                    desiredKeys: ["backupData", "backedUpAt"],
                                                    resultsLimit: 50)
            var newestDate = Date.distantPast
            var newestData: Data?
            for (_, res) in results {
                guard case .success(let record) = res,
                      let data = record["backupData"] as? Data else { continue }
                let when = (record["backedUpAt"] as? Date) ?? Date.distantPast
                if newestData == nil || when >= newestDate { newestDate = when; newestData = data }
            }
            return .success(newestData)   // newestData == nil ⇒ genuinely no backups
        } catch {
            return .failure(error)        // a real CloudKit failure — surface it
        }
    }

    // MARK: - New-device auto-restore (once per install)
    // Called on launch. If this install has never auto-restored AND iCloud is available,
    // pull the latest backup in MERGE mode so a fresh device repopulates inventory +
    // preferences without wiping local data. Sign-in restore still covers Apple auth.
    @MainActor
    static func autoRestoreOnNewDeviceIfNeeded(into session: AppSession) {
        let flagKey = "didAutoRestoreFromiCloud_v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        let mgr = session.transferManager   // retained — async task won't be orphaned
        mgr.isCheckingForExistingAccount = true   // RootView shows splash while this runs
        Task { @MainActor in
            defer { mgr.isCheckingForExistingAccount = false }
            guard let status = try? await mgr.cloudContainer.accountStatus(),
                  status == .available else {
                Log.transfer.notice("Auto-restore deferred: iCloud not available yet")
                return   // leave flag unset so we retry on a later launch
            }
            switch await mgr.fetchLatestICloudBackupResult() {
            case .success(.some(let data)):
                let ok = mgr.importFromData(data, into: session.guestStore, merge: true)
                Log.transfer.notice("Auto-restored kitchen from iCloud on new device")
                UserDefaults.standard.set(true, forKey: flagKey)
                // This Apple ID has used Stocked before — restore their data AND skip onboarding.
                // Returning users shouldn't have to retake the setup quiz.
                if ok { session.guestStore.quizCompleted = true }
            case .success(nil):
                Log.transfer.notice("Auto-restore: no iCloud backup to restore")
                UserDefaults.standard.set(true, forKey: flagKey)
            case .failure(let error):
                // Don't set the flag — a transient/query error should let us retry next launch.
                Log.transfer.notice("Auto-restore query failed — \(error.localizedDescription, privacy: .public); will retry next launch")
            }
        }
    }

    // MARK: - Device Backup (saves .stocked file to Files app)
    func backupToDevice(store: GuestDataStore, completion: @escaping (URL?) -> Void) {
        let snapshot = makeSnapshot(store: store)
        guard let data = try? JSONEncoder().encode(snapshot) else {
            completion(nil); return
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let name = "Stocked_Backup_\(formatter.string(from: Date())).stocked"
        let url  = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
            exportedFileURL = url
            statusMessage   = "Ready to save to Files"
            completion(url)
        } catch {
            errorMessage = "Device backup failed: \(error.localizedDescription)"
            completion(nil)
        }
    }

    var lastBackupDate: String {
        guard let date = UserDefaults.standard.object(forKey: "lastICloudBackup") as? Date else {
            return "Never"
        }
        return DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}

// MARK: - Lenient backup decoding (backward compatibility)
// Reconstructs a KitchenSnapshot from ANY older/partial backup JSON. Each field is read
// with a safe default, and per-element decoding so one bad record can't fail the whole
// restore. Used only when the strict Codable decode throws.
extension KitchenTransferManager {

    nonisolated static func lenientSnapshot(from data: Data) -> KitchenSnapshot? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        let displayName = (root["displayName"] as? String) ?? "My Kitchen"
        let invArr      = (root["inventoryItems"] as? [[String: Any]]) ?? []
        let groArr      = (root["groceryItems"]   as? [[String: Any]]) ?? []
        let mealArr     = (root["pastMeals"]      as? [[String: Any]]) ?? []
        let recArr      = (root["userRecipes"]    as? [[String: Any]]) ?? []

        let inventory = invArr.compactMap { lenientInventoryItem($0) }
        let grocery   = groArr.compactMap { lenientGroceryItem($0) }
        let meals     = mealArr.compactMap { lenientPastMeal($0) }
        let recipes   = recArr.compactMap { lenientUserRecipe($0) }

        // Preferences: try strict decode of just that sub-object; default if absent.
        var prefs: KitchenPreferences? = nil
        if let prefDict = root["preferences"] as? [String: Any],
           let pData = try? JSONSerialization.data(withJSONObject: prefDict) {
            prefs = try? JSONDecoder().decode(KitchenPreferences.self, from: pData)
        }

        var snap = KitchenSnapshot(displayName: displayName, inventoryItems: inventory,
                                   groceryItems: grocery, pastMeals: meals,
                                   userRecipes: recipes.isEmpty ? nil : recipes,
                                   preferences: prefs)
        snap.pastMeals = meals
        return snap
    }

    private nonisolated static func lenientInventoryItem(_ d: [String: Any]) -> LocalInventoryItem? {
        guard let name = d["name"] as? String, !name.isEmpty else { return nil }
        let zone = (d["storageCategory"] as? String) ?? (d["zone"] as? String) ?? "Pantry"
        var item = LocalInventoryItem(
            name: name,
            level: (d["level"] as? Double) ?? 1.0,
            zone: zone,
            quantity: (d["quantity"] as? Int) ?? 1,
            containerType: (d["containerType"] as? String) ?? "item",
            sizeAmount: d["sizeAmount"] as? Double,
            sizeUnit: d["sizeUnit"] as? String
        )
        item.quantityUsed = d["quantityUsed"] as? Double
        item.brand        = d["brand"] as? String
        item.price        = d["price"] as? Double
        item.storePurchasedAt = d["storePurchasedAt"] as? String
        item.isLeftover   = (d["isLeftover"] as? Bool) ?? false
        item.leftoverMeal = d["leftoverMeal"] as? String
        item.hasStash     = (d["hasStash"] as? Bool) ?? false
        // expirationDate may be ISO string or epoch number depending on backup age.
        if let iso = d["expirationDate"] as? String {
            item.expirationDate = ISO8601DateFormatter().date(from: iso)
        } else if let epoch = d["expirationDate"] as? Double {
            item.expirationDate = Date(timeIntervalSinceReferenceDate: epoch)
        }
        return item
    }

    private nonisolated static func lenientGroceryItem(_ d: [String: Any]) -> LocalGroceryItem? {
        guard let name = d["name"] as? String, !name.isEmpty else { return nil }
        var item = LocalGroceryItem(name: name, isChecked: (d["isChecked"] as? Bool) ?? false)
        item.quantity      = (d["quantity"] as? Int) ?? 1
        item.isRecommended = (d["isRecommended"] as? Bool) ?? false
        item.recipeSource  = (d["recipeSource"] as? String) ?? ""
        return item
    }

    private nonisolated static func lenientPastMeal(_ d: [String: Any]) -> LocalPastMeal? {
        guard let title = d["title"] as? String, !title.isEmpty else { return nil }
        let date = (d["date"] as? String) ?? ""
        var meal = LocalPastMeal(title: title, date: date)
        meal.rating  = (d["rating"] as? Int) ?? 0
        meal.thumbUp = (d["thumbUp"] as? Bool) ?? true
        meal.notes   = (d["notes"] as? String) ?? ""
        return meal
    }

    private nonisolated static func lenientUserRecipe(_ d: [String: Any]) -> UserRecipe? {
        guard let title = d["title"] as? String, !title.isEmpty else { return nil }
        var r = UserRecipe(title: title)
        r.description  = (d["description"] as? String) ?? ""
        r.cookTime     = (d["cookTime"] as? String) ?? ""
        r.prepTime     = (d["prepTime"] as? String) ?? ""
        r.servings     = (d["servings"] as? Int) ?? 4
        r.difficulty   = (d["difficulty"] as? String) ?? "Medium"
        r.cuisine      = (d["cuisine"] as? String) ?? ""
        r.tags         = (d["tags"] as? [String]) ?? []
        r.instructions = (d["instructions"] as? [String]) ?? []
        r.notes        = (d["notes"] as? String) ?? ""
        r.imageURL     = d["imageURL"] as? String
        r.isFavorited  = (d["isFavorited"] as? Bool) ?? false
        // Ingredients: re-encode the sub-array and decode strictly (it's small + low-risk).
        if let ingArr = d["ingredients"] as? [[String: Any]],
           let iData = try? JSONSerialization.data(withJSONObject: ingArr),
           let ings = try? JSONDecoder().decode([RecipeIngredient].self, from: iData) {
            r.ingredients = ings
        } else if let names = d["ingredients"] as? [String] {
            // Very old backups may store ingredients as plain strings.
            r.ingredients = names.map { RecipeIngredient(name: $0, amount: "") }
        }
        return r
    }
}
