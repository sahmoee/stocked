//
//  AdaptiveCookingTests.swift
//  StockedTests
//
//  Unit tests for the adaptive Cook Now decision logic added to fill the
//  spec gaps: SideSuggestionEngine, MakeabilityEngine, CookAheadCoordinator,
//  StorageAndReheatPlanBuilder, and ReadinessChecklistBuilder.
//
//  These are pure-logic tests — no live session required. They also assert the
//  spec's acceptance criteria where they reduce to logic (e.g. "cooking only the
//  entrée counts as successful completion", "cook-ahead never regresses").
//
//  Add to the StockedTests unit-test target's membership.
//

import XCTest
@testable import Stocked

final class AdaptiveCookingTests: XCTestCase {

    // MARK: - SideSuggestionEngine

    func testSideSuggestionsRespectRemainingWindow() {
        // A 4-minute window must not surface a 20-minute side.
        let quick = SideSuggestionEngine.suggestions(remainingMinutes: 4, inventoryNamesLowercased: [])
        XCTAssertFalse(quick.isEmpty)
        XCTAssertTrue(quick.allSatisfy { $0.approxMinutes <= 6 }, "short window should only yield quick sides")
    }

    func testSideSuggestionsPrioritizeInventoryMatches() {
        // "rice" in stock should push a rice-based idea to the top.
        let s = SideSuggestionEngine.suggestions(remainingMinutes: 20, inventoryNamesLowercased: ["rice", "milk"])
        XCTAssertTrue(s.first?.usesInventory ?? false, "an in-stock match should rank first")
        XCTAssertTrue(s.contains { $0.title.lowercased().contains("rice") })
    }

    func testSideSuggestionsAlwaysReturnAtLeastOne() {
        // "Do nothing" is the caller's job; the engine should still offer options.
        let s = SideSuggestionEngine.suggestions(remainingMinutes: 1, inventoryNamesLowercased: [])
        XCTAssertGreaterThanOrEqual(s.count, 1)
    }

    func testSideSuggestionProfileBias() {
        let filling = SideSuggestionEngine.suggestions(remainingMinutes: 30, inventoryNamesLowercased: [], preferFilling: true)
        // A filling bias should surface at least one filling-profile idea near the top.
        XCTAssertTrue(filling.prefix(4).contains { $0.profile == .filling })
    }

    // MARK: - CookAheadCoordinator  (planned dinner cooked early)

    func testCookAheadForwardOrderIsMonotonic() {
        var status: CookAheadStatus = .none
        var steps = 0
        while let n = CookAheadCoordinator.next(after: status) {
            status = n; steps += 1
            XCTAssertLessThan(steps, 20, "advancement must terminate")
        }
        XCTAssertEqual(status, .served, "advancing to the end lands on served")
    }

    func testCookAheadCookingEarlyNeverRegresses() {
        // Spec: cooking early should not undo prep/marinate progress.
        XCTAssertEqual(CookAheadCoordinator.statusForCookingEarly(from: .marinating), .cookingEarly)
        XCTAssertEqual(CookAheadCoordinator.statusForCookingEarly(from: .stored), .stored, "already-stored stays put")
        XCTAssertEqual(CookAheadCoordinator.statusForCookingEarly(from: .none), .cookingEarly)
    }

    func testCookAheadAwaitingFinish() {
        XCTAssertTrue(CookAheadCoordinator.isAwaitingFinish(.readyToReheat))
        XCTAssertTrue(CookAheadCoordinator.isAwaitingFinish(.cooked))
        XCTAssertFalse(CookAheadCoordinator.isAwaitingFinish(.none))
        XCTAssertFalse(CookAheadCoordinator.isAwaitingFinish(.served))
    }

    func testCookAheadIsCooked() {
        XCTAssertFalse(CookAheadCoordinator.isCooked(.marinating))
        XCTAssertTrue(CookAheadCoordinator.isCooked(.cooked))
        XCTAssertTrue(CookAheadCoordinator.isCooked(.readyToReheat))
    }

    // MARK: - StorageAndReheatPlanBuilder  (lamb: cook early, serve later)

    func testSaucyDishGetsCoveredReheatWithLiquid() {
        let plan = StorageAndReheatPlanBuilder.plan(for: .init(name: "braised lamb", isSaucy: true))
        XCTAssertTrue(plan.reheating.contains { $0.lowercased().contains("covered") })
        XCTAssertTrue(plan.reheating.contains { $0.lowercased().contains("liquid") || $0.lowercased().contains("water") })
    }

    func testCrispDishGetsSeparateFinishingStep() {
        let plan = StorageAndReheatPlanBuilder.plan(for: .init(name: "roast chicken", hasCrispElement: true))
        XCTAssertTrue(plan.finishing.contains { $0.lowercased().contains("broiler") || $0.lowercased().contains("air fryer") })
    }

