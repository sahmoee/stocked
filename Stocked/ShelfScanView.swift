// ShelfScanView.swift — Overall improvement #13: add items from a photo of a shelf.
//
// Bulk entry is the biggest chore in any pantry app. The app already has on-device text
// recognition (RecipeOCR, Vision). Point it at a shelf photo, pull out the label lines, let the
// user confirm which are real items, and drop them straight into inventory. No new ML, no network.

import SwiftUI
import PhotosUI

struct ShelfScanView: View {
    @Environment(AppSession.self) private var session
    @State private var photo: PhotosPickerItem?
    @State private var candidates: [String] = []
    @State private var picked: Set<String> = []
    @State private var loading = false
    @State private var scanned = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Take or pick a clear photo of a shelf or a group of items. Stocked reads the labels and lets you confirm what to add.")
                    .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.6))

                PhotosPicker(selection: $photo, matching: .images) {
                    Label(scanned ? "Choose another photo" : "Choose a photo", systemImage: "camera.viewfinder")
                        .scaledFont(15, weight: .semibold)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(session.accentColor).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                if loading {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading labels…")
                        .scaledFont(13).foregroundStyle(session.themeSecondaryText) }
                }

                if scanned && candidates.isEmpty && !loading {
                    Text("Couldn't make out any item names. Try a closer, better-lit photo with the labels facing the camera.")
                        .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.5))
                }

                if !candidates.isEmpty {
                    Text("Tap to include or exclude, then add.").scaledFont(12)
                        .foregroundStyle(session.themeSecondaryText)
                    ForEach(candidates, id: \.self) { name in
                        Button { toggle(name) } label: {
                            HStack {
                                Image(systemName: picked.contains(name) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked.contains(name) ? session.accentColor : session.themeSecondaryText)
                                Text(name.capitalized).scaledFont(15).foregroundStyle(session.themeTextColor)
                                Spacer()
                            }
                            .padding(.vertical, 10).padding(.horizontal, 12)
                            .background(session.themeTextColor.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                        .buttonStyle(.plain)
                    }

                    Button(action: addPicked) {
                        Text(picked.isEmpty ? "Select some items" : "Add \(picked.count) to inventory")
                            .scaledFont(15, weight: .semibold)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(picked.isEmpty ? Color.gray.opacity(0.3) : session.accentColor)
                            .foregroundStyle(.white).clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain).disabled(picked.isEmpty).padding(.top, 4)
                }
            }
            .padding(18)
        }
        .stockedScreen()
        .navigationTitle("Scan a Shelf")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: photo) { _, newValue in
            guard let newValue else { return }
            Task { await scan(newValue) }
        }
    }

    private func toggle(_ name: String) {
        if picked.contains(name) { picked.remove(name) } else { picked.insert(name) }
    }

    private func addPicked() {
        let toAdd = candidates.filter { picked.contains($0) }
        for name in toAdd { session.guestStore.addInventoryItem(LocalInventoryItem(name: name)) }
        ToastCenter.shared.success("Added \(toAdd.count) item\(toAdd.count == 1 ? "" : "s")")
        HapticManager.success()
        candidates.removeAll(); picked.removeAll(); scanned = false; photo = nil
    }

    private func scan(_ item: PhotosPickerItem) async {
        loading = true; scanned = true; candidates = []; picked = []
        defer { loading = false }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        let text = await RecipeOCR.recognizeText(in: image)
        let cleaned = ShelfScanView.itemLines(from: text)
        candidates = cleaned
        picked = Set(cleaned)          // default everything on; user prunes
    }

    /// Reduce raw OCR into plausible item names: reject prices, quantities, and noise.
    nonisolated static func itemLines(from raw: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for lineSub in raw.split(whereSeparator: \.isNewline) {
            let line = lineSub.trimmingCharacters(in: .whitespaces)
            let letters = line.filter { $0.isLetter }.count
            guard line.count >= 3, line.count <= 28, letters >= 3 else { continue }
            // Mostly-letters (labels), not receipts/prices.
            let digits = line.filter { $0.isNumber }.count
            guard Double(digits) <= Double(line.count) * 0.4 else { continue }
            guard !line.contains("$"), !line.lowercased().contains("total") else { continue }
            let norm = line.lowercased()
            if seen.insert(norm).inserted { out.append(line) }
            if out.count >= 24 { break }
        }
        return out
    }
}
