import XCTest
@testable import Stocked

@MainActor final class QAIdentityTests: XCTestCase {
    func testTicketWireRoundTripPreservesCaptureAndRegression() throws {
        var ticket = QATicket(number: "STK-100-0001-ABC", title: "Regression")
        ticket.origin = .automatic
        ticket.context.identity = QAReportIdentity(deviceFamily: "iPhone", deviceModel: "iPhone 17 Pro",
            modelIdentifier: "iPhone18,1", installationID: "original-phone", isSimulator: false).assigning(.shalise)
        ticket.context.environment = ["Theme: dark"]
        ticket.automaticCheckID = "fixture-check"
        ticket.regressionDetectedAt = Date(timeIntervalSince1970: 1_000)
        ticket.checkTicket = "QA-45-07"
        ticket.runID = "test-run"
        ticket.requiresManualReview = true
        let decoded = QATicketStore.remoteTicket(QATicketStore.dictionary(for: ticket), number: ticket.number, title: ticket.title)
        XCTAssertEqual(decoded.id, ticket.id)
        XCTAssertEqual(decoded.origin, .automatic)
        XCTAssertEqual(decoded.context.identity, ticket.context.identity)
        XCTAssertEqual(decoded.context.environment, ticket.context.environment)
        XCTAssertEqual(decoded.automaticCheckID, ticket.automaticCheckID)
        XCTAssertEqual(decoded.regressionDetectedAt, ticket.regressionDetectedAt)
        XCTAssertEqual(decoded.checkTicket, ticket.checkTicket)
        XCTAssertEqual(decoded.runID, ticket.runID)
        XCTAssertEqual(decoded.requiresManualReview, true)
    }
    func testLegacyTicketDoesNotInheritCurrentTesterOrDevice() {
        let ticket = QATicketStore.remoteTicket(["environment": ["device": "iPad"], "status": "fixed"], number: "old", title: "Legacy")
        XCTAssertNil(ticket.context.identity)
        XCTAssertEqual(ticket.context.device, "iPad")
        XCTAssertFalse(ticket.needsAttention)
        XCTAssertEqual(ticket.statusLabel, "Completed")
    }
    func testFixedManualReviewRemainsActiveUntilVerified() {
        var ticket = QATicket(number: "test", title: "Review")
        ticket.status = .fixed
        ticket.requiresManualReview = true
        XCTAssertTrue(ticket.needsAttention)
        XCTAssertEqual(ticket.statusLabel, "Fixed · review needed")
        ticket.status = .verified
        XCTAssertFalse(ticket.needsAttention)
    }
    func testResolvedVerdictIsNotAPassOrOpenBlocker() {
        XCTAssertNotEqual(QAVerdict.resolved, .pass)
        XCTAssertFalse(QAFeatureCoverage.isOpenBlocker(blocker: true, verdict: "resolved"))
        XCTAssertEqual(QAVerdict.resolved.next, .untested)
    }
}
