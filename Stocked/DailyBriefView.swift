// DailyBriefView.swift — Daily Brief overlay triggered from the Home card (#246).
// Styled to the "Daily Brief (Expanded)" mockup: charcoal sheet, gold "Good Evening,
// Chef" greeting, cream stats card with the kitchen-report link, then At a Glance
// and Household Activity columns.
import SwiftUI

struct DailyBriefOverlay: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedDevice) private var device
    @Binding var isPresented: Bool

    var onScanReceipt:   () -> Void = {}
    var onScanBarcode:   () -> Void = {}
    var onShoppingList:  () -> Void = {}
    var onPreferences:   () -> Void = {}
    var onMealBuilder:   () -> Void = {}
    var onKitchenReport: () -> Void = {}   // #246 — cream card footer

    var store: GuestDataStore { session.guestStore }

    // ── Real household activity ─────────────────────────────────────────
    // When the user is in a household, the feed shows actual synced events from the
    // Worker (who added/removed/checked what, and when) instead of only local
    // inventory guesses. Fetched once per open; falls back to local rows when solo
    // or offline.
    @State private var householdRows: [HouseholdActivity] = []
    @State private var fetchedHousehold = false

    // Perf: the brief's derived lists (stale items, predicted restocks, unexplained
    // waste) each scan the store; computed once when the brief opens instead of on
    // every render of the overlay.
    @State private var briefStale: [LocalInventoryItem] = []
    @State private var briefPredicted: [String] = []
    @State private var briefWaste: ConsumptionRecord? = nil
    @State private var briefLoaded = false

    // Expiring / Low Stock detail presented from the brief itself, so "At a Glance"
    // numbers are tappable. sheet(item:) with an Identifiable payload (never
    // Bool+optional) per the app's sheet pattern.
    private struct BriefDetailSheet: Identifiable {
        let id: String
        let mode: ExpiringItemsView.Mode
    }
    @State private var detailSheet: BriefDetailSheet?

    // "Recommended in 2 Days (Sat, May 24)" — exact mockup string for the cream card.
    private var nextRunValue: String {
        let days = store.groceryRunDays
        guard let date = Calendar.current.date(byAdding: .day, value: days, to: Date()) else { return "Soon" }
        let f = DateFormatter(); f.dateFormat = "E, MMM d"
        switch days {
        case 0:  return "Recommended Today"
        case 1:  return "Recommended Tomorrow (\(f.string(from: date)))"
        default: return "Recommended in \(days) Days (\(f.string(from: date)))"
        }
    }

    private var expiringCount: Int { store.metrics.expiringSoonCount }
    private var lowStockCount: Int { store.metrics.lowStockCount }
    private var toBuyCount:    Int { store.groceryItems.filter { !$0.isChecked }.count }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.4).ignoresSafeArea().onTapGesture { close() }

            mainCard
                .padding(.horizontal, 16)
                .padding(.top, max(StockedScreen.safeTopInset + 24, 78))
        }
        .task {
            if !briefLoaded {
                briefLoaded = true
                briefStale     = store.staleItems(limit: 3)
                briefPredicted = store.predictedRunningLow(limit: 4)
                briefWaste     = store.unexplainedWaste
            }
            await loadHouseholdActivity()
        }
        .sheet(item: $detailSheet) { sheet in
            NavigationStack {
                ExpiringItemsView(mode: sheet.mode).environment(session)
            }
        }
    }

    /// Pull the shared activity feed when in a household. Solo users keep the
    /// local fallback rows; any network failure quietly keeps the fallback too.
    private func loadHouseholdActivity() async {
        guard !fetchedHousehold else { return }
        fetchedHousehold = true
        let sync = HouseholdSync.shared
        guard sync.state == .owner || sync.state == .member else { return }
        let fetched = await sync.fetchActivity(limit: 10)
        if !fetched.isEmpty {
            householdRows = Array(fetched.sorted { $0.date > $1.date }.prefix(4))
        }
    }

    // MARK: - Main card (mockup "Daily Brief (Expanded)")
    @ViewBuilder private var mainCard: some View {
        VStack(alignment: .leading, spacing: 0) {

            // ── Greeting header + close ───────────────────────────────
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    // The Home screen behind this already greets the user, so the brief leads with
                    // its own title instead of repeating "Good Evening, Chef".
                    Text("Today's Brief")
                        .font(.system(size: 23, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedGoldDark)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("Here is where your kitchen stands today.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.stockedWhite.opacity(0.55))
                }
                Spacer(minLength: 8)
                Button { close() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite.opacity(0.6))
                        .frame(width: 28, height: 28)
                        .background(Color.stockedWhite.opacity(0.08))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .a11yButton("Close")
            }
            .padding(.bottom, 16)

            // ── Stats card | At a Glance + Household Activity ─────────
            ScrollView(showsIndicators: false) {
                if device == .tablet {
                    HStack(alignment: .top, spacing: 16) {
                        statsCard.frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 18) {
                            atAGlance
                            pantryCheck
                            runningLow
                            wastePostMortem
                            householdActivity
                            quickActions
                        }
                        .frame(width: 230, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 18) {
                        statsCard
                        atAGlance
                        pantryCheck
                        runningLow
                        wastePostMortem
                        householdActivity
                        quickActions
                    }
                }
            }
            .frame(maxHeight: StockedScreen.height * 0.62)
        }
        .padding(18)
        .background(Color.stockedCharcoal.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
    }

    // ── Cream stats card (mockup left column) ─────────────────────────
    private var statsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Every stat is a working shortcut, not just a readout.
            statRow(icon: "fork.knife", label: "Available Meals",
                    value: "\(store.metrics.mealsReady) makeable meal\(store.metrics.mealsReady == 1 ? "" : "s")") {
                close()
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.cook)
            }
            statRow(icon: "refrigerator", label: "Inventory Status",
                    value: "\(store.metrics.stockPercent)% Stocked") {
                close()
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.inventory)
            }
            statRow(icon: "clock.badge.exclamationmark", label: "Items Expiring Soon",
                    value: "\(store.metrics.expiringSoonCount) item\(store.metrics.expiringSoonCount == 1 ? "" : "s")") {
                detailSheet = BriefDetailSheet(id: "expiring", mode: .expiring)
            }
            statRow(icon: "cart", label: "Next Grocery Run",
                    value: nextRunValue) {
                close()
                onShoppingList()
            }

            Divider().background((session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal).opacity(0.12)).padding(.top, 4)

            Button {
                close()
                onKitchenReport()
            } label: {
                HStack(spacing: 6) {
                    Text("View full kitchen report")
                        .font(.system(size: 13.5, weight: .semibold))
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(session.accentColor)
                .padding(.top, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11yButton("View full kitchen report")
        }
        .padding(16)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg - 4))
    }

    private func statRow(icon: String, label: String, value: String,
                         action: @escaping () -> Void = {}) -> some View {
        // Text/icon sit on the brief card, which is white in light mode and dark in dark mode,
        // so the ink color flips with it to stay legible. Each row is a shortcut to its detail.
        let ink = session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal
        return Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundStyle(ink.opacity(0.6))
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 12))
                        .foregroundStyle(ink.opacity(0.55))
                    Text(value)
                        .font(.system(size: 15.5, weight: .bold))
                        .foregroundStyle(ink)
                        .lineLimit(1).minimumScaleFactor(0.75)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(ink.opacity(0.25))
                    .padding(.top, 8)
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yButton(label, hint: value)
    }

    // ── At a Glance (mockup right column) ─────────────────────────────
    private var atAGlance: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("At a Glance")
                .font(.system(size: 14, weight: .bold, design: .serif))
                .foregroundStyle(Color.stockedGoldDark)
            glanceLine(expiringCount, "expiring", "clock.badge.exclamationmark") {
                detailSheet = BriefDetailSheet(id: "expiring", mode: .expiring)
            }
            glanceLine(lowStockCount, "low stock", "chart.bar") {
                detailSheet = BriefDetailSheet(id: "lowstock", mode: .lowStock)
            }
            glanceLine(toBuyCount, "to buy", "cart") {
                close()
                onShoppingList()
            }
        }
    }

    private func glanceLine(_ value: Int, _ label: String, _ icon: String,
                            action: @escaping () -> Void = {}) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.stockedGold.opacity(0.18)).frame(width: 28, height: 28)
                    Image(systemName: icon).font(.system(size: 12))
                        .foregroundStyle(Color.stockedGoldDark)
                }
                Text("\(value)")
                    .font(.system(size: 16, weight: .heavy, design: .serif))
                    .foregroundStyle(Color.stockedWhite)
                Text(label)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color.stockedWhite.opacity(0.6))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.stockedWhite.opacity(0.25))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yButton("\(value) \(label)")
    }

    // ── Household Activity (mockup) ───────────────────────────────────
    private struct BriefActivityRow: Identifiable {
        let id = UUID(); let text: String; let when: Date
    }
    private var activityRows: [BriefActivityRow] {
        var rows: [BriefActivityRow] = []
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let added = store.inventoryItems.filter { ($0.purchaseDate ?? .distantPast) > cutoff }
        if !added.isEmpty {
            let newest = added.compactMap(\.purchaseDate).max() ?? Date()
            rows.append(BriefActivityRow(
                text: "\(session.userName) added \(added.count) item\(added.count == 1 ? "" : "s")",
                when: newest))
        }
        let recent = Array(store.consumptionLog.suffix(4)).sorted { $0.depletedAt > $1.depletedAt }
        let used = recent.filter { !$0.wasted }
        if used.count > 1, let newest = used.first {
            rows.append(BriefActivityRow(text: "\(used.count) items were used", when: newest.depletedAt))
        } else if let one = used.first {
            rows.append(BriefActivityRow(text: "\(one.itemName.displayNormalized) was used", when: one.depletedAt))
        }
        return Array(rows.sorted { $0.when > $1.when }.prefix(3))
    }
    private func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
    private var householdActivity: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Household Activity")
                .font(.system(size: 14, weight: .bold, design: .serif))
                .foregroundStyle(Color.stockedGoldDark)
            // Real synced events win; local fallback rows cover solo/offline use.
            if !householdRows.isEmpty {
                ForEach(householdRows) { a in
                    HStack(spacing: 10) {
                        Text("\(a.actorName) \(a.kind.verb) \(a.phrase)")
                            .font(.system(size: 13.5))
                            .foregroundStyle(Color.stockedWhite.opacity(0.9))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        Spacer(minLength: 6)
                        Text(relative(a.date))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Color.stockedWhite.opacity(0.45))
                    }
                }
            } else {
                let rows = activityRows
                if rows.isEmpty {
                    Text("No activity yet")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.stockedWhite.opacity(0.5))
                } else {
                    ForEach(rows) { row in
                        HStack(spacing: 10) {
                            Text(row.text)
                                .font(.system(size: 13.5))
                                .foregroundStyle(Color.stockedWhite.opacity(0.9))
                                .lineLimit(1).minimumScaleFactor(0.8)
                            Spacer(minLength: 6)
                            Text(relative(row.when))
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.stockedWhite.opacity(0.45))
                        }
                    }
                }
            }
        }
    }

    // ── Pantry Check (#A2 drift-proofing) ──────────────────────────────
    // Items the app hasn't seen touched in a while get a one-tap "still have this?"
    // ask. Three taps a week keeps the inventory honest without a chore. Answers:
    // Yes (refreshes confirmation) · Used it (level → 0, logs consumption) ·
    // Ran out (level → 0 AND straight onto the grocery list).
    @State private var checkedOff: Set<UUID> = []

    private var pantryCheck: some View {
        let items = briefStale.filter { !checkedOff.contains($0.id) }
        return Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Pantry Check")
                        .font(.system(size: 14, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedGoldDark)
                    Text("Haven't seen these in a while — still have them?")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.stockedWhite.opacity(0.5))
                    ForEach(items) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.name.displayNormalized)
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(Color.stockedWhite.opacity(0.9))
                            HStack(spacing: 8) {
                                checkChip("Yes", "checkmark", Color.stockedGreen) {
                                    store.confirmInventoryItem(id: item.id)
                                    withAnimation { _ = checkedOff.insert(item.id) }
                                }
                                checkChip("Used it", "fork.knife", Color.stockedGold) {
                                    store.updateInventoryLevel(id: item.id, level: 0)
                                    withAnimation { _ = checkedOff.insert(item.id) }
                                }
                                checkChip("Ran out", "cart.badge.plus", Color.stockedWhite.opacity(0.8)) {
                                    store.updateInventoryLevel(id: item.id, level: 0)
                                    store.addGroceryItem(name: item.name)
                                    withAnimation { _ = checkedOff.insert(item.id) }
                                }
                            }
                        }
                        .padding(10)
                        .background(Color.stockedWhite.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    }
                }
            }
        }
    }

    private func checkChip(_ title: String, _ icon: String, _ color: Color,
                           action: @escaping () -> Void) -> some View {
        Button {
            action()
            HapticManager.light()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(color.opacity(0.14))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .a11yButton(title)
    }

    // ── Running Low Soon (#A4 depletion-rate learning, surfaced) ───────
    // predictedRunningLow() learns each item's burn rate from the consumption log
    // and flags staples that are due or overdue for a restock. One tap adds them all.
    @State private var addedRunningLow = false

    private var runningLow: some View {
        let names = briefPredicted
        return Group {
            if !names.isEmpty && !addedRunningLow {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Running Low Soon")
                        .font(.system(size: 14, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedGoldDark)
                    Text("Based on how fast you usually go through them: \(names.map { $0.displayNormalized }.joined(separator: ", "))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Color.stockedWhite.opacity(0.75))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        for n in names { store.addGroceryItem(name: n) }
                        withAnimation { addedRunningLow = true }
                        HapticManager.light()
                    } label: {
                        Label("Add all to grocery list", systemImage: "cart.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.stockedGoldDark)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Color.stockedGold.opacity(0.16))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .a11yButton("Add all running-low items to grocery list")
                }
            }
        }
    }

    // ── Waste post-mortem (#D3) ────────────────────────────────────────
    // One short "what happened?" for the most recent unexplained waste this week.
    // Answers train par levels and sharpen the Stats coaching over time.
    @State private var answeredWasteID: UUID? = nil

    private var wastePostMortem: some View {
        Group {
            if let rec = briefWaste, rec.id != answeredWasteID {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Quick Question")
                        .font(.system(size: 14, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedGoldDark)
                    Text("\(rec.itemName.displayNormalized) went to waste — what happened?")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.stockedWhite.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        checkChip("Bought too much", "cart.fill.badge.plus", Color.stockedGold) {
                            store.setWasteReason(recordID: rec.id, reason: "too much")
                            withAnimation { answeredWasteID = rec.id }
                        }
                        checkChip("Forgot it", "eye.slash", Color.stockedWhite.opacity(0.8)) {
                            store.setWasteReason(recordID: rec.id, reason: "forgot")
                            withAnimation { answeredWasteID = rec.id }
                        }
                        checkChip("Plans changed", "calendar.badge.minus", Color.stockedGreen) {
                            store.setWasteReason(recordID: rec.id, reason: "plans changed")
                            withAnimation { answeredWasteID = rec.id }
                        }
                    }
                }
            }
        }
    }

    // ── Quick actions ──────────────────────────────────────────────────
    // The brief's direct actions, wired to the callbacks MainTabView already passes
    // in (previously they were plumbed but never surfaced, so nothing happened).
    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.system(size: 14, weight: .bold, design: .serif))
                .foregroundStyle(Color.stockedGoldDark)
            HStack(spacing: 8) {
                quickAction("Scan Receipt", "doc.text.viewfinder") { close(); onScanReceipt() }
                quickAction("Scan Barcode", "barcode.viewfinder")  { close(); onScanBarcode() }
            }
            HStack(spacing: 8) {
                quickAction("Shopping List", "cart")               { close(); onShoppingList() }
                quickAction("Settings", "slider.horizontal.3")     { close(); onPreferences() }
            }
        }
    }

    private func quickAction(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon).font(.system(size: 13))
                    .foregroundStyle(Color.stockedGoldDark)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.stockedWhite.opacity(0.9))
                    .lineLimit(1).minimumScaleFactor(0.8)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color.stockedWhite.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yButton(title)
    }

    private func close() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { isPresented = false }
    }
}

