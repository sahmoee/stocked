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

    func testEveryRecordedRootTabTapStormCoalescesToOneRebuild() {
        let recordedTapCounts = [
            "Home": 3,
            "Cook": 9,
            "Recipes": 8
        ]

        for (tab, tapCount) in recordedTapCounts {
            var gate = TabRootPopGate()
            let start = Date(timeIntervalSinceReferenceDate: 2_000)
            let accepted = (0..<tapCount).filter { index in
                gate.shouldAccept(at: start.addingTimeInterval(Double(index) * 0.05))
            }
            XCTAssertEqual(accepted.count, 1, "\(tab) should perform one root rebuild per tap storm")
        }
    }
}
