// Run WITHOUT a simulator:
// xcrun swiftc Stocked/RecipeFinderCore.swift scripts/RecipeFinderCoreChecks.swift -o /tmp/stocked-finder-checks
// /tmp/stocked-finder-checks
import Foundation

@main struct RecipeFinderCoreChecks {
    static func main() {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) {
            checks += 1
            precondition(condition(), "FAILED: \(label)")
        }
        var flow = FinderFlow()
        var request = FinderRequestState()
        let first = request.begin()
        check(request.phase == .loading && request.isWorking && request.isBlocking, "Loading state")
        check(request.preview(first, count: 2) && !request.isBlocking, "Preview ends blocking state")
        let second = request.begin()
        check(!request.complete(first, count: 99), "Stale completion discarded")
        check(!request.fail(first), "Stale error discarded")
        check(request.complete(second, count: 4) && request.count == 4, "Actual count completion")
        let third = request.begin(); request.cancel()
        check(!request.complete(third, count: 999), "Cancelled completion discarded")
        let fourth = request.begin()
        check(request.fail(fourth) && request.phase == .failed, "Error state")
        let retry = request.begin()
        check(request.complete(retry, count: 0) && request.count == 0 && request.phase == .ready, "Retry empty results")
        flow.filters.toggle(.dinner, in: .meal)
        flow.filters.toggle(.lunch, in: .meal)
        check(flow.filters[.meal] == [.dinner, .lunch], "Meal multi-select")
        flow.next(); check(flow.phase == .quiz(1), "Next")
        check(!flow.back() && flow.phase == .quiz(0), "Back")
        check(flow.filters[.meal].count == 2, "Back preserves state")
        check(flow.back(), "First step returns to hub")
        flow.start(search: false); check(flow.filters[.meal].count == 2, "Session resume preserves draft")
        for category in [FinderCategory.ingredient, .cuisine, .diet] {
            let specific = category.options.first!, neutral = category == .diet ? FinderChoice.noRestrictions : .noPreference
            flow.filters.toggle(specific, in: category); flow.filters.toggle(neutral, in: category)
            check(flow.filters[category] == [neutral], "Neutral clears \(category)")
            flow.filters.toggle(specific, in: category)
            check(flow.filters[category] == [specific], "Specific clears neutral \(category)")
        }
        flow.filters.toggle(.quick, in: .mood); flow.filters.toggle(.surpriseMe, in: .mood)
        check(flow.filters[.mood] == [.surpriseMe], "Surprise exclusive")
        flow.filters.toggle(.comfort, in: .mood)
        check(flow.filters[.mood] == [.comfort], "Mood clears surprise")
        flow.filters.toggle(.under15, in: .time); flow.filters.toggle(.under30, in: .time)
        check(flow.filters[.time] == [.under30], "Time single select")
        flow.filters.toggle(.useWhatIHave, in: .kitchen); flow.filters.toggle(.canShop, in: .kitchen)
        check(flow.filters[.kitchen] == [.canShop], "Kitchen single select")
        flow.phase = .quiz(6); flow.next(); check(flow.phase == .review, "Seven steps to review")
        flow.edit(.ingredient); check(flow.phase == .quiz(1), "Edit targeted step")
        flow.next(); check(flow.phase == .review, "Edit returns to review")
        flow.edit(.meal); flow.next(skip: true)
        check(flow.filters[.meal].isEmpty && flow.phase == .review, "Skip edit clears only category")
        flow.phase = .results; check(!flow.back() && flow.phase == .review, "Quiz results back")
        check(!flow.back() && flow.phase == .quiz(6), "Review back")
        flow.start(search: true); check(flow.back(), "Search results back")
        let retained = flow.filters
        flow.requestClear(); check(flow.needsClearConfirmation && flow.filters == retained, "Clear requires confirmation")
        flow.needsClearConfirmation = false; check(flow.filters == retained, "Cancel clear preserves choices")
        flow.clear(); check(!flow.filters.hasChoices && flow.phase == .quiz(0), "Confirm clears")
        flow.requestClear(); check(!flow.needsClearConfirmation, "Empty clear no prompt")

