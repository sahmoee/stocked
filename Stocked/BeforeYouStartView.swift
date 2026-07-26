// BeforeYouStartView.swift
// ─────────────────────────────────────────────────────────────────
// The readiness + kitchen-setup screen that removes pre-cook friction. Not a
// generic ingredient list — a sectioned checklist so nothing heat-sensitive
// begins before chopping, measuring, and equipment setup are done:
//
//   1. Equipment      — what the chosen method needs, with a readiness state
//                        each (Ready / Needs cleaning / Needs assembly /
//                        Unavailable → swap method).
//   2. Pull From Inventory — anchor + supporting ingredients checked against
//                        real Stocked inventory (have vs needed, location,
//                        expiry, substitution).
//   3. Prep Before Heat — chop/measure/thaw/setup tasks derived from the
//                        method + ingredients.
//   4. Optional Decisions — add vegetables, make a side, cook-ahead, prep for
//                        another meal — all opt-in, none required.
//
// Progress is tracked on the CookNowSession so leaving and returning keeps the
// checklist state. Replaces the Batch 7 stub of the same name.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct BeforeYouStartView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var equipmentService = EquipmentAvailabilityService()
    @State private var goCook = false
    @State private var goMethod = false

    private var anchor: String { cookSession?.anchorItem ?? "" }
    private var profile: UserCookingProfile { store.cookingProfile }
    private var method: CookingMethod? {
        cookSession?.cookingMethodID.flatMap { CookingMethodCatalog.method(id: $0) }
    }

    var body: some View {
        StockedShell(showBack: true, titleText: "Before You Start") {
            VStack(alignment: .leading, spacing: 20) {
                header
                equipmentSection
                inventorySection
                prepSection
                optionalSection
                startButton
                Spacer(minLength: 20)
            }
            .navigationDestination(isPresented: $goCook) {
                cookingDestination
            }
            .navigationDestination(isPresented: $goMethod) {
                if let cs = cookSession { CookingMethodComparisonView().environment(cs) }
            }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Let's get set up")
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            if let method {
                Text("\(method.name) · \(anchor.displayNormalized)")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.stockedGold)
            }
            Text("Get everything ready before any heat. Check items off as you go.")
                .font(.system(size: 13))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
    }

    // MARK: 1. Equipment

    private var equipmentSection: some View {
        sectionCard(title: "Equipment", icon: "wrench.and.screwdriver") {
            let needed = method?.requiredEquipment ?? []
            if needed.isEmpty {
                bodyText("Any basic cookware works for this.")
            } else {
                VStack(spacing: 8) {
                    ForEach(needed) { eq in
                        equipmentRow(eq)
                    }
                }
            }
        }
    }

    private func equipmentRow(_ eq: KitchenEquipment) -> some View {
        let avail = equipmentService.availability(of: eq)
        let owned = equipmentService.owned(from: profile).contains(eq)
        return HStack(spacing: 10) {
            Text(eq.emoji).font(.system(size: 18)).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(eq.rawValue)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                Text(owned ? avail.label : "Not in your equipment list")
                    .font(.system(size: 11))
                    .foregroundStyle(avail.isUsable && owned ? Color.stockedGreen : Color.stockedGold)
            }
            Spacer()
            Menu {
                ForEach(EquipmentAvailability.allCases, id: \.self) { state in
                    Button { equipmentService.setAvailability(state, for: eq); HapticManager.select() } label: {
                        Label(state.label, systemImage: state.icon)
                    }
                }
                Button(role: .destructive) { goMethod = true } label: {
                    Label("Use a different method", systemImage: "arrow.triangle.2.circlepath")
                }
            } label: {
                Image(systemName: avail.isUsable && owned ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(avail.isUsable && owned ? Color.stockedGreen : Color.stockedGold)
            }
        }
        .padding(12)
        .background(dark ? Color.darkSurface.opacity(0.5) : Color.stockedWhite.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
    }

    // MARK: 2. Pull From Inventory

    /// The anchor plus common aromatics/liquid the method implies, matched to
    /// real inventory. We keep the supporting list conservative and honest.
    private var pullItems: [String] {
        var items = [anchor]
        if let method, method.moisture >= .high { items.append("cooking liquid") }
        items.append(contentsOf: ["onion", "garlic", "oil", "salt"])
        // De-dupe, drop empties.
        var seen = Set<String>(); var out: [String] = []
        for i in items where !i.isEmpty && seen.insert(i.lowercased()).inserted { out.append(i) }
        return out
    }

    private var inventorySection: some View {
        sectionCard(title: "Pull From Inventory", icon: "tray.and.arrow.down") {
            VStack(spacing: 8) {
                ForEach(pullItems, id: \.self) { name in
                    pullRow(name)
                }
            }
        }
    }

    private func pullRow(_ name: String) -> some View {
        let key = "pull::\(name.lowercased())"
        let done = cookSession?.isReadinessDone(key) ?? false
        let match = store.inventoryItems.first { looseContains($0.name, name) && $0.effectiveLevel > 0 }
        return Button {
            cookSession?.setReadinessDone(key, done: !done)
            HapticManager.select()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(done ? Color.stockedGreen : session.themeTextColor.opacity(0.3))
                Text(name.displayNormalized)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                    .strikethrough(done, color: session.themeTextColor.opacity(0.4))
                Spacer()
                if let match {
                    Text(match.zone)
                        .font(.system(size: 10.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                    if match.isExpiringSoonOrExpired {
                        Image(systemName: "clock.fill").font(.system(size: 9)).foregroundStyle(Color.stockedGold)
                    }
                } else {
                    let subs = store.inStockSubstitutes(for: name)
                    if let sub = subs.first {
                        Text("sub: \(sub.displayNormalized)")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(Color.stockedGold)
                    } else {
                        Text("not logged")
                            .font(.system(size: 10.5))
                            .foregroundStyle(session.themeTextColor.opacity(0.35))
                    }
                }
            }
            .padding(12)
            .background(dark ? Color.darkSurface.opacity(0.5) : Color.stockedWhite.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
        }
        .buttonStyle(.plain)
        .a11yButton("Pull \(name). \(done ? "Done" : "Not done")")
    }

    // MARK: 3. Prep Before Heat

    private var prepTasks: [String] {
        var tasks = ["Remove \(anchor.displayNormalized) from the fridge"]
        tasks.append("Slice onion")
        tasks.append("Mince garlic")
        if let method, method.moisture >= .high { tasks.append("Measure cooking liquid") }
        tasks.append("Set out tongs and a transfer plate")
        if let method, method.requiredEquipment.contains(.instantPot) {
            tasks.append("Confirm the sealing ring is installed and the valve moves")
        }
        if let method, method.browning >= .high {
            tasks.append("Pat the \(anchor.displayNormalized) dry for better browning")
        }
        return tasks
    }

    private var prepSection: some View {
        sectionCard(title: "Prep Before Heating Anything", icon: "list.bullet.clipboard") {
            VStack(spacing: 8) {
                ForEach(prepTasks, id: \.self) { task in
                    prepRow(task)
                }
            }
        }
    }

    private func prepRow(_ task: String) -> some View {
        let key = "prep::\(task.lowercased())"
        let done = cookSession?.isReadinessDone(key) ?? false
        return Button {
            cookSession?.setReadinessDone(key, done: !done)
            HapticManager.select()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(done ? Color.stockedGreen : session.themeTextColor.opacity(0.3))
                Text(task)
                    .font(.system(size: 13.5))
                    .foregroundStyle(session.themeTextColor)
                    .strikethrough(done, color: session.themeTextColor.opacity(0.4))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(dark ? Color.darkSurface.opacity(0.5) : Color.stockedWhite.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
        }
        .buttonStyle(.plain)
        .a11yButton("\(task). \(done ? "Done" : "Not done")")
    }

    // MARK: 4. Optional Decisions

    private var optionalDecisions: [String] {
        var out = ["Add vegetables to the pot?", "Cook now and serve later?", "Add one easy side?"]
        if let method, method.moisture >= .high { out.append("Make gravy from the cooking liquid?") }
        out.append("Save part of it for lunch?")
        return out
    }

    private var optionalSection: some View {
        sectionCard(title: "Optional Decisions", icon: "questionmark.circle") {
            VStack(alignment: .leading, spacing: 8) {
                bodyText("None of these are required — the entrée alone is a complete cook.")
                ForEach(optionalDecisions, id: \.self) { d in
                    HStack(spacing: 8) {
                        Image(systemName: "circle.dotted").font(.system(size: 13)).foregroundStyle(Color.stockedGold)
                        Text(d).font(.system(size: 12.5)).foregroundStyle(session.themeTextColor.opacity(0.7))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }

    // MARK: Start

    private var startButton: some View {
        VStack(spacing: 6) {
            Button {
                cookSession?.setStatus(.cooking)
                HapticManager.light()
                goCook = true
            } label: {
                Text("Start Cooking")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                    .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL).stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }
            .buttonStyle(.plain)
            Text("You can start even with items unchecked — this is your call.")
                .font(.system(size: 11))
                .foregroundStyle(session.themeTextColor.opacity(0.45))
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    /// Route into the existing cooking flow. If the anchor maps to a saved
    /// recipe, cook that; otherwise open the flashcard flow with a minimal
    /// step set so the path always completes.
    @ViewBuilder private var cookingDestination: some View {
        if let recipe = matchedRecipe {
            RecipeOverviewView(title: recipe.title, servings: cookSession?.servings ?? recipe.servings,
                               ingredients: recipe.ingredients.map { $0.amount.isEmpty ? $0.name : "\($0.amount) \($0.name)" },
                               steps: recipe.instructions,
                               cookTime: recipe.cookTime)
        } else {
            CookingFlashcardView(recipeTitle: anchor.displayNormalized,
                                 ingredients: pullItems.map { $0.displayNormalized },
                                 steps: prepTasks + ["Cook the \(anchor.displayNormalized) using your chosen method.",
                                                     "Check doneness and rest before serving."])
        }
    }

    private var matchedRecipe: UserRecipe? {
        store.cookCatalog.first { looseContains($0.title, anchor) }
    }

    // MARK: Helpers

    // Shared matcher — was a fourth copy of the substring rule.
    private func looseContains(_ a: String, _ b: String) -> Bool {
        KitchenAvailability.nameMatches(a, b)
    }

    private func sectionCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.stockedGold)
                Text(title).font(.system(size: 15, weight: .bold, design: .serif)).foregroundStyle(session.themeTextColor)
            }
            content()
        }
        .padding(.horizontal, CookStyle.screenHPad)
    }

    private func bodyText(_ t: String) -> some View {
        Text(t)
            .font(.system(size: 12.5))
            .foregroundStyle(session.themeTextColor.opacity(0.6))
            .fixedSize(horizontal: false, vertical: true)
    }
}
