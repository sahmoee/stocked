// SmartKitchenView.swift — Worker-powered tools that the local Kitchen Toolbox doesn't
// already cover. Everything else the Worker offers (unit convert, seasonal, shelf life,
// storage tips, recipe scaling) is redundant with existing offline Toolbox tools, so only
// these two are added: Ingredient Substitutions and Nutrition Estimate. Registered as tiles
// inside KitchenToolboxView (not a separate screen). Backed by SmartClient.

import SwiftUI

// MARK: - Substitutions (Worker: /ingredients/substitute)

struct SubstitutionsToolView: View {
    @Environment(AppSession.self) private var session
    @State private var name = ""
    @State private var vegan = false
    @State private var glutenFree = false
    @State private var subs: [Substitution] = []
    @State private var loading = false
    @State private var searched = false
    @State private var seededFromProfile = false

    /// DEP-09: pre-set the dietary toggles from the saved Dietary Profile so this tool honors it
    /// without the user re-toggling every time. They can still override for a one-off search.
    private func seedFromProfileIfNeeded() {
        guard !seededFromProfile else { return }
        seededFromProfile = true
        let p = session.guestStore.cookingProfile
        let diet = p.dietaryStyle.lowercased()
        if diet.contains("vegan") { vegan = true }
        let allergens = p.allergens.map { $0.lowercased() }
        if diet.contains("gluten") || allergens.contains(where: { $0.contains("gluten") || $0.contains("wheat") }) {
            glutenFree = true
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Out of something? Find what to use instead, with the right ratio. Your own saved swaps come first.")
                    .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.6))

                TextField("Ingredient (e.g. butter, egg, buttermilk)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(run)
                    .onChange(of: name) { _, new in
                        // Improvement #1: local results appear as you type, with no network round trip.
                        let local = SubstitutionEngine.local(for: new, userEntries: session.guestStore.userSubstitutions)
                        if !local.isEmpty { subs = local; searched = true }
                    }
                HStack(spacing: 16) {
                    Toggle("Vegan", isOn: $vegan).toggleStyle(.switch)
                    Toggle("Gluten-free", isOn: $glutenFree).toggleStyle(.switch)
                }.font(.system(size: 13))

                Button(action: run) {
                    HStack { if loading { ProgressView().controlSize(.small) }
                        Text("Find substitutes").font(.system(size: 15, weight: .semibold)) }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(session.accentColor).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || loading)

                if searched && subs.isEmpty && !loading {
                    Text("No substitutes found for \"\(name)\". Try a common baking ingredient.")
                        .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                }
                ForEach(subs) { s in
                    SubstitutionRow(substitution: s)
                        .padding(12)
                        .background(session.themeTextColor.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(18)
        }
        .stockedScreen()
        .navigationTitle("Substitutions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: seedFromProfileIfNeeded)   // DEP-09
    }

    /// Renders local results immediately, then folds in the Worker's diet-aware suggestions.
    /// Offline this still works — which it did not before, when the tool was Worker-only.
    private func run() {
        let n = name
        let diet = vegan ? "vegan" : (glutenFree ? "gluten-free" : nil)
        let entries = session.guestStore.userSubstitutions
        loading = true
        searched = true
        Task {
            let combined = await SubstitutionEngine.all(for: n, userEntries: entries, diet: diet) { local in
                subs = local
            }
            subs = combined
            loading = false
        }
    }
}

// MARK: - Nutrition estimate (Worker: /nutrition/estimate)

struct NutritionToolView: View {
    @Environment(AppSession.self) private var session
    @State private var text = "100 g chicken\n1 cup rice\n1 tbsp olive oil"
    @State private var result: SmartNutrition?
    @State private var loading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Rough calories and macros for a list of ingredients. Estimates only — not medical advice.")
                    .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.6))

                TextField("Ingredients, one per line", text: $text, axis: .vertical)
                    .lineLimit(3...10).textFieldStyle(.roundedBorder)

                Button(action: run) {
                    HStack { if loading { ProgressView().controlSize(.small) }
                        Text("Estimate").font(.system(size: 15, weight: .semibold)) }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(session.accentColor).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }.disabled(loading)

                if let r = result {
                    HStack(spacing: 10) {
                        macro("\(r.total.kcal)", "kcal")
                        macro("\(r.total.protein)g", "protein")
                        macro("\(r.total.carbs)g", "carbs")
                        macro("\(r.total.fat)g", "fat")
                    }
                    ForEach(Array(r.items.enumerated()), id: \.offset) { _, it in
                        HStack {
                            Text(it.name.capitalized).font(.system(size: 13)).foregroundStyle(session.themeTextColor)
                            Spacer()
                            Text(it.kcal.map { "\($0) kcal" } ?? "—").font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.6))
                        }
                        .padding(.vertical, 4)
                        Divider().opacity(0.4)
                    }
                }
            }
            .padding(18)
        }
        .stockedScreen()
        .navigationTitle("Nutrition")
        .navigationBarTitleDisplayMode(.inline)
    }
    private func macro(_ v: String, _ label: String) -> some View {
        VStack(spacing: 1) {
            Text(v).font(.system(size: 17, weight: .bold)).foregroundStyle(session.accentColor)
            Text(label).font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.5))
        }
        .frame(maxWidth: .infinity).padding(.vertical, 10)
        .background(session.themeTextColor.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 12))
    }
    private func run() {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        loading = true
        Task { result = await SmartClient.shared.estimateNutrition(lines); loading = false }
    }
}
