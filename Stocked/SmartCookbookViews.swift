import SwiftUI

struct SmartCookbooksView: View {
    @Environment(AppSession.self) private var session
    @State private var store = SmartCookbookStore.shared
    @State private var editor: CookbookEditorRequest?
    @State private var deleting: SmartCookbookRule?
    @State private var message = ""

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Smart cookbooks", systemImage: "books.vertical")
                    .font(.stocked(.title2))
                Text("Save a few rules and your cookbook fills itself from recipes you've saved. Adding or editing a recipe updates its matches automatically.")
                    .font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
                Text("Cookbook rules travel with your household when recipe sharing is on. Each device matches the saved recipes it has downloaded. No AI or subscription is needed.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                Button { editor = CookbookEditorRequest(baseline: nil) } label: {
                    Label("New smart cookbook", systemImage: "plus").frame(maxWidth: .infinity).padding(.vertical, 8)
                }.buttonStyle(.borderedProminent).tint(session.themeButtonColor)
                    .disabled(!HouseholdSync.shared.can(.recipeEdit) || store.rules.count >= SmartCookbookRule.maximumRules)
                    .accessibilityIdentifier("smart-cookbook-create")
                if !message.isEmpty { Text(message).font(.stocked(.body)) }
                if store.rules.isEmpty {
                    Text("Try ‘Quick favorites’: turn on Favorites and set cook time to 30 minutes or less.")
                        .font(.stocked(.body)).padding(18).frame(maxWidth: .infinity, alignment: .leading)
                        .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 16))
                }
                LazyVStack(spacing: 12) {
                    ForEach(store.rules.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) { rule in
                        VStack(alignment: .leading, spacing: 10) {
                            NavigationLink { SmartCookbookResultsView(ruleID: rule.id) } label: {
                                HStack {
                                    Image(systemName: "book.closed.fill").foregroundStyle(session.accentColor)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(rule.name).font(.stocked(.headline))
                                        Text(rule.summary).font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(session.themeSecondaryText)
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            HStack {
                                Button("Edit rules") { editor = CookbookEditorRequest(baseline: rule) }.frame(minHeight: 44)
                                Spacer()
                                Button("Delete", role: .destructive) { deleting = rule }.frame(minHeight: 44)
                            }.font(.stocked(.footnote)).disabled(!HouseholdSync.shared.can(.recipeEdit))
                        }.padding(16).background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 16))
                    }
                }
                Text("\(store.rules.count) saved cookbooks. New additions are limited to \(SmartCookbookRule.maximumRules). Deleting a cookbook keeps every recipe.")
                    .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                if store.rules.count > SmartCookbookRule.maximumRules {
                    Text("Your household added cookbooks on different devices. All were kept. Remove an unused cookbook before adding another.")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                }
            }.padding(20).foregroundStyle(session.themeTextColor)
        }
        .sheet(item: $editor) { request in SmartCookbookEditorView(baseline: request.baseline).environment(session) }
        .confirmationDialog("Delete this smart cookbook?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete cookbook", role: .destructive) {
                if let deleting { do { try store.delete(deleting); message = "Cookbook deleted. Your recipes are still saved." } catch { message = error.localizedDescription } }
                deleting = nil
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This removes \(deleting?.name ?? "the cookbook") and its rules from the household. Recipes stay saved.") }
    }
}

private struct CookbookEditorRequest: Identifiable {
    let id = UUID()
    let baseline: SmartCookbookRule?
}

