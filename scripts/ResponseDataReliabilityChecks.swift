// swiftc -parse-as-library Stocked/ResponseCacheStorage.swift Stocked/AIResultCache.swift Stocked/Nutrition/APIResponseCache.swift Stocked/SmartResponseCache.swift Stocked/QuantityParser.swift Stocked/CorrectionCalibration.swift scripts/ResponseDataReliabilityChecks.swift -o /tmp/stocked-response-data-checks
import Foundation

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Double
    init(_ value: Double) { self.value = value }
    func get() -> Double { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ delta: Double) { lock.lock(); value += delta; lock.unlock() }
}
private actor Gate {
    private var continuation: CheckedContinuation<Data?, Never>?
    private var began = false
    private(set) var calls = 0
    func load() async -> Data? { calls += 1; began = true; return await withCheckedContinuation { continuation = $0 } }
    func wait() async { while !began { await Task.yield() } }
    func finish(_ data: Data?) { continuation?.resume(returning: data); continuation = nil }
}
private actor Calls {
    var count = 0
    func hit() -> Data? { count += 1; return nil }
}
@main struct ResponseDataReliabilityChecks {
    static func main() async throws {
        var count = 0
        func check(_ value: Bool, _ message: String) { count += 1; precondition(value, message) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StockedDataChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock(1000)
        let now: @Sendable () -> Date = { Date(timeIntervalSince1970: clock.get()) }
        check(ResponseCacheKey.make(["a|b", "c"]) != ResponseCacheKey.make(["a", "b|c"]), "Framed separators")
        check(ResponseCacheKey.make([Data([0, 1]), Data([2])]) != ResponseCacheKey.make([Data([0]), Data([1, 2])]), "Framed binary bytes")
        check(SmartResponseCache.key("a", "b", responseType: "X") != SmartResponseCache.key("a", "b", responseType: "Y"), "Response shape identity")
        let tiny = ResponseCacheStorage.Limits(entryBytes: 128, memoryBytes: 256, diskBytes: 10_000, entries: 2, maximumTTL: 3600)
        let dir = root.appendingPathComponent("core")
        var storage = ResponseCacheStorage(directory: dir, limits: tiny, now: now)
        check(storage.store(Data("a".utf8), for: "a", ttl: 100), "Store")
        check(storage.lookup("a")?.data == Data("a".utf8), "Memory read")
        check(storage.store(Data("b".utf8), for: "b", ttl: 100), "Second store")
        clock.advance(1); _ = storage.lookup("a")
        clock.advance(1); _ = storage.store(Data("c".utf8), for: "c", ttl: 100)
        check(storage.retainedCount == 2 && storage.diskEntryCount() == 2, "Memory/disk count bound")
        check(storage.lookup("b") == nil && storage.lookup("a") != nil, "Read-touch LRU")
        _ = storage.store(Data("A".utf8), for: "a", ttl: 100)
        check(storage.lookup("c") != nil, "Replacement does not evict peer")
        check(!storage.store(Data(repeating: 1, count: 129), for: "large", ttl: 100), "Entry write bound")
        check(!storage.store(Data(), for: "empty", ttl: 100), "Empty result stays a miss")
        check(storage.lookup(String(repeating: "a", count: 65_537)) == nil, "Long lookup key bound")
        check(!storage.store(Data([1]), for: "a", ttl: .infinity) && storage.lookup("a") == nil, "Infinite TTL removes previous answer")
        _ = storage.store(Data([1]), for: "a", ttl: 100)
        check(!storage.store(Data([2]), for: "a", ttl: 0) && storage.lookup("a") == nil, "Zero TTL invalidates")
        _ = storage.store(Data([1]), for: "a", ttl: 100)
        check(!storage.store(Data([2]), for: "a", ttl: -.infinity), "Negative infinite TTL rejected")
        _ = storage.store(Data([1]), for: "a", ttl: 10)
        clock.advance(10)
        check(storage.lookup("a") == nil, "Exact expiry")
        _ = storage.store(Data([1]), for: "future", ttl: 1000)
        clock.advance(-400)
        check(storage.lookup("future") == nil, "Future stamp rejected after large clock correction")
        clock.advance(400)
        let generation = storage.generation
        storage.clear()
        check(!storage.store(Data([1]), for: "retired", ttl: 10, expectedGeneration: generation), "Retired publication rejected")
        check(storage.diskEntryCount() == 0 && storage.retainedCount == 0, "Clear empties owned state")
        _ = storage.store(Data([1]), for: "purged", ttl: 100)
        try FileManager.default.removeItem(at: dir)
        _ = storage.store(Data([2]), for: "rebuilt", ttl: 100)
        check(storage.diskEntryCount() == 1, "OS-purged directory recreated")
        var reader = ResponseCacheStorage(directory: dir, limits: tiny, now: now)
        check(reader.lookup("rebuilt")?.data == Data([2]), "Disk round trip")
        let digest = ResponseCacheKey.make(["oversized"])
        let oversized = dir.appendingPathComponent("v2_" + digest + ".json")
        try Data(repeating: 0, count: 5000).write(to: oversized)
        check(reader.lookup("oversized") == nil && !FileManager.default.fileExists(atPath: oversized.path), "Oversized disk body removed without unbounded read")
        let corrupt = dir.appendingPathComponent("v2_" + ResponseCacheKey.make(["corrupt"]) + ".json")
        try Data("broken".utf8).write(to: corrupt)
        check(reader.lookup("corrupt") == nil && !FileManager.default.fileExists(atPath: corrupt.path), "Corrupt envelope evicted")
        _ = reader.store(Data([4]), for: "identity", ttl: 100)
        let identity = dir.appendingPathComponent("v2_" + ResponseCacheKey.make(["identity"]) + ".json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: identity)) as! [String: Any]
        json["key"] = "another-key"
        try JSONSerialization.data(withJSONObject: json).write(to: identity)
        var newReader = ResponseCacheStorage(directory: dir, limits: tiny, now: now)
        check(newReader.lookup("identity") == nil, "Envelope ownership validated")
        let foreign = dir.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: foreign)
        let outside = root.appendingPathComponent("outside.txt")
        try Data("keep outside".utf8).write(to: outside)
        let link = dir.appendingPathComponent("v2_" + ResponseCacheKey.make(["linked"]) + ".json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        check(newReader.lookup("linked") == nil, "Symlink ignored")
        let subdir = dir.appendingPathComponent("v2_" + ResponseCacheKey.make(["folder"]) + ".json")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        newReader.clear()
        check(FileManager.default.fileExists(atPath: foreign.path) && FileManager.default.fileExists(atPath: outside.path) && FileManager.default.fileExists(atPath: subdir.path), "Clear preserves foreign files, links and folders")
        let memoryLimit = ResponseCacheStorage.Limits(entryBytes: 200, memoryBytes: 100, diskBytes: 1000, entries: 20)
        var bounded = ResponseCacheStorage(directory: root.appendingPathComponent("bounded"), limits: memoryLimit, now: now)
        for i in 0..<10 { _ = bounded.store(Data(repeating: UInt8(i), count: 70), for: String(i), ttl: 100) }
        check(bounded.retainedBytes <= 100 && bounded.retainedCount <= 1, "Memory byte budget independent of entry count")
        check(bounded.diskSizeBytes() <= 1000, "Disk byte budget immediate")
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data([0]).write(to: blocked)
        var memoryFallback = ResponseCacheStorage(directory: blocked, now: now)
        _ = memoryFallback.store(Data([9]), for: "offline", ttl: 100)
        check(memoryFallback.lookup("offline")?.data == Data([9]), "Disk failure retains fetched response in memory")
        var extremeClock = ResponseCacheStorage(directory: root.appendingPathComponent("extreme"), now: { Date(timeIntervalSince1970: .greatestFiniteMagnitude) })
        check(!extremeClock.store(Data([1]), for: "bad-date", ttl: 100), "Unrepresentable expiry rejected")
        let api = APIResponseCache(namespace: "../bad", rootDirectory: root)
        await api.store(["a": 1], for: "../../request", ttl: 100)
        check(await api.value(for: "../../request", as: [String: Int].self) == ["a": 1], "API namespace/key path safe round trip")
        check(await api.value(for: "../../request", as: String.self) == nil, "Wrong decoded model rejected")
        check(await api.value(for: "../../request", as: [String: Int].self) == nil, "Bad model entry removed")
        let ai = AIResultCache(rootDirectory: root)
        let aiGeneration = await ai.currentGeneration()
        await ai.clear()
        await ai.save(Data([1]), route: "r", schemaVersion: 1, payloadData: Data([2]), ttl: 100, expectedGeneration: aiGeneration)
        check(await ai.value(route: "r", schemaVersion: 1, payloadData: Data([2])) == nil, "AI clear rejects old request save")
        await ai.save(Data([3]), route: "r", schemaVersion: 1, payloadData: Data([2]), ttl: 100)
        check(await ai.value(route: "r", schemaVersion: 1, payloadData: Data([2])) == Data([3]), "AI response wrapper")

        let smart = SmartResponseCache(rootDirectory: root, now: now, uptime: { clock.get() })
        let gate = Gate()
        let first = Task { await smart.refreshedData("shared") { await gate.load() } }
        await gate.wait()
        let second = Task { await smart.refreshedData("shared") { await gate.load() } }
        await Task.yield()
        await gate.finish(Data([5]))
        let firstValue = await first.value, secondValue = await second.value
        check(firstValue == Data([5]) && secondValue == Data([5]), "Shared cold response")
        check(await gate.calls == 1, "Cold callers coalesced")
        let cancelledGate = Gate()
        let cancelledWaiter = Task { await smart.refreshedData("cancelled-waiter") { await cancelledGate.load() } }
        await cancelledGate.wait()
        cancelledWaiter.cancel()
        let activeWaiter = Task { await smart.refreshedData("cancelled-waiter") { await cancelledGate.load() } }
        await Task.yield()
        await cancelledGate.finish(Data([6]))
        check(await cancelledWaiter.value == nil, "Cancelled waiter does not publish shared answer")
        let activeAnswer = await activeWaiter.value, cancelledProducerCalls = await cancelledGate.calls
        check(activeAnswer == Data([6]) && cancelledProducerCalls == 1, "Active waiter keeps shared producer")
        let failure = Calls()
        _ = await smart.refreshedData("failure") { await failure.hit() }
        _ = await smart.refreshedData("failure") { await failure.hit() }
        check(await failure.count == 1, "Failed refresh cooldown")
        clock.advance(31)
        _ = await smart.refreshedData("failure") { await failure.hit() }
        check(await failure.count == 2, "Failure becomes retryable")
        let retired = Gate()
        let oldGeneration = await smart.currentGeneration()
        let old = Task { await smart.refreshedData("reset") { await retired.load() } }
        await retired.wait(); await smart.clear()
        let fresh = await smart.refreshedData("reset") { Data([8]) }
        await retired.finish(Data([7]))
        check(await old.value == nil && fresh == Data([8]), "Clear retires producer")
        check(await smart.lookup("reset").data == Data([8]), "Old completion does not overwrite fresh response")
        check(await smart.refreshedData("after-clear", expectedGeneration: oldGeneration) { Data([1]) } == nil, "Old lookup generation cannot launch new flight")
        clock.advance(3601)
        check(await smart.lookup("reset").freshness == .stale, "Stale state remains usable")
        let staleGate = Gate()
        await smart.refreshInBackground("reset") { await staleGate.load() }
        await staleGate.wait()
        await smart.refreshInBackground("reset") { await staleGate.load() }
        let staleData = await smart.lookup("reset").data, staleCalls = await staleGate.calls
        check(staleData == Data([8]) && staleCalls == 1, "Stale answer returned while one refresh runs")
        await staleGate.finish(Data([9]))
        _ = await smart.refreshedData("reset") { Data([0]) }
        check(await smart.lookup("reset").data == Data([9]), "Stale refresh publishes once")

        let quantities: [(String, Double, String, Double?, String?, String)] = [
            ("4 bags of chips",4,"bag",nil,nil,"chips"), ("6 poptarts",6,"item",nil,nil,"poptarts"),
            ("half a bag of cheese",0.5,"bag",nil,nil,"cheese"), ("a half bag",0.5,"bag",nil,nil,""),
            ("a dozen eggs",12,"item",nil,nil,"eggs"), ("two dozen eggs",24,"item",nil,nil,"eggs"),
            ("half a dozen eggs",6,"item",nil,nil,"eggs"), ("dozen eggs",12,"item",nil,nil,"eggs"),
            ("2 1/2 lbs chicken",2.5,"lb",nil,nil,"chicken"), ("2-1/2 lb chicken",2.5,"lb",nil,nil,"chicken"),
            ("1½ cups flour",1.5,"cup",nil,nil,"flour"), ("⅝ cup flour",0.625,"cup",nil,nil,"flour"),
            ("6 cans of 8 oz",6,"can",8,"oz",""), ("6 cans 8 oz peaches",6,"can",8,"oz","peaches"),
            ("6 cans · 8 oz each",6,"can",8,"oz",""), ("2 bottles of 12 fl. oz. juice",2,"bottle",12,"fl oz","juice"),
            ("12 fluid ounces milk",12,"fl oz",nil,nil,"milk"), ("2 cases of water",2,"case",nil,nil,"water"),
            ("2 loaves bread",2,"loaf",nil,nil,"bread"), ("6 vitamin b12 tablets",6,"item",nil,nil,"vitamin b12 tablets"),
            ("2 bags 3 musketeers",2,"bag",nil,nil,"3 musketeers"), ("2 3 bags",2,"item",nil,nil,"3 bags"),
            ("6-pack soda",6,"pack",nil,nil,"soda"), (".5 kg flour",0.5,"kg",nil,nil,"flour"),
            ("1,000 g flour",1000,"g",nil,nil,"flour"), ("0,5 kg flour",0.5,"kg",nil,nil,"flour"),
            ("zero cans",0,"can",nil,nil,""), ("7up",1,"item",nil,nil,"7up"),
            ("one and a half bags",1.5,"bag",nil,nil,""), ("2 and 1/4 cups",2.25,"cup",nil,nil,""),
            ("one and two",1,"item",nil,nil,"and two")
        ]
        for (input, number, container, each, unit, item) in quantities {
            let got = QuantityParser.parse(input)
            check(abs(got.count - number) < 0.000001 && got.container == container && got.amountEach == each && got.unitEach == unit && got.item == item, "Quantity: \(input): \(got)")
        }
        for input in ["-5 bags", "nan cups", "inf cans", "1e999 grams", "1/0 bags", "1000000001 cans", "2 cans of 1/0 oz", "2 cans of nan oz", "-0½ cups", "-¼ bag", "−¼ cup", "−0½ cups", "-1½ cups", "2 bags of -¼ cup", "2 bags of −0½ cup", "-0¼ bag", String(repeating: "a", count: 4097)] {
            check(QuantityParser.parse(input).count == 0 && QuantityParser.parse(input).validationMessage != nil, "Invalid quantity: \(input.prefix(30))")
        }
        let legacyAmount = try JSONDecoder().decode(ParsedAmount.self, from: Data(#"{"count":2,"container":"bag","item":"chips"}"#.utf8))
        check(legacyAmount.validationMessage == nil && legacyAmount.count == 2, "Legacy amount decodes without validation field")
        check(QuantityParser.parse("zero cans").validationMessage == nil, "Explicit zero remains valid")
        for value in [Double.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            check(!ParsedAmount.trim(value).isEmpty, "Extreme formatting does not trap")
        }
        check(QuantityParser.parse("2 cases").display == "2 cases", "Case plural")
        check(QuantityParser.parse("2 loaves").display == "2 loaves", "Loaf plural")
        check(QuantityParser.parse("12 oz").display == "12 oz", "Measure abbreviations not pluralized")

        let date = Date(timeIntervalSince1970: 1000)
        var rows: [String: CorrectionCalibration.Record] = [:]
        for i in 0..<300 { rows["itemName|\(i)"] = .init(predicted: "Old \(i)", final: "New \(i)", edited: i + 1, updatedAt: date) }
        rows["unknown|item"] = .init(predicted: "a", final: "b", updatedAt: date)
        rows["itemName|bad"] = .init(predicted: "", final: "b", updatedAt: date)
        var calibration = CorrectionCalibration(records: rows, now: date)
        check(calibration.records.count == 250, "Restored calibration bounded")
        check(calibration.records["unknown|item"] == nil && calibration.records["itemName|bad"] == nil, "Invalid restored records rejected")
        var evidence = CorrectionCalibration(records: ["itemName|milk": .init(predicted: "Milk", final: "Oat milk", accepted: Int.max, edited: Int.max, rejected: Int.min, updatedAt: date)], now: date)
        check(evidence.records["itemName|milk"]?.accepted == 1_000_000 && evidence.records["itemName|milk"]?.rejected == 0, "Restored counters repaired")
        _ = evidence.record(kind: .itemName, original: "milk", predicted: "Milk", final: "Oat milk", outcome: .edited, now: date)
        check(evidence.records["itemName|milk"]?.edited == 1_000_000, "Counter saturation")
        check(evidence.confidence(kind: .itemName, original: "milk", predicted: "Cheese", base: 0.7) == 0.7, "Unrelated prediction cannot influence confidence")
        _ = evidence.record(kind: .itemName, original: "milk", predicted: "Milk powder", final: "Milk powder", outcome: .accepted, now: date)
        check(evidence.records["itemName|milk"]?.edited == 0 && evidence.records["itemName|milk"]?.accepted == 1, "Changed prediction starts new evidence")
        check(evidence.confidence(kind: .itemName, original: "none", predicted: "anything", base: .nan) == 0, "Nonfinite base confidence safe")
        check(evidence.confidence(kind: .itemName, original: "none", predicted: "anything", base: 5) == 1, "Base confidence bounded even without history")
        check(evidence.promptCorrections(limit: -1).isEmpty, "Negative prompt limit safe")
        check(!calibration.record(kind: .itemName, original: "item", predicted: String(repeating: "a", count: 513), final: "x", outcome: .edited, now: date), "Oversized correction rejected")
        let promptRows: [String: CorrectionCalibration.Record] = [
            "itemName|a": .init(predicted: "Milk", final: "Oat milk", edited: 10, updatedAt: date),
            "itemName|b": .init(predicted: "milk", final: "Almond milk", edited: 1, updatedAt: date),
            "zone|c": .init(predicted: "Milk", final: "Fridge", edited: 20, updatedAt: date),
            "itemName|d": .init(predicted: "Egg", final: "Egg", edited: 30, updatedAt: date),
            "itemName|future": .init(predicted: "A", final: "B", edited: 1, updatedAt: date.addingTimeInterval(500))]
        let prompt = CorrectionCalibration(records: promptRows, now: date)
        check(prompt.promptCorrections() == ["Milk": "Oat milk"], "Strongest deterministic name correction wins, excluding other kinds/no-op")
        check(prompt.records["itemName|future"] == nil, "Future calibration date rejected")
        print("Response/data reliability: \(count) checks passed")
    }
}