#Preview {
    ZStack {
        Color.stockedBg.ignoresSafeArea()
        DailyBriefOverlay(isPresented: .constant(true)).environment(AppSession())
    }
}

// MARK: - Expiring Soon Detail Page
struct ExpiringItemsView: View {
    @Environment(AppSession.self) var session
    enum Mode { case expiring, lowStock }
    let mode: Mode
    var store: GuestDataStore { session.guestStore }

    var items: [LocalInventoryItem] {
        switch mode {
        case .expiring:
            return store.inventoryItems.filter { item in
                guard !store.isSnoozed(item.id) else { return false }   // hide snoozed items
                guard let exp = item.expirationDate else { return false }
                return exp.timeIntervalSinceNow < 86400 * 5
            }.sorted { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }
        case .lowStock:
            return store.inventoryItems.filter { $0.level < 0.2 }
                .sorted { $0.level < $1.level }
        }
    }

    var grouped: [String: [LocalInventoryItem]] {
        Dictionary(grouping: items) { $0.storageCategory.rawValue }
    }

    var title: String { mode == .expiring ? "Expiring Soon" : "Low Stock" }
    var icon:  String { mode == .expiring ? "clock.badge.exclamationmark" : "chart.bar.fill" }
    var tint:  Color  { mode == .expiring ? .orange : Color.stockedGold }

