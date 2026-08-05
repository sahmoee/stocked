// RecipeCatalogImportView.swift — Mac Catalyst admin tool for bulk-importing the
// Epicurious/archive recipe CSV into the Worker KV catalog so all users get the
// full recipe dataset.
//
// Flow:
//   1. Pick the CSV file ("Food Ingredients and Recipe Dataset with Image Name Mapping.csv")
//   2. Tap "Import to Catalog" — parses the CSV on a background thread then uploads
//      100-recipe pages to POST /admin/catalog/chunk on the Worker.
//   3. Worker stores pages in the CROWD KV namespace (catalog:page:N keys) and the
//      GET /content/recipes route begins serving them, rotating every 6 hours.
//
// Images: upload the "Food Images" folder to CPanel at /content/img/recipes/ so the
// image proxy (/content/img/recipes/{Image_Name}.jpg) resolves them.

import SwiftUI
import UniformTypeIdentifiers

#if targetEnvironment(macCatalyst)

struct RecipeCatalogImportView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var csvURL: URL?
    @State private var phase: ImportPhase = .idle
    @State private var progress: Double = 0
    @State private var statusLine = ""
    @State private var showFilePicker = false
    @State private var pagesDone = 0
    @State private var pagesTotal = 0

    enum ImportPhase { case idle, parsing, uploading, done, failed }

    var body: some View {
        NavigationStack {
            Form {
                Section("CSV File") {
                    if let url = csvURL {
                        Label(url.lastPathComponent, systemImage: "doc.text.fill")
                            .foregroundStyle(.primary)
                        Button("Change File") { showFilePicker = true }
                            .disabled(phase == .parsing || phase == .uploading)
                    } else {
                        Button {
                            showFilePicker = true
                        } label: {
                            Label("Pick Recipe CSV…", systemImage: "folder.badge.plus")
                        }
                    }
                }

                if csvURL != nil && (phase == .idle || phase == .done || phase == .failed) {
                    Section {
                        Button(action: startImport) {
                            Label("Import to Worker Catalog", systemImage: "arrow.up.doc.fill")
                        }
                    }
                }

                if phase == .parsing || phase == .uploading {
                    Section("Progress") {
                        ProgressView(value: progress)
                        Text(statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if phase == .done {
                    Section {
                        Label(statusLine, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Catalog is live. All users receive the new recipes on their next app open (6-hour edge cache).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if phase == .failed {
                    Section {
                        Label(statusLine, systemImage: "xmark.circle.fill")
                            .foregroundStyle(.red)
                    }
                }

                Section("How it works") {
                    Text("Reads the recipe CSV, converts each row to RemoteRecipe format, and uploads 100-recipe pages to the Worker via POST /admin/catalog/chunk. The Worker stores them in KV and begins rotating through all pages every 6 hours — so every Stocked user sees different recipes each day.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Images: separately upload the \"Food Images\" folder to your CPanel hosting at /content/img/recipes/ so the image proxy resolves them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Recipe Catalog Import")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.commaSeparatedText, .text, UTType(filenameExtension: "csv") ?? .data]
        ) { result in
            if case .success(let url) = result {
                csvURL = url
                phase = .idle
                statusLine = ""
                progress = 0
            }
        }
    }

    // MARK: - Import

    private func startImport() {
        guard let url = csvURL else { return }
        phase = .parsing
        progress = 0
        statusLine = "Parsing CSV…"
        pagesDone = 0
        pagesTotal = 0

        Task {
            await runImport(url: url)
        }
    }

    private func runImport(url: URL) async {
        // 1. Parse
        let recipes: [CatalogRecipe]
        do {
            recipes = try await Task.detached(priority: .userInitiated) { @Sendable in
                try parseCatalogCSV(url: url)
            }.value
        } catch {
            await update { phase = .failed; statusLine = "Parse failed: \(error.localizedDescription)" }
            return
        }

        guard !recipes.isEmpty else {
            await update { phase = .failed; statusLine = "No recipes found in CSV." }
            return
        }

        // 2. Split into pages of 100
        let pageSize = 100
        let pages: [[CatalogRecipe]] = stride(from: 0, to: recipes.count, by: pageSize).map {
            Array(recipes[$0..<min($0 + pageSize, recipes.count)])
        }
        let totalPages = pages.count
        let totalRecipes = recipes.count

        await update {
            pagesTotal = totalPages
            phase = .uploading
            statusLine = "Uploading page 1 of \(totalPages)…"
        }

        // 3. Upload each page
        guard let workerBase = URL(string: BuildConfig.receiptWorkerURL) else {
            await update { phase = .failed; statusLine = "Worker URL not configured." }
            return
        }
        let endpoint = workerBase.appendingPathComponent("admin/catalog/chunk")

        for (i, page) in pages.enumerated() {
            let payload = CatalogChunk(page: i, totalPages: totalPages,
                                       totalRecipes: totalRecipes, recipes: page)
            do {
                var req = URLRequest(url: endpoint, timeoutInterval: 30)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                BuildConfig.authorizeWorkerRequest(&req)
                req.httpBody = try JSONEncoder().encode(payload)
                let (_, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                guard (200...299).contains(code) else {
                    await update {
                        phase = .failed
                        statusLine = "Upload failed at page \(i + 1) — HTTP \(code)."
                    }
                    return
                }
            } catch {
                await update {
                    phase = .failed
                    statusLine = "Upload failed at page \(i + 1): \(error.localizedDescription)"
                }
                return
            }

            let frac = Double(i + 1) / Double(totalPages)
            await update {
                pagesDone = i + 1
                progress = frac
                statusLine = "Uploaded page \(i + 1) of \(totalPages) · \((i + 1) * pageSize) recipes"
            }
        }

        await update {
            progress = 1
            phase = .done
            statusLine = "Done — \(totalRecipes) recipes in \(totalPages) pages uploaded."
        }
    }

    @MainActor
    private func update(_ block: () -> Void) {
        block()
    }
}

// MARK: - Catalog data types

private struct CatalogRecipe: Codable, Sendable {
    let id: String
    let title: String
    let image: String
    let ingredients: [String]
    let measures: [String]
    let instructions: String
    let category: String
    let area: String
}

private struct CatalogChunk: Codable {
    let page: Int
    let totalPages: Int
    let totalRecipes: Int
    let recipes: [CatalogRecipe]
}

// MARK: - CSV parsing

private func parseCatalogCSV(url: URL) throws -> [CatalogRecipe] {
    let accessed = url.startAccessingSecurityScopedResource()
    defer { if accessed { url.stopAccessingSecurityScopedResource() } }

    let text = try String(contentsOf: url, encoding: .utf8)
    let rows = parseCSV(text)

    guard let header = rows.first else { return [] }
    let col: (String) -> Int? = { name in header.firstIndex(of: name) }

    let titleIdx   = col("Title")
    let ingrIdx    = col("Ingredients")
    let cleanIdx   = col("Cleaned_Ingredients")
    let instrIdx   = col("Instructions")
    let imageIdx   = col("Image_Name")

    return rows.dropFirst().enumerated().compactMap { (i, row) in
        guard let t = titleIdx, t < row.count else { return nil }
        let title = row[t].trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return nil }

        let rawIngr   = ingrIdx.flatMap  { $0 < row.count ? row[$0] : nil } ?? ""
        let cleanIngr = cleanIdx.flatMap { $0 < row.count ? row[$0] : nil } ?? ""
        let ingredients = parsePythonList(cleanIngr.isEmpty ? rawIngr : cleanIngr)

        let instructions = (instrIdx.flatMap { $0 < row.count ? row[$0] : nil } ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imageName = imageIdx.flatMap { $0 < row.count ? row[$0] : nil } ?? ""
        let imageRelPath = imageName.isEmpty ? "" : "img/recipes/\(imageName).jpg"

        return CatalogRecipe(
            id: "arc-\(String(format: "%05d", i + 1))",
            title: title,
            image: imageRelPath,
            ingredients: ingredients,
            measures: [],
            instructions: instructions,
            category: "",
            area: ""
        )
    }
}

private func parsePythonList(_ raw: String) -> [String] {
    var s = raw.trimmingCharacters(in: .whitespaces)
    guard s.hasPrefix("[") && s.hasSuffix("]") else {
        return s.isEmpty ? [] : [s]
    }
    s = String(s.dropFirst().dropLast())
    var results: [String] = []
    var current = ""
    var inString = false
    var quoteChar: Character = "'"
    for c in s {
        if inString {
            if c == quoteChar {
                let v = current.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { results.append(v) }
                current = ""
                inString = false
            } else {
                current.append(c)
            }
        } else if c == "'" || c == "\"" {
            inString = true
            quoteChar = c
        }
    }
    return results
}

// RFC 4180 CSV parser — handles quoted fields with embedded newlines and commas.
private func parseCSV(_ text: String) -> [[String]] {
    var rows: [[String]] = []
    var row: [String] = []
    var field = ""
    var inQuotes = false
    var i = text.startIndex

    while i < text.endIndex {
        let c = text[i]
        let next = text.index(after: i)

        if inQuotes {
            if c == "\"" && next < text.endIndex && text[next] == "\"" {
                field.append("\"")
                i = text.index(after: next)
                continue
            } else if c == "\"" {
                inQuotes = false
            } else {
                field.append(c)
            }
        } else {
            switch c {
            case "\"":
                inQuotes = true
            case ",":
                row.append(field); field = ""
            case "\r":
                row.append(field); field = ""
                rows.append(row); row = []
                if next < text.endIndex && text[next] == "\n" {
                    i = text.index(after: next); continue
                }
            case "\n":
                row.append(field); field = ""
                rows.append(row); row = []
            default:
                field.append(c)
            }
        }
        i = next
    }

    if !field.isEmpty || !row.isEmpty {
        row.append(field)
        rows.append(row)
    }

    return rows
}

#endif
