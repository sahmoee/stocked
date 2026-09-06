// FoodPredictiveTextField.swift
// Reusable ingredient text field powered by StockedKnowledgeBase.
// Suggestions come from the unified KB (IngredientDatabase + user-learned items),
// ranked by search frequency. Selecting a chip records it for future ranking.
import SwiftUI

struct FoodPredictiveTextField: View {
    let placeholder: String
    @Binding var text: String
    var onCommit: () -> Void = {}
    var onSelect: (String) -> Void = { _ in }
    var externalFocus: FocusState<Bool>.Binding? = nil
    var textColor: Color? = nil   // explicit override — use this instead of environment

    @FocusState private var isFocused: Bool
    // Spoonacular autocomplete results, fetched on a debounce only when local results are thin.
    // Kept as state (not fetched inside the computed `suggestions`) so we control WHEN it fires
    // and protect the 150/day quota.
    @State private var learnedOnline: [KnowledgeIngredient] = []
    @State private var autocompleteTask: Task<Void, Never>? = nil
    @Environment(AppSession.self) var session
    // Always derive from session directly — environment color chain is unreliable
    // in nested views like grocery list and recipe tab search bars
    private var resolvedColor: Color {
        textColor ?? (session.isDarkMode ? Color.stockedWhite : .black)
    }
    private let kb = StockedKnowledgeBase.shared

    private var suggestions: [KnowledgeIngredient] {
        let local = kb.suggestIngredients(prefix: text, limit: 5)
        if text.count >= 2 {
            let catalogHits = ProductCatalog.search(text).prefix(4).map { entry in
                KnowledgeIngredient(name: entry.name, category: entry.category, emoji: entry.emoji)
            }
            // Merge local + catalog + anything Spoonacular taught us (learnedOnline), so online
            // autocomplete results show up here once they've been fetched + cached.
            let combined = (local + Array(catalogHits) + learnedOnline).uniqued { $0.name.lowercased() }.prefix(8)
            return Array(combined)
        }
        return local
    }

    // Bind the field DIRECTLY to the caller's externalFocus when provided, so setting
    // that focus state actually moves first responder here. The old approach used a
    // separate internal @FocusState bridged via onChange, which didn't reliably focus
    // (why the grocery "Add Item" button appeared to do nothing).
    @ViewBuilder private var textField: some View {
        if let ext = externalFocus {
            TextField(placeholder, text: $text)
                .foregroundStyle(resolvedColor)
                .focused(ext)
                .onSubmit { onCommit() }
                .autocorrectionDisabled()
        } else {
            TextField(placeholder, text: $text)
                .foregroundStyle(resolvedColor)
                .focused($isFocused)
                .onSubmit { onCommit() }
                .autocorrectionDisabled()
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            textField

            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(suggestions) { entry in
                            Button {
                                text = entry.name
                                if let ext = externalFocus { ext.wrappedValue = false }
                                else { isFocused = false }
                                kb.recordSearch(entry.name)
                                onSelect(entry.name)
                            } label: {
                                HStack(spacing: 5) {
                                    Text(correctedFoodEmoji(name: entry.name, fallback: entry.emoji)).scaledFont(14)
                                    Text(entry.name)
                                        .scaledFont(13, weight: .medium, design: .serif)
                                        .foregroundStyle(session.themeTextColor)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(.horizontal, 11).padding(.vertical, 7)
                                .background(Color.stockedGold.opacity(0.18))
                                .overlay(Capsule().stroke(Color.stockedGold.opacity(0.5), lineWidth: 1))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .stockedScrollTargetLayout()
                    .padding(.horizontal, 2).padding(.vertical, 2)
                }
                .stockedHorizontalSnap()
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: suggestions.map(\.id))
        .onChange(of: text) { _, newValue in
            // Debounced online autocomplete — only when LOCAL results are thin, min 3 chars, and
            // after a 0.4s pause in typing. This protects the Spoonacular 150/day quota: it won't
            // fire on every keystroke, only when the on-device sources can't help. No-ops without a key.
            autocompleteTask?.cancel()
            let query = newValue.trimmingCharacters(in: .whitespaces)
            guard query.count >= 3,
                  SpoonacularClient.shared.isConfigured,
                  kb.suggestIngredients(prefix: query, limit: 5).count < 3 else {
                learnedOnline = []
                return
            }
            autocompleteTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)  // debounce
                guard !Task.isCancelled, query == text.trimmingCharacters(in: .whitespaces) else { return }
                let names = await SpoonacularClient.shared.autocomplete(query, number: 6)
                guard !Task.isCancelled else { return }
                learnedOnline = names.map { KnowledgeIngredient(name: $0, category: "Pantry", emoji: "🍽️") }
                // Also teach the local KB so next time it's instant + free.
                for name in names { kb.learnFromInventoryItem(name: name, category: "Pantry") }
            }
        }
    }
}


private extension Array {
    func uniqued<T: Hashable>(_ key: (Element) -> T) -> [Element] {
        var seen = Set<T>()
        return filter { seen.insert(key($0)).inserted }
    }
}

/// Corrects a food emoji using the item NAME, so suggestions that were stored with a
/// wrong/generic emoji (e.g. a learned "Chicken Stock" saved as 🥕) still display the
/// right icon. Only overrides when the name clearly implies a different food group;
/// otherwise keeps whatever the entry already had.
func correctedFoodEmoji(name: String, fallback: String) -> String {
    let n = name.lowercased()
    if n.contains("chicken") || n.contains("turkey") || n.contains("duck") || n.contains("poultry") { return "🍗" }
    if ["beef","steak","pork","bacon","sausage"," ham","lamb","veal","bison","venison",
        "ribeye","sirloin","brisket","chorizo","salami","pepperoni","prosciutto",
        "hot dog","frank","bratwurst","meatball"].contains(where: { n.contains($0) }) { return "🥩" }
    if ["fish","salmon","tuna","shrimp","crab","lobster","scallop","cod","tilapia","halibut",
        "trout","mackerel","catfish","sardine","anchovy","clam","mussel","oyster","squid",
        "octopus","calamari","seafood"].contains(where: { n.contains($0) }) { return "🐟" }
    if n.contains("egg") { return "🥚" }
    if ["milk","cheese","yogurt"," cream","butter","cheddar","mozzarella","parmesan","brie",
        "feta","ricotta"].contains(where: { n.contains($0) }) { return "🥛" }
    if ["soda","cola"," juice","coffee"," tea ","lemonade","seltzer","kombucha",
        "gatorade","energy drink","sparkling water"].contains(where: { n.contains($0) }) { return "🥤" }
    if ["honey","syrup","sugar","molasses","agave"].contains(where: { n.contains($0) }) { return "🍯" }
    return fallback
}
