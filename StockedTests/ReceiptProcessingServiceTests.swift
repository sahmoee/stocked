import XCTest
@testable import Stocked

final class ReceiptProcessingServiceTests: XCTestCase {
    func testNormalizesBrandQuantityAndSize() throws {
        let item = try XCTUnwrap(ReceiptProcessingService.normalize(
            raw: "2 CT GREAT VALUE BLACK BEANS 15 OZ 3.98",
            aiResolved: "Great Value Black Beans 15 oz",
            storeName: "Walmart",
            learnedTranslation: nil,
            abbreviationTranslation: nil
        ))
        XCTAssertEqual(item.resolved, "Black Beans")
        XCTAssertEqual(item.brand, "Great Value")
        XCTAssertEqual(item.quantity, 2)
        XCTAssertEqual(item.sizeAmount, 15)
        XCTAssertEqual(item.sizeUnit, "oz")
    }

    func testProductBeginningWithNumberIsNotQuantity() throws {
        let item = try XCTUnwrap(ReceiptProcessingService.normalize(
            raw: "7 UP 12 OZ", aiResolved: "7 Up 12 oz", storeName: "",
            learnedTranslation: nil, abbreviationTranslation: nil
        ))
        XCTAssertEqual(item.quantity, 1)
        XCTAssertEqual(item.resolved, "7 Up")
    }

    func testRejectsReceiptTotals() {
        XCTAssertNil(ReceiptProcessingService.normalize(
            raw: "SUBTOTAL 42.18", aiResolved: nil, storeName: "",
            learnedTranslation: nil, abbreviationTranslation: nil
        ))
    }

    func testConsolidatesDuplicateCanonicalNames() {
        let rows = [("Black Beans", 2), ("black bean", 1)]
        let consolidated = ReceiptProcessingService.consolidate(
            rows, key: { $0.0 }, quantity: { $0.1 }, merging: { ($0.0, $1) }
        )
        XCTAssertEqual(consolidated.count, 1)
        XCTAssertEqual(consolidated.first?.1, 3)
    }
}
