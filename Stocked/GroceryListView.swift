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
                .scaledFont(13, weight: .bold).foregroundStyle(Color.stockedGoldDark)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4).padding(.horizontal, 24)
        .transition(.stockedMove(edge: .bottom).combined(with: .opacity))
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
    @State private var addFieldText = ""
    @FocusState private var addFieldFocused: Bool
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
                title: "Add to Kitchen", candidates: candidates, flags: flags))
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
                // Milk belongs in the fridge and peas in the freezer, not everything in Pantry.
                var inv = LocalInventoryItem(name: g.name, level: 1.0,
                                             zone: ReceiptDatabase.shared.guessZone(for: g.name),
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
                    title: "Add groceries to kitchen",
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
            ? "Nothing new to add — duplicates skipped"
            : "Added \(moved) item\(moved == 1 ? "" : "s") to your kitchen\(segmentNote)"
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
            .padding(.bottom, 12)
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
                    .stockedPresentationSurface(width: .readable)
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
            // Uses the roster cached by the last household pull; only fetches when it is stale.
            let sync = HouseholdSync.shared
            if sync.state == .owner || sync.state == .member {
                householdMemberNames = await sync.cachedMembers().map(\.name).filter { !$0.isEmpty }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedFocusGroceryAdd)) { _ in
            showBought = false
            addFieldFocused = true
        }
        .onChange(of: store.groceryRevision) { _, _ in rebuildSections() }
        .onChange(of: searchText) { _, _ in rebuildSections() }
        .onChange(of: showBought) { _, _ in rebuildSections() }
        .onChange(of: showMineOnly) { _, _ in rebuildSections() }
        .onChange(of: sortAZ) { _, _ in rebuildSections() }
        .onChange(of: groupByStore) { _, _ in rebuildSections() }
        .onChange(of: selectedStore) { _, _ in rebuildSections() }
        .onChange(of: selectedAisle) { _, _ in rebuildSections() }
        .onChange(of: session.preferredStore) { _, _ in preferredStoreDidChange() }
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
                Button("Add Bought Items to Kitchen") {
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
        StockedEditorialHero(eyebrow: "Your next grocery trip",
            title: toBuyCount == 0 ? "Nothing to buy yet." : toBuyCount == 1 ? "1 thing for a well-stocked week." : "\(toBuyCount) things for a well-stocked week.",
            subtitle: "Organized for an easier shop at \(session.preferredStore).",
            artwork: "pastel_fresh_produce")
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
                Text(store.groceryItems.isEmpty ? "Add items to plan your trip" : "\(boughtCount) of \(store.groceryItems.count) in cart")
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
            }
            .stockedPrimary(fg: Color.selectedTabForeground(dark))
            .disabled(toBuyCount == 0)
            .opacity(toBuyCount == 0 ? 0.5 : 1)
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
        Button {
            grocerySheet = .storePicker
        } label: {
            HStack(spacing: 8) {
                Text(session.preferredStore)
                    .font(.stocked(.title2).weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
                Image(systemName: "chevron.down")
                    .font(.stocked(.caption).weight(.semibold))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(session.accentColor)
            .frame(minHeight: layoutMetrics.minimumControlHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(StockedWidgetButtonStyle())
        .accessibilityLabel("Shopping store")
        .accessibilityValue(session.preferredStore)
        .accessibilityHint("Choose a different store for your grocery list")
    }

    private func preferredStoreDidChange() {
        // Item-specific store choices remain owned by MultiStoreAssignments. Only default-store
        // rows resolve differently, so discard stale screen filters and the previous aisle order.
        if !storeFilters.contains(selectedStore) { selectedStore = "All Stores" }
        isSortedForShopping = false
        rebuildSections()
    }

    private var shoppingTripFacts: some View {
        HStack(spacing: 18) {
            Label(toBuyCount == 1 ? "1 item" : "\(toBuyCount) items", systemImage: "bag")
            if toBuyCount > 0 {
                Label("About \(estimatedTripMinutes) min", systemImage: "clock")
            }
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
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
                                        Text(meal.title.recipeDisplayTitle)
                                            .font(.stockedSerif(17, weight: .bold, relativeTo: .headline))
                                            .foregroundStyle(text).fixedSize(horizontal: false, vertical: true)
                                        Text("· \(meal.ingredients.count) items")
                                            .font(.stocked(.caption).weight(.semibold))
                                            .foregroundStyle(Color.stockedSuccessInk)
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
                Button { showMoreDialog = true } label: {
                    Label("Organize", systemImage: "line.3.horizontal.decrease")
                        .font(.stocked(.subheadline).weight(.semibold))
                        .foregroundStyle(session.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .stockedGlassSurface(.control, cornerRadius: StockedRadius.md)
                }
                .buttonStyle(.plain)
            }
            if !showBought { groceryAddField }
            if !loopMessage.isEmpty {
                Text(loopMessage).font(.stocked(.caption)).foregroundStyle(session.accentColor)
            }
            if sections.isEmpty {
                let emptyLayout = layoutMetrics.isAccessibilityText || layoutMetrics.contentWidth < 350
                    ? AnyLayout(VStackLayout(alignment: .center, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
                emptyLayout {
                    Image(systemName: showBought ? "checkmark.circle" : "cart.badge.plus")
                        .font(.stocked(.largeTitle))
                        .foregroundStyle(session.accentColor)
                    Text(showBought ? "Nothing in the cart yet" : "Your list is clear")
                        .font(.stockedSerif(19, weight: .bold, relativeTo: .headline))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: layoutMetrics.isAccessibilityText ? .center : .leading)
                    if showBought {
                        Button("Add Item") { addFieldFocused = true }
                            .font(.stocked(.subheadline).weight(.semibold))
                            .foregroundStyle(session.accentColor)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(18)
                .background(session.themeCardColor,
                            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            } else {
                LazyVStack(spacing: 12) {
                    ForEach(sections) { sectionCard($0) }
                }
            }
        }
    }

    /// Always-visible add field: one tap + type + return, instead of Organize → Add Item → alert.
    @ViewBuilder
    private var groceryAddField: some View {
        HStack(spacing: 10) {
            Image(systemName: "plus.circle.fill")
                .font(.stocked(.title3))
                .foregroundStyle(session.accentColor)
                .accessibilityHidden(true)
            TextField("Add item…", text: $addFieldText)
                .textFieldStyle(.plain)
                .font(.stocked(.body))
                .foregroundStyle(text)
                .focused($addFieldFocused)
                .submitLabel(.done)
                .textInputAutocapitalization(.words)
                .onSubmit { commitAddField(keepFocus: true) }
            if !addFieldText.trimmingCharacters(in: .whitespaces).isEmpty {
                Button("Add") { commitAddField(keepFocus: true) }
                    .font(.stocked(.subheadline).weight(.semibold))
                    .foregroundStyle(session.accentColor)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 48)
        .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .contain)
        if addFieldFocused, !addFieldSuggestions.isEmpty {
            // One-tap adds from the user's usual purchases, filtered by what they're typing.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(addFieldSuggestions, id: \.self) { name in
                        Button {
                            store.addGroceryItem(name: name)
                            HapticManager.success()
                            addFieldText = ""
                        } label: {
                            Text(name.displayNormalized)
                                .font(.stocked(.subheadline))
                                .foregroundStyle(text)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 36)
                                .background(session.themeCardColor, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Add \(name.displayNormalized)")
                    }
                }
            }
        }
    }

    private var addFieldSuggestions: [String] {
        let typed = addFieldText.trimmingCharacters(in: .whitespaces)
        let usuals = GroceryUsuals.shared.suggestions(excluding: store.groceryItems.map(\.name), limit: 20)
        let matches = typed.isEmpty ? usuals : usuals.filter { $0.searchMatches(typed) }
        return Array(matches.prefix(6))
    }

    private func commitAddField(keepFocus: Bool) {
        let name = addFieldText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { addFieldFocused = false; return }
        store.addGroceryItem(name: name)
        HapticManager.success()
        addFieldText = ""
        addFieldFocused = keepFocus
    }

    /// Removes a row with an Undo toast that puts it back in the same position.
    private func removeWithUndo(_ item: LocalGroceryItem) {
        guard let index = store.groceryItems.firstIndex(where: { $0.id == item.id }) else { return }
        withAnimation { _ = store.groceryItems.remove(at: index) }
        HapticManager.warning()
        ToastCenter.shared.undo("Removed \(GroceryNameParser.parse(item.name).name.displayNormalized)") {
            guard !store.groceryItems.contains(where: { $0.id == item.id }) else { return }
            withAnimation { store.groceryItems.insert(item, at: min(index, store.groceryItems.count)) }
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
            .frame(minWidth: 44, minHeight: 44)
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

    // The pre-editorial Grocery layout (~500 lines, never rendered since `body` switched to
    // editorialPresentation) was removed; it only cost compile time.

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
                            .foregroundStyle(done == total && total > 0 ? Color.stockedSuccessInk : sub)
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
                    .foregroundStyle(session.accentColor)
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
                            .foregroundStyle(Color.stockedErrorInk)
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
        .stockedPastelCard(radius: 22)
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
                        // A mis-tap hides the row in Bought; offer a one-tap way back.
                        let id = item.id
                        ToastCenter.shared.undo("Checked off \(GroceryNameParser.parse(item.name).name.displayNormalized)") {
                            if let i = store.groceryItems.firstIndex(where: { $0.id == id }) {
                                withAnimation { store.groceryItems[i].isChecked = false }
                            }
                        }
                    }
                    HapticManager.light()
                }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.stocked(.title2))
                    .foregroundStyle(item.isChecked ? (dark ? Color.stockedSuccess : Color.stockedSuccessInk) : sub)
                    .frame(minWidth: 32, minHeight: 44)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(parsed.name.displayNormalized)
                        .font(.stocked(.body).weight(.medium))
                        .foregroundStyle(item.isChecked ? sub : text)
                        .strikethrough(item.isChecked)
                    if !item.recipeSource.isEmpty {
                        Text(item.recipeSource)
                            .font(.stocked(.caption))
                            .foregroundStyle(sub)
                            .fixedSize(horizontal: false, vertical: true)
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
                        removeWithUndo(item)
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

    // MARK: - Quick Store Picker Sheet
    private var quickStorePickerSheet: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text("Choose your default shopping store. Items assigned to a specific store keep that choice.")
                        .font(.stocked(.subheadline))
                        .foregroundStyle(session.themeSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.bottom, 8)

                    ForEach(allStores, id: \.self) { store in
                        Button {
                            session.preferredStore = store
                            grocerySheet = nil
                            HapticManager.success()
                        } label: {
                            HStack {
                                Text(store)
                                    .font(.stockedBody.weight(session.preferredStore == store ? .semibold : .regular))
                                    .foregroundStyle(session.preferredStore == store ? session.accentColor : session.themeTextColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 12)
                                if session.preferredStore == store {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(session.accentColor)
                                        .font(.stockedHeadline)
                                        .accessibilityHidden(true)
                                }
                            }
                            .padding(.horizontal, layoutMetrics.controlHorizontalPadding)
                            .padding(.vertical, 10)
                            .frame(maxWidth: .infinity, minHeight: layoutMetrics.minimumControlHeight, alignment: .leading)
                            .background(session.themeCardColor,
                                        in: RoundedRectangle(cornerRadius: layoutMetrics.controlCornerRadius, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: layoutMetrics.controlCornerRadius, style: .continuous))
                        }
                        .buttonStyle(StockedWidgetButtonStyle())
                        .accessibilityAddTraits(session.preferredStore == store ? .isSelected : [])
                    }
                }
                .padding(.horizontal, layoutMetrics.horizontalPadding)
                .padding(.vertical, 16)
            }
            .navigationTitle("Choose Store")
            .navigationBarTitleDisplayMode(.inline)
            .scrollContentBackground(.hidden)
            .background(session.themeBgColor.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { grocerySheet = nil }
                        .foregroundStyle(session.accentColor)
                }
            }
        }
        .stockedPresentationSurface()
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


extension Notification.Name {
    /// Opens the Grocery tab's add field with the keyboard up (Home "Add Grocery Item").
    static let stockedFocusGroceryAdd = Notification.Name("stockedFocusGroceryAdd")
}
