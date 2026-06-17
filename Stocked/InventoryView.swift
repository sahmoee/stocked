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

// MARK: - Edit Item Sheet
struct EditItemSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    var item: LocalInventoryItem
    @State private var level:       Double
    @State private var zone:        String
    @State private var hasExpiry:   Bool
    @State private var expiryDate:  Date
    @State private var qty:         Int
    @State private var unit:        String
    @State private var hasCount:    Bool
    @State private var countValue:  Int
    @State private var imageData:   Data?
    @State private var par:         Int
    @State private var category:    String
    @State private var subZone:     String
    @State private var showPhotoPicker = false
    @State private var editedName:    String
    @State private var isEditingName: Bool = false
    @FocusState private var nameFieldFocused: Bool

    let zones = ["Fridge","Freezer","Pantry","Staples"]
    let commonUnits = ["items","g","kg","ml","L","oz","lb","bag","box","pack","can","jar","bottle","bunch","dozen"]

    init(item: LocalInventoryItem) {
        self.item = item
        _level     = State(initialValue: item.level)
        _zone      = State(initialValue: item.zone)
        _hasExpiry  = State(initialValue: item.expirationDate != nil)
        _expiryDate = State(initialValue: item.expirationDate ?? Date().addingTimeInterval(7*86400))
        _qty        = State(initialValue: max(1, item.quantity))
        _unit       = State(initialValue: item.containerType.isEmpty ? "item" : item.containerType)
        _hasCount   = State(initialValue: false)
        _countValue = State(initialValue: 1)
        _imageData  = State(initialValue: item.imageData)
        _par        = State(initialValue: item.parQuantity ?? 0)
        _category   = State(initialValue: item.customCategory ?? "")
        _subZone    = State(initialValue: item.subZone ?? "")
        _editedName = State(initialValue: item.name.displayNormalized)
    }

    private var subZonePlaceholder: String {
        switch zone {
        case "Fridge":  return "e.g. Door, Top shelf, Crisper"
        case "Freezer": return "e.g. Top drawer, Door bin"
        case "Pantry":  return "e.g. Top shelf, Spice rack"
        default:         return "e.g. Cabinet, Counter"
        }
    }

    private func commitName() {
        let trimmed = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            editedName = item.name.displayNormalized
        } else {
            editedName = trimmed
        }
        withAnimation(.easeInOut(duration: 0.15)) { isEditingName = false }
        nameFieldFocused = false
        HapticManager.select()
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                        .frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 16)

                    // Item name — tap the pencil to rename in place.
                    if isEditingName {
                        HStack(spacing: 8) {
                            TextField("Item name", text: $editedName, axis: .vertical)
                                .font(.system(size: 22, weight: .bold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                                .tint(Color.stockedGold)
                                .focused($nameFieldFocused)
                                .submitLabel(.done)
                                .onSubmit { commitName() }
                            Button { commitName() } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(Color.stockedGold)
                            }.buttonStyle(.plain)
                            .a11yButton("Save name")
                        }
                        .padding(.horizontal, 28).padding(.bottom, 16)
                        .onAppear { nameFieldFocused = true }
                    } else {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(editedName)
                                .font(.system(size: 22, weight: .bold, design: .serif)).dynamicTypeSize(.xSmall ... .accessibility2)
                                .foregroundStyle(session.themeTextColor)
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { isEditingName = true }
                            } label: {
                                Image(systemName: "square.and.pencil")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.stockedGold)
                            }.buttonStyle(.plain)
                            .a11yButton("Edit name", hint: "Rename this item")
                        }
                        .padding(.horizontal, 28).padding(.bottom, 16)
                    }

                    // ── Photo row ────────────────────────────────────────
                    photoRow
                    Picker("Zone", selection: $zone) {
                        ForEach(zones, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.segmented).padding(.horizontal, 28).padding(.bottom, 20)

                    // ── Quantity row: (N) (unit) of (N optional) ────
                    quantityRow

                    // ── Amount slider (fill level) ───────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Fill Level")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                            Spacer()
                            Text("\(Int(level*100))%")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Color.stockedGold)
                        }
                        Slider(value: $level, in: 0.05...1.0, step: 0.05).tint(Color.stockedGold)
                    }.padding(.horizontal, 28).padding(.bottom, 20)

                    // ── Par level (auto-reorder) ─────────────────────
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Keep at least")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                            Spacer()
                            Text(par > 0 ? "\(par) in stock" : "Off")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(par > 0 ? Color.stockedGold : session.themeTextColor.opacity(0.4))
                        }
                        HStack(spacing: 16) {
                            Button { if par > 0 { withAnimation(.spring(response: 0.2)) { par -= 1 } } } label: {
                                Image(systemName: "minus.circle.fill").font(.system(size: 26))
                                    .foregroundStyle(par > 0 ? Color.stockedGold : session.themeTextColor.opacity(0.25))
                            }.buttonStyle(.plain).disabled(par == 0)
                            Text(par > 0 ? "\(par)" : "—")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(session.themeTextColor)
                                .frame(minWidth: 28)
                            Button { withAnimation(.spring(response: 0.2)) { par += 1 } } label: {
                                Image(systemName: "plus.circle.fill").font(.system(size: 26))
                                    .foregroundStyle(Color.stockedGold)
                            }.buttonStyle(.plain)
                            Spacer()
                            Text(par > 0 ? "Auto-added to your list when you drop below \(par)." : "Set a minimum to auto-reorder this item.")
                                .font(.system(size: 11))
                                .foregroundStyle(session.themeTextColor.opacity(0.45))
                                .multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }.padding(.horizontal, 28).padding(.bottom, 20)

                    // ── Organize: category + spot (surfaces customCategory / subZone) ──
                    VStack(alignment: .leading, spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Category")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                            TextField("e.g. Snacks, Baking, Drinks", text: $category)
                                .font(.system(size: 15))
                                .foregroundStyle(session.themeTextColor)
                                .tint(Color.stockedGold)
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .background(Color.stockedWhite.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Spot in \(zone)")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                            TextField(subZonePlaceholder, text: $subZone)
                                .font(.system(size: 15))
                                .foregroundStyle(session.themeTextColor)
                                .tint(Color.stockedGold)
                                .padding(.horizontal, 14).padding(.vertical, 11)
                                .background(Color.stockedWhite.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 20)

                    // ── Expiry ───────────────────────────────────────
                    ExpiryDateRow(hasExpiry: $hasExpiry, expiryDate: $expiryDate)
                        .padding(.horizontal, 28).padding(.bottom, 24)

                    // ── Actions ──────────────────────────────────────
                    actionButtons
                }
            }
        }
        .presentationDetents([.large]).presentationDragIndicator(.hidden)
    }

    @ViewBuilder private var photoRow: some View {
        Button { showPhotoPicker = true } label: {
            ZStack {
                if let data = imageData, let ui = UIImage(data: data) {
                    Image(uiImage: ui)
                        .resizable().scaledToFill()
                        .frame(height: 140)
                        .clipped()
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                } else {
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                        .fill(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
                        .frame(height: 80)
                    VStack(spacing: 6) {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(session.themeTextColor.opacity(0.35))
                        Text("Add Photo")
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeTextColor.opacity(0.35))
                    }
                }
                if imageData != nil {
                    VStack {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation { imageData = nil }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(.white)
                                    .shadow(radius: 3)
                            }
                            .buttonStyle(.plain)
                            .padding(8)
                        }
                        Spacer()
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 28).padding(.bottom, 20)
        .sheet(isPresented: $showPhotoPicker) {
            ItemPhotoPicker(imageData: $imageData)
        }
    }

    @ViewBuilder private var quantityRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUANTITY")
                .font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(session.themeTextColor.opacity(0.4))
                .padding(.horizontal, 28)

            HStack(spacing: 12) {
                // First number — stepper
                HStack(spacing: 0) {
                    Button { qty = max(1, qty - 1) } label: {
                        Image(systemName: "minus").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(session.themeTextColor).frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Text("\(qty)")
                        .font(.system(size: 18, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedGold).frame(minWidth: 32)
                    Button { qty += 1 } label: {
                        Image(systemName: "plus").font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(session.themeTextColor).frame(width: 36, height: 36).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))

                // Unit picker
                Menu {
                    ForEach(commonUnits, id: \.self) { u in Button(u) { unit = u } }
                } label: {
                    HStack(spacing: 4) {
                        Text(unit).font(.system(size: 14, weight: .semibold)).foregroundStyle(session.themeTextColor)
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                }

                // "of" connector
                Text("of").font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.4))

                // Second number (optional)
                if hasCount {
                    HStack(spacing: 0) {
                        Button { countValue = max(1, countValue - 1) } label: {
                            Image(systemName: "minus").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor).frame(width: 30, height: 36).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        Text("\(countValue)")
                            .font(.system(size: 18, weight: .bold, design: .serif))
                            .foregroundStyle(Color.stockedGold).frame(minWidth: 28)
                        Button { countValue += 1 } label: {
                            Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(session.themeTextColor).frame(width: 30, height: 36).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    Button {
                        withAnimation(.spring(response: 0.25)) { hasCount = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(session.themeTextColor.opacity(0.25))
                    }.buttonStyle(.plain)
                } else {
                    Button {
                        withAnimation(.spring(response: 0.25)) { hasCount = true; countValue = 1 }
                    } label: {
                        Text("None")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 28)

            // Preview label
            let preview = hasCount
                ? "\(qty) \(unit) of \(countValue)"
                : "\(qty) \(unit)"
            Text(preview + " of \(item.name)")
                .font(.system(size: 12, design: .serif))
                .foregroundStyle(session.themeTextColor.opacity(0.5))
                .padding(.horizontal, 28)
        }
        .padding(.bottom, 20)
    }

    @ViewBuilder private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                commitName()   // fold in any in-progress rename
                let finalName = editedName.trimmingCharacters(in: .whitespacesAndNewlines)
                if let i = session.guestStore.inventoryItems.firstIndex(where: { $0.id == item.id }) {
                    if !finalName.isEmpty { session.guestStore.inventoryItems[i].name = finalName }
                    session.guestStore.inventoryItems[i].level          = level
                    session.guestStore.inventoryItems[i].storageCategory = StorageCategory(rawValue: zone) ?? .pantry
                    session.guestStore.inventoryItems[i].expirationDate = hasExpiry ? expiryDate : nil
                    session.guestStore.inventoryItems[i].quantity       = qty
                    session.guestStore.inventoryItems[i].containerType  = unit
                    session.guestStore.inventoryItems[i].imageData      = imageData
                    session.guestStore.inventoryItems[i].parQuantity    = par > 0 ? par : nil
                    let cat  = category.trimmingCharacters(in: .whitespacesAndNewlines)
                    let spot = subZone.trimmingCharacters(in: .whitespacesAndNewlines)
                    session.guestStore.inventoryItems[i].customCategory = cat.isEmpty ? nil : cat
                    session.guestStore.inventoryItems[i].subZone        = spot.isEmpty ? nil : spot
                    if hasCount {
                        session.guestStore.inventoryItems[i].quantityUsed = Double(countValue)
                    }
                }
                dismiss()
            } label: {
                Text("Save Changes")
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }.buttonStyle(.plain).padding(.horizontal, 28)

            Button(role: .destructive) {
                session.guestStore.removeInventoryItem(id: item.id)
                dismiss()
            } label: {
                Text("Remove Item")
                    .font(.system(size: 14)).foregroundStyle(.red)
            }
        }.padding(.bottom, 32)
    }
}

// MARK: - Add Item Sheet — 3-step flow
struct AddItemSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    var defaultZone: String = "Fridge"

    // ── Step state ─────────────────────────────────────────────────
    @State private var step: Int = 1

    // Step 1
    @State private var itemName:       String = ""
    @State private var nameTouched:    Bool   = false   // inline validation (#9)
    @State private var zone:           String
    @State private var quantity:       Int    = 1
    @State private var containerType:  String = ""
    // Combined size + current-amount control (e.g. "6 of 12 eggs"). totalUnits is how many the
    // full container holds; currentUnits is how many are left → drives the stored fill level.
    @State private var hasAmount:      Bool   = false
    @State private var totalUnits:     Double = 12
    @State private var currentUnits:   Double = 12

    // Step 2
    @State private var showSizeDetails: Bool   = false
    @State private var sizeAmount:      String = ""
    @State private var sizeUnit:        String = ""

    // Step 3
    @State private var hasExpiry:  Bool = false
    @State private var expiryDate: Date = Date().addingTimeInterval(7 * 86400)

    // Browse
    @State private var showBrowse = false
    @State private var showScanBarcode = false   // #250 — Scan Barcode from Add Item
    // Duplicate detection
    @State private var duplicateItem: LocalInventoryItem? = nil
    @State private var showDuplicateAlert = false
    // UPC fallback — name provided by user after failed barcode scan
    var upcFallbackName: String? = nil

    let zones = ["Fridge", "Freezer", "Pantry", "Staples"]

    init(defaultZone: String = "Fridge") {
        self.defaultZone = defaultZone
        _zone = State(initialValue: defaultZone)
    }

    // MARK: Body
    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {

                // ── Handle ──────────────────────────────────────────────
                Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 4)

                // ── Header ──────────────────────────────────────────────
                HStack {
                    Text("Add Item")
                        .font(.system(size: 22, weight: .bold, design: .serif)).dynamicTypeSize(.xSmall ... .accessibility2)
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Button { showScanBarcode = true } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "barcode.viewfinder").font(.system(size: 12, weight: .semibold))
                            Text("Scan")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
                        .clipShape(Capsule())
                    }.buttonStyle(.plain)
                    Button { showBrowse = true } label: {
                        Text("Browse")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.stockedWhite)
                            .padding(.horizontal, 14).padding(.vertical, 11)
                            .background(Color.stockedCharcoal)
                            .clipShape(Capsule())
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 24).padding(.vertical, 12)

                // ── Step indicator ──────────────────────────────────────
                HStack(spacing: 8) {
                    ForEach(1...3, id: \.self) { s in
                        HStack(spacing: 6) {
                            Circle()
                                .fill(s <= step ? Color.stockedGold : Color.stockedCharcoal.opacity(0.2))
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Text("\(s)").font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(s <= step ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.4))
                                )
                            if s < 3 {
                                Rectangle().fill(Color.stockedCharcoal.opacity(s < step ? 0.5 : 0.15))
                                    .frame(height: 1).frame(maxWidth: 40)
                            }
                        }
                    }
                    Spacer()
                    Text(stepLabel).font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
                }
                .padding(.horizontal, 24).padding(.bottom, 16)

                Divider()

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {
                        switch step {
                        case 1:  stepOneContent
                        case 2:  stepTwoContent
                        default: stepThreeContent
                        }
                    }
                    .padding(.top, 20).padding(.bottom, 40)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
        .dismissKeyboardOnTap()
        .keyboardDoneToolbar()
        .sheet(isPresented: $showBrowse) {
            IngredientBrowserSheet(defaultZone: zone).environment(session)
        }
        .sheet(isPresented: $showScanBarcode) {
            // #250 — BarcodeScannerView adds the scanned item to inventory itself, then
            // calls onResult and dismisses. Once it returns having added something, close
            // the Add Item sheet too so the user lands back on their pantry.
            BarcodeScannerView { name, _ in
                showScanBarcode = false
                if !name.isEmpty { dismiss() }
            }
            .environment(session)
        }
        .animation(.easeInOut(duration: 0.2), value: step)
    }

    private var stepLabel: String {
        switch step {
        case 1: return "Required fields"
        case 2: return "Size details (optional)"
        default: return "Expiration (optional)"
        }
    }

    // MARK: - Step 1: Basic Info
    private var stepOneContent: some View {
        VStack(spacing: 20) {
            // Item name
            VStack(alignment: .leading, spacing: 10) {
                Text("ITEM NAME")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                VStack(alignment: .leading, spacing: 0) {
                    FoodPredictiveTextField(
                        placeholder: "Item name",
                        text: $itemName,
                        onCommit: {},
                        onSelect: { selected in
                            // Auto-classify zone when user picks a suggestion
                            let suggested = ZoneClassifier.classify(selected).rawValue
                            withAnimation(.spring(response: 0.25)) { zone = suggested }
                        }
                    )
                    .font(.system(size: 16)).foregroundStyle(session.themeTextColor)
                    .onChange(of: itemName) { _, name in
                        if !name.isEmpty { nameTouched = true }
                        guard name.count >= 2 else { return }
                        // The zone follows what you're adding (so a seasoning lands on
                        // Staples) rather than sticking to the last/viewed area. The user
                        // can still tap a different zone to override.
                        let suggested = ZoneClassifier.classify(name).rawValue
                        if zone != suggested {
                            withAnimation(.spring(response: 0.25)) { zone = suggested }
                        }
                    }
                }
                .padding(14)
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                .overlay(
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                        .stroke(showNameError ? Color.stockedGold : Color.clear, lineWidth: 1.5)
                )
                // Inline validation message — appears only once the user has typed then cleared
                // it, explaining why Continue is disabled instead of a dead button (#9).
                if showNameError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                        Text("Give the item a name to continue")
                            .font(.system(size: 12)).foregroundStyle(Color.stockedGold)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .accessibilityElement(children: .combine)
                }
            }.padding(.horizontal, 24)
            .animation(.easeInOut(duration: 0.2), value: showNameError)

            // Zone tabs
            VStack(alignment: .leading, spacing: 8) {
                Text("STORED IN")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                HStack(spacing: 0) {
                    ForEach(zones, id: \.self) { z in
                        Button {
                            withAnimation(.spring(response: 0.25)) { zone = z }
                        } label: {
                            Text(z)
                                .font(.system(size: 13, weight: zone == z ? .bold : .medium, design: .serif))
                                .foregroundStyle(zone == z ? Color.stockedWhite : session.themeTextColor.opacity(0.6))
                                .frame(maxWidth: .infinity).padding(.vertical, 10)
                                .background(zone == z ? session.themeButtonColor : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }.padding(.horizontal, 24)

            // Quantity
            VStack(alignment: .leading, spacing: 8) {
                Text("QUANTITY")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                HStack(spacing: 0) {
                    Button { if quantity > 1 { withAnimation(.spring(response: 0.2)) { quantity -= 1 } } } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                            .frame(width: 52, height: 46).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    Text("\(quantity)")
                        .font(.system(size: 22, weight: .bold, design: .serif)).dynamicTypeSize(.xSmall ... .accessibility2)
                        .foregroundStyle(Color.stockedGold).frame(minWidth: 50)
                    Button { withAnimation(.spring(response: 0.2)) { quantity += 1 } } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                            .frame(width: 52, height: 46).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            }.padding(.horizontal, 24)

            // Container type
            VStack(alignment: .leading, spacing: 8) {
                Text("CONTAINER TYPE")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                Menu {
                    ForEach(ContainerType.all, id: \.self) { c in
                        Button(c) { containerType = c }
                    }
                } label: {
                    HStack {
                        Text(containerType.isEmpty ? "Select container type" : containerType)
                            .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge)
                            .foregroundStyle(containerType.isEmpty ? session.themeTextColor.opacity(0.35) : session.themeTextColor)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeTextColor.opacity(0.35))
                    }
                    .padding(14)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                }
            }.padding(.horizontal, 24)

            // Current amount — combined size + how-much-you-have slider ("6 of 12 eggs").
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("CURRENT AMOUNT")
                        .font(.system(size: 10, weight: .bold)).tracking(1)
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                    Spacer()
                    Toggle("", isOn: $hasAmount.animation(.spring(response: 0.25))).labelsHidden()
                        .tint(Color.stockedGold)
                }
                if hasAmount {
                    // Total size (how many a full one holds)
                    HStack(spacing: 10) {
                        Text("Holds")
                            .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.7))
                        Button { if totalUnits > 1 { totalUnits -= 1; currentUnits = min(currentUnits, totalUnits) } } label: {
                            Image(systemName: "minus.circle").font(.system(size: 18)).foregroundStyle(session.themeTextColor.opacity(0.6))
                        }.buttonStyle(.plain)
                        Text("\(Int(totalUnits))")
                            .font(.system(size: 18, weight: .bold, design: .serif)).foregroundStyle(Color.stockedGold).frame(minWidth: 34)
                        Button { totalUnits += 1 } label: {
                            Image(systemName: "plus.circle").font(.system(size: 18)).foregroundStyle(session.themeTextColor.opacity(0.6))
                        }.buttonStyle(.plain)
                        Text(containerType.isEmpty ? "total" : "per \(containerType)")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        Spacer()
                    }
                    // Current amount slider, shown as "X of Y"
                    VStack(alignment: .leading, spacing: 4) {
                        Text("You have \(Int(currentUnits)) of \(Int(totalUnits))")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(session.themeTextColor)
                        Slider(value: $currentUnits, in: 0...totalUnits, step: 1).tint(Color.stockedGold)
                    }
                }
            }.padding(.horizontal, 24)

            continueButton(enabled: !itemName.trimmingCharacters(in: .whitespaces).isEmpty) {
                let name = itemName.trimmingCharacters(in: .whitespaces).lowercased()
                // Fuzzy duplicate check — match if existing name contains or is contained by new name
                if let match = session.guestStore.inventoryItems.first(where: {
                    let existing = $0.name.lowercased()
                    return existing == name || existing.contains(name) || name.contains(existing)
                }) {
                    duplicateItem = match
                    showDuplicateAlert = true
                } else {
                    withAnimation { step = 2 }
                }
            }
            .alert("Already in Pantry", isPresented: $showDuplicateAlert, presenting: duplicateItem) { match in
                Button("Add Anyway") { withAnimation { step = 2 } }
                Button("Cancel", role: .cancel) {}
            } message: { match in
                Text("\"\(match.name)\" is already in your \(match.zone). Add another or cancel to update that item instead.")
            }
        }
    }

    // MARK: - Step 2: Size Details
    private var stepTwoContent: some View {
        VStack(spacing: 20) {
            // Summary row
            summaryRow

            // Toggle
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Add size details")
                            .font(.system(size: 15, weight: .medium, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text("optional")
                            .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                    Spacer()
                    Toggle("", isOn: $showSizeDetails.animation(.spring(response: StockedUI.animationMd)))
                        .tint(Color.stockedGold).labelsHidden()
                }
                .padding(16)
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))

                if showSizeDetails {
                    VStack(spacing: 14) {
                        // Amount per container
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Amount per container")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                            TextField("e.g. 16, 12, 1.5", text: $sizeAmount)
                                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                                .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge).foregroundStyle(session.themeTextColor)
                                .keyboardType(.decimalPad)
                                .padding(14)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        }
                        // Measurement unit
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Measurement Unit")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                            Menu {
                                ForEach(MeasurementUnit.all, id: \.self) { u in
                                    Button(u) { sizeUnit = u }
                                }
                            } label: {
                                HStack {
                                    Text(sizeUnit.isEmpty ? "Select unit" : sizeUnit)
                                        .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge)
                                        .foregroundStyle(sizeUnit.isEmpty ? session.themeTextColor.opacity(0.35) : session.themeTextColor)
                                    Spacer()
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 12))
                                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                                }
                                .padding(14)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            }
                        }
                    }
                    .padding(.horizontal, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }.padding(.horizontal, 24)

            // Live preview
            if !itemName.isEmpty {
                previewBadge
            }

            HStack(spacing: 12) {
                backButton
                continueButton(enabled: true) {
                    withAnimation { step = 3 }
                }
            }.padding(.horizontal, 24)
        }
    }

    // MARK: - Step 3: Extras
    private var stepThreeContent: some View {
        VStack(spacing: 20) {
            summaryRow

            // Expiry
            VStack(alignment: .leading, spacing: 8) {
                Text("EXPIRES ON (optional)")
                    .font(.system(size: 10, weight: .bold)).tracking(1)
                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                ExpiryDateRow(hasExpiry: $hasExpiry, expiryDate: $expiryDate)
                    .padding(14)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    .onChange(of: hasExpiry) { _, on in
                        // Smart default: when expiry is switched on, pre-fill a sensible date
                        // based on where the item is stored, so the user confirms vs. types (#10).
                        guard on else { return }
                        let days: TimeInterval
                        switch zone {
                        case "Freezer": days = 90
                        case "Pantry":  days = 180
                        case "Staples": days = 365
                        default:        days = 7      // Fridge
                        }
                        expiryDate = Date().addingTimeInterval(days * 86400)
                    }
            }.padding(.horizontal, 24)

            if !itemName.isEmpty {
                previewBadge
            }

            HStack(spacing: 12) {
                backButton

                // Gold "Add to Zone" button
                Button {
                    let name = itemName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    // Derive the fill level from the current-amount control if used ("6 of 12" → 0.5).
                    let derivedLevel = (hasAmount && totalUnits > 0) ? max(0.0, min(1.0, currentUnits / totalUnits)) : 1.0
                    var item = LocalInventoryItem(
                        name: name, level: derivedLevel, zone: zone,
                        quantity: quantity,
                        containerType: containerType.isEmpty ? "item" : containerType,
                        sizeAmount: hasAmount ? totalUnits : Double(sizeAmount),
                        sizeUnit: sizeUnit.isEmpty ? nil : sizeUnit
                    )
                    item.expirationDate   = hasExpiry ? expiryDate : nil
                    item.storePurchasedAt = session.preferredStore
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    session.guestStore.addInventoryItem(item)
                    UsageMetrics.shared.record(.itemAddedManual)
                    ToastCenter.shared.success("Added \(name) to \(zone)")
                    dismiss()
                } label: {
                    Text("Add to \(zone)")
                        .font(.system(size: 16, weight: .bold, design: .serif))
                        .foregroundStyle(name.isEmpty ? Color.stockedWhite.opacity(0.5) : Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(
                            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                                .fill(itemName.trimmingCharacters(in: .whitespaces).isEmpty
                                    ? Color.stockedGold.opacity(0.4)
                                    : Color.stockedGold)
                        )
                }
                .disabled(itemName.trimmingCharacters(in: .whitespaces).isEmpty)
                .buttonStyle(.plain)
            }.padding(.horizontal, 24)
        }
    }

    // MARK: - Shared components
    private var summaryRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedGold)
            VStack(alignment: .leading, spacing: 1) {
                Text(itemName.isEmpty ? "Item" : itemName)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text("\(quantity) \(containerType.isEmpty ? "item" : containerType) · \(zone)")
                    .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
        }
        .padding(.horizontal, 24).padding(.vertical, 10)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
    }

    private var previewBadge: some View {
        let preview: String = {
            let amt = Double(sizeAmount)
            let container = containerType.isEmpty ? "item" : containerType
            if showSizeDetails, let a = amt, !sizeAmount.isEmpty, !sizeUnit.isEmpty {
                return "\(quantity) \(container) (\(a.clean) \(sizeUnit) each) of \(itemName)"
            }
            return "\(quantity) \(container) of \(itemName)"
        }()
        return HStack(spacing: 8) {
            Text(preview).font(.system(size: 13, design: .serif))
                .foregroundStyle(session.themeTextColor.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 24)
    }

    private var backButton: some View {
        Button {
            withAnimation { step -= 1 }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left").font(.system(size: 13, weight: .semibold))
                Text("Back").font(.system(size: 15, weight: .semibold, design: .serif))
            }
            .foregroundStyle(session.themeTextColor)
            .padding(.vertical, 16).padding(.horizontal, 20)
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
        }.buttonStyle(.plain)
    }

    private func continueButton(enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text("Continue")
                .font(.system(size: 16, weight: .semibold, design: .serif))
                .foregroundStyle(enabled ? Color.stockedWhite : Color.stockedWhite.opacity(0.4))
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                        .fill(enabled ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.4))
                )
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    // Computed property to avoid closure capture issue
    private var name: String { itemName.trimmingCharacters(in: .whitespaces) }
    // True once the user has interacted with the name field and left it empty (#9).
    private var showNameError: Bool { nameTouched && name.isEmpty }
}

