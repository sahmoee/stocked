import XCTest
import SowensSearch

final class SearchIndexTests: XCTestCase {
    func testPrefixSearchAndSafeSyntax() async throws {
        let index = try SearchIndex()
        try await index.replace(with: [.init(id: "wings", text: "Grilled Chicken Wings"), .init(id: "rice", text: "Brown Rice")], revision: "1")
        let matches = try await index.search("chick wing")
        XCTAssertEqual(matches, ["wings"])
        let empty = try await index.search("\" * ()")
        XCTAssertEqual(empty, [])
        let literal = try await index.search("chicken OR rice")
        XCTAssertEqual(literal, [])
    }
    func testFailedReplacementPreservesPreviousIndex() async throws {
        let index = try SearchIndex()
        try await index.replace(with: [.init(id: "old", text: "Chicken")], revision: "1")
        do {
            try await index.replace(with: [.init(id: "same", text: "Rice"), .init(id: "same", text: "Beans")], revision: "2")
            XCTFail("Expected duplicate rejection")
        } catch SearchIndex.IndexError.duplicateID {}
        let matches = try await index.search("chicken")
        XCTAssertEqual(matches, ["old"])
    }
    func testReplacingRevisionRemovesStaleResults() async throws {
        let index = try SearchIndex()
        try await index.replace(with: [.init(id: "old", text: "Chicken")], revision: "1")
        try await index.replace(with: [.init(id: "new", text: "Rice")], revision: "2")
        let old = try await index.search("chicken")
        let new = try await index.search("rice")
        XCTAssertEqual(old, [])
        XCTAssertEqual(new, ["new"])
    }
}
