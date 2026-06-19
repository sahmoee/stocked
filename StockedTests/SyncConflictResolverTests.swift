// SyncConflictResolverTests.swift — tests for #12 merge policy.
//
// Add to the StockedTests Unit Test Bundle target (same one as StockedLogicTests), NOT the app
// target.

import XCTest
@testable import Stocked

final class SyncConflictResolverTests: XCTestCase {

    private struct Rec: SyncMergeable {
        var id: String
        var modifiedAt: Date
        var isDeleted: Bool = false
    }

    private func date(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_000_000 + offset) }

    func testNewerWins() {
        let a = Rec(id: "x", modifiedAt: date(0))
        let b = Rec(id: "x", modifiedAt: date(10))
        XCTAssertEqual(SyncConflictResolver.newer(a, b).modifiedAt, date(10))
    }

    func testMergePicksLatestPerId() {
        let local  = [Rec(id: "a", modifiedAt: date(0)), Rec(id: "b", modifiedAt: date(5))]
        let remote = [Rec(id: "a", modifiedAt: date(20)), Rec(id: "c", modifiedAt: date(1))]
        let merged = SyncConflictResolver.merge(local: local, remote: remote)
        let byId = Dictionary(uniqueKeysWithValues: merged.map { ($0.id, $0) })
        XCTAssertEqual(byId["a"]?.modifiedAt, date(20))   // remote newer
        XCTAssertEqual(byId["b"]?.modifiedAt, date(5))    // only local
        XCTAssertEqual(byId["c"]?.modifiedAt, date(1))    // only remote
        XCTAssertEqual(merged.count, 3)
    }

    func testNewerDeletionRemovesItem() {
        let edit   = Rec(id: "x", modifiedAt: date(0), isDeleted: false)
        let delete = Rec(id: "x", modifiedAt: date(10), isDeleted: true)
        let merged = SyncConflictResolver.merge(local: [edit], remote: [delete])
        XCTAssertTrue(merged.isEmpty)   // newer tombstone wins → item gone
    }

    func testOlderDeletionLosesToNewerEdit() {
        let delete = Rec(id: "x", modifiedAt: date(0), isDeleted: true)
        let edit   = Rec(id: "x", modifiedAt: date(10), isDeleted: false)
        let merged = SyncConflictResolver.merge(local: [delete], remote: [edit])
        XCTAssertEqual(merged.count, 1)          // newer edit resurrects
        XCTAssertEqual(merged.first?.id, "x")
    }

    func testTieFavorsDeletion() {
        let edit   = Rec(id: "x", modifiedAt: date(5), isDeleted: false)
        let delete = Rec(id: "x", modifiedAt: date(5), isDeleted: true)
        let merged = SyncConflictResolver.merge(local: [edit], remote: [delete])
        XCTAssertTrue(merged.isEmpty)   // equal timestamps → deletion wins
    }
}
