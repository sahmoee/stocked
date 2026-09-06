// RecipeCSV.swift — recipes in and out as a spreadsheet, and out in bulk.
//
// The vault holds thousands of recipes and the only way to remove one was a context menu.
// This is the bulk door: export every recipe as a CSV, open it anywhere, mark the ones you
// want gone in the `remove` column, hand the file back, confirm the list, done.
//
// Two things about this file are deliberate and should not be "cleaned up":
//
//  1. It carries its own CSV parser/escaper rather than calling into KitchenTransferManager.
//     Those helpers are `private` there, and the Mac app — which has no KitchenTransferManager
//     at all — needs byte-identical behaviour so a file marked up on one device removes exactly
//     the same recipes on the other. StockedMac/Core/MacRecipeCSV.swift is the twin of this
//     file. Change one, change both.
//
//  2. Removal assigns `store.userRecipes` / `store.savedGeneratedRecipes` ONCE, as a whole
//     array. Those properties have `didSet` observers that diff old against new and record
//     household tombstones for whatever disappeared. Mutating in place, or calling
//     deleteUserRecipe(id:) in a loop, either skips the tombstones — in which case the next
//     household pull cheerfully puts every deleted recipe back — or fires N pushes for one
//     user action. One assignment. That's the whole trick.

import SwiftUI
import UniformTypeIdentifiers
import os

// MARK: - Model

enum RecipeCSVLibrary: String, Codable, Sendable {
    case mine       // UserRecipe — the recipes you wrote or saved into the vault
    case saved      // GeneratedRecipe — the ones the app produced and you kept
}

/// One row of the file, parsed but not yet matched against anything.
struct RecipeCSVRow: Identifiable, Sendable {
    let id = UUID()
    var library: RecipeCSVLibrary?      // nil = the file didn't say; search both
    var recipeID: UUID?
    var title: String
    var markedForRemoval: Bool
    var lineNumber: Int
}

/// A recipe a row might be referring to.
struct RecipeCSVCandidate: Identifiable, Sendable {
    let id: UUID
    var title: String
    var detail: String
    var library: RecipeCSVLibrary
}

/// A row after matching. One candidate is a clean hit; several is ambiguous and needs a
/// person; none means the row named something that isn't here.
struct RecipeCSVMatch: Identifiable, Sendable {
    let id = UUID()
    var row: RecipeCSVRow
    var candidates: [RecipeCSVCandidate]
    var matchedByID: Bool

    var isAmbiguous: Bool { candidates.count > 1 }
    var isUnmatched: Bool { candidates.isEmpty }
    var isClean: Bool { candidates.count == 1 }
}

/// What a parse produced, before anyone has been asked anything.
struct RecipeCSVPlan: Sendable {
    var matches: [RecipeCSVMatch] = []
    var totalDataRows: Int = 0
    var hadRemoveColumn: Bool = false
    var parseError: String?

    var clean: [RecipeCSVMatch]     { matches.filter(\.isClean) }
    var ambiguous: [RecipeCSVMatch] { matches.filter(\.isAmbiguous) }
    var unmatched: [RecipeCSVMatch] { matches.filter(\.isUnmatched) }
}

// MARK: - RecipeCSV

enum RecipeCSV {

    // MARK: Shared text helpers
    // Kept identical to KitchenTransferManager's private versions and to MacRecipeCSV's copy.

