import XCTest
@testable import SowensKit

final class DiagnosticsTests: XCTestCase {
    func testPrivateValuesNeverReachSummary() {
        var request = URLRequest(url: URL(string: "https://alice:password@example.com/private-recipe?token=secret#private")!)
        request.httpBody = Data("secret body".utf8)
        request.setValue("Bearer secret", forHTTPHeaderField: "Authorization")
        let observation = NetworkObservation(request: request, response: nil, bytes: 4, elapsed: .infinity,
                                              error: URLError(.notConnectedToInternet))
        for secret in ["alice", "password", "example", "private", "token", "secret", "Bearer"] {
            XCTAssertFalse(observation.summary.contains(secret))
        }
        XCTAssertEqual(observation.errorCode, URLError.notConnectedToInternet.rawValue)
        XCTAssertEqual(observation.milliseconds, 0)
        let clean = URLRequest(url: URL(string: "https://example.com/private-recipe")!)
        XCTAssertEqual(observation.endpoint, NetworkObservation(request: clean, response: nil, bytes: 0, elapsed: 0).endpoint)
    }

    func testPhotoInputPreservesOriginalSourceAndLocalPrecedence() {
        let remote = "https://example.com/wings.jpg"
        XCTAssertEqual(PhotoInput.resolve(data: nil, url: remote), .remote(URL(string: remote)!))
        XCTAssertEqual(PhotoInput.resolve(data: Data([1, 2]), url: remote), .embedded(Data([1, 2])))
        XCTAssertEqual(PhotoInput.resolve(data: Data(), url: remote), .remote(URL(string: remote)!))
        for invalid in [nil, "", "file:///private/image", "https://user:secret@example.com/photo", "javascript:alert(1)"] {
            XCTAssertEqual(PhotoInput.resolve(data: nil, url: invalid), .missing)
        }
    }
}
