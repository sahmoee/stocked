// SubstitutionReviewSheet.swift
// ─────────────────────────────────────────────────────────────────
// The explicit substitution decision point. A recipe classified as
// "swap needs review" is one confirmation away from ready — this sheet is
// that confirmation. For each unresolved ingredient with an in-stock swap:
//
//   Buttermilk  →  you have: milk
//   "Add 1 tbsp lemon juice or vinegar per cup and let sit 5 minutes."
//   [ Use This Swap ]   [ Add Buttermilk to Grocery ]
//
// Confirming records the decision on the CookNowSession (readiness upgrades
// live everywhere, because every surface reads the same session) and stages
// a "used a swap" note for the Inventory Update Review. Declining routes the
// original to the grocery list. Guidance text comes from the curated
// substitution database when it has notes for the pairing — never invented.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct SubstitutionReviewSheet: View {
    let recipe: UserRecipe

    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    @Environment(\.dismiss) private var dismiss
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var classification: ClassifiedRecipe? = nil
    @State private var addedToGrocery: Set<String> = []

    private var reviewRows: [(name: String, amount: String, suggestion: String)] {
        guard let c = classification else { return [] }
        return c.resolutions.compactMap { r in
            if case .substituteNeedsReview(let s) = r.status { return (r.name, r.amount, s) }
            return nil
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Review substitutions")
                        .scaledFont(21, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text("You don't have these exact ingredients, but you have swaps that work. Confirm the ones you want to use.")
                        .scaledFont(13)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    if reviewRows.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .scaledFont(38).foregroundStyle(Color.stockedGreen)
                            Text("All substitutions confirmed.")
                                .scaledFont(15, weight: .semibold, design: .serif)
                                .foregroundStyle(session.themeTextColor)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 10) {
                                ForEach(reviewRows, id: \.name) { row in
                                    swapCard(row)
                                }
                            }
                        }
                    }

                    Button { dismiss() } label: {
                        Text("Done")
                            .scaledFont(15, weight: .semibold, design: .serif)
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                                .stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
        }
        .presentationDetents([.medium, .large])
        .task { recompute() }
    }

    private func recompute() {
        classification = CookNowCompute.classify(recipe: recipe, store: store, session: cookSession)
    }

    // MARK: Swap card

    private func swapCard(_ row: (name: String, amount: String, suggestion: String)) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(row.name.displayNormalized)
                    .scaledFont(15, weight: .semibold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                Image(systemName: "arrow.right")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                Text("you have: \(row.suggestion.displayNormalized)")
                    .scaledFont(13.5, weight: .semibold)
                    .foregroundStyle(Color.stockedGreen)
                Spacer()
            }

            if let note = guidance(for: row.name, substitute: row.suggestion) {
                Text(note)
                    .scaledFont(12)
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button {
                    confirm(row)
                } label: {
                    Label("Use This Swap", systemImage: "checkmark")
                        .scaledFont(12.5, weight: .semibold)
                        .foregroundStyle(Color.stockedGreen)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Color.stockedGreen.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .a11yButton("Use \(row.suggestion) instead of \(row.name)")

                Button {
                    addOriginalToGrocery(row)
                } label: {
                    Label(addedToGrocery.contains(row.name.lowercased()) ? "Added" : "Add to Grocery",
                          systemImage: addedToGrocery.contains(row.name.lowercased()) ? "checkmark" : "cart.badge.plus")
                        .scaledFont(12.5, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(Color.stockedGold.opacity(0.12))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(addedToGrocery.contains(row.name.lowercased()))
                .a11yButton("Add \(row.name) to the grocery list")
            }
        }
        .padding(14)
        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    /// Curated guidance for this pairing when the database has it — never invented.
    private func guidance(for ingredient: String, substitute: String) -> String? {
        guard let entry = StockedDatabase.shared.substitutions(for: ingredient) else { return nil }
        let target = substitute.lowercased()
        let hit = entry.substitutions.first {
            let s = $0.substitute.lowercased()
            return s.contains(target) || target.contains(s)
        }
        guard let hit, !hit.notes.isEmpty else { return nil }
        return hit.notes
    }

    private func confirm(_ row: (name: String, amount: String, suggestion: String)) {
        guard let cs = cookSession else { return }
        cs.confirmSubstitution(ingredient: row.name, substitute: row.suggestion)
        cs.stage(StagedInventoryChange(ingredientName: row.name, kind: .recordSubstitute,
                                       note: "Used \(row.suggestion.displayNormalized) instead"))
        HapticManager.light()
        recompute()
    }

    private func addOriginalToGrocery(_ row: (name: String, amount: String, suggestion: String)) {
        store.addGroceryItem(name: row.name)
        addedToGrocery.insert(row.name.lowercased())
        HapticManager.light()
    }
}
