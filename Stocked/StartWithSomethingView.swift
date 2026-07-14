// StartWithSomethingView.swift
// ─────────────────────────────────────────────────────────────────
// The broad entry point: begin a cooking session with an INGREDIENT, prepared
// item, protein, vegetable, starch, leftover, or a free-typed idea — not with
// a complete recipe. Whatever the user picks becomes the session's anchor.
//
// Deliberately NOT called "Build Around a Protein": the anchor may be a
// vegetable, a starch, a leftover, or an idea. "Build Around This" is an action
// AFTER selection, surfaced on the next screen (intent selection).
//
// Sources offered here:
//   • Inventory items (grouped, expiring surfaced first)
//   • "I already know what I'm making" free-text idea
// Selecting an anchor creates/updates the CookNowSession and pushes intent
// selection. Nothing here commits the user to a full meal.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct StartWithSomethingView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var envSession: CookNowSession?
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var localSession: CookNowSession? = nil
    private var cookSession: CookNowSession? { envSession ?? localSession }

    @State private var query = ""
    @State private var ideaText = ""
    @State private var goIntent = false
    @State private var showIdeaField = false

    var body: some View {
        StockedShell(showBack: true, titleText: "Start With Something") {
            VStack(alignment: .leading, spacing: 18) {
                header
                ideaEntry
                if !expiringItems.isEmpty { section("Use these soon", expiringItems, urgent: true) }
                proteinSection
                otherSection

                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goIntent) {
                if let cs = cookSession { CookingIntentView().environment(cs) }
            }
        }
        .task { ensureSession() }
    }

    private func ensureSession() {
        if envSession == nil && localSession == nil {
            localSession = CookNowSession(householdSize: store.cookingProfile.householdSize)
        }
    }

    // MARK: Header + search

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What are you starting with?")
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text("Pick an ingredient, a protein, a leftover — anything. We'll figure out what to do with it next.")
                .font(.system(size: 13.5))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            searchField
        }
        .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(session.themeTextColor.opacity(0.4))
            TextField("Search your kitchen", text: $query)
                .font(.system(size: 14))
                .foregroundStyle(session.themeTextColor)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.3))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    // MARK: Idea entry ("I already know what I'm making")

    private var ideaEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showIdeaField {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("e.g. marinated lamb chops, seared then pressure cooked", text: $ideaText, axis: .vertical)
                        .font(.system(size: 14))
                        .foregroundStyle(session.themeTextColor)
                        .lineLimit(1...3)
                        .padding(12)
                        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.7))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    Button {
                        startWithIdea()
                    } label: {
                        Text("Continue")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL).stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .buttonStyle(.plain)
                    .disabled(ideaText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button { withAnimation { showIdeaField = true } } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "hand.raised")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.stockedGold)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("I already know what I'm making")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(session.themeTextColor)
                            Text("Skip discovery — go straight to prep and cooking.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.3))
                    }
                    .padding(13)
                    .background(Color.stockedGold.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    // MARK: Inventory sections

    private var filteredInStock: [LocalInventoryItem] {
        let inStock = store.inventoryItems.filter { $0.effectiveLevel > 0 }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return inStock }
        return inStock.filter { $0.name.lowercased().contains(q) }
    }

    private var expiringItems: [LocalInventoryItem] {
        filteredInStock.filter { $0.isExpiringSoonOrExpired }
            .sorted { ($0.daysUntilExpiry ?? 99) < ($1.daysUntilExpiry ?? 99) }
    }

    /// Likely proteins, surfaced as a first-class starting point.
    private var proteinItems: [LocalInventoryItem] {
        let words = ["chicken","beef","pork","turkey","lamb","steak","shrimp","fish","salmon","tuna","bacon","sausage","tofu","egg","thigh","breast","ground"]
        return filteredInStock
            .filter { item in words.contains { item.name.lowercased().contains($0) } && !item.isExpiringSoonOrExpired }
    }

    private var otherItems: [LocalInventoryItem] {
        let expiringIDs = Set(expiringItems.map { $0.id })
        let proteinIDs = Set(proteinItems.map { $0.id })
        return filteredInStock.filter { !expiringIDs.contains($0.id) && !proteinIDs.contains($0.id) }
            .sorted { $0.name < $1.name }
    }

    private var proteinSection: some View {
        Group { if !proteinItems.isEmpty { section("Proteins", proteinItems, urgent: false) } }
    }
    private var otherSection: some View {
        Group { if !otherItems.isEmpty { section("Everything else", otherItems, urgent: false) } }
    }

    private func section(_ title: String, _ items: [LocalInventoryItem], urgent: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 15, weight: .bold, design: .serif))
                .foregroundStyle(urgent ? Color.stockedGold : session.themeTextColor)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(items) { item in
                    anchorTile(item, urgent: urgent)
                }
            }
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    private func anchorTile(_ item: LocalInventoryItem, urgent: Bool) -> some View {
        Button { startWith(item) } label: {
            HStack(spacing: 8) {
                Text(ImageFallbackService.emoji(for: item.name)).font(.system(size: 20))
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name.displayNormalized)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                        .lineLimit(1)
                    if urgent, let d = item.daysUntilExpiry {
                        Text(d <= 0 ? "Use today" : "\(d)d left")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.stockedGold)
                    } else {
                        Text(item.zone)
                            .font(.system(size: 10.5))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                .stroke(urgent ? Color.stockedGold.opacity(0.35) : Color.clear, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
        .a11yButton("Start with \(item.name)")
    }

    // MARK: Selection actions

    private func startWith(_ item: LocalInventoryItem) {
        guard let cs = cookSession else { return }
        cs.setAnchor(item: item.name,
                     source: item.isExpiringSoonOrExpired ? .expiringIngredient : .inventoryItem,
                     inventoryItemID: item.id)
        cs.selectedIngredient = item.name
        cs.setStatus(.selectingIntent)
        HapticManager.light()
        goIntent = true
    }

    private func startWithIdea() {
        guard let cs = cookSession else { return }
        let idea = ideaText.trimmingCharacters(in: .whitespaces)
        cs.setAnchor(item: idea, source: .userIdea)
        cs.selectedIngredient = idea
        // A typed idea implies the user already has a plan.
        cs.setIntent(.alreadyKnowPlan)
        cs.setStatus(.selectingMethod)
        HapticManager.light()
        goIntent = true
    }
}
