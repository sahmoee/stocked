// CookWorkspaceDestinations.swift
// ─────────────────────────────────────────────────────────────────
// Remaining transitional destinations for the adaptive workspace. Preparation
// discovery, cooking method comparison, and Before You Start have graduated to
// their own dedicated files with full logic (batch 8). What stays here are the
// hub entry points still being built out: Makeable Now, Finish & Serve, and
// Use Something Up. None are dead ends — each routes somewhere useful and
// preserves the session.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

// MARK: - Makeable Now hub (stub → Batch 8)

/// Browse things makeable from current inventory, by category (entrées, sides,
/// meals, components, sauces, quick, use-soon). For now routes to the shared
/// tiered results; Batch 8 adds dish-role category tabs.
struct MakeableNowView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    private var dark: Bool { session.isDarkMode }
    @State private var goResults = false

    var body: some View {
        StockedShell(showBack: true, titleText: "Makeable Now") {
            VStack(alignment: .leading, spacing: 14) {
                Text("What you can make right now")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
                Button { goResults = true } label: {
                    Text("See All Matches")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                        .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL).stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, CookStyle.screenHPad)
                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goResults) {
                if let cs = cookSession { CookNowResultsView(focus: .readyFirst).environment(cs) }
                else { CookNowResultsView(focus: .readyFirst) }
            }
        }
    }
}

// MARK: - Use Something Up (routes to existing use-it-up path)

/// Prioritize expiring, open, or leftover ingredients as anchors.
struct UseSomethingUpView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }
    @State private var goStart = false

    private var expiring: [LocalInventoryItem] {
        store.inventoryItems.filter { $0.effectiveLevel > 0 && $0.isExpiringSoonOrExpired }
            .sorted { ($0.daysUntilExpiry ?? 99) < ($1.daysUntilExpiry ?? 99) }
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Use Something Up") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Let's use what needs using")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

                if expiring.isEmpty {
                    Text("Nothing's expiring soon — your kitchen's in good shape.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .padding(.horizontal, CookStyle.screenHPad)
                } else {
                    VStack(spacing: 8) {
                        ForEach(expiring.prefix(10)) { item in
                            Button { startWith(item) } label: {
                                HStack(spacing: 10) {
                                    Text(ImageFallbackService.emoji(for: item.name)).font(.system(size: 20))
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.name.displayNormalized)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor)
                                        Text((item.daysUntilExpiry ?? 0) <= 0 ? "Use today" : "\(item.daysUntilExpiry ?? 0)d left")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                                }
                                .padding(13)
                                .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                                .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd).stroke(Color.stockedGold.opacity(0.3), lineWidth: 1))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            }
                            .buttonStyle(.plain)
                            .a11yButton("Use up \(item.name)")
                        }
                    }
                    .padding(.horizontal, CookStyle.screenHPad)
                }

                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goStart) {
                if let cs = cookSession { CookingIntentView().environment(cs) }
            }
        }
        .task {
            if cookSession == nil {
                // Standalone entry gets its own session for the flow.
            }
        }
    }

    private func startWith(_ item: LocalInventoryItem) {
        guard let cs = cookSession else { return }
        cs.setAnchor(item: item.name, source: .expiringIngredient, inventoryItemID: item.id)
        cs.selectedIngredient = item.name
        cs.setIntent(.useItUp)
        cs.setStatus(.selectingIntent)
        HapticManager.light()
        goStart = true
    }
}