private struct SmartCookbookEditorView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let baseline: SmartCookbookRule?
    @State private var draft: SmartCookbookRule
    @State private var requiredTags: String
    @State private var excludedTags: String
    @State private var message = ""

    init(baseline: SmartCookbookRule?) {
        self.baseline = baseline
        let value = baseline ?? SmartCookbookRule()
        _draft = State(initialValue: value)
        _requiredTags = State(initialValue: value.requiredTags.joined(separator: ", "))
        _excludedTags = State(initialValue: value.excludedTags.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name your cookbook") {
                    TextField("For example, quick favorites", text: $draft.name)
                }.listRowBackground(session.themeCardColor)
                Section {
                    TextField("Words in title, ingredients or description", text: $draft.text)
                    TextField("Saved cuisine, for example Italian", text: $draft.cuisine)
                    TextField("Saved category, for example Dinner", text: $draft.category)
                    Toggle("Favorites only", isOn: $draft.favoritesOnly)
                } header: { Text("Match your saved recipes") } footer: {
                    Text("Every filled-in rule must match. Leave a field empty to allow any value. Cuisine and category use saved labels; recipes missing them do not match those filters.")
                }.listRowBackground(session.themeCardColor)
                Section {
                    TextField("Must have tags, separated by commas", text: $requiredTags, axis: .vertical)
                    TextField("Leave out tags, separated by commas", text: $excludedTags, axis: .vertical)
                } header: { Text("Recipe tags") } footer: {
                    Text("All required tags must be present. Excluded tags are exact saved labels. A missing tag does not prove a recipe is suitable for an allergy or diet; check its ingredients yourself.")
                }.listRowBackground(session.themeCardColor)
                Section {
                    minuteLimit("Prep time at most", value: $draft.maxPrepMinutes)
                    minuteLimit("Cook time at most", value: $draft.maxCookMinutes)
                    Picker("Order recipes", selection: $draft.order) {
                        ForEach(SmartCookbookRule.Order.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                } header: { Text("Time and order") } footer: {
                    Text("Time limits use recorded prep or cook times, not estimates. Missing or unclear times are left out when a time limit is on. This is not a total-time filter.")
                }.listRowBackground(session.themeCardColor)
                if !message.isEmpty { Section { Text(message).accessibilityAddTraits(.updatesFrequently) }.listRowBackground(session.themeCardColor) }
            }
            .foregroundStyle(session.themeTextColor).scrollContentBackground(.hidden)
            .background(session.themeBgColor.ignoresSafeArea()).tint(session.themeButtonColor)
            .navigationTitle(baseline == nil ? "New smart cookbook" : "Edit cookbook")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.requiredTags = requiredTags.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                        draft.excludedTags = excludedTags.components(separatedBy: CharacterSet(charactersIn: ",\n"))
                        do { try SmartCookbookStore.shared.save(draft, replacing: baseline); dismiss() }
                        catch { message = error.localizedDescription }
                    }.disabled(!HouseholdSync.shared.can(.recipeEdit))
                }
            }
        }
    }

    private func minuteLimit(_ title: String, value: Binding<Int?>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? 30 : nil }))
            if value.wrappedValue != nil {
                Stepper(value: Binding(get: { value.wrappedValue ?? 30 }, set: { value.wrappedValue = $0 }), in: 0...1440, step: 5) {
                    Text("\(value.wrappedValue ?? 30) minutes")
                }
            }
        }
    }
}

private struct SmartCookbookRecipeRow: Identifiable, Sendable {
    let id: UUID
    let title: String
    let detail: String
}

private struct SmartCookbookResults: Sendable {
    var matches = SmartCookbookMatches()
    var rows: [SmartCookbookRecipeRow] = []
}

private struct SmartCookbookRequest: Hashable {
    let rule: SmartCookbookRule?
    let recipeRevision: Int
    let limit: Int
}