    @State private var addedToList: Set<UUID> = []
    @State private var selectedItem: LocalInventoryItem?
    @State private var selectedRecipe: OnlineRecipe?
    // Closing the loop: recipes that use the expiring items, so they don't go to waste.
    @State private var useUpRecipes: [RecipeDatabaseEntry] = []
    @State private var loadingUseUp = false

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 0) {

                    // Header
                    HStack(spacing: 12) {
                        Image(systemName: icon).font(.system(size: 22)).foregroundStyle(tint)
                        Text(title)
                            .font(.system(size: 26, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Spacer()
                        Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                    .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 6)

                    if mode == .expiring {
                        Text("These items need to be used or added to your shopping list.")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                            .padding(.horizontal, 24).padding(.bottom, 18)

                        // #6 — YOUR saved recipes first: cooking something you've already
                        // saved beats a random online suggestion. NavigationLink works here
                        // because this view lives inside the sheet's NavigationStack.
                        let savedUseUp = session.guestStore.recipesUsingExpiringItems(within: 3, limit: 3)
                        if !savedUseUp.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "book.fill").font(.system(size: 12)).foregroundStyle(Color.stockedGold)
                                Text("From your collection")
                                    .font(.system(size: 12, weight: .bold)).tracking(0.5)
                                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                            }
                            .padding(.horizontal, 24).padding(.bottom, 8)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(savedUseUp) { r in
                                        NavigationLink(destination: UserRecipeDetailView(recipe: r).environment(session)) {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(r.title)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(session.themeTextColor)
                                                    .lineLimit(2).multilineTextAlignment(.leading)
                                                let match = session.guestStore.stockMatch(for: r)
                                                if match.total > 0 {
                                                    Text("\(match.have)/\(match.total) in stock")
                                                        .font(.system(size: 10)).foregroundStyle(Color.stockedGreen)
                                                }
                                            }
                                            .frame(width: 130, alignment: .leading)
                                            .padding(12)
                                            .background(Color.stockedGold.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd).stroke(Color.stockedGold.opacity(0.3), lineWidth: 1))
                                        }
                                        .buttonStyle(.plain)
                                        .a11yButton("Your recipe: \(r.title)", hint: "Uses an item that's expiring soon")
                                    }
                                }
                                .stockedScrollTargetLayout()
                                .padding(.horizontal, 24)
                            }
                            .stockedHorizontalSnap()
                            .padding(.bottom, 14)
                        }

                        // Closing the loop: recipe ideas that use these expiring items.
                        if !useUpRecipes.isEmpty {
                            HStack(spacing: 6) {
                                Image(systemName: "leaf.fill").font(.system(size: 12)).foregroundStyle(Color.stockedGreen)
                                Text("Cook these to use them up")
                                    .font(.system(size: 12, weight: .bold)).tracking(0.5)
                                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                            }
                            .padding(.horizontal, 24).padding(.bottom, 8)
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 12) {
                                    ForEach(useUpRecipes) { r in
                                        Button {
                                            selectedRecipe = OnlineRecipe(
                                                id: r.id.uuidString,
                                                title: r.title,
                                                category: r.category,
                                                area: r.cuisine,
                                                instructions: r.steps.joined(separator: "\n"),
                                                imageURL: r.imageURL,
                                                ingredients: r.ingredients,
                                                measures: Array(repeating: "", count: r.ingredients.count),
                                                source: r.sourceName.isEmpty ? "Stocked." : r.sourceName)
                                        } label: {
                                            VStack(alignment: .leading, spacing: 4) {
                                                Text(r.title)
                                                    .font(.system(size: 13, weight: .semibold))
                                                    .foregroundStyle(session.themeTextColor)
                                                    .lineLimit(2).multilineTextAlignment(.leading)
                                                if !r.totalTime.isEmpty {
                                                    Text(r.totalTime)
                                                        .font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.45))
                                                }
                                            }
                                            .frame(width: 130, alignment: .leading)
                                            .padding(12)
                                            .background(Color.stockedWhite.opacity(0.3))
                                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                        }
                                        .buttonStyle(.plain)
                                        .a11yButton("Recipe: \(r.title)", hint: "Uses an item that's expiring soon")
                                    }
                                }
                                .stockedScrollTargetLayout()
                                .padding(.horizontal, 24)
                            }
                            .stockedHorizontalSnap()
                            .padding(.bottom, 18)
                        }
                    } else {
                        Text("Items below 20% — restock or plan a meal around them.")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                            .padding(.horizontal, 24).padding(.bottom, 18)
                    }

                    if items.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 44)).foregroundStyle(Color.stockedGold)
                            Text(mode == .expiring ? "Nothing expiring soon!" : "All items well stocked!")
                                .font(.system(size: 17, weight: .semibold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 60)
                    } else {
                        // Grouped by storage zone
                        ForEach(grouped.keys.sorted(), id: \.self) { zone in
                            let zoneItems = grouped[zone] ?? []
                            VStack(alignment: .leading, spacing: 0) {
                                Text(zone.uppercased())
                                    .font(.system(size: 10, weight: .bold)).tracking(1.5)
                                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                                    .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)

                                ForEach(zoneItems) { item in
                                    itemRow(item)
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 40)
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadUseUpRecipes() }
        .sheet(item: $selectedItem) { item in
            // Was a dead-end serving picker (the neutralized ServingSizeView with
            // isCookNow: false advanced nowhere). Now: cook around this item —
            // recipes built on the expiring ingredient, using the saved household
            // size as the serving default.
            NavigationStack {
                StarIngredientRecipesView(category: "Expiring Soon",
                                          selection: item.name,
                                          servings: max(1, session.guestStore.cookingProfile.householdSize))
                    .environment(session)
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: $selectedRecipe) { recipe in
            OnlineRecipeDetailView(recipe: recipe).environment(session)
        }
    }

    private func loadUseUpRecipes() async {
        guard mode == .expiring, !items.isEmpty, useUpRecipes.isEmpty, !loadingUseUp else { return }
        loadingUseUp = true
        let snapshot = await RecipeDatabaseManager.shared.loadSnapshot()
        var seen = Set<UUID>()
        var results: [RecipeDatabaseEntry] = []
        for item in items.prefix(5) {
            let matches = RecipeDatabaseManager.shared.suggestions(for: item.name, in: snapshot, limit: 4)
            for m in matches where seen.insert(m.id).inserted {
                results.append(m)
                if results.count >= 8 { break }
            }
            if results.count >= 8 { break }
        }
        useUpRecipes = results
        loadingUseUp = false
    }

    /// Compact action chip used by the Daily Brief item rows. One consistent style for all five
    /// direct actions so the row reads as a tidy cluster rather than a stack of mismatched buttons.
    private func briefAction(_ title: String, _ icon: String, _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
        .a11yButton(title)
    }

    private func itemRow(_ item: LocalInventoryItem) -> some View {
        HStack(spacing: 14) {
            // Level indicator
            ZStack {
                Circle().fill(session.themeTextColor.opacity(0.06)).frame(width: 40, height: 40)
                if mode == .expiring {
                    Text("⏰").font(.system(size: 18))
                } else {
                    VStack(spacing: 2) {
                        Text("\(Int(item.level * 100))%")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(item.level < 0.1 ? .red : tint)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.system(size: 15, weight: .semibold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                if mode == .expiring, let exp = item.expirationDate {
                    let days = Int(exp.timeIntervalSinceNow / 86400)
                    Text(days <= 0 ? "Expired" : "Expires in \(days) day\(days == 1 ? "" : "s")")
                        .font(.system(size: 11)).foregroundStyle(days <= 0 ? .red : tint)
                } else {
                    Text(item.displayText).font(.system(size: 11))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                }
            }

            Spacer()

            // Action buttons — the five Daily Brief direct actions. Cook this / Add to grocery
            // are always available; Mark used / Freeze / Snooze apply to expiring items with stock.
            VStack(alignment: .trailing, spacing: 6) {
                HStack(spacing: 6) {
                    briefAction("Cook this", "fork.knife", Color.stockedGold) {
                        selectedItem = item
                    }
                    briefAction(addedToList.contains(item.id) ? "Added ✓" : "Add to grocery",
                                addedToList.contains(item.id) ? "checkmark" : "cart.badge.plus",
                                addedToList.contains(item.id) ? Color.stockedGold : session.themeTextColor) {
                        store.addGroceryItem(name: item.name)
                        withAnimation { _ = addedToList.insert(item.id) }
                    }
                }
                if mode == .expiring {
                    HStack(spacing: 6) {
                        if item.level > 0 {
                            // Mark used: logs consumption, zeroes the item, and (with auto-add on)
                            // restocks the grocery list via the store's depletion handling.
                            briefAction("Mark used", "checkmark.circle", Color.stockedGreen) {
                                store.updateInventoryLevel(id: item.id, level: 0)
                                HapticManager.light()
                            }
                        }
                        // Freeze: moves it to the freezer and extends the date so it stops nagging.
                        briefAction("Freeze", "snowflake", Color(red: 0.30, green: 0.55, blue: 0.80)) {
                            store.freezeItem(id: item.id)
                            HapticManager.light()
                        }
                        // Snooze: quiets this item in the brief for a few days.
                        briefAction("Snooze", "moon.zzz", session.themeTextColor.opacity(0.6)) {
                            withAnimation { store.snoozeExpiring(id: item.id) }
                            HapticManager.light()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .background(Color.stockedWhite.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .padding(.horizontal, 16).padding(.bottom, 6)
    }
}
