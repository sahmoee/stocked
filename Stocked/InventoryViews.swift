// InventoryViews.swift — Inventory sub-components: item card, stash, receipt review, undo toast.
// InventoryView and AddItemView are declared in InventoryView.swift — NOT here.
// Color.theme.* removed — all tokens use DesignTokens.swift definitions.
import SwiftUI

// MARK: - Live Inventory Zone View
// Reads from GuestDataStore and displays items for a given zone.
struct LiveInventoryZoneView: View {
    @Environment(AppSession.self) var session
    let zoneName: String

    var items: [LocalInventoryItem] {
        session.guestStore.inventoryItems.filter { $0.zone == zoneName }
    }

    var body: some View {
        VStack(spacing: 12) {
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "tray")
                        .scaledFont(36)
                        .foregroundStyle(session.themeTextColor.opacity(0.2))
                    Text("No items in \(zoneName)")
                        .font(.stockedSans(14))
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                    Text("Tap \"+ Manual\" below to get started")
                        .font(.stockedSans(12))
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                ForEach(items) { item in
                    LiveInventoryItemCard(item: item)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
    }
}

// MARK: - Live Inventory Item Card
struct LiveInventoryItemCard: View {
    @Environment(AppSession.self) var session
    let item: LocalInventoryItem
    @State private var dragLevel: Double? = nil   // #20 — live level while dragging the bar

    private var displayLevel: Double { dragLevel ?? item.level }

    private static let runOutFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEE"; return f
    }()

    var batteryColor: Color {
        displayLevel < 0.25 ? .red : (displayLevel < 0.5 ? Color.stockedGold : Color.stockedGreen)
    }

    var levelLabel: String {
        if displayLevel >= 0.66 { return "Full" }
        if displayLevel >= 0.33 { return "Half" }
        return "Low"
    }

    var body: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.stockedSans(15, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                    if item.hasStash {
                        Text("✦")
                            .scaledFont(13)
                            .foregroundStyle(Color.stockedGold)
                    }
                }
                // Structured quantity display: "2 cases (24 cans each)"
                if item.quantity > 1 || !item.containerType.isEmpty {
                    Text(item.displayText)
                        .font(.stockedSans(12))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }
                Text(levelLabel)
                    .font(.stockedSans(12))
                    .foregroundStyle(batteryColor)
                // #4 — learned run-out prediction, shown only when it's near enough to act on
                if item.level > 0, let runOut = session.guestStore.predictedRunOut(for: item),
                   runOut.timeIntervalSinceNow < 86_400 * 6 {
                    Text(runOut < Date() ? "Likely out" : "Runs out ~\(Self.runOutFormatter.string(from: runOut))")
                        .font(.stockedSans(11))
                        .foregroundStyle(runOut.timeIntervalSinceNow < 86_400 * 2 ? .red : session.themeTextColor.opacity(0.45))
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                // #20 — drag the bar to set the level directly; no editor round-trip.
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.stockedCharcoal.opacity(0.12))
                        .frame(width: 80, height: 10)
                    Capsule()
                        .fill(batteryColor)
                        .frame(width: max(0, 80 * displayLevel), height: 10)
                }
                .frame(width: 80, height: 24)         // taller hit area for the finger
                .contentShape(Rectangle())
                // Tap anywhere on the bar to jump the level to that point (#1), in
                // addition to dragging. SpatialTapGesture gives us the tap x.
                .gesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            let frac = min(1, max(0, value.location.x / 80))
                            let snapped = StockedVelocitySnapPolicy().magneticValue(
                                frac,
                                increment: 0.05,
                                bounds: 0...1
                            )
                            session.guestStore.updateInventoryLevel(id: item.id, level: snapped)
                            HapticManager.light()
                        }
                )
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            // Bar is a fixed 80pt wide, so position → level is just x/80.
                            dragLevel = min(1, max(0, value.location.x / 80))
                        }
                        .onEnded { _ in
                            if let final = dragLevel {
                                let snapped = StockedVelocitySnapPolicy().magneticValue(
                                    final,
                                    increment: 0.05,
                                    bounds: 0...1
                                )
                                session.guestStore.updateInventoryLevel(id: item.id, level: snapped)
                                HapticManager.light()
                            }
                            dragLevel = nil
                        }
                )
                Text("\(Int(displayLevel * 100))%")
                    .font(.stockedSans(11))
                    .foregroundStyle(batteryColor)
            }
        }
        .padding(16)
        .background(Color.stockedWhite.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: StockedRadius.md))
        .contextMenu {
            Button {
                session.guestStore.updateInventoryLevel(id: item.id, level: min(1.0, item.level + 0.25))
            } label: {
                Label("Restock (+25%)", systemImage: "arrow.up.circle")
            }
            Button {
                session.guestStore.updateInventoryLevel(id: item.id, level: max(0, item.level - 0.25))
            } label: {
                Label("Use Some (-25%)", systemImage: "minus.circle")
            }
            Divider()
            Button(role: .destructive) {
                session.guestStore.removeInventoryItem(id: item.id)
            } label: {
                Label("Remove Item", systemImage: "trash")
            }
        }
    }
}

