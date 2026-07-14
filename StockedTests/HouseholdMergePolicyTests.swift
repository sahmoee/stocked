import XCTest
@testable import Stocked

final class HouseholdMergePolicyTests: XCTestCase {
    func testNewerTimestampWins() {
        XCTAssertTrue(HouseholdMergePolicy.remoteWins(remoteUpdatedAt: 20, remoteWriterID: "a",
                                                       localUpdatedAt: 10, localWriterID: "z"))
    }

    func testWriterIDBreaksEqualTimestampTieDeterministically() {
        XCTAssertTrue(HouseholdMergePolicy.remoteWins(remoteUpdatedAt: 10, remoteWriterID: "z",
                                                       localUpdatedAt: 10, localWriterID: "a"))
        XCTAssertFalse(HouseholdMergePolicy.remoteWins(remoteUpdatedAt: 10, remoteWriterID: "a",
                                                        localUpdatedAt: 10, localWriterID: "z"))
    }

    func testIdenticalVersionDoesNotChurn() {
        XCTAssertFalse(HouseholdMergePolicy.remoteWins(remoteUpdatedAt: 10, remoteWriterID: "same",
                                                        localUpdatedAt: 10, localWriterID: "same"))
    }
}
