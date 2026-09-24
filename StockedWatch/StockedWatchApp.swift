import SwiftUI
import WatchConnectivity

@main struct StockedWatchApp: App {
    @State private var store = StockedWatchStore()
    @State private var timer = StockedWatchTimer()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            NavigationStack { WatchKitchenHome() }
                .environment(store).environment(timer)
                .tint(Color(red: 0.835, green: 0.702, blue: 0.420))
                .alert("Change needs attention", isPresented: Binding(get: { store.operationIssue != nil }, set: { if !$0 { store.operationIssue = nil } })) {
                    Button("OK", role: .cancel) { store.operationIssue = nil }
                } message: { Text(store.operationIssue ?? "") }
                .onChange(of: phase) { _, phase in if phase == .active { store.active() } }
        }
        .backgroundTask(.watchConnectivity) {
            await store.drainBackgroundDelivery()
        }
    }
}

struct WatchKitchenHome: View {
    @Environment(StockedWatchStore.self) private var store
    @Environment(StockedWatchTimer.self) private var timer
    var body: some View {
        List {
            Section {
                if let snapshot = store.snapshot {
                    Label(snapshot.enabled ? "Your kitchen" : "Sharing paused", systemImage: snapshot.enabled ? "leaf.fill" : "pause.circle")
                    Text("Updated \(snapshot.date, style: .relative) ago").font(.caption2).foregroundStyle(.secondary)
                } else { Text("Open Stocked on your paired iPhone to bring your kitchen to Watch.").font(.footnote) }
            }
            NavigationLink { WatchGroceryList() } label: { Label("Grocery list", systemImage: "cart") }
            NavigationLink { WatchInventoryList() } label: { Label("Inventory", systemImage: "refrigerator") }
            NavigationLink { WatchRecipeList() } label: { Label("Recipes", systemImage: "book.closed") }
            NavigationLink { WatchMeals() } label: { Label("Meal plan", systemImage: "calendar") }
            NavigationLink { WatchTimerView() } label: { Label(timer.running ? "Timer running" : "Kitchen timer", systemImage: "timer") }
            NavigationLink { WatchTools() } label: { Label("Kitchen tools", systemImage: "scalemass") }
            NavigationLink { WatchSyncSettings() } label: { Label(store.pending.isEmpty ? "Connection & settings" : "\(store.pending.count) queued changes", systemImage: "applewatch.radiowaves.left.and.right") }
        }.navigationTitle("Stocked")
    }
}

struct WatchPageControls: View {
    @Environment(StockedWatchStore.self) private var store
    let section: String; let totalIndex: Int; let pageSize: Int
    @State private var search = ""
    var body: some View {
        Section {
            TextField("Search all \(section)", text: $search).onSubmit { find() }
            Button("Search") { find() }.disabled(!store.reachable)
            let offset = store.snapshot?.offsets[section] ?? 0
            let total = store.snapshot?.totals[safe: totalIndex] ?? 0
            let delivered = store.snapshot?.deliveredCount(for: section) ?? 0
            Text(total == 0 ? "No matches" : "\(offset + 1)–\(offset + delivered) of \(total)").font(.caption2).foregroundStyle(.secondary)
            HStack {
                Button("Previous") { store.refresh(section: section, query: store.snapshot?.queries[section], offset: max(0, offset - pageSize)) }.disabled(offset == 0 || !store.reachable)
                Button("Next") { store.refresh(section: section, query: store.snapshot?.queries[section], offset: store.snapshot?.nextOffset(for: section)) }.disabled(delivered == 0 || offset + delivered >= total || !store.reachable)
            }
            if store.snapshot?.limited == true { Text("Showing one downloaded page. Connect iPhone to search or load other pages.").font(.caption2).foregroundStyle(.secondary) }
        }
    }
    private func find() { store.refresh(section: section, query: KitchenWatch.text(search, limit: 80), offset: 0) }
}
private extension Array { subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil } }

