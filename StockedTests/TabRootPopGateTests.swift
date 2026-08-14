import XCTest
@testable import Stocked

final class TabRootPopGateTests: XCTestCase {
    func testRapidReselectionCausesOnlyOneRootRebuild() {
        var gate = TabRootPopGate()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(gate.shouldAccept(at: start))
        XCTAssertFalse(gate.shouldAccept(at: start.addingTimeInterval(0.1)))
        XCTAssertFalse(gate.shouldAccept(at: start.addingTimeInterval(0.5)))
    }

    func testReselectionIsAcceptedAfterTransitionWindow() {
        var gate = TabRootPopGate()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)

        XCTAssertTrue(gate.shouldAccept(at: start))
        XCTAssertTrue(gate.shouldAccept(at: start.addingTimeInterval(TabRootPopGate.minimumInterval)))
    }
}
