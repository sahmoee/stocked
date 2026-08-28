import XCTest
import UIKit
@testable import Stocked

final class RecipeDatabaseChangeTests: XCTestCase {
    func testRecipeMediaStoreRetainsOriginalBytesWithStableReference() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecipeMediaStore(rootDirectory: root)
        let original = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).pngData { context in
            UIColor.systemOrange.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }

        let first = try store.retain(original)
        let second = try store.retain(original)

        XCTAssertEqual(first.storedValue, second.storedValue)
        XCTAssertTrue(first.storedValue.hasPrefix("stocked-recipe-media://originals/"))
        XCTAssertEqual(try store.retainedData(for: first.storedValue), original)
        XCTAssertEqual(store.validateReference(first.storedValue), .success(first))
    }

    func testRecipeMediaStoreFallsBackFromInvalidRemoteToLocalOriginal() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RecipeMediaStore(rootDirectory: root)
        let original = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).pngData { context in
            UIColor.black.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        }

        let reference = try store.resolvedReference(
            remoteURL: "http://insecure.example/image.jpg",
            imageData: original
        )

        XCTAssertTrue(reference.storedValue.hasPrefix("stocked-recipe-media://originals/"))
        XCTAssertEqual(try store.retainedData(for: reference.storedValue), original)
    }

    func testRecipeMediaStoreRejectsMissingOrInvalidMedia() {
        let store = RecipeMediaStore(
            rootDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
        )

        XCTAssertThrowsError(try store.resolvedReference(remoteURL: nil, imageData: nil)) {
            XCTAssertEqual($0 as? RecipeMediaFailure, .missingReference)
        }
        XCTAssertThrowsError(try store.retain(Data("not an image".utf8))) {
            XCTAssertEqual($0 as? RecipeMediaFailure, .invalidImageData)
        }
    }

    func testChangeAppliesInsertUpdateAndDeleteWithoutReloadingSnapshot() {
        let removed = entry(id: UUID(), title: "Remove Me", description: "old")
        let retained = entry(id: UUID(), title: "Retained", description: "old")
        let insertedA = entry(id: UUID(), title: "Inserted A", description: "new")
        let insertedB = entry(id: UUID(), title: "Inserted B", description: "new")
        let updated = entry(id: retained.id, title: retained.title, description: "updated")

        let change = RecipeDatabaseChange(
            revision: 42,
            origin: .householdSync,
            inserted: [insertedA, insertedB],
            updated: [updated],
            deletedIDs: [removed.id],
            totalCount: 3
        )

        let result = change.applying(to: [removed, retained])

        XCTAssertEqual(result.map(\.id), [insertedB.id, insertedA.id, retained.id])
        XCTAssertEqual(result.last?.description, "updated")
        XCTAssertEqual(change.affectedCount, 4)
        XCTAssertFalse(change.isEmpty)
    }

    func testChangeDeduplicatesDamagedInputAndUsesLatestPayload() {
        let id = UUID()
        let stale = entry(id: id, title: "Same Recipe", description: "stale")
        let duplicate = entry(id: id, title: "Same Recipe", description: "duplicate")
        let latest = entry(id: id, title: "Same Recipe", description: "latest")
        let change = RecipeDatabaseChange(
            revision: 7,
            origin: .direct,
            inserted: [],
            updated: [latest],
            deletedIDs: [],
            totalCount: 1
        )

        let result = change.applying(to: [stale, duplicate])

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].description, "latest")
    }

    func testDeletedIdentifierWinsOverConflictingPayload() {
        let doomed = entry(id: UUID(), title: "Doomed", description: "")
        let change = RecipeDatabaseChange(
            revision: 9,
            origin: .sourcePurge,
            inserted: [doomed],
            updated: [doomed],
            deletedIDs: [doomed.id],
            totalCount: 0
        )

        XCTAssertTrue(change.applying(to: [doomed]).isEmpty)
    }

    func testCacheTimestampAloneDoesNotCreateAContentUpdate() {
        let id = UUID()
        let original = entry(id: id, title: "Stable Recipe", description: "same")
        var rediscovered = original
        rediscovered.cachedAt = original.cachedAt.addingTimeInterval(3_600)

        XCTAssertTrue(RecipeDatabase.hasSameRecipeContent(original, rediscovered))

        rediscovered.description = "substantively richer"
        XCTAssertFalse(RecipeDatabase.hasSameRecipeContent(original, rediscovered))
    }

    func testCanonicalIngestionStandardizesTitleAndAcceptsHTTPSArtwork() throws {
        let incoming = entry(
            id: UUID(),
            title: "  GARLIC   BUTTER SALMON  ",
            description: "Dinner"
        )

        let canonical = try RecipeDatabase.canonicalizedForIngestion(
            incoming,
            origin: .harvested
        ).get()

        XCTAssertEqual(canonical.title, "Garlic Butter Salmon")
        XCTAssertEqual(canonical.imageURL, "https://example.com/image.jpg")
        XCTAssertEqual(
            RecipeDatabase.stableDedupKey(forTitle: "Gárlíc—Butter  SALMON"),
            RecipeDatabase.stableDedupKey(forTitle: canonical.title)
        )
    }

    func testCanonicalIngestionQuarantinesBlockedAndImagelessRows() {
        let blocked = entry(
            id: UUID(),
            title: "Valid Dinner",
            description: "",
            sourceName: "Kaggle Food Dataset"
        )
        let imageless = entry(
            id: UUID(),
            title: "Another Dinner",
            description: "",
            imageURL: ""
        )

        switch RecipeDatabase.canonicalizedForIngestion(blocked, origin: .harvested) {
        case .failure(let record): XCTAssertEqual(record.reason, .blockedSource)
        case .success: XCTFail("Blocked provenance entered the canonical store")
        }
        switch RecipeDatabase.canonicalizedForIngestion(imageless, origin: .harvested) {
        case .failure(let record): XCTAssertEqual(record.reason, .missingImage)
        case .success: XCTFail("Imageless row entered the canonical store")
        }
    }

    private func entry(
        id: UUID,
        title: String,
        description: String,
        sourceName: String = "Test",
        imageURL: String = "https://example.com/image.jpg"
    ) -> RecipeDatabaseEntry {
        RecipeDatabaseEntry(
            id: id,
            title: title,
            description: description,
            sourceURL: "https://example.com/\(id.uuidString)",
            sourceName: sourceName,
            prepTime: "",
            cookTime: "",
            totalTime: "",
            servings: "1",
            category: "Dinner",
            cuisine: "American",
            tags: [],
            ingredients: ["1 ingredient"],
            steps: ["Cook it."],
            imageURL: imageURL
        )
    }
}
