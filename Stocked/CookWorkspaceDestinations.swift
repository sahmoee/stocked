// CookWorkspaceDestinations.swift
// ─────────────────────────────────────────────────────────────────
// Transitional destinations for the adaptive workspace. Batch 7 wires the
// full navigation graph (Start With Something → intent → discovery / method /
// Before You Start) and the Cook hub entry points. These screens are
// functional routing shells that lean on already-shipped surfaces
// (SmartRecommendation, CookNowResults, RefreshKitchen) so the whole flow is
// usable now; Batch 8 replaces the bodies with the full standalone-preparation
// feed, method comparison, and Before You Start logic.
//
// They are intentionally thin but never dead ends — each routes the user
// somewhere useful and preserves the session.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

// MARK: - Preparation discovery (intent-scoped)

/// Standalone-preparation discovery, scoped by the session's intent. For now it
/// hands off to the shared recommendation/results surfaces with the anchor as
/// the ingredient; Batch 8 makes this a dedicated standalone-entrée feed with
/// dish-role filtering, "cook now serve later", freezes-well, and technique tags.
struct PreparationDiscoveryView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    private var dark: Bool { session.isDarkMode }

    @State private var goRecommend = false
    @State private var goResults = false

    private var anchor: String { cookSession?.anchorItem ?? "" }
    private var intent: CookIntent { cookSession?.intent ?? .justMakeThis }

    var body: some View {
        StockedShell(showBack: true, titleText: title) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(heading)
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subheading)
                        .font(.system(size: 13.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

                VStack(spacing: 10) {
                    primaryButton(intent == .buildFullMeal ? "See Meal Ideas" : "See Preparations") {
                        goRecommend = true
                    }
                    secondaryButton("Browse All Matches") { goResults = true }
                }
                .padding(.horizontal, CookStyle.screenHPad)

                Text("Pick one and stop there, or build from it — you decide how far to go.")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, CookStyle.screenHPad + 8)

                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goRecommend) {
                if let cs = cookSession {
                    SmartRecommendationView(mode: anchor.isEmpty ? .best : .ingredient(anchor)).environment(cs)
                }
            }
            .navigationDestination(isPresented: $goResults) {
                if let cs = cookSession {
                    CookNowResultsView(focus: .readyFirst).environment(cs)
                }
            }
        }
    }

    private var title: String {
        switch intent {
        case .buildFullMeal:   return "Meal Ideas"
        case .trySomethingNew: return "Something New"
        case .useItUp:         return "Use It Up"
        default:               return "Preparations"
        }
    }
    private var heading: String {
        switch intent {
        case .justMakeThis:    return "Ways to make \(anchor.displayNormalized)"
        case .addSomething:    return "\(anchor.displayNormalized), plus a little more"
        case .buildFullMeal:   return "Full meals around \(anchor.displayNormalized)"
        case .trySomethingNew: return "Try something new with \(anchor.displayNormalized)"
        case .useWhatIHave:    return "Most makeable with \(anchor.displayNormalized)"
        case .useItUp:         return "Use up \(anchor.displayNormalized)"
        case .alreadyKnowPlan: return anchor.displayNormalized
        }
    }
    private var subheading: String {
        switch intent {
        case .justMakeThis:    return "Standalone preparations. No sides required — cook it and stop if you like."
        case .addSomething:    return "The star stays simple; we'll keep the extras light."
        case .buildFullMeal:   return "Complete meal structures built around your anchor."
        case .trySomethingNew: return "Flavors and techniques outside your usual rotation."
        case .useWhatIHave:    return "Ranked by what you can make right now."
        case .useItUp:         return "Built around what's expiring or already open."
        case .alreadyKnowPlan: return "Let's get to cooking."
        }
    }

    private func primaryButton(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(Color.stockedWhite)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL).stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
        }
        .buttonStyle(.plain)
    }
    private func secondaryButton(_ t: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(t)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(session.themeTextColor)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Cooking method comparison (stub → Batch 8)

/// Explains cooking-method tradeoffs (texture, browning, active time, cleanup,
/// cook-ahead suitability, simultaneous-appliance use) and combined-device
/// workflows. Batch 8 builds the full comparison + equipment gating; this shell
/// confirms the anchor and moves into Before You Start.
struct CookingMethodComparisonView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    private var dark: Bool { session.isDarkMode }
    @State private var goReady = false

    private var anchor: String { cookSession?.anchorItem ?? "your dish" }

    var body: some View {
        StockedShell(showBack: true, titleText: "Cooking Method") {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("How do you want to cook \(anchor.displayNormalized)?")
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("We'll compare the tradeoffs — texture, effort, and time — and check your equipment. Full comparison is coming; for now, continue to get set up.")
                        .font(.system(size: 13.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

                Button { cookSession?.setStatus(.gettingReady); goReady = true } label: {
                    Text("Get Ready to Cook")
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
            .navigationDestination(isPresented: $goReady) {
                if let cs = cookSession { BeforeYouStartView().environment(cs) }
            }
        }
    }
}

// MARK: - Before You Start (stub → Batch 8)

/// The readiness + kitchen-setup screen (equipment, pull-from-inventory, prep,
/// optional decisions). Batch 8 builds the full sectioned checklist; this shell
/// links onward to the existing cooking flow so the path is complete today.
struct BeforeYouStartView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?

    var body: some View {
        StockedShell(showBack: true, titleText: "Before You Start") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Getting your kitchen ready")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
                Text("Equipment, ingredients to pull, prep tasks, and optional decisions will appear here. Full checklist coming in the next update.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.horizontal, CookStyle.screenHPad)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 20)
            }
        }
    }
}

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

// MARK: - Finish & Serve (stub → later batch)

/// Food cooked earlier and intended for an upcoming meal — reheat + finish
/// guidance. Batch on cook-ahead builds this out against the meal planner.
struct FinishAndServeView: View {
    @Environment(AppSession.self) var session

    var body: some View {
        StockedShell(showBack: true, titleText: "Finish & Serve") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cooked ahead, ready to finish")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
                Text("Meals you cooked early will appear here with reheat and finishing steps. Coming with cook-ahead support.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.horizontal, CookStyle.screenHPad)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 20)
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
