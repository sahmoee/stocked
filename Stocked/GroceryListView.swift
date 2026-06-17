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
                .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.stockedGold)
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
    case storePicker, share, scanList
    var id: Int {
        switch self { case .storePicker: return 0; case .share: return 1; case .scanList: return 2 }
    }
}

struct GroceryListView: View {
    @Environment(AppSession.self) var session
    @State private var newItem      = ""
    @State private var searchText   = ""
    @State private var expanded     = Set<String>()
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
    @State private var showQuickAdd = false  // #235 — bottom "+ Add Item" button
    @State private var showMoreDialog = false // #245 — header ··· (store/share/scan/move)
    @State private var sortAZ = false          // #245 — "Sort: Category / Name" pill
    @State private var quickAddName = ""

    // #235 — mockup segmented pill.
    private func segmentButton(_ title: String, count: Int, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 13.5, weight: .bold))
                if count > 0 {
                    Text("\(count)").font(.system(size: 11.5, weight: .bold)).opacity(0.7)
                }
            }
            .foregroundStyle(active ? Color.stockedWhite : (dark ? Color.stockedWhite.opacity(0.6) : Color.stockedCharcoal.opacity(0.6)))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(active ? Color.stockedCharcoal : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private let aisleOrder: [String: Int] = [
        "vegetable":1,"fruit":1,"apple":1,"banana":1,"berry":1,"lettuce":1,
        "tomato":1,"onion":1,"garlic":1,"pepper":1,"broccoli":1,"carrot":1,"spinach":1,
        "bread":2,"bagel":2,"tortilla":2,"roll":2,"muffin":2,
        "milk":3,"cheese":3,"yogurt":3,"butter":3,"cream":3,"egg":3,
        "chicken":4,"beef":4,"pork":4,"fish":4,"salmon":4,"shrimp":4,"turkey":4,"steak":4,
        "deli":5,"ham":5,"bacon":5,"sausage":5,
        "frozen":6,"ice cream":6,
        "can":7,"canned":7,"pasta":7,"rice":7,"bean":7,"lentil":7,"soup":7,
        "chip":8,"snack":8,"cereal":8,"cracker":8,"cookie":8,"nut":8,
        "water":9,"juice":9,"soda":9,"coffee":9,"tea":9,
        "oil":10,"vinegar":10,"salt":10,"spice":10,"herb":10,"ketchup":10,"mustard":10,"honey":10,
    ]
    private func aisleScore(_ name: String) -> Int {
        let lower = name.lowercased()
        return aisleOrder.first { lower.contains($0.key) }?.value ?? 99
    }
    private func sortForShopping() {
        withAnimation(.spring(response: 0.3)) {
            store.groceryItems.sort {
                let sa = aisleScore($0.name), sb = aisleScore($1.name)
                return sa == sb ? $0.name < $1.name : sa < sb
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
    private var text: Color  { dark ? Color.stockedWhite : Color.stockedCharcoal }
    private var sub:  Color  { dark ? Color(white: 0.55) : Color.stockedCharcoal.opacity(0.45) }

    // MARK: - Grouped sections (search-filtered)
    private func filteredItems(_ items: [LocalGroceryItem]) -> [LocalGroceryItem] {
        guard !searchText.isEmpty else { return items }
        return items.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    // Reads the cached value (rebuilt via rebuildSections on change). See #2.
    private var sections: [GrocerySection] { cachedSections }

    // #244 — mockup store category for an item name. Frozen wins first so
    // "frozen peas" / "chicken nuggets" land in Frozen, not Produce/Meat.
    private func categoryFor(_ name: String) -> (title: String, icon: String, order: Int) {
        let n = name.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { n.contains($0) } }
        if has(["frozen", "ice cream", "nugget", "popsicle"]) { return ("Frozen", "snowflake", 5) }
        // Spices / seasonings / baking → Pantry, checked BEFORE Produce so "ground
        // pepper", "black pepper", "seasoned salt", "cajun seasoning" etc. aren't
        // miscaught by Produce's "pepper" (bell pepper) match.
        if has(["salt","pepper corn","peppercorn","black pepper","white pepper","ground pepper",
                "lemon pepper","cayenne","paprika","cumin","oregano","thyme","rosemary","basil",
                "cinnamon","turmeric","nutmeg","seasoning","seasoned","spice","garlic powder",
                "onion powder","chili powder","curry","vanilla","baking soda","baking powder",
                "sugar","honey","syrup","vinegar","olive oil","vegetable oil","sauce"]) {
            return ("Pantry", "cabinet", 6)
        }
        if has(["vegetable","fruit","apple","banana","berry","lettuce","tomato","onion","garlic",
                "broccoli","carrot","spinach","avocado","potato","lemon","lime","cucumber",
                "celery","mushroom","corn","pea","grape","orange","melon","kale","zucchini","cilantro"]) {
            return ("Produce", "leaf", 1)
        }
        // Fresh peppers only (not ground/seasoning pepper, handled above) → Produce.
        if has(["bell pepper","jalapeño","jalapeno","poblano","serrano","habanero","fresh herb"]) {
            return ("Produce", "leaf", 1)
        }
        if has(["bread","bagel","tortilla","roll","muffin","bun","croissant","pita","baguette"]) {
            return ("Bakery", "basket", 2)
        }
        if has(["milk","cheese","yogurt","butter","cream","egg"]) { return ("Dairy", "drop", 3) }
        if has(["chicken","beef","pork","fish","salmon","shrimp","turkey","steak","bacon","sausage","ham","deli","lamb","tuna"]) {
            return ("Meat", "fork.knife", 4)
        }
        return ("Pantry", "cabinet", 6)
    }

    private func rebuildSections() {
        // #244 — mockup grouping: store categories, ordered Produce → Pantry.
        // The To Buy / Bought segment (#235) still filters the pool first.
        let pool = store.groceryItems.filter { $0.isChecked == showBought }
        let visible = filteredItems(pool)
        var grouped: [String: (icon: String, order: Int, items: [LocalGroceryItem])] = [:]
        for item in visible {
            let cat = categoryFor(item.name)
            grouped[cat.title, default: (cat.icon, cat.order, [])].items.append(item)
        }
        cachedSections = grouped
            .map { (title: $0.key, info: $0.value) }
            .sorted { $0.info.order < $1.info.order }
            .map { GrocerySection(title: $0.title, icon: $0.info.icon,
                                  items: sortAZ ? $0.info.items.sorted { $0.name.lowercased() < $1.name.lowercased() }
                                                : $0.info.items) }
    }

    var body: some View {
        StockedShell(scrollDisabled: true,
                     titleText: "Grocery List",
                     leadingTitle: true,
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
                }
                .padding(4)
                .background(dark ? Color.white.opacity(0.06) : Color.stockedWhite.opacity(0.35))
                .clipShape(Capsule())
                .padding(.horizontal, 24).padding(.bottom, 12)

                // ── #245 — stacked title + Sort pill (mockup) ───────────
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(showBought ? "Bought" : "To Buy")
                            .font(.system(size: 24, weight: .bold, design: .serif))
                            .foregroundStyle(text)
                        let n = store.groceryItems.filter { $0.isChecked == showBought }.count
                        Text("\(n) item\(n == 1 ? "" : "s")")
                            .font(.system(size: 13)).foregroundStyle(sub)
                    }
                    Spacer()
                    Menu {
                        Button { sortAZ = false } label: {
                            Label("Category", systemImage: sortAZ ? "circle" : "checkmark")
                        }
                        Button { sortAZ = true } label: {
                            Label("Name (A–Z)", systemImage: sortAZ ? "checkmark" : "circle")
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text("Sort: \(sortAZ ? "Name" : "Category")")
                                .font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .foregroundStyle(text.opacity(0.75))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(dark ? Color.white.opacity(0.08) : Color.stockedWhite.opacity(0.35))
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 10)


                if !loopMessage.isEmpty {
                    Text(loopMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.stockedGold)
                        .padding(.horizontal, 24).padding(.bottom, 8)
                        .transition(.opacity)
                }

                // ── SCROLLABLE LIST ──────────────────────────────────
                ScrollView(showsIndicators: false) {
                Color.clear.frame(height: 1) // anchor for refreshable
                    VStack(alignment: .leading, spacing: 0) {

                        // Recipe sections
                        if sections.isEmpty && store.groceryItems.isEmpty {
                            StockedEmptyState(
                                icon: "🛒",
                                title: "List is empty",
                                subtitle: "Add items above, or plan a meal — ingredients will show up here automatically."
                            ).padding(.top, 24)
                        } else if sections.isEmpty && !searchText.isEmpty {
                            VStack(spacing: 10) {
                                Text("🔍").font(.system(size: 36))
                                Text("No results for \"\(searchText)\"")
                                    .font(.system(size: 14)).foregroundStyle(sub)
                                Button("Add \"\(searchText)\" to list") { addItem() }
                                    .font(.system(size: 14, weight: .semibold))
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
                            inv.effectiveLevel < 0.25 &&
                            !store.groceryItems.contains { $0.name.lowercased() == inv.name.lowercased() }
                        }
                        if !lowNotInList.isEmpty {
                            sectionLabel("🔴 Low Stock — Tap to Add")
                            ForEach(lowNotInList) { inv in
                                Button {
                                    withAnimation {
                                        store.groceryItems.append(
                                            LocalGroceryItem(name: inv.name, isChecked: false, isRecommended: true))
                                    }
                                } label: {
                                    HStack {
                                        Image(systemName: "exclamationmark.circle")
                                            .font(.system(size: 16))
                                            .foregroundStyle(inv.effectiveLevel == 0 ? .red : .orange)
                                            .frame(width: 28)
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(inv.name).font(.system(size: 14)).foregroundStyle(text)
                                            Text("\(inv.zone) · \(Int(inv.effectiveLevel * 100))% left")
                                                .font(.system(size: 11))
                                                .foregroundStyle(inv.effectiveLevel == 0 ? .red : .orange)
                                            // #7 — where it's been cheapest lately
                                            if let deal = store.bestPrice(for: inv.name) {
                                                Text("Cheapest at \(deal.store) · $\(String(format: "%.2f", deal.price))")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(Color.stockedGreen)
                                            }
                                        }
                                        Spacer()
                                        Text("Add").font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(dark ? Color.white.opacity(0.06) : Color.stockedWhite.opacity(0.35))
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 8)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
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
                                        store.groceryItems.append(
                                            LocalGroceryItem(name: inv.name, isChecked: false, isRecommended: true))
                                    }
                                    HapticManager.light()
                                } label: {
                                    HStack {
                                        Image(systemName: "gauge.with.needle")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Color.stockedGold)
                                            .frame(width: 28)
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text(inv.name).font(.system(size: 14)).foregroundStyle(text)
                                            if let ro = store.predictedRunOut(for: inv) {
                                                Text("At your usual pace, gone by \(ro.formatted(.dateTime.weekday(.wide)))")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(Color.stockedGold)
                                            }
                                            if let deal = store.bestPrice(for: inv.name) {
                                                Text("Cheapest at \(deal.store) · $\(String(format: "%.2f", deal.price))")
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(Color.stockedGreen)
                                            }
                                        }
                                        Spacer()
                                        Text("Add").font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(dark ? Color.white.opacity(0.06) : Color.stockedWhite.opacity(0.35))
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 8)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
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
                                        store.groceryItems.append(
                                            LocalGroceryItem(name: name, isChecked: false))
                                    }
                                    GroceryUsuals.shared.record(name)
                                    HapticManager.light()
                                } label: {
                                    HStack {
                                        Image(systemName: "arrow.counterclockwise.circle")
                                            .font(.system(size: 16))
                                            .foregroundStyle(Color.stockedGold)
                                            .frame(width: 28)
                                        Text(name).font(.system(size: 14)).foregroundStyle(text)
                                        Spacer()
                                        Text("Add").font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                    .background(dark ? Color.white.opacity(0.06) : Color.stockedWhite.opacity(0.35))
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                    .padding(.horizontal, 24)
                                    .padding(.bottom, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .a11yButton("Add \(name) to list", hint: "One of your frequently bought items")
                            }
                        }
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
            }
        }
        .onAppear { rebuildSections() }
        .onChange(of: store.groceryItems) { _, _ in rebuildSections() }
        .onChange(of: searchText) { _, _ in rebuildSections() }
        .onChange(of: showBought) { _, _ in rebuildSections() }   // #235 — segment filter
        .onChange(of: sortAZ) { _, _ in rebuildSections() }        // #245 — sort pill
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
                    let n = store.moveCheckedGroceryToInventory()
                    loopMessage = "Moved \(n) item\(n == 1 ? "" : "s") into your pantry"
                    HapticManager.success()
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        // #235 — mockup's pinned "+ Add Item" button (To Buy only).
        .overlay(alignment: .bottom) {
            if !showBought {
                Button { showQuickAdd = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "plus").font(.system(size: 15, weight: .bold))
                        Text("Add Item").font(.system(size: 15, weight: .bold, design: .serif))
                    }
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 26).padding(.vertical, 14)
                    .background(Color.stockedCharcoal)
                    .clipShape(Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 14)
            }
        }
        .alert("Add Item", isPresented: $showQuickAdd) {
            TextField("Item name", text: $quickAddName)
            Button("Add") {
                let name = quickAddName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty {
                    store.groceryItems.append(LocalGroceryItem(name: name, isChecked: false))
                    HapticManager.success()
                }
                quickAddName = ""
            }
            Button("Cancel", role: .cancel) { quickAddName = "" }
        } message: {
            Text("Add something to your grocery list.")
        }
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
        let isOpen = expanded.contains(section.title)
        let done   = section.items.filter { $0.isChecked }.count
        let total  = section.items.count

        VStack(spacing: 0) {
            // Header — tapping the row toggles; trailing trash removes the whole group.
            HStack(spacing: 0) {
                Button {
                    withAnimation(.spring(response: 0.28)) {
                        if isOpen { expanded.remove(section.title) }
                        else      { expanded.insert(section.title) }
                    }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.stockedGold)
                            .frame(width: 22)
                        Text(section.title)
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(text)
                            .lineLimit(1)
                        Spacer()
                        Text("\(done)/\(total)")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(done == total && total > 0 ? Color.stockedGreen : sub)
                        Image(systemName: isOpen ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11)).foregroundStyle(sub)
                    }
                    .padding(.leading, 14).padding(.vertical, 13)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    pendingDeleteTitle = section.title
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(sub)
                        .padding(.leading, 8).padding(.trailing, 14).padding(.vertical, 13)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove all items in \(section.title)")
            }
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

            // Rows
            if isOpen {
                Divider().padding(.horizontal, 14)
                ForEach(section.items) { item in
                    groceryRow(item)
                    if item.id != section.items.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }

                // Clear checked button
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
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.red.opacity(0.7))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .a11yButton("Clear \(done) checked items", hint: "Removes checked items. You can undo.")
                }
            }
        }
        .background(Color.stockedWhite.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .onAppear { if !expanded.contains(section.title) { expanded.insert(section.title) } }
    }

    // MARK: - Individual row — full cell tappable
    private func groceryRow(_ item: LocalGroceryItem) -> some View {
        Button {
            withAnimation(.spring(response: 0.25)) {
                if let idx = store.groceryItems.firstIndex(where: { $0.id == item.id }) {
                    store.groceryItems[idx].isChecked.toggle()
                    // Light tap confirms the check toggle (#20).
                    HapticManager.light()
                    // Checking off is a strong "I bought this" signal — weight it for usuals.
                    if store.groceryItems[idx].isChecked {
                        GroceryUsuals.shared.record(store.groceryItems[idx].name)
                    }
                }
            }
        } label: {
            HStack(spacing: 12) {
                // Checkmark — #237 mockup style (square check)
                Image(systemName: item.isChecked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20))
                    .foregroundStyle(item.isChecked ? Color.stockedGold : Color.stockedCharcoal.opacity(0.35))
                    .frame(width: 26)
                    .a11yDecorative()

                // #237 — food emoji tile, matching the mockup's grocery rows.
                Text(ImageFallbackService.emoji(for: item.name))
                    .font(.system(size: 17))
                    .frame(width: 24)

                // Item name + source badge
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name.displayNormalized)
                        .font(.system(size: 15)).dynamicTypeSize(.xSmall ... .xxxLarge)
                        .foregroundStyle(item.isChecked ? sub : text)
                        .strikethrough(item.isChecked)
                    HStack(spacing: 4) {
                        if !item.recipeSource.isEmpty {
                            Image(systemName: "fork.knife").font(.system(size: 8))
                            Text(item.recipeSource).font(.system(size: 9, weight: .semibold))
                        } else if item.isRecommended {
                            Image(systemName: "arrow.2.circlepath").font(.system(size: 8))
                            Text("Auto-added").font(.system(size: 9, weight: .semibold))
                        } else {
                            Image(systemName: "hand.point.right").font(.system(size: 8))
                            Text("Manual").font(.system(size: 9, weight: .semibold))
                        }
                        // Sub available hint
                        if StockedDatabase.shared.hasSubstitution(for: item.name) {
                            Text("·").font(.system(size: 8)).foregroundStyle(sub)
                            Image(systemName: "arrow.left.arrow.right").font(.system(size: 7))
                                .foregroundStyle(Color.stockedGold.opacity(0.7))
                            Text("Sub available").font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.stockedGold.opacity(0.7))
                        }
                    }
                    .foregroundStyle(item.recipeSource.isEmpty && !item.isRecommended
                        ? Color.stockedCharcoal.opacity(0.3) : Color.stockedGold.opacity(0.7))
                }

                Spacer()

                // Qty buttons — centred between item and Find in Store
                HStack(spacing: 6) {
                    Button { if item.quantity > 1 { store.updateGroceryQty(id: item.id, qty: item.quantity - 1) } } label: {
                        Image(systemName: "minus.circle").font(.system(size: 18)).foregroundStyle(Color.stockedGold)
                    }.buttonStyle(.plain)
                    Text("\(item.quantity)")
                        .font(.system(size: 13, weight: .bold)).foregroundStyle(Color.stockedGold)
                        .frame(minWidth: 18)
                    Button { store.updateGroceryQty(id: item.id, qty: item.quantity + 1) } label: {
                        Image(systemName: "plus.circle").font(.system(size: 18)).foregroundStyle(Color.stockedGold)
                    }.buttonStyle(.plain)
                }

                // Find in Store
                Button { openInStore(item.name) } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "cart.fill").font(.system(size: 10))
                        Text("Find").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color.stockedGold)
                    .padding(.horizontal, 8).padding(.vertical, 9)
                    .background(Color.stockedGold.opacity(0.12))
                    .clipShape(Capsule())
                }.buttonStyle(.plain)

                Button {
                    undoItem = item
                    withAnimation { store.groceryItems.removeAll { $0.id == item.id } }
                    withAnimation(.spring(response: 0.3)) { showUndo = true }
                    HapticManager.warning()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 12))
                        .foregroundStyle(sub.opacity(0.5))
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
        Text(t).font(.system(size: 11, weight: .bold)).tracking(0.5)
            .foregroundStyle(sub)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 4)
    }

    // MARK: - Quick Store Picker Sheet
    private var quickStorePickerSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    Text("Tap to change your shopping store. Your preference is saved per-item when you use Find in Store.")
                        .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
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
                                    .font(.system(size: 16, weight: session.preferredStore == store ? .bold : .regular, design: .serif))
                                    .foregroundStyle(session.preferredStore == store ? Color.stockedGold : session.themeTextColor)
                                Spacer()
                                if session.preferredStore == store {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.stockedGold).font(.system(size: 20))
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
        withAnimation { store.groceryItems.append(LocalGroceryItem(name: n, isChecked: false)) }
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
                            .font(.system(size: 28)).foregroundStyle(.white.opacity(0.8))
                    }
                    Spacer()
                }.padding()
                Spacer()
                Text(status)
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.55)).clipShape(Capsule())
                Button {
                    NotificationCenter.default.post(name: .captureReceiptShutter, object: nil)
                } label: {
                    Text("Capture List")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(.white).clipShape(Capsule())
                }.padding(.bottom, 36)
            }
        }
    }
}
