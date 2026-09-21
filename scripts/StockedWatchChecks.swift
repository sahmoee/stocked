// swiftc -parse-as-library StockedWatchShared/StockedWatchContract.swift Stocked/KitchenMathCore.swift scripts/StockedWatchChecks.swift -o /tmp/stocked-watch-checks
import Foundation

@main struct StockedWatchChecks {
    static func main() throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) { checks += 1; precondition(condition, name) }
        func rejects(_ name: String, _ action: () throws -> Void) { var rejected = false; do { try action() } catch { rejected = true }; check(rejected, name) }
        let now = Date(timeIntervalSince1970: 1_800_000_000), scope = UUID(), id = UUID()
        func command(_ operation: KitchenWatch.Operation = .addGrocery) -> KitchenWatch.Command {
            KitchenWatch.Command(scope: scope, created: now, operation: operation, target: id, baseline: 123, name: "Apples", number: 2, flag: true, value: "Pantry", date: now)
        }
        func snapshot() -> KitchenWatch.Snapshot {
            .init(scope: scope, revision: 4, date: now, enabled: true,
                  grocery: [.init(id: id, name: "Apples", quantity: 4, checked: false, size: "bag", revision: 123)],
                  inventory: [], recipes: [], meals: [], detail: nil, permissions: ["view", "groceryEdit"], totals: [1,0,0,0])
        }
        let first = command()
        check(first.validation(now: now) == nil, "Valid grocery addition")
        var bad = first; bad.name = " \n "; check(bad.validation(now: now) != nil, "Whitespace name rejected")
        bad = first; bad.name = String(repeating: "a", count: 161); check(bad.validation(now: now) != nil, "Name length")
        bad = first; bad.name = "Line\nbreak"; check(bad.validation(now: now) != nil, "Multiline name")
        bad = first; bad.number = 1000; check(bad.validation(now: now) != nil, "Write quantity upper bound")
        bad = first; bad.number = 0; check(bad.validation(now: now) != nil, "Grocery zero rejected")
        bad = first; bad.created = now.addingTimeInterval(-KitchenWatch.validity); check(bad.validation(now: now) == nil, "Exact seven day lifetime")
        bad.created = bad.created.addingTimeInterval(-1); check(bad.validation(now: now) != nil, "Expired command")
        bad = first; bad.created = now.addingTimeInterval(301); check(bad.validation(now: now) != nil, "Future timestamp")
        bad = first; bad.baseline = .infinity; check(bad.validation(now: now) != nil, "Nonfinite baseline")
        bad = first; bad.baseline = -1; check(bad.validation(now: now) != nil, "Negative baseline")
        bad = command(.removeGrocery); bad.baseline = nil; check(bad.validation(now: now) != nil, "Remove requires baseline")
        bad = command(.setGroceryChecked); bad.flag = nil; check(bad.validation(now: now) != nil, "Check requires absolute value")
        bad = command(.setInventoryQuantity); bad.number = 0; check(bad.validation(now: now) == nil, "Inventory permits zero")
        bad.number = -1; check(bad.validation(now: now) != nil, "Negative inventory rejected")
        bad = command(.addInventory); check(bad.validation(now: now) == nil, "Quick inventory add")
        bad.value = "Unknown"; check(bad.validation(now: now) != nil, "Unknown storage rejected")
        bad = command(.setInventoryExpiry); bad.date = nil; check(bad.validation(now: now) == nil, "Clear expiry")
        bad.date = now.addingTimeInterval(11*365*86400); check(bad.validation(now: now) != nil, "Extreme expiry")
        bad = command(.addMeal); bad.value = "Dinner"; check(bad.validation(now: now) == nil, "Meal addition")
        bad.number = 100; check(bad.validation(now: now) != nil, "Serving write bound")
        bad = command(.rescheduleMeal); bad.value = "Lunch"; check(bad.validation(now: now) == nil, "Reschedule")
        bad.date = Date(timeIntervalSince1970: 1e300); check(bad.validation(now: now) != nil, "Finite extreme date rejected before Calendar")
        bad = command(.setRecipeFavorite); bad.value = "saved"; check(bad.validation(now: now) == nil, "Favorite saved recipe")
        bad.value = "generated"; check(bad.validation(now: now) == nil, "Favorite generated recipe")
        bad.value = "public"; check(bad.validation(now: now) != nil, "No public catalog mutation")
        check(KitchenWatch.Operation.removeGrocery.permission == "groceryRemove", "Remove permission distinct")
        check(KitchenWatch.Operation.addInventory.permission == "inventoryAdd", "Add permission distinct")
        check(KitchenWatch.Operation.setRecipeFavorite.permission == "recipeEdit", "Favorite permission")
        let original = snapshot()
        let encoded = try KitchenWatch.Packet(snapshot: original).encoded()
        check(try KitchenWatch.Packet.decode(encoded).snapshot == original, "Snapshot roundtrip")
        rejects("Oversized envelope") { _ = try KitchenWatch.Packet.decode(Data(repeating: 0, count: KitchenWatch.wireLimit + 1)) }
        var packet = KitchenWatch.Packet(command: first); packet.app = "other-app"
        rejects("App isolation") { _ = try KitchenWatch.Packet.decode(packet.encoded()) }
        packet = .init(command: first); packet.version = 99
        rejects("Version isolation") { _ = try KitchenWatch.Packet.decode(packet.encoded()) }
        packet = .init(command: first, request: .init())
        rejects("Ambiguous packet") { _ = try KitchenWatch.Packet.decode(packet.encoded()) }
        rejects("Empty packet") { _ = try KitchenWatch.Packet.decode(KitchenWatch.Packet().encoded()) }
        var incoming = original
        check(!KitchenWatch.accepts(incoming, current: original, nonce: nil), "Equal revision rejected")
        incoming.revision = 3; check(!KitchenWatch.accepts(incoming, current: original, nonce: nil), "Old same epoch snapshot")
        incoming.revision = 5; check(KitchenWatch.accepts(incoming, current: original, nonce: nil), "New revision")
        incoming.scope = UUID(); incoming.revision = 0
        check(!KitchenWatch.accepts(incoming, current: original, nonce: nil), "Unsolicited foreign epoch blocked")
        let nonce = UUID(); incoming.handshake = nonce
        check(KitchenWatch.accepts(incoming, current: original, nonce: nonce), "Live handshake adopts reset revision zero")
        check(!KitchenWatch.accepts(incoming, current: original, nonce: UUID()), "Old handshake blocked")
        check(!KitchenWatch.accepts(original, current: incoming, nonce: nil), "Delayed pre-reset context blocked")
        check(KitchenWatch.accepts(original, current: nil, nonce: nil), "Initial paired snapshot")
        var invalid = original; invalid.offsets["grocery"] = Int.max; check(!invalid.isValid, "Offset overflow blocked")
        invalid = original; invalid.totals = [-1,0,0,0]; check(!invalid.isValid, "Negative counts blocked")
        invalid = original; invalid.date = Date(timeIntervalSince1970: .infinity); check(!invalid.isValid, "Invalid snapshot date")
        invalid = original; invalid.grocery[0].quantity = Int.max; check(invalid.isValid, "Read-only quantities stay truthful beyond write bound")
        var outbox = KitchenWatch.Outbox(); try outbox.enqueue(first, now: now); try outbox.enqueue(first, now: now)
        check(outbox.pending.count == 1, "Duplicate UUID enqueue")
        for _ in 1..<KitchenWatch.queueLimit { try outbox.enqueue(command(), now: now) }
        let retained = outbox.pending.map(\.id)
        rejects("Full outbox rejects without eviction") { try outbox.enqueue(command(), now: now) }
        check(outbox.pending.map(\.id) == retained, "No silent eviction")
        try outbox.enqueue(first, now: now); check(outbox.pending.count == 64, "Duplicate at full capacity is a no-op")
        var receipt = KitchenWatch.Receipt(id: first.id, scope: UUID(), result: .accepted, message: "Saved", date: now, snapshotRevision: 5)
        outbox.receive(receipt); check(outbox.pending.count == 64, "Foreign receipt cannot consume pending work")
        receipt.scope = scope; receipt.result = .preparing; outbox.receive(receipt); check(outbox.pending.count == 64, "Preparing is never terminal")
        receipt.result = .accepted
        check(!receipt.canComplete(in: original), "Accepted receipt waits for current snapshot")
        var confirmed = original; confirmed.revision = 5; check(receipt.canComplete(in: confirmed), "Confirmed revision permits completion")
        confirmed.scope = UUID(); check(!receipt.canComplete(in: confirmed), "Foreign snapshot cannot confirm accepted write")
        receipt.snapshotRevision = nil; check(!receipt.canComplete(in: original), "Missing accepted revision cannot erase pending overlay")
        receipt.result = .rejected; check(receipt.canComplete(in: nil), "Failure can finish without snapshot")
        outbox.receive(receipt); check(outbox.pending.count == 63 && outbox.history.first?.id == first.id, "Matching terminal receipt")
        outbox.reconcile(scope: scope, now: now.addingTimeInterval(KitchenWatch.validity + 1))
        check(outbox.pending.isEmpty && outbox.history.count == 30, "Expiry clears queued operations into bounded visible history")
        try outbox.enqueue(first, now: now); outbox.reconcile(scope: UUID(), now: now)
        check(outbox.pending.isEmpty && outbox.history.first?.message.contains("Kitchen changed") == true, "Epoch change visibly rejects old work")
        var journal = KitchenWatch.Journal(); journal.scope = scope
        check(try journal.prepare(first, now: now) == nil, "First UUID prepares once")
        check(try journal.prepare(first, now: now)?.result == .review, "Interrupted intent cannot replay")
        receipt = .init(id: first.id, scope: scope, result: .accepted, message: "Saved", date: now, snapshotRevision: 5)
        journal.finish(receipt)
        check(try journal.prepare(first, now: now) == receipt, "Resend returns persisted receipt without applying again")
        var changedScope = first; changedScope.scope = UUID()
        rejects("Journal UUID cannot cross scope") { _ = try journal.prepare(changedScope, now: now) }
        let beforeEpoch = journal.resetEpoch, beforeScope = journal.scope
        rejects("Reset fails closed when durable retirement fails") { try journal.retire { _ in throw KitchenWatch.Failure.unavailable } }
        check(journal.resetEpoch == beforeEpoch && journal.scope == beforeScope, "Failed reset leaves active epoch untouched")
        var captured: KitchenWatch.Journal?
        try journal.retire { captured = $0 }
        check(journal.resetEpoch != beforeEpoch && journal.scope != beforeScope && captured?.resetEpoch == journal.resetEpoch, "Retirement persists before epoch publication")
        check(try journal.prepare(first, now: now) == receipt, "Retirement preserves duplicate receipts")
        var fullJournal = KitchenWatch.Journal()
        for _ in 0..<1024 { _ = try fullJournal.prepare(command(), now: now) }
        rejects("Journal limit retains all live UUIDs") { _ = try fullJournal.prepare(command(), now: now) }
        check(fullJournal.receipts.count == 1024, "No live journal eviction")
        check(try fullJournal.prepare(command(), now: now.addingTimeInterval(KitchenWatch.validity + 86401)) == nil && fullJournal.receipts.count == 1, "Only expired receipt history pruned")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StockedWatchChecks-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try KitchenWatchDisk.save(journal, name: "journal", directory: root)
        let loaded = try KitchenWatchDisk.load(KitchenWatch.Journal.self, name: "journal", directory: root)
        check(loaded?.scope == journal.scope && loaded?.receipts == journal.receipts, "Atomic disk journal recovery")
        check(try KitchenWatchDisk.load(KitchenWatch.Journal.self, name: "absent", directory: root) == nil, "Missing file is fresh state")
        rejects("Disk read bound") { _ = try KitchenWatchDisk.load(KitchenWatch.Journal.self, name: "journal", limit: 10, directory: root) }
        rejects("Oversized replacement rejected") { try KitchenWatchDisk.save(String(repeating: "x", count: 200), name: "journal", limit: 100, directory: root) }
        check(try KitchenWatchDisk.load(KitchenWatch.Journal.self, name: "journal", directory: root)?.scope == journal.scope, "Failed replacement preserves previous file")
        rejects("Owned filename rejects path traversal") { _ = try KitchenWatchDisk.url("../foreign", directory: root) }
        try Data("broken".utf8).write(to: KitchenWatchDisk.url("corrupt", directory: root))
        rejects("Corrupt persisted file is not empty success") { _ = try KitchenWatchDisk.load(KitchenWatch.Journal.self, name: "corrupt", directory: root) }
        rejects("Read limit overflow blocked") { _ = try KitchenWatchDisk.load(KitchenWatch.Journal.self, name: "journal", limit: Int.max, directory: root) }
        var large = original
        let long = String(repeating: "🍎", count: 160)
        large.grocery = (0..<80).map { _ in .init(id: UUID(), name: long, quantity: 1, checked: false, size: String(repeating: "🍎", count: 80), revision: 1) }
        large.inventory = (0..<60).map { _ in .init(id: UUID(), name: long, quantity: 1, location: "Pantry", expiry: nil, low: false, revision: 1) }
        large.totals = [80,60,0,0]; large.offsets = ["grocery": 0, "inventory": 0]
        large.detail = .init(id: UUID(), title: "Recipe", servings: 4, ingredients: [], steps: [String(repeating: "🍎", count: 1200)], incomplete: false, source: "Private")
        let bounded = try KitchenWatch.bounded(large)
        let small = try KitchenWatch.Packet.decode(bounded).snapshot!
        check(bounded.count <= KitchenWatch.wireLimit && small.limited, "Multibyte snapshot bounded")
        check(small.detail == nil && small.notice.contains("iPhone"), "Oversized detail never silently truncated")
        check(small.nextOffset(for: "grocery") == small.grocery.count, "Paging advances by delivered count, not requested size")
        check(small.nextOffset(for: "inventory") == small.inventory.count, "Trimmed inventory remains reachable on next page")
        check(KitchenMathCore.parse("1,5", locale: Locale(identifier: "fr_FR")) == 1.5, "Watch uses localized decimal parser")
        check(KitchenMathCore.parse("1abc", locale: Locale(identifier: "en_US")) == nil, "Partial numeric parse rejected")
        let request = KitchenWatch.Request(recipe: id, section: "recipes", query: "Soup", offset: 30, handoff: "recipes", nonce: nonce)
        let decoded = try KitchenWatch.Packet.decode(KitchenWatch.Packet(request: request).encoded()).request
        check(decoded?.nonce == nonce && decoded?.handoff == "recipes" && decoded?.offset == 30, "One replaceable request carries handshake, query and handoff without a mutation UUID")
        print("Stocked Watch: \(checks) native protocol, durability, paging and input checks passed")
    }
}