    /// Quote fields containing comma, quote, or newline; double internal quotes.
    static func csvEscape(_ s: String) -> String {
        if s.contains(",") || s.contains("\"") || s.contains("\n") {
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return s
    }

    /// Trims, lowercases, and collapses internal whitespace so "Chicken Pot Pie",
    /// "chicken pot pie " and "Chicken  Pot  Pie" are all the same recipe.
    static func normKey(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// Minimal RFC-4180-ish CSV parser (handles quoted fields, embedded commas/newlines).
    static func parseCSVRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []; var field = ""; var row: [String] = []
        var inQuotes = false
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 }
                    else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\n", "\r":
                    if c == "\r" && i + 1 < chars.count && chars[i + 1] == "\n" { i += 1 }
                    row.append(field); field = ""
                    if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                        rows.append(row)
                    }
                    row = []
                default: field.append(c)
                }
            }
            i += 1
        }
        row.append(field)
        if row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) { rows.append(row) }
        return rows
    }

    private static let truthy: Set<String> = ["yes", "y", "true", "1", "x", "✓", "remove", "delete"]

    // MARK: Export

    /// The header every Stocked recipe CSV carries. `remove` is written empty so the
    /// mark-the-ones-you-want-gone workflow is the one people fall into by default.
    static let header = "library,id,title,cuisine,category,tags,source,created,remove"

    @MainActor
    static func exportCSV(store: GuestDataStore) -> String {
        var lines: [String] = [header]
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"

        for r in store.userRecipes {
            lines.append([
                "mine",
                r.id.uuidString,
                csvEscape(r.title),
                csvEscape(r.cuisine),
                csvEscape(r.dishRole == .unspecified ? "" : String(describing: r.dishRole)),
                csvEscape(r.tags.joined(separator: "|")),
                csvEscape(r.imageURL ?? ""),
                day.string(from: r.dateCreated),
                ""
            ].joined(separator: ","))
        }

        for r in store.savedGeneratedRecipes {
            lines.append([
                "saved",
                r.id.uuidString,
                csvEscape(r.title),
                "",
                csvEscape(r.mealCategory),
                "",
                csvEscape(r.imageURL ?? ""),
                "",
                ""
            ].joined(separator: ","))
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Writes the export to a temp file ready for a share sheet. Returns nil on failure.
    @MainActor
    static func writeExportFile(store: GuestDataStore) -> URL? {
        let name = "Stocked-Recipes-\(dateStamp()).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try exportCSV(store: store).data(using: .utf8)?.write(to: url, options: .atomic)
            return url
        } catch {
            Log.transfer.error("Recipe CSV export failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // MARK: Parse

    /// Parse only. Touches nothing, decides nothing.
    ///
    /// If the header has a `remove` column, only rows marked in it are candidates — that's
    /// the "export everything, tick a few" workflow. If it has no `remove` column at all,
    /// every data row is a candidate, which is the "I filtered this down in Excel" workflow.
    /// Either way nothing happens without the confirmation screen.
    static func parseRemovalRows(_ text: String) -> (rows: [RecipeCSVRow], hadRemoveColumn: Bool, total: Int, error: String?) {
        let raw = parseCSVRows(text)
        guard let headerRow = raw.first else {
            return ([], false, 0, "That file is empty.")
        }

        let header = headerRow.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        func col(_ names: [String]) -> Int? {
            for n in names { if let i = header.firstIndex(of: n) { return i } }
            return nil
        }
        let libIdx    = col(["library", "section", "list"])
        let idIdx     = col(["id", "uuid", "recipeid"])
        let titleIdx  = col(["title", "name", "recipe"])
        let removeIdx = col(["remove", "delete"])

        guard let titleIdx else {
            return ([], removeIdx != nil, 0, "That CSV needs a Title column. Export your recipes first to get the right shape.")
        }

        var out: [RecipeCSVRow] = []
        var total = 0
        for (offset, r) in raw.dropFirst().enumerated() {
            func cell(_ i: Int?) -> String {
                guard let i, i < r.count else { return "" }
                return r[i].trimmingCharacters(in: .whitespaces)
            }
            let title = cell(titleIdx)
            if title.isEmpty { continue }
            total += 1

            let marked: Bool
            if removeIdx != nil {
                marked = truthy.contains(cell(removeIdx).lowercased())
            } else {
                marked = true          // no remove column: the file itself is the list
            }
            guard marked else { continue }

            let lib: RecipeCSVLibrary?
            switch cell(libIdx).lowercased() {
            case "mine", "user", "vault", "userrecipe": lib = .mine
            case "saved", "generated", "ai":            lib = .saved
            default:                                    lib = nil
            }

            out.append(RecipeCSVRow(
                library: lib,
                recipeID: UUID(uuidString: cell(idIdx)),
                title: title,
                markedForRemoval: true,
                lineNumber: offset + 2      // +1 for zero-index, +1 for the header
            ))
        }

        return (out, removeIdx != nil, total, nil)
    }

    // MARK: Match

    /// Resolve rows against the store. Touches nothing.
    ///
    /// ID first, because it's exact. Falling back to a normalised title is what makes
    /// hand-written files work, but a title that hits twice is never resolved automatically —
    /// picking "the newest one" would be a coin flip with someone's recipe on it.
    @MainActor
    static func match(_ rows: [RecipeCSVRow], store: GuestDataStore) -> [RecipeCSVMatch] {
        let mine  = store.userRecipes
        let saved = store.savedGeneratedRecipes

        var mineByID: [UUID: UserRecipe] = [:]
        for r in mine { mineByID[r.id] = r }
        var savedByID: [UUID: GeneratedRecipe] = [:]
        for r in saved { savedByID[r.id] = r }

        var mineByTitle: [String: [UserRecipe]] = [:]
        for r in mine { mineByTitle[normKey(r.title), default: []].append(r) }
        var savedByTitle: [String: [GeneratedRecipe]] = [:]
        for r in saved { savedByTitle[normKey(r.title), default: []].append(r) }

        func candidate(_ r: UserRecipe) -> RecipeCSVCandidate {
            var bits: [String] = []
            if !r.cuisine.isEmpty { bits.append(r.cuisine) }
            bits.append("\(r.ingredients.count) ingredients")
            let f = DateFormatter(); f.dateStyle = .medium
            bits.append("added \(f.string(from: r.dateCreated))")
            return RecipeCSVCandidate(id: r.id, title: r.title,
                                      detail: bits.joined(separator: " · "), library: .mine)
        }
        func candidate(_ r: GeneratedRecipe) -> RecipeCSVCandidate {
            var bits: [String] = []
            if !r.mealCategory.isEmpty { bits.append(r.mealCategory) }
            bits.append("\(r.ingredients.count) ingredients")
            bits.append("generated")
            return RecipeCSVCandidate(id: r.id, title: r.title,
                                      detail: bits.joined(separator: " · "), library: .saved)
        }

        var seen = Set<UUID>()      // collapse duplicate rows pointing at the same recipe
        var out: [RecipeCSVMatch] = []

        for row in rows {
            // 1. Exact by ID, in whichever library it turns up.
            if let rid = row.recipeID {
                if row.library != .saved, let hit = mineByID[rid] {
                    if seen.insert(rid).inserted {
                        out.append(RecipeCSVMatch(row: row, candidates: [candidate(hit)], matchedByID: true))
                    }
                    continue
                }
                if row.library != .mine, let hit = savedByID[rid] {
                    if seen.insert(rid).inserted {
                        out.append(RecipeCSVMatch(row: row, candidates: [candidate(hit)], matchedByID: true))
                    }
                    continue
                }
                // ID given but not found — fall through and try the title, since an
                // exported-then-restored recipe legitimately has a new ID.
            }

            // 2. By normalised title, within whichever libraries the row allows.
            let key = normKey(row.title)
            var cands: [RecipeCSVCandidate] = []
            if row.library != .saved { cands += (mineByTitle[key] ?? []).map(candidate) }
            if row.library != .mine  { cands += (savedByTitle[key] ?? []).map(candidate) }

            if cands.count == 1, !seen.insert(cands[0].id).inserted { continue }
            out.append(RecipeCSVMatch(row: row, candidates: cands, matchedByID: false))
        }

        return out
    }

    @MainActor
    static func plan(from text: String, store: GuestDataStore) -> RecipeCSVPlan {
        let parsed = parseRemovalRows(text)
        var p = RecipeCSVPlan()
        p.hadRemoveColumn = parsed.hadRemoveColumn
        p.totalDataRows = parsed.total
        p.parseError = parsed.error
        p.matches = parsed.error == nil ? match(parsed.rows, store: store) : []
        return p
    }

    // MARK: Remove

    private struct RemovalBackup: Codable {
        var exportedAt: Date
        var userRecipes: [UserRecipe]
        var generatedRecipes: [GeneratedRecipe]
    }

    /// The only function here that deletes anything.
    ///
    /// Writes a JSON copy of everything about to go, then assigns each array exactly once so
    /// the store's `didSet` records household tombstones for the removed IDs. Without those
    /// tombstones the server still believes the recipes exist and the next pull restores the
    /// lot — the bulk delete would quietly undo itself an hour later on another device.
    @MainActor
    @discardableResult
    static func remove(userRecipeIDs: Set<UUID>,
                       savedRecipeIDs: Set<UUID>,
                       store: GuestDataStore) -> (removed: Int, backupURL: URL?) {

        guard !userRecipeIDs.isEmpty || !savedRecipeIDs.isEmpty else { return (0, nil) }

        let doomedUser  = store.userRecipes.filter { userRecipeIDs.contains($0.id) }
        let doomedSaved = store.savedGeneratedRecipes.filter { savedRecipeIDs.contains($0.id) }
        let backupURL = writeBackup(userRecipes: doomedUser, generated: doomedSaved)

        if !userRecipeIDs.isEmpty {
            var l = store.userRecipes
            l.removeAll { userRecipeIDs.contains($0.id) }
            store.userRecipes = l                       // one assignment — didSet does the tombstones
        }
        if !savedRecipeIDs.isEmpty {
            var l = store.savedGeneratedRecipes
            l.removeAll { savedRecipeIDs.contains($0.id) }
            store.savedGeneratedRecipes = l             // ditto
        }

        let total = doomedUser.count + doomedSaved.count
        Log.transfer.notice("CSV removal: \(total, privacy: .public) recipes removed")
        return (total, backupURL)
    }

    /// A JSON copy of everything about to be deleted, written before anything is.
    ///
    /// Restoring it brings the recipes back as NEW recipes with new IDs, on purpose: the old
    /// IDs now carry household tombstones, so putting them back under their original IDs would
    /// get them deleted again on the next pull from another device.
    @MainActor
    private static func writeBackup(userRecipes: [UserRecipe], generated: [GeneratedRecipe]) -> URL? {
        guard !userRecipes.isEmpty || !generated.isEmpty else { return nil }
        let payload = RemovalBackup(exportedAt: Date(), userRecipes: userRecipes, generatedRecipes: generated)
        let name = "Stocked-Removed-Recipes-\(dateStamp()).json"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601
            try enc.encode(payload).write(to: url, options: .atomic)
            return url
        } catch {
            Log.transfer.error("Removal backup failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func dateStamp() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

// MARK: - Confirmation sheet

/// Nothing is deleted until this screen says so.
///
/// Clean matches arrive ticked. Ambiguous ones — a title that matches two recipes — arrive
/// unticked in their own section, expanded, with enough detail to tell the recipes apart.
/// Rows that matched nothing are listed at the bottom so a typo shows up as a typo instead
/// of as silence.
struct RecipeCSVRemovalSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss

    let plan: RecipeCSVPlan
    let onRemove: (Set<UUID>, Set<UUID>) -> Void

    @State private var selected: Set<UUID> = []
    @State private var libraryOf: [UUID: RecipeCSVLibrary] = [:]
    @State private var confirming = false

    private var selectedCount: Int { selected.count }

    var body: some View {
        NavigationStack {
            Group {
                if let err = plan.parseError {
                    errorState(err)
                } else if plan.matches.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Remove Recipes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .onAppear(perform: prime)
        .confirmationDialog(
            "Remove \(selectedCount) recipe\(selectedCount == 1 ? "" : "s")?",
            isPresented: $confirming,
            titleVisibility: .visible
        ) {
            Button("Remove \(selectedCount)", role: .destructive) { commit() }
            Button("Keep everything", role: .cancel) { }
        } message: {
            Text("A copy of everything removed is saved first, so this is recoverable.")
        }
    }

    // MARK: Pieces

    private var list: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    Text(summary)
                        .scaledFont(13)
                        .foregroundStyle(session.themeTextColor.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !plan.clean.isEmpty {
                    Section("Found — \(plan.clean.count)") {
                        ForEach(plan.clean) { m in
                            if let c = m.candidates.first { candidateRow(c, matchedByID: m.matchedByID) }
                        }
                    }
                }

                if !plan.ambiguous.isEmpty {
                    Section("More than one match — pick which") {
                        ForEach(plan.ambiguous) { m in
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\"\(m.row.title)\" matches \(m.candidates.count) recipes")
                                    .scaledFont(12, weight: .semibold)
                                    .foregroundStyle(Color.stockedWarning)
                                ForEach(m.candidates) { c in candidateRow(c, matchedByID: false) }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if !plan.unmatched.isEmpty {
                    Section("Not found — nothing to remove") {
                        ForEach(plan.unmatched) { m in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(m.row.title)
                                    .scaledFont(14)
                                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                                Text("line \(m.row.lineNumber)")
                                    .scaledFont(11)
                                    .foregroundStyle(session.themeTextColor.opacity(0.35))
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)

            removeBar
        }
    }

    private func candidateRow(_ c: RecipeCSVCandidate, matchedByID: Bool) -> some View {
        Button {
            if selected.contains(c.id) { selected.remove(c.id) } else { selected.insert(c.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                    .scaledFont(19)
                    .foregroundStyle(selected.contains(c.id) ? Color.stockedError : session.themeTextColor.opacity(0.3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title)
                        .scaledFont(15, weight: .semibold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text(c.library == .saved ? "Saved recipe · \(c.detail)" : c.detail)
                        .scaledFont(11)
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }
                Spacer(minLength: 0)
                if !matchedByID {
                    Image(systemName: "textformat.abc")
                        .scaledFont(11)
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                        .help("Matched by title, not ID")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var removeBar: some View {
        VStack(spacing: 10) {
            Button {
                confirming = true
            } label: {
                Text(selectedCount == 0
                     ? "Nothing selected"
                     : "Remove \(selectedCount) recipe\(selectedCount == 1 ? "" : "s")")
                    .scaledFont(16, weight: .semibold)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(selectedCount == 0 ? Color.gray.opacity(0.4) : Color.stockedError)
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }
            .buttonStyle(.plain)
            .disabled(selectedCount == 0)

            Text("A copy of everything removed is saved first.")
                .scaledFont(11)
                .foregroundStyle(session.themeTextColor.opacity(0.45))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(session.themeBgColor)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .scaledFont(38)
                .foregroundStyle(Color.stockedSuccess)
            Text("Nothing to remove")
                .scaledFont(18, weight: .semibold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            Text(plan.hadRemoveColumn
                 ? "That file has \(plan.totalDataRows) recipes but none are marked in the remove column."
                 : "That file didn't list any recipes.")
                .scaledFont(13)
                .multilineTextAlignment(.center)
                .foregroundStyle(session.themeTextColor.opacity(0.6))
                .padding(.horizontal, 40)
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .scaledFont(34)
                .foregroundStyle(Color.stockedWarning)
            Text(message)
                .scaledFont(14)
                .multilineTextAlignment(.center)
                .foregroundStyle(session.themeTextColor.opacity(0.75))
                .padding(.horizontal, 36)
        }
    }

    private var summary: String {
        var bits = ["\(plan.clean.count) matched"]
        if !plan.ambiguous.isEmpty { bits.append("\(plan.ambiguous.count) need a choice") }
        if !plan.unmatched.isEmpty { bits.append("\(plan.unmatched.count) weren't found") }
        let tail = plan.hadRemoveColumn
            ? "Read from the remove column of a \(plan.totalDataRows)-recipe file."
            : "That file had no remove column, so every row in it counts as a removal."
        return bits.joined(separator: ", ") + ". " + tail
    }

    // MARK: Actions

    private func prime() {
        guard selected.isEmpty else { return }
        for m in plan.matches {
            for c in m.candidates { libraryOf[c.id] = c.library }
        }
        // Clean matches start ticked; ambiguous ones never do.
        selected = Set(plan.clean.compactMap { $0.candidates.first?.id })
    }

    private func commit() {
        var users: Set<UUID> = []
        var saveds: Set<UUID> = []
        for id in selected {
            if libraryOf[id] == .saved { saveds.insert(id) } else { users.insert(id) }
        }
        onRemove(users, saveds)
        dismiss()
    }
}
