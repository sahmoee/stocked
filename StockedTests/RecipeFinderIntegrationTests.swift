import XCTest
@testable import Stocked

final class RecipeFinderIntegrationTests: XCTestCase {
    func testJamaicanRecipesKeepSpecificAndParentCuisine() {
        XCTAssertEqual(RecipeTaxonomy.canonicalCuisine("Jamaican"), "Jamaican")
        XCTAssertEqual(RecipeTaxonomy.parentCuisine("Jamaican"), "Caribbean")
        var recipe = UserRecipe(title: "Jamaican Brown Stew Chicken")
        recipe.cuisine = "Caribbean" // historical collapsed record
        recipe.tags = ["Main Course", "Chicken"]
        recipe.ingredients = [RecipeIngredient(name: "chicken", amount: "1 kg")]
        var filters = FinderFilters()
        filters[.ingredient] = [.chicken]; filters[.cuisine] = [.jamaican]; filters[.meal] = [.dinner]
        let record = FinderData.record(recipe, entry: nil, history: [], inventory: [], filters: filters)
        XCTAssertTrue(FinderQuery.matches(record, filters: filters))
        XCTAssertTrue(record.facets[.cuisine, default: []].contains(.caribbean))
        XCTAssertTrue(RecipeFacets.matches(recipe, cuisine: "Jamaican"))
        XCTAssertEqual(RecipeFacets.count(cuisine: "Jamaican", in: [recipe]), 1)
        XCTAssertEqual(RecipeFacets.count(cuisine: "Caribbean", in: [recipe]), 1)
        filters[.mood] = [.comfort]
        XCTAssertFalse(FinderQuery.matches(record, filters: filters), "Do not invent Comfort metadata")
        XCTAssertTrue(FinderQuery.matches(record, filters: FinderQuery.alternatives(for: filters)[0].filters))
        XCTAssertEqual(RecipeTaxonomy.resolvedCuisine("Caribbean", title: "Cuban Chicken", keywords: []), "Caribbean")
        XCTAssertEqual(RecipeTaxonomy.resolvedCuisine("American", title: "Smoky Cola Jerky", keywords: []), "American")
    }
    func testSharedAvailabilityExcludesZeroContainers() {
        var item = LocalInventoryItem(name: "Rice"); item.quantity = 0; item.level = 1
        XCTAssertTrue(KitchenAvailability.availableItems(in: [item]).isEmpty)
    }
    func testQuantityConversionAndExpiredStock() {
        var rice = LocalInventoryItem(name: "Rice"); rice.quantity = 1; rice.level = 1
        rice.sizeAmount = 1; rice.sizeUnit = "kg"
        let ingredient = RecipeIngredient(name: "rice", amount: "500 g", quantity: 500, unit: "g")
        let result = FinderData.coverage([ingredient], inventory: [rice])
        XCTAssertEqual(result.have, 1); XCTAssertEqual(result.uncertain, 0)
        rice.expirationDate = Date(timeIntervalSinceNow: -100)
        XCTAssertEqual(FinderData.coverage([ingredient], inventory: [rice]).have, 0)
    }
    func testOptionalIngredientsAndUnknownAmounts() {
        var rice = LocalInventoryItem(name: "Rice"); rice.level = 1
        let optional = RecipeIngredient(name: "parsley", amount: "", isOptional: true)
        let unknown = RecipeIngredient(name: "rice", amount: "to taste")
        let result = FinderData.coverage([optional, unknown], inventory: [rice])
        XCTAssertEqual(result.required, 1); XCTAssertEqual(result.have, 1); XCTAssertEqual(result.uncertain, 1)
    }
    func testSourceMetadataAndUnknownTimeAreNotFabricated() {
        var recipe = UserRecipe(title: "Soup")
        recipe.cookTime = "15 min" // prep time is unknown: cannot assume zero.
        recipe.ingredients = [RecipeIngredient(name: "carrot", amount: "1")]
        let record = FinderData.record(recipe, entry: nil, history: [], inventory: [], filters: FinderFilters())
        XCTAssertNil(record.totalMinutes); XCTAssertNil(record.rating); XCTAssertNil(record.ratingCount)
        XCTAssertTrue(record.facets[.diet, default: []].isEmpty)
    }
    func testLocalizedPastMealHistoryAndActualRatings() {
        var recipe = UserRecipe(title: "Soup"); recipe.prepTime = "10 min"; recipe.cookTime = "20 min"
        var meal = LocalPastMeal(title: "Soup", date: DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none))
        meal.recipeId = recipe.id; meal.rating = 3
        let record = FinderData.record(recipe, entry: nil, history: [meal], inventory: [], filters: FinderFilters())
        XCTAssertEqual(record.totalMinutes, 30); XCTAssertEqual(record.rating, 3); XCTAssertEqual(record.ratingCount, 1)
        XCTAssertEqual(record.cookCount, 1); XCTAssertNotNil(record.lastCooked)
    }
    func testAllSevenCategoriesAndStableSelectionLabels() {
        XCTAssertEqual(FinderCategory.allCases.count, 7)
        for category in FinderCategory.allCases {
            XCTAssertFalse(category.question.isEmpty); XCTAssertFalse(category.icon.isEmpty)
            for option in category.options {
                XCTAssertFalse(option.label.isEmpty)
                var filters = FinderFilters(); filters.toggle(option, in: category)
                XCTAssertTrue(filters[category].contains(option)); filters.remove(option, in: category)
                XCTAssertFalse(filters[category].contains(option))
            }
        }
    }
    func testSavingDatabaseResultPreservesAmountsAndAttribution() {
        let entry = RecipeDatabaseEntry(title: "Rice", description: "Fixture", sourceURL: "https://example.com/rice",
            sourceName: "Original publisher", prepTime: "0 min", cookTime: "20 min", totalTime: "20 min",
            servings: "2", category: "Side", cuisine: "American", tags: [], ingredients: ["500 g rice"],
            steps: ["Cook rice."], imageURL: "https://example.com/rice.jpg")
        let recipe = FinderData.recipe(entry, parseAmounts: true)
        XCTAssertEqual(recipe.sourceURL, entry.sourceURL); XCTAssertEqual(recipe.sourceName, entry.sourceName)
        XCTAssertEqual(recipe.imageURL, entry.imageURL)
        XCTAssertEqual(recipe.ingredients.first?.quantity, 500)
        XCTAssertFalse(recipe.ingredients.first?.amount.isEmpty ?? true)
    }
}
