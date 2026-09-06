// CustomRecipeSources.swift — lets users add their own recipe websites on top of the
// built-in catalogue, and suggests popular sources they can add with one tap.
//
// The registry's `all` accessor merges these user sources with the bundled list, so every
// existing consumer (filters, counts, URL import, source badges) picks them up automatically.
import SwiftUI

// MARK: - Persisted custom source store

@Observable
@MainActor
final class CustomRecipeSourceStore {
    static let shared = CustomRecipeSourceStore()

    private static let key = "custom_recipe_sources_v1"
    private static let maxSources = 60   // generous cap; keeps persistence bounded

    private(set) var sources: [RecipeSource] = []

    private init() { load() }

    /// True if a domain is already covered by a bundled or custom source.
    func isKnown(_ domain: String) -> Bool {
        let d = Self.normalizeDomain(domain)
        return RecipeSourceRegistry.bundled.contains { $0.domain == d }
            || sources.contains { $0.domain == d }
    }

    @discardableResult
    func add(domain rawDomain: String, displayName rawName: String,
             category: RecipeSource.SourceCategory, specialty: String, emoji: String) -> Bool {
        let domain = Self.normalizeDomain(rawDomain)
        guard !domain.isEmpty, domain.contains("."), !isKnown(domain), sources.count < Self.maxSources else {
            return false
        }
        let name = rawName.trimmingCharacters(in: .whitespaces)
        let source = RecipeSource(
            id: UUID(),
            domain: domain,
            displayName: name.isEmpty ? domain : name,
            category: category,
            specialty: specialty.trimmingCharacters(in: .whitespaces).isEmpty ? "Custom source" : specialty,
            iconEmoji: emoji.isEmpty ? "🍽️" : emoji
        )
        sources.append(source)
        persist()
        HapticManager.success()
        return true
    }

    func remove(_ source: RecipeSource) {
        sources.removeAll { $0.id == source.id }
        persist()
        HapticManager.warning()
    }

