import XCTest
import CryptoKit
@testable import Stocked

/// Saved/private recipes may be text-complete. Public catalogue eligibility (artwork,
/// title quality) must never remove them from the user's own library.
@MainActor
final class SavedRecipePreservationTests: XCTestCase {
    func testSourceLinkedTextOnlyRecipeSurvivesHydrationAndResave() async throws {
        let saved = savedFixtures()
        let previousVersion = DBSchema.storedVersion("recipes")
        defer { DBSchema.setVersion(previousVersion, "recipes") }

        // Every supported schema version plus a forward version: hydration is lossless.
        for version in 0...(DBSchema.recipeVersion + 1) {
            DBSchema.setVersion(version, "recipes")
            await LocalDatabase.shared.flush()
            let hydrated = DBMigrations.migrateRecipes(saved)
            XCTAssertEqual(hydrated, saved, "version \(version) lost saved recipes")
            XCTAssertEqual(DBSchema.storedVersion("recipes"), max(version, DBSchema.recipeVersion))

            let reloaded = try JSONDecoder().decode([UserRecipe].self, from: JSONEncoder().encode(hydrated))
            XCTAssertEqual(DBMigrations.migrateRecipes(reloaded), saved, "version \(version) resave lost content")
        }

        // Backup/restore package carries the same text-only records unchanged.
        let key = SymmetricKey(size: .bits256)
        let snapshot = KitchenSnapshot(displayName: "Fixture", inventoryItems: [], groceryItems: [],
                                       pastMeals: [], userRecipes: saved)
        let restored = try KitchenBackupCodec.open(KitchenBackupCodec.seal(snapshot, using: key), using: key)
        XCTAssertEqual(restored.snapshot.userRecipes, saved)
    }

    func testLaunchPurgeKeepsPrivateRecipesWithGenericTitles() async throws {
        let store = GuestDataStore()
        let deadline = Date().addingTimeInterval(10)
        while !store.hasCompletedInitialHydration && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(store.hasCompletedInitialHydration, "Fixture setup requires completed local hydration")
        guard store.hasCompletedInitialHydration else { return }
        let previousUser = store.userRecipes
        let previousGenerated = store.savedGeneratedRecipes
        let previousRemote = store.isApplyingHouseholdRemote
        defer {
            store.isApplyingHouseholdRemote = true
            store.userRecipes = previousUser
            store.savedGeneratedRecipes = previousGenerated
            store.flushPendingSaves()
            store.isApplyingHouseholdRemote = previousRemote
        }

        var dinner = UserRecipe(title: "Dinner")
        dinner.instructions = ["Grandma's Sunday dinner."]
        let mealPlan = UserRecipe(title: "Meal plan")
        var retired = UserRecipe(title: "Retired Source Soup")
        retired.tags = ["kaggle"]
        let generated = GeneratedRecipe(title: "Breakfast", cookTime: "10 min", servings: 1,
                                        difficulty: "Easy", ingredients: [], steps: ["Toast bread."],
                                        tips: "")
        store.isApplyingHouseholdRemote = true
        store.userRecipes = [dinner, mealPlan, retired]
        store.savedGeneratedRecipes = [generated]
        store.isApplyingHouseholdRemote = previousRemote

        _ = await RecipePurge.run(store: store)

        XCTAssertEqual(Set(store.userRecipes.map(\.id)), [dinner.id, mealPlan.id],
                       "Private recipes with generic titles must survive; retired sources are removed")
        XCTAssertEqual(store.savedGeneratedRecipes.map(\.id), [generated.id])
    }

    private func savedFixtures() -> [UserRecipe] {
        var textOnly = UserRecipe(title: "Saved Bean Soup")
        textOnly.sourceURL = "https://publisher.example/soup"
        textOnly.sourceName = "Fixture Publisher"
        textOnly.ingredients = [RecipeIngredient(name: "beans", amount: "1 cup")]
        textOnly.instructions = ["Simmer the beans until tender."]
        textOnly.notes = "Family variation"
        textOnly.collectionSavedByUser = true
        var https = textOnly; https.id = UUID(); https.imageURL = "https://publisher.example/soup.jpg"
        var bytes = textOnly; bytes.id = UUID(); bytes.imageData = Data([1, 2, 3])
        var relative = textOnly; relative.id = UUID(); relative.imageURL = "/soup.jpg"
        var http = textOnly; http.id = UUID(); http.imageURL = "http://publisher.example/soup.jpg"
        var sourceLess = textOnly; sourceLess.id = UUID(); sourceLess.sourceURL = nil
        return [textOnly, https, bytes, relative, http, sourceLess]
    }
}
