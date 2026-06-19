// InventoryView.swift — Database-powered add, expiration, full-cell tappable rows
import SwiftUI
import Combine
import PhotosUI
import os

// iPad split-view (master list | detail editor) size presets. Replaces the draggable
// divider: the user picks how the space is divided from a small set of named options.
// listWidth is the master (list) pane width in points; the editor fills the rest.
enum SplitPreset: String, CaseIterable {
    case narrowList   // small list, large editor
    case even         // balanced
    case wideList     // large list, small editor

    var listWidth: CGFloat {
        switch self {
        case .narrowList: return 360
        case .even:       return 540
        case .wideList:   return 680
        }
    }
    var label: String {
        switch self {
        case .narrowList: return "List ⅓"
        case .even:       return "Even"
        case .wideList:   return "List ⅔"
        }
    }

    private static let key = "inventorySplitPreset"
    static func load() -> SplitPreset {
        SplitPreset(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .wideList
    }
    func save() { UserDefaults.standard.set(rawValue, forKey: SplitPreset.key) }
}

// One enum drives a SINGLE .sheet(item:) — stacking multiple .sheet(isPresented:)
// modifiers on one view is unreliable in SwiftUI (only one fires), which is why the
// Add Item button and drag-to-plan sheet were dead.
enum InventorySheet: Identifiable {
    case add
    case barcode
    case receipt
    case mealPlanner(itemName: String, dayIndex: Int)
    var id: Int {
        switch self {
        case .add: return 0; case .barcode: return 1
        case .receipt: return 2; case .mealPlanner: return 3
        }
    }
}

struct InventoryView: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedDevice) private var device
    @State private var selectedZone   = "Fridge"
    @State private var expandedSubs:   Set<String> = []
    @State private var preEditExpanded: Set<String> = []   // restore on exiting edit mode
    @State private var buildToast: String? = nil           // drag-to-build confirmation
    @State private var detailItemID: UUID? = nil           // iPad master-detail selection
    // #17 — item opened from an expiry-reminder deep link (works on iPhone + iPad).
    @State private var deepLinkItem: LocalInventoryItem? = nil
    // Split-view master (list) width is chosen from presets, not dragged.
    @State private var splitPreset: SplitPreset = SplitPreset.load()
    private var splitListWidth: CGFloat { splitPreset.listWidth }
    @State private var activeSheet:    InventorySheet? = nil
    @State private var editMode       = false
    @State private var selectedIDs:    Set<UUID> = []
    @State private var showZonePicker  = false
    @State private var showSearchField = false   // #245 — header magnifier toggles the field
    @State private var showSortDialog  = false   // #245 — header funnel
    @State private var showAllRows     = false   // #245 — "View All <zone> Items" footer
    let zones = ["All","Fridge","Freezer","Pantry","Staples"]

    // #235 mockup — per-zone chip icon.
    private func zoneIcon(_ zone: String) -> String {
        switch zone {
        case "All":     return "square.grid.2x2"
        case "Fridge":  return "refrigerator"
        case "Pantry":  return "cabinet"
        case "Freezer": return "snowflake"
        case "Staples": return "star"
        default:        return "archivebox"
        }
    }

    var items: [LocalInventoryItem] {
        let all = session.guestStore.inventoryItems
        var filtered = selectedZone == "All" ? all : all.filter { $0.zone == selectedZone }
        // #16/#9 — accent- and case-insensitive search across name + brand + category.
        let q = invSearch.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            filtered = filtered.filter {
                $0.name.searchMatches(q)
                || ($0.brand?.searchMatches(q) ?? false)
                || ($0.customCategory?.searchMatches(q) ?? false)
            }
        }
        // #5/#6 — sort by the chosen mode (default = use-first / soonest expiry).
        switch invSort {
        case .useFirst:  return filtered.sorted { ($0.daysUntilExpiry ?? 999) < ($1.daysUntilExpiry ?? 999) }
        case .name:      return filtered.sorted { $0.name.lowercased() < $1.name.lowercased() }
        case .quantity:  return filtered.sorted { $0.quantity > $1.quantity }
        case .lowFirst:  return filtered.sorted { $0.effectiveLevel < $1.effectiveLevel }
        case .recent:    return filtered.sorted { ($0.purchaseDate ?? .distantPast) > ($1.purchaseDate ?? .distantPast) }
        }
    }

    enum InvSort: String, CaseIterable {
        case useFirst = "Use first"
        case name     = "Name"
        case quantity = "Quantity"
        case lowFirst = "Low first"
        case recent   = "Recent"
    }
    @State private var invSort: InvSort = .useFirst   // #5
    @State private var invSearch: String = ""          // #16
    var startWithSearch: Bool = false                  // #246 — hub magnifier opens list with search live
    @State private var inventoryShareCSV: String? = nil // #20 share payload

    // iPad orientation — master-detail split is only used in landscape, where there's
    // room for two panes. Portrait keeps the single full-width list (taps open the sheet).
    // iPad orientation — kept in state and updated on rotation so the view re-renders
    // immediately (a plain computed read isn't observed by SwiftUI, so rotation didn't
    // apply until you navigated away and back).
    @State private var isLandscape: Bool = StockedScreen.isLandscape
    private var splitActive: Bool { device == .tablet && isLandscape }
    // Shalise's feedback: in landscape, start full-screen (list only) and only switch to a
    // split view once an item is actually selected. So the detail pane is gated on a selection.
    private var showDetailPane: Bool { splitActive && detailItemID != nil }

    private func refreshOrientation() {
        let landscape = StockedScreen.isLandscape
        if landscape != isLandscape {
            withAnimation(.easeInOut(duration: 0.25)) { isLandscape = landscape }
        }
    }

    var body: some View {
        StockedShell(showBack: true, scrollDisabled: true,
                     trailingIcon: "magnifyingglass", trailingLabel: "Search",
                     onTrailing: { withAnimation(.easeInOut(duration: 0.2)) { showSearchField.toggle() } },
                     trailingIcon2: "line.3.horizontal.decrease", trailingLabel2: "Sort",
                     onTrailing2: { showSortDialog = true }) {
            HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {

                // ── Combined expiry + drag-to-plan strip ─────────────
                WeeklyPlanStrip(
                    onDrop: { itemName, dayIndex in
                        addToBuildingMeal(itemName: itemName, dayIndex: dayIndex)
                    },
                    onTap: { dayIndex in
                        activeSheet = .mealPlanner(itemName: "", dayIndex: dayIndex)
                    }
                )
                .padding(.horizontal, 20).padding(.bottom, 8)

                // Header row: Edit toggle (#9)
                HStack {
                    Spacer()
                    Button(editMode ? "Done" : "Edit") {
                        withAnimation(.spring(response: 0.25)) {
                            editMode.toggle()
                            if editMode {
                                // Remember what was open, then expand every category so all
                                // items are visible to select.
                                preEditExpanded = expandedSubs
                                for (subcat, _) in groupedItems(items, zone: selectedZone) {
                                    expandedSubs.insert(subcat)
                                }
                            } else {
                                selectedIDs.removeAll()
                                // Restore the categories to how they were before editing.
                                expandedSubs = preEditExpanded
                            }
                        }
                    }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.stockedGold)
                }
                .padding(.horizontal, 24).padding(.bottom, 4)

                // Bulk action bar — shown when items are selected
                batchActionBar

                // Scanner buttons row
                HStack(spacing: 10) {
                    Button { activeSheet = .barcode } label: {
                        Label("Scan Barcode", systemImage: "barcode.viewfinder")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    }.buttonStyle(.plain)
                    .a11yButton("Scan barcode", hint: "Add an item by scanning its barcode")
                    Button { activeSheet = .receipt } label: {
                        Label("Scan Receipt", systemImage: "doc.text.viewfinder")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    }.buttonStyle(.plain)
                    .a11yButton("Scan receipt", hint: "Add multiple items by scanning a grocery receipt")
                }
                .padding(.horizontal, 24).padding(.bottom, 16)

                // Zone tabs — tighter spacing in portrait so all five pills fit comfortably.
                // #22 — each chip is a mini heatmap: colored dot = average fill of that zone
                // (green/gold/red), small number = item count. Gaps are visible at a glance.
                // #241 — exact mockup zone chips: boxy rounded cards, icon + label only.
                // (Heatmap dots/counts and the "All" chip removed for mockup fidelity —
                // counts live in the header below; All remains reachable via search.)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(zones.filter { $0 != "All" }, id: \.self) { z in
                            let isSel = selectedZone == z
                            Button { withAnimation { selectedZone = z } } label: {
                                HStack(spacing: 7) {
                                    Image(systemName: zoneIcon(z))
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(isSel ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.55))
                                    Text(z)
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(isSel ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.6))
                                }
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .background(isSel ? Color.stockedWhite.opacity(0.95) : Color.stockedWhite.opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm + 2))
                                .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm + 2)
                                    .stroke(isSel ? Color.stockedCharcoal.opacity(0.25) : .clear, lineWidth: 1.2))
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 24)
                }.padding(.bottom, 14)

                // ── Zone title + Sort pill (#245 exact) ──────────────────
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selectedZone)
                            .font(.system(size: 24, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text("\(items.count) item\(items.count == 1 ? "" : "s")")
                            .font(.system(size: 13))
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                    Spacer()
                    Menu {
                        ForEach(InvSort.allCases, id: \.self) { mode in
                            Button { invSort = mode } label: {
                                Label(mode.rawValue, systemImage: invSort == mode ? "checkmark" : "arrow.up.arrow.down")
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Sort: \(invSort.rawValue)")
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(session.themeTextColor.opacity(0.75))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.stockedWhite.opacity(0.35))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 10)
                .onChange(of: selectedZone) { _, _ in showAllRows = false }

                // ── Search field — hidden until the header magnifier (#245) ──
                if showSearchField { inlineSearchField }

                // ── SCROLLABLE LIST ──────────────────────────────────────
                inventoryListScroll
            }
            .frame(maxWidth: showDetailPane ? splitListWidth : .infinity)
            .animation(.easeInOut(duration: 0.25), value: splitListWidth)

            detailPane
            }
        }
        .confirmationDialog("Sort by", isPresented: $showSortDialog, titleVisibility: .visible) {
            ForEach(InvSort.allCases, id: \.self) { mode in
                Button(mode.rawValue) { invSort = mode }
            }
        }
        .onChange(of: invSort) { _, newValue in
            // #246 — keep the hub's sort dialog and this list in agreement.
            UserDefaults.standard.set(newValue.rawValue, forKey: "stocked.invSort")
        }
        .onAppear {
            // #246 — pick up a sort chosen on the hub before this list was pushed.
            if let saved = UserDefaults.standard.string(forKey: "stocked.invSort"),
               let mode = InvSort(rawValue: saved) {
                invSort = mode
            }
            if startWithSearch { showSearchField = true }
        }
        .overlay(alignment: .bottom) {
            if let toast = buildToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedGreen)
                    Text(toast).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Color.stockedCharcoal).clipShape(Capsule())
                .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                .padding(.bottom, 130)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            // Re-read interface orientation on rotation. Uses interfaceOrientation (not
            // device orientation) so face-up/face-down don't flip the layout.
            refreshOrientation()
        }
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            refreshOrientation()
            // Keep expiry reminders in sync with current inventory (#9).
            DailyBriefNotificationManager.shared.rescheduleExpiryIfNeeded(store: session.guestStore)
            // Keep the "use it up" cook suggestion in sync too (#13).
            DailyBriefNotificationManager.shared.scheduleCookSuggestionIfEnabled(store: session.guestStore)
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                AddItemSheet(defaultZone: selectedZone).environment(session)
            case .barcode:
                BarcodeScannerView { _, _ in }.environment(session)
            case .receipt:
                ReceiptScannerView().environment(session)
            case let .mealPlanner(itemName, dayIndex):
                // Day + item come from the enum case (not separate @State) so they can
                // never be stale when SwiftUI builds the sheet — that timing gap was why
                // a drop on Friday opened the planner on Today.
                NavigationStack {
                    MealPlannerView(servings: 2,
                                    initialItemName: itemName,
                                    initialDayIndex: dayIndex)
                        .environment(session)
                }
            }
        }
        .sheet(isPresented: Binding(get: { inventoryShareCSV != nil },
                                    set: { if !$0 { inventoryShareCSV = nil } })) {
            // #20 — write CSV to a temp file and present the system share sheet.
            if let csv = inventoryShareCSV {
                ShareSheet(items: [Self.writeInventoryCSV(csv)])
            }
        }
        // #17 — open the exact item when an expiry reminder is tapped. On iPad it also
        // selects the split-pane detail; everywhere it presents the editor sheet.
        .onReceive(NotificationCenter.default.publisher(for: .stockedOpenInventoryItem)) { note in
            guard let idStr = note.object as? String, let uuid = UUID(uuidString: idStr) else { return }
            if let match = session.guestStore.inventoryItems.first(where: { $0.id == uuid }) {
                if splitActive { withAnimation(.spring(response: 0.3)) { detailItemID = uuid } }
                else { deepLinkItem = match }
            }
        }
        .sheet(item: $deepLinkItem) { item in
            NavigationStack { EditItemSheet(item: item).environment(session) }
        }
    }

    // Writes the CSV to a temp file for the share sheet, logging if the write fails
    // instead of silently handing back a URL to a missing file (#10).
    private static func writeInventoryCSV(_ csv: String) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Stocked-Inventory.csv")
        do {
            if let data = csv.data(using: .utf8) { try data.write(to: url) }
        } catch {
            Log.app.error("CSV export: write failed: \(error.localizedDescription, privacy: .public)")
        }
        return url
    }

    // MARK: - Quick Add
    // Create an inventory item from just a typed name. Zone is inferred via ZoneClassifier,
    // a sensible default expiry is applied by zone, and duplicates bump quantity instead of
    // creating a second row. One line replaces the 3-step sheet for the common case.
    // Shared category accordion builder used by both the iPad two-column layout and the
    // iPhone single-column layout, so the disclosure logic lives in one place.
    // Single exit path for edit mode: clears selection and restores the categories
    // to whatever was expanded before editing (so auto-expanded ones re-collapse).
    private func exitEditMode() {
        selectedIDs.removeAll()
        editMode = false
        withAnimation(.spring(response: 0.25)) { expandedSubs = preEditExpanded }
        HapticManager.success()
    }

    // Drag-to-build: dropping an inventory item on a day adds it to that day's
    // "building" meal (creating one if needed), so multiple drops accumulate into a
    // single recipe-in-progress rather than separate one-ingredient meals.
    private func addToBuildingMeal(itemName: String, dayIndex: Int) {
        let name = itemName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        var meals = session.guestStore.plannedMeals
        if let idx = meals.firstIndex(where: { $0.dayIndex == dayIndex && $0.isBuilding }) {
            // Append to the existing building meal (avoid duplicate ingredient).
            if !meals[idx].ingredients.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
                meals[idx].ingredients.append(name)
            }
            buildToast = "Added \(name.displayNormalized) — \(meals[idx].ingredients.count) items"
        } else {
            // Start a new building meal for this day.
            let meal = PlannedMeal(
                dayIndex:    dayIndex,
                title:       "New Recipe",
                servings:    session.guestStore.cookingProfile.householdSize > 0 ? session.guestStore.cookingProfile.householdSize : 2,
                ingredients: [name],
                mealType:    "Dinner",
                isBuilding:  true
            )
            meals.append(meal)
            buildToast = "Started a recipe with \(name.displayNormalized)"
        }
        session.guestStore.plannedMeals = meals
        HapticManager.success()
        // Auto-dismiss the toast.
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await MainActor.run { withAnimation { buildToast = nil } }
        }
    }

    @ViewBuilder private var batchActionBar: some View {
        if editMode && !selectedIDs.isEmpty {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    Text("\(selectedIDs.count) selected")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                    Spacer()
                    // Add selected to grocery list
                    Button {
                        for id in selectedIDs {
                            if let item = session.guestStore.inventoryItems.first(where: { $0.id == id }) {
                                session.guestStore.groceryItems.append(
                                    LocalGroceryItem(name: item.name, isChecked: false, isRecommended: true))
                            }
                        }
                        exitEditMode()
                    } label: {
                        Label("To list", systemImage: "cart.badge.plus")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.stockedGreen).clipShape(Capsule())
                    }.buttonStyle(.plain)
                    // Delete selected
                    Button {
                        let ids = selectedIDs
                        let removed = session.guestStore.inventoryItems.filter { ids.contains($0.id) }
                        withAnimation {
                            session.guestStore.inventoryItems.removeAll { ids.contains($0.id) }
                        }
                        exitEditMode()
                        let count = removed.count
                        ToastCenter.shared.undo(count == 1 ? "Item deleted" : "\(count) items deleted") {
                            withAnimation {
                                session.guestStore.inventoryItems.append(contentsOf: removed)
                            }
                        }
                    } label: {
                        Label("Delete", systemImage: "trash")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(Color.red.opacity(0.85)).clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
                // Move-to-zone row
                HStack(spacing: 8) {
                    Text("Move to:")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                    ForEach(["Fridge","Freezer","Pantry","Staples"], id: \.self) { z in
                        Button(z) {
                            for id in selectedIDs {
                                if let idx = session.guestStore.inventoryItems.firstIndex(where: { $0.id == id }) {
                                    session.guestStore.inventoryItems[idx].storageCategory = StorageCategory(rawValue: z) ?? .pantry
                                }
                            }
                            exitEditMode()
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(Color.stockedCharcoal).clipShape(Capsule())
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 8)
            .background(Color.stockedGold.opacity(0.1))
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    // #245 — mockup keeps the chrome clean; search appears on demand.
    @ViewBuilder private var inlineSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(Color.stockedWhite.opacity(0.5))
            TextField("", text: $invSearch, prompt: Text("Search items").foregroundColor(Color.stockedWhite.opacity(0.4)))
                .font(.system(size: 13)).foregroundStyle(Color.stockedWhite)
                .autocorrectionDisabled()
            if !invSearch.isEmpty {
                Button { invSearch = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13)).foregroundStyle(Color.stockedWhite.opacity(0.4))
                }.buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(session.themeButtonColor.opacity(0.6)).clipShape(Capsule())
        .padding(.horizontal, 24).padding(.bottom, 12)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder private var searchSortExportBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12)).foregroundStyle(Color.stockedWhite.opacity(0.5))
                TextField("", text: $invSearch, prompt: Text("Search items").foregroundColor(Color.stockedWhite.opacity(0.4)))
                    .font(.system(size: 13)).foregroundStyle(Color.stockedWhite)
                    .autocorrectionDisabled()
                if !invSearch.isEmpty {
                    Button { invSearch = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13)).foregroundStyle(Color.stockedWhite.opacity(0.4))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(session.themeButtonColor.opacity(0.6)).clipShape(Capsule())

            Menu {
                ForEach(InvSort.allCases, id: \.self) { mode in
                    Button {
                        invSort = mode
                    } label: {
                        Label(mode.rawValue, systemImage: invSort == mode ? "checkmark" : "arrow.up.arrow.down")
                    }
                }
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(session.themeButtonColor).clipShape(Capsule())
            }

            Menu {
                Button {
                    UIPasteboard.general.string = session.guestStore.inventoryCSV()
                } label: { Label("Copy CSV to clipboard", systemImage: "doc.on.clipboard") }
                Button {
                    inventoryShareCSV = session.guestStore.inventoryCSV()
                } label: { Label("Share CSV…", systemImage: "square.and.arrow.up") }
            } label: {
                Image(systemName: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 11).padding(.vertical, 9)
                    .background(session.themeButtonColor).clipShape(Capsule())
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 14)
    }

    @ViewBuilder private var inventoryListScroll: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                if items.isEmpty {
                    StockedEmptyState(
                        icon: "🧺",
                        title: session.guestStore.inventoryItems.isEmpty
                            ? "Your pantry is empty"
                            : "Nothing in \(selectedZone) yet",
                        subtitle: session.guestStore.inventoryItems.isEmpty
                            ? "Add items with Quick Add above, scan a barcode, or scan a grocery receipt to fill your kitchen."
                            : "Items you add to \(selectedZone) will appear here.",
                        ctaLabel: "Add an item",
                        onCTA: { activeSheet = .add }
                    )
                } else {
                    // #245 — exact mockup: a FLAT list (no subcategory groups), first 8
                    // rows, then a "View All <zone> Items" footer that expands the rest.
                    let visible = showAllRows ? items : Array(items.prefix(8))
                    LazyVStack(spacing: 8) {
                        ForEach(visible) { item in
                            InventoryItemRow(item: item, onSelect: splitActive ? { id in
                                withAnimation(.spring(response: 0.3)) {
                                    detailItemID = id
                                    if splitPreset == .wideList { splitPreset = .even; splitPreset.save() }
                                }
                            } : nil)
                        }
                    }.padding(.horizontal, 24)

                    if items.count > 8 && !showAllRows {
                        Button { withAnimation(.easeInOut(duration: 0.25)) { showAllRows = true } } label: {
                            HStack {
                                Text("View All \(selectedZone) Items")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor.opacity(0.35))
                            }
                            .padding(.horizontal, 16).padding(.vertical, 13)
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24).padding(.top, 10)
                    }
                }
            }
            .padding(.bottom, 110)
        }
    }

    @ViewBuilder private var detailPane: some View {
        // iPad master-detail: selected item's editor fills the right pane. (#3) Landscape
        // only, and only once an item is selected — otherwise the list is full-screen.
        if showDetailPane {
            // Static divider — split width is set via presets, not by dragging.
            ZStack {
                Divider()
                Capsule()
                    .fill(session.themeTextColor.opacity(0.25))
                    .frame(width: 4, height: 40)
            }
            .frame(width: 14)
            Group {
                if let id = detailItemID,
                   let item = session.guestStore.inventoryItems.first(where: { $0.id == id }) {
                    VStack(spacing: 0) {
                        HStack(spacing: 8) {
                            // Split-view size presets — how the list/editor space is divided.
                            ForEach(SplitPreset.allCases, id: \.self) { preset in
                                Button {
                                    withAnimation(.easeInOut(duration: 0.25)) { splitPreset = preset }
                                    splitPreset.save()
                                    HapticManager.light()
                                } label: {
                                    Text(preset.label)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(splitPreset == preset ? Color.stockedGold : session.themeTextColor.opacity(0.5))
                                        .padding(.horizontal, 12).padding(.vertical, 6)
                                        .background(
                                            Capsule().fill(splitPreset == preset
                                                ? session.themeButtonColor
                                                : session.themeButtonColor.opacity(0.4)))
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Split layout: \(preset.label)")
                            }
                            Spacer()
                            Button { withAnimation { detailItemID = nil } } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                            }.buttonStyle(.plain).padding(12)
                        }
                        .padding(.leading, 12)
                        EditItemSheet(item: item).environment(session)
                            .id(item.id)   // rebuild editor when a different item is picked
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "hand.tap")
                            .font(.system(size: 40)).foregroundStyle(session.themeTextColor.opacity(0.25))
                        Text("Select an item to view details")
                            .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func categoryDisclosure(_ subcat: String, _ subcatItems: [LocalInventoryItem]) -> some View {
        SubcategoryDisclosure(
            editMode: editMode,
            selectedIDs: $selectedIDs,
            onSelect: splitActive ? { id in
                withAnimation(.spring(response: 0.3)) {
                    detailItemID = id
                    // Give the detail pane room if the list preset is the widest one.
                    if splitPreset == .wideList { splitPreset = .even; splitPreset.save() }
                }
            } : nil,
            title: subcat,
            items: subcatItems,
            isExpanded: expandedSubs.contains(subcat)
        ) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                if expandedSubs.contains(subcat) { expandedSubs.remove(subcat) }
                else { expandedSubs.insert(subcat) }
            }
        }
    }

    // Default shelf life by storage zone (nil = no default expiry).
    private func defaultExpiryDays(for zone: StorageCategory) -> Int? {
        switch zone {
        case .fridge:  return 7      // perishables — a week is a safe default nudge
        case .freezer: return 90     // frozen — long
        case .pantry:  return 180    // dry goods — months
        case .staples: return nil    // salt/sugar/etc. — no meaningful expiry
        }
    }
}

// MARK: - Subcategory grouping helper
private func groupedItems(_ items: [LocalInventoryItem], zone: String = "All") -> [(String, [LocalInventoryItem])] {
    var dict: [String: [LocalInventoryItem]] = [:]
    for item in items {
        let key = subcategoryFor(item)
        dict[key, default: []].append(item)
    }
    let order = subcategoryOrder(for: zone)
    return order.compactMap { key in dict[key].map { (key, $0) } }
        + dict.filter { !order.contains($0.key) }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
}

private func subcategoryOrder(for zone: String) -> [String] {
    switch zone {
    case "Fridge":
        return ["Proteins","Dairy & Eggs","Vegetables","Fruits","Sauces & Condiments","Beverages","Leftovers","Other"]
    case "Freezer":
        return ["Proteins","Fruits & Veg","Prepared & Meals","Other"]
    case "Pantry":
        return ["Grains & Pasta","Canned & Jarred","Sauces & Condiments","Snacks","Baking","Beverages","Other"]
    case "Staples":
        return ["Oils & Fats","Aromatics","Seasonings & Spices","Sweeteners","Other"]
    default: // "All" — zone-neutral
        return ["Proteins","Dairy & Eggs","Vegetables","Fruits","Grains & Pasta",
                "Canned & Jarred","Sauces & Condiments","Oils & Fats","Aromatics",
                "Seasonings & Spices","Snacks","Baking","Beverages","Leftovers","Other"]
    }
}

private func subcategoryFor(_ item: LocalInventoryItem) -> String {
    let n = item.name.lowercased()

    if item.isLeftover { return "Leftovers" }

    // Beverages FIRST — a drink's name often contains fruit or sweetener words
    // ("Blueberry-Pomegranate Water", "Sweet Tea", "Honey Lemonade"), but it's still a
    // beverage. Checking drinks before produce/sweeteners stops that misrouting.
    let beverages = ["juice","water","soda","cola","pepsi","sprite","coffee","tea","wine","beer",
                     "drink","lemonade","smoothie","kombucha","seltzer","sparkling water","tonic",
                     "club soda","gatorade","powerade","energy drink","sports drink","cold brew",
                     "iced coffee","iced tea","coconut water","kefir","protein shake","cider",
                     "hard seltzer","lacroix","la croix","perrier","snapple","arizona","vitamin water",
                     "vitaminwater","glaceau","red bull","monster","nesquik","capri sun","sunny d"]
    if beverages.contains(where: { n.contains($0) }) { return "Beverages" }

    // Proteins
    let proteins = ["chicken","beef","pork","steak","turkey","lamb","salmon","tuna","shrimp","fish",
                    "bacon","sausage","ground","chorizo","ham","veal","bison","cod","tilapia",
                    "crab","lobster","scallop","squid","tofu","tempeh","edamame","egg","eggs"]
    if proteins.contains(where: { n.contains($0) }) { return "Proteins" }

    // Dairy & Eggs
    let dairy = ["milk","cheese","yogurt","butter","cream","cheddar","mozzarella","parmesan",
                 "brie","feta","ricotta","sour cream","whipping","half and half","kefir","ghee"]
    if dairy.contains(where: { n.contains($0) }) { return "Dairy & Eggs" }

    // Vegetables
    let vegetables = ["carrot","broccoli","spinach","lettuce","kale","cabbage","onion","garlic",
                      "tomato","pepper","celery","zucchini","squash","mushroom","corn","pea",
                      "asparagus","cucumber","eggplant","leek","beet","radish","artichoke",
                      "fennel","chard","arugula","bok choy","bean sprout","brussels","cauliflower"]
    if vegetables.contains(where: { n.contains($0) }) { return "Vegetables" }

    // Fruits
    let fruits = ["apple","banana","orange","grape","strawberry","blueberry","raspberry","mango",
                  "pineapple","peach","plum","pear","cherry","watermelon","melon","lemon","lime",
                  "avocado","fig","date","kiwi","papaya","pomegranate","grapefruit","coconut"]
    if fruits.contains(where: { n.contains($0) }) { return "Fruits" }

    // Grains & Pasta
    let grains = ["rice","pasta","noodle","spaghetti","linguine","penne","bread","flour","oat",
                  "quinoa","barley","couscous","tortilla","cracker","cereal","granola","farro"]
    if grains.contains(where: { n.contains($0) }) { return "Grains & Pasta" }

    // Canned & Jarred
    let canned = ["canned","can of","jar","jarred","bean","lentil","chickpea","soup","broth",
                  "stock","tomato sauce","tomato paste","diced tomato","coconut milk","pickle"]
    if canned.contains(where: { n.contains($0) }) { return "Canned & Jarred" }

    // Sauces & Condiments
    let sauces = ["sauce","ketchup","mustard","mayo","mayonnaise","hot sauce","soy sauce",
                  "worcestershire","bbq","ranch","vinaigrette","dressing","salsa","hummus",
                  "tahini","pesto","aioli","sriracha","teriyaki","hoisin","oyster sauce"]
    if sauces.contains(where: { n.contains($0) }) { return "Sauces & Condiments" }

    // Oils & Fats
    let oils = ["oil","olive oil","coconut oil","vegetable oil","canola","lard","shortening",
                "sesame oil","avocado oil","butter","margarine"]
    if oils.contains(where: { n.contains($0) }) { return "Oils & Fats" }

    // Aromatics
    let aromatics = ["garlic","onion","shallot","ginger","scallion","green onion","chive",
                     "lemongrass","turmeric root","horseradish"]
    if aromatics.contains(where: { n.contains($0) }) { return "Aromatics" }

    // Seasonings & Spices
    let spices = ["salt","pepper","cumin","paprika","oregano","basil","thyme","rosemary",
                  "cinnamon","nutmeg","cayenne","chili powder","curry","bay leaf","coriander",
                  "cardamom","clove","allspice","dill","parsley","sage","turmeric","sumac",
                  "za'atar","seasoning","spice","herb","vanilla","extract"]
    if spices.contains(where: { n.contains($0) }) { return "Seasonings & Spices" }

    // Sweeteners
    let sweet = ["sugar","honey","maple syrup","agave","molasses","syrup","brown sugar",
                 "powdered sugar","stevia","splenda","corn syrup","jam","jelly","preserve"]
    if sweet.contains(where: { n.contains($0) }) { return "Sweeteners" }

    // Baking
    let baking = ["baking powder","baking soda","yeast","cocoa","chocolate chip","vanilla",
                  "cornstarch","cream of tartar","gelatin","agar","buttermilk","evaporated"]
    if baking.contains(where: { n.contains($0) }) { return "Baking" }

    // Snacks
    let snacks = ["chip","crisp","pretzel","popcorn","nut","almond","cashew","walnut","peanut",
                  "seed","trail mix","granola bar","cookie","cracker","dried fruit","jerky"]
    if snacks.contains(where: { n.contains($0) }) { return "Snacks" }

    // Frozen catch-all
    if item.zone == "Freezer" { return "Prepared & Meals" }

    return "Other"
}

// MARK: - Subcategory disclosure row
struct SubcategoryDisclosure: View {
    @Environment(AppSession.self) var session
    var editMode: Bool = false
    var selectedIDs: Binding<Set<UUID>>? = nil
    var onSelect: ((UUID) -> Void)? = nil
    let title:      String
    let items:      [LocalInventoryItem]
    let isExpanded: Bool
    let onToggle:   () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            Button(action: onToggle) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor.opacity(0.7))
                    Spacer()
                    Text("\(items.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.stockedGold.opacity(0.12))
                        .clipShape(Capsule())
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                        .padding(.leading, 6)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Color.stockedCharcoal.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }
            .buttonStyle(.plain)

            // Items
            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        if editMode, let sel = selectedIDs {
                            // Edit mode: show a checkbox and toggle selection on tap.
                            Button {
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    if sel.wrappedValue.contains(item.id) { sel.wrappedValue.remove(item.id) }
                                    else { sel.wrappedValue.insert(item.id) }
                                }
                                HapticManager.light()
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: sel.wrappedValue.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 20))
                                        .foregroundStyle(sel.wrappedValue.contains(item.id) ? Color.stockedGold : session.themeTextColor.opacity(0.35))
                                        .padding(.leading, 12)
                                    InventoryItemRow(item: item)
                                        .allowsHitTesting(false)   // taps select, not open the row
                                }
                            }
                            .buttonStyle(.plain)
                        } else {
                            InventoryItemRow(item: item, onSelect: onSelect)
                                .padding(.horizontal, 4)
                        }
                        if item.id != items.last?.id {
                            Divider().background(session.themeTextColor.opacity(0.08))
                                .padding(.horizontal, 16)
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

// MARK: - Rounded corners helper
struct RoundedCorners: Shape {
    var tl: CGFloat; var tr: CGFloat; var bl: CGFloat; var br: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + tl, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - tr, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + tr),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - br))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - br, y: rect.maxY),
                          control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + bl, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - bl),
                          control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + tl))
        path.addQuadCurve(to: CGPoint(x: rect.minX + tl, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

// MARK: - Inventory Item Row — full cell tappable
// MARK: - Inventory Meal Plan Strip
// 7 day cells — drag any inventory item here to plan a meal for that day
// MARK: - WeeklyPlanStrip (merged ExpiryWeekStripView + InventoryMealPlanStrip)
private struct WeeklyDayData: Identifiable {
    let id: Int; let label: String; let dayNum: String
    let expiryCount: Int; let dotColor: Color
}

struct WeeklyPlanStrip: View {
    var onDrop: (String, Int) -> Void
    var onTap:  (Int) -> Void = { _ in }
    @Environment(AppSession.self) private var session

    private var days: [WeeklyDayData] {
        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let items = session.guestStore.inventoryItems
        return (0..<7).map { offset in
            let date  = cal.date(byAdding: .day, value: offset, to: today) ?? today
            let label = offset == 0 ? "Today" : offset == 1 ? "Tmrw"
                      : cal.weekdaySymbols[cal.component(.weekday, from: date) - 1].prefix(3).description
            let num   = cal.component(.day, from: date)
            let expiring = items.filter {
                guard let exp = $0.expirationDate else { return false }
                return cal.isDate(exp, inSameDayAs: date)
            }.count
            let dot: Color = expiring == 0 ? session.themeTextColor.opacity(0.15)
                           : offset == 0   ? .red : offset <= 2 ? .orange : Color.stockedGold
            return WeeklyDayData(id: offset, label: label, dayNum: "\(num)",
                                 expiryCount: expiring, dotColor: dot)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Drag to plan  ·  dots = expiring")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(session.themeTextColor.opacity(0.35))
                .padding(.leading, 2)
            HStack(spacing: 5) {
                ForEach(days) { day in
                    WeeklyPlanCell(day: day, onDrop: onDrop, onTap: onTap)
                        .environment(session)
                }
            }
        }
    }
}

private struct WeeklyPlanCell: View {
    @Environment(AppSession.self) private var session
    let day:    WeeklyDayData
    var onDrop: (String, Int) -> Void
    var onTap:  (Int) -> Void = { _ in }
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 3) {
            Text(day.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(isTargeted ? session.accentColor : session.themeTextColor.opacity(0.5))
                .lineLimit(1).minimumScaleFactor(0.7)
            ZStack {
                Circle().fill(isTargeted ? session.accentColor : day.dotColor)
                    .frame(width: 30, height: 30)
                if isTargeted { Image(systemName: "plus").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
                else if day.expiryCount > 0 { Text("\(day.expiryCount)").font(.system(size: 11, weight: .bold)).foregroundStyle(.white) }
            }
            Text(day.dayNum)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isTargeted ? session.accentColor : session.themeTextColor.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
            .fill(isTargeted ? session.accentColor.opacity(0.12) : session.themeCardColor.opacity(session.isDarkMode ? 1.0 : 0.5)))
        .scaleEffect(isTargeted ? 1.06 : 1.0)
        .animation(.spring(response: 0.2), value: isTargeted)
        .dropDestination(for: String.self) { items, _ -> Bool in
            guard let name = items.first else { return false }
            onDrop(name, day.id); return true
        } isTargeted: { isTargeted = $0 }
        .onTapGesture { onTap(day.id) }
    }
}

struct InventoryItemRow: View {
    @Environment(AppSession.self) var session
    let item: LocalInventoryItem
    var onSelect: ((UUID) -> Void)? = nil   // iPad: route tap to detail pane instead of sheet
    @State private var showUndo = false
    @State private var undoItem: LocalInventoryItem? = nil
    @State private var showEdit = false
    @State private var showPairings = false

    private var batteryColor: Color {
        if item.isExpired { return .red }
        if item.isExpiringSoon { return .orange }
        return item.effectiveLevel < 0.25 ? .red : item.effectiveLevel < 0.5 ? Color.stockedGold : Color.stockedGreen
    }
    // #241 — exact mockup quantity line: count when >1, otherwise the fill word.
    private var qtyLine: String {
        if item.quantity > 1 { return "\(item.quantity) count" }
        return item.level >= 0.66 ? "Full" : item.level >= 0.33 ? "Half" : "Low"
    }
    private var levelLabel: String {
        if item.isExpired { return "Expired" }
        if item.isExpiringSoon, let d = item.daysUntilExpiry { return d == 0 ? "Expires today" : (d == 1 ? "Expires tomorrow" : "Expires in \(d) days") }
        return item.level >= 0.66 ? "Full" : item.level >= 0.33 ? "Half" : "Low"
    }

    var body: some View {
        Button {
            if let onSelect { onSelect(item.id) } else { showEdit = true }
        } label: {
            // #237 — full mockup row: emoji/photo tile · name + qty line · right-aligned
            // expiry in orange · chevron. The level bar moved into a thin strip under the
            // name so drag/level info isn't lost.
            HStack(spacing: 14) {
                if let data = item.imageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable().scaledToFill()
                        .frame(width: 42, height: 42)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm)
                            .fill(Color.stockedWhite.opacity(0.55))
                            .frame(width: 42, height: 42)
                        Text(ImageFallbackService.emoji(for: item.name))
                            .font(.system(size: 22))
                    }
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.name.displayNormalized)
                        .font(.system(size: 15.5, weight: .semibold))
                        .dynamicTypeSize(.xSmall ... .xxxLarge)
                        .foregroundStyle(session.themeTextColor)
                        .lineLimit(1)
                    Text(qtyLine)
                        .font(.system(size: 12.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }

                Spacer(minLength: 8)

                if let d = item.daysUntilExpiry {
                    Text(d < 0 ? "Expired" : d == 0 ? "Expires today" : d == 1 ? "Expires tomorrow" : "Expires in \(d) days")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(d < 0 ? Color.red : d <= 1 ? Color.red.opacity(0.8) : Color.orange)
                        .lineLimit(1).minimumScaleFactor(0.75)
                } else {
                    Text(item.level >= 0.66 ? "Full" : item.level >= 0.33 ? "Half" : "Low")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(batteryColor)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(.horizontal, 14).padding(.vertical, 13)
            .background(item.isExpired ? Color.red.opacity(0.08)
                        : (session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.50)))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                .stroke(item.isExpired ? Color.red.opacity(0.3) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button { session.guestStore.updateInventoryLevel(id: item.id, level: min(1, item.level + 0.25)) } label: {
                Label("Restock (+25%)", systemImage: "arrow.up.circle")
            }
            Button { session.guestStore.updateInventoryLevel(id: item.id, level: max(0.1, item.level - 0.25)) } label: {
                Label("Use Some (-25%)", systemImage: "minus.circle")
            }
            Button { showPairings = true } label: {
                Label("Ingredient Pairings", systemImage: "link.circle")
            }
            Divider()
            Button(role: .destructive) {
                // #251 — undoable delete (mirrors the batch-delete + grocery clear pattern).
                let removed = item
                session.guestStore.removeInventoryItem(id: item.id)
                UsageMetrics.shared.record(.itemDeleted)
                ToastCenter.shared.undo("Deleted \(item.name.displayNormalized)") {
                    session.guestStore.restoreInventoryItems([removed])
                }
            } label: {
                Label("Remove", systemImage: "trash")
            }
        }
        .sheet(isPresented: $showEdit) {
            EditItemSheet(item: item).environment(session)
        }
        .sheet(isPresented: $showPairings) {
            IngredientPairingsSheet(itemName: item.name).environment(session)
        }
        // Drag to meal calendar — transfers item name as plain text
        .draggable(item.name)
    }
}
