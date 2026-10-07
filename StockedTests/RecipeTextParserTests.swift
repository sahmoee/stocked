import XCTest
@testable import Stocked

final class RecipeTextParserTests: XCTestCase {
    func testHeaderlessNumberedStepsAreNotIngredients() {
        let form = RecipeTextParser.parse("""
        Simple Bread
        1 cup flour
        2 tsp yeast
        1. Mix flour.
        2. Bake.
        """)
        XCTAssertEqual(form.title, "Simple Bread")
        XCTAssertEqual(form.ingredients, ["1 cup flour", "2 tsp yeast"])
        XCTAssertEqual(form.steps, ["Mix flour.", "Bake."])
    }

    func testHeadedRecipeKeepsNumericIngredients() {
        let form = RecipeTextParser.parse("""
        Simple Bread
        Ingredients
        1 cup flour
        Instructions
        1. Mix flour.
        2. Bake.
        """)
        XCTAssertEqual(form.ingredients, ["1 cup flour"])
        XCTAssertEqual(form.steps, ["Mix flour.", "Bake."])
    }

    func testMultiPageMergeKeepsIntentionalRepetition() {
        let merged = RecipeTextParser.mergeOCRPages([
            "Layer Cake\nFor the cake\n1 cup flour\n1 cup sugar\nFor the topping",
            "For the topping\n1 cup sugar\nWhisk until smooth\nWhisk until smooth"
        ])
        let lines = merged.components(separatedBy: "\n")
        // Page overlap ("For the topping") is removed once; the topping's own sugar and
        // the intentionally repeated step survive.
        XCTAssertEqual(lines, ["Layer Cake", "For the cake", "1 cup flour", "1 cup sugar",
                               "For the topping", "1 cup sugar", "Whisk until smooth", "Whisk until smooth"])
    }
}
