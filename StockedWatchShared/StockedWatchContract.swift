import Foundation

/// Private paired-device transport. No Worker credentials, household codes, photos or raw imports.
nonisolated enum KitchenWatch {
    static let version = 1
    static let wireLimit = 60 * 1024
    static let queueLimit = 64
    static let validity: TimeInterval = 7 * 86400
    static let locations = ["Fridge", "Freezer", "Pantry", "Staples"]
    static let mealTypes = ["Breakfast", "Lunch", "Dinner", "Snack"]
    static func text(_ value: String, limit: Int = 160) -> String {
        String(value.trimmingCharacters(in: .whitespacesAndNewlines).prefix(limit))
    }
    struct Grocery: Codable, Identifiable, Equatable, Sendable {
        var id: UUID; var name: String; var quantity: Int; var checked: Bool; var size: String; var revision: Double
    }
    struct Inventory: Codable, Identifiable, Equatable, Sendable {
        var id: UUID; var name: String; var quantity: Int; var location: String; var expiry: Date?; var low: Bool; var revision: Double
    }
    struct Recipe: Codable, Identifiable, Equatable, Sendable {
        var id: UUID; var title: String; var time: String; var servings: Int; var favorite: Bool; var generated: Bool
    }
    struct RecipeDetail: Codable, Identifiable, Equatable, Sendable {
        var id: UUID; var title: String; var servings: Int; var ingredients: [String]; var steps: [String]
        var incomplete: Bool; var source: String
        var favorite: Bool = false; var revision: Double = 0; var generated: Bool = false
    }
    struct Meal: Codable, Identifiable, Equatable, Sendable {
        var id: UUID; var title: String; var date: Date; var slot: String; var servings: Int; var cooked: Bool; var revision: Double
    }
    struct Snapshot: Codable, Equatable, Sendable {
        var scope: UUID; var revision: UInt64; var date: Date; var enabled: Bool
        var grocery: [Grocery]; var inventory: [Inventory]; var recipes: [Recipe]; var meals: [Meal]
        var detail: RecipeDetail?; var permissions: [String]; var totals: [Int]; var limited: Bool = false
        var notice: String = ""
        var offsets: [String: Int] = [:]; var queries: [String: String] = [:]
        var handshake: UUID? = nil
        var preferredStore: String = ""
        var isValid: Bool {
            Self.validDate(date) && grocery.count <= 160 && inventory.count <= 120
                && recipes.count <= 40 && meals.count <= 40 && permissions.count <= 12 && totals.count == 4
                && totals.allSatisfy { $0 >= 0 } && preferredStore.count <= 80 && notice.count <= 300
                && offsets.count <= 4 && offsets.allSatisfy { ["grocery", "inventory", "recipes", "meals"].contains($0.key) && (0...(Int.max - 160)).contains($0.value) }
                && queries.count <= 4 && queries.allSatisfy { ["grocery", "inventory", "recipes", "meals"].contains($0.key) && $0.value.count <= 80 }
                && grocery.allSatisfy { $0.revision.isFinite && $0.revision >= 0 && $0.quantity >= 0 && $0.name.count <= 160 && $0.size.count <= 80 }
                && inventory.allSatisfy { $0.revision.isFinite && $0.revision >= 0 && $0.quantity >= 0 && $0.name.count <= 160 && $0.location.count <= 32 && ($0.expiry == nil || Self.validDate($0.expiry!)) }
                && recipes.allSatisfy { $0.title.count <= 160 && $0.time.count <= 40 }
                && meals.allSatisfy { $0.title.count <= 160 && Self.validDate($0.date) && $0.revision.isFinite && $0.revision >= 0 && $0.slot.count <= 32 }
                && (detail == nil || (detail!.title.count <= 160 && detail!.source.count <= 160 && detail!.revision.isFinite && detail!.revision >= 0 && detail!.steps.count <= 60 && detail!.ingredients.count <= 80 && detail!.steps.allSatisfy { $0.count <= 1200 } && detail!.ingredients.allSatisfy { $0.count <= 300 }))
        }
        private static func validDate(_ date: Date) -> Bool { date.timeIntervalSince1970.isFinite && abs(date.timeIntervalSince1970) <= 40_000_000_000 }
        func deliveredCount(for section: String) -> Int {
            switch section { case "grocery": grocery.count; case "inventory": inventory.count; case "recipes": recipes.count; case "meals": meals.count; default: 0 }
        }
        func nextOffset(for section: String) -> Int { (offsets[section] ?? 0) + deliveredCount(for: section) }
    }

    enum Operation: String, Codable, Sendable {
        case addGrocery, removeGrocery, setGroceryChecked, setGroceryQuantity, addInventory, setInventoryQuantity, setInventoryLocation, setInventoryExpiry, setRecipeFavorite, addMeal, rescheduleMeal
        var permission: String {
            switch self {
            case .addGrocery: "groceryAdd"
            case .removeGrocery: "groceryRemove"
            case .addInventory: "inventoryAdd"
            case .setRecipeFavorite: "recipeEdit"
            case .setGroceryChecked, .setGroceryQuantity: "groceryEdit"
            case .setInventoryQuantity, .setInventoryLocation, .setInventoryExpiry: "inventoryEdit"
            case .addMeal, .rescheduleMeal: "mealPlanEdit"
            }
        }
    }
    struct Command: Codable, Identifiable, Equatable, Sendable {
        var id = UUID(); var scope: UUID; var created = Date(); var operation: Operation
        var target: UUID?; var baseline: Double?; var name: String?; var number: Int?; var flag: Bool?; var value: String?; var date: Date?
        func validation(now: Date = Date()) -> String? {
            let age = now.timeIntervalSince(created)
            guard age.isFinite, age >= -300, age <= KitchenWatch.validity else { return "This change expired. Refresh and try again." }
            if let baseline, !baseline.isFinite || baseline < 0 { return "Invalid item version." }
            if let name, name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || name.count > 160 || name.contains(where: \.isNewline) { return "Use a name from 1 to 160 characters." }
            if let value, value.count > 32 { return "Invalid selection." }
            if let date, !date.timeIntervalSince1970.isFinite || abs(date.timeIntervalSince1970) > 40_000_000_000 { return "Invalid date." }
            switch operation {
            case .removeGrocery: guard target != nil, baseline != nil else { return "Refresh this item first." }
            case .addInventory: guard name != nil, let number, (1...999).contains(number), KitchenWatch.locations.contains(value ?? "") else { return "Enter an item, quantity and storage location." }
            case .setRecipeFavorite: guard target != nil, baseline != nil, flag != nil, ["saved", "generated"].contains(value ?? "") else { return "Refresh this recipe first." }
            case .addGrocery: guard name != nil, let number, (1...999).contains(number) else { return "Enter a name and quantity." }
            case .setGroceryChecked: guard target != nil, baseline != nil, flag != nil else { return "Refresh this item first." }
            case .setGroceryQuantity: guard target != nil, baseline != nil, let number, (1...999).contains(number) else { return "Quantity must be 1–999." }
            case .setInventoryQuantity: guard target != nil, baseline != nil, let number, (0...999).contains(number) else { return "Quantity must be 0–999." }
            case .setInventoryLocation: guard target != nil, baseline != nil, KitchenWatch.locations.contains(value ?? "") else { return "Choose a storage location." }
            case .setInventoryExpiry: guard target != nil, baseline != nil, date == nil || abs(date!.timeIntervalSince(now)) < 10 * 365 * 86400 else { return "Choose an expiry within ten years." }
            case .addMeal: guard name != nil, let number, (1...99).contains(number), KitchenWatch.mealTypes.contains(value ?? ""), date != nil else { return "Choose a meal name, date and servings." }
            case .rescheduleMeal: guard target != nil, baseline != nil, date != nil, KitchenWatch.mealTypes.contains(value ?? "") else { return "Refresh and choose a meal date." }
            }
            return nil
        }
    }
    enum Result: String, Codable, Sendable { case preparing, accepted, rejected, conflict, review }
    struct Receipt: Codable, Identifiable, Equatable, Sendable {
        var id: UUID; var scope: UUID; var result: Result; var message: String; var date = Date()
        var snapshotRevision: UInt64? = nil
        func canComplete(in snapshot: Snapshot?) -> Bool {
            guard result != .preparing else { return false }
            guard result == .accepted else { return true }
            guard let snapshotRevision, let snapshot, snapshot.scope == scope else { return false }
            return snapshot.revision >= snapshotRevision
        }
    }
    struct Request: Codable, Sendable {
        var recipe: UUID? = nil; var section: String? = nil; var query: String? = nil; var offset: Int? = nil; var handoff: String? = nil; var nonce: UUID? = nil
    }
    struct Packet: Codable, Sendable {
        var app = "com.sowens.Stocked.watch"; var version = KitchenWatch.version
        var snapshot: Snapshot?; var command: Command?; var receipt: Receipt?; var request: Request?
        func encoded() throws -> Data {
            let data = try JSONEncoder().encode(self)
            guard data.count <= KitchenWatch.wireLimit else { throw Failure.tooLarge }
            return data
        }
        static func decode(_ data: Data) throws -> Packet {
            guard data.count <= KitchenWatch.wireLimit else { throw Failure.tooLarge }
            let value = try JSONDecoder().decode(Self.self, from: data)
            guard value.app == "com.sowens.Stocked.watch", value.version == KitchenWatch.version,
                  [value.snapshot != nil, value.command != nil, value.receipt != nil, value.request != nil].filter({ $0 }).count == 1,
                  value.snapshot?.isValid != false else { throw Failure.incompatible }
            return value
        }
    }
    enum Failure: Error { case tooLarge, incompatible, unavailable }
    static func accepts(_ incoming: Snapshot, current: Snapshot?, nonce: UUID?) -> Bool {
        guard let current else { return true }
        if incoming.scope == current.scope { return incoming.revision > current.revision }
        return nonce != nil && incoming.handshake == nonce
    }

    /// Bounded retry queue persists before sending. A matching terminal receipt is the only success.
    struct Outbox: Codable, Sendable {
        var pending: [Command] = []
        var history: [Receipt] = []
        mutating func enqueue(_ command: Command, now: Date = Date()) throws {
            guard command.validation(now: now) == nil else { throw Failure.unavailable }
            guard !pending.contains(where: { $0.id == command.id }) else { return }
            guard pending.count < KitchenWatch.queueLimit else { throw Failure.unavailable }
            pending.append(command)
        }
        mutating func receive(_ receipt: Receipt) {
            guard receipt.result != .preparing,
                  pending.contains(where: { $0.id == receipt.id && $0.scope == receipt.scope }) else { return }
            pending.removeAll { $0.id == receipt.id }
            history.removeAll { $0.id == receipt.id }; history.insert(receipt, at: 0)
            history = Array(history.prefix(30))
        }
        mutating func reconcile(scope: UUID, now: Date = Date()) {
            for command in pending where command.scope != scope || command.validation(now: now) != nil {
                receive(Receipt(id: command.id, scope: command.scope, result: .rejected,
                    message: command.scope != scope ? "Kitchen changed. Review this change on iPhone." : "Change expired; it was not resent.", date: now))
            }
        }
    }

    /// Keep all receipts while their commands can be valid; refuse more work instead of forgetting IDs.
    struct Journal: Codable, Sendable {
        var scopeKey = ""; var scope = UUID(); var resetEpoch = UUID(); var revision: UInt64 = 0
        var receipts: [Receipt] = []
        mutating func retire(persist: (Journal) throws -> Void) throws {
            var next = self
            next.resetEpoch = UUID(); next.scope = UUID(); next.scopeKey = ""
            try persist(next)
            self = next
        }
        mutating func prepare(_ command: Command, now: Date = Date()) throws -> Receipt? {
            if let prior = receipts.first(where: { $0.id == command.id }) {
                guard prior.scope == command.scope else { throw Failure.incompatible }
                if prior.result == .preparing {
                    return Receipt(id: prior.id, scope: prior.scope, result: .review, message: "Delivery was interrupted. Review this change on iPhone before adding it again.", date: now)
                }
                return prior
            }
            receipts.removeAll { now.timeIntervalSince($0.date) > KitchenWatch.validity + 86400 }
            guard receipts.count < 1024 else { throw Failure.unavailable }
            receipts.append(Receipt(id: command.id, scope: command.scope, result: .preparing, message: "Pending durable save", date: now))
            return nil
        }
        mutating func finish(_ receipt: Receipt) { receipts.removeAll { $0.id == receipt.id }; receipts.append(receipt) }
    }
    static func bounded(_ original: Snapshot) throws -> Data {
        var value = original
        // Detail steps are never silently truncated by transport. If needed, omit it with explanation.
        while (try? Packet(snapshot: value).encoded()) == nil {
            value.limited = true
            if value.detail != nil { value.detail = nil; value.notice = "This recipe is too large for Watch. Open it on iPhone." }
            else if value.inventory.count > 10 { value.inventory.removeLast() }
            else if value.grocery.count > 10 { value.grocery.removeLast() }
            else if value.recipes.count > 5 { value.recipes.removeLast() }
            else if value.meals.count > 7 { value.meals.removeLast() }
            else { throw Failure.tooLarge }
        }
        return try Packet(snapshot: value).encoded()
    }
}

