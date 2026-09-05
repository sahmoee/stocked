// DatabasesView.swift
// Databases hub — accessible from left drawer (iPhone) and iPad sidebar.
// All data routes through StockedDatabase.shared.
// Tabs: Substitutions · Abbreviations · Ingredients · Tips
import SwiftUI

// MARK: - Main Hub
struct DatabasesView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @Environment(\.stockedDismiss) private var stockedDismiss
    @Environment(\.stockedMotion) private var motion
    @State private var selectedTab = 0

    private let tabs      = ["Substitutions", "Abbreviations", "Ingredients", "Tips"]
    private let tabIcons  = ["arrow.left.arrow.right", "textformat.abc", "leaf", "lightbulb"]

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(spacing: 0) {

                    // ── Tab pills ───────────────────────────────────────
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(tabs.indices, id: \.self) { i in
                                Button {
                                    motion.animate(.selection, intent: .spatial) { selectedTab = i }
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: tabIcons[i]).scaledFont(11)
                                        Text(tabs[i]).scaledFont(12, weight: .semibold)
                                    }
                                    // These horizontally scrolling pills are atomic
                                    // controls, not paragraphs. Preserve each complete
                                    // word and let the rail scroll at every text size.
                                    .fixedSize(horizontal: true, vertical: true)
                                    .foregroundStyle(selectedTab == i ? Color.stockedCharcoal : Color.stockedWhite)
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(selectedTab == i ? Color.stockedGold : Color.stockedCharcoal.opacity(0.6))
                                    .clipShape(Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                        .stockedScrollTargetLayout()
                        .padding(.horizontal, 20)
                    }
                    .stockedHorizontalSnap()
                    .padding(.vertical, 12)

                    Divider().opacity(0.3)

                    // ── Tab content ─────────────────────────────────────
                    Group {
                        switch selectedTab {
                        case 0: SubstitutionsDatabaseTab()
                        case 1: AbbreviationsDatabaseTab()
                        case 2: IngredientsDatabaseTab()
                        default: TipsDatabaseTab()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Databases")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { if let stockedDismiss { stockedDismiss() } else { dismiss() } }
                        .foregroundStyle(Color.stockedGold)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared search bar
// ─────────────────────────────────────────────────────────────────────────────
private struct DBSearchBar: View {
    @Environment(AppSession.self) private var session
    @Binding var text: String
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .scaledFont(14).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .scaledFont(14)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain)
            }
        }
        .padding(11)
        .background(session.themeCardColor)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .padding(.horizontal, 20).padding(.bottom, 2)
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Substitutions Tab
// ─────────────────────────────────────────────────────────────────────────────
// One enum → one .sheet(item:) (two stacked .sheet modifiers fire unreliably).
enum SubsSheet: Identifiable {
    case edit(entry: SubstitutionEntry)
    case addCustom
    var id: String {
        switch self {
        case .edit(let e): return "edit-\(e.id)"
        case .addCustom:   return "add"
        }
    }
}

struct SubstitutionsDatabaseTab: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion
    @State private var search           = ""
    @State private var subsSheet: SubsSheet? = nil
    @State private var expandedSubstitutionID: UUID? = nil

    private var filtered: [SubstitutionEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return StockedDatabase.shared.sortedSubstitutionEntries }
        return StockedDatabase.shared.sortedSubstitutionEntries.filter {
            $0.displayName.lowercased().contains(q) ||
            $0.substitutions.contains { $0.substitute.lowercased().contains(q) }
        }
    }

    // User-added entries from AppSession
    private var userFiltered: [UserSubstitutionEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return session.guestStore.userSubstitutions }
        return session.guestStore.userSubstitutions.filter {
            $0.ingredient.lowercased().contains(q) ||
            $0.substitute.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                DBSearchBar(text: $search, placeholder: "Search ingredients or substitutes…")
                Button {
                    subsSheet = .addCustom
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .scaledFont(22)
                        .foregroundStyle(Color.stockedGold)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 16)
            }

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    // User-added entries shown first with a distinct badge
                    if !userFiltered.isEmpty {
                        HStack {
                            Text("MY SUBSTITUTIONS")
                                .scaledFont(10, weight: .bold).tracking(1.2)
                                .foregroundStyle(session.themeTextColor.opacity(0.4))
                            Spacer()
                        }
                        .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)

                        ForEach(userFiltered) { entry in
                            UserSubstitutionRow(entry: entry)
                            Divider().padding(.leading, 20)
                        }
                    }

                    // Built-in entries
                    ForEach(filtered) { entry in
                        SubstitutionDBRow(
                            entry: entry,
                            isExpanded: expandedSubstitutionID == entry.id,
                            onToggle: {
                                motion.animate(.selection, intent: .spatial) {
                                    expandedSubstitutionID = expandedSubstitutionID == entry.id ? nil : entry.id
                                }
                            },
                            onTap: { subsSheet = .edit(entry: entry) }
                        )
                        Divider().padding(.leading, 20)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .sheet(item: $subsSheet) { sheet in
            switch sheet {
            case let .edit(entry):
                SubstitutionDetailSheet(entry: entry).environment(session)
            case .addCustom:
                AddCustomSubstitutionSheet().environment(session)
            }
        }
    }
}

