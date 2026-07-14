// InventoryUpdateReviewView.swift
// ─────────────────────────────────────────────────────────────────
// The single reconciliation point where session learnings become permanent
// inventory. Everything the user staged during Kitchen Check, substitution
// review, or cooking arrives here as explicit line items:
//
//   "Mark chicken thighs as available"        [on]
//   "Mark buttermilk as empty"                [on]
//   "Used half and half instead of cream"     [on]
//
// The user can toggle rows off, apply all, or skip entirely. Mutations go
// through the SAME store APIs the rest of the app uses (confirm / level /
// add / grocery), so sync and logging behave identically — and each staged
// change is marked applied on the session afterward, guaranteeing a change
// is never applied twice even if the sheet reappears.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct InventoryUpdateReviewView: View {
    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    @Environment(\.dismiss) private var dismiss
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var enabled: Set<UUID> = []
    @State private var seeded = false

    private var changes: [StagedInventoryChange] { cookSession?.pendingChanges ?? [] }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Update your inventory?")
                        .font(.system(size: 21, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("These changes come from what you told us while cooking. Apply the ones that should stick.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    if changes.isEmpty {
                        Text("Nothing to update — you're all set.")
                            .font(.system(size: 13.5))
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                            .frame(maxWidth: .infinity).padding(.vertical, 30)
                    } else {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 8) {
                                ForEach(changes) { change in
                                    row(change)
                                }
                            }
                        }
                    }

                    VStack(spacing: 8) {
                        Button { apply() } label: {
                            Text(applyLabel)
                                .font(.system(size: 15, weight: .semibold, design: .serif))
                                .foregroundStyle(Color.stockedWhite)
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                                .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                                    .stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                        }
                        .buttonStyle(.plain)
                        .disabled(changes.isEmpty)

                        Button { dismiss() } label: {
                            Text("Skip — keep inventory as is")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
                .padding(20)
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            if !seeded {
                enabled = Set(changes.map { $0.id })   // default: everything on
                seeded = true
            }
        }
    }

    private var applyLabel: String {
        let n = enabled.count
        if n == 0 { return "Apply Nothing" }
        if n == changes.count { return "Apply All (\(n))" }
        return "Apply Selected (\(n))"
    }

    // MARK: Row

    private func row(_ change: StagedInventoryChange) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon(change.kind))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.stockedGold)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(label(change))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                if !change.note.isEmpty {
                    Text(change.note)
                        .font(.system(size: 11))
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                }
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { enabled.contains(change.id) },
                set: { on in
                    if on { enabled.insert(change.id) } else { enabled.remove(change.id) }
                }
            ))
            .labelsHidden()
            .tint(Color.stockedGold)
        }
        .padding(12)
        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
    }

    private func icon(_ kind: StagedInventoryChange.Kind) -> String {
        switch kind {
        case .markAvailable:    return "checkmark.circle"
        case .markEmpty:        return "xmark.circle"
        case .reduceQuantity:   return "minus.circle"
        case .addItem:          return "plus.circle"
        case .markDiscarded:    return "trash"
        case .recordSubstitute: return "arrow.triangle.swap"
        }
    }

    private func label(_ change: StagedInventoryChange) -> String {
        let n = change.ingredientName.displayNormalized
        switch change.kind {
        case .markAvailable:    return "Mark \(n) as available"
        case .markEmpty:        return "Mark \(n) as empty"
        case .reduceQuantity:   return "Reduce \(n) after use"
        case .addItem:          return "Add \(n) to inventory"
        case .markDiscarded:    return "Mark \(n) as discarded"
        case .recordSubstitute: return "Note: used a swap for \(n)"
        }
    }

    // MARK: Apply

    private func apply() {
        guard let cs = cookSession else { dismiss(); return }
        var appliedIDs: Set<UUID> = []

        for change in changes where enabled.contains(change.id) {
            perform(change)
            appliedIDs.insert(change.id)
        }
        cs.markApplied(ids: appliedIDs)
        HapticManager.light()
        dismiss()
    }

    /// One staged change → the same store mutations the rest of the app uses.
    private func perform(_ change: StagedInventoryChange) {
        func existing() -> LocalInventoryItem? {
            let target = change.ingredientName.lowercased()
            return store.inventoryItems.first {
                let n = $0.name.lowercased()
                return n.contains(target) || target.contains(n)
            }
        }

        switch change.kind {
        case .markAvailable:
            if let item = existing() {
                if item.effectiveLevel <= 0 { store.updateInventoryLevel(id: item.id, level: 1.0) }
                store.confirmInventoryItem(id: item.id)
            } else {
                store.addInventoryItem(LocalInventoryItem(name: change.ingredientName))
            }
        case .addItem:
            if existing() == nil {
                store.addInventoryItem(LocalInventoryItem(name: change.ingredientName))
            } else if let item = existing() {
                store.confirmInventoryItem(id: item.id)
            }
        case .markEmpty, .markDiscarded:
            if let item = existing() { store.updateInventoryLevel(id: item.id, level: 0) }
        case .reduceQuantity:
            if let item = existing() {
                store.updateInventoryLevel(id: item.id, level: max(0, item.level * 0.5))
            }
        case .recordSubstitute:
            break   // informational — no inventory mutation
        }
    }
}
