// PantryAuditView.swift — bulk pantry accuracy sweep (#A2/#A3 power version).
//
// The Daily Brief's Pantry Check asks about three stale items at a time; this is
// the sit-down version: every item the app is no longer sure about, in one list,
// with the same three answers per row — Yes (confirm) · Used it (deplete + log) ·
// Ran out (deplete + add to grocery). Ten minutes here resets the whole kitchen
// to truth, which is what keeps every recipe match and grocery suggestion honest.
import SwiftUI

struct PantryAuditView: View {
    @Environment(AppSession.self) private var session

    private var store: GuestDataStore { session.guestStore }

    @State private var handled: Set<UUID> = []

    /// Every stale item, most-overdue first (not capped like the brief's three).
    private var auditItems: [LocalInventoryItem] {
        store.inventoryItems
            .filter { GuestDataStore.isStale($0) && !handled.contains($0.id) }
            .sorted { (GuestDataStore.staleness(of: $0) ?? 0) > (GuestDataStore.staleness(of: $1) ?? 0) }
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if auditItems.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 44)).foregroundStyle(Color.stockedGreen)
                            Text(handled.isEmpty ? "Everything's confirmed!" : "All caught up!")
                                .font(.system(size: 17, weight: .semibold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            Text("Your inventory matches your real kitchen. Recipe matches and grocery suggestions are as accurate as they can be.")
                                .font(.system(size: 13))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 30)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        Text("Stocked hasn't seen these touched in a while. One tap each keeps your kitchen honest.")
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 6)

                        ForEach(auditItems) { item in
                            auditRow(item)
                        }
                        Color.clear.frame(height: 40)
                    }
                }
            }
        }
        .navigationTitle("Pantry Audit")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func auditRow(_ item: LocalInventoryItem) -> some View {
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
                    }
                }
                Spacer()
            }
            HStack(spacing: 8) {
                auditChip("Still have it", "checkmark", Color.stockedGreen) {
                    store.confirmInventoryItem(id: item.id)
                    withAnimation { _ = handled.insert(item.id) }
                }
                auditChip("Used it", "fork.knife", Color.stockedGold) {
                    store.updateInventoryLevel(id: item.id, level: 0)
                    withAnimation { _ = handled.insert(item.id) }
                }
                auditChip("Ran out", "cart.badge.plus", session.themeTextColor.opacity(0.7)) {
                    store.updateInventoryLevel(id: item.id, level: 0)
                    store.addGroceryItem(name: item.name)
                    withAnimation { _ = handled.insert(item.id) }
                }
            }
        }
        .padding(14)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .padding(.horizontal, 20)
    }

    private func auditChip(_ title: String, _ icon: String, _ color: Color,
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
