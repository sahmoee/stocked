import Foundation
import os

// Native harness for the actual production retry implementation. No simulator or external requests.
enum ConnectivityMonitor { static let isOnlineFlag = true }
enum Log { static let net = Logger(subsystem: "Stocked.NetworkRetryChecks", category: "tests") }

final class RetryFixture: @unchecked Sendable {
    static let shared = RetryFixture()
    private let lock = NSLock()
    private var responses: [(Int, String?)] = []
    private var count = 0
    func set(_ values: [(Int, String?)]) { lock.lock(); defer { lock.unlock() }; responses = values; count = 0 }
    func take() -> (Int, String?) { lock.lock(); defer { lock.unlock() }; count += 1; return responses.isEmpty ? (200, nil) : responses.removeFirst() }
    var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
}

final class RetryURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (status, retry) = RetryFixture.shared.take()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: retry.map { ["Retry-After": $0] })!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct NetworkRetryChecks {
    static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ name: String) { checks += 1; precondition(condition, name) }
        for value in ["-1", "nan", "inf", "1e309", "", "abc"] {
            check(NetworkRetryPolicy.retryAfterSeconds(value) == nil, "reject unsafe Retry-After \(value)")
        }
        check(NetworkRetryPolicy.retryAfterSeconds(" 0 ") == 0, "zero retry accepted")
        check(NetworkRetryPolicy.retryAfterSeconds("120") == 120, "server minimum not shortened")
        let now = Date(timeIntervalSince1970: 1_000_000)
        check(NetworkRetryPolicy.retryAfterSeconds("Mon, 12 Jan 1970 13:48:40 GMT", now: now) == 120, "HTTP date supported")
        check(NetworkRetryPolicy.queueDelay(exponential: 2, serverMinimum: 60, serverImposed: true, jitter: 0.8) == 60, "rate limit jitter cannot retry early")
        check(NetworkRetryPolicy.queueDelay(exponential: 2, serverMinimum: 2, serverImposed: false, jitter: 0.8) == 1.6, "ordinary jitter retained")
        check(!NetworkRetryPolicy.isTransient(URLError(.cancelled)), "cancel never retried")
        check(!NetworkRetryPolicy.isTransient(URLError(.serverCertificateUntrusted)), "TLS failure never retried")
        check(NetworkRetryPolicy.isTransient(URLError(.timedOut)), "timeout retry retained")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RetryURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://example.invalid/retry-fixture")!
        RetryFixture.shared.set([(429, "120"), (200, nil)])
        let limited = await NetworkRetry.data(from: url, session: session, baseDelay: 0)
        check(limited == nil && RetryFixture.shared.requests == 1, "long rate limit stops foreground retry")
        RetryFixture.shared.set([(503, "120"), (200, nil)])
        let unavailable = await NetworkRetry.data(from: url, session: session, baseDelay: 0)
        check(unavailable?.1.statusCode == 503 && RetryFixture.shared.requests == 1, "503 server cooldown retained")
        RetryFixture.shared.set([(503, nil), (200, nil)])
        let recovered = await NetworkRetry.data(from: url, session: session, baseDelay: 0)
        check(recovered?.1.statusCode == 200 && RetryFixture.shared.requests == 2, "transient service recovers")
        RetryFixture.shared.set([(429, "5"), (200, nil)])
        let cancelled = Task { await NetworkRetry.data(from: url, session: session) }
        while RetryFixture.shared.requests == 0 { await Task.yield() }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        check(cancelledResult == nil && RetryFixture.shared.requests == 1, "cancelled backoff never starts another request")
        print("Network retry: \(checks) native checks passed (no simulator or live network).")
    }
}
