// StockedSession.swift — short-lived session-token manager for the Stocked Worker.
//
// The Worker issues a signed, ~1h session token (X-Stocked-Session) that the app
// sends alongside the shipping X-Stocked-Key. This reduces reliance on the static
// shared key (which ships in the app and can be extracted). Everything here is
// ADDITIVE and fail-open: if a token can't be fetched, requests still go with
// X-Stocked-Key alone, exactly as before — nothing breaks.
//
// Default path is a guest session (works with no sign-in). When Sign in with
// Apple provides an identity token, we upgrade to a full session on the next
// fetch. Token fetches are single-flighted so concurrent requests share one call.

import Foundation
import os

actor StockedSession {
    static let shared = StockedSession()

    private var token: String?
    private var expiresAt: Date = .distantPast
    private var appleIdentityToken: String?
    private var inFlight: Task<String?, Never>?

    /// Refresh a little early so an in-flight request never rides an expiring token.
    private let earlyRefresh: TimeInterval = 120

    /// A valid session token, fetching/refreshing as needed. Returns nil (never throws)
    /// so callers can treat the session header as best-effort.
    func currentToken() async -> String? {
        if let t = token, Date() < expiresAt.addingTimeInterval(-earlyRefresh) { return t }
        if let existing = inFlight { return await existing.value }
        let task = Task<String?, Never> { await self.fetchToken() }
        inFlight = task
        let result = await task.value
        inFlight = nil
        return result
    }

    /// Called from the Sign in with Apple flow. Storing a fresh identity token
    /// invalidates the current (likely guest) session so the next request upgrades.
    func setAppleIdentityToken(_ jwt: String?) {
        let trimmed = jwt?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else { return }
        appleIdentityToken = trimmed
        token = nil
        expiresAt = .distantPast
    }

    /// Clear the cached token (e.g. after a 401) so the next request re-fetches.
    func invalidate() {
        token = nil
        expiresAt = .distantPast
    }

    // MARK: - Fetch

    private func fetchToken() async -> String? {
        guard let base = URL(string: BuildConfig.receiptWorkerURL) else { return nil }
        let usingApple = appleIdentityToken != nil
        let endpoint = base.appendingPathComponent(usingApple ? "session/apple" : "session/guest")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&request)   // X-Stocked-Key only — never a session header (avoids a loop)
        request.timeoutInterval = 15
        if usingApple, let jwt = appleIdentityToken {
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["identityToken": jwt])
        } else {
            request.httpBody = Data("{}".utf8)
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let session = obj["session"] as? String, !session.isEmpty else {
                // If an Apple upgrade was rejected, drop it and fall back to guest next time.
                if usingApple { appleIdentityToken = nil }
                return nil
            }
            let ttl = (obj["expiresIn"] as? TimeInterval) ?? 3600
            token = session
            expiresAt = Date().addingTimeInterval(ttl)
            return session
        } catch {
            Log.app.error("StockedSession fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