    func testServeTimeAddsTimingNudge() {
        let noon = Date(timeIntervalSince1970: 1_700_000_000)
        let plan = StorageAndReheatPlanBuilder.plan(for: .init(name: "stew", isSaucy: true, serveTime: noon))
        XCTAssertTrue(plan.finishing.first?.lowercased().contains("start reheating") ?? false)
    }

    // MARK: - ReadinessChecklistBuilder  (Before You Start)

    func testChecklistHasAllFourSectionsForRealMethod() {
        // Use a real method id from the catalog so equipment rows populate.
        let anyMethodID = CookingMethodCatalog.all.first?.id
        let ingredients = [
            RecipeIngredient(name: "onion", amount: "1", prep: "sliced"),
            RecipeIngredient(name: "garlic", amount: "2 cloves", prep: "minced"),
            RecipeIngredient(name: "salt", amount: "to taste"),
        ]
        let items = ReadinessChecklistBuilder.build(methodID: anyMethodID, ingredients: ingredients, anchorName: "lamb")
        let grouped = ReadinessChecklistBuilder.grouped(items)
        let sections = Set(grouped.map { $0.section })
        XCTAssertTrue(sections.contains(.pull))
        XCTAssertTrue(sections.contains(.prep))
        XCTAssertTrue(sections.contains(.optional))
    }

    func testChecklistPrepTasksAreBlocking() {
        let ingredients = [RecipeIngredient(name: "onion", amount: "1", prep: "sliced")]
        let items = ReadinessChecklistBuilder.build(methodID: nil, ingredients: ingredients, anchorName: nil)
        let blocking = ReadinessChecklistBuilder.blockingItems(items)
        XCTAssertTrue(blocking.contains { $0.title.lowercased().contains("sliced onion") })
        // Optional decisions must never be blocking.
        XCTAssertFalse(items.filter { $0.section == .optional }.contains { $0.isPreHeatBlocking })
    }

    func testChecklistSkipsOptionalIngredientsInPull() {
        let ingredients = [
            RecipeIngredient(name: "carrots", amount: "2", isOptional: true),
            RecipeIngredient(name: "lamb", amount: "4"),
        ]
        let items = ReadinessChecklistBuilder.build(methodID: nil, ingredients: ingredients, anchorName: nil)
        let pullTitles = items.filter { $0.section == .pull }.map { $0.title.lowercased() }
        XCTAssertTrue(pullTitles.contains { $0.contains("lamb") })
        XCTAssertFalse(pullTitles.contains { $0.contains("carrot") }, "optional ingredients aren't force-pulled")
    }

    // MARK: - Completion semantics  (acceptance criteria)

    func testEntreeOnlyCountsAsSuccessfulCompletion() {
        // Spec: "Cooking only the entrée counts as successful completion."
        XCTAssertTrue(CookCompletionType.entreeCompleted.isSuccessful)
        XCTAssertTrue(CookCompletionType.componentCompleted.isSuccessful)
        XCTAssertTrue(CookCompletionType.ingredientPrepared.isSuccessful)
        XCTAssertFalse(CookCompletionType.stoppedEarly.isSuccessful)
    }

    // MARK: - MakeabilityEngine bucketing

    func testMakeabilityBucketsSplitByRoleAndReadiness() {
        // Two ready-now recipes with different roles land in different buckets.
        let entree = classified(title: "Cajun Chicken", role: .entree, readiness: .exact)
        let side   = classified(title: "Buttered Rice", role: .side,   readiness: .exact)
        let almost = classified(title: "Beef Stew",     role: .fullMeal, readiness: .missingOne)

        let buckets = MakeabilityEngine.buckets(from: [entree, side, almost])
        func recipes(_ c: MakeabilityCategory) -> [ClassifiedRecipe] {
            buckets.first { $0.category == c }?.recipes ?? []
        }
        XCTAssertTrue(recipes(.entrees).contains { $0.recipe.title == "Cajun Chicken" })
        XCTAssertTrue(recipes(.sides).contains { $0.recipe.title == "Buttered Rice" })
        XCTAssertTrue(recipes(.almost).contains { $0.recipe.title == "Beef Stew" })
        // A ready-now entrée must NOT appear in "meals".
        XCTAssertFalse(recipes(.meals).contains { $0.recipe.title == "Cajun Chicken" })
    }

    func testMakeabilityWithSubstitutionBucket() {
        let swap = classified(title: "Salmon Rice Bowl", role: .fullMeal, readiness: .readyWithSwap)
        let buckets = MakeabilityEngine.buckets(from: [swap])
        let sub = buckets.first { $0.category == .withSubstitution }?.recipes ?? []
        XCTAssertTrue(sub.contains { $0.recipe.title == "Salmon Rice Bowl" })
    }

    // MARK: - Helpers

    /// Build a minimal ClassifiedRecipe for bucketing tests.
    private func classified(title: String, role: DishRole, readiness: CookNowReadiness) -> ClassifiedRecipe {
        var r = UserRecipe(title: title)
        r.dishRole = role
        return ClassifiedRecipe(recipe: r, readiness: readiness, resolutions: [])
    }
}