// MARK: - Ingredient Browser Sheet (accessed via Browse button)
struct IngredientBrowserSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    var defaultZone: String = "Fridge"
    @State private var searchText      = ""
    @State private var selectedCategory: String? = nil
    @State private var recentlyAdded:  Set<String> = []
    @State private var detailEntry:    IngredientEntry? = nil
    @State private var detailQty:      Int    = 1
    @State private var detailUnit:     String = "items"
    @State private var detailNote:     String = ""
    @State private var detailHasExpiry: Bool  = false
    @State private var detailExpiry:   Date   = Date().addingTimeInterval(7*86400)

    private let kb = StockedKnowledgeBase.shared

    private var filteredItems: [KnowledgeIngredient] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            return kb.ingredients.filter { $0.name.searchMatches(q) }
        }
        if let cat = selectedCategory {
            return kb.ingredients.filter { $0.category == cat }
                .sorted { $0.name < $1.name }
        }
        return kb.ingredients.sorted { $0.name < $1.name }
    }
    private var categories: [String] {
        Array(Set(kb.ingredients.map(\.category))).sorted()
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.2)).frame(width: 40, height: 4).padding(.top, 12)
                HStack {
                    Text("Browse Ingredients")
                        .font(.system(size: 22, weight: .bold, design: .serif)).dynamicTypeSize(.xSmall ... .accessibility2).foregroundStyle(session.themeTextColor)
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 22))
                            .foregroundStyle(session.themeTextColor.opacity(0.3))
                    }.buttonStyle(.plain)
                }.padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 16)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(session.themeTextColor.opacity(0.4))
                    FoodPredictiveTextField(placeholder: "Search ingredients…", text: $searchText, onCommit: {})
                        .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge).foregroundStyle(session.themeTextColor)
                }.padding(12).background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                 .padding(.horizontal, 24).padding(.bottom, 12)

                if searchText.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(categories, id: \.self) { cat in
                                Button {
                                    selectedCategory = selectedCategory == cat ? nil : cat
                                } label: {
                                    Text(cat)
                                        .font(.system(size: 12, weight: selectedCategory == cat ? .bold : .medium))
                                        .foregroundStyle(selectedCategory == cat ? Color.stockedWhite : session.themeTextColor.opacity(0.7))
                                        .padding(.horizontal, 12).padding(.vertical, 10)
                                        .background(selectedCategory == cat ? Color.stockedCharcoal : Color.stockedWhite.opacity(0.4))
                                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 24).padding(.bottom, 12)
                    }
                }

                List {
                    ForEach(filteredItems) { ki in
                        browserRow(ki.asIngredientEntry)
                    }
                }.listStyle(.plain).scrollContentBackground(.hidden)
            }
        }
        .sheet(item: $detailEntry) { entry in
            ItemDetailPopup(
                entry: entry, qty: $detailQty, unit: $detailUnit,
                note: $detailNote, hasExpiry: $detailHasExpiry, expiry: $detailExpiry,
                onAdd: { qty, unit, note, hasExp, expDate in
                    let zone = defaultZone
                    var item = LocalInventoryItem(name: entry.name, level: 1.0, zone: zone,
                                                   quantity: qty, containerType: unit)
                    item.expirationDate = hasExp ? expDate : nil
                    item.storePurchasedAt = session.preferredStore
                    if let topBrand = BrandDatabase.brands(for: entry.name).first {
                        item.brand = topBrand.brand; item.nutrition = topBrand.nutrition.toFacts()
                    }
                    session.guestStore.addInventoryItem(item)
                    session.guestStore.recordItemAdded(name: entry.name, zone: zone,
                                                       unit: unit, brand: item.brand ?? "")
                    recentlyAdded.insert(entry.name)
                    Task {
                        try? await Task.sleep(nanoseconds: 1400000000)
                        recentlyAdded.remove(entry.name)
                    }
                    detailEntry = nil
                }
            ).environment(session)
        }
    }

    private func browserRow(_ entry: IngredientEntry) -> some View {
        HStack(spacing: 14) {
            Text(itemIcon(for: entry)).font(.system(size: 26)).frame(width: 36)
            VStack(alignment: .leading, spacing: 10) {
                Text(entry.name).font(.system(size: 15, weight: .semibold)).dynamicTypeSize(.xSmall ... .xxxLarge).foregroundStyle(session.themeTextColor)
                Text(entry.category).font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
            }
            Spacer()
            if recentlyAdded.contains(entry.name) {
                Label("Added!", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(Color.stockedGreen)
            } else {
                Button {
                    detailEntry = entry; detailQty = 1
                    detailUnit = defaultUnit(for: entry); detailNote = ""
                    detailHasExpiry = false
                    detailExpiry = Date().addingTimeInterval(7*86400)
                } label: {
                    Image(systemName: "plus.circle.fill").font(.system(size: 22)).foregroundStyle(Color.stockedGold)
                }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .listRowBackground(Color.clear)
    }

    private func itemIcon(for entry: IngredientEntry) -> String {
        // reuse same logic
        switch entry.category {
        case "Meats","Poultry": return "🥩"
        case "Seafood": return "🐟"
        case "Dairy": return "🥛"
        case "Produce": return "🥦"
        case "Bakery": return "🍞"
        case "Beverages": return "🧃"
        case "Snacks": return "🍪"
        case "Condiments": return "🫙"
        case "Freezer": return "🧊"
        default: return entry.emoji
        }
    }

    private func defaultUnit(for entry: IngredientEntry) -> String {
        switch entry.category {
        case "Meats","Poultry","Seafood": return "lb"
        case "Produce": return "g"
        case "Beverages": return "bottle"
        case "Dairy": return "carton"
        case "Bakery": return "loaf"
        default: return "item"
        }
    }
}

struct ExpiryDateRow: View {
    @Environment(AppSession.self) var session
    @Binding var hasExpiry:  Bool
    @Binding var expiryDate: Date
    @State private var mode: ExpiryMode = .useBy

    enum ExpiryMode: String, CaseIterable {
        case useBy     = "Use By"
        case expiresOn = "Expires On"
    }

    var body: some View {
        VStack(spacing: 10) {
            // Toggle row
            HStack(spacing: 0) {
                ForEach(ExpiryMode.allCases, id: \.self) { m in
                    Button {
                        withAnimation(.spring(response: 0.25)) {
                            mode = m
                            if !hasExpiry { hasExpiry = false }
                        }
                    } label: {
                        Text(m.rawValue)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(mode == m ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.5))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(mode == m ? Color.stockedGold : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    }.buttonStyle(.plain)
                }
            }
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))

            // Date picker row
            HStack(spacing: 12) {
                Image(systemName: "calendar")
                    .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge)
                    .foregroundStyle(Color.stockedGold)
                    .frame(width: 22)
                Text(mode.rawValue)
                    .font(.system(size: 14))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
                if hasExpiry {
                    Button {
                        withAnimation(.spring(response: 0.25)) { hasExpiry = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge)
                            .foregroundStyle(session.themeTextColor.opacity(0.25))
                    }.buttonStyle(.plain)
                } else {
                    Text("Optional")
                        .font(.system(size: 11))
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }
                DatePicker("", selection: $expiryDate, in: Date()..., displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .tint(Color.stockedGold)
                    .labelsHidden()
                    .onChange(of: expiryDate) { _, _ in hasExpiry = true }
            }
        }
    }
}

