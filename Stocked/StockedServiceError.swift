// StockedServiceError.swift
// Small, Sendable error vocabulary shared by network and AI clients.
import Foundation

nonisolated enum StockedServiceError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured(String)
    case offline
    case invalidRequest(String)
    case transport(String)
    case httpStatus(Int, String?)
    case rateLimited(retryAfter: TimeInterval?)
    case quotaExhausted(String)
    case malformedResponse(String)
    case schemaMismatch(expected: Int, actual: Int?)
    case truncatedResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured(let service): return "\(service) is not configured."
        case .offline: return "You're offline."
        case .invalidRequest(let detail): return detail
        case .transport(let detail): return detail
        case .httpStatus(let code, let detail):
            return detail.map { "Server error \(code): \($0)" } ?? "Server error \(code)."
        case .rateLimited(let retryAfter):
            if let retryAfter { return "Too many requests. Try again in about \(Int(retryAfter.rounded())) seconds." }
            return "Too many requests. Try again shortly."
        case .quotaExhausted(let detail): return detail
        case .malformedResponse(let detail): return detail
        case .schemaMismatch(let expected, let actual):
            return "The service response schema is incompatible (expected \(expected), received \(actual.map(String.init) ?? "unknown"))."
        case .truncatedResponse: return "The service response was cut off before it finished."
        case .cancelled: return "The request was cancelled."
        }
    }
}
