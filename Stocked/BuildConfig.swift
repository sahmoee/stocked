// BuildConfig.swift — Reads xcconfig values injected into Info.plist at build time.
//
// ── Xcode setup (one-time) ──────────────────────────────────────────────────
// 1. Open Info.plist, add keys matching each xcconfig variable, e.g.:
//    MealDBBaseURL      → $(MEALDB_BASE_URL)
//    VerboseLogging     → $(VERBOSE_LOGGING)
//    ShowDebugOverlay   → $(SHOW_DEBUG_OVERLAY)
//    EnableMealPrep     → $(ENABLE_MEAL_PREP)
//    EnableStreakBadges → $(ENABLE_STREAK_MILESTONES)
//    NetworkTimeout     → $(NETWORK_TIMEOUT_REQUEST)
// 2. Project → Info → Configurations → assign each .xcconfig to the correct scheme.
// 3. Scheme → Build Configuration → Debug / Staging / Release as needed.
// ────────────────────────────────────────────────────────────────────────────
import Foundation

// nonisolated: pure build constants + config accessors with no shared mutable state, read
// from background/actor contexts (e.g. RecipeImageResolver) as well as the main actor.
nonisolated enum BuildConfig {


    // MARK: - Version info
    // Single source of truth = the app bundle (CFBundleVersion / CFBundleShortVersionString),
    // which come from CURRENT_PROJECT_VERSION / MARKETING_VERSION in Build Settings.
    // MARKETING_VERSION and CURRENT_PROJECT_VERSION are set manually in Xcode. These accessors
    // only read the built bundle; they never mutate or script version numbers. The literals are
    // fallbacks for SwiftUI previews / unit tests where the bundle keys may be absent.
    static var buildNumber: Int {
        Int(bundleString("CFBundleVersion") ?? "") ?? fallbackBuildNumber
    }
    static var version: String {
        let v = bundleString("CFBundleShortVersionString") ?? ""
        return v.isEmpty ? fallbackVersion : v
    }
    static var displayLabel: String { "Build \(buildNumber) · v\(version)" }
    static var buildTag: String     { "Stocked_Build\(buildNumber)_v\(version)" }

    // Fallbacks (keep in sync with Build Settings when you cut a release).
    private static let fallbackBuildNumber = 0
    private static let fallbackVersion     = "0.0"

    static let changeCount   = 1
    static let buildName     = "Build 44 — Adaptive cooking workspace: Start With Something and intent selection, standalone preparation discovery by dish role, cooking method comparison with equipment availability gating and combined device workflows, sectioned Before You Start checklist, hands off orchestration during long cooks, cook ahead now with cooling storage and reheat lifecycle tied to the meal planner, Finish and Serve, compounding prep across upcoming meals, and an inventory consumption coordinator."
    static let buildDate     = "July 2026"

    // MARK: - Environment detection
    nonisolated enum Environment: Sendable { case debug, staging, release }
    static var environment: Environment {
        #if DEBUG
        return .debug
        #else
        return bundleString("StockedEnv") == "staging" ? .staging : .release
        #endif
    }

    // MARK: - API config (falls back to hardcoded defaults if Info.plist not wired yet)
    static var mealDBBaseURL: String {
        bundleString("MealDBBaseURL") ?? "https://www.themealdb.com/api/json/v1/1"
    }
    // MOVED TO WORKER (2026-07): the direct Anthropic path (ClaudeAPIURL/ClaudeModel/
    // ClaudeAPIKey/claudeAPIVersion) is gone. Every AI request goes through the Stocked
    // Worker, which holds the Anthropic key server-side, picks models (with fallback),
    // rate-limits, validates output, and caches. No AI vendor key ships in the app.
    /// Receipt parsing proxied through a Cloudflare Worker that holds the Anthropic
    /// key server-side (no key in the app). See _worker/stocked-receipt-worker/README.md.
    static let receiptWorkerURL = "https://stocked-receipt-worker.stocked.workers.dev"
    /// Custom API domain via a Cloudflare Worker custom-domain route. Once
    /// `api.sowensstudios.com` is verified in Cloudflare (see SOWENS_STUDIOS.md), change
    /// `receiptWorkerURL` above to this value and ship — both URLs hit the same Worker.
    static let receiptWorkerCustomURL = "https://api.sowensstudios.com"

    // ── Sowens Studios — brand & support ─────────────────────────────────────
    static let company        = "Sowens Studios"
    static let websiteURL     = "https://sowensstudios.com"
    static let supportEmail   = "support@sowensstudios.com"
    static let privacyURL     = "https://sowensstudios.com/privacy"
    static let termsURL       = "https://sowensstudios.com/terms"
    static let supportPageURL = "https://sowensstudios.com/support"

    // ── Content CDN (Namecheap cPanel static hosting) ────────────────────────
    // Curated recipe JSON + images live at <contentBaseURL>/content/… served over
    // HTTPS from the Namecheap Stellar Plus disk and cached on-device.
    //
    // NOTE: the apex sowensstudios.com points at Netlify, so cPanel content is served
    // from a subdomain (cdn.sowensstudios.com) pointed at the cPanel server. If you'd
    // rather host the same content/ folder on Netlify instead, set Info.plist
    // ContentBaseURL to https://sowensstudios.com.
    static var contentBaseURL: String { bundleString("ContentBaseURL") ?? "https://cdn.sowensstudios.com" }
    static let contentEnabled = true
    /// Shared secret sent to the Worker as the `X-Stocked-Key` header so the public endpoint
    /// rejects drive-by callers. Injected via xcconfig STOCKED_WORKER_KEY → Info.plist
    /// StockedWorkerKey. Must match the Worker's STOCKED_SHARED_KEY secret. Never hardcode.
    static var stockedWorkerKey: String {
        bundleString("StockedWorkerKey") ?? ""
    }
    /// Applies the Worker auth header to a request, if a key is configured. Centralizes the
    /// header name so all Worker callers stay consistent.
    static func authorizeWorkerRequest(_ request: inout URLRequest) {
        let key = stockedWorkerKey
        if !key.isEmpty { request.setValue(key, forHTTPHeaderField: "X-Stocked-Key") }
    }
    /// Injected via xcconfig SPOONACULAR_API_KEY → Info.plist SpoonacularAPIKey.
    static var spoonacularAPIKey: String {
        bundleString("SpoonacularAPIKey") ?? ""
    }
    /// USDA FoodData Central key (Info.plist USDAAPIKey). Falls back to the rate-limited
    /// DEMO_KEY for development; ship a real free key for production.
    static var usdaAPIKey: String {
        let k = bundleString("USDAAPIKey") ?? "DEMO_KEY"
        return k.isEmpty ? "DEMO_KEY" : k
    }
    /// Edamam Recipe Search free tier (no card). Add EdamamAppID + EdamamAppKey to
    /// Info.plist to enable; absent → the Edamam source simply no-ops.
    static var edamamAppID: String  { bundleString("EdamamAppID")  ?? "" }
    static var edamamAppKey: String { bundleString("EdamamAppKey") ?? "" }
    // Tasty (BuzzFeed) via RapidAPI — free tier. Add to xcconfig: RAPIDAPI_KEY = your_key
    static var rapidAPIKey: String { bundleString("RapidAPIKey") ?? "" }
    /// API Ninjas Cocktail API (free tier, 10k/month). Add APINinjasKey to Info.plist via
    /// Secrets.xcconfig to enable; absent -> the source simply no-ops.
    static var apiNinjasKey: String { bundleString("APINinjasKey") ?? "" }
    /// Suggestic recipe API token. Read from Info.plist's SuggesticAPIToken key, which maps
    /// to SUGGESTIC_API_TOKEN in Secrets.xcconfig. Empty when unconfigured — SuggesticSource
    /// guards on empty and simply returns no results, so this is never a hard dependency.
    static var suggesticToken: String { bundleString("SuggesticAPIToken") ?? "" }
    static var networkTimeout: Double {
        Double(bundleString("NetworkTimeout") ?? "8") ?? 8
    }

    // MARK: - Feature flags
    static var enableMealPrep: Bool     { bundleBool("EnableMealPrep",     default: true)  }
    static var enableStreakBadges: Bool { bundleBool("EnableStreakBadges",  default: true)  }
    static var enableCloudKit: Bool     { bundleBool("EnableCloudKit",      default: false) }
    static var verboseLogging: Bool     { bundleBool("VerboseLogging",      default: false) }
    static var showDebugOverlay: Bool   { bundleBool("ShowDebugOverlay",    default: false) }

    // MARK: - Logging helper
    static func log(_ message: String, file: String = #file, line: Int = #line) {
        guard verboseLogging else { return }
        let _ = (file as NSString).lastPathComponent
    }

    // MARK: - Private helpers
    private static func bundleString(_ key: String) -> String? {
        guard let raw = Bundle.main.infoDictionary?[key] as? String else { return nil }
        // Trim whitespace/newlines so a stray copied space or trailing dash in a pasted
        // API key (a common mistake) can't cause auth failures.
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    private static func bundleBool(_ key: String, default def: Bool) -> Bool {
        guard let val = bundleString(key) else { return def }
        return val == "1" || val.lowercased() == "true"
    }
}
