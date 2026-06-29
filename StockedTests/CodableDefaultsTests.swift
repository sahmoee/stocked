// CodableDefaultsTests.swift — Tests that saved data survives app updates (#4).
//
// Stocked persists its models as JSON in UserDefaults. When a new build adds a field to a model,
// data saved by an older build will be MISSING that field. If any model field is non-optional and
// lacks a default, decoding that old data throws and the user appears to lose their kitchen. These
// tests decode intentionally-minimal and old-shaped JSON to prove every model tolerates missing
// keys.
//
// Run in the StockedTests unit-test target (same as StockedLogicTests).

import XCTest
@testable import Stocked

final class CodableDefaultsTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String,
                                      file: StaticString = #filePath, line: UInt = #line) -> T? {
        guard let data = json.data(using: .utf8) else {
            XCTFail("bad json literal", file: file, line: line); return nil
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { XCTFail("decode failed: \(error)", file: file, line: line); return nil }
    }

    // MARK: Inventory item

    func testInventoryItemDecodesFromMinimalJSON() {
        // Oldest plausible shape: just a name. Everything else must default.
        let item = decode(LocalInventoryItem.self, #"{"name":"Milk"}"#)
        XCTAssertEqual(item?.name, "Milk")
        XCTAssertNotNil(item, "an inventory item with only a name must still decode")
    }

    func testInventoryItemDecodesWithoutNewerFields() {
        // Simulates data saved before avatarPhotoData/par/etc. existed.
        let json = #"{"name":"Eggs","quantity":2,"level":0.5,"zone":"Fridge"}"#
        let item = decode(LocalInventoryItem.self, json)
        XCTAssertEqual(item?.name, "Eggs")
        XCTAssertEqual(item?.quantity, 2)
    }

    // MARK: Grocery item

    func testGroceryItemDecodesFromMinimalJSON() {
        let g = decode(LocalGroceryItem.self, #"{"name":"Bananas"}"#)
        XCTAssertEqual(g?.name, "Bananas")
        XCTAssertEqual(g?.isChecked, false, "isChecked must default to false")
    }

    func testGroceryItemDecodesWithoutRecipeSource() {
        // recipeSource was added later; old items won't have it.
        let g = decode(LocalGroceryItem.self, #"{"name":"Flour","isChecked":true}"#)
        XCTAssertEqual(g?.name, "Flour")
        XCTAssertEqual(g?.isChecked, true)
    }

    // MARK: Cooking profile

    func testCookingProfileDecodesFromEmptyJSON() {
        // A brand-new or very old profile may be essentially empty.
        let p = decode(UserCookingProfile.self, #"{}"#)
        XCTAssertNotNil(p, "an empty cooking profile must decode to all-defaults")
    }

    func testCookingProfileDecodesWithoutAvatarPhoto() {
        // avatarPhotoData is a newer optional; its absence must be fine.
        let json = #"{"householdSize":2,"avatarEmoji":"chef"}"#
        let p = decode(UserCookingProfile.self, json)
        XCTAssertNotNil(p)
    }

    // MARK: Recipe

    func testGeneratedRecipeDecodesWithoutOptionalImage() {
        let json = #"""
        {"title":"Toast","cookTime":"5 minutes","servings":1,"difficulty":"Easy",
         "ingredients":[],"steps":["Toast bread"],"tips":""}
        """#
        let r = decode(GeneratedRecipe.self, json)
        XCTAssertEqual(r?.title, "Toast")
        XCTAssertNil(r?.imageURL, "imageURL is optional and may be absent")
        XCTAssertEqual(r?.isFavorited, false, "isFavorited must default to false")
    }

    // MARK: Round-trip

    func testInventoryItemRoundTripsLosslessly() {
        let original = LocalInventoryItem(name: "Chicken", level: 0.8, zone: "Fridge",
                                          quantity: 3, containerType: "package")
        guard let data = try? JSONEncoder().encode(original),
              let back = try? JSONDecoder().decode(LocalInventoryItem.self, from: data) else {
            XCTFail("round trip failed"); return
        }
        XCTAssertEqual(back.name, original.name)
        XCTAssertEqual(back.quantity, original.quantity)
    }
}