// MARK: - User substitution row
private struct UserSubstitutionRow: View {
    @Environment(AppSession.self) var session
    let entry: UserSubstitutionEntry

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.ingredient.capitalized)
                    .scaledFont(15, weight: .semibold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                HStack(spacing: 6) {
                    Image(systemName: "arrow.right").scaledFont(10).foregroundStyle(Color.stockedGold)
                    Text(entry.substitute)
                        .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.6))
                    if !entry.notes.isEmpty {
                        Text("· \(entry.notes)").scaledFont(11)
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                }
            }
            Spacer()
            // Badge
            Text("Custom").scaledFont(9, weight: .bold)
                .foregroundStyle(Color.stockedGold)
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Color.stockedGold.opacity(0.12)).clipShape(Capsule())
            // Delete
            Button {
                withAnimation { session.guestStore.userSubstitutions.removeAll { $0.id == entry.id } }
            } label: {
                Image(systemName: "trash").scaledFont(13).foregroundStyle(.red.opacity(0.6))
            }.buttonStyle(.plain)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }
}

// MARK: - Add Custom Substitution Sheet
private struct AddCustomSubstitutionSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @State private var ingredient = ""
    @State private var substitute = ""
    @State private var notes      = ""

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 16)

                Text("Add Substitution")
                    .scaledFont(20, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor).padding(.bottom, 24)

                VStack(spacing: 16) {
                    inputField("Ingredient", text: $ingredient, placeholder: "e.g. Buttermilk")
                    inputField("Substitute with", text: $substitute, placeholder: "e.g. Milk + lemon juice")
                    inputField("Notes (optional)", text: $notes, placeholder: "e.g. 1 cup milk + 1 tbsp lemon juice")
                }.padding(.horizontal, 24)

                Spacer()

                Button {
                    let ing = ingredient.trimmingCharacters(in: .whitespaces)
                    let sub = substitute.trimmingCharacters(in: .whitespaces)
                    guard !ing.isEmpty, !sub.isEmpty else { return }
                    session.guestStore.userSubstitutions.append(
                        UserSubstitutionEntry(ingredient: ing.lowercased(), substitute: sub, notes: notes.trimmingCharacters(in: .whitespaces))
                    )
                    dismiss()
                } label: {
                    Text("Save Substitution")
                        .scaledFont(16, weight: .semibold, design: .serif)
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(ingredient.isEmpty || substitute.isEmpty
                            ? Color.stockedCharcoal.opacity(0.3) : session.themeButtonColor)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .buttonStyle(.plain)
                .disabled(ingredient.isEmpty || substitute.isEmpty)
                .padding(.horizontal, 24).padding(.bottom, 32)
            }
        }
        .presentationDetents([.medium, .large])
        .dismissKeyboardOnTap()
    }

    private func inputField(_ label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .scaledFont(10, weight: .bold).tracking(1)
                .foregroundStyle(session.themeTextColor.opacity(0.4))
            TextField(placeholder, text: text)
                .scaledFont(15)
                .foregroundStyle(session.themeTextColor)
                .padding(12)
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
        }
    }
}

private struct SubstitutionDBRow: View {
    @Environment(AppSession.self) var session
    let entry: SubstitutionEntry
    let isExpanded: Bool
    let onToggle: () -> Void
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.displayName)
                            .scaledFont(15, weight: .semibold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Text("\(entry.substitutions.count) substitute\(entry.substitutions.count == 1 ? "" : "s")")
                            .scaledFont(11)
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                    Spacer()
                    Button(action: onTap) {
                        Image(systemName: "info.circle")
                            .scaledFont(14)
                            .foregroundStyle(session.themeTextColor.opacity(0.3))
                    }.buttonStyle(.plain)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.4))
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(entry.substitutions) { sub in
                        HStack(alignment: .top, spacing: 10) {
                            Circle().fill(Color.stockedGold).frame(width: 5, height: 5).padding(.top, 6)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sub.substitute)
                                    .scaledFont(13, weight: .semibold)
                                    .foregroundStyle(session.themeTextColor)
                                if !sub.notes.isEmpty {
                                    Text(sub.notes)
                                        .scaledFont(11)
                                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 28).padding(.vertical, 8)
                        .background(session.isDarkMode ? Color.darkSurface.opacity(0.4) : Color.stockedWhite.opacity(0.25))
                    }
                }
            }
        }
    }
}

