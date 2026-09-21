import Foundation
import Observation

@MainActor @Observable final class StockedPhoneWatchBridge {
    static let shared = StockedPhoneWatchBridge()
    var enabled = UserDefaults.standard.object(forKey: "stockedWatchEnabled-v1") as? Bool ?? true
    private(set) var status = "Waiting for Apple Watch"
    private(set) var lastSync: Date?
    @ObservationIgnored private weak var store: GuestDataStore?
    @ObservationIgnored private weak var appSession: AppSession?
    @ObservationIgnored private let transport = KitchenWatchTransport()
    @ObservationIgnored private var journal = KitchenWatch.Journal()
    @ObservationIgnored private var storageReady = true
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var selectedRecipe: UUID?
    @ObservationIgnored private var pages: [String: (String, Int)] = [:]
    @ObservationIgnored private var replyNonce: UUID?

    private init() {
        do { journal = try KitchenWatchDisk.load(KitchenWatch.Journal.self, name: "phone-journal") ?? .init() }
        catch { storageReady = false; status = "Watch delivery history needs repair. Changes are paused." }
    }
    func start(session: AppSession) {
        guard self.store == nil else { return }
        self.appSession = session; self.store = session.guestStore
        transport.receive = { [weak self] data in self?.receive(data) }
        transport.changed = { [weak self] in self?.schedule() }
        transport.start(); observe(); schedule()
    }
    private func observe() {
        guard let store else { return }
        withObservationTracking {
            _ = store.hasCompletedInitialHydration
            _ = [store.inventoryRevision, store.groceryRevision, store.recipeRevision, store.planRevision]
            _ = HouseholdSync.shared.joinCode; _ = HouseholdSync.shared.myPermissions
            _ = appSession?.isLoggedIn; _ = appSession?.forceLogin; _ = appSession?.appleUserID; _ = appSession?.preferredStore
        } onChange: { [weak self] in
            Task { @MainActor in self?.schedule(); self?.observe() }
        }
    }
    func setEnabled(_ value: Bool) {
        enabled = value; UserDefaults.standard.set(value, forKey: "stockedWatchEnabled-v1")
        schedule()
    }
    func schedule() {
        publishTask?.cancel()
        publishTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            self?.publish()
        }
    }
    private func ensureScope() throws {
        let household = HouseholdSync.shared
        let key = ResponseCacheKey.make([household.joinCode ?? "solo", household.memberId, appSession?.appleUserID ?? "", sharing ? "enabled" : "disabled", journal.resetEpoch.uuidString])
        if key != journal.scopeKey { journal.scopeKey = key; journal.scope = UUID(); selectedRecipe = nil; pages.removeAll() }
        try KitchenWatchDisk.save(journal, name: "phone-journal")
    }
    private func receive(_ data: Data) {
        guard let packet = try? KitchenWatch.Packet.decode(data) else { status = "Update Stocked on both devices to connect."; return }
        if let request = packet.request {
            replyNonce = request.nonce
            if let section = request.handoff, ["home", "grocery", "inventory", "recipes", "cook"].contains(section) {
                UserDefaults.standard.set(section, forKey: "stockedWatchHandoff-v1")
            }
            if let section = request.section, ["grocery", "inventory", "recipes", "meals"].contains(section) {
                pages[section] = (KitchenWatch.text(request.query ?? "", limit: 80), max(0, request.offset ?? 0))
            }
            if let recipe = request.recipe { selectedRecipe = recipe }
            publish()
        } else if let command = packet.command {
            process(command)
        }
    }
    private func process(_ command: KitchenWatch.Command) {
        guard let store, store.hasCompletedInitialHydration else { status = "Restoring the kitchen before applying Watch changes."; return }
        do {
            guard storageReady else { throw KitchenWatch.Failure.unavailable }
            try ensureScope()
            if let previous = try journal.prepare(command) { send(previous); publish(); return }
            // Durable intent precedes every side effect. An interrupted attempt is never blindly replayed.
            try KitchenWatchDisk.save(journal, name: "phone-journal")
            let reason = command.validation() ?? (command.scope != journal.scope || !sharing ? "Kitchen changed, you signed out, or Watch sharing is off. Refresh before retrying." : nil)
            var result: KitchenWatch.Result = .accepted
            var message = "Saved on iPhone"
            if let reason { result = .rejected; message = reason }
            else if !HouseholdSync.shared.can(HouseholdPermission(rawValue: command.operation.permission) ?? .view) {
                result = .rejected; message = "Your household permissions do not allow this change."
            } else {
                do { try apply(command, to: store) }
                catch let failure as WatchChangeFailure { result = failure.result; message = failure.message }
                catch { result = .review; message = "Could not confirm the local save. Review the change on iPhone before adding it again." }
            }
            let receipt = KitchenWatch.Receipt(id: command.id, scope: command.scope, result: result, message: message,
                                              snapshotRevision: result == .accepted ? journal.revision &+ 1 : nil)
            journal.finish(receipt)
            try KitchenWatchDisk.save(journal, name: "phone-journal")
            publish(); send(receipt)
        } catch {
            status = "Watch changes are paused because delivery history could not be saved. Retry after freeing storage."
        }
    }
    private struct WatchChangeFailure: Error { let result: KitchenWatch.Result; let message: String }
    private func conflict() -> WatchChangeFailure { .init(result: .conflict, message: "This item changed on iPhone. Refresh and review before trying again.") }
    private func apply(_ command: KitchenWatch.Command, to store: GuestDataStore) throws {
        let encoder = JSONEncoder()
        var key: DBKey
        var data: Data
        switch command.operation {
        case .removeGrocery:
            guard let id = command.target, let row = store.groceryItems.first(where: { $0.id == id }), row.updatedAt == command.baseline else { throw conflict() }
            store.removeGrocery(id: id)
            key = .groceryItems; data = try encoder.encode(store.groceryItems)
        case .addInventory:
            if !store.inventoryItems.contains(where: { $0.id == command.id }) {
                guard !store.inventoryItems.contains(where: { DBNormalize.key($0.name) == DBNormalize.key(command.name!) && $0.zone == command.value }) else {
                    throw WatchChangeFailure(result: .conflict, message: "This item is already in that location. Refresh and edit its quantity.")
                }
                var item = LocalInventoryItem(name: command.name!)
                item.id = command.id; item.quantity = command.number!; item.storageCategory = StorageCategory(rawValue: command.value!)!
                item.lastConfirmedAt = Date(); store.inventoryItems.append(item)
            }
            guard store.inventoryItems.contains(where: { $0.id == command.id }) else { throw conflict() }
            key = .inventoryItems; data = try encoder.encode(store.inventoryItems)
        case .setRecipeFavorite:
            if command.value == "generated" {
                guard let i = store.savedGeneratedRecipes.firstIndex(where: { $0.id == command.target }), store.savedGeneratedRecipes[i].updatedAt == command.baseline else { throw conflict() }
                store.savedGeneratedRecipes[i].isFavorited = command.flag!
                key = .savedGeneratedRecipes; data = try encoder.encode(store.savedGeneratedRecipes)
            } else {
                guard let i = store.userRecipes.firstIndex(where: { $0.id == command.target }), store.userRecipes[i].updatedAt == command.baseline else { throw conflict() }
                var recipe = store.userRecipes[i]; recipe.isFavorited = command.flag!; store.updateUserRecipe(recipe)
                key = .userRecipes; data = try encoder.encode(store.userRecipes)
            }
        case .addGrocery:
            if !store.groceryItems.contains(where: { $0.id == command.id }) {
                guard !GroceryDedup.isDuplicate(command.name!, in: store.groceryItems.map(\.name)) else {
                    throw WatchChangeFailure(result: .conflict, message: "This item is already on the list. Refresh and edit its quantity.")
                }
                store.groceryItems.append(LocalGroceryItem(quantity: command.number!, id: command.id, name: command.name!))
            }
            guard store.groceryItems.contains(where: { $0.id == command.id }) else { throw conflict() }
            key = .groceryItems; data = try encoder.encode(store.groceryItems)
        case .setGroceryChecked, .setGroceryQuantity:
            guard let i = store.groceryItems.firstIndex(where: { $0.id == command.target }), store.groceryItems[i].updatedAt == command.baseline else { throw conflict() }
            if command.operation == .setGroceryChecked { store.groceryItems[i].isChecked = command.flag! }
            else { store.updateGroceryQty(id: store.groceryItems[i].id, qty: command.number!) }
            key = .groceryItems; data = try encoder.encode(store.groceryItems)
        case .setInventoryQuantity, .setInventoryLocation, .setInventoryExpiry:
            guard let id = command.target, let i = store.inventoryIndex(of: id), store.inventoryItems[i].updatedAt == command.baseline else { throw conflict() }
            var items = store.inventoryItems
            switch command.operation {
            case .setInventoryQuantity: items[i].quantity = command.number!; items[i].lastConfirmedAt = Date()
            case .setInventoryLocation: items[i].storageCategory = StorageCategory(rawValue: command.value!)!; items[i].subZone = nil
            default: items[i].expirationDate = command.date
            }
            store.inventoryItems = items
            key = .inventoryItems; data = try encoder.encode(store.inventoryItems)
        case .addMeal, .rescheduleMeal:
            guard let date = command.date,
                  let day = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: Date()), to: Calendar.current.startOfDay(for: date)).day,
                  (0...6).contains(day) else { throw WatchChangeFailure(result: .rejected, message: "Choose today or one of the next six days. Longer plans are available on iPhone.") }
            if command.operation == .addMeal {
                if !store.plannedMeals.contains(where: { $0.id == command.id }) {
                    var meal = PlannedMeal(dayIndex: day, title: command.name!, servings: command.number!, ingredients: [], mealType: command.value!)
                    meal.id = command.id; store.plannedMeals.append(meal)
                }
            } else {
                guard let i = store.plannedMeals.firstIndex(where: { $0.id == command.target }), store.plannedMeals[i].updatedAt == command.baseline else { throw conflict() }
                var meals = store.plannedMeals; meals[i].dayIndex = day; meals[i].mealType = command.value!; store.plannedMeals = meals
            }
            key = .plannedMeals; data = try encoder.encode(store.plannedMeals)
        }
        // Existing array didSets own permission checks, journal/sync and widget updates.
        store.flushPendingSaves()
        try LocalDatabase.shared.saveDataDurably(data, key: key.rawValue)
    }
    private func send(_ receipt: KitchenWatch.Receipt) {
        if let data = try? KitchenWatch.Packet(receipt: receipt).encoded() { transport.send(data, durableID: receipt.id) }
    }
    func publish() {
        guard let store, store.hasCompletedInitialHydration, transport.ready else { return }
        do {
            guard storageReady else { throw KitchenWatch.Failure.unavailable }
            try ensureScope(); journal.revision &+= 1
            try KitchenWatchDisk.save(journal, name: "phone-journal")
            var snapshot = snapshot(store); snapshot.handshake = replyNonce
            transport.context(try KitchenWatch.bounded(snapshot))
            replyNonce = nil
            lastSync = snapshot.date
            status = transport.failure ?? (transport.reachable ? "Connected to Apple Watch" : "Latest kitchen queued for Apple Watch")
        } catch { status = "Could not prepare a Watch snapshot. Your iPhone kitchen is unchanged." }
    }
    private func slice<T>(_ rows: [T], section: String, size: Int, name: (T) -> String) -> ([T], Int, Int, String) {
        let page = pages[section] ?? ("", 0)
        let filtered = page.0.isEmpty ? rows : rows.filter { name($0).localizedCaseInsensitiveContains(page.0) }
        let offset = min(max(0, filtered.count - 1), max(0, page.1))
        return (Array(filtered.dropFirst(offset).prefix(size)), filtered.count, offset, page.0)
    }
    private func snapshot(_ store: GuestDataStore) -> KitchenWatch.Snapshot {
        let now = Date()
        guard sharing else { return .init(scope: journal.scope, revision: journal.revision, date: now, enabled: false, grocery: [], inventory: [], recipes: [], meals: [], detail: nil, permissions: [], totals: [0,0,0,0], notice: "Open Stocked on iPhone, sign in and enable Watch sharing.") }
        let groceries = slice(store.groceryItems.sorted { $0.isChecked == $1.isChecked ? $0.name < $1.name : !$0.isChecked }, section: "grocery", size: 80, name: { $0.name })
        let inventory = slice(store.inventoryItems.sorted { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }, section: "inventory", size: 60, name: { $0.name })
        let summaries = store.userRecipes.map { KitchenWatch.Recipe(id: $0.id, title: KitchenWatch.text($0.title), time: KitchenWatch.text($0.cookTime, limit: 40), servings: $0.servings, favorite: $0.isFavorited, generated: false) }
            + store.savedGeneratedRecipes.filter { !$0.isHidden }.map { KitchenWatch.Recipe(id: $0.id, title: KitchenWatch.text($0.title), time: KitchenWatch.text($0.cookTime, limit: 40), servings: $0.servings, favorite: $0.isFavorited, generated: true) }
        let recipes = slice(summaries.sorted { $0.favorite == $1.favorite ? $0.title < $1.title : $0.favorite }, section: "recipes", size: 30, name: { $0.title })
        var detail: KitchenWatch.RecipeDetail?
        if let id = selectedRecipe ?? recipes.0.first?.id {
            if let recipe = store.userRecipes.first(where: { $0.id == id }) {
                detail = recipeDetail(id: id, title: recipe.title, servings: recipe.servings, ingredients: recipe.ingredients.map { $0.amount + " " + $0.name }, steps: recipe.instructions, source: recipe.sourceName ?? "Saved recipe")
                detail?.favorite = recipe.isFavorited; detail?.revision = recipe.updatedAt
            } else if let recipe = store.savedGeneratedRecipes.first(where: { $0.id == id && !$0.isHidden }) {
                detail = recipeDetail(id: id, title: recipe.title, servings: recipe.servings, ingredients: recipe.ingredients.map { $0.amount + " " + $0.name }, steps: recipe.steps, source: "Saved generated recipe")
                detail?.favorite = recipe.isFavorited; detail?.revision = recipe.updatedAt; detail?.generated = true
            }
        }
        let meals = slice(store.plannedMeals.filter { (0...6).contains($0.dayIndex) }.sorted { $0.dayIndex == $1.dayIndex ? $0.id.uuidString < $1.id.uuidString : $0.dayIndex < $1.dayIndex }, section: "meals", size: 20, name: { $0.title })
        return .init(scope: journal.scope, revision: journal.revision, date: now, enabled: true,
            grocery: groceries.0.map { .init(id: $0.id, name: KitchenWatch.text($0.name), quantity: $0.quantity, checked: $0.isChecked, size: KitchenWatch.text($0.sizeText, limit: 80), revision: $0.updatedAt.isFinite ? $0.updatedAt : 0) },
            inventory: inventory.0.map { .init(id: $0.id, name: KitchenWatch.text($0.name), quantity: $0.quantity, location: $0.zone, expiry: $0.expirationDate, low: $0.isLow, revision: $0.updatedAt.isFinite ? $0.updatedAt : 0) },
            recipes: recipes.0, meals: meals.0.map { .init(id: $0.id, title: KitchenWatch.text($0.title), date: Calendar.current.date(byAdding: .day, value: $0.dayIndex, to: Calendar.current.startOfDay(for: now)) ?? now, slot: $0.mealType, servings: $0.servings, cooked: $0.isCooked, revision: $0.updatedAt.isFinite ? $0.updatedAt : 0) },
            detail: detail, permissions: HouseholdPermission.allCases.filter { ["view", "groceryAdd", "groceryEdit", "groceryRemove", "inventoryAdd", "inventoryEdit", "recipeEdit", "mealPlanEdit"].contains($0.rawValue) && HouseholdSync.shared.can($0) }.map(\.rawValue),
            totals: [groceries.1, inventory.1, recipes.1, meals.1], limited: groceries.1 > groceries.0.count || inventory.1 > inventory.0.count || recipes.1 > recipes.0.count || meals.1 > meals.0.count,
            offsets: ["grocery": groceries.2, "inventory": inventory.2, "recipes": recipes.2, "meals": meals.2], queries: ["grocery": groceries.3, "inventory": inventory.3, "recipes": recipes.3, "meals": meals.3], preferredStore: KitchenWatch.text(appSession?.preferredStore ?? "", limit: 80))
    }
    private func recipeDetail(id: UUID, title: String, servings: Int, ingredients: [String], steps: [String], source: String) -> KitchenWatch.RecipeDetail {
        let tooLarge = ingredients.count > 80 || steps.count > 60 || ingredients.contains { $0.count > 300 } || steps.contains { $0.count > 1200 }
        return .init(id: id, title: KitchenWatch.text(title), servings: servings,
                     ingredients: Array(ingredients.prefix(80)).map { KitchenWatch.text($0, limit: 300) },
                     steps: tooLarge ? [] : steps, incomplete: tooLarge, source: KitchenWatch.text(source))
    }
    func consumeHandoff() {
        guard let section = UserDefaults.standard.string(forKey: "stockedWatchHandoff-v1") else { return }
        UserDefaults.standard.removeObject(forKey: "stockedWatchHandoff-v1")
        let tab: StockedTab = switch section {
        case "grocery": .grocery
        case "inventory": .inventory
        case "recipes": .recipes
        case "cook": .cook
        default: .home
        }
        NotificationCenter.default.post(name: .stockedSwitchTab, object: tab)
    }
    private var sharing: Bool { enabled && appSession?.isLoggedIn == true && appSession?.forceLogin == false && HouseholdSync.shared.can(.view) }
    func invalidateKitchen() throws {
        do {
            try journal.retire { try KitchenWatchDisk.save($0, name: "phone-journal") }
            selectedRecipe = nil; pages.removeAll(); schedule()
        } catch {
            status = "Reset stopped: Watch delivery history could not be saved. Free storage and try again."
            throw ResetFailure()
        }
    }
    private struct ResetFailure: LocalizedError {
        var errorDescription: String? { "Reset stopped because Watch delivery history could not be saved. Free storage and try again; your kitchen has not been erased." }
    }
}