        for (choice, boundary) in [(FinderChoice.under15, 15), (.under30, 30), (.under45, 45), (.under60, 60)] {
            check(FinderQuery.acceptsTime(boundary, selection: choice), "Inclusive time boundary \(boundary)")
            check(!FinderQuery.acceptsTime(boundary + 1, selection: choice), "Above boundary \(boundary)")
            check(FinderQuery.acceptsTime(boundary - 1, selection: choice), "Below boundary \(boundary)")
            check(!FinderQuery.acceptsTime(nil, selection: choice), "Unknown excludes \(choice)")
        }
        check(!FinderQuery.acceptsTime(60, selection: .over60), "Over60 excludes60")
        check(FinderQuery.acceptsTime(61, selection: .over60), "Over60 includes61")
        check(FinderQuery.acceptsTime(nil, selection: .noTimeLimit), "Unknown includes unlimited")
        for (text, expected) in [("PT1H30M", 90), ("1 hour 15 minutes", 75), ("15 min", 15), ("PT30S", 1), ("45", 45), ("1.5 hours", 90), ("P1DT1H", 1500)] {
            check(FinderDuration.minutes(text) == expected, "Parse total \(text)")
        }
        for text in ["", "unknown", "-15 min", "15–30 min", "1 hr 30", "P1M"] { check(FinderDuration.minutes(text) == nil, "Do not guess total \(text)") }
        let stock = [FinderQuantityPool.Stock(family: "weight", amount: 500)]
        let same = FinderQuantityPool.Need(family: "weight", amount: 300, matchingStock: [0])
        let repeated = FinderQuantityPool.coverage(stock: stock, needs: [same, same])
        check(repeated.required == 2 && repeated.have == 1 && repeated.uncertain == 0, "Repeated lines spend stock once")
        let exact = FinderQuantityPool.coverage(stock: stock, needs: [.init(family: "weight", amount: 500, matchingStock: [0])])
        check(exact.have == 1 && exact.uncertain == 0, "Exact quantity sufficient")
        let empty = FinderQuantityPool.coverage(stock: [.init(family: "weight", amount: 0)], needs: [same])
        check(empty.have == 0, "Zero stock unavailable")
        let negative = FinderQuantityPool.coverage(stock: [.init(family: "weight", amount: -5)], needs: [same])
        check(negative.have == 0, "Negative stock unavailable")
        let cross = FinderQuantityPool.coverage(stock: stock, needs: [.init(family: "volume", amount: 10, matchingStock: [0])])
        check(cross.have == 1 && cross.uncertain == 1, "No invented density conversion")
        let unspecified = FinderQuantityPool.coverage(stock: stock, needs: [.init(family: nil, amount: nil, matchingStock: [0])])
        check(unspecified.have == 1 && unspecified.uncertain == 1, "Unspecified quantity uncertain")
        let pooled = FinderQuantityPool.coverage(stock: stock + stock, needs: [.init(family: "weight", amount: 1000, matchingStock: [0, 1])])
        check(pooled.have == 1, "Combine compatible containers")

