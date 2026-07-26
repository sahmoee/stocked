// RefreshKitchenView.swift
// ─────────────────────────────────────────────────────────────────
// Cook Now's focused inventory-refresh: confirm a handful of high-impact items
// instead of auditing the whole kitchen. Sister to PantryAuditView (the full
// sweep) — same trusted verbs and store APIs, different selection logic:
//
// Priority order (highest first):
//   1. Pivot items — in-stock items whose absence would change a Ready Now
//      recipe's classification, or missing items that gate an Almost Ready
//      recipe (confirming these moves tonight's numbers the most).
//   2. Stale items — not confirmed/touched in a while (GuestDataStore.isStale).
//   3. Expiring-soon items.
//
// Actions write through the SAME store mutations PantryAuditView uses
// (confirmInventoryItem / updateInventoryLevel / addGroceryItem), so household
// sync, revision bumps, and consumption logging behave identically. The
// dashboard recomputes automatically off the revision change.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

struct RefreshKitchenView: View {
    @Environment(AppSession.self) var session
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var queue: [LocalInventoryItem] = []
    @State private var handled: Set<UUID> = []
    @State private var built = false

    private var remaining: [LocalInventoryItem] { queue.filter { !handled.contains($0.id) } }

    var body: some View {
        StockedShell(showBack: true, titleText: "Refresh Kitchen") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Confirm a few high-impact items to improve tonight's matches.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)
                    .fixedSize(horizontal: false, vertical: true)

                if remaining.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 44)).foregroundStyle(Color.stockedGreen)
                        Text(handled.isEmpty ? "Everything checks out!" : "All caught up!")
                            .font(.system(size: 17, weight: .semibold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text("Tonight's matches are as accurate as your kitchen can make them.")
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 50)
                } else {
                    VStack(spacing: 10) {
                        ForEach(remaining) { item in
                            row(item)
                        }
                    }
                    .padding(.horizontal, CookStyle.screenHPad)
                }

                Spacer(minLength: 20)
            }
        }
        .task { buildQueueIfNeeded() }
    }

    // MARK: Queue construction

    private func buildQueueIfNeeded() {
        guard !built else { return }
        built = true

        // Classify once to find pivot ingredients.
        let snapshot = CookNowCompute.run(store: store, session: nil)

        // Names that gate Almost Ready recipes (their missing items) — items
        // matching these unlock meals when confirmed present.
        var gateNames: Set<String> = []
        for c in snapshot.almostReady {
            for n in c.missingNames { gateNames.insert(n.lowercased()) }
        }
        // Names Ready Now recipes DEPEND on — confirming these protects tonight.
        var dependNames: Set<String> = []
        for c in snapshot.readyNow {
            for r in c.resolutions {
                if case .inStock = r.status { dependNames.insert(r.name.lowercased()) }
            }
        }

        func isPivot(_ item: LocalInventoryItem) -> Bool {
            // Shared matcher — was another inline substring pair.
            if KitchenAvailability.isPresent(item.name, inNames: dependNames) { return true }
            if KitchenAvailability.isPresent(item.name, inNames: gateNames) { return true }
            return false
        }

        let inStock = store.inventoryItems.filter { $0.effectiveLevel > 0 }
        let pivots  = inStock.filter { isPivot($0) && GuestDataStore.isStale($0) }
        let stale   = inStock.filter { GuestDataStore.isStale($0) && !isPivot($0) }
            .sorted { (GuestDataStore.staleness(of: $0) ?? 0) > (GuestDataStore.staleness(of: $1) ?? 0) }
        let expiring = inStock.filter { $0.isExpiringSoon && !GuestDataStore.isStale($0) }

        var seen = Set<UUID>()
        var out: [LocalInventoryItem] = []
        for item in pivots + stale + expiring where seen.insert(item.id).inserted {
            out.append(item)
        }
        queue = Array(out.prefix(8))   // focused, never a full audit
    }

    // MARK: Row (same verbs and store calls as PantryAuditView)

    private func row(_ item: LocalInventoryItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(ImageFallbackService.emoji(for: item.name))
                    .font(.system(size: 20)).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name.displayNormalized)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    if let days = GuestDataStore.staleness(of: item) {
                        Text("Last seen \(days) day\(days == 1 ? "" : "s") ago · \(item.zone)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                    } else if item.isExpiringSoon {
                        Text("Expiring soon · \(item.zone)")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.stockedGold)
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                chip("Still have it", "checkmark", Color.stockedGreen) {
                    store.confirmInventoryItem(id: item.id)
                    withAnimation { _ = handled.insert(item.id) }
                }
                chip("Used it", "fork.knife", Color.stockedGold) {
                    store.updateInventoryLevel(id: item.id, level: 0)
                    withAnimation { _ = handled.insert(item.id) }
                }
                chip("Out", "cart.badge.plus", session.themeTextColor.opacity(0.7)) {
                    store.updateInventoryLevel(id: item.id, level: 0)
                    store.addGroceryItem(name: item.name)
                    withAnimation { _ = handled.insert(item.id) }
                }
            }
        }
        .padding(14)
        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    private func chip(_ title: String, _ icon: String, _ color: Color,
                      action: @escaping () -> Void) -> some View {
        Button {
            action()
            HapticManager.light()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(color)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(color.opacity(0.12))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .a11yButton(title)
    }
}
