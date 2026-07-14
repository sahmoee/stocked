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
        if !ConnectivityMonitor.isOnlineFlag {
            Log.net.debug("Skipping fetch — device offline")
            return nil
        }

        var attempt = 0
        while attempt < maxAttempts {
            attempt += 1
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse else { return nil }

                switch http.statusCode {
                case 200..<300:
                    return (data, http)
                case 429:
                    // Respect Retry-After (seconds or HTTP-date) if present.
                    let wait = retryAfterSeconds(http) ?? backoff(attempt, baseDelay)
                    Log.net.notice("429 rate-limited; backing off \(wait, format: .fixed(precision: 1), privacy: .public)s")
                    if attempt >= maxAttempts { return nil }
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                case 500..<600:
                    if attempt >= maxAttempts { return (data, http) }
                    let wait = backoff(attempt, baseDelay)
                    try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                default:
                    // 4xx other than 429 — won't improve on retry.
                    return (data, http)
                }
            } catch {
                if attempt >= maxAttempts {
                    Log.net.debug("Fetch failed after \(maxAttempts, privacy: .public) attempts: \(error.localizedDescription, privacy: .public)")
                    return nil
                }
                let wait = backoff(attempt, baseDelay)
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
        return nil
    }

    /// Exponential backoff with ±25% jitter: base * 2^(attempt-1), jittered.
    private static func backoff(_ attempt: Int, _ base: Double) -> Double {
        let raw = base * pow(2.0, Double(attempt - 1))
        let jitter = Double.random(in: 0.75...1.25)
        return min(raw * jitter, 8.0)   // cap so we never wait absurdly long
    }

    private static func retryAfterSeconds(_ http: HTTPURLResponse) -> Double? {
        guard let value = http.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let secs = Double(value) { return min(secs, 10.0) }
        // HTTP-date form.
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = fmt.date(from: value) {
            return min(max(date.timeIntervalSinceNow, 0), 10.0)
        }
        return nil
    }
}
