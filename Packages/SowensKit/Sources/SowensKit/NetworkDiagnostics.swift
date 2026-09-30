import Foundation
import CryptoKit
#if DEBUG
import Pulse
#endif

/// Only numeric outcomes and a one-way endpoint identity enter diagnostics.
/// URL credentials, paths, query values, headers, bodies and error descriptions never do.
public struct NetworkObservation: Sendable, Equatable {
    public let method: String
    public let endpoint: String
    public let status: Int
    public let bytes: Int
    public let milliseconds: Int
    public let errorCode: Int

    public init(request: URLRequest, response: URLResponse?, bytes: Int, elapsed: TimeInterval, error: Error? = nil) {
        let proposedMethod = request.httpMethod?.uppercased() ?? "GET"
        method = ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"].contains(proposedMethod) ? proposedMethod : "OTHER"
        var parts = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        parts?.user = nil
        parts?.password = nil
        parts?.query = nil
        parts?.fragment = nil
        endpoint = SHA256.hash(data: Data((parts?.string ?? "unknown").utf8))
            .prefix(12).map { String(format: "%02x", $0) }.joined()
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        self.bytes = max(0, bytes)
        milliseconds = elapsed.isFinite ? Int(min(max(0, elapsed * 1_000), 86_400_000)) : 0
        errorCode = (error as? URLError)?.code.rawValue ?? (error is CancellationError ? URLError.cancelled.rawValue : (error == nil ? 0 : -1))
    }

    public var summary: String {
        "method=\(method) endpoint=\(endpoint) status=\(status) bytes=\(bytes) ms=\(milliseconds) error=\(errorCode)"
    }
}

public enum NetworkDiagnostics {
    #if DEBUG
    /// Ephemeral debug-only storage: no user-data migration, uploads or logging in release.
    public static let store: LoggerStore? = {
        var configuration = LoggerStore.Configuration(sizeLimit: 4 * 1_024 * 1_024)
        configuration.maxAge = 3_600
        configuration.responseBodySizeLimit = 0
        return try? LoggerStore(storeURL: URL(fileURLWithPath: "/dev/null"),
                                options: [.inMemory, .sweep], configuration: configuration)
    }()
    #endif

    public static func record(_ observation: NetworkObservation) {
        #if DEBUG
        guard let url = URL(string: "https://redacted.invalid/" + observation.endpoint) else { return }
        var request = URLRequest(url: url)
        request.httpMethod = observation.method
        let response = observation.status > 0 ? HTTPURLResponse(url: url, statusCode: observation.status,
                                                               httpVersion: nil, headerFields: ["Content-Length": String(observation.bytes)]) : nil
        let error = observation.errorCode == 0 ? nil : URLError(URLError.Code(rawValue: observation.errorCode))
        store?.storeRequest(request, response: response, error: error, data: nil,
                            label: "network", taskDescription: observation.summary)
        #endif
    }
}

extension URLSession {
    /// Uses this session unchanged, including its redirect, cookie, cache and auth policies.
    public func sowensData(for request: URLRequest, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        #if DEBUG
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let result = try await data(for: request, delegate: delegate)
            NetworkDiagnostics.record(.init(request: request, response: result.1, bytes: result.0.count,
                                            elapsed: ProcessInfo.processInfo.systemUptime - started))
            return result
        } catch {
            NetworkDiagnostics.record(.init(request: request, response: nil, bytes: 0,
                                            elapsed: ProcessInfo.processInfo.systemUptime - started, error: error))
            throw error
        }
        #else
        return try await data(for: request, delegate: delegate)
        #endif
    }

    public func sowensData(from url: URL, delegate: (any URLSessionTaskDelegate)? = nil) async throws -> (Data, URLResponse) {
        try await sowensData(for: URLRequest(url: url), delegate: delegate)
    }
}
