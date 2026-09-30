import XCTest
import SwiftUI
@testable import Stocked

@MainActor
final class RecipePhotoPlumbingTests: XCTestCase {
    func testRecipeHeroForwardsURLAndPersonalPhotoToSharedLoader() throws {
        let url = "https://example.com/chicken-wings.jpg"
        let data = Data([1, 2, 3])
        let hero = RecipeHeroImage(imageData: data, imageURL: url, recipeName: "Chicken Wings", height: 180)
        let child = try XCTUnwrap(hero.body as? CachedAsyncImage)
        XCTAssertEqual(child.url, url)
        XCTAssertEqual(child.imageData, data)
        XCTAssertEqual(child.height, 180)
        XCTAssertEqual(child.resolveName, "Chicken Wings")
    }
}