// MARK: - Item Detail Popup (shown when tapping + on any ingredient)
struct ItemDetailPopup: View {
    @Environment(AppSession.self) var session
    let entry:       IngredientEntry
    @Binding var qty:          Int
    @Binding var unit:         String      // containerType
    @Binding var note:         String
    @Binding var hasExpiry:    Bool
    @Binding var expiry:       Date
    let onAdd: (Int, String, String, Bool, Date) -> Void
    @Environment(\.dismiss) var dismiss

    // Size details
    @State private var sizeAmountInput: String = ""
    @State private var sizeUnit: String = "oz"
    @State private var showSizeDetails = false

    var previewText: String {
        let amt = Double(sizeAmountInput)
        if showSizeDetails, let a = amt, !sizeAmountInput.isEmpty {
            return "\(qty) \(unit) (\(a.clean) \(sizeUnit) each) of \(entry.name)"
        }
        return "\(qty) \(unit) of \(entry.name)"
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                // Handle
                Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4).padding(.top, 12)

                // Header
                HStack {
                    Text(entry.emoji).font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.name)
                            .font(.system(size: 20, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text(entry.category)
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(session.themeTextColor.opacity(0.2))
                    }.buttonStyle(.plain)
                }
                .padding(.horizontal, 24).padding(.top, 16).padding(.bottom, 20)

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 20) {

                        // ── QUANTITY ──────────────────────────────────────────
                        quantitySection

                        Divider().padding(.horizontal, 24)

                        // ── SIZE DETAILS (optional) ───────────────────────────
                        sizeDetailsSection

                        // ── LIVE PREVIEW ──────────────────────────────────────
                        HStack {
                            Image(systemName: "eye")
                                .font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                            Text(previewText)
                                .font(.system(size: 13, design: .serif))
                                .foregroundStyle(session.themeTextColor.opacity(0.6))
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .animation(.easeInOut(duration: 0.15), value: previewText)

                        Divider().padding(.horizontal, 24)

                        // ── EXPIRY ────────────────────────────────────────────
                        VStack(alignment: .leading, spacing: 8) {
                            Text("EXPIRY DATE")
                                .font(.system(size: 10, weight: .bold)).tracking(1)
                                .foregroundStyle(session.themeTextColor.opacity(0.4))
                            ExpiryDateRow(hasExpiry: $hasExpiry, expiryDate: $expiry)
                        }.padding(.horizontal, 24)

                        // ── ADD BUTTON ────────────────────────────────────────
                        Button {
                            onAdd(qty, unit, note, hasExpiry, expiry)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "plus.circle.fill")
                                Text(previewText)
                                    .lineLimit(1)
                            }
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                        }
                        .padding(.horizontal, 24).padding(.bottom, 32)
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
        .dismissKeyboardOnTap()
        .keyboardDoneToolbar()
    }

    @ViewBuilder private var quantitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("QUANTITY")
                .font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(session.themeTextColor.opacity(0.4))

            HStack(spacing: 14) {
                // Stepper
                HStack(spacing: 0) {
                    Button {
                        withAnimation(.spring(response: 0.2)) { qty = max(1, qty - 1) }
                    } label: {
                        Image(systemName: "minus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)

                    Text("\(qty)")
                        .font(.system(size: 22, weight: .bold, design: .serif)).dynamicTypeSize(.xSmall ... .accessibility2)
                        .foregroundStyle(Color.stockedGold).frame(minWidth: 40)

                    Button {
                        withAnimation(.spring(response: 0.2)) { qty += 1 }
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))

                // Container Type
                Menu {
                    ForEach(ContainerType.all, id: \.self) { c in
                        Button(c) { unit = c }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(unit)
                            .font(.system(size: 15, weight: .semibold)).dynamicTypeSize(.xSmall ... .xxxLarge)
                            .foregroundStyle(session.themeTextColor)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 11))
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                }
                Spacer()
            }
        }
        .padding(.horizontal, 24)
    }

    @ViewBuilder private var sizeDetailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.spring(response: StockedUI.animationMd)) { showSizeDetails.toggle() }
            } label: {
                HStack {
                    Text("SIZE DETAILS")
                        .font(.system(size: 10, weight: .bold)).tracking(1)
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                    Text("optional")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.stockedGold)
                    Spacer()
                    Image(systemName: showSizeDetails ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11))
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }
            }.buttonStyle(.plain)

            if showSizeDetails {
                HStack(spacing: 12) {
                    // Amount per container
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Amount per \(unit)")
                            .font(.system(size: 11))
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                        TextField("e.g. 24", text: $sizeAmountInput)
                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                            .font(.system(size: 15, weight: .semibold)).dynamicTypeSize(.xSmall ... .xxxLarge)
                            .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                            .keyboardType(.decimalPad)
                            .padding(10)
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    }

                    // Measurement unit
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Unit")
                            .font(.system(size: 11))
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                        Menu {
                            ForEach(MeasurementUnit.all, id: \.self) { u in
                                Button(u) { sizeUnit = u }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Text(sizeUnit)
                                    .font(.system(size: 15, weight: .semibold)).dynamicTypeSize(.xSmall ... .xxxLarge)
                                    .foregroundStyle(session.themeTextColor)
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 10))
                                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                            }
                            .padding(10)
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                        }
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Photo Picker wrapper (PHPicker)
struct ItemPhotoPicker: UIViewControllerRepresentable {
    @Binding var imageData: Data?
    @Environment(\.dismiss) var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ItemPhotoPicker
        init(_ parent: ItemPhotoPicker) { self.parent = parent }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()
            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }
            provider.loadObject(ofClass: UIImage.self) { image, _ in
                Task { @MainActor in
                    if let ui = image as? UIImage {
                        // Compress to max 300KB for storage efficiency
                        self.parent.imageData = ui.jpegData(compressionQuality: 0.5)
                    }
                }
            }
        }
    }
}

