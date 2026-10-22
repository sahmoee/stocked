import XCTest
import CloudKit
@testable import Stocked

@MainActor
final class CloudKitTransferSafetyTests: XCTestCase {
    func testFailedDownloadNeverUploadsLocalSnapshot() async {
        var uploads = 0
        let succeeded = await HouseholdCloudKit.transfer(pull: { false }, push: {
            uploads += 1
            return true
        })
        XCTAssertFalse(succeeded)
        XCTAssertEqual(uploads, 0)
    }

    func testFailedUploadCannotCompleteTransfer() async {
        var events: [String] = []
        let succeeded = await HouseholdCloudKit.transfer(pull: {
            events.append("download")
            return true
        }, push: {
            events.append("upload")
            return false
        })
        XCTAssertFalse(succeeded)
        XCTAssertEqual(events, ["download", "upload"])
    }

    func testSuccessfulTransferPreservesDownloadBeforeUpload() async {
        var downloaded = false
        let succeeded = await HouseholdCloudKit.transfer(pull: {
            downloaded = true
            return true
        }, push: { downloaded })
        XCTAssertTrue(succeeded)
    }

    func testKnownMembershipNeverFallsBackToAnotherSharedKitchen() {
        let intended = CKRecordZone.ID(zoneName: HouseholdSchema.zoneName, ownerName: "owner-a")
        let other = CKRecordZone.ID(zoneName: HouseholdSchema.zoneName, ownerName: "owner-b")
        XCTAssertNil(HouseholdCloudKit.selectMemberZone([other], expected: intended))
        XCTAssertEqual(HouseholdCloudKit.selectMemberZone([other, intended], expected: intended), intended)
    }

    func testLegacyMembershipRequiresUnambiguousHouseholdZone() {
        let first = CKRecordZone.ID(zoneName: HouseholdSchema.zoneName, ownerName: "owner-a")
        let second = CKRecordZone.ID(zoneName: HouseholdSchema.zoneName, ownerName: "owner-b")
        let unrelated = CKRecordZone.ID(zoneName: "OtherSharedData", ownerName: "owner-a")
        XCTAssertNil(HouseholdCloudKit.selectMemberZone([], expected: nil))
        XCTAssertNil(HouseholdCloudKit.selectMemberZone([first, second], expected: nil))
        XCTAssertNil(HouseholdCloudKit.selectMemberZone([unrelated], expected: nil))
        XCTAssertEqual(HouseholdCloudKit.selectMemberZone([unrelated, first], expected: nil), first)
    }
}
