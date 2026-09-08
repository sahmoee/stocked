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
    @Environment(\.stockedLayout) private var layoutMetrics

    @State private var localSession: CookNowSession? = nil
    private var cookSession: CookNowSession? { envSession ?? localSession }

    @State private var query = ""
    @State private var ideaText = ""
    @State private var goIntent = false
    @State private var showIdeaField = false

    var body: some View {
        StockedShell(showBack: true, titleText: "Start With Something") {
            LazyVStack(alignment: .leading, spacing: layoutMetrics.sectionSpacing) {
                header
                ideaEntry
                if !expiringItems.isEmpty { section("Use these soon", expiringItems, urgent: true) }
                proteinSection
                otherSection

                Spacer(minLength: layoutMetrics.sectionSpacing)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("What are you starting with?")
                .font(.stockedTitle)
                .foregroundStyle(session.themeTextColor)
            Text("Pick an ingredient, a protein, a leftover — anything. We'll figure out what to do with it next.")
                .font(.stockedBody)
                .foregroundStyle(session.themeSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            searchField
        }
        .padding(.horizontal, layoutMetrics.horizontalPadding)
        .padding(.top, 8)
    }

    private var searchField: some View {
        StockedSearchField(text: $query, prompt: "Search your kitchen")
    }

    // MARK: Idea entry ("I already know what I'm making")

    private var ideaEntry: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showIdeaField {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("What are you making?", text: $ideaText, axis: .vertical)
                        .font(.stockedBody)
                        .lineLimit(2...4)
                    Button {
                        startWithIdea()
                    } label: {
                        Label("Continue", systemImage: "arrow.right")
                    }
                    .stockedPrimary(accent: session.themeButtonColor)
                    .disabled(ideaText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                StockedActionRow(
                    title: "I already know what I'm making",
                    detail: "Skip discovery and go straight to prep.",
                    symbol: "hand.raised.fill",
                    action: { withAnimation { showIdeaField = true } }
                )
            }
        }
        .padding(.horizontal, layoutMetrics.horizontalPadding)
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
            .sorted {
                let lhs = $0.daysUntilExpiry ?? 99
                let rhs = $1.daysUntilExpiry ?? 99
                return lhs == rhs ? itemComesBefore($0, $1) : lhs < rhs
            }
    }

    /// Likely proteins, surfaced as a first-class starting point.
    private var proteinItems: [LocalInventoryItem] {
        return filteredInStock
            .filter { isLikelyProtein($0) && !$0.isExpiringSoonOrExpired }
            .sorted(by: itemComesBefore)
    }

    /// Product names often contain a meat word without being a protein anchor
    /// (beef broth, chicken bouillon) or contain “ground” as a preparation
    /// (coffee and pepper). Keep those pantry items out of the protein section.
    private func isLikelyProtein(_ item: LocalInventoryItem) -> Bool {
        if item.customCategory?.localizedCaseInsensitiveContains("protein") == true { return true }
        let name = item.name.lowercased()
        let pantryQualifiers = ["broth", "stock", "bouillon", "soup", "gravy", "sauce",
                                "seasoning", "pepper", "coffee", "flavor", "flavour"]
        guard !pantryQualifiers.contains(where: name.contains) else { return false }
        let proteinWords = ["chicken", "beef", "pork", "turkey", "lamb", "steak", "shrimp",
                            "fish", "salmon", "tuna", "bacon", "sausage", "tofu", "egg",
                            "thigh", "breast", "wings", "meatball"]
        return proteinWords.contains(where: name.contains)
    }

    private var otherItems: [LocalInventoryItem] {
        let expiringIDs = Set(expiringItems.map { $0.id })
        let proteinIDs = Set(proteinItems.map { $0.id })
        return filteredInStock.filter { !expiringIDs.contains($0.id) && !proteinIDs.contains($0.id) }
            .sorted(by: itemComesBefore)
    }

    /// A strict, deterministic display order keeps tiles anchored while sync and product
    /// enrichment update metadata in the background.
    private func itemComesBefore(_ lhs: LocalInventoryItem, _ rhs: LocalInventoryItem) -> Bool {
        let nameOrder = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
        if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
        let lhsBrand = lhs.brand ?? ""
        let rhsBrand = rhs.brand ?? ""
        let brandOrder = lhsBrand.localizedCaseInsensitiveCompare(rhsBrand)
        if brandOrder != .orderedSame { return brandOrder == .orderedAscending }
        if lhs.sizeAmount != rhs.sizeAmount { return (lhs.sizeAmount ?? 0) < (rhs.sizeAmount ?? 0) }
        return lhs.id.uuidString < rhs.id.uuidString
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
                .font(.stockedHeadline)
                .foregroundStyle(urgent ? session.accentColor : session.themeTextColor)
            LazyVGrid(columns: layoutMetrics.gridColumns(minimum: 150, maximum: 2, spacing: 10), spacing: 10) {
                ForEach(items) { item in
                    anchorTile(item, urgent: urgent)
                }
            }
        }
        .padding(.horizontal, layoutMetrics.horizontalPadding)
    }

    private func anchorTile(_ item: LocalInventoryItem, urgent: Bool) -> some View {
        Button { startWith(item) } label: {
            HStack(spacing: 10) {
                Text(ImageFallbackService.emoji(for: item.name)).font(.title3)
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name.displayNormalized)
                        .font(.stockedBodyBold)
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    if urgent, let d = item.daysUntilExpiry {
                        Text(d <= 0 ? "Use today" : "\(d)d left")
                            .font(.stockedCaption.weight(.semibold))
                            .foregroundStyle(session.accentColor)
                    } else {
                        Text(item.zone)
                            .font(.stockedCaption)
                            .foregroundStyle(session.themeSecondaryText)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(layoutMetrics.surfaceContentPadding)
            .frame(maxWidth: .infinity, minHeight: layoutMetrics.minimumControlHeight, alignment: .leading)
            .background(session.themeCardColor)
            .overlay(RoundedRectangle(cornerRadius: layoutMetrics.surfaceCornerRadius)
                .stroke(urgent ? session.accentColor.opacity(0.55) : session.themeTextColor.opacity(0.08), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: layoutMetrics.surfaceCornerRadius, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: layoutMetrics.surfaceCornerRadius, style: .continuous))
        }
        .buttonStyle(StockedWidgetButtonStyle())
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