// MARK: - Receipt Review View
struct ReceiptReviewView: View {
    @Environment(AppSession.self) var session
    struct LineItem: Identifiable {
        let id         = UUID()
        let raw:       String
        var resolved:  String?
        var isConfirmed: Bool
    }

    @State private var items: [LineItem] = [
        LineItem(raw: "CHKN BRST 2LB", resolved: "Chicken Breast", isConfirmed: true),
        LineItem(raw: "2% MLK GAL",   resolved: "2% Milk Gallon",  isConfirmed: true),
        LineItem(raw: "SPNCH 9OZ",    resolved: "Spinach 9oz",     isConfirmed: true),
        LineItem(raw: "XTRVGN OIL",   resolved: nil,               isConfirmed: false),
        LineItem(raw: "PSTA ROTN",    resolved: nil,               isConfirmed: false),
    ]

    var confirmed:  [LineItem] { items.filter {  $0.isConfirmed } }
    var unresolved: [LineItem] { items.filter { !$0.isConfirmed } }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Receipt Review")
                        .font(.stockedSerif(26, weight: .bold))
                        .foregroundStyle(session.themeTextColor)
                        .padding(.top, 28)
                        .padding(.horizontal, 24)

                    receiptSectionHeader("Confirmed (\(confirmed.count))", color: session.themeTextColor.opacity(0.5))
                    ForEach(confirmed)  { item in ReceiptRow(item: item, isConfirmed: true)  }

                    if !unresolved.isEmpty {
                        receiptSectionHeader("Needs Review (\(unresolved.count))", color: session.themeTextColor.opacity(0.5))
                        ForEach(unresolved) { item in ReceiptRow(item: item, isConfirmed: false) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 30)
            }
        }
    }
}

private func receiptSectionHeader(_ text: String, color: Color) -> some View {
    Text(text)
        .font(.stockedSans(13, weight: .bold))
        .foregroundStyle(color)
        .padding(.horizontal, 24)
}

struct ReceiptRow: View {
    @Environment(AppSession.self) var session
    let item:        ReceiptReviewView.LineItem
    let isConfirmed: Bool

    var body: some View {
        HStack {
            Image(systemName: isConfirmed ? "checkmark.circle.fill" : "questionmark.circle.fill")
                .foregroundStyle(isConfirmed ? Color.stockedGreen : Color.stockedGold)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.resolved ?? item.raw)
                    .font(.stockedSans(15, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                if !isConfirmed {
                    Text("Raw: \(item.raw)")
                        .font(.stockedSans(12))
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                }
            }
            Spacer()
            if !isConfirmed {
                Image(systemName: "pencil").foregroundStyle(Color.stockedGold)
            }
        }
        .padding(14)
        .background(Color.stockedWhite.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: StockedRadius.md))
        .padding(.horizontal, 4)
    }
}

// MARK: - Stash View
struct StashView: View {
    @Environment(AppSession.self) var session

    struct StashItem: Identifiable {
        let id = UUID()
        let name: String
    }

    let stashItems = [
        StashItem(name: "Backup Chicken"),
        StashItem(name: "Extra Pasta"),
        StashItem(name: "Frozen Peas (x2)"),
        StashItem(name: "Reserve Olive Oil"),
    ]

    @State private var moveModal: StashItem?
    let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack {
                Text("The Stash ✦")
                    .font(.stockedSerif(26, weight: .bold))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.top, 28)
                Text("Your surplus inventory")
                    .font(.stockedSans(14, weight: .light))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))

                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(stashItems) { item in
                        Button { moveModal = item } label: {
                            VStack(spacing: 8) {
                                Text("✦")
                                    .scaledFont(22)
                                    .foregroundStyle(Color.stockedGold)
                                Text(item.name)
                                    .font(.stockedSans(14, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor)
                                    .multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(18)
                            .background(Color.stockedWhite.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: StockedRadius.lg))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                Spacer()
            }

            if let item = moveModal {
                Color.black.opacity(0.4)
                    .ignoresSafeArea()
                    .onTapGesture { moveModal = nil }

                VStack(spacing: 20) {
                    Text("Move to Active?")
                        .font(.stockedSerif(22, weight: .bold))
                        .foregroundStyle(session.themeTextColor)
                    Text(item.name)
                        .font(.stockedSans(15))
                        .foregroundStyle(session.themeTextColor.opacity(0.7))
                    HStack(spacing: 16) {
                        Button { moveModal = nil } label: {
                            Text("Not Now")
                                .font(.stockedSans(15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundStyle(session.themeTextColor)
                                .background(Color.stockedWhite.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: StockedRadius.md))
                        }
                        Button { moveModal = nil } label: {
                            Text("Move It")
                                .font(.stockedSans(15, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundStyle(Color.stockedWhite)
                                .background(Color.stockedCharcoal)
                                .clipShape(RoundedRectangle(cornerRadius: StockedRadius.md))
                        }
                    }
                }
                .padding(24)
                .background(session.themeBgColor)
                .clipShape(RoundedRectangle(cornerRadius: StockedRadius.xl))
                .padding(.horizontal, 28)
            }
        }
    }
}

// MARK: - Undo Toast
