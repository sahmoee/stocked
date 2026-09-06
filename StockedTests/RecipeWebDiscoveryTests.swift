import XCTest
@testable import Stocked

@MainActor final class RecipeWebDiscoveryTests: XCTestCase {
    func testUnifiedResultsMergeAndSortWithoutSourceSections() throws {
        let filters = FinderFilters()
        let webResponse = try FinderService.webQuery([web()], filters: filters, saved: [], history: [], inventory: [], allergens: [])
        var cached = try XCTUnwrap(webResponse.hits.first)
        cached.recipe.title = "Saved version"
        let local = FinderResponse(hits: [cached], count: 1, catalogueUnavailable: false, matchedIdentities: [cached.id])
        let merged = FinderService.merge(local: local, web: webResponse, filters: filters, limit: 60)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.hits.first?.recipe.title, "Saved version")
        XCTAssertEqual(merged.matchedIdentities.count, 1)
    }
    func testUnifiedCountDeduplicatesRecordsOutsideVisibleLocalWindow() throws {
        let webResponse = try FinderService.webQuery([web()], filters: FinderFilters(), saved: [], history: [], inventory: [], allergens: [])
        let id = try XCTUnwrap(webResponse.hits.first?.id)
        let local = FinderResponse(hits: [], count: 8005, catalogueUnavailable: false, matchedIdentities: [id])
        let merged = FinderService.merge(local: local, web: webResponse, filters: FinderFilters(), limit: 60)
        XCTAssertEqual(merged.count, 8005)
        XCTAssertEqual(merged.hits.count, 1)
    }
    func testUnifiedEmptyWebDoesNotHideCachedResults() throws {
        let local = try FinderService.webQuery([web()], filters: FinderFilters(), saved: [], history: [], inventory: [], allergens: [])
        let empty = FinderResponse(hits: [], count: 0, catalogueUnavailable: false)
        let merged = FinderService.merge(local: local, web: empty, filters: FinderFilters(), limit: 60)
        XCTAssertEqual(merged.count, local.count)
        XCTAssertEqual(merged.hits.map(\.id), local.hits.map(\.id))
    }
    private func web(tags: [String] = [], time: String = "30 min") -> WebRecipe {
        WebRecipe(title: "Jamaican Chicken", sourceURL: "https://example.com/chicken", sourceName: "Publisher", sourceDomain: "example.com",
                  imageURL: "https://example.com/image.jpg", description: "Original description", prepTime: "10 min", cookTime: "20 min",
                  totalTime: time, servings: "4", difficulty: "", category: "Dinner", cuisine: "Jamaican",
                  ingredients: ["500 g chicken", "1 tsp salt", "2 cups rice"], steps: [.init(index: 0, text: "Cook until done.", name: nil)],
                  tags: tags, rating: 4.2, ratingCount: 37, calories: nil, cachedAt: Date())
    }
    func testWebUsesSameStrictSelectorAndRealRatings() throws {
        var filters = FinderFilters(); filters[.ingredient] = [.chicken]; filters[.cuisine] = [.jamaican]; filters[.time] = [.under30]
        let response = try FinderService.webQuery([web()], filters: filters, saved: [], history: [], inventory: [], allergens: [])
        XCTAssertEqual(response.count, 1); XCTAssertEqual(response.source, .web)
        XCTAssertEqual(response.hits.first?.record.rating, 4.2)
        XCTAssertEqual(response.hits.first?.publisherRatingCount, 37)
        XCTAssertEqual(response.hits.first?.record.have, 0)
        filters[.diet] = [.vegan]
        XCTAssertEqual(try FinderService.webQuery([web()], filters: filters, saved: [], history: [], inventory: [], allergens: []).count, 0)
        filters[.diet] = []; filters[.kitchen] = [.useWhatIHave]
        XCTAssertEqual(try FinderService.webQuery([web()], filters: filters, saved: [], history: [], inventory: [], allergens: []).count, 0)
    }
    func testDietaryMetadataAndRatingScaleParser() {
        let html = #"<script type="application/ld+json">{"@type":"Recipe","name":"Vegetable Rice","image":"https://example.com/rice.jpg","recipeIngredient":["rice","carrots"],"recipeInstructions":"Cook rice and carrots until tender.","suitableForDiet":"https://schema.org/VeganDiet","aggregateRating":{"ratingValue":9,"bestRating":10,"ratingCount":7}}</script>"#
        let result = JSONLDRecipeParser.parse(html: html, pageURL: "https://example.com/rice")
        XCTAssertTrue(result?.tags.contains("Vegan") == true)
        XCTAssertNil(result?.rating); XCTAssertNil(result?.ratingCount)
    }
    func testSourceSavedRecipeIsNotDuplicatedByWebSearch() throws {
        let page = web()
        var saved = UserRecipe(title: page.title); saved.sourceURL = page.sourceURL
        let response = try FinderService.webQuery([page, page], filters: FinderFilters(), saved: [saved], history: [], inventory: [], allergens: [])
        XCTAssertEqual(response.count, 1); XCTAssertNil(response.hits.first?.databaseEntry)
        XCTAssertEqual(response.hits.first?.recipe.id, saved.id)
    }
    func testBrowserFailedNavigationInvalidatesImport() {
        var page = RecipeBrowserPageState(); page.finished(URL(string: "https://example.com/recipe"))
        XCTAssertNotNil(page.importURL)
        page.started(); XCTAssertNil(page.importURL)
        page.failed("Offline"); XCTAssertNil(page.importURL)
    }
    func testPublisherAttributionRequiresARealHostBoundary() {
        XCTAssertNotNil(RecipeSourceRegistry.source(for: "www.allrecipes.com"))
        XCTAssertNil(RecipeSourceRegistry.source(for: "allrecipes.com.unrelated.example"))
        XCTAssertNil(RecipeSourceRegistry.source(for: "notallrecipes.com"))
    }
    func testPreviewPrefillPreservesPublisherFields() {
        let entry = RecipeDatabaseEntry(title: "Original", description: "Original description", sourceURL: "https://example.com/original", sourceName: "Publisher",
                                       prepTime: "10 min", cookTime: "20 min", totalTime: "30 min", servings: "4", category: "Dinner", cuisine: "Jamaican",
                                       tags: ["One Pot"], ingredients: ["1 cup rice"], steps: ["Cook rice."], imageURL: "https://example.com/image.jpg")
        var form = AddRecipeForm(); form.fill(from: entry)
        XCTAssertEqual(form.sourceURL, entry.sourceURL); XCTAssertEqual(form.steps, entry.steps)
        XCTAssertEqual(form.tags, entry.tags); XCTAssertEqual(form.totalTime, entry.totalTime)
    }

    func testRenderedRecipeImportUsesSourceMetadataWithoutNetwork() async throws {
        let html = #"<script type="application/ld+json">{"@type":"Recipe","name":"Rice &amp; Beans","image":{"contentUrl":"/rice.jpg"},"recipeYield":"4 servings","recipeIngredient":["&#189; cup rice","1 cup beans"],"recipeInstructions":["Mix.","<b>Cook</b> until tender."]}</script>"#
        let url = try XCTUnwrap(URL(string: "https://example.com/rice"))
        let parsed = await RecipeImportCoordinator.parsePage(html: html, url: url, allowTextFallback: false)
        XCTAssertEqual(parsed?.form.title, "Rice & Beans")
        XCTAssertEqual(parsed?.form.imageURL, "https://example.com/rice.jpg")
        XCTAssertEqual(parsed?.form.ingredients.first, "½ cup rice")
        XCTAssertEqual(parsed?.form.steps.first, "Mix.")
        XCTAssertEqual(parsed?.form.sourceURL, url.absoluteString)
        XCTAssertEqual(parsed?.form.servings, "4 servings")
        XCTAssertEqual(parsed?.source, "example.com")
    }
    func testRenderedImportRejectsNonRecipeAndOversizedSnapshots() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/rice"))
        let empty = await RecipeImportCoordinator.parsePage(html: "<h1>No recipe</h1>", url: url, allowTextFallback: false)
        XCTAssertNil(empty)
        let large = await RecipeImportCoordinator.parsePage(html: String(repeating: "x", count: 3_000_001), url: url)
        XCTAssertNil(large)
    }
    func testCancelledImportCannotPublishAForm() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/rice"))
        let html = #"<script type="application/ld+json">{"@type":"Recipe","name":"Rice","recipeIngredient":["rice"],"recipeInstructions":["Cook rice until tender."]}</script>"#
        let task = Task {
            try? await Task.sleep(for: .milliseconds(10))
            return await RecipeImportCoordinator.parsePage(html: html, url: url)
        }
        task.cancel()
        let result = await task.value
        XCTAssertNil(result)
    }
    func testExactDuplicateDistinguishesDifferentPublishers() {
        var form = AddRecipeForm(); form.title = "Rice"; form.sourceURL = "https://example.com/rice?utm_source=stocked#recipe"
        var saved = UserRecipe(title: "Rice"); saved.sourceURL = "https://www.example.com/rice"
        XCTAssertEqual(RecipeImportQuality.exactDuplicate(form, in: [saved])?.id, saved.id)
        saved.sourceURL = "https://example.com/rice?igshid=oldtracker"
        XCTAssertEqual(RecipeImportQuality.exactDuplicate(form, in: [saved])?.id, saved.id)
        saved.sourceURL = "https://other.example/rice"
        XCTAssertNil(RecipeImportQuality.exactDuplicate(form, in: [saved]))
        form.sourceURL = ""; saved.sourceURL = ""
        XCTAssertNil(RecipeImportQuality.exactDuplicate(form, in: [saved]))
    }
    func testImportURLPreservesFunctionalQueryAndRejectsUnsafeLinks() {
        XCTAssertEqual(RecipeImportCoordinator.normalizedURLString(from: "Try https://example.com/rice?id=7&utm_source=a"), "https://example.com/rice?id=7")
        XCTAssertNil(RecipeImportCoordinator.normalizedURLString(from: "https://user:pass@example.com"))
        XCTAssertNil(RecipeImportCoordinator.normalizedURLString(from: "https://127.0.0.1/recipe"))
    }
    func testTextFallbackRequiresRecipeSectionsAndPreservesHyphenatedTitle() async throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/no-bake"))
        let html = "<title>No-Bake Rice &amp; Beans | Publisher</title><main><h1>No-Bake Rice</h1><h2>Ingredients</h2><p>1 cup rice</p><p>2 cups beans</p><h2>Instructions</h2><p>Mix the prepared rice and beans together in a bowl.</p><p>Serve immediately with vegetables.</p></main>"
        let result = await RecipeImportCoordinator.parsePage(html: html, url: url)
        XCTAssertEqual(result?.form.title, "No-Bake Rice & Beans")
        XCTAssertEqual(result?.form.sourceURL, url.absoluteString)
        let notRecipe = await RecipeImportCoordinator.parsePage(html: "<main><h1>Contact us</h1><p>Welcome to the recipe website. Read our privacy policy and subscribe to our weekly cooking newsletter.</p></main>", url: url)
        XCTAssertNil(notRecipe)
    }
    func testSingleInstructionObjectAndNestedSections() {
        let html = #"<script type="application/ld+json">{"@type":"Recipe","name":"Rice","recipeIngredient":["1 cup rice"],"recipeInstructions":{"@type":"HowToStep","text":"Stir."}}</script>"#
        let result = JSONLDRecipeParser.parse(html: html, pageURL: "https://example.com/rice")
        XCTAssertEqual(result?.steps.map(\.text), ["Stir."])
    }
    func testOversizedRecipeDoesNotSilentlyDropIngredients() throws {
        let payload: [String: Any] = ["@type": "Recipe", "name": "Rice", "recipeIngredient": Array(repeating: "rice", count: 501), "recipeInstructions": ["Cook until tender."]]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let result = JSONLDRecipeParser.parse(html: "<script type=\"application/ld+json\">\(json)</script>", pageURL: "https://example.com/rice")
        XCTAssertNil(result)
    }
    func testInstructionSectionOverflowDoesNotDropFinalSteps() throws {
        let instructions: [[String: Any]] = [
            ["@type": "HowToSection", "itemListElement": Array(repeating: ["text": "Stir."], count: 500)],
            ["@type": "HowToStep", "text": "Cook until safely done."]
        ]
        let payload: [String: Any] = ["@type": "Recipe", "name": "Rice", "recipeIngredient": ["rice"], "recipeInstructions": instructions]
        let json = String(decoding: try JSONSerialization.data(withJSONObject: payload), as: UTF8.self)
        let result = JSONLDRecipeParser.parse(html: "<script type=\"application/ld+json\">\(json)</script>", pageURL: "https://example.com/rice")
        XCTAssertTrue(result?.steps.isEmpty == true)
    }
}