struct WatchGroceryList: View {
    @Environment(StockedWatchStore.self) private var store
    @State private var showBought = false
    var body: some View {
        List {
            if let preferred = store.snapshot?.preferredStore, !preferred.isEmpty { Label(preferred, systemImage: "storefront").font(.headline) }
            NavigationLink("Add an item") { WatchAddGrocery() }.disabled(!store.can(.addGrocery))
            Toggle("Show bought", isOn: $showBought)
            ForEach((store.snapshot?.grocery ?? []).filter { showBought || !$0.checked }) { item in
                HStack {
                    let pending = store.pending.first { $0.target == item.id }
                    Button {
                        store.send(.setGroceryChecked, target: item.id, baseline: item.revision, flag: !item.checked)
                    } label: { Image(systemName: (pending?.flag ?? item.checked) ? "checkmark.circle.fill" : "circle").font(.title3) }
                    .buttonStyle(.plain).frame(minWidth: 40, minHeight: 44)
                    .disabled(store.changing(item.id) || !store.can(.setGroceryChecked))
                    .accessibilityLabel("\(item.checked ? "Uncheck" : "Check") \(item.name)")
                    NavigationLink { WatchGroceryDetail(item: item) } label: {
                        VStack(alignment: .leading) {
                            Text(item.name).fixedSize(horizontal: false, vertical: true)
                            Text("\(pending?.number ?? item.quantity) \(item.size)").font(.caption2).foregroundStyle(.secondary)
                            if pending != nil { Text("Queued").font(.caption2).foregroundStyle(.tint) }
                        }
                    }
                }
            }
            if store.snapshot?.grocery.isEmpty != false { Text("Your downloaded list is empty. Add an item or refresh from iPhone.").font(.footnote) }
            WatchPageControls(section: "grocery", totalIndex: 0, pageSize: 80)
        }.navigationTitle("Grocery")
    }
}
struct WatchAddGrocery: View {
    @Environment(StockedWatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""; @State private var quantity = 1
    var body: some View {
        Form {
            TextField("Item name", text: $name)
            Stepper("Quantity: \(quantity)", value: $quantity, in: 1...999)
            Button("Add to grocery list") {
                let before = store.pending.count
                store.send(.addGrocery, name: KitchenWatch.text(name), number: quantity)
                if store.pending.count > before { dismiss() }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.can(.addGrocery))
            Text("Changes wait for iPhone. An existing item is flagged for review instead of silently increasing its quantity.").font(.caption2).foregroundStyle(.secondary)
        }.navigationTitle("Add item")
    }
}
struct WatchGroceryDetail: View {
    @Environment(StockedWatchStore.self) private var store
    private let initial: KitchenWatch.Grocery
    init(item: KitchenWatch.Grocery) { initial = item }
    private var live: KitchenWatch.Grocery? { store.snapshot?.grocery.first { $0.id == initial.id } }
    private var item: KitchenWatch.Grocery { live ?? initial }
    @State private var quantity = 1
    @State private var confirmRemove = false
    var body: some View {
        Form {
            if live == nil { Text("This item is no longer in the downloaded page. Return to the list and refresh.").font(.caption2) }
            Text(item.name).font(.headline)
            Text("Saved quantity: \(item.quantity)")
            Stepper("New quantity: \(quantity)", value: $quantity, in: 1...999)
            Button("Save quantity") { store.send(.setGroceryQuantity, target: item.id, baseline: item.revision, number: quantity) }
                .disabled(store.changing(item.id) || !store.can(.setGroceryQuantity))
            if store.changing(item.id) { Text("Queued; waiting for iPhone confirmation.").font(.caption2) }
            Button("Remove item", role: .destructive) { confirmRemove = true }.disabled(store.changing(item.id) || !store.can(.removeGrocery))
        }.disabled(live == nil).navigationTitle("Grocery item").onAppear { quantity = min(999,max(1,item.quantity)) }
        .confirmationDialog("Remove \(item.name) from the grocery list?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { store.send(.removeGrocery, target: item.id, baseline: item.revision) }
        }
    }
}

struct WatchInventoryList: View {
    @Environment(StockedWatchStore.self) private var store
    @State private var location = "All"
    var body: some View {
        List {
            NavigationLink("Add inventory item") { WatchAddInventory() }.disabled(!store.can(.addInventory))
            Picker("Location", selection: $location) { ForEach(["All"] + KitchenWatch.locations, id: \.self) { Text($0).tag($0) } }
            ForEach((store.snapshot?.inventory ?? []).filter { location == "All" || $0.location == location }) { item in
                NavigationLink { WatchInventoryDetail(item: item) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.name)
                        Text("\(item.quantity) · \(item.location)").font(.caption2).foregroundStyle(.secondary)
                        if let expiry = item.expiry { Text("Expires \(expiry, style: .date)").font(.caption2) }
                        if item.low { Label("Low stock", systemImage: "exclamationmark.circle").font(.caption2).foregroundStyle(.yellow) }
                    }
                }
            }
            WatchPageControls(section: "inventory", totalIndex: 1, pageSize: 60)
            Button("Add or scan on iPhone") { store.handoff("inventory") }
        }.navigationTitle("Inventory")
    }
}
struct WatchAddInventory: View {
    @Environment(StockedWatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""; @State private var location = "Pantry"; @State private var quantity = 1
    var body: some View {
        Form {
            TextField("Item name", text: $name)
            Picker("Location", selection: $location) { ForEach(KitchenWatch.locations, id: \.self) { Text($0).tag($0) } }
            Stepper("\(quantity) containers", value: $quantity, in: 1...999)
            Button("Add inventory item") {
                let before = store.pending.count
                store.send(.addInventory, name: KitchenWatch.text(name), number: quantity, value: location)
                if store.pending.count > before { dismiss() }
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !store.can(.addInventory))
            Text("Add expiry after syncing. Scanning and nutrition details remain on iPhone.").font(.caption2).foregroundStyle(.secondary)
        }.navigationTitle("Add inventory")
    }
}
struct WatchInventoryDetail: View {
    @Environment(StockedWatchStore.self) private var store
    private let initial: KitchenWatch.Inventory
    init(item: KitchenWatch.Inventory) { initial = item }
    private var live: KitchenWatch.Inventory? { store.snapshot?.inventory.first { $0.id == initial.id } }
    private var item: KitchenWatch.Inventory { live ?? initial }
    @State private var quantity = 1; @State private var location = "Pantry"; @State private var expiryDays = 3
    var body: some View {
        Form {
            if live == nil { Text("This item is no longer in the downloaded page. Return to the list and refresh.").font(.caption2) }
            Text(item.name).font(.headline)
            Text("Saved: \(item.quantity) · \(item.location)").font(.caption)
            Section("Quantity") {
                Stepper("\(quantity) containers", value: $quantity, in: 0...999)
                Button("Save quantity") { store.send(.setInventoryQuantity, target: item.id, baseline: item.revision, number: quantity) }
            }.disabled(store.changing(item.id) || !store.can(.setInventoryQuantity))
            Section("Storage") {
                Picker("Move to", selection: $location) { ForEach(KitchenWatch.locations, id: \.self) { Text($0).tag($0) } }
                Button("Move item") { store.send(.setInventoryLocation, target: item.id, baseline: item.revision, value: location) }
            }.disabled(store.changing(item.id) || !store.can(.setInventoryLocation))
            Section("Expiry") {
                if let date = item.expiry { Text(date, style: .date) } else { Text("No expiry saved") }
                Stepper("In \(expiryDays) days", value: $expiryDays, in: 0...365)
                Button("Set expiry") { store.send(.setInventoryExpiry, target: item.id, baseline: item.revision, date: Calendar.current.date(byAdding: .day, value: expiryDays, to: Date())) }
                Button("Clear expiry") { store.send(.setInventoryExpiry, target: item.id, baseline: item.revision) }
                Text("Use the package date. Stocked does not infer food safety.").font(.caption2).foregroundStyle(.secondary)
            }.disabled(store.changing(item.id) || !store.can(.setInventoryExpiry))
            if store.changing(item.id) { Text("Change queued. Saved details update when iPhone confirms it.").font(.caption2) }
        }.disabled(live == nil).navigationTitle("Inventory item").onAppear { quantity = min(999,max(0,item.quantity)); location = item.location }
    }
}

struct WatchRecipeList: View {
    @Environment(StockedWatchStore.self) private var store
    var body: some View {
        List {
            ForEach(store.snapshot?.recipes ?? []) { recipe in
                NavigationLink { WatchRecipeDetail(id: recipe.id) } label: {
                    VStack(alignment: .leading) {
                        Text(recipe.title)
                        Text("\(recipe.time) · \(recipe.servings) servings").font(.caption2).foregroundStyle(.secondary)
                        if recipe.favorite { Label("Favorite", systemImage: "star.fill").font(.caption2) }
                    }
                }
            }
            WatchPageControls(section: "recipes", totalIndex: 2, pageSize: 30)
            Button("Discover or import on iPhone") { store.handoff("recipes") }
        }.navigationTitle("Saved recipes")
    }
}
struct WatchRecipeDetail: View {
    @Environment(StockedWatchStore.self) private var store
    @Environment(StockedWatchTimer.self) private var timer
    let id: UUID
    @State private var checked = Set<Int>()
    var body: some View {
        List {
            if let recipe = store.recipe(id) {
                Text(recipe.title).font(.headline)
                Text("\(recipe.servings) servings · \(recipe.source)").font(.caption2).foregroundStyle(.secondary)
                Button(recipe.favorite ? "Remove favorite" : "Favorite recipe") {
                    store.send(.setRecipeFavorite, target: recipe.id, baseline: recipe.revision, flag: !recipe.favorite, value: recipe.generated ? "generated" : "saved")
                }.disabled(store.changing(recipe.id) || !store.can(.setRecipeFavorite))
                if recipe.incomplete {
                    Text("This recipe is too large for complete Watch instructions. Continue on iPhone.")
                    Button("Continue on iPhone") { store.handoff("recipes") }
                } else {
                    Section("Ingredients") {
                        ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { index, ingredient in
                            Button { if !checked.insert(index).inserted { checked.remove(index) } } label: {
                                Label(ingredient, systemImage: checked.contains(index) ? "checkmark.circle.fill" : "circle")
                            }.buttonStyle(.plain)
                        }
                    }
                    if !recipe.steps.isEmpty {
                        let index = min(store.step(id), recipe.steps.count - 1)
                        Section("Step \(index + 1) of \(recipe.steps.count)") {
                            Text(recipe.steps[index]).fixedSize(horizontal: false, vertical: true)
                            if let duration = CookingTimerPolicy.detectSeconds(in: recipe.steps[index]), duration <= 86400 {
                                NavigationLink { WatchTimerView() } label: { Text("Timer: \(CookingTimerPolicy.display(duration))") }
                                Button(timer.running ? "Replace running timer" : "Start step timer") { timer.start(seconds: Double(duration), title: "Step \(index + 1) timer") }
                            }
                            HStack {
                                Button("Back") { store.setStep(index - 1, recipe: id, total: recipe.steps.count) }.disabled(index == 0)
                                Button("Next") { store.setStep(index + 1, recipe: id, total: recipe.steps.count) }.disabled(index + 1 >= recipe.steps.count)
                            }
                        }
                    } else { Text("No instructions saved. Edit this recipe on iPhone.") }
                    Text("Step progress and ingredient checks stay on this Watch. Cooking does not automatically deduct stock.").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text(store.reachable ? "Requesting recipe from iPhone…" : "Connect iPhone once to download these instructions.")
                Button("Retry download") { store.refresh(recipe: id) }
            }
        }.navigationTitle("Cook").task { store.refresh(recipe: id) }
    }
}

struct WatchMeals: View {
    @Environment(StockedWatchStore.self) private var store
    var body: some View {
        List {
            NavigationLink("Plan a meal") { WatchMealForm(meal: nil) }.disabled(!store.can(.addMeal))
            ForEach(store.snapshot?.meals ?? []) { meal in
                NavigationLink { WatchMealForm(meal: meal) } label: {
                    VStack(alignment: .leading) {
                        Text(meal.title)
                        Text("\(meal.date, style: .date) · \(meal.slot)").font(.caption2)
                        Text(meal.cooked ? "Cooked" : "\(meal.servings) servings").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            WatchPageControls(section: "meals", totalIndex: 3, pageSize: 20)
            Text("Current week. Ingredient assignments, longer schedules and the cooked-meal stock review are on iPhone.").font(.caption2).foregroundStyle(.secondary)
            Button("Continue planning on iPhone") { store.handoff("cook") }
        }.navigationTitle("Meal plan")
    }
}
struct WatchMealForm: View {
    @Environment(StockedWatchStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    private let initial: KitchenWatch.Meal?
    init(meal: KitchenWatch.Meal?) { initial = meal }
    private var live: KitchenWatch.Meal? { store.snapshot?.meals.first { $0.id == initial?.id } }
    private var meal: KitchenWatch.Meal? { live ?? initial }
    @State private var title = ""; @State private var day = 0; @State private var slot = "Dinner"; @State private var servings = 2
    var body: some View {
        Form {
            if initial != nil && live == nil { Text("This meal is no longer in the downloaded page. Return to the plan and refresh.").font(.caption2) }
            if let meal { Text(meal.title).font(.headline) } else { TextField("Meal name", text: $title) }
            Picker("Day", selection: $day) { ForEach(0..<7) { value in Text(value == 0 ? "Today" : value == 1 ? "Tomorrow" : "In \(value) days").tag(value) } }
            Picker("Meal", selection: $slot) { ForEach(KitchenWatch.mealTypes, id: \.self) { Text($0).tag($0) } }
            if meal == nil { Stepper("\(servings) servings", value: $servings, in: 1...99) }
            Button(meal == nil ? "Add meal" : "Reschedule") {
                let before = store.pending.count
                store.send(meal == nil ? .addMeal : .rescheduleMeal, target: meal?.id, baseline: meal?.revision,
                           name: meal == nil ? KitchenWatch.text(title) : nil, number: servings, value: slot,
                           date: Calendar.current.date(byAdding: .day, value: day, to: Calendar.current.startOfDay(for: Date())))
                if meal == nil && store.pending.count > before { dismiss() }
            }.disabled(!store.can(.addMeal) || (meal == nil && title.trimmingCharacters(in: .whitespaces).isEmpty) || (meal.map { store.changing($0.id) } ?? false))
            if meal == nil { Text("Adds a named meal. Link ingredients on iPhone when ready.").font(.caption2).foregroundStyle(.secondary) }
        }.disabled(initial != nil && live == nil).navigationTitle(meal == nil ? "Plan meal" : "Reschedule").onAppear {
            if let meal { slot = meal.slot; day = min(6,max(0,Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: meal.date).day ?? 0)) }
        }
    }
}

struct WatchTimerView: View {
    @Environment(StockedWatchTimer.self) private var timer
    @State private var minutes = 5
    var body: some View {
        List {
            TimelineView(.periodic(from: Date(), by: 1)) { _ in
                VStack(alignment: .leading) {
                    Text(timer.state.title).font(.headline)
                    Text(CookingTimerPolicy.display(Int(timer.remaining.rounded(.up)))).font(.system(.largeTitle, design: .rounded).monospacedDigit()).minimumScaleFactor(0.7)
                    Text(timer.finished ? "Finished" : timer.running ? "Running" : "Ready / paused").font(.caption)
                }.accessibilityElement(children: .combine)
            }
            if timer.running { Button("Pause") { timer.pause() } }
            else if !timer.finished { Button("Resume") { timer.resume() } }
            Button("Reset") { timer.reset() }
            Stepper("\(minutes) minutes", value: $minutes, in: 1...1440)
            Button(timer.running ? "Replace with new timer" : "Start timer") { timer.start(seconds: Double(minutes) * 60) }
            if let notice = timer.notice { Text(notice).font(.caption2) }
            Text("One saved Watch timer. Notifications provide the background alert; Focus and system delivery settings still apply.").font(.caption2).foregroundStyle(.secondary)
        }.navigationTitle("Timer")
    }
}
struct WatchTools: View {
    @State private var amount = "1"; @State private var from = "cup"; @State private var to = "ml"
    @State private var original = 4; @State private var desired = 2
    private let units = ["cup", "tbsp", "tsp", "ml", "l", "fl oz", "g", "kg", "oz", "lb"]
    var body: some View {
        Form {
            Section("Unit converter") {
                TextField("Amount", text: $amount)
                Picker("From", selection: $from) { ForEach(units, id: \.self) { Text($0).tag($0) } }
                Picker("To", selection: $to) { ForEach(units, id: \.self) { Text($0).tag($0) } }
                if let number = KitchenMathCore.parse(amount), let converted = UnitMath.convert(number, from: from, to: to), converted.isFinite {
                    Text("\(converted.formatted(.number.precision(.significantDigits(1...6)))) \(to)").font(.headline)
                } else { Text("Use a finite nonnegative number and compatible units. Density is not guessed.").font(.caption2) }
            }
            Section("Portion multiplier") {
                Stepper("Recipe serves \(original)", value: $original, in: 1...99)
                Stepper("Want \(desired) servings", value: $desired, in: 1...99)
                Text("Multiply ingredients by \((Double(desired) / Double(original)).formatted(.number.precision(.fractionLength(0...3))))").font(.headline)
                Text("Cooking time does not scale automatically.").font(.caption2).foregroundStyle(.secondary)
            }
        }.navigationTitle("Kitchen tools")
    }
}
struct WatchSyncSettings: View {
    @Environment(StockedWatchStore.self) private var store
    var body: some View {
        List {
            Text(store.reachable ? "iPhone connected" : "Using downloaded information")
            if let date = store.snapshot?.date { Text("Updated \(date, style: .relative) ago").font(.caption2) }
            Button("Refresh kitchen") { store.active() }
            if let message = store.message { Text(message).font(.footnote).foregroundStyle(.secondary) }
            Section("Queued changes · \(store.pending.count)/64") {
                ForEach(store.pending) { command in
                    VStack(alignment: .leading) {
                        Text(command.name ?? command.operation.rawValue)
                        Text("Queued \(command.created, style: .relative) ago").font(.caption2)
                    }
                }
                Text("Changes expire after seven days. Do not add the same item again while its change is waiting.").font(.caption2).foregroundStyle(.secondary)
            }
            Section("Delivery history") {
                ForEach(store.saved.outbox.history) { receipt in
                    Label(receipt.message, systemImage: receipt.result == .accepted ? "checkmark.circle" : "exclamationmark.circle").font(.footnote)
                }
            }
            Button("Clear downloaded kitchen", role: .destructive) { store.clearDownloads() }.disabled(!store.pending.isEmpty)
            Text("This removes Watch copies only. Control sharing in iPhone Settings → Data & Storage → Apple Watch. Scanning, imports, AI and provider setup remain on iPhone.").font(.caption2).foregroundStyle(.secondary)
        }.navigationTitle("Connection")
    }
}
