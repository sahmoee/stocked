// Native: xcrun swiftc Stocked/SmartCookbookCore.swift scripts/SmartCookbookChecks.swift -o /tmp/stocked-smart-cookbooks
import Foundation

@main struct SmartCookbookChecks {
    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ label: String) { checks += 1; precondition(value, label) }
        func rejects(_ body: () throws -> Void) -> Bool { do { try body(); return false } catch { return true } }
        let norm = SmartCookbookQuery.normalize
        let id1 = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let id2 = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let id3 = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        var one = SmartCookbookRecord(id: id1, title: "Crème soup", searchText: norm("Crème  soup with Beans"), cuisines: ["french"], categories: ["dinner"], tags: ["vegetarian", "weeknight"], prepMinutes: 10, cookMinutes: 30, isFavorite: true, dateCreated: Date(timeIntervalSince1970: 10))
        var two = one; two.id = id2; two.title = "Roast"; two.searchText = "roast"; two.tags = ["weeknight"]; two.cookMinutes = nil; two.isFavorite = false
        var three = one; three.id = id3; three.cookMinutes = 31; three.prepMinutes = nil
        var rule = SmartCookbookRule(); rule.name = "Quick"
        check(norm(" CRÈME\n  Soup ") == "creme soup", "case accents and whitespace normalize")
        rule.text = " Crème SOUP "
        check(SmartCookbookQuery.matchesMetadata(one, rule: rule), "normalized text matches saved searchable facts")
        check(!SmartCookbookQuery.matchesMetadata(two, rule: rule), "text rejects absent words")
        rule.text = ""; rule.requiredTags = ["Vegetarian", "weeknight"]
        check(SmartCookbookQuery.matchesMetadata(one, rule: rule) && !SmartCookbookQuery.matchesMetadata(two, rule: rule), "all required tags are mandatory")
        rule.requiredTags = []; rule.excludedTags = ["vegetarian"]
        check(!SmartCookbookQuery.matchesMetadata(one, rule: rule) && SmartCookbookQuery.matchesMetadata(two, rule: rule), "exclude exact saved tag without guessing diet")
        rule.excludedTags = ["veg"]
        check(SmartCookbookQuery.matchesMetadata(one, rule: rule), "tag prefix never acts as dietary safety inference")
        rule.excludedTags = []; rule.cuisine = "French"; rule.category = "Dinner"; rule.favoritesOnly = true
        check(SmartCookbookQuery.matchesMetadata(one, rule: rule) && !SmartCookbookQuery.matchesMetadata(two, rule: rule), "cuisine category and favorites combine with AND")
        rule = SmartCookbookRule(); rule.name = "Times"
        var matches = try SmartCookbookQuery.scan([one, two, three], rule: rule)
        check(matches.total == 3 && matches.unknownTimeExcluded == 0, "unfiltered missing time is retained")
        rule.maxCookMinutes = 30
        matches = try SmartCookbookQuery.scan([one, two, three], rule: rule)
        check(matches.ids == [id1] && matches.unknownTimeExcluded == 1, "inclusive cook bound and explicit unknown count")
        rule.maxPrepMinutes = 10
        matches = try SmartCookbookQuery.scan([one, two, three], rule: rule)
        check(matches.unknownTimeExcluded == 1, "known failing time does not count as otherwise matching unknown")
        one.prepMinutes = 0; rule.maxPrepMinutes = 0
        check(try SmartCookbookQuery.scan([one], rule: rule).total == 1, "known zero prep time is valid")
        rule.maxPrepMinutes = nil; rule.maxCookMinutes = nil; rule.order = .shortestCookTime
        matches = try SmartCookbookQuery.scan([two, three, one], rule: rule)
        check(matches.ids == [id1, id3, id2], "unknown cook time sorts last")
        three.title = one.title; three.cookMinutes = one.cookMinutes; three.dateCreated = Date(timeIntervalSince1970: 50)
        rule.order = .name
        check(try SmartCookbookQuery.scan([three, one], rule: rule).ids == [id1, id3], "ties have deterministic UUID ordering")
        rule.order = .newest
        check(try SmartCookbookQuery.scan([one, three], rule: rule).ids == [id3, id1], "recent saves sort first")
        let many = (0..<1000).map { index in
            var record = one; record.id = UUID(); record.title = String(format: "%04d", 999 - index); return record
        }
        rule.order = .name
        let window = try SmartCookbookQuery.scan(many, rule: rule, limit: 10000)
        check(window.total == 1000 && window.ids.count == 240 && window.ids.first == many.last?.id, "bounded visible window preserves complete count and sorted best matches")
        check(try SmartCookbookQuery.scan([SmartCookbookRecord](), rule: rule).total == 0, "empty library has no synthetic recipe")
        var valid = rule; valid.name = "  Weeknights  "; valid.requiredTags = ["Quick", "QUÍCK", ""]
        let normalized = try valid.validated()
        check(normalized.name == "Weeknights" && normalized.requiredTags == ["Quick"], "saved names trim and tags deduplicate")
        valid.excludedTags = ["quick"]
        check(rejects { _ = try valid.validated() }, "conflicting tag rules fail visibly")
        valid = rule; valid.name = ""; check(rejects { _ = try valid.validated() }, "empty cookbook name rejected")
        valid = rule; valid.maxCookMinutes = -1; check(rejects { _ = try valid.validated() }, "negative time rejected")
        var collection = (0..<50).map { i in var r = rule; r.id = UUID(); r.name = "Cookbook \(i)"; return r }
        try SmartCookbookRule.validateCollection(collection)
        check(collection.count == 50, "fifty concise rules accepted")
        collection.append(rule)
        check(rejects { try SmartCookbookRule.validateCollection(collection) }, "fifty-first rule cannot be added")
        var merged = collection
        var extra = rule; extra.id = UUID(); extra.name = "Extra cookbook"
        merged.append(extra)
        try SmartCookbookRule.validateChange(from: merged, to: Array(merged.dropLast()))
        check(true, "merged oversized collection can shrink without first falling below cap")
        check(rejects { try SmartCookbookRule.validateChange(from: collection, to: merged) }, "oversized household cannot grow through local editing")
        collection = (0..<50).map { i in var r = rule; r.id = UUID(); r.name = "Cookbook \(i)"; r.text = String(repeating: "🍲", count: 200); return r }
        check(rejects { try SmartCookbookRule.validateCollection(collection) }, "wire byte budget includes multibyte text")
        valid = rule; valid.updatedAt = 1_750_000_000_123; valid.lastWriterID = "member"
        check(try JSONDecoder().decode(SmartCookbookRule.self, from: JSONEncoder().encode(valid)) == valid, "sync timestamps and writer round-trip")
        let cancelled = await Task.detached { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try SmartCookbookQuery.scan(many, rule: rule); return false }
            catch is CancellationError { return true }
            catch { return false }
        }.value
        check(cancelled, "cancelled background query stops without late results")
        print("Smart cookbooks: \(checks) native checks passed")
    }
}
