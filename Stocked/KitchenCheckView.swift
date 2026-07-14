// KitchenCheckView.swift
// ─────────────────────────────────────────────────────────────────
// The pre-cook reality check: "the app says you have these — still true?"
//
// For each required ingredient the user can answer Have it / Out / Not sure.
// Answers are MEAL-ONLY overrides stored on the CookNowSession — they change
// this recipe's readiness immediately (live recalculation through the same
// engine) but never silently rewrite permanent inventory. Each changed row
// offers an explicit "also update my inventory" stage toggle; staged changes
// are collected for the Inventory Update Review and applied exactly once.
//
// "Not sure" is visible uncertainty: it blocks the "Kitchen Confirmed" state
// (the Continue button says so) but never traps the user — Continue anyway is
// always available.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct KitchenCheckView: View {
    let recipe: UserRecipe

    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var envSession: CookNowSession?
    @Environment(\.dismiss) private var dismiss
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    // Works standalone too: if no Cook Now session is in the environment,
    // a local one holds the overrides for this visit.
    @State private var localSession: CookNowSession? = nil
    private var cookSession: CookNowSession? { envSession ?? localSession }

    @State private var classification: ClassifiedRecipe? = nil
    @State private var stagedRows: Set<String> = []       // rows with "also update inventory" on
    @State private var showInventoryReview = false

    var body: some View {
        StockedShell(showBack: true, titleText: "Kitchen Check") {
            VStack(alignment: .leading, spacing: 14) {
                Text("The app thinks you have these. Anything changed?")
                    .font(.system(size: 13.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

                if let c = classification {
                    VStack(spacing: 10) {
                        ForEach(c.resolutions) { r in
                            row(r)
                        }
                    }
                    .padding(.horizontal, CookStyle.screenHPad)

                    summaryFooter(c)
                } else {
                    ProgressView().frame(maxWidth: .infinity).padding(.vertical, 40)
                }

                Spacer(minLength: 20)
            }
        }
        .task { bootstrap() }
        .onChange(of: store.inventoryRevision) { _, _ in recompute() }
        .sheet(isPresented: $showInventoryReview, onDismiss: { dismiss() }) {
            if let cs = cookSession {
                InventoryUpdateReviewView().environment(session).environment(cs)
            }
        }
    }

    // MARK: Data

    private func bootstrap() {
        if envSession == nil && localSession == nil {
            localSession = CookNowSession(householdSize: store.cookingProfile.householdSize)
        }
        recompute()
    }

    private func recompute() {
        classification = CookNowCompute.classify(recipe: recipe, store: store, session: cookSession)
    }

    // MARK: Rows

    private func row(_ r: IngredientResolution) -> some View {
        let current = cookSession?.override(for: r.name)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                statusIcon(r)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.name.displayNormalized)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text(statusText(r))
                        .font(.system(size: 11.5))
                        .foregroundStyle(statusColor(r).opacity(0.9))
                }
                Spacer()
                if !r.amount.isEmpty {
                    Text(r.amount)
                        .font(.system(size: 11.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                }
            }

            if case .optional = r.status {} else {
                HStack(spacing: 8) {
                    answerChip("Have it", "checkmark", Color.stockedGreen,
                               selected: current == .haveIt) { answer(r, .haveIt) }
                    answerChip("Out", "xmark", Color.stockedError.opacity(0.85),
                               selected: current == .out) { answer(r, .out) }
                    answerChip("Not sure", "questionmark", Color.stockedGold,
                               selected: current == .notSure) { answer(r, .notSure) }
                }

                if let current, current != .notSure {
                    Toggle(isOn: stageBinding(r, current)) {
                        Text("Also update my inventory")
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeTextColor.opacity(0.6))
                    }
                    .toggleStyle(.switch)
                    .tint(Color.stockedGold)
                    .padding(.top, 2)
                }
            }
        }
        .padding(14)
        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    private func answer(_ r: IngredientResolution, _ value: IngredientOverride) {
        guard let cs = cookSession else { return }
        // Tap again to clear.
        if cs.override(for: r.name) == value {
            cs.setOverride(nil, for: r.name)
            unstage(r)
        } else {
            cs.setOverride(value, for: r.name)
            if value == .notSure { unstage(r) }
        }
        HapticManager.select()
        recompute()
    }

    private func stageBinding(_ r: IngredientResolution, _ current: IngredientOverride) -> Binding<Bool> {
        Binding(
            get: { stagedRows.contains(r.id) },
            set: { on in
                guard let cs = cookSession else { return }
                if on {
                    stagedRows.insert(r.id)
                    let kind: StagedInventoryChange.Kind = (current == .haveIt || current == .enough)
                        ? .markAvailable : .markEmpty
                    cs.stage(StagedInventoryChange(ingredientName: r.name, kind: kind,
                                                   note: "From Kitchen Check"))
                } else {
                    unstage(r)
                }
            }
        )
    }

    private func unstage(_ r: IngredientResolution) {
        guard let cs = cookSession else { return }
        stagedRows.remove(r.id)
        for change in cs.pendingChanges
        where change.ingredientName.lowercased() == r.name.lowercased() && change.note == "From Kitchen Check" {
            cs.unstage(change.id)
        }
    }

    // MARK: Status presentation

    private func statusIcon(_ r: IngredientResolution) -> some View {
        Image(systemName: {
            switch r.status {
            case .inStock:                 return "checkmark.circle.fill"
            case .substituted:             return "arrow.triangle.swap"
            case .substituteNeedsReview:   return "arrow.triangle.swap"
            case .missing:                 return "cart.badge.plus"
            case .unconfirmed:             return "questionmark.circle.fill"
            case .optional:                return "circle.dotted"
            }
        }())
        .font(.system(size: 16, weight: .semibold))
        .foregroundStyle(statusColor(r))
        .frame(width: 24)
    }

    private func statusColor(_ r: IngredientResolution) -> Color {
        switch r.status {
        case .inStock, .substituted:     return Color.stockedGreen
        case .substituteNeedsReview:     return Color.stockedGold
        case .missing:                   return Color.stockedError.opacity(0.85)
        case .unconfirmed:               return Color.stockedGold
        case .optional:                  return session.themeTextColor.opacity(0.4)
        }
    }

    private func statusText(_ r: IngredientResolution) -> String {
        switch r.status {
        case .inStock:                          return "In stock"
        case .substituted(let with):            return "Using \(with.displayNormalized) as a swap"
        case .substituteNeedsReview(let s):     return "Swap available: \(s.displayNormalized) — review first"
        case .missing:                          return "Not in stock"
        case .unconfirmed:                      return "Marked not sure"
        case .optional:                         return "Optional"
        }
    }

    // MARK: Footer

    private func summaryFooter(_ c: ClassifiedRecipe) -> some View {
        VStack(spacing: 10) {
            Text(c.groupedSummary.isEmpty ? "All set" : c.groupedSummary)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(session.themeTextColor.opacity(0.65))

            Button {
                finish()
            } label: {
                Text(continueLabel(c))
                    .font(.system(size: 15.5, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                    .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                        .stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }
            .buttonStyle(.plain)
            .a11yButton(continueLabel(c))

            if c.unconfirmedCount > 0 {
                Text("Resolve the \"not sure\" items to fully confirm your kitchen — or continue anyway.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, CookStyle.screenHPad)
        .padding(.top, 6)
    }

    private func continueLabel(_ c: ClassifiedRecipe) -> String {
        if c.unconfirmedCount > 0 { return "Continue Anyway" }
        if c.missingCount > 0 { return "Continue — \(c.missingCount) Still Missing" }
        return "Kitchen Confirmed — Continue"
    }

    private func finish() {
        HapticManager.light()
        if let cs = cookSession, !cs.pendingChanges.isEmpty {
            showInventoryReview = true       // review staged writes, then dismiss
        } else {
            dismiss()
        }
    }
}
