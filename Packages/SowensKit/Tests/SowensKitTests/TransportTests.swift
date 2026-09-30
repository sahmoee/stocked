import XCTest
@testable import SowensKit

private final class FixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/offline" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
        } else {
            let response = HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "60"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("fixture".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}

final class TransportTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FixtureProtocol.self]
        return URLSession(configuration: config)
    }
    func testPreservesHTTPFailureResponseAndRetryHeader() async throws {
        let client = session()
        defer { client.invalidateAndCancel() }
        let (data, response) = try await client.sowensData(from: URL(string: "https://fixture.invalid/failure")!)
        XCTAssertEqual(data, Data("fixture".utf8))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 503)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"), "60")
    }
    func testCancellationRemainsCancellation() async {
        let client = session()
        defer { client.invalidateAndCancel() }
        let request = Task { try await client.sowensData(from: URL(string: "https://fixture.invalid/cancel")!) }
        request.cancel()
        do {
            _ = try await request.value
            XCTFail("Cancelled request returned a result")
        } catch {
            XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    func testPreservesOfflineError() async {
        let client = session()
        defer { client.invalidateAndCancel() }
        do {
            _ = try await client.sowensData(from: URL(string: "https://fixture.invalid/offline")!)
            XCTFail("Expected offline failure")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
    }
}