nonisolated enum KitchenWatchDisk {
    static func url(_ name: String, directory: URL? = nil) throws -> URL {
        guard !name.isEmpty, name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else { throw KitchenWatch.Failure.incompatible }
        let root = try directory ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("StockedWatch-v1", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var excluded = root; var values = URLResourceValues(); values.isExcludedFromBackup = true
        try? excluded.setResourceValues(values)
        return root.appendingPathComponent(name + ".json")
    }
    static func load<T: Decodable>(_ type: T.Type, name: String, limit: Int = 1024 * 1024, directory: URL? = nil) throws -> T? {
        guard limit > 0 && limit <= 1024 * 1024 else { throw KitchenWatch.Failure.tooLarge }
        let file = try url(name, directory: directory)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        guard let data = try handle.read(upToCount: limit + 1), data.count <= limit else { throw KitchenWatch.Failure.tooLarge }
        return try JSONDecoder().decode(type, from: data)
    }
    static func save<T: Encodable>(_ value: T, name: String, limit: Int = 1024 * 1024, directory: URL? = nil) throws {
        guard limit > 0 && limit <= 1024 * 1024 else { throw KitchenWatch.Failure.tooLarge }
        let data = try JSONEncoder().encode(value)
        guard data.count <= limit else { throw KitchenWatch.Failure.tooLarge }
        try data.write(to: url(name, directory: directory), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
