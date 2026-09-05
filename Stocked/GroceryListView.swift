// GroceryListView.swift — Recipe-grouped grocery list with expandable sections
import SwiftUI
import Combine

// MARK: - Grouped grocery section model
private struct GrocerySection: Identifiable {
    let id    = UUID()
    let title: String          // Recipe name or "My List" / "Running Low"
    let icon:  String
    var items: [LocalGroceryItem]
    var isExpanded: Bool = true
}

// MARK: - Undo toast (UX #1)
struct StockedUndoToast: View {
    let message: String; let onUndo: () -> Void; @Binding var isShowing: Bool
    // MARK: body split into: emptyState, groupedList, ungroupedList (item #15)
    var body: some View {
        HStack(spacing: 12) {
            Text(message).stocked(.callout).foregroundStyle(Color.stockedWhite)
            Spacer()
            Button("Undo") { onUndo(); withAnimation { isShowing = false } }
                .scaledFont(13, weight: .bold).foregroundStyle(Color.stockedGold)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4).padding(.horizontal, 24)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .task {
                try? await Task.sleep(nanoseconds: UInt64(StockedUI.undoToastDuration * 1_000_000_000))
                withAnimation { isShowing = false }
        }
    }
}

// Single enum drives one .sheet(item:) — avoids the SwiftUI stacked-.sheet bug
// (multiple .sheet(isPresented:) on one view → only one fires reliably).
enum GrocerySheet: Identifiable {
    case storePicker
    case share
    case scanList
    case cookLater(CookLaterContext)
    // RL-007 — flagged-duplicate review before checked items move into the pantry.
    case purchaseReview(PurchaseDupReviewContext)
    var id: String {
        switch self {
        case .storePicker: return "store-picker"
        case .share: return "share"
        case .scanList: return "scan-list"
        case .cookLater(let context): return "cook-later-\(context.id.uuidString)"
        case .purchaseReview(let context): return "purchase-review-\(context.id.uuidString)"
        }
    }
}