private struct SubstitutionDetailSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let entry: SubstitutionEntry

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(entry.displayName)
                            .scaledFont(22, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                            .padding(.horizontal, 24).padding(.top, 20)

                        ForEach(entry.substitutions) { sub in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(sub.substitute)
                                    .scaledFont(15, weight: .semibold)
                                    .foregroundStyle(session.themeTextColor)
                                if !sub.notes.isEmpty {
                                    Text(sub.notes)
                                        .scaledFont(13)
                                        .foregroundStyle(session.themeTextColor.opacity(0.6))
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            .padding(.horizontal, 20)
                        }

                        Text("Source: Food Network Ingredient Substitution Guide + common cooking knowledge.")
                            .scaledFont(11)
                            .foregroundStyle(session.themeTextColor.opacity(0.35))
                            .padding(.horizontal, 24).padding(.bottom, 40)
                    }
                }
            }
            .navigationTitle("Substitution Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.stockedGold)
                }
            }
        }
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Abbreviations Tab
// ─────────────────────────────────────────────────────────────────────────────
enum AbbrSheet: Identifiable {
    case add
    case edit(entry: AbbreviationEntry)
    var id: String {
        switch self {
        case .add:         return "add"
        case .edit(let e): return "edit-\(e.id)"
        }
    }
}

struct AbbreviationsDatabaseTab: View {
    @Environment(AppSession.self) var session
    @State private var search        = ""
    @State private var abbrSheet: AbbrSheet? = nil
    @State private var showDeleteAlert = false
    @State private var deleteTarget: AbbreviationEntry? = nil

    private var filtered: [AbbreviationEntry] {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return StockedDatabase.shared.sortedAbbreviationEntries }
        return StockedDatabase.shared.sortedAbbreviationEntries.filter {
            $0.abbreviation.lowercased().contains(q) || $0.resolved.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                DBSearchBar(text: $search, placeholder: "Search abbreviations…")
                Button {
                    abbrSheet = .add
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .scaledFont(24)
                        .foregroundStyle(Color.stockedGold)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 20)
            }

            // Legend
            HStack(spacing: 16) {
                legendBadge("Built-in",   color: .blue)
                legendBadge("User Added", color: Color.stockedGold)
                legendBadge("Corrected",  color: .orange)
                Spacer()
                Text("\(filtered.count) entries")
                    .scaledFont(11)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
            }
            .padding(.horizontal, 20).padding(.vertical, 8)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { entry in
                        AbbreviationRow(entry: entry) {
                            abbrSheet = .edit(entry: entry)
                        } onDelete: {
                            deleteTarget  = entry
                            showDeleteAlert = true
                        }
                        Divider().padding(.leading, 20)
                    }
                }
                .padding(.bottom, 40)
            }
        }
        .sheet(item: $abbrSheet) { sheet in
            switch sheet {
            case .add:
                AddAbbreviationSheet(existingEntry: nil).environment(session)
            case let .edit(entry):
                AddAbbreviationSheet(existingEntry: entry).environment(session)
            }
        }
        .alert("Delete abbreviation?", isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                if let t = deleteTarget { StockedDatabase.shared.deleteAbbreviations(ids: [t.id]) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \"\(deleteTarget?.abbreviation ?? "")\" → \"\(deleteTarget?.resolved ?? "")\" from your catalog.")
        }
    }

    private func legendBadge(_ label: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).scaledFont(10).foregroundStyle(session.themeTextColor.opacity(0.5))
        }
    }
}

private struct AbbreviationRow: View {
    @Environment(AppSession.self) var session
    let entry: AbbreviationEntry
    var onEdit: () -> Void
    var onDelete: () -> Void

    private var sourceColor: Color {
        switch entry.source {
        case .builtIn:   return .blue
        case .userAdded: return Color.stockedGold
        case .corrected: return .orange
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(sourceColor).frame(width: 7, height: 7).padding(.leading, 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.abbreviation)
                        .scaledFont(14, weight: .bold, design: .monospaced)
                        .foregroundStyle(session.themeTextColor)
                    Image(systemName: "arrow.right")
                        .scaledFont(10)
                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                    Text(entry.resolved)
                        .scaledFont(14)
                        .foregroundStyle(session.themeTextColor)
                }
                if entry.timesUsed > 0 {
                    Text("Used \(entry.timesUsed)×")
                        .scaledFont(10)
                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                }
            }

