// InventoryExporter.swift — #13 Backup / export.
//
// Self-contained: reads the persisted stores directly via minimal Codable DTOs (same pattern as
// the App Intents reader), so it doesn't depend on the live session and can't regress existing
// types. Produces CSV text for the inventory and the grocery list, writes them to temporary
// files, and offers a SwiftUI share sheet. Nothing here edits existing files.

import SwiftUI
import UniformTypeIdentifiers

#if canImport(UIKit)
import UIKit
#endif

enum InventoryExporter {

    // MARK: DTOs mirroring the persisted shapes (decode-only; defaults guard missing fields)

    private struct InvDTO: Codable {
        var name: String = ""
        var quantity: Int = 1
        var containerType: String = "item"
        var storageCategory: String = ""
        var expirationDate: Date?
    }
    private struct GroceryDTO: Codable {
        var name: String = ""
        var quantity: Int = 1
        var isChecked: Bool = false
    }

    private static let invKey = "inventory_items"   // DBKey.inventoryItems
    private static let groKey = "grocery_items"     // DBKey.groceryItems

    // MARK: CSV builders

    private static func csvField(_ s: String) -> String {
        // Quote if the field contains comma, quote, or newline; double internal quotes.
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    /// Inventory as CSV. Columns: Name, Quantity, Container, Zone, Expires.
    static func inventoryCSV() -> String {
        var rows = ["Name,Quantity,Container,Zone,Expires"]
        let fmt = ISO8601DateFormatter(); fmt.formatOptions = [.withFullDate]
        if let data = UserDefaults.standard.data(forKey: invKey),
           let items = try? JSONDecoder().decode([InvDTO].self, from: data) {
            for it in items {
                let exp = it.expirationDate.map { fmt.string(from: $0) } ?? ""
                rows.append([
                    csvField(it.name),
                    String(it.quantity),
                    csvField(it.containerType),
                    csvField(it.storageCategory),
                    exp
                ].joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n")
    }

    /// Grocery list as CSV. Columns: Item, Quantity, Checked.
    static func groceryCSV() -> String {
        var rows = ["Item,Quantity,Checked"]
        if let data = UserDefaults.standard.data(forKey: groKey),
           let items = try? JSONDecoder().decode([GroceryDTO].self, from: data) {
            for it in items {
                rows.append([csvField(it.name), String(it.quantity), it.isChecked ? "yes" : "no"]
                    .joined(separator: ","))
            }
        }
        return rows.joined(separator: "\n")
    }

    // MARK: File writing

    /// Writes a CSV string to a temp file and returns its URL (for sharing).
    static func writeTempFile(_ text: String, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do { try text.data(using: .utf8)?.write(to: url, options: .atomic); return url }
        catch { return nil }
    }

    /// Convenience: both exports as file URLs, dated.
    static func exportFiles() -> [URL] {
        let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
        var urls: [URL] = []
        if let u = writeTempFile(inventoryCSV(), name: "Stocked-Inventory-\(stamp).csv") { urls.append(u) }
        if let u = writeTempFile(groceryCSV(), name: "Stocked-Grocery-\(stamp).csv") { urls.append(u) }
        return urls
    }
}

// MARK: - Share sheet wrapper (UIKit-backed)

#if canImport(UIKit)
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
#endif

// MARK: - Drop-in export button (use anywhere, e.g. Settings)
// Add `ExportDataButton()` to a settings screen. Self-contained; no changes to existing views.

struct ExportDataButton: View {
    @State private var showShare = false
    @State private var shareItems: [Any] = []

    var body: some View {
        Button {
            shareItems = InventoryExporter.exportFiles()
            showShare = !shareItems.isEmpty
        } label: {
            Label("Export inventory & grocery list (CSV)", systemImage: "square.and.arrow.up")
        }
        #if canImport(UIKit)
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
        #endif
    }
}
