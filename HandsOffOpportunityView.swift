// HandsOffOpportunityView.swift
// Surfaced during a long unattended cooking window (pressure cook, slow cook,
// braise, roast). Doing NOTHING is a first-class, framed choice, and the other
// options fit the remaining time and free appliances. Chosen sides are recorded
// on the session. Opened from the cooking flow with an estimated remaining window.

import SwiftUI

struct HandsOffOpportunityView: View {
    /// Minutes of hands-off time remaining (caller estimates from the method).
    var remainingMinutes: Int = 30

    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    @Environment(\.dismiss) private var dismiss
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var equipmentService = EquipmentAvailabilityService()
    @State private var showQuickSides = false
    @State private var showLongerSides = false
    @State private var goCompounding = false

    private var anchor: String { cookSession?.anchorItem ?? "your food" }
    private var effort: CookEffortLevel { cookSession?.effort ?? .normal }

    /// The appliance the main cook is using (so we suggest OTHER ones).
    private var occupiedEquipment: KitchenEquipment? {
        guard let mid = cookSession?.cookingMethodID,
              let method = CookingMethodCatalog.method(id: mid) else { return nil }
        return method.requiredEquipment.first
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "While It Cooks") {
            VStack(alignment: .leading, spacing: 18) {
                header
                optionsList
                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goCompounding) {
                if let cs = cookSession { CompoundingPrepView().environment(cs) }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "timer").font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.stockedGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(anchor.displayNormalized) is cooking")
                        .font(.system(size: 19, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("About \(remainingMinutes) minutes hands-off remaining.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
            }
            Text("What would you like to do?")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(session.themeTextColor.opacity(0.7))
                .padding(.top, 2)
        }
        .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
    }

    private var optionsList: some View {
        VStack(spacing: 10) {
            optionCard(icon: "cup.and.saucer", title: "Nothing - the \(anchor.displayNormalized) is enough",
                       subtitle: "Rest or step away. This is a complete cook.", tint: Color.stockedGreen) {
                cookSession?.setStatus(.handsOff)
                HapticManager.light()
                dismiss()
            }

            if remainingMinutes >= 5 {
                optionCard(icon: "leaf", title: "Add a 5-minute side",
                           subtitle: quickSidesPreview, tint: Color.stockedGold) {
                    showQuickSides = true
                }
            }
            if remainingMinutes >= 15 {
                optionCard(icon: "flame", title: "Add a 15-minute side",
                           subtitle: longerSidesPreview, tint: Color.stockedGold) {
                    showLongerSides = true
                }
            }
            if let free = firstFreeAppliance {
                optionCard(icon: "oven", title: "Use your \(free.rawValue)",
                           subtitle: "It's free while the \(occupiedEquipment?.rawValue ?? "main pot") is busy.", tint: Color.stockedGold) {
                    showLongerSides = true
                }
            }
            if effort.allowsCompounding {
                optionCard(icon: "square.stack.3d.up", title: "Prep for another meal",
                           subtitle: "Get ahead on ingredients your upcoming meals share.", tint: Color.stockedGold) {
                    goCompounding = true
                }
            }
            optionCard(icon: "sparkles", title: "Clean as you go",
                       subtitle: "Knock out the dishes you're done with.", tint: Color.stockedGold) {
                HapticManager.light(); dismiss()
            }
        }
        .padding(.horizontal, CookStyle.screenHPad)
        .sheet(isPresented: $showQuickSides) { sideSheet(maxMinutes: 5, title: "5-minute sides") }
        .sheet(isPresented: $showLongerSides) { sideSheet(maxMinutes: 15, title: "15-minute sides") }
    }

    private func optionCard(icon: String, title: String, subtitle: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.14)).frame(width: 40, height: 40)
                    Image(systemName: icon).font(.system(size: 16, weight: .semibold)).foregroundStyle(tint)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14.5, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }
        .buttonStyle(.plain)
        .a11yButton("\(title). \(subtitle)")
    }

    private func sideCandidates(maxMinutes: Int) -> [String] {
        let quick = ["Bagged salad", "Sauteed spinach", "Microwave rice", "Sliced cucumber", "Steamed broccoli", "Buttered peas"]
        let longer = ["Rice", "Mashed potatoes", "Roasted vegetables", "Couscous", "Macaroni", "Garlic bread"]
        let pool = maxMinutes <= 5 ? quick : (quick + longer)
        let inStock = store.inventoryItems.filter { $0.effectiveLevel > 0 }.map { $0.name.lowercased() }
        let matched = pool.filter { idea in
            let words = idea.lowercased().split(separator: " ").map(String.init)
            return words.contains { w in inStock.contains { $0.contains(w) } }
        }
        return (matched.isEmpty ? Array(pool.prefix(4)) : Array((matched + pool).reduce(into: [String]()) { acc, x in if !acc.contains(x) { acc.append(x) } }.prefix(6)))
    }

    private var quickSidesPreview: String {
        let c = sideCandidates(maxMinutes: 5)
        return c.isEmpty ? "Quick options from your kitchen." : c.prefix(3).joined(separator: ", ")
    }
    private var longerSidesPreview: String {
        let c = sideCandidates(maxMinutes: 15)
        return c.isEmpty ? "Something more substantial." : c.prefix(3).joined(separator: ", ")
    }

    private func sideSheet(maxMinutes: Int, title: String) -> some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Fits your remaining window and uses what you have.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 8) {
                            ForEach(sideCandidates(maxMinutes: maxMinutes), id: \.self) { side in
                                let picked = cookSession?.selectedSideTitles.contains(side) ?? false
                                Button {
                                    if picked { cookSession?.removeSide(side) } else { cookSession?.addSide(side) }
                                    HapticManager.select()
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: picked ? "checkmark.circle.fill" : "plus.circle")
                                            .font(.system(size: 17))
                                            .foregroundStyle(picked ? Color.stockedGreen : Color.stockedGold)
                                        Text(side).font(.system(size: 14, weight: .semibold)).foregroundStyle(session.themeTextColor)
                                        Spacer()
                                    }
                                    .padding(13)
                                    .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    Button { showQuickSides = false; showLongerSides = false } label: {
                        Text("Done")
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 13)
                            .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL).stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .buttonStyle(.plain)
                }
                .padding(20)
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var firstFreeAppliance: KitchenEquipment? {
        let usable = equipmentService.usableEquipment(profile: store.cookingProfile)
        return usable.first { $0 != occupiedEquipment && ($0 == .airFryer || $0 == .oven || $0 == .stovetop || $0 == .riceCooker || $0 == .toasterOven) }
    }
}
