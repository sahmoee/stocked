// InventoryDetailsSheet.swift
// "View details" on the Inventory Status card now opens this sheet instead of
// firing a drawer quick-action that had no listener on that screen. Shows the
// full stock picture: per-zone breakdown, low items, and expiring items — all
// live from the store.

import SwiftUI

struct InventoryDetailsSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    private var items: [LocalInventoryItem] { session.guestStore.inventoryItems }
    // RL-003 — derived reservations (Total / Reserved / Available per item).
    private var ledger: ReservationLedger { ReservationLedger.shared }

    private func zoneStats(_ zones: [String]) -> (count: Int, pct: Int) {
        let zi = items.filter { zones.contains($0.zone) }
        guard !zi.isEmpty else { return (0, 0) }
        let avg = zi.map(\.effectiveLevel).reduce(0, +) / Double(zi.count)
        return (zi.count, Int((avg * 100).rounded()))
    }

    private var lowItems: [LocalInventoryItem] {
        items.filter { KitchenAvailability.isRunningLow($0) }
             .sorted { $0.effectiveLevel < $1.effectiveLevel }
    }
    private var emptyItems: [LocalInventoryItem] {
        items.filter { $0.effectiveLevel <= 0 }
    }
    private var expiring: [LocalInventoryItem] {
        session.guestStore.expiringSoonItems
    }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Inventory Details")
                                .font(.system(size: 22, weight: .bold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            Text("\(session.guestStore.stockPercent)% stocked across \(items.count) item\(items.count == 1 ? "" : "s")")
                                .font(.system(size: 13))
                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                        }
                        .padding(.top, 18)

                        // ── Zone breakdown ────────────────────────────
                        VStack(spacing: 10) {
                            zoneRow("Fridge",  icon: "refrigerator.fill", tint: Color.stockedGreen, zones: ["Fridge"])
                            zoneRow("Freezer", icon: "snowflake",          tint: Color.stockedInfo,  zones: ["Freezer"])
                            zoneRow("Pantry",  icon: "cabinet.fill",       tint: Color.stockedGoldDark, zones: ["Pantry", "Staples"])
                        }

                        // ── Reserved for planned meals (RL-003) ──────
                        reservationSection

                        // ── Running low ───────────────────────────────
                        detailSection("Running Low", icon: "arrow.down.circle.fill",
                                      tint: Color.stockedGold,
                                      items: lowItems,
                                      emptyText: "Nothing is running low.")

                        // ── Out of stock ──────────────────────────────
                        detailSection("Out of Stock", icon: "xmark.circle.fill",
                                      tint: Color.stockedError,
                                      items: emptyItems,
                                      emptyText: "Nothing is fully out.")

                        // ── Expiring soon ─────────────────────────────
                        detailSection("Expiring Soon", icon: "clock.badge.exclamationmark",
                                      tint: Color.orange,
                                      items: Array(expiring.prefix(10)),
                                      emptyText: "Nothing expiring in the next few days.")

                        Spacer(minLength: 30)
                    }
                    .padding(.horizontal, 22)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                }
            }
        }
        .presentationDetents([.large, .medium])
        // RL-006 — reservations re-derive whenever the plan or inventory moves.
        .task { ledger.refreshIfNeeded(store: session.guestStore) }
        .onChange(of: session.guestStore.inventoryRevision) { _, _ in ledger.refreshIfNeeded(store: session.guestStore) }
        .onChange(of: session.guestStore.planRevision)      { _, _ in ledger.refreshIfNeeded(store: session.guestStore) }
    }

    // MARK: - Reserved for planned meals (RL-003)

    private func claimDayLabel(_ claim: ReservationClaim) -> String {
        if claim.dayIndex == 0 { return "Today" }
        if claim.dayIndex == 1 { return "Tomorrow" }
        let f = DateFormatter(); f.dateFormat = "EEE"
        return f.string(from: claim.date)
    }

    @ViewBuilder
    private var reservationSection: some View {
        let breakdowns = ledger.snapshot.breakdowns
        let conflictCount = ledger.snapshot.conflicts.count
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "calendar.badge.clock").font(.system(size: 13)).foregroundStyle(Color.stockedGold)
                Text("Reserved for Planned Meals")
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                if !breakdowns.isEmpty {
                    Text("\(breakdowns.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.stockedGold)
                }
            }
            if breakdowns.isEmpty {
                Text("Nothing is reserved — every item is fully available.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.45))
            } else {
                if conflictCount > 0 {
                    Text("\(conflictCount) planned meal\(conflictCount == 1 ? " is" : "s are") short — see the planner for fixes.")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(Color.stockedError.opacity(0.85))
                }
                VStack(spacing: 0) {
                    ForEach(Array(breakdowns.prefix(10).enumerated()), id: \.element.id) { idx, b in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 10) {
                                FoodIconView(name: b.itemName, size: 26, emojiSize: 16)
                                Text(b.itemName.displayNormalized)
                                    .font(.system(size: 13.5, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor)
                                    .lineLimit(1)
                                Spacer(minLength: 6)
                                // Total / Reserved / Available in the item's own units;
                                // Available is floored at zero — a deficit shows as a
                                // shortage state, never a misleading negative.
                                if b.quantified {
                                    Text("\(b.totalDisplay) · \(b.reservedDisplay) held · \(b.availableDisplay) free")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                                        .lineLimit(1).fixedSize()
                                } else {
                                    Text("Reserved for \(b.claims.count) meal\(b.claims.count == 1 ? "" : "s")")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(Color.stockedGold)
                                        .lineLimit(1).fixedSize()
                                }
                            }
                            // Every reservation labeled with its meal, day, and amount.
                            ForEach(b.claims.prefix(4)) { claim in
                                HStack(spacing: 6) {
                                    Image(systemName: claim.prepared ? "checkmark.circle" : "calendar")
                                        .font(.system(size: 9.5))
                                        .foregroundStyle(claim.prepared ? Color.stockedGreen : Color.stockedGold.opacity(0.8))
                                    Text("\(claim.mealTitle.displayNormalized) · \(claimDayLabel(claim))")
                                        .font(.system(size: 11))
                                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                                        .lineLimit(1)
                                    Spacer(minLength: 4)
                                    Text(claim.amountDisplay)
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                                        .fixedSize()
                                }
                                .padding(.leading, 36)
                            }
                            if b.claims.count > 4 {
                                Text("+ \(b.claims.count - 4) more")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(session.themeTextColor.opacity(0.35))
                                    .padding(.leading, 36)
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        if idx < min(breakdowns.count, 10) - 1 {
                            Divider().overlay(session.themeTextColor.opacity(0.08)).padding(.leading, 46)
                        }
                    }
                }
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }
        }
    }

    private func zoneRow(_ name: String, icon: String, tint: Color, zones: [String]) -> some View {
        let stats = zoneStats(zones)
        return HStack(spacing: 12) {
            ZStack {
                Circle().fill(tint.opacity(0.14)).frame(width: 38, height: 38)
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                Text("\(stats.count) item\(stats.count == 1 ? "" : "s")")
                    .font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
            Text(stats.count == 0 ? "—" : "\(stats.pct)%")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(session.themeTextColor)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    @ViewBuilder
    private func detailSection(_ title: String, icon: String, tint: Color,
                               items: [LocalInventoryItem], emptyText: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 16, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                if !items.isEmpty {
                    Text("\(items.count)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(tint)
                }
            }
            if items.isEmpty {
                Text(emptyText)
                    .font(.system(size: 12.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.45))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, item in
                        HStack(spacing: 10) {
                            FoodIconView(name: item.name, size: 26, emojiSize: 16)
                            Text(item.name.displayNormalized)
                                .font(.system(size: 13.5))
                                .foregroundStyle(session.themeTextColor)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            if let d = item.daysUntilExpiry, title == "Expiring Soon" {
                                Text(d < 0 ? "Expired" : d == 0 ? "Today" : d == 1 ? "Tomorrow" : "\(d) days")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(d <= 1 ? Color.red.opacity(0.8) : Color.orange)
                                    .lineLimit(1)
                                    .fixedSize()
                            } else {
                                Text("\(Int((item.effectiveLevel * 100).rounded()))%")
                                    .font(.system(size: 11.5, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        if idx < items.count - 1 {
                            Divider().overlay(session.themeTextColor.opacity(0.08)).padding(.leading, 46)
                        }
                    }
                }
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }
        }
    }
}