            Spacer()

            Button(action: onEdit) {
                Image(systemName: "pencil").scaledFont(13)
                    .foregroundStyle(entry.source == .builtIn ? session.themeTextColor.opacity(0.25) : Color.stockedGold)
            }.buttonStyle(.plain).padding(.trailing, 8)

            if entry.source != .builtIn {
                Button(action: onDelete) {
                    Image(systemName: "trash").scaledFont(13)
                        .foregroundStyle(.red.opacity(0.6))
                }.buttonStyle(.plain).padding(.trailing, 16)
            } else {
                Color.clear.frame(width: 14 + 16) // keep alignment consistent
            }
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Add / Edit Abbreviation Sheet
struct AddAbbreviationSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    let existingEntry: AbbreviationEntry?

    @State private var abbreviation = ""
    @State private var resolved     = ""

    private var isEditing: Bool { existingEntry != nil }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 20) {
                    Text("Abbreviation appears on receipt exactly as scanned. It will be auto-resolved next time it's seen.")
                        .scaledFont(13)
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .padding(.horizontal, 24).padding(.top, 20)

                    VStack(spacing: 0) {
                        fieldRow(label: "Abbreviation (e.g. CHKN BRS)", text: $abbreviation)
                            .onChange(of: abbreviation) { _, v in abbreviation = v.uppercased() }
                        Divider().padding(.leading, 20)
                        fieldRow(label: "Resolves to (e.g. Chicken Breast)", text: $resolved)
                    }
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    .padding(.horizontal, 20)

                    Spacer()
                }
            }
            .navigationTitle(isEditing ? "Edit Abbreviation" : "New Abbreviation")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(abbreviation.isEmpty || resolved.isEmpty)
                        .foregroundStyle(Color.stockedGold)
                }
            }
            .onAppear {
                if let e = existingEntry { abbreviation = e.abbreviation; resolved = e.resolved }
            }
        }
    }

    private func fieldRow(label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .scaledFont(11, weight: .semibold)
                .foregroundStyle(session.themeTextColor.opacity(0.45))
            TextField(label, text: text)
                .scaledFont(15)
                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }

    private func save() {
        let abbr = abbreviation.trimmingCharacters(in: .whitespacesAndNewlines)
        let res  = resolved.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !abbr.isEmpty, !res.isEmpty else { return }
        if let entry = existingEntry {
            StockedDatabase.shared.updateAbbreviation(id: entry.id, abbreviation: abbr, resolved: res)
        } else {
            StockedDatabase.shared.addAbbreviation(abbr, resolved: res, source: .userAdded)
        }
        dismiss()
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Ingredients Tab
// ─────────────────────────────────────────────────────────────────────────────
struct IngredientsDatabaseTab: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion
    @State private var search     = ""
    @State private var filterZone = "All"

    private var store: GuestDataStore { session.guestStore }

    private var zones: [String] {
        ["All"] + Array(Set(store.inventoryItems.map(\.zone))).sorted()
    }

    private var filtered: [LocalInventoryItem] {
        let items = store.inventoryItems
        let zoned = filterZone == "All" ? items : items.filter { $0.zone == filterZone }
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return zoned.sorted { $0.name < $1.name } }
        return zoned.filter { $0.name.lowercased().contains(q) }.sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            DBSearchBar(text: $search, placeholder: "Search pantry ingredients…")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(zones, id: \.self) { zone in
                        Button {
                            motion.animate(.selection, intent: .spatial) { filterZone = zone }
                        } label: {
                            Text(zone)
                                .scaledFont(12, weight: .semibold)
                                .foregroundStyle(filterZone == zone ? Color.stockedCharcoal : Color.stockedWhite)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(filterZone == zone ? Color.stockedGold : Color.stockedCharcoal.opacity(0.5))
                                .clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                .stockedScrollTargetLayout()
                .padding(.horizontal, 20)
            }
            .stockedHorizontalSnap()
            .padding(.vertical, 10)

            if filtered.isEmpty {
                VStack(spacing: 12) {
                    Text("🥫").scaledFont(36)
                    Text("No ingredients found")
                        .scaledFont(14)
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { item in
                            IngredientDBRow(item: item)
                            Divider().padding(.leading, 20)
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
        }
    }
}

private struct IngredientDBRow: View {
    @Environment(AppSession.self) var session
    let item: LocalInventoryItem

    @State private var showEdit  = false
    @State private var editedName = ""
    @State private var editedZone = ""

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                if showEdit {
                    HStack(spacing: 8) {
                        TextField("Name", text: $editedName)
                            .scaledFont(14, weight: .semibold)
                            .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                        TextField("Zone", text: $editedZone)
                            .scaledFont(12)
                            .foregroundStyle(session.themeTextColor.opacity(0.6))
                    }
                } else {
                    Text(item.name)
                        .scaledFont(14, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                    HStack(spacing: 6) {
                        Text(item.zone)
                            .scaledFont(11)
                            .foregroundStyle(Color.stockedGold)
                        Text("·")
                            .foregroundStyle(session.themeTextColor.opacity(0.3))
                        Text("\(Int(item.effectiveLevel * 100))% stocked")
                            .scaledFont(11)
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                }
            }
            Spacer()
            if showEdit {
                Button("Save") {
                    if let idx = session.guestStore.inventoryItems.firstIndex(where: { $0.id == item.id }) {
                        let name = editedName.trimmingCharacters(in: .whitespaces)
                        let zone = editedZone.trimmingCharacters(in: .whitespaces)
                        if !name.isEmpty { session.guestStore.inventoryItems[idx].name = name }
                        if !zone.isEmpty {
                            session.guestStore.inventoryItems[idx].storageCategory =
                                StorageCategory(rawValue: zone) ?? .pantry
                        }
                    }
                    showEdit = false
                }
                .scaledFont(13, weight: .bold).foregroundStyle(Color.stockedGold)
                .buttonStyle(.plain)

                Button("Cancel") { showEdit = false }
                    .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.4))
                    .buttonStyle(.plain)
            } else {
                Button {
                    editedName = item.name
                    editedZone = item.zone
                    showEdit   = true
                } label: {
                    Image(systemName: "pencil")
                        .scaledFont(13).foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Tips Tab
// ─────────────────────────────────────────────────────────────────────────────
struct TipsDatabaseTab: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion
    @State private var selectedCategory: CookingTip.TipCategory? = nil
    @State private var search       = ""
    @State private var expandedIDs  = Set<UUID>()

    private var filtered: [CookingTip] {
        var items = selectedCategory == nil
            ? StockedDatabase.shared.cookingTips
            : StockedDatabase.shared.tips(for: selectedCategory ?? .general)
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !q.isEmpty {
            items = items.filter { $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q) }
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            DBSearchBar(text: $search, placeholder: "Search tips…")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    categoryPill(nil, label: "All")
                    ForEach(StockedDatabase.shared.allTipCategories, id: \.self) { cat in
                        categoryPill(cat, label: cat.rawValue)
                    }
                }
                .stockedScrollTargetLayout()
                .padding(.horizontal, 20)
            }
            .stockedHorizontalSnap()
            .padding(.vertical, 10)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(filtered) { tip in
                        TipDBRow(tip: tip, isExpanded: expandedIDs.contains(tip.id)) {
                            motion.animate(.selection, intent: .spatial) {
                                if expandedIDs.contains(tip.id) { expandedIDs.remove(tip.id) }
                                else                             { expandedIDs = [tip.id] }
                            }
                        }
                        Divider().padding(.leading, 20)
                    }
                }
                .padding(.bottom, 40)
            }
        }
    }

    private func categoryPill(_ cat: CookingTip.TipCategory?, label: String) -> some View {
        let isActive = selectedCategory == cat
        return Button {
            motion.animate(.selection, intent: .spatial) { selectedCategory = cat }
        } label: {
            Text(label)
                .scaledFont(12, weight: .semibold)
                .foregroundStyle(isActive ? Color.stockedCharcoal : Color.stockedWhite)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(isActive ? Color.stockedGold : Color.stockedCharcoal.opacity(0.5))
                .clipShape(Capsule())
        }.buttonStyle(.plain)
    }
}

private struct TipDBRow: View {
    @Environment(AppSession.self) var session
    let tip: CookingTip
    let isExpanded: Bool
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text(tip.emoji).scaledFont(20).frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tip.title)
                            .scaledFont(14, weight: .semibold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Text(tip.category.rawValue)
                            .scaledFont(10)
                            .foregroundStyle(Color.stockedGold)
                    }
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.35))
                }
                .padding(.horizontal, 20).padding(.vertical, 14)

                if isExpanded {
                    Text(tip.body)
                        .scaledFont(13)
                        .foregroundStyle(session.themeTextColor.opacity(0.7))
                        .lineSpacing(3)
                        .padding(.horizontal, 58).padding(.bottom, 14)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