        var a = FinderRecord(id: "a", title: "Jerk Chicken", searchText: FinderQuery.normalize("Jerk Chicken Garlic Jamaican Dinner Description"))
        a.facets = [.meal: [.dinner], .ingredient: [.chicken], .cuisine: [.jamaican], .diet: [.vegetarian, .pescatarian], .mood: [.comfort]]
        a.totalMinutes = 30; a.rating = 4; a.ratingCount = 3; a.addedAt = Date(timeIntervalSince1970: 100)
        a.lastCooked = Date(timeIntervalSince1970: 100); a.cookCount = 2; a.required = 10; a.have = 10
        var b = a; b.id = "b"; b.title = "Apple"; b.totalMinutes = 15; b.rating = 5
        b.ratingCount = 1; b.addedAt = Date(timeIntervalSince1970: 200); b.lastCooked = Date(timeIntervalSince1970: 200); b.cookCount = 4; b.have = 7
        var unknown = FinderRecord(id: "u", title: "Unknown", searchText: "unknown")
        unknown.required = 10
        var filters = FinderFilters()
        filters[.meal] = [.dinner]; filters[.ingredient] = [.chicken, .fish]; filters[.cuisine] = [.jamaican]
        check(FinderQuery.matches(a, filters: filters), "AND categories, OR ingredient")
        filters[.meal] = [.breakfast]; check(!FinderQuery.matches(a, filters: filters), "Different category excludes")
        filters[.meal] = [.dinner, .breakfast]; check(FinderQuery.matches(a, filters: filters), "OR meals")
        filters[.diet] = [.vegetarian, .vegan]; check(!FinderQuery.matches(a, filters: filters), "AND dietary")
        filters[.diet] = [.vegetarian, .pescatarian]; check(FinderQuery.matches(a, filters: filters), "Every diet satisfied")
        filters[.diet] = []; filters[.mood] = [.quick]
        check(FinderQuery.matches(a, filters: filters), "Quick total30")
        a.totalMinutes = 31; check(!FinderQuery.matches(a, filters: filters), "Quick excludes31")
        filters[.mood] = [.quick, .comfort]; check(FinderQuery.matches(a, filters: filters), "Mood OR quick or comfort")
        filters = FinderFilters(); filters.query = "  GARL Jam  "
        check(FinderQuery.matches(a, filters: filters), "Case trimmed partial multi-field search")
        filters.query = "does not exist"; check(FinderQuery.results([a, b], filters: filters).isEmpty, "Empty search")
        filters.query = ""; filters[.kitchen] = [.useWhatIHave]
        check(FinderQuery.matches(a, filters: filters), "Full kitchen match")
        a.uncertain = 1; check(!FinderQuery.matches(a, filters: filters), "Unknown quantity not ready")
        a.uncertain = 0; filters[.kitchen] = [.mostlyHave]
        check(FinderQuery.matches(b, filters: filters), "70 percent inclusive")
        b.have = 6; check(!FinderQuery.matches(b, filters: filters), "Below70 excluded")
        filters[.kitchen] = [.canShop]; check(FinderQuery.matches(unknown, filters: filters), "Shopping not inventory gated")
        filters[.kitchen] = [.noPreference]; check(FinderQuery.matches(unknown, filters: filters), "No kitchen preference")
        filters[.meal] = [.dinner]; filters.remove(.dinner, in: .meal)
        check(filters[.meal].isEmpty, "Remove chip")
        filters.selections = [.meal: [.dinner]]; check(FinderQuery.matches(a, filters: filters), "All filters shared selector")
        filters = FinderFilters(); a.totalMinutes = 30
        let expected: [FinderSort: String] = [.bestMatch: "b", .readyToCook: "a", .fastest: "b", .highestRated: "b", .recentlyAdded: "b", .recentlyCooked: "b", .mostCooked: "b", .az: "b", .za: "u"]
        for sort in FinderSort.allCases {
            filters.sort = sort
            check(FinderQuery.results([a, unknown, b], filters: filters).first?.id == expected[sort], "Sort \(sort)")
        }
        for sort in [FinderSort.fastest, .highestRated, .recentlyAdded, .recentlyCooked, .mostCooked] {
            filters.sort = sort
            check(FinderQuery.results([unknown, a, b], filters: filters).last?.id == "u", "Missing fields last \(sort)")
        }
        filters.sort = .bestMatch; filters[.mood] = [.surpriseMe]
        check(FinderQuery.results([a, b], filters: filters).map(\.id) == FinderQuery.results([b, a], filters: filters).map(\.id), "Deterministic variety")
        filters[.diet] = [.vegan]; check(FinderQuery.results([a, b], filters: filters).isEmpty, "Discovery never relaxes diet")
        check(a.title == "Jerk Chicken", "Source collection unmutated")
        filters = FinderFilters()
        filters[.mood] = [.comfort]; filters[.cuisine] = [.jamaican]; filters[.diet] = [.vegan]
        filters[.time] = [.under30]; filters[.kitchen] = [.useWhatIHave]; filters.query = "chicken"
        let alternatives = FinderQuery.alternatives(for: filters)
        check(alternatives.count == 3, "Only active soft categories broaden")
        check(alternatives[0].removed == [.comfort], "Mood broadens first")
        check(alternatives[1].removed == [.comfort, .jamaican], "Cuisine broadens second")
        for alternative in alternatives {
            check(alternative.filters[.diet] == [.vegan], "Alternative preserves diet")
            check(alternative.filters[.kitchen] == [.useWhatIHave], "Alternative preserves kitchen")
            check(alternative.filters.query == "chicken", "Alternative preserves search")
            check(!FinderQuery.matches(a, filters: alternative.filters), "Alternative never admits non-vegan")
        }
        a.hasAllergenConflict = true
        check(!FinderQuery.matches(a, filters: FinderQuery.alternatives(for: filters).last!.filters), "Allergens cannot broaden")
        check(filters[.mood] == [.comfort], "Preview never changes requested filters")
        check(FinderQuery.alternatives(for: FinderFilters()).isEmpty, "No fake alternative for empty choices")
        print("Passed \(checks) Find a Recipe core checks (native macOS; no simulator).")
    }
}
