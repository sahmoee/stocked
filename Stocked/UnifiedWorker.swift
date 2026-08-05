//
//  UnifiedWorker.swift
//  Stocked
//
//  One place that knows where the backend is.
//
//  The four apps' Workers were merged into a single Cloudflare Worker
//  (`sowens-worker`, in Documents/worker). Nothing about that merge requires an
//  app change: Stocked reaches it at https://api.sowensstudios.com exactly as
//  before, because that is a custom domain and it now points at the merged
//  script.
//
//  This file exists for what comes next. The unified Worker also answers on a
//  per-app path prefix — https://api.sowensstudios.com/stocked/... — and moving
//  to that is what eventually lets the legacy hostnames retire. Today Stocked
//  builds URLs ad hoc in about eleven files (StockedSession, StockedRemoteConfig,
//  WorkerBarcodeResolver, RemoteContentClient, HouseholdSync, the QA uploaders,
//  SmartWorkerClient…), each doing its own `appendingPathComponent`. Converting
//  those in one sweep would be a needless risk.
//
//  So: point them at `StockedUnifiedWorker.url(_:)` one at a time, at whatever
//  pace is comfortable. When they all go through here, flipping to the prefix is
//  changing `pathPrefix` from "" to "/stocked" — one line, one build, one test.
//
//  Until then this is a no-op wrapper around exactly what BuildConfig already
//  returns, which is the point: adopting it can't break anything.
//

import Foundation

enum StockedUnifiedWorker {

    /// The merged Worker's base. Unchanged from `BuildConfig.receiptWorkerURL` —
    /// the custom domain moved to the new script, so the app didn't have to.
    static var baseURLString: String { BuildConfig.receiptWorkerURL }

    /// Set to "/stocked" once every call site goes through `url(_:)`.
    ///
    /// Both addressing modes are live on the Worker simultaneously, so this can
    /// be flipped and reverted freely — there is no coordinated cutover and no
    /// window where one is right and the other is wrong.
    ///
    /// One caveat before flipping: `StockedWorkerClient` POSTs the AI routes to
    /// the BARE base URL and names the route in the body. The Worker handles a
    /// bare "/stocked" as "/" for exactly this reason, but it is the first thing
    /// to smoke-test.
    static let pathPrefix = ""

    /// Base URL including the prefix, if any.
    static var baseURL: URL? {
        URL(string: baseURLString + pathPrefix)
    }

    /// Build a URL for a Worker path.
    ///
    ///     StockedUnifiedWorker.url("household/push")
    ///     StockedUnifiedWorker.url("/content/recipes")     // leading slash is fine
    static func url(_ path: String) -> URL? {
        guard let base = baseURL else { return nil }
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard !trimmed.isEmpty else { return base }
        return base.appendingPathComponent(trimmed)
    }

    /// True when the Worker looks configured. Mirrors the existing
    /// `REPLACE-WITH-YOUR-WORKER` sentinel check so behaviour is identical.
    static var isConfigured: Bool {
        guard let url = URL(string: baseURLString), let host = url.host else { return false }
        return url.scheme == "https" && !host.contains("REPLACE-WITH-YOUR-WORKER")
    }

    /// Diagnostics: the merged Worker's cross-app status page. Every response
    /// from the Worker also carries `X-Worker-App`, which says which app's module
    /// answered — the fastest way to confirm a request landed where you meant.
    static var unifiedHealthURL: URL? {
        guard let base = URL(string: baseURLString) else { return nil }
        return base.appendingPathComponent("_unified/health")
    }
}