struct GroceryListView: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion
    @Environment(\.stockedLayout) private var layoutMetrics
    @State private var newItem      = ""
    @State private var searchText   = ""
    // One accordion may be open at a time. Starting nil keeps the grocery list compact
    // and opening another group automatically closes the previous one.
    @State private var expandedSection: String? = nil
    @State private var undoItem:    LocalGroceryItem? = nil
    @State private var showUndo     = false
    @State private var batchMode    = false
    @State private var selectedIDs  = Set<UUID>()
    // #2 perf: cache the grouped sections so the 4+ filter passes only run when the
    // underlying items or search text change — not on every view render.
    @State private var cachedSections: [GrocerySection] = []
    @State private var loopMessage           = ""   // close-the-loop action feedback
    @State private var isSortedForShopping  = false
    @State private var pendingDeleteTitle    : String? = nil   // whole-group delete confirm
    @State private var showBought = false   // #235 — To Buy / Bought segment
    // #E2 — household roster for the Assign to… menu (fetched once per appearance).
    @State private var householdMemberNames: [String] = []
    // #E2 — "Mine" filter: show only items assigned to me (or unassigned).
    @State private var showMineOnly = false
    @State private var selectedRecipe = "All Recipes"
    @State private var selectedStore = "All Stores"
    @State private var selectedAisle: GroceryAisle? = nil
    // Perf: the burn-rate prediction scans the consumption log; cached alongside the
    // section cache instead of recomputing in the suggestions area every render.
    @State private var cachedPredicted: [String] = []

    /// Names offered in the Assign menu: fetched roster, else just me.
    private var assignableMembers: [String] {
        householdMemberNames.isEmpty ? [session.userName] : householdMemberNames
    }
    @State private var showQuickAdd = false  // #235 — bottom "+ Add Item" button
    @State private var showMoreDialog = false // #245 — header ··· (store/share/scan/move)
    @State private var sortAZ = false          // #245 — "Sort: Category / Name" pill
    @State private var quickAddName = ""
    // RL-010 — optional "group by store" view mode. Off by default so the unified list
    // stays the primary experience; persisted so shoppers who organize by store keep it.
    @AppStorage("groceryGroupByStore_v1") private var groupByStore = false

    // #235 — mockup segmented pill.
    private func segmentButton(_ title: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).scaledFont(13.5, weight: .bold)
                if count > 0 {
                    Text("\(count)").scaledFont(11.5, weight: .bold).opacity(0.7)
                }
            }
            .foregroundStyle(active ? Color.selectedTabForeground(dark) : session.themeSecondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(active ? Color.stockedCharcoal : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func filterPill(icon: String, title: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).scaledFont(11, weight: .semibold)
            Text(title).scaledFont(12, weight: .semibold).fixedSize(horizontal: false, vertical: true)
            if icon != "xmark" {
                Image(systemName: "chevron.down").scaledFont(8, weight: .bold)
            }
        }
        .foregroundStyle(text.opacity(0.78))
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(session.themeCardColor)
        .overlay(Capsule().stroke(text.opacity(0.14), lineWidth: 1))
        .clipShape(Capsule())
    }

    private func sortForShopping() {
        // StoreRouting owns both the learned branch order and the GroceryAisle fallback. Keeping
        // the compatibility sort here avoids a second, screen-local aisle database drifting from
        // GroceryKnowledgeBase when a store has not been taught yet.
        let layout = StoreLayoutStore.shared.layout(for: session.preferredStore)
        let ordered = StoreRouting.sort(store.groceryItems.map(\.name), layout: layout)
        var rank: [String: Int] = [:]
        for (index, name) in ordered.enumerated() where rank[name.lowercased()] == nil {
            rank[name.lowercased()] = index
        }
        motion.animate(.standard, intent: .spatial) {
            store.groceryItems.sort {
                (rank[$0.name.lowercased()] ?? .max, $0.name)
                    < (rank[$1.name.lowercased()] ?? .max, $1.name)
            }
            isSortedForShopping = true
        }
        HapticManager.success()
    }
    @State private var grocerySheet: GrocerySheet? = nil
    @State private var shareText       = ""
    @FocusState private var addFocused: Bool

    private let allStores = ["Walmart","Target","H-E-B","Kroger","Whole Foods","Aldi",
                             "Publix","Safeway","Costco","Trader Joe's","Sprouts",
                             "Meijer","Wegmans","Food Lion","Amazon Fresh"]

    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool   { session.isDarkMode }

    /// True if any Low Stock / Running Out / Usuals suggestions are available to show. Drives
    /// whether the empty list shows the big empty-state or a compact header (so suggestions lead).
    private var hasSuggestions: Bool {
        let low = store.inventoryItems.contains { inv in
            KitchenAvailability.isRunningLow(inv) &&
            !store.groceryItems.contains { $0.name.lowercased() == inv.name.lowercased() }
        }
        if low { return true }
        let runningOut = store.itemsRunningOutSoon(within: KitchenThresholds.expiringSoonDays)
            .contains { $0.effectiveLevel >= KitchenThresholds.lowFillLevel }
        if runningOut { return true }
        return !GroceryUsuals.shared.suggestions(excluding: store.groceryItems.map { $0.name }, limit: 8).isEmpty
    }
    private var text: Color  { session.themeTextColor }
    private var sub:  Color  { session.themeSecondaryText }

    // MARK: - Grouped sections (search-filtered)
    private func filteredItems(_ items: [LocalGroceryItem]) -> [LocalGroceryItem] {
        var result = items
        if selectedStore != "All Stores" {
            result = result.filter { resolvedStore(for: $0) == selectedStore }
        }
        if let selectedAisle {
            result = result.filter { aisle(for: $0.name) == selectedAisle }
        }
        if selectedRecipe != "All Recipes" {
            result = result.filter {
                selectedRecipe == "Manual Items" ? $0.recipeSource.isEmpty
                    : $0.recipeSource.localizedCaseInsensitiveContains(selectedRecipe)
            }
        }
        guard !searchText.isEmpty else { return result }
        return result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var storeFilters: [String] {
        let assigned = Set(store.groceryItems.map { resolvedStore(for: $0) }.filter { !$0.isEmpty })
        return ["All Stores"] + assigned.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
    }

    private func aisle(for name: String) -> GroceryAisle {
        ProductCatalog.bestMatch(for: name)?.resolvedAisle ?? GroceryKnowledgeBase.inferAisle(for: name)
    }

    private var recipeFilters: [String] {
        let names = store.groceryItems.flatMap { item in
            item.recipeSource.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }.filter { !$0.isEmpty }
        var values = ["All Recipes"] + Array(Set(names)).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        if store.groceryItems.contains(where: { $0.recipeSource.isEmpty }) { values.append("Manual Items") }
        return values
    }

    // Reads the cached value (rebuilt via rebuildSections on change). See #2.
    private var sections: [GrocerySection] { cachedSections }

    // #244 — mockup store category for an item name. Frozen wins first so
    // "frozen peas" / "chicken nuggets" land in Frozen, not Produce/Meat.
    private func categoryFor(_ name: String) -> (title: String, icon: String, order: Int) {
        let aisle = aisle(for: name)
        let icon: String
        switch aisle {
        case .produce: icon = "leaf"
        case .bakery: icon = "basket"
        case .deli: icon = "takeoutbag.and.cup.and.straw"
        case .meat: icon = "fork.knife"
        case .dairy: icon = "drop"
        case .frozen: icon = "snowflake"
        case .breakfast: icon = "sunrise"
        case .pantry: icon = "cabinet"
        case .canned: icon = "cylinder"
        case .baking: icon = "birthday.cake"
        case .condiments: icon = "takeoutbag.and.cup.and.straw"
        case .snacks: icon = "popcorn"
        case .beverages: icon = "waterbottle"
        case .household: icon = "house"
        case .baby: icon = "figure.and.child.holdinghands"
        case .pets: icon = "pawprint"
        }
        return (aisle.rawValue, icon, aisle.defaultOrder)
    }

    private func rebuildSections() {
        // Perf: refresh the predicted-restock suggestions with the same cadence as the
        // section cache (list changes, segment flips, search) — not per render.
        cachedPredicted = store.predictedRunningLow(limit: 5).filter { name in
            !GroceryDedup.isDuplicate(name, in: store.groceryItems.map { $0.name })
        }
        // #244 — mockup grouping: store categories, ordered Produce → Pantry.
        // The To Buy / Bought segment (#235) still filters the pool first.
        var pool = store.groceryItems.filter { $0.isChecked == showBought }
        // #E2 — "Mine" keeps items assigned to me or to nobody (unassigned = shared).
        if showMineOnly {
            let me = session.userName
            pool = pool.filter { $0.assignedTo.isEmpty || $0.assignedTo.caseInsensitiveCompare(me) == .orderedSame }
        }
        let visible = filteredItems(pool)
        // RL-010 — housekeeping: drop store assignments for rows no longer on the list.
        MultiStoreAssignments.shared.prune(keeping: Set(store.groceryItems.map(\.id)))
        var grouped: [String: (icon: String, order: Int, items: [LocalGroceryItem])] = [:]
        if groupByStore {
            // RL-010 — per-store sections: explicit assignment → learned store → default.
            // The default store sorts first (it's where most of the trip happens); other
            // stores follow alphabetically.
            for item in visible {
                let name = resolvedStore(for: item)
                grouped[name, default: ("storefront", name == session.preferredStore ? 0 : 1, [])].items.append(item)
            }
        } else {
            for item in visible {
                let cat = categoryFor(item.name)
                grouped[cat.title, default: (cat.icon, cat.order, [])].items.append(item)
            }
        }
        cachedSections = grouped
            .map { (title: $0.key, info: $0.value) }
            // Tie-break alphabetically so store sections (all order 1) render stably.
            .sorted { ($0.info.order, $0.title) < ($1.info.order, $1.title) }
            .map { GrocerySection(title: $0.title, icon: $0.info.icon,
                                  items: sortAZ ? $0.info.items.sorted { $0.name.lowercased() < $1.name.lowercased() }
                                                : $0.info.items) }
    }

    // MARK: - RL-010 store resolution

    /// Which store this row belongs to: explicit assignment → learned history → default.
    private func resolvedStore(for item: LocalGroceryItem) -> String {
        MultiStoreAssignments.shared.resolvedStore(for: item,
                                                   learned: store.itemStoreHistory,
                                                   defaultStore: session.preferredStore)
    }

    /// True when every item earmarked for `storeName` is checked off — the per-store
    /// completion state that makes a multi-store trip legible ("H-E-B done, Costco next").
    private func storeSegmentComplete(_ storeName: String) -> Bool {
        !store.groceryItems.contains { !$0.isChecked && resolvedStore(for: $0) == storeName }
    }

    // MARK: - RL-007 dedupe-aware "move purchased → pantry"

    /// Entry point for both the whole-list "Move Checked → Pantry" action and the
    /// per-store segment buttons. Runs the dedupe engine first: a clean bill transfers
    /// immediately (the checked list is its own review); flagged items get the
    /// Merge / Keep Both / Skip sheet before anything lands.
    private func beginPantryTransfer(_ items: [LocalGroceryItem]) {
        guard !items.isEmpty else { return }
        let candidates = items.map { g in
            PurchaseImportCandidate(id: g.id, name: g.name, quantity: max(1, g.quantity),
                                    store: resolvedStore(for: g), source: .shoppingTrip)
        }
        let flags = PurchaseDedupEngine.evaluate(candidates: candidates,
                                                 history: PurchaseImportLog.shared.records)
        if flags.isEmpty {
            commitPantryTransfer(candidates: candidates, resolutions: [:])
        } else {
            grocerySheet = .purchaseReview(PurchaseDupReviewContext(
                title: "Move to Pantry", candidates: candidates, flags: flags))
        }
    }

    /// The actual transfer, after RL-007 review (or directly when nothing was flagged).
    /// Mirrors GuestDataStore.moveCheckedGroceryToInventory but is duplicate-aware and
    /// stamps each line with the trip id + store segment (RL-010): finishing H-E-B now
    /// and Costco in an hour logs two segments of ONE trip, so a later receipt scan of
    /// either store is recognized as the same shopping.
    private func commitPantryTransfer(candidates: [PurchaseImportCandidate],
                                      resolutions: [UUID: PurchaseDupResolution]) {
        let tripID = PurchaseImportLog.shared.currentTripID()
        let who = UserDefaults.standard.string(forKey: "householdMemberName_v1") ?? ""
        var moved = 0
        var importRecords: [PurchaseImportRecord] = []
        var additions: [ProposedChange] = []

        for cand in candidates {
            guard let g = store.groceryItems.first(where: { $0.id == cand.id }) else { continue }
            switch resolutions[cand.id] ?? .keepBoth {
            case .skip:
                break   // duplicate — never enters inventory
            case .merge:
                PurchaseImportMerge.refreshExisting(in: store, name: g.name,
                                                    storeName: cand.store.isEmpty ? nil : cand.store,
                                                    origin: .groceryTransfer)
            case .keepBoth:
                var inv = LocalInventoryItem(name: g.name, level: 1.0, zone: "Pantry",
                                             quantity: max(1, g.quantity))
                inv.purchaseDate     = Date()
                inv.addedBy          = who
                inv.storePurchasedAt = cand.store.isEmpty ? nil : cand.store
                additions.append(InventoryProposalBatch.reviewableAdd(
                    item: inv,
                    origin: .groceryTransfer,
                    sourceID: "grocery-transfer",
                    reason: "Moved from the grocery list"
                ))
                moved += 1
                importRecords.append(PurchaseImportRecord(
                    normalizedName: PurchaseDedupEngine.normalizedName(g.name),
                    displayName: g.name, quantity: max(1, g.quantity),
                    store: cand.store, source: .shoppingTrip,
                    transactionKey: tripID, importedAt: Date()))
            }
        }
        if !additions.isEmpty {
            store.applyProposalBatch(
                InventoryProposalBatch(
                    origin: .groceryTransfer,
                    title: "Move groceries to pantry",
                    changes: additions,
                    mergePolicy: .storeCompatible
                ),
                brandPreferences: store.cookingProfile.brandPreferences,
                retailerID: GroceryKnowledgeBase.retailer(matching: session.preferredStore)?.id
            )
        }
        // Every handled row leaves the list — skipped/merged lines were already bought
        // and accounted for; keeping them would just re-flag next time.
        let handled = Set(candidates.map(\.id))
        withAnimation { store.groceryItems.removeAll { handled.contains($0.id) } }
        PurchaseImportLog.shared.record(importRecords)

        let segments = PurchaseImportLog.shared.storeSegments(forTrip: tripID)
        let segmentNote = segments.count > 1 ? " (\(segments.joined(separator: " + ")))" : ""
        loopMessage = moved == 0
            ? "Nothing new to move — duplicates skipped"
            : "Moved \(moved) item\(moved == 1 ? "" : "s") into your pantry\(segmentNote)"
        HapticManager.success()
    }

    var body: some View { editorialPresentation }

    private var editorialPresentation: some View {
        StockedShell {
            VStack(alignment: .leading, spacing: 24) {
                groceryHero
                shoppingTripCard
                    .coachmarkAnchor("grocery.segments")
                forThisWeekSection
                editorialListSection
                if let suggestion = editorialSuggestion {
                    editorialSuggestionCard(name: suggestion.name, reason: suggestion.reason)
                }
            }
            .stockedSnapTargetLayout()
            .frame(maxWidth: layoutMetrics.readableContentWidth)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, layoutMetrics.horizontalPadding)
            .padding(.bottom, 110)
        }
        .sheet(item: $grocerySheet) { sheet in
            switch sheet {
            case .storePicker: quickStorePickerSheet
            case .share: ShareSheet(items: [shareText])
            case .scanList:
                HandwrittenListScanner { lines in
                    var count = 0
                    for line in lines {
                        let name = line.trimmingCharacters(in: .whitespaces)
                        guard name.count >= 2,
                              !store.groceryItems.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
                        else { continue }
                        store.groceryItems.append(LocalGroceryItem(name: name, isChecked: false))
                        count += 1
                    }
                    loopMessage = "Added \(count) item\(count == 1 ? "" : "s") from your list"
                    grocerySheet = nil
                }
                .environment(session)
            case .cookLater(let context):
                NavigationStack { CookLaterWorkspaceView(context: context).environment(session) }
            case .purchaseReview(let context):
                PurchaseDedupReviewView(
                    context: context,
                    onCommit: { resolutions in
                        grocerySheet = nil
                        commitPantryTransfer(candidates: context.candidates, resolutions: resolutions)
                    },
                    onCancel: { grocerySheet = nil }
                )
                .environment(session)
            }
        }
        .onAppear { rebuildSections() }
        .task {
            let sync = HouseholdSync.shared
            if sync.state == .owner || sync.state == .member {
                householdMemberNames = await sync.fetchMembers().map(\.name).filter { !$0.isEmpty }
            }
        }
        .onChange(of: store.groceryRevision) { _, _ in rebuildSections() }
        .onChange(of: searchText) { _, _ in rebuildSections() }
        .onChange(of: showBought) { _, _ in rebuildSections() }
        .onChange(of: showMineOnly) { _, _ in rebuildSections() }
        .onChange(of: sortAZ) { _, _ in rebuildSections() }
        .onChange(of: groupByStore) { _, _ in rebuildSections() }
        .onChange(of: selectedStore) { _, _ in rebuildSections() }
        .onChange(of: selectedAisle) { _, _ in rebuildSections() }
        .confirmationDialog("Organize Grocery", isPresented: $showMoreDialog, titleVisibility: .visible) {
            Button("Add Item") { showQuickAdd = true }
            Button(showBought ? "Show To Buy" : "Show Bought") { showBought.toggle() }
            if store.groceryItems.contains(where: { !$0.assignedTo.isEmpty }) {
                Button(showMineOnly ? "Show Everyone’s Items" : "Show My Items") { showMineOnly.toggle() }
            }
            Button(sortAZ ? "Sort by Aisle" : "Sort by Name") { sortAZ.toggle() }
            Button(groupByStore ? "Group by Aisle" : "Group by Store") { groupByStore.toggle() }
            Button("Shopping at \(session.preferredStore) — Change Store") { grocerySheet = .storePicker }
            Button("Share List") { prepareShare() }
            Button("Scan a List") { grocerySheet = .scanList }
            if store.groceryItems.contains(where: { $0.isChecked }) {
                Button("Move Bought Items to Inventory") {
                    beginPantryTransfer(store.groceryItems.filter(\.isChecked))
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Add Item", isPresented: $showQuickAdd) {
            TextField("Item name", text: $quickAddName)
            Button("Add") {
                let name = quickAddName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    store.addGroceryItem(name: name)
                    HapticManager.success()
                }
                quickAddName = ""
            }
            Button("Cancel", role: .cancel) { quickAddName = "" }
        } message: {
            Text("Add something to your grocery list.")
        }
        .coachmarks(page: .grocery, steps: GroceryCoachmarks.steps)
    }

    private var groceryHero: some View {
        HStack(alignment: .center, spacing: 4) {
            VStack(alignment: .leading, spacing: 12) {
                Text("\(toBuyCount) things for\nyour next trip.")
                    .font(.stockedSerif(36, weight: .bold, relativeTo: .largeTitle))
                    .foregroundStyle(text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Organized for a quicker shop at \(session.preferredStore).")
                    .font(.stocked(.body))
                    .foregroundStyle(sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)
            Spacer(minLength: 0)
            Image("home_grocery_bag")
                .resizable()
                .scaledToFit()
                .frame(width: layoutMetrics.contentWidth >= 700 ? 260 : 165,
                       height: layoutMetrics.contentWidth >= 700 ? 260 : 210,
                       alignment: .bottomTrailing)
                .accessibilityHidden(true)
        }
    }

    private var toBuyCount: Int { store.groceryItems.filter { !$0.isChecked }.count }
    private var boughtCount: Int { store.groceryItems.count - toBuyCount }
    private var estimatedTripMinutes: Int { max(8, min(60, toBuyCount * 2)) }

    private var shoppingTripCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) { shoppingTripIdentity; Spacer(); shoppingTripFacts }
                VStack(alignment: .leading, spacing: 10) { shoppingTripIdentity; shoppingTripFacts }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("\(boughtCount) of \(store.groceryItems.count) in cart")
                    .font(.stocked(.subheadline))
                    .foregroundStyle(text)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(session.themeTextColor.opacity(0.10))
                        Capsule().fill(Color.stockedGreen)
                            .frame(width: proxy.size.width * shoppingProgress)
                    }
                }
                .frame(height: 7)
            }
            Button {
                showBought = false
                selectedStore = "All Stores"
                groupByStore = false
                sortForShopping()
                expandedSection = sections.first?.title
                loopMessage = "Your list is arranged in shopping order"
            } label: {
                Text("Start Shopping")
                    .font(.stockedSerif(17, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(Color.selectedTabForeground(dark))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.stockedCharcoal,
                                in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(session.themeCardColor,
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(text.opacity(0.07), lineWidth: 1)
        }
    }

    private var shoppingTripIdentity: some View {
        Text(session.preferredStore)
            .font(.stockedSerif(24, weight: .bold, relativeTo: .title2))
            .foregroundStyle(Color.stockedGreen)
    }

    private var shoppingTripFacts: some View {
        HStack(spacing: 18) {
            Label("\(toBuyCount) items", systemImage: "bag")
            Label("About \(estimatedTripMinutes) min", systemImage: "clock")
        }
        .font(.stocked(.subheadline))
        .foregroundStyle(text)
    }

    private var shoppingProgress: CGFloat {
        guard !store.groceryItems.isEmpty else { return 0 }
        return CGFloat(boughtCount) / CGFloat(store.groceryItems.count)
    }

    private var forThisWeekSection: some View {
        let meals = Array(store.plannedMeals.filter { !$0.isCooked }.prefix(6))
        return VStack(alignment: .leading, spacing: 12) {
            editorialSectionTitle("For This Week")
            if meals.isEmpty {
                HStack(spacing: 12) {
                    StockedKitchenArtwork(asset: "home_widget_planning").frame(width: 92, height: 72)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Plan a meal")
                            .font(.stockedSerif(17, weight: .bold, relativeTo: .headline))
                        Text("Recipe ingredients will stay grouped here.")
                            .font(.stocked(.subheadline)).foregroundStyle(sub)
                    }
                }
                .padding(14)
                .background(session.themeCardColor,
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 12) {
                        ForEach(meals) { meal in
                            Button {
                                grocerySheet = .cookLater(.grocery(name: meal.title, recipeSource: meal.title))
                            } label: {
                                HStack(spacing: 10) {
                                    StockedKitchenArtwork(asset: "home_widget_planning")
                                        .frame(width: 104, height: 92)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(meal.title)
                                            .font(.stockedSerif(17, weight: .bold, relativeTo: .headline))
                                            .foregroundStyle(text).fixedSize(horizontal: false, vertical: true)
                                        Text("· \(meal.ingredients.count) items")
                                            .font(.stocked(.caption).weight(.semibold))
                                            .foregroundStyle(Color.stockedGreen)
                                    }
                                }
                                .padding(12)
                                .frame(width: 286, alignment: .leading)
                                .background(session.themeCardColor,
                                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .stockedScrollTargetLayout()
                }
                .stockedHorizontalSnap()
            }
        }
    }

    private var editorialListSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                editorialSectionTitle(showBought ? "Bought" : "Your List")
                Spacer()
                Button("Organize") { showMoreDialog = true }
                    .font(.stocked(.subheadline).weight(.semibold))
                    .foregroundStyle(session.accentColor)
            }
            if !loopMessage.isEmpty {
                Text(loopMessage).font(.stocked(.caption)).foregroundStyle(session.accentColor)
            }
            if sections.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: showBought ? "checkmark.circle" : "cart.badge.plus")
                        .font(.stocked(.largeTitle))
                        .foregroundStyle(session.accentColor)
                    Text(showBought ? "Nothing in the cart yet" : "Your list is clear")
                        .font(.stockedSerif(19, weight: .bold, relativeTo: .headline))
                    Button("Add Item") { showQuickAdd = true }
                        .font(.stocked(.subheadline).weight(.semibold))
                        .foregroundStyle(session.accentColor)
                }
                .frame(maxWidth: .infinity)
                .padding(28)
                .background(session.themeCardColor,
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(sections) { sectionCard($0) }
                }
            }
        }
    }

    private func editorialSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.stockedSerif(26, weight: .bold, relativeTo: .title2))
            .foregroundStyle(text)
    }

    private var editorialSuggestion: (name: String, reason: String)? {
        if let item = store.inventoryItems.first(where: { inventoryItem in
            KitchenAvailability.isRunningLow(inventoryItem) &&
            !GroceryDedup.isDuplicate(inventoryItem.name, in: store.groceryItems.map(\.name))
        }) {
            return (item.name.displayNormalized, "\(item.name.displayNormalized) is running low")
        }
        if let name = cachedPredicted.first { return (name.displayNormalized, "Likely to run out soon") }
        if let name = GroceryUsuals.shared.suggestions(excluding: store.groceryItems.map(\.name), limit: 1).first {
            return (name.displayNormalized, "One of your usuals")
        }
        return nil
    }

    private func editorialSuggestionCard(name: String, reason: String) -> some View {
        HStack(spacing: 14) {
            FoodIconView(name: name, size: 72, emojiSize: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text("Suggested for your list")
                    .font(.stocked(.caption).weight(.semibold))
                    .foregroundStyle(session.accentColor)
                Text(reason)
                    .font(.stockedSerif(17, weight: .bold, relativeTo: .headline))
                    .foregroundStyle(text)
            }
            Spacer(minLength: 8)
            Button("Add") {
                store.addToGroceryIfMissing(name, recommended: true)
                HapticManager.success()
            }
            .font(.stockedSerif(16, weight: .bold, relativeTo: .headline))
            .foregroundStyle(session.accentColor)
        }
        .padding(16)
        .background(session.themeCardColor,
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(text.opacity(0.07), lineWidth: 1)
        }
    }

    private func prepareShare() {
        let items = store.groceryItems.filter { !$0.isChecked }
        let lines = items.map { "• \($0.name)\($0.recipeSource.isEmpty ? "" : " (\($0.recipeSource))")" }
        shareText = lines.isEmpty ? "No items on the list." : "My Grocery List:\n\n" + lines.joined(separator: "\n")
        grocerySheet = .share
    }

    private var legacyPresentation: some View {
        StockedShell(scrollDisabled: true,
                     titleText: "Grocery List",
                     trailingIcon: "ellipsis", trailingLabel: "More",
                     onTrailing: { showMoreDialog = true }) {
            VStack(alignment: .leading, spacing: 0) {
                // Undo toast
                if showUndo, let item = undoItem {
                    StockedUndoToast(message: "Item removed", onUndo: {
                        withAnimation { store.groceryItems.insert(item, at: 0) }
                        HapticManager.success()
                    }, isShowing: $showUndo).padding(.horizontal, 4).padding(.bottom, 8)
                }


                // ── To Buy / Bought (#235 mockup) ───────────────────────
                HStack(spacing: 0) {
                    segmentButton("To Buy", count: store.groceryItems.filter { !$0.isChecked }.count, active: !showBought) {
                        withAnimation(.easeInOut(duration: 0.18)) { showBought = false }
                    }
                    segmentButton("Bought", count: store.groceryItems.filter { $0.isChecked }.count, active: showBought) {
                        withAnimation(.easeInOut(duration: 0.18)) { showBought = true }
                    }
                    // #E2 — only meaningful in a household with assignments in play.
                    if store.groceryItems.contains(where: { !$0.assignedTo.isEmpty }) {
                        segmentButton("Mine", count: store.groceryItems.filter {
                            !$0.isChecked && ($0.assignedTo.isEmpty || $0.assignedTo.caseInsensitiveCompare(session.userName) == .orderedSame)
                        }.count, active: showMineOnly) {
                            withAnimation(.easeInOut(duration: 0.18)) { showMineOnly.toggle(); rebuildSections() }
                        }
                    }
                }
                .padding(4)
                .background(session.themeCardColor)
                .clipShape(Capsule())
                .padding(.horizontal, 24).padding(.bottom, 12)
                .coachmarkAnchor("grocery.segments")

                if recipeFilters.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(recipeFilters, id: \.self) { recipe in
                                Button {
                                    selectedRecipe = recipe
                                    rebuildSections()
                                } label: {
                                    Text(recipe).scaledFont(12, weight: .semibold).fixedSize(horizontal: false, vertical: true)
                                        .foregroundStyle(selectedRecipe == recipe ? Color.stockedWhite : text.opacity(0.7))
                                        .padding(.horizontal, 12).padding(.vertical, 8)
                                        .background(selectedRecipe == recipe ? Color.stockedCharcoal : Color.clear)
                                        .clipShape(Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                        .stockedScrollTargetLayout()
                        .padding(.horizontal, 24)
                    }
                    .stockedHorizontalSnap()
                    .padding(.bottom, 10)
                    .accessibilityLabel("Filter grocery list by recipe")
                }

                // Store and department filters compose with recipe, household, search,
                // and To Buy/Bought filters. Only stores that own at least one current
                // row are offered, so this stays useful instead of becoming a directory.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Menu {
                            ForEach(storeFilters, id: \.self) { storeName in
                                Button {
                                    selectedStore = storeName
                                    rebuildSections()
                                } label: {
                                    Label(storeName, systemImage: selectedStore == storeName ? "checkmark" : "storefront")
                                }
                            }
                        } label: {
                            filterPill(icon: "storefront", title: selectedStore)
                        }

                        Menu {
                            Button {
                                selectedAisle = nil
                                rebuildSections()
                            } label: {
                                Label("All Aisles", systemImage: selectedAisle == nil ? "checkmark" : "square.grid.2x2")
                            }
                            ForEach(GroceryAisle.allCases, id: \.self) { aisle in
                                Button {
                                    selectedAisle = aisle
                                    rebuildSections()
                                } label: {
                                    Label(aisle.rawValue, systemImage: selectedAisle == aisle ? "checkmark" : "square.grid.2x2")
                                }
                            }
                        } label: {
                            filterPill(icon: "square.grid.2x2", title: selectedAisle?.rawValue ?? "All Aisles")
                        }

                        if selectedStore != "All Stores" || selectedAisle != nil {
                            Button {
                                selectedStore = "All Stores"
                                selectedAisle = nil
                                rebuildSections()
                            } label: {
                                filterPill(icon: "xmark", title: "Clear")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear store and aisle filters")
                        }
                    }
                    .stockedScrollTargetLayout()
                    .padding(.horizontal, 24)
                }
                .stockedHorizontalSnap()
                .padding(.bottom, 10)
                .accessibilityLabel("Filter grocery list by store or aisle")

                // ── #245 — stacked title + Sort pill (mockup) ───────────
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(showBought ? "Bought" : "To Buy")
                            .scaledFont(24, weight: .bold, design: .serif)
                            .foregroundStyle(text)
                        let n = store.groceryItems.filter { $0.isChecked == showBought }.count
                        Text("\(n) item\(n == 1 ? "" : "s")")
                            .scaledFont(13).foregroundStyle(sub)
                    }
                    Spacer()
                    Menu {
                        Button { sortAZ = false } label: {
                            Label("Category", systemImage: sortAZ ? "circle" : "checkmark")
                        }
                        Button { sortAZ = true } label: {
                            Label("Name (A–Z)", systemImage: sortAZ ? "checkmark" : "circle")
                        }
                        Divider()
                        // RL-010 — optional store-organized view; unified list stays default.
                        Button { groupByStore.toggle() } label: {
                            Label("Group by Store", systemImage: groupByStore ? "checkmark" : "storefront")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(groupByStore ? "By Store" : "Sort: \(sortAZ ? "Name" : "Category")")
                                .scaledFont(12, weight: .semibold)
                            Image(systemName: "chevron.down")
                                .scaledFont(12, weight: .semibold)
                        }
                        .foregroundStyle(text.opacity(0.75))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(session.themeCardColor)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 10)


                if !loopMessage.isEmpty {
                    Text(loopMessage)
                        .scaledFont(11)
                        .foregroundStyle(Color.stockedGold)
                        .padding(.horizontal, 24).padding(.bottom, 8)
                        .transition(.opacity)
                }

                // ── SCROLLABLE LIST ──────────────────────────────────
                ScrollView(showsIndicators: false) {
                Color.clear.frame(height: 1) // anchor for refreshable
                    VStack(alignment: .leading, spacing: 0) {

                        // Recipe sections
                        if sections.isEmpty && store.groceryItems.isEmpty && !hasSuggestions {
                            // Truly nothing — full empty state.
                            StockedEmptyState(
                                icon: "🛒",
                                title: "List is empty",
                                subtitle: "Add items above, or plan a meal — ingredients will show up here automatically."
                            ).padding(.top, 24)
                        } else if sections.isEmpty && store.groceryItems.isEmpty && hasSuggestions {
                            // Empty list but we have suggestions — compact header so the
                            // suggestions below become the focus instead of a big "empty" block.
                            HStack(spacing: 12) {
                                Image(systemName: "cart.badge.plus")
                                    .scaledFont(22)
                                    .foregroundStyle(Color.stockedGold)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Your list is clear")
                                        .scaledFont(15, weight: .semibold, design: .serif)
                                        .foregroundStyle(session.themeTextColor)
                                    Text("Add an item below, or tap a suggestion to restock.")
                                        .scaledFont(12)
                                        .foregroundStyle(session.themeSecondaryText)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                            }
                            .padding(14)
                            .background(session.themeCardColor)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            .padding(.horizontal, 20)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                        } else if sections.isEmpty && !searchText.isEmpty {
                            VStack(spacing: 10) {
                                Text("🔍").scaledFont(36)
                                Text("No results for \"\(searchText)\"")
                                    .scaledFont(14).foregroundStyle(sub)
                                Button("Add \"\(searchText)\" to list") { addItem() }
                                    .scaledFont(14, weight: .semibold)
                                    .foregroundStyle(Color.stockedGold)
                            }
                            .frame(maxWidth: .infinity).padding(.top, 40)
                        } else {
                            ForEach(sections) { section in
                                sectionCard(section)
                                    .padding(.horizontal, 20)
                                    .padding(.bottom, 12)
                                    .springIn(delay: Double(sections.firstIndex(where: { $0.id == section.id }) ?? 0) * 0.06)
                            }
                        }

                        // Low stock suggestions (not yet added)
                        let lowNotInList = store.inventoryItems.filter { inv in
                            KitchenAvailability.isRunningLow(inv) &&
                            !store.groceryItems.contains { $0.name.lowercased() == inv.name.lowercased() }
                        }
                        if !lowNotInList.isEmpty {
                            sectionLabel("🔴 Low Stock — Tap to Add")
                            ForEach(lowNotInList) { inv in
                                Button {
                                    withAnimation {
                                        store.addToGroceryIfMissing(inv.name, recommended: true)
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "exclamationmark.circle")
                                            .scaledFont(16)
                                            .foregroundStyle(inv.effectiveLevel == 0 ? Color.red : text)
                                            .frame(width: 28)
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(inv.name).scaledFont(14).foregroundStyle(text)
                                            Text("\(inv.zone) · \(Int(inv.effectiveLevel * 100))% left")
                                                .scaledFont(11)
                                                .foregroundStyle(inv.effectiveLevel == 0 ? Color.red : text)
                                            // #7 — where it's been cheapest lately
                                            if let deal = store.bestPrice(for: inv.name) {
                                                Text("Cheapest at \(deal.store) · $\(String(format: "%.2f", deal.price))")
                                                    .scaledFont(11)
                                                    .foregroundStyle(Color.stockedGreen)
                                            }
                                        }
                                        Spacer()
                                        Text("Add").scaledFont(13, weight: .semibold)
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(session.themeCardColor)
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 8)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                .swipeToDelete(confirmTitle: "Remove \(inv.name) from your kitchen?") {
                                    let removed = inv
                                    store.removeInventoryItem(id: inv.id)
                                    ToastCenter.shared.undo("Deleted \(inv.name.displayNormalized)") {
                                        store.restoreInventoryItems([removed])
                                    }
                                }
                            }
                        }

                        // #5 — velocity reorder: not low YET, but the learned usage rate says
                        // they'll run out within days. itemsRunningOutSoon already excludes
                        // anything on the list; filter out <25% too so rows never double up
                        // with the Low Stock section above.
                        let runningOut = store.itemsRunningOutSoon(within: 4)
                            .filter { $0.effectiveLevel >= 0.25 }
                        if !runningOut.isEmpty {
                            sectionLabel("📉 Running Out Soon — Tap to Add")
                            ForEach(runningOut) { inv in
                                Button {
                                    withAnimation {
                                        store.addToGroceryIfMissing(inv.name, recommended: true)
                                    }
                                    HapticManager.light()
                                } label: {
                                    HStack {
                                        Image(systemName: "gauge.with.needle")
                                            .scaledFont(16)
                                            .foregroundStyle(Color.stockedGold)
                                            .frame(width: 28)
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(inv.name).scaledFont(14).foregroundStyle(text)
                                            if let ro = store.predictedRunOut(for: inv) {
                                                Text("At your usual pace, gone by \(ro.formatted(.dateTime.weekday(.wide)))")
                                                    .scaledFont(11)
                                                    .foregroundStyle(Color.stockedGold)
                                            }
                                            if let deal = store.bestPrice(for: inv.name) {
                                                Text("Cheapest at \(deal.store) · $\(String(format: "%.2f", deal.price))")
                                                    .scaledFont(11)
                                                    .foregroundStyle(Color.stockedGreen)
                                            }
                                        }
                                        Spacer()
                                        Text("Add").scaledFont(13, weight: .semibold)
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(session.themeCardColor)
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 8)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                .swipeToDelete(confirmTitle: "Remove \(inv.name) from your kitchen?") {
                                    let removed = inv
                                    store.removeInventoryItem(id: inv.id)
                                    ToastCenter.shared.undo("Deleted \(inv.name.displayNormalized)") {
                                        store.restoreInventoryItems([removed])
                                    }
                                }
                            }
                        }

                        // #A4 — predicted restocks: staples due based on YOUR burn rate
                        // (learned from the consumption log), not just current levels.
                        let predicted = cachedPredicted
                        if !predicted.isEmpty {
                            sectionLabel("🔮 Probably Running Low — Tap to Add")
                            ForEach(predicted, id: \.self) { name in
                                Button {
                                    withAnimation { store.addGroceryItem(name: name) }
                                    HapticManager.light()
                                } label: {
                                    HStack {
                                        Image(systemName: "clock.arrow.circlepath")
                                            .scaledFont(16)
                                            .foregroundStyle(Color.stockedGold)
                                            .frame(width: 28)
                                        Text(name.displayNormalized).scaledFont(14).foregroundStyle(text)
                                        Spacer()
                                        Text("Add").scaledFont(13, weight: .semibold)
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(session.themeCardColor)
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .a11yButton("Add \(name.displayNormalized), likely running low")
                            }
                        }

                        // Your usuals — frequently added items not currently on the list.
                        let usuals = GroceryUsuals.shared.suggestions(
                            excluding: store.groceryItems.map { $0.name }, limit: 8)
                        if !usuals.isEmpty {
                            sectionLabel("⭐ Your Usuals — Tap to Add")
                            ForEach(usuals, id: \.self) { name in
                                Button {
                                    withAnimation {
                                        store.addGroceryItem(name: name)
                                    }
                                    GroceryUsuals.shared.record(name)
                                    HapticManager.light()
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.counterclockwise.circle")
                                            .scaledFont(16)
                                            .foregroundStyle(Color.stockedGold)
                                            .frame(width: 28)
                                        Text(name).scaledFont(14).foregroundStyle(text)
                                        Spacer()
                                        Text("Add").scaledFont(13, weight: .semibold)
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(session.themeCardColor)
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .a11yButton("Add \(name) to list", hint: "One of your frequently bought items")
                            }
                        }

                        // Nearby grocery discovery belongs directly in the Grocery tab. The
                        // embedded variant reuses this scroll view instead of nesting another one.
                        GroceryStoreFinderView(embedded: true)
                            .padding(.top, 20)
                    }
                    .padding(.bottom, 110)
                }
            }
        }
        .sheet(item: $grocerySheet) { sheet in
            switch sheet {
            case .storePicker: quickStorePickerSheet
            case .share:       ShareSheet(items: [shareText])
            case .scanList:
                // #16 — scan a handwritten/printed list; each line becomes a grocery item.
                HandwrittenListScanner { lines in
                    var n = 0
                    for line in lines {
                        let name = line.trimmingCharacters(in: .whitespaces)
                        guard name.count >= 2,
                              !store.groceryItems.contains(where: { $0.name.lowercased() == name.lowercased() })
                        else { continue }
                        store.groceryItems.append(LocalGroceryItem(name: name, isChecked: false))
                        n += 1
                    }
                    loopMessage = "Added \(n) item\(n == 1 ? "" : "s") from your list"
                    grocerySheet = nil
                }.environment(session)
            case .cookLater(let context):
                NavigationStack {
                    CookLaterWorkspaceView(context: context).environment(session)
                }
            case .purchaseReview(let context):
                // RL-007 — Merge / Keep Both / Skip for flagged duplicates, then commit.
                PurchaseDedupReviewView(context: context,
                                        onCommit: { resolutions in
                                            grocerySheet = nil
                                            commitPantryTransfer(candidates: context.candidates,
                                                                 resolutions: resolutions)
                                        },
                                        onCancel: { grocerySheet = nil })
                    .environment(session)
            }
        }
        .onAppear { rebuildSections() }
        .task {
            // #E2 — load the household roster for assignments (no-op when solo).
            let sync = HouseholdSync.shared
            if sync.state == .owner || sync.state == .member {
                let members = await sync.fetchMembers()
                householdMemberNames = members.map(\.name).filter { !$0.isEmpty }
            }
        }
        .onChange(of: store.groceryRevision) { _, _ in rebuildSections() }
        .onChange(of: searchText) { _, _ in rebuildSections() }
        .onChange(of: showBought) { _, _ in rebuildSections() }   // #235 — segment filter
        .onChange(of: showMineOnly) { _, _ in rebuildSections() } // #E2 — Mine filter
        .onChange(of: sortAZ) { _, _ in rebuildSections() }        // #245 — sort pill
        .onChange(of: groupByStore) { _, _ in rebuildSections() }  // RL-010 — store grouping
        .onChange(of: selectedStore) { _, _ in rebuildSections() }
        .onChange(of: selectedAisle) { _, _ in rebuildSections() }
        // #245 — header ··· hosts the relocated chrome (store / share / scan / move).
        .confirmationDialog("Grocery List", isPresented: $showMoreDialog, titleVisibility: .visible) {
            Button("Shopping at \(session.preferredStore) — change store") { grocerySheet = .storePicker }
            Button("Share List") {
                let items = store.groceryItems.filter { !$0.isChecked }
                let lines = items.map { "• \($0.name)\($0.recipeSource.isEmpty ? "" : " (\($0.recipeSource))")" }
                shareText = lines.isEmpty ? "No items on the list." : "My Grocery List:\n\n" + lines.joined(separator: "\n")
                grocerySheet = .share
            }
            Button("Scan a List") { grocerySheet = .scanList }
            if store.groceryItems.contains(where: { $0.isChecked }) {
                Button("Move Checked → Pantry") {
                    // RL-007 — routed through the dedupe-aware transfer so a trip that was
                    // already receipt-scanned (or double-tapped) can't land twice.
                    beginPantryTransfer(store.groceryItems.filter { $0.isChecked })
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        // #235 — mockup's pinned "+ Add Item" button (To Buy only).
        .overlay(alignment: .bottom) {
            if !showBought {
                Button { showQuickAdd = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").scaledFont(15, weight: .bold)
                        Text("Add Item").scaledFont(15, weight: .bold, design: .serif)
                    }
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 26).padding(.vertical, 14)
                    .background(Color.stockedCharcoal)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 14)
                .coachmarkAnchor("grocery.add")
            }
        }
        .alert("Add Item", isPresented: $showQuickAdd) {
            TextField("Item name", text: $quickAddName)
            Button("Add") {
                let name = quickAddName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    store.addGroceryItem(name: name)
                    HapticManager.success()
                }
                quickAddName = ""
            }
            Button("Cancel", role: .cancel) { quickAddName = "" }
        } message: {
            Text("Add something to your grocery list.")
        }
        .coachmarks(page: .grocery, steps: GroceryCoachmarks.steps)
    }

    // MARK: - Receipt Reconciliation
    // Called by ReceiptScannerView after a successful scan via Notification
    func reconcileWithReceipt(_ scannedNames: [String]) {
        let normalised = scannedNames.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
        for i in store.groceryItems.indices {
            let itemLower = store.groceryItems[i].name.lowercased()
            if normalised.contains(where: { $0.contains(itemLower) || itemLower.contains($0) }) {
                store.groceryItems[i].isChecked = true
            }
        }
    }

    // MARK: - Section card with expandable rows
    @ViewBuilder
    private func sectionCard(_ section: GrocerySection) -> some View {
        let isOpen = expandedSection == section.title
        let done   = section.items.filter { $0.isChecked }.count
        let total  = section.items.count

        VStack(spacing: 0) {
            Button {
                motion.animate(.standard, intent: .spatial) {
                    expandedSection = isOpen ? nil : section.title
                }
            } label: {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.stockedGold.opacity(0.09))
                        FoodIconView(name: section.title, size: 62, emojiSize: 34)
                    }
                    .frame(width: 78, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(section.title)
                            .font(.stockedSerif(19, weight: .bold, relativeTo: .headline))
                            .foregroundStyle(text)
                        Text("\(done) of \(total)")
                            .font(.stocked(.subheadline).weight(.semibold))
                            .foregroundStyle(done == total && total > 0 ? Color.stockedGreen : sub)
                    }
                    Spacer()
                    Image(systemName: isOpen ? "chevron.up" : "chevron.right")
                        .font(.stocked(.subheadline).weight(.semibold))
                        .foregroundStyle(sub)
                }
                .padding(14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .confirmationDialog("Remove \"\(section.title)\"?",
                                isPresented: Binding(get: { pendingDeleteTitle == section.title },
                                                     set: { if !$0 { pendingDeleteTitle = nil } }),
                                titleVisibility: .visible) {
                Button("Remove \(total) item\(total == 1 ? "" : "s")", role: .destructive) {
                    let ids = Set(section.items.map(\.id))
                    withAnimation { store.groceryItems.removeAll { ids.contains($0.id) } }
                    pendingDeleteTitle = nil
                }
                Button("Cancel", role: .cancel) { pendingDeleteTitle = nil }
            } message: {
                Text("Removes every item in this group from your list.")
            }

            Divider().padding(.horizontal, 14)
            let visibleItems = isOpen ? section.items : Array(section.items.prefix(3))
            ForEach(visibleItems) { item in
                editorialGroceryRow(item)
                if item.id != visibleItems.last?.id {
                    Divider().padding(.leading, 58)
                }
            }
            if !isOpen && total > visibleItems.count {
                Button("\(total - visibleItems.count) more") { expandedSection = section.title }
                    .font(.stocked(.caption).weight(.semibold))
                    .foregroundStyle(Color.stockedGoldDark)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }

            if isOpen {
                if done > 0 {
                    Divider().padding(.horizontal, 14)
                    Button {
                        let sectionIDs = Set(section.items.map(\.id))
                        let removed = store.groceryItems.filter { $0.isChecked && sectionIDs.contains($0.id) }
                        withAnimation {
                            store.groceryItems.removeAll { $0.isChecked && sectionIDs.contains($0.id) }
                        }
                        // Undoable (#11) instead of a permanent clear.
                        let count = removed.count
                        ToastCenter.shared.undo(count == 1 ? "1 item cleared" : "\(count) items cleared") {
                            withAnimation { store.groceryItems.append(contentsOf: removed) }
                        }
                    } label: {
                        Label("Clear \(done) checked", systemImage: "trash")
                            .scaledFont(12, weight: .semibold)
                            .foregroundStyle(.red.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .a11yButton("Clear \(done) checked items", hint: "Removes checked items. You can undo.")
                }
            }

            // RL-010 — per-store segment transfer: in the Bought view grouped by store,
            // each store's purchases can move to the pantry as soon as that segment is
            // confirmed, without waiting for the rest of a multi-store trip. Runs through
            // the RL-007 dedupe path like every other import.
            if groupByStore && showBought && total > 0 {
                Divider().padding(.horizontal, 14)
                MultiStoreSegmentFooter(storeName: section.title,
                                        itemCount: total,
                                        isComplete: storeSegmentComplete(section.title)) {
                    beginPantryTransfer(section.items)
                }
            }
        }
        .background(session.themeCardColor)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(text.opacity(0.07), lineWidth: 1)
        }
        .contextMenu {
            Button(role: .destructive) { pendingDeleteTitle = section.title } label: {
                Label("Remove \(section.title)", systemImage: "trash")
            }
        }
    }

    private func editorialGroceryRow(_ item: LocalGroceryItem) -> some View {
        let parsed = GroceryNameParser.parse(item.name)
        let size = item.sizeText.isEmpty ? parsed.sizeText : item.sizeText
        return Button {
            motion.animate(.selection, intent: .spatial) {
                if let index = store.groceryItems.firstIndex(where: { $0.id == item.id }) {
                    store.groceryItems[index].isChecked.toggle()
                    if store.groceryItems[index].isChecked {
                        GroceryUsuals.shared.record(store.groceryItems[index].name)
                    }
                    HapticManager.light()
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.stocked(.title2))
                    .foregroundStyle(item.isChecked ? Color.stockedGreen : sub.opacity(0.75))
                    .frame(width: 32, height: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(parsed.name.displayNormalized)
                        .font(.stocked(.body).weight(.medium))
                        .foregroundStyle(item.isChecked ? sub : text)
                        .strikethrough(item.isChecked)
                    if !item.recipeSource.isEmpty {
                        Text(item.recipeSource)
                            .font(.stocked(.caption))
                            .foregroundStyle(sub)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                Text(size.isEmpty ? (item.quantity == 1 ? "1" : "\(item.quantity)") : size)
                    .font(.stocked(.subheadline))
                    .foregroundStyle(sub)
                Menu {
                    Button("Add one", systemImage: "plus") {
                        store.updateGroceryQty(id: item.id, qty: item.quantity + 1)
                    }
                    if item.quantity > 1 {
                        Button("Remove one", systemImage: "minus") {
                            store.updateGroceryQty(id: item.id, qty: item.quantity - 1)
                        }
                    }
                    Button("Plan with this item", systemImage: "calendar.badge.plus") {
                        grocerySheet = .cookLater(.grocery(name: item.name, recipeSource: item.recipeSource))
                    }
                    Button("Find at \(resolvedStore(for: item))", systemImage: "cart") {
                        openInStore(item.name)
                    }
                    Button("Remove", systemImage: "trash", role: .destructive) {
                        undoItem = item
                        store.groceryItems.removeAll { $0.id == item.id }
                        showUndo = true
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.stocked(.body).weight(.semibold))
                        .foregroundStyle(sub)
                        .frame(width: 44, height: 44)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.isChecked ? "Uncheck" : "Check") \(parsed.name.displayNormalized), quantity \(item.quantity)")
    }

    // MARK: - Individual row — full cell tappable
    private func groceryRow(_ item: LocalGroceryItem) -> some View {
        let parsed = GroceryNameParser.parse(item.name)
        let size = item.sizeText.isEmpty ? parsed.sizeText : item.sizeText
        let displayName = size.isEmpty
            ? parsed.name.displayNormalized
            : "\(parsed.name.displayNormalized) (\(size))"

        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Button {
                    motion.animate(.selection, intent: .spatial) {
                        if let idx = store.groceryItems.firstIndex(where: { $0.id == item.id }) {
                            store.groceryItems[idx].isChecked.toggle()
                            HapticManager.light()
                            if store.groceryItems[idx].isChecked {
                                GroceryUsuals.shared.record(store.groceryItems[idx].name)
                            }
                        }
                    }
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                            .scaledFont(20)
                            .foregroundStyle(item.isChecked ? session.themeContrastAccent : sub)
                            .frame(width: 26, height: 28, alignment: .center)
                            .a11yDecorative()

                        Text(ImageFallbackService.emoji(for: item.name))
                            .scaledFont(17)
                            .frame(width: 24, height: 28, alignment: .center)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(displayName)
                                .scaledFont(16, weight: .medium)
                                .foregroundStyle(item.isChecked ? sub : text)
                                .strikethrough(item.isChecked)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)

                            StockedFlowLayout(spacing: 4, lineSpacing: 4) {
                                if !item.recipeSource.isEmpty {
                                    Image(systemName: "fork.knife").scaledFont(8)
                                    Text(item.recipeSource).scaledFont(12, weight: .semibold)
                                } else if item.isRecommended {
                                    Image(systemName: "arrow.2.circlepath").scaledFont(8)
                                    Text("Auto-added").scaledFont(12, weight: .semibold)
                                } else {
                                    Image(systemName: "hand.point.right").scaledFont(8)
                                    Text("Manual").scaledFont(12, weight: .semibold)
                                }
                                if StockedDatabase.shared.hasSubstitution(for: item.name) {
                                    Text("·").scaledFont(8).foregroundStyle(sub)
                                    Image(systemName: "arrow.left.arrow.right").scaledFont(7)
                                        .foregroundStyle(session.themeContrastAccent)
                                    Text("Sub available").scaledFont(12, weight: .semibold)
                                        .foregroundStyle(session.themeContrastAccent)
                                }
                                if !item.assignedTo.isEmpty {
                                    Text("·").scaledFont(8).foregroundStyle(sub)
                                    Image(systemName: "person.fill").scaledFont(7)
                                        .foregroundStyle(Color.stockedGreen)
                                    Text(item.assignedTo).scaledFont(12, weight: .semibold)
                                        .foregroundStyle(Color.stockedGreen)
                                } else if !item.addedByName.isEmpty {
                                    Text("·").scaledFont(8).foregroundStyle(sub)
                                    Text("by \(item.addedByName)").scaledFont(12, weight: .semibold)
                                        .foregroundStyle(session.themeContrastAccent)
                                }
                            }
                            .foregroundStyle(sub)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(item.isChecked ? "Uncheck" : "Check") \(displayName)")

                // Flexible inset yields to large text and the 44-point quantity controls.
                HStack(spacing: 7) {
                    Color.clear.frame(minWidth: 0, maxWidth: 60, minHeight: 1, maxHeight: 1)
                        .layoutPriority(-1)
                    Text("Qty")
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(sub)
                    Button {
                        if item.quantity > 1 {
                            store.updateGroceryQty(id: item.id, qty: item.quantity - 1)
                        }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .scaledFont(22)
                            .foregroundStyle(session.themeContrastAccent)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Decrease quantity")
                    .disabled(item.quantity <= 1)

                    Text("\(item.quantity)")
                        .scaledFont(15, weight: .bold)
                        .foregroundStyle(text)
                        .frame(minWidth: 18)

                    Button {
                        store.updateGroceryQty(id: item.id, qty: item.quantity + 1)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .scaledFont(22)
                            .foregroundStyle(session.themeContrastAccent)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Increase quantity")
                    Spacer(minLength: 0)
                }
            }
            .layoutPriority(1)

            VStack(spacing: 8) {
                Button {
                    grocerySheet = .cookLater(.grocery(name: item.name, recipeSource: item.recipeSource))
                } label: {
                    Image(systemName: "calendar.badge.plus")
                        .scaledFont(16)
                        .foregroundStyle(session.themeContrastAccent)
                        .frame(width: 44, height: 44)
                        .background(Color.stockedGreen.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(item.recipeSource.isEmpty ? "Plan with this item" : "View planned meal")

                Button { openInStore(item.name) } label: {
                    Image(systemName: "cart.fill")
                        .scaledFont(16)
                        .foregroundStyle(session.themeContrastAccent)
                        .frame(width: 44, height: 44)
                        .background(Color.stockedGold.opacity(0.12))
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Find in store")

                Button {
                    undoItem = item
                    withAnimation { store.groceryItems.removeAll { $0.id == item.id } }
                    motion.animate(.standard, intent: .spatial) { showUndo = true }
                    HapticManager.warning()
                } label: {
                    Image(systemName: "xmark")
                        .scaledFont(16)
                        .foregroundStyle(sub)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove item")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        // #E2 assignable items — long-press to ask a household member to grab it.
        // Members come from the household roster; solo users just see Unassign/me.
        .contextMenu {
            Button {
                grocerySheet = .cookLater(.grocery(name: item.name, recipeSource: item.recipeSource))
            } label: {
                Label(item.recipeSource.isEmpty ? "Plan with this item" : "View planned meal", systemImage: "calendar.badge.plus")
            }
            // RL-010 — assign/move this row to a store. Just a side-table write, so the
            // item is never recreated: checked state and provenance survive the move.
            Menu {
                MultiStorePickerMenu(
                    currentStore: resolvedStore(for: item),
                    isExplicit: MultiStoreAssignments.shared.explicitStore(for: item.id) != nil,
                    extras: Array(Set(store.itemStoreHistory.values)).sorted(),
                    onSelect: { name in
                        MultiStoreAssignments.shared.assign(name, to: item.id)
                        rebuildSections()
                        HapticManager.select()
                    })
            } label: {
                Label("Store: \(resolvedStore(for: item))", systemImage: "storefront")
            }
            if HouseholdSync.shared.state == .owner || HouseholdSync.shared.state == .member {
                Menu {
                    ForEach(assignableMembers, id: \.self) { name in
                        Button {
                            if let idx = store.groceryItems.firstIndex(where: { $0.id == item.id }) {
                                store.groceryItems[idx].assignedTo = name
                            }
                        } label: { Label(name, systemImage: "person") }
                    }
                    if !item.assignedTo.isEmpty {
                        Button(role: .destructive) {
                            if let idx = store.groceryItems.firstIndex(where: { $0.id == item.id }) {
                                store.groceryItems[idx].assignedTo = ""
                            }
                        } label: { Label("Unassign", systemImage: "person.slash") }
                    }
                } label: { Label("Assign to…", systemImage: "person.badge.plus") }
            }
        }
        .swipeToDelete {
            undoItem = item
            withAnimation { store.groceryItems.removeAll { $0.id == item.id } }
            motion.animate(.standard, intent: .spatial) { showUndo = true }
            HapticManager.warning()
        }
    }

    // MARK: - Store URL handoff engine
    private func openInStore(_ itemName: String) {
        let enc = itemName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? itemName
        let urlMap: [String: String] = [
            "Walmart":       "https://www.walmart.com/search?q=\(enc)",
            "Target":        "https://www.target.com/s?searchTerm=\(enc)",
            "H-E-B":         "https://www.heb.com/search/?q=\(enc)",
            "Kroger":        "https://www.kroger.com/search?query=\(enc)",
            "Whole Foods":   "https://www.wholefoodsmarket.com/search?text=\(enc)",
            "Aldi":          "https://www.aldi.us/en/search/?q=\(enc)",
            "Publix":        "https://www.publix.com/search#criteria=\(enc)",
            "Safeway":       "https://www.safeway.com/shop/search-results.html?q=\(enc)",
            "Costco":        "https://www.costco.com/CatalogSearch?keyword=\(enc)",
            "Trader Joe\'s": "https://www.traderjoes.com/home/search?q=\(enc)",
            "Sprouts":       "https://www.sprouts.com/search/?q=\(enc)",
            "Meijer":        "https://www.meijer.com/shopping/search.html?search=\(enc)",
            "Wegmans":       "https://shop.wegmans.com/search?search_term=\(enc)",
            "Food Lion":     "https://www.foodlion.com/search?searchText=\(enc)",
            "Amazon Fresh":  "https://www.amazon.com/s?k=\(enc)&i=amazonfresh",
        ]
        let url = urlMap[session.preferredStore] ?? "https://www.google.com/search?q=\(enc)+grocery"
        if let u = URL(string: url) { UIApplication.shared.open(u) }
    }

    private func sectionLabel(_ t: String) -> some View {
        SectionHeader(text: t)
    }

    // MARK: - Quick Store Picker Sheet
    private var quickStorePickerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Text("Tap to change your shopping store. Your preference is saved per-item when you use Find in Store.")
                        .scaledFont(13).foregroundStyle(session.themeSecondaryText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)

                    ForEach(allStores, id: \.self) { store in
                        Button {
                            session.preferredStore = store
                            grocerySheet = nil
                            HapticManager.success()
                        } label: {
                            HStack {
                                Text(store)
                                    .font(.stockedSystem(size: 16, weight: session.preferredStore == store ? .bold : .regular, design: .serif))
                                    .foregroundStyle(session.preferredStore == store ? Color.stockedGold : session.themeTextColor)
                                Spacer()
                                if session.preferredStore == store {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.stockedGold).scaledFont(20)
                                }
                            }
                            .padding(.horizontal, 28).padding(.vertical, 14)
                        }.buttonStyle(.plain)
                        Divider().padding(.leading, 28)
                    }
                }
            }
            .navigationTitle("Choose Store")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(session.themeBgColor.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { grocerySheet = nil }
                        .foregroundStyle(Color.stockedGold)
                }
            }
        }
    }

    private func addItem() {
        let n = newItem.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }
        withAnimation { store.addGroceryItem(name: n) }
        GroceryUsuals.shared.record(n)   // learn frequently-added items for one-tap re-add
        newItem = ""
        searchText = ""
    }
}

// MARK: Share Sheet — defined in ShareHelpers.swift

#Preview { GroceryListView().environment(AppSession()) }

// MARK: - Handwritten / printed list scanner (#16)
// Scans a shopping list with the camera and returns each line as a grocery item.
struct HandwrittenListScanner: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    var onLines: ([String]) -> Void
    @State private var status = "Point at your written list, then Capture"

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if #available(iOS 16.0, *) {
                LiveTextScannerPanel(onCapture: { text in
                    let lines = text
                        .components(separatedBy: .newlines)
                        .map { $0.trimmingCharacters(in: .whitespaces) }
                        .filter { $0.count >= 2 && !$0.allSatisfy { c in c.isNumber || c.isPunctuation } }
                    if lines.isEmpty {
                        status = "Couldn't read any items — try again"
                    } else {
                        onLines(lines)
                    }
                })
                .ignoresSafeArea()
            } else {
                Text("List scanning needs iOS 16+").foregroundStyle(.white)
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .scaledFont(28).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                }.padding()
                Spacer()
                Text(status)
                    .scaledFont(14, weight: .semibold).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.55)).clipShape(Capsule())
                Button {
                    NotificationCenter.default.post(name: .captureReceiptShutter, object: nil)
                } label: {
                    Text("Capture List")
                        .scaledFont(16, weight: .semibold).foregroundStyle(.black)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(.white).clipShape(Capsule())
                }.padding(.bottom, 36)
            }
        }
    }
}
