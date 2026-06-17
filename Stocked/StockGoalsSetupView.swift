// StockGoalsSetupView.swift — the "what does stocked mean to you?" stepped quiz.
//
// A light, guided quiz: one staple group per step (far less overwhelming than one long
// list), an intro that frames the question, and a review step to add your own + confirm.
// Saving writes the chosen staples to GuestDataStore and flips stockGoalsConfigured, which
// upgrades the Daily Brief's "Inventory Status" % from average-fill to a staples ratio —
// i.e. the exact same result as the old single-screen version, just gathered as a quiz.
import SwiftUI

struct StockGoalsSetupView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme

    @State private var selected: Set<String>
    @State private var extras: [String]
    @State private var newStaple: String = ""
    @State private var step: Int = 0

    private var store: GuestDataStore { session.guestStore }
    private var cats: [StapleCategory] { StapleCategory.selectable }
    /// 0 = intro · 1...cats.count = one category each · cats.count+1 = review & additions.
    private var lastStep: Int { cats.count + 1 }

    init(existing: [String], configured: Bool) {
        if configured && !existing.isEmpty {
            _selected = State(initialValue: Set(existing))
            let known = Set(StapleCategory.selectable.flatMap { $0.defaults }.map { $0.lowercased() })
            _extras  = State(initialValue: existing.filter { !known.contains($0.lowercased()) })
        } else {
            _selected = State(initialValue: Set(StapleCategory.selectable.flatMap { $0.defaults }))
            _extras  = State(initialValue: [])
        }
    }

    // MARK: Theme
    private var dark: Bool { scheme == .dark }
    private var bg: Color { dark ? Color.stockedBlack : Color.stockedBg }
    private var primaryText: Color { dark ? Color.stockedWhite : Color.stockedCharcoal }
    private var chipSurface: Color { dark ? Color.white.opacity(0.08) : Color.stockedWhite.opacity(0.85) }
    private var chipBorder: Color { dark ? Color.white.opacity(0.18) : Color.stockedCharcoal.opacity(0.18) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                progressBar
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        stepContent
                        Color.clear.frame(height: 8)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                navBar
            }
            .background(bg.ignoresSafeArea())
            .navigationTitle("Kitchen Goals")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.foregroundStyle(primaryText)
                }
            }
        }
    }

    // MARK: Progress
    private var progressBar: some View {
        HStack(spacing: 4) {
            ForEach(0...lastStep, id: \.self) { i in
                Capsule()
                    .fill(i <= step ? Color.stockedGreen : primaryText.opacity(0.15))
                    .frame(height: 4)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: step)
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 2)
    }

    // MARK: Steps
    @ViewBuilder private var stepContent: some View {
        if step == 0 {
            introStep
        } else if step <= cats.count {
            categoryStep(cats[step - 1])
        } else {
            reviewStep
        }
    }

    private var introStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("What does “stocked” mean to you?")
                .font(.system(size: 24, weight: .bold, design: .serif))
                .foregroundStyle(primaryText)
            Text("A few quick taps — pick the staples you like to keep on hand, one group at a time. We’ll track how many you actually have and turn that into your real kitchen stock level.")
                .font(.system(size: 15))
                .foregroundStyle(primaryText.opacity(0.7))
            Label("Takes about 30 seconds", systemImage: "clock")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.stockedGreen)
                .padding(.top, 4)
        }
    }

    @ViewBuilder
    private func categoryStep(_ cat: StapleCategory) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(cat.icon)  \(cat.rawValue.uppercased())")
                .font(.system(size: 13, weight: .bold))
                .tracking(1)
                .foregroundStyle(Color.stockedGreen)
            Text("Which of these do you keep stocked?")
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(primaryText)
            Text("Tap the ones you usually have on hand.")
                .font(.system(size: 13))
                .foregroundStyle(primaryText.opacity(0.55))
            chipGrid(cat.defaults)
                .padding(.top, 2)
        }
    }

    private var reviewStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Anything we missed?")
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(primaryText)
            Text("Add your own staples, then you’re all set.")
                .font(.system(size: 13))
                .foregroundStyle(primaryText.opacity(0.55))
            addOwnField
            if !extras.isEmpty {
                Text("➕  Your additions")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(primaryText)
                chipGrid(extras)
            }
            Text("\(selected.count) staple\(selected.count == 1 ? "" : "s") selected")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.stockedGreen)
                .padding(.top, 4)
        }
    }

    // MARK: Nav bar
    private var navBar: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button { withAnimation(.easeInOut(duration: 0.2)) { step -= 1 } } label: {
                    Text("Back")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(primaryText)
                        .padding(.horizontal, 20).padding(.vertical, 13)
                        .background(chipSurface)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                }.buttonStyle(.plain)
            }
            Spacer()
            if step < lastStep {
                Button { withAnimation(.easeInOut(duration: 0.2)) { step += 1 } } label: {
                    Text(step == 0 ? "Start" : "Next")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 13)
                        .background(Color.stockedGold)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                }.buttonStyle(.plain)
            } else {
                Button { save() } label: {
                    Text("Save")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 13)
                        .background(selected.isEmpty ? Color.stockedGreen.opacity(0.4) : Color.stockedGreen)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                }.buttonStyle(.plain).disabled(selected.isEmpty)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(bg)
    }

    // MARK: Chips
    private func chipGrid(_ items: [String]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items, id: \.self) { chip($0) }
        }
    }

    private func chip(_ item: String) -> some View {
        let isSel = selected.contains(item)
        return Button { toggle(item) } label: {
            Text(item)
                .font(.system(size: 14, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(isSel ? Color.stockedGreen : chipSurface)
                .foregroundStyle(isSel ? Color.white : primaryText)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(isSel ? Color.clear : chipBorder, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private var addOwnField: some View {
        HStack(spacing: 10) {
            TextField("Add your own staple", text: $newStaple)
                .textInputAutocapitalization(.words)
                .submitLabel(.done)
                .onSubmit(addCustom)
                .padding(.horizontal, 14).padding(.vertical, 11)
                .background(chipSurface)
                .foregroundStyle(primaryText)
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd).stroke(chipBorder, lineWidth: 1))
            Button(action: addCustom) {
                Text("Add")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 11)
                    .background(Color.stockedGold)
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }
            .buttonStyle(.plain)
            .disabled(newStaple.trimmingCharacters(in: .whitespaces).isEmpty)
            .opacity(newStaple.trimmingCharacters(in: .whitespaces).isEmpty ? 0.5 : 1)
        }
    }

    // MARK: Actions
    private func toggle(_ item: String) {
        if selected.contains(item) { selected.remove(item) } else { selected.insert(item) }
    }

    private func addCustom() {
        let name = newStaple.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let exists = selected.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
            || extras.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        if !exists { extras.append(name) }
        selected.insert(name)
        newStaple = ""
    }

    private func save() {
        let ordered = StapleCategory.selectable.flatMap { $0.defaults }.filter { selected.contains($0) }
            + extras.filter { selected.contains($0) }
        store.stockStaples = ordered
        store.stockGoalsConfigured = true
        dismiss()
    }
}
