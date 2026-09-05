import XCTest
import UIKit
@testable import Stocked

@MainActor final class ArtworkPreparationTests: XCTestCase {
    func testEvictedArtworkRetriesOnlyOnce() {
        XCTAssertTrue(ArtworkPreparationResult.cancelled.shouldRetry(completedRetries: 0))
        XCTAssertFalse(ArtworkPreparationResult.cancelled.shouldRetry(completedRetries: 1))
        XCTAssertFalse(ArtworkPreparationResult.cancelled.shouldRetry(completedRetries: 2))
    }

    func testUnavailableOrLoadedArtworkDoesNotRetry() {
        XCTAssertFalse(ArtworkPreparationResult.unavailable.shouldRetry(completedRetries: 0))
        XCTAssertFalse(ArtworkPreparationResult.ready(UIImage()).shouldRetry(completedRetries: 0))
    }

    func testCancelledPreparationIsNotReportedAsMissingAsset() async {
        // Cancel before this actor yields: the request must never enter asset lookup.
        let request = Task { await ImageCache.shared.prepareArtworkResult(named: "not-a-real-test-asset") }
        request.cancel()
        let result = await request.value
        if case .cancelled = result { return }
        XCTFail("Cancellation must be distinct from a permanently unavailable asset")
    }
}
