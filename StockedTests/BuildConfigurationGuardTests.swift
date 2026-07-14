import XCTest
@testable import Stocked

final class BuildConfigurationGuardTests: XCTestCase {
    func testValidVersionSettingsPass() {
        let issues = BuildConfigurationGuard.audit(info: [
            "CFBundleShortVersionString": "4.22",
            "CFBundleVersion": "42"
        ])
        XCTAssertFalse(issues.contains { if case .missing = $0 { return true }; return false })
        XCTAssertFalse(issues.contains { if case .unresolved = $0 { return true }; return false })
    }

    func testUnresolvedBuildSettingIsDetected() {
        let issues = BuildConfigurationGuard.audit(info: [
            "CFBundleShortVersionString": "$(MARKETING_VERSION)",
            "CFBundleVersion": "42"
        ])
        XCTAssertTrue(issues.contains(.unresolved("CFBundleShortVersionString")))
    }
}
