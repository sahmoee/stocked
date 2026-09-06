import XCTest
@testable import Stocked

final class InterHubContractTests: XCTestCase {
    func testEveryRouteSurvivesPersistenceRoundTrip() throws {
        let routes: [InterHubRoute] = [
            .tab(.home), .tab(.cook), .tab(.inventory), .tab(.recipes), .tab(.grocery),
            .recipe(id: "recipe-42", kind: .server), .inventoryItem(UUID()),
            .groceryItem(UUID()), .cook(recipeID: "recipe-42"), .search(query: "beans"),
            .scan(.receipt), .scan(.barcode), .presentation(.homeWidgets)
        ]
        for route in routes {
            let data = try JSONEncoder().encode(route)
            XCTAssertEqual(try JSONDecoder().decode(InterHubRoute.self, from: data), route)
        }
    }

    func testActionRegistryHasUniqueActionsAndDurableRoutes() {
        XCTAssertEqual(Set(StockedActionRegistry.all.map(\.id)).count, StockedActionRegistry.all.count)
        XCTAssertTrue(StockedActionID.allCases.allSatisfy {
            StockedActionRegistry.descriptor(for: $0) != nil
        })
        XCTAssertTrue(StockedActionRegistry.all.allSatisfy { !$0.route.deduplicationKey.isEmpty })
    }

    func testEveryHubDeclaresDependencies() {
        XCTAssertEqual(Set(HubDependencyGraph.dependencies.keys), Set(InterHubTab.allCases))
        XCTAssertTrue(HubDependencyGraph.dependencies.values.allSatisfy { !$0.isEmpty })
        XCTAssertTrue(HubDependencyGraph.dependencies[.recipes]?.contains(.inventory) == true)
        XCTAssertTrue(HubDependencyGraph.dependencies[.grocery]?.contains(.plan) == true)
    }

    func testCanonicalUserRecipePreservesBoundaryData() {
        let original = UserRecipe(
            title: "Test Soup", description: "Warm", cookTime: "20 min", prepTime: "5 min",
            servings: 3, cuisine: "Home", tags: ["quick"],
            ingredients: [RecipeIngredient(name: "Beans", amount: "2 cups")],
            instructions: ["Simmer."], imageURL: "https://example.com/soup.jpg",
            sourceURL: "https://example.com/soup", sourceName: "Example", categories: ["Soup"]
        )
        let canonical = CanonicalRecipeDescriptor(original)
        let restored = canonical.userRecipe
        XCTAssertEqual(restored.title, original.title)
        XCTAssertEqual(restored.ingredients, original.ingredients)
        XCTAssertEqual(restored.instructions, original.instructions)
        XCTAssertEqual(restored.sourceURL, original.sourceURL)
        XCTAssertEqual(restored.categories, original.categories)
    }

    func testCanonicalValidationRejectsIncompleteImports() async throws {
        try await MainActor.run {
            var recipe = UserRecipe(title: "No Image", ingredients: [RecipeIngredient(name: "Rice", amount: "1 cup")], instructions: ["Cook."])
            XCTAssertThrowsError(try CanonicalRecipeActions.validate(CanonicalRecipeDescriptor(recipe))) {
                XCTAssertEqual($0 as? CanonicalRecipeValidationError, .missingImage)
            }
            recipe.imageURL = "https://example.com/rice.jpg"
            XCTAssertNoThrow(try CanonicalRecipeActions.validate(CanonicalRecipeDescriptor(recipe)))
        }
    }
}
