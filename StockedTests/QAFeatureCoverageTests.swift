import XCTest

@testable import Stocked

@MainActor final class QAFeatureCoverageTests: XCTestCase {
  func testAllProductionFeatureContractsPass() {
    for check in QAFeatureContracts.run() { XCTAssertTrue(check.passed, check.name) }
  }
  func testEveryChecklistIDIsUniqueAndNewCoverageIsExportedUntested() throws {
    let all = StockedQAChecklist.sections.flatMap(\.items)
    XCTAssertEqual(Set(all.map(\.id)).count, all.count)
    let report = StockedQABridge.buildReport()
    let checklists = try XCTUnwrap(report["checklists"] as? [[String: Any]])
    let rows = checklists.flatMap { ($0["items"] as? [[String: Any]]) ?? [] }
    XCTAssertEqual(rows.count, all.count, "Untested checks must reach companion QA too")
    XCTAssertTrue(checklists.contains { ($0["title"] as? String)?.hasPrefix("40.") == true })
  }
  func testLegacyCheckStateDecodesWithoutLosingNotesOrTicketLinks() throws {
    let data = Data(
      #"{"verdict":"pass","note":"Device observation","ticketNumber":"STK-89-0009"}"#.utf8)
    let state = try JSONDecoder().decode(QACheckItemState.self, from: data)
    XCTAssertEqual(state.note, "Device observation")
    XCTAssertEqual(state.ticketNumber, "STK-89-0009")
    XCTAssertNil(state.definition)
  }
  func testInventoryPolishCoverageHasStableAppendedIdentifiers() throws {
    let section = try XCTUnwrap(QAFeatureCoverage.sections.first { $0.number == 48 })
    XCTAssertEqual(section.rows.count, 11)
    XCTAssertTrue(section.rows.allSatisfy { !$0.0.isEmpty })
    XCTAssertEqual(QAFeatureCoverage.sections.map(\.number), Array(37...48))
  }
  func testUntestedSafetyCheckBlocksSignOff() {
    XCTAssertTrue(QAFeatureCoverage.isOpenBlocker(blocker: true, verdict: "untested"))
    XCTAssertFalse(QAFeatureCoverage.isOpenBlocker(blocker: true, verdict: "pass"))
  }
  func testAccessibilitySweepIgnoresInteractiveInfrastructureContainers() {
    XCTAssertFalse(QAAccessibilityAuditPolicy.shouldAudit(
      isAccessibilityElement: false,
      isControl: false,
      hasButtonOrLinkTrait: false,
      isUserInteractionEnabled: true,
      hasTapOrLongPressGesture: true
    ), "Window, passthrough, scroll-host and floating-bar gestures are not VoiceOver stops")
    XCTAssertTrue(QAAccessibilityAuditPolicy.shouldAudit(
      isAccessibilityElement: true,
      isControl: true,
      hasButtonOrLinkTrait: true,
      isUserInteractionEnabled: true,
      hasTapOrLongPressGesture: false
    ))
  }
  func testOptionalCoverageUsesExplicitFlagsAndTextOnlyAsFallback() {
    let lines = ["1 cup rice", "parsley for garnish"]
    let required = KitchenAvailability.coverage(
      lines: lines, optionalFlags: [false, false], availableNames: [])
    let optional = KitchenAvailability.coverage(
      lines: lines, optionalFlags: [false, true], availableNames: [])
    let inferred = KitchenAvailability.coverage(lines: lines, availableNames: [])
    XCTAssertEqual(required.total, 2, "Explicit required must not be overridden by a text guess")
    XCTAssertEqual(optional.total, 1)
    XCTAssertEqual(inferred.total, 1)
  }
}