    /// Cleans a pasted domain or URL down to a bare host (drops scheme, www., path).
    static func normalizeDomain(_ raw: String) -> String {
        var s = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let range = s.range(of: "://") { s = String(s[range.upperBound...]) }
        if s.hasPrefix("www.") { s = String(s.dropFirst(4)) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let decoded = try? JSONDecoder().decode([RecipeSource].self, from: data) else {
            RecipeSourceRegistry.customSnapshot = []
            return
        }
        sources = decoded
        RecipeSourceRegistry.customSnapshot = decoded
    }

    private func persist() {
        // Keep the nonisolated lookup snapshot in step so the import pipeline resolves
        // user domains too.
        RecipeSourceRegistry.customSnapshot = sources
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}

// MARK: - Suggested sources (one-tap add)

/// Popular, well-structured recipe sites not in the bundled list — offered as quick adds.
enum SuggestedRecipeSources {
    struct Suggestion: Identifiable {
        var id: String { domain }
        let domain: String
        let displayName: String
        let category: RecipeSource.SourceCategory
        let specialty: String
        let emoji: String
    }

    static let all: [Suggestion] = [
        .init(domain: "cookieandkate.com",     displayName: "Cookie and Kate",   category: .healthy,       specialty: "Whole-food vegetarian",     emoji: "🥦"),
        .init(domain: "ambitiouskitchen.com",  displayName: "Ambitious Kitchen",  category: .healthy,       specialty: "Wholesome baking and meals", emoji: "🌱"),
        .init(domain: "onceuponachef.com",     displayName: "Once Upon a Chef",   category: .homeCook,      specialty: "Tested crowd-pleasers",     emoji: "👩‍🍳"),
        .init(domain: "recipetineats.com",     displayName: "RecipeTin Eats",     category: .homeCook,      specialty: "Reliable everyday dinners",  emoji: "🍛"),
        .init(domain: "justonecookbook.com",   displayName: "Just One Cookbook",  category: .international, specialty: "Authentic Japanese cooking", emoji: "🍱"),
        .init(domain: "hostthetoast.com",      displayName: "Host The Toast",     category: .creative,      specialty: "Bold comfort food",         emoji: "🥂"),
        .init(domain: "twopeasandtheirpod.com",displayName: "Two Peas & Their Pod",category: .homeCook,     specialty: "Family-friendly recipes",    emoji: "🌿"),
        .init(domain: "spendwithpennies.com",  displayName: "Spend With Pennies", category: .budget,        specialty: "Easy budget cooking",       emoji: "🪙"),
        .init(domain: "natashaskitchen.com",   displayName: "Natasha's Kitchen",  category: .homeCook,      specialty: "Comfort food with video",    emoji: "🎥"),
        .init(domain: "sipandfeast.com",       displayName: "Sip and Feast",      category: .world,         specialty: "Italian-American cooking",   emoji: "🍝"),
    ]
}

// MARK: - Management view

struct RecipeSourcesManagerView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var store = CustomRecipeSourceStore.shared

    // Add-source form state
    @State private var domain = ""
    @State private var name = ""
    @State private var specialty = ""
    @State private var emoji = ""
    @State private var category: RecipeSource.SourceCategory = .homeCook
    @State private var showAddError = false

    private var suggestions: [SuggestedRecipeSources.Suggestion] {
        SuggestedRecipeSources.all.filter { !store.isKnown($0.domain) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                List {
                    // Add your own
                    Section {
                        TextField("Website domain (e.g. mykitchen.com)", text: $domain)
                            .autocorrectionDisabled().textInputAutocapitalization(.never)
                            .foregroundStyle(session.themeTextColor)
                        TextField("Display name (optional)", text: $name)
                            .foregroundStyle(session.themeTextColor)
                        TextField("What it's known for (optional)", text: $specialty)
                            .foregroundStyle(session.themeTextColor)
                        HStack {
                            TextField("Emoji", text: $emoji)
                                .frame(width: 60)
                                .foregroundStyle(session.themeTextColor)
                            Picker("Category", selection: $category) {
                                ForEach(RecipeSource.SourceCategory.allCases, id: \.self) { cat in
                                    Text(cat.rawValue).tag(cat)
                                }
                            }
                        }
                        Button {
                            let ok = store.add(domain: domain, displayName: name,
                                               category: category, specialty: specialty, emoji: emoji)
                            if ok {
                                domain = ""; name = ""; specialty = ""; emoji = ""
                            } else {
                                showAddError = true
                            }
                        } label: {
                            Label("Add Source", systemImage: "plus.circle.fill")
                                .scaledFont(14, weight: .semibold)
                                .foregroundStyle(Color.stockedGold)
                        }
                        .disabled(domain.trimmingCharacters(in: .whitespaces).isEmpty)
                    } header: {
                        Text("Add a Website")
                    } footer: {
                        Text("Paste any recipe site's domain. It remains hidden from recipe browsing until Stocked has cached 20 unique complete recipes from it.")
                    }

                    // Suggested
                    if !suggestions.isEmpty {
                        Section("Discovery Candidates") {
                            ForEach(suggestions) { s in
                                Button {
                                    store.add(domain: s.domain, displayName: s.displayName,
                                              category: s.category, specialty: s.specialty, emoji: s.emoji)
                                } label: {
                                    HStack {
                                        Text(s.emoji)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(s.displayName).scaledFont(14, weight: .medium)
                                                .foregroundStyle(session.themeTextColor)
                                            Text(s.specialty).scaledFont(11)
                                                .foregroundStyle(session.themeSecondaryText)
                                        }
                                        Spacer()
                                        Image(systemName: "plus.circle")
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                }
                            }
                        }
                    }

                    // Your custom sources
                    if !store.sources.isEmpty {
                        Section("Your Configured Candidates") {
                            ForEach(store.sources) { src in
                                HStack {
                                    Text(src.iconEmoji)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(src.displayName).scaledFont(14, weight: .medium)
                                            .foregroundStyle(session.themeTextColor)
                                        Text(src.domain).scaledFont(11)
                                            .foregroundStyle(session.themeSecondaryText)
                                    }
                                    Spacer()
                                }
                            }
                            .onDelete { indexSet in
                                for i in indexSet { store.remove(store.sources[i]) }
                            }
                        }
                    }

                    // Built-in count
                    Section {
                        Text("Configured sources are discovery candidates only. Recipe browsing shows a source after it reaches 20 complete recipes; failed sources with five or fewer are removed from cache.")
                            .scaledFont(12)
                            .foregroundStyle(session.themeSecondaryText)
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Recipe Sources")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.stockedGold)
                }
            }
            .alert("Couldn't add that source", isPresented: $showAddError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Enter a valid website domain that isn't already in your list.")
            }
        }
    }
}