// MARK: - Ingredient Pairings Sheet
struct IngredientPairingsSheet: View {
    @Environment(AppSession.self) var session
    let itemName: String

    // Populated on appear from the prebuilt cooccurrence DB (RecipeStore), with the
    // curated fallback applied inside IngredientCooccurrence. Held in state so the
    // async warm-up can refresh the list once data-derived pairings load.
    @State private var pairList: [(name: String, inStock: Bool)] = []

    private func loadPairings() async {
        // Pull data-derived pairings from SQLite into the session cache first…
        await IngredientCooccurrence.shared.warm(for: itemName)
        // …then read the now-warmed (or curated-fallback) list synchronously.
        let pairs = IngredientCooccurrence.shared.pairings(for: itemName, limit: 10)
        let pantry = Set(session.guestStore.inventoryItems.map { $0.name.lowercased() })
        pairList = pairs.map { (name: $0, inStock: pantry.contains($0.lowercased())) }
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 16)
                Text("Pairs well with \(itemName)")
                    .font(.system(size: 18, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.bottom, 20)

                if pairList.isEmpty {
                    Text("No pairing data for this item yet.")
                        .font(.system(size: 14))
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                        .padding(.top, 40)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(pairList.sorted { $0.inStock && !$1.inStock }, id: \.name) { pair in
                                HStack(spacing: 14) {
                                    Image(systemName: pair.inStock ? "checkmark.circle.fill" : "circle.dashed")
                                        .font(.system(size: 20))
                                        .foregroundStyle(pair.inStock ? Color.stockedGold : session.themeTextColor.opacity(0.3))
                                    Text(pair.name)
                                        .font(.system(size: 15, design: .serif))
                                        .foregroundStyle(session.themeTextColor)
                                    Spacer()
                                    if pair.inStock {
                                        Text("In stock")
                                            .font(.system(size: 11, weight: .semibold))
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                }
                                .padding(14)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 40)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await loadPairings() }
    }
}

#Preview { InventoryView().environment(AppSession()) }
