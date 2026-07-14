// CookingIntentView.swift
// ─────────────────────────────────────────────────────────────────
// "You're starting with X. What do you want to do?"
//
// The pivot screen of the adaptive workspace. After an anchor is chosen, the
// user declares intent — and the whole downstream experience scopes to it.
// Crucially, the user is NEVER forced toward a full meal: "Just Make This"
// (entrée only) sits first and is framed as complete on its own.
//
// Routing by intent:
//   justMakeThis / trySomethingNew / useWhatIHave / useItUp
//        → standalone preparation discovery (Batch 8)
//   addSomething
//        → pick a scope, then discovery scoped to the add-on
//   buildFullMeal
//        → full-meal structures (Batch 8)
//   alreadyKnowPlan
//        → skip discovery, go straight to method + Before You Start (Batch 8)
//
// An effort control rides along so discovery and side suggestions can respect
// the user's real energy. Affirming, non-judgmental language throughout.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct CookingIntentView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var showAddScope = false
    @State private var goDiscovery = false
    @State private var goPlan = false

    private var anchor: String { cookSession?.anchorItem ?? "this" }

    var body: some View {
        StockedShell(showBack: true, titleText: "What Now?") {
            VStack(alignment: .leading, spacing: 18) {
                header
                effortStrip

                VStack(spacing: 10) {
                    ForEach(CookIntent.allCases) { intent in
                        intentCard(intent)
                    }
                }
                .padding(.horizontal, CookStyle.screenHPad)

                affirmation

                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goDiscovery) {
                if let cs = cookSession { PreparationDiscoveryView().environment(cs) }
            }
            .navigationDestination(isPresented: $goPlan) {
                if let cs = cookSession { CookingMethodComparisonView().environment(cs) }
            }
            .sheet(isPresented: $showAddScope) {
                if let cs = cookSession { addScopeSheet(cs) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(ImageFallbackService.emoji(for: anchor)).font(.system(size: 24))
                Text("You're starting with \(anchor.displayNormalized).")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("What do you want to do with it?")
                .font(.system(size: 14))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
        }
        .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
    }

    // MARK: Effort strip

    private var effortStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How much energy do you have?")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(session.themeTextColor.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(CookEffortLevel.allCases) { level in
                        let selected = cookSession?.effort == level
                        Button {
                            cookSession?.setEffort(selected ? nil : level)
                            HapticManager.select()
                        } label: {
                            Text(level.title)
                                .font(.system(size: 12.5, weight: .semibold))
                                .foregroundStyle(selected ? Color.stockedCharcoal : session.themeTextColor)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(selected ? Color.stockedGold : (dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6)))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .a11yButton("Effort level: \(level.title)")
                    }
                }
            }
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    // MARK: Intent cards

    private func intentCard(_ intent: CookIntent) -> some View {
        Button { choose(intent) } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(Color.stockedGold.opacity(0.14)).frame(width: 40, height: 40)
                    Image(systemName: intent.icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.stockedGold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(intent.title)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text(intent.blurb)
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }
        .buttonStyle(.plain)
        .a11yButton("\(intent.title). \(intent.blurb)")
    }

    private func choose(_ intent: CookIntent) {
        guard let cs = cookSession else { return }
        cs.setIntent(intent)
        HapticManager.light()
        switch intent {
        case .addSomething:
            showAddScope = true
        case .alreadyKnowPlan:
            cs.setStatus(.selectingMethod)
            goPlan = true
        case .buildFullMeal, .justMakeThis, .trySomethingNew, .useWhatIHave, .useItUp:
            cs.setStatus(.selectingPreparation)
            goDiscovery = true
        }
    }

    // MARK: Add-scope sheet

    private func addScopeSheet(_ cs: CookNowSession) -> some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("How much more are you trying to do?")
                        .font(.system(size: 18, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("The \(anchor.displayNormalized) is the star. We'll keep the extras light.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(AddSomethingScope.allCases) { scope in
                                Button {
                                    cs.setAddScope(scope)
                                    cs.setStatus(.selectingPreparation)
                                    showAddScope = false
                                    goDiscovery = true
                                } label: {
                                    HStack {
                                        Text(scope.title)
                                            .font(.system(size: 14, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor.opacity(0.3))
                                    }
                                    .padding(13)
                                    .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(20)
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Affirmation

    private var affirmation: some View {
        Text("The entrée is enough. You can stop after one thing, or keep going — your call.")
            .font(.system(size: 12))
            .foregroundStyle(session.themeTextColor.opacity(0.5))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, CookStyle.screenHPad + 8)
    }
}
