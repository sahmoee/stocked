// FetchOptimizations.swift — online-fetching improvements, Batch 1.
//
// Stocked already has strong fetch infrastructure (NetworkRetry backoff+jitter,
// per-host throttling in WebRecipeDatabase, ConnectivityMonitor reachability,
// ImageCache two-tier + downsample + prefetch, RecipeImageResolver negative cache
// + multi-source fallback + content-type validation). These two utilities fill the
// remaining genuine gaps without duplicating any of that:
//   • #6  RequestCoalescer — dedupes identical in-flight network requests so two
//          callers asking for the same URL at the same time share ONE fetch.
//   • #17 URLCanonicalizer — strips tracking params + fragments so cache keys for
//          the same resource don't fragment across utm_/fbclid/etc. variants.
//
// Both are additive and opt-in; nothing else changes unless a caller uses them.

import Foundation

// MARK: - Duplicate-safe dictionary construction

extension Dictionary {
    /// Builds a dictionary without trapping when synced/cached input contains duplicate keys.
    /// The newest value wins, which matches Stocked's merge semantics.
    /// `nonisolated` so it's callable from any actor/background context (the project defaults
    /// declarations to @MainActor, which would otherwise pin this pure utility to the main actor).
    nonisolated init<S>(keepingLastValues sequence: S) where S: Sequence, S.Element == (Key, Value) {
        self.init()
        for (key, value) in sequence {
            self[key] = value
        }
    }
}

// MARK: - #6 Request coalescing

/// Dedupes concurrent identical async requests. If two callers request the same key
/// while a fetch is in flight, the second awaits the first's result instead of issuing
/// a duplicate network call. Results are NOT cached beyond the in-flight window — pair
/// with the existing on-disk/title caches for persistence.
actor RequestCoalescer {
    static let shared = RequestCoalescer()

    private var inFlight: [String: Task<Data, Error>] = [:]

    /// Returns Data for `url`, coalescing with any identical request already running.
    /// `loader` performs the actual fetch (defaults to NetworkRetry if available).
    func data(for url: URL, loader: @escaping @Sendable (URL) async throws -> Data) async throws -> Data {
        let key = URLCanonicalizer.canonicalKey(url)
        if let existing = inFlight[key] {
            return try await existing.value
        }
        let task = Task<Data, Error> { try await loader(url) }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        return try await task.value
    }

    /// Number of requests currently in flight (for diagnostics).
    var inFlightCount: Int { inFlight.count }
}

// MARK: - #17 URL canonicalization

// nonisolated: pure, stateless URL helpers with no shared mutable state, so they can be
// called from the RecipeDatabase actor and background fetch contexts without main-actor hops.
nonisolated enum URLCanonicalizer {
    /// Tracking / analytics query keys that never change which resource is returned,
    /// so two URLs differing only by these point at the same thing for caching.
    private static let trackingKeys: Set<String> = [
        "utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content",
        "utm_id", "utm_reader", "utm_name", "utm_social", "utm_brand",
        "fbclid", "gclid", "dclid", "gclsrc", "msclkid", "mc_cid", "mc_eid",
        "igshid", "ref", "ref_src", "ref_url", "source", "spm", "_hsenc", "_hsmi",
        "vero_id", "yclid", "wickedid", "twclid", "oly_anon_id", "oly_enc_id"
    ]

    /// A canonical URL with tracking params and fragment removed, host lowercased,
    /// and remaining query items sorted (so order doesn't fragment the key).
    static func canonical(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        comps.fragment = nil
        if let host = comps.host { comps.host = host.lowercased() }
        if let items = comps.queryItems, !items.isEmpty {
            let kept = items
                .filter { !trackingKeys.contains($0.name.lowercased()) }
                .sorted { $0.name < $1.name }
            comps.queryItems = kept.isEmpty ? nil : kept
        }
        // Drop a trailing slash on the path for consistency (but keep root "/").
        if comps.path.count > 1 && comps.path.hasSuffix("/") {
            comps.path = String(comps.path.dropLast())
        }
        return comps.url ?? url
    }

    /// String form of the canonical URL, used as a cache key.
    static func canonicalKey(_ url: URL) -> String {
        canonical(url).absoluteString
    }

    /// Convenience for string inputs (returns the original string if it isn't a URL).
    static func canonicalString(_ urlString: String) -> String {
        guard let url = URL(string: urlString) else { return urlString }
        return canonical(url).absoluteString
    }
}
