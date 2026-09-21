// NetworkRetry.swift
// #17/#19 Shared network resilience: exponential backoff with jitter, plus precise
// honoring of HTTP 429 "Retry-After" headers, and a hard skip when offline (#16).
// Free, local, no dependencies. Use for any GET that should survive transient failures
// or rate limits without hammering the server.

import Foundation
import os

enum NetworkRetry {

    struct GiveUp: Error { let lastStatus: Int? }

    /// Fetch `url` with up to `maxAttempts`, backing off on 429/5xx. Honors Retry-After
    /// on 429s; otherwise uses exponential backoff (base 0.4s) with ±25% jitter. Returns
    /// nil immediately if the device is known to be offline.
    static func data(from url: URL,
                     session: URLSession = .shared,
                     maxAttempts: Int = 3,
                     baseDelay: Double = 0.4) async -> (Data, HTTPURLResponse)? {
        // #16: don't even try if we know we're offline.
        if Task.isCancelled || !ConnectivityMonitor.isOnlineFlag {
            Log.net.debug("Skipping fetch — cancelled or offline")
            return nil
        }

        var attempt = 0
        let attemptLimit = min(max(maxAttempts, 0), 8)
        while attempt < attemptLimit {
            guard !Task.isCancelled, ConnectivityMonitor.isOnlineFlag else { return nil }
            attempt += 1
            do {
                let (data, response) = try await session.data(from: url)
                try Task.checkCancellation()
                guard let http = response as? HTTPURLResponse else { return nil }

                switch http.statusCode {
                case 200..<300:
                    return (data, http)
                case 429:
                    // Respect Retry-After (seconds or HTTP-date) if present.
                    let wait = NetworkRetryPolicy.retryAfterSeconds(http.value(forHTTPHeaderField: "Retry-After")) ?? backoff(attempt, baseDelay)
                    Log.net.notice("429 rate-limited; minimum retry delay \(wait, format: .fixed(precision: 1), privacy: .public)s")
                    // Long server cooldowns outlive this foreground request. Give up
                    // rather than silently shortening Retry-After and hammering it.
                    if attempt >= attemptLimit || wait > 10 { return nil }
                    try await Task.sleep(for: .seconds(wait))
                case 500..<600:
                    if attempt >= attemptLimit { return (data, http) }
                    let wait = NetworkRetryPolicy.retryAfterSeconds(http.value(forHTTPHeaderField: "Retry-After")) ?? backoff(attempt, baseDelay)
                    if wait > 10 { return (data, http) }
                    try await Task.sleep(for: .seconds(wait))
                default:
                    // 4xx other than 429 — won't improve on retry.
                    return (data, http)
                }
            } catch {
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return nil }
                if attempt >= attemptLimit || !NetworkRetryPolicy.isTransient(error) {
                    Log.net.debug("Fetch stopped after \(attempt, privacy: .public) attempts")
                    return nil
                }
                let wait = backoff(attempt, baseDelay)
                do { try await Task.sleep(for: .seconds(wait)) } catch { return nil }
            }
        }
        return nil
    }

    /// Exponential backoff with ±25% jitter: base * 2^(attempt-1), jittered.
    private static func backoff(_ attempt: Int, _ base: Double) -> Double {
        let safeBase = base.isFinite && base >= 0 ? min(base, 8) : 0.4
        let raw = safeBase * pow(2.0, Double(max(0, min(attempt - 1, 8))))
        let jitter = Double.random(in: 0.75...1.25)
        return min(raw * jitter, 8.0)   // cap so we never wait absurdly long
    }

}

/// Shared GET and durable-household retry parsing; no UI, storage, or network side effects.
nonisolated enum NetworkRetryPolicy {
    static func retryAfterSeconds(_ raw: String?, now: Date = Date()) -> Double? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        if let secs = Double(value) {
            guard secs.isFinite, secs >= 0, secs <= 31_536_000 else { return nil }
            return secs
        }
        // HTTP-date form.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = fmt.date(from: value) {
            return max(date.timeIntervalSince(now), 0)
        }
        return nil
    }

    static func isTransient(_ error: Error) -> Bool {
        guard let error = error as? URLError else { return false }
        switch error.code {
        case .timedOut, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return true
        default: return false
        }
    }

    static func queueDelay(exponential: Double, serverMinimum: Double, serverImposed: Bool, jitter: Double) -> Double {
        let local = exponential * jitter
        // Jitter must never move a rate-limit/quota retry before the server's deadline.
        return serverImposed ? max(local, serverMinimum) : local
    }
}