struct SmartCookbookResultsView: View {
    @Environment(AppSession.self) private var session
    let ruleID: UUID
    @State private var result = SmartCookbookResults()
    @State private var limit = 60
    @State private var updating = false
    @State private var generation = 0
    @State private var selectedID: UUID?
    @State private var showRecipe = false
    @State private var editor: CookbookEditorRequest?
    private var rule: SmartCookbookRule? { SmartCookbookStore.shared.rules.first { $0.id == ruleID } }

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 16) {
                if let rule {
                    Text(rule.name).font(.stocked(.title2))
                    Text(rule.summary).font(.stocked(.body)).foregroundStyle(session.themeSecondaryText)
                    Button("Edit rules") { editor = CookbookEditorRequest(baseline: rule) }.buttonStyle(.bordered)
                        .disabled(!HouseholdSync.shared.can(.recipeEdit))
                    if updating { ProgressView("Updating saved recipe matches…") }
                    Text(updating ? "Previous matches: \(result.matches.total) saved recipes" : "\(result.matches.total) matching saved recipes").font(.stocked(.headline))
                        .accessibilityAddTraits(.updatesFrequently)
                    if result.matches.unknownTimeExcluded > 0 {
                        Text("\(result.matches.unknownTimeExcluded) otherwise matching recipes have missing or unclear times and were left out.")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    }
                    if result.rows.isEmpty && !updating {
                        Text("No saved recipes match yet. Adjust these rules or save a recipe with the matching labels.")
                            .font(.stocked(.body))
                    }
                    LazyVStack(spacing: 10) {
                        ForEach(result.rows) { row in
                            Button { selectedID = row.id; showRecipe = true } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "book.pages").foregroundStyle(session.accentColor)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(row.title).font(.stocked(.headline))
                                        Text(row.detail).font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").foregroundStyle(session.themeSecondaryText)
                                }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(16)
                                    .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 16))
                            }.buttonStyle(.plain)
                        }
                    }
                    if result.matches.total > limit && limit < SmartCookbookQuery.maximumVisible {
                        Button("Show more recipes") { limit = min(limit + 60, SmartCookbookQuery.maximumVisible) }
                            .buttonStyle(.bordered).disabled(updating)
                    }
                    if result.matches.total > SmartCookbookQuery.maximumVisible {
                        Text("Showing up to 240 recipes to keep browsing quick. Narrow the rules to find a smaller group.")
                            .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                    }
                    Text("Matches use saved labels and recorded times. Dietary and allergy suitability is never verified by these filters.")
                        .font(.stocked(.footnote)).foregroundStyle(session.themeSecondaryText)
                } else {
                    Text("This cookbook was removed").font(.stocked(.title2))
                    Text("Your recipes are still in your collection.").font(.stocked(.body))
                }
            }.padding(20).foregroundStyle(session.themeTextColor)
        }
        .task(id: SmartCookbookRequest(rule: rule, recipeRevision: session.guestStore.recipeRevision, limit: limit)) { await refresh() }
        .sheet(item: $editor) { request in SmartCookbookEditorView(baseline: request.baseline).environment(session) }
        .navigationDestination(isPresented: $showRecipe) {
            if let recipe = session.guestStore.userRecipes.first(where: { $0.id == selectedID }) {
                UserRecipeDetailView(recipe: recipe)
            } else {
                ContentUnavailableView("Recipe no longer saved", systemImage: "book.closed", description: Text("It may have been removed on another household device."))
                    .background(session.themeBgColor.ignoresSafeArea())
            }
        }
    }

    @MainActor private func refresh() async {
        generation &+= 1
        let token = generation
        guard let rule else { result = SmartCookbookResults(); updating = false; return }
        updating = true
        defer { if token == generation { updating = false } }
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        let recipes = session.guestStore.userRecipes
        let cap = limit
        let work = Task.detached(priority: .userInitiated) { () throws -> SmartCookbookResults in
            let matches = try SmartCookbookQuery.scan(recipes.lazy.map(SmartCookbookData.record), rule: rule, limit: cap)
            let wanted = Set(matches.ids)
            var rows: [UUID: SmartCookbookRecipeRow] = [:]
            for recipe in recipes where wanted.contains(recipe.id) {
                try Task.checkCancellation()
                var details: [String] = []
                if recipe.isFavorited { details.append("Favorite") }
                if !recipe.cuisine.isEmpty { details.append(recipe.cuisine) }
                if let prep = FinderDuration.minutes(recipe.prepTime) { details.append("\(prep) min prep") }
                if let cook = FinderDuration.minutes(recipe.cookTime) { details.append("\(cook) min cook") }
                if details.isEmpty { details.append("Saved recipe · time not recorded") }
                rows[recipe.id] = SmartCookbookRecipeRow(id: recipe.id, title: recipe.title, detail: details.joined(separator: " · "))
            }
            return SmartCookbookResults(matches: matches, rows: matches.ids.compactMap { rows[$0] })
        }
        do {
            let value = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            guard !Task.isCancelled, token == generation else { return }
            result = value
        } catch { /* A newer query or navigation cancellation owns the next result. */ }
    }
}

private extension SmartCookbookRule {
    var summary: String {
        var parts: [String] = []
        if favoritesOnly { parts.append("Favorites") }
        if !text.isEmpty { parts.append("Contains ‘\(text)’") }
        if !cuisine.isEmpty { parts.append(cuisine) }
        if !category.isEmpty { parts.append(category) }
        if !requiredTags.isEmpty { parts.append("Tags: \(requiredTags.joined(separator: ", "))") }
        if !excludedTags.isEmpty { parts.append("Without tags: \(excludedTags.joined(separator: ", "))") }
        if let maxPrepMinutes { parts.append("Prep ≤ \(maxPrepMinutes) min") }
        if let maxCookMinutes { parts.append("Cook ≤ \(maxCookMinutes) min") }
        return parts.isEmpty ? "All your saved recipes" : parts.joined(separator: " · ")
    }
}
