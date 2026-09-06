// Live inventory health. The sheet shares the Inventory editorial canvas and data owners.
import SwiftUI

struct InventoryDetailsSheet: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: LocalInventoryItem?
    @State private var expandedSections: Set<String> = []
    private var ledger: ReservationLedger { .shared }
    private var items: [LocalInventoryItem] { session.guestStore.inventoryItems }
    private var lowItems: [LocalInventoryItem] {
        items.filter { KitchenAvailability.isRunningLow($0) }
            .sorted { $0.effectiveLevel < $1.effectiveLevel }
    }
    private var emptyItems: [LocalInventoryItem] { items.filter { $0.effectiveLevel <= 0 } }
    private var refreshID: String { "\(session.guestStore.inventoryRevision)-\(session.guestStore.planRevision)" }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    InventoryEditorialHeading(title: "Inventory details",
                        subtitle: "\(session.guestStore.stockPercent)% stocked across \(items.count) item\(items.count == 1 ? "" : "s").",
                        artwork: 1)
                    VStack(spacing: 10) {
                        zoneRow("Fridge", icon: "refrigerator", zones: ["Fridge"])
                        zoneRow("Freezer", icon: "snowflake", zones: ["Freezer"])
                        zoneRow("Pantry & Staples", icon: "cabinet", zones: ["Pantry", "Staples"])
                    }
                    reservationSection
                    detailSection("Running Low", icon: "arrow.down.circle", items: lowItems,
                                  emptyText: "Nothing is running low.")
                    detailSection("Out of Stock", icon: "xmark.circle", items: emptyItems,
                                  emptyText: "Nothing is fully out.")
                    detailSection("Expiring Soon", icon: "clock.badge.exclamationmark",
                                  items: session.guestStore.expiringSoonItems,
                                  emptyText: "Nothing expiring in the next few days.", expiry: true)
                }
                .padding(.horizontal, 20).padding(.bottom, 28)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .background(session.inventoryCanvas.ignoresSafeArea())
        }
        .stockedPresentationSurface(width: .form, canvasColor: session.inventoryCanvas)
        .presentationDetents([.medium, .large])
        .task(id: refreshID) { await ledger.refreshForPresentation(store: session.guestStore) }
        .sheet(item: $selectedItem) { item in
            NavigationStack { EditItemSheet(item: item).environment(session) }
        }
    }

    private func zoneRow(_ name: String, icon: String, zones: [String]) -> some View {
        let zoneItems = items.filter { zones.contains($0.zone) }
        let average = zoneItems.isEmpty ? 0 : zoneItems.reduce(0.0) { $0 + $1.effectiveLevel } / Double(zoneItems.count)
        return HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.stocked(.title2)).foregroundStyle(session.inventoryGold)
                .frame(width: 38).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.stockedSerif(18, weight: .semibold, relativeTo: .headline))
                Text("\(zoneItems.count) item\(zoneItems.count == 1 ? "" : "s")")
                    .font(.stocked(.caption)).foregroundStyle(session.themeSecondaryText)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(zoneItems.isEmpty ? "—" : "\(Int((average * 100).rounded()))%")
                .font(.stockedSerif(20, weight: .bold, relativeTo: .title3))
                .monospacedDigit().foregroundStyle(session.inventoryGold)
        }
        .modifier(InventoryEditorialCard())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(zoneItems.count) items")
        .accessibilityValue(zoneItems.isEmpty ? "No stock recorded" : "Average fill \(Int((average * 100).rounded())) percent")
    }

    private func sectionHeading(_ title: String, icon: String, count: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(session.inventoryGold).accessibilityHidden(true)
            Text(title).font(.stockedSerif(19, weight: .semibold, relativeTo: .headline))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Text(count.formatted()).font(.stocked(.subheadline).bold())
                .monospacedDigit().foregroundStyle(session.inventoryGold)
        }
        .accessibilityAddTraits(.isHeader)
    }

    private var reservationSection: some View {
        let breakdowns = ledger.snapshot.breakdowns
        let showAll = expandedSections.contains("reservations")
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeading("Reserved for planned meals", icon: "calendar.badge.clock", count: breakdowns.count)
            if breakdowns.isEmpty {
                Text("Nothing is reserved — every item is fully available.")
                    .font(.stocked(.subheadline)).foregroundStyle(session.themeSecondaryText)
            } else {
                if !ledger.snapshot.conflicts.isEmpty {
                    Label("\(ledger.snapshot.conflicts.count) planned meals have a shortage. Review them in the planner.",
                          systemImage: "exclamationmark.triangle")
                        .font(.stocked(.subheadline)).foregroundStyle(session.inventoryGold)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(breakdowns.prefix(showAll ? breakdowns.count : 10)) { breakdown in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(breakdown.itemName.displayNormalized)
                            .font(.stockedSerif(17, weight: .semibold, relativeTo: .headline))
                        Text(breakdown.quantified
                            ? "\(breakdown.totalDisplay) total · \(breakdown.reservedDisplay) held · \(breakdown.availableDisplay) available"
                            : "Reserved for \(breakdown.claims.count) meals")
                            .font(.stocked(.caption)).foregroundStyle(session.themeSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        // No hidden four-claim cap or non-actionable '+ more' label.
                        ForEach(breakdown.claims) { claim in
                            VStack(alignment: .leading, spacing: 3) {
                                Label(claim.mealTitle.displayNormalized, systemImage: claim.prepared ? "checkmark.circle" : "calendar")
                                Text("\(claim.date.formatted(date: .abbreviated, time: .omitted)) · \(claim.amountDisplay)")
                                    .foregroundStyle(session.themeSecondaryText)
                            }
                            .font(.stocked(.caption)).fixedSize(horizontal: false, vertical: true)
                        }
                    }.modifier(InventoryEditorialCard())
                }
                expandButton(key: "reservations", count: breakdowns.count)
            }
        }
    }

    private func detailSection(_ title: String, icon: String, items: [LocalInventoryItem],
                               emptyText: String, expiry: Bool = false) -> some View {
        let showAll = expandedSections.contains(title)
        return VStack(alignment: .leading, spacing: 12) {
            sectionHeading(title, icon: icon, count: items.count)
            if items.isEmpty {
                Text(emptyText).font(.stocked(.subheadline)).foregroundStyle(session.themeSecondaryText)
            } else {
                ForEach(items.prefix(showAll ? items.count : 10)) { item in
                    Button { selectedItem = item } label: {
                        HStack(spacing: 12) {
                            FoodIconView(name: item.name, size: 34, emojiSize: 22).accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(item.name.displayNormalized)
                                    .font(.stockedSerif(17, weight: .semibold, relativeTo: .headline))
                                Text(item.zone + " · " + status(item, expiry: expiry))
                                    .font(.stocked(.caption)).foregroundStyle(session.themeSecondaryText)
                            }.fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right").foregroundStyle(session.inventoryGold)
                                .accessibilityHidden(true)
                        }.modifier(InventoryEditorialCard())
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Review and update this inventory item")
                }
                expandButton(key: title, count: items.count)
            }
        }
    }

    @ViewBuilder private func expandButton(key: String, count: Int) -> some View {
        if count > 10 {
            Button(expandedSections.contains(key) ? "Show fewer" : "Show all \(count)") {
                if !expandedSections.insert(key).inserted { expandedSections.remove(key) }
            }
            .font(.stockedSerif(15, weight: .semibold, relativeTo: .body))
            .foregroundStyle(session.inventoryGold).frame(minHeight: 44)
        }
    }

    private func status(_ item: LocalInventoryItem, expiry: Bool) -> String {
        if expiry, let days = item.daysUntilExpiry {
            return days < 0 ? "Past date" : days == 0 ? "Due today" : days == 1 ? "Due tomorrow" : "\(days) days left"
        }
        return "\(Int((item.effectiveLevel * 100).rounded()))% remaining"
    }
}
