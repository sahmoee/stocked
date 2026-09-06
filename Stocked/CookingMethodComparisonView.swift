// CookingMethodComparisonView.swift
// ─────────────────────────────────────────────────────────────────
// Choose or confirm HOW to cook the anchor — by outcome and tradeoff, not by
// appliance list. Each method card explains texture, browning, moisture,
// active/total time, cleanup, attention, best use, cook-ahead suitability, and
// whether it frees other appliances. Combined-device workflows (sear → pressure
// cook) are shown as staged methods.
//
// Equipment gating: methods whose required equipment the user can't currently
// use are shown as unavailable with the blocking device named, and an inline
// equipment strip lets the user flip availability and watch the list
// recalculate immediately — honoring "I own an Instant Pot but it's dirty".
//
// Replaces the Batch 7 stub of the same name.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct CookingMethodComparisonView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var equipmentService = EquipmentAvailabilityService()
    @State private var goReady = false
    @State private var expanded: Set<String> = []

    private var anchor: String { cookSession?.anchorItem ?? "your dish" }
    private var profile: UserCookingProfile { store.cookingProfile }
    private var usable: Set<KitchenEquipment> { Set(equipmentService.usableEquipment(profile: profile)) }

    private var methods: [CookingMethod] {
        CookingMethodCatalog.candidates(forAnchor: anchor).sorted { a, b in
            let aAvail = a.isAvailable(usable: usable)
            let bAvail = b.isAvailable(usable: usable)
            if aAvail != bAvail { return aAvail }        // available first
            if a.activeMinutes != b.activeMinutes { return a.activeMinutes < b.activeMinutes }
            return a.name < b.name
        }
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Cooking Method") {
            VStack(alignment: .leading, spacing: 16) {
                header
                equipmentStrip
                VStack(spacing: 12) {
                    ForEach(methods) { method in
                        methodCard(method)
                    }
                }
                .padding(.horizontal, CookStyle.screenHPad)
                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goReady) {
                if let cs = cookSession { BeforeYouStartView().environment(cs) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How do you want to cook \(anchor.displayNormalized)?")
                .scaledFont(20, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Text("Each method gives you a different result. Pick the tradeoffs you want.")
                .scaledFont(13.5)
                .foregroundStyle(session.themeTextColor.opacity(0.55))
        }
        .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
    }

    // MARK: Equipment availability strip

    private var equipmentStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Your equipment right now")
                .scaledFont(12.5, weight: .semibold)
                .foregroundStyle(session.themeTextColor.opacity(0.6))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(equipmentService.owned(from: profile)) { eq in
                        Menu {
                            ForEach(EquipmentAvailability.allCases, id: \.self) { state in
                                Button {
                                    equipmentService.setAvailability(state, for: eq)
                                    HapticManager.select()
                                } label: { Label(state.label, systemImage: state.icon) }
                            }
                        } label: {
                            let avail = equipmentService.availability(of: eq)
                            HStack(spacing: 5) {
                                Text(eq.emoji).scaledFont(13)
                                Text(eq.rawValue).scaledFont(12, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                                Image(systemName: avail.isUsable ? "checkmark.circle.fill" : "xmark.circle.fill")
                                    .scaledFont(10)
                                    .foregroundStyle(avail.isUsable ? Color.stockedGreen : Color.stockedError.opacity(0.8))
                            }
                            .foregroundStyle(session.themeTextColor)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
                            .clipShape(Capsule())
                        }
                    }
                    if equipmentService.owned(from: profile).isEmpty {
                        Text("Set your equipment in your cooking profile to get tailored methods.")
                            .scaledFont(11.5)
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                }
                .stockedScrollTargetLayout()
            }
            .stockedHorizontalSnap()
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    // MARK: Method card

    private func methodCard(_ method: CookingMethod) -> some View {
        let available = method.isAvailable(usable: usable)
        let isOpen = expanded.contains(method.id)
        return VStack(alignment: .leading, spacing: 10) {
            // Title row
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(method.name)
                        .scaledFont(16, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text(method.resultSummary)
                        .scaledFont(12)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                if method.isCombined {
                    Text("2-step")
                        .scaledFont(9.5, weight: .bold)
                        .foregroundStyle(Color.stockedGold)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.stockedGold.opacity(0.12)).clipShape(Capsule())
                }
            }

            // Quick stats
            HStack(spacing: 14) {
                stat("clock", "\(method.activeMinutes)m active")
                stat("timer", "\(method.totalMinutes)m total")
                if method.goodForCookAhead { stat("calendar", "cook ahead") }
            }
            .scaledFont(11.5)
            .foregroundStyle(session.themeTextColor.opacity(0.6))

            if !available {
                let blocking = method.blockingEquipment(usable: usable).map { $0.rawValue }.joined(separator: ", ")
                Label(blocking.isEmpty ? "Equipment not available" : "Needs: \(blocking)", systemImage: "exclamationmark.triangle.fill")
                    .scaledFont(11.5, weight: .semibold)
                    .foregroundStyle(Color.stockedGold)
            }

            if isOpen {
                Divider().background(session.themeTextColor.opacity(0.1))
                detailGrid(method)
                Text(method.bestUseCase)
                    .scaledFont(12)
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                    .italic()
            }

            HStack(spacing: 8) {
                Button {
                    withAnimation { if isOpen { expanded.remove(method.id) } else { expanded.insert(method.id) } }
                } label: {
                    Text(isOpen ? "Less" : "Details")
                        .scaledFont(12.5, weight: .semibold)
                        .foregroundStyle(session.themeTextColor.opacity(0.7))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(dark ? Color.darkSurface.opacity(0.6) : Color.stockedWhite.opacity(0.5))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button { choose(method) } label: {
                    Text(available ? "Use This Method" : "Use Anyway")
                        .scaledFont(12.5, weight: .semibold)
                        .foregroundStyle(available ? Color.stockedWhite : session.themeTextColor)
                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                        .background(available ? (dark ? Color.darkSurface : Color.stockedCharcoal) : Color.stockedGold.opacity(0.14))
                        .overlay(RoundedRectangle(cornerRadius: 100).stroke(available && dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .a11yButton("Use \(method.name)")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.55))
        .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
            .stroke(available ? Color.clear : Color.stockedGold.opacity(0.25), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        .opacity(available ? 1 : 0.85)
    }

    private func stat(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) { Image(systemName: icon); Text(text) }
    }

    private func detailGrid(_ m: CookingMethod) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow("Texture", m.texture)
            detailRow("Browning", m.browning.label)
            detailRow("Moisture", m.moisture.label)
            detailRow("Cleanup", m.cleanup.label)
            detailRow("Attention", m.attention.label)
            if m.freesOtherAppliances {
                detailRow("Frees appliances", "Yes — cook a side meanwhile")
            }
            if m.isCombined {
                detailRow("Steps", m.stages.joined(separator: " → "))
            }
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .scaledFont(11.5, weight: .semibold)
                .foregroundStyle(session.themeTextColor.opacity(0.5))
                .frame(width: 100, alignment: .leading)
            Text(value)
                .scaledFont(11.5)
                .foregroundStyle(session.themeTextColor.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func choose(_ method: CookingMethod) {
        guard let cs = cookSession else { return }
        cs.setCookingMethod(method.id)
        // Record the method's equipment on the session for Before You Start.
        for eq in method.requiredEquipment { cs.selectEquipment(eq.rawValue) }
        for eq in equipmentService.owned(from: profile) where !equipmentService.availability(of: eq).isUsable {
            cs.markEquipmentUnavailable(eq.rawValue)
        }
        cs.setStatus(.gettingReady)
        HapticManager.light()
        goReady = true
    }
}
