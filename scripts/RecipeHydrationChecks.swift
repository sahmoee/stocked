// Compiled with production DBMigration.swift and extracted production recipe models.
import Foundation

// Persistence doubles have no filesystem/defaults access. They isolate schema metadata
// while exercising the production migration and the production UserRecipe Codable shape.
final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    func set(_ value: Any, forKey key: String) { values[key] = value }
}
final class LocalDatabase {
    static let shared = LocalDatabase()
    private var values: [String: Data] = [:]
    func save<T: Codable>(_ value: T, key: String) { values[key] = try! JSONEncoder().encode(value) }
    func load<T: Codable>(_ type: T.Type, key: String) -> T? {
        values[key].flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
    func loadArray<T: Codable>(_ type: T.Type, key: String) -> [T]? { load([T].self, key: key) }
}
struct LocalInventoryItem: Codable {
    enum StorageCategory: String, Codable { case fridge = "Fridge", drinks = "Drinks" }
    var storageCategory: StorageCategory
}
struct LocalGroceryItem: Codable {}
struct LocalPastMeal: Codable {}

@main struct RecipeHydrationChecks {
    static func testSourceLinkedTextOnlyRecipeSurvivesHydrationAndResave() throws -> [String] {
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
        let saved = [textOnly, https, bytes, relative, http, sourceLess]
        var failures: [String] = []
        // Every supported schema version, plus a forward version: hydration is lossless.
        for version in 0...(DBSchema.recipeVersion + 1) {
            DBSchema.setVersion(version, "recipes")
            let hydrated = DBMigrations.migrateRecipes(saved)
            if hydrated != saved { failures.append("version \(version): saved identities/content lost (\(hydrated.count)/6 retained)") }
            if DBSchema.storedVersion("recipes") != max(version, DBSchema.recipeVersion) {
                failures.append("version \(version): schema stamp changed incorrectly")
            }
            let persisted = try JSONEncoder().encode(hydrated)
            let reloaded = try JSONDecoder().decode([UserRecipe].self, from: persisted)
            if DBMigrations.migrateRecipes(reloaded) != saved {
                failures.append("version \(version): encode/decode/re-hydration lost saved content")
            }
        }
        for image in [nil, "/soup.jpg", "http://publisher.example/soup.jpg"] as [String?] {
            if RecipeDisplayPolicy.isPresentable(title: "Bean Soup", imageURL: image,
                ingredients: 3, steps: 1) { failures.append("public policy accepted missing/ineligible artwork") }
        }
        if !RecipeDisplayPolicy.isPresentable(title: "Bean Soup",
            imageURL: "https://publisher.example/soup.jpg", ingredients: 3, steps: 1) {
            failures.append("public policy rejected eligible artwork")
        }
        return failures
    }
    static func main() throws {
        let failures = try testSourceLinkedTextOnlyRecipeSurvivesHydrationAndResave()
        guard failures.isEmpty else {
            failures.forEach { print("FAIL: \($0)") }
            exit(1)
        }
        print("PASS: testSourceLinkedTextOnlyRecipeSurvivesHydrationAndResave (6 fixtures, schema versions 0/current/future, Codable resave)")
    }
}
// Portable provenance is nil in these fixtures; only its size-error dependency is doubled.
enum PortableCooklang {
    static let maximumBytes = 60 * 1024
    enum ParseError: Error { case tooLarge }
}

// Title quality is outside this image-boundary regression.
enum RecipeQuality {
    static func hasMeaningfulTitle(_ title: String) -> Bool { !title.isEmpty }
}
