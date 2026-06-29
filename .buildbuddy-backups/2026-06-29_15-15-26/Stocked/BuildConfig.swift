// BuildConfig.swift — Reads xcconfig values injected into Info.plist at build time.
//
// ── Xcode setup (one-time) ──────────────────────────────────────────────────
// 1. Open Info.plist, add keys matching each xcconfig variable, e.g.:
//    MealDBBaseURL      → $(MEALDB_BASE_URL)
//    ClaudeAPIURL       → $(CLAUDE_API_URL)
//    ClaudeModel        → $(CLAUDE_MODEL)
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
    // The auto-increment build phase bumps CURRENT_PROJECT_VERSION, so these track it
    // automatically — no manual edits needed here on each build. The literals are only
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
    private static let fallbackBuildNumber = 3
    private static let fallbackVersion     = "1.5.1"

    static let changeCount   = 4
    static let buildName     = "Build 272 — The tab bar now matches the mockup: a flat bar that sits directly on the background instead of a dark floating pill, with the active tab in gold. It still stays visible on every screen."
    static let buildDate     = "June 2026"

    // MARK: - Environment detection
    enum Environment { case debug, staging, release }
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
    static var claudeAPIURL: String {
        bundleString("ClaudeAPIURL") ?? "https://api.anthropic.com/v1/messages"
    }
    static var claudeModel: String {
        bundleString("ClaudeModel") ?? "claude-sonnet-4-20250514"
    }
    /// Injected via xcconfig CLAUDE_API_KEY → Info.plist ClaudeAPIKey.
    /// Never hardcode this value — leave it blank here and set it in your xcconfig.
    static var claudeAPIKey: String {
        bundleString("ClaudeAPIKey") ?? ""
    }
    static let claudeAPIVersion = "2023-06-01"
    /// Receipt parsing proxied through a Cloudflare Worker that holds the Anthropic
    /// key server-side (no key in the app). See _worker/stocked-receipt-worker/README.md.
    static let receiptWorkerURL = "https://stocked-receipt-worker.stocked.workers.dev"
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
        let k = bundleString("USDAAPIKey") ?? ""
        return k.isEmpty ? "DEMO_KEY" : k
    }
    /// Edamam Recipe Search free tier (no card). Add EdamamAppID + EdamamAppKey to
    /// Info.plist to enable; absent → the Edamam source simply no-ops.
    static var edamamAppID: String  { bundleString("EdamamAppID")  ?? "" }
    static var edamamAppKey: String { bundleString("EdamamAppKey") ?? "" }
    // Tasty (BuzzFeed) via RapidAPI — free tier. Add to xcconfig: RAPIDAPI_KEY = your_key
    static var rapidAPIKey: String { bundleString("RapidAPIKey") ?? "" }
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
