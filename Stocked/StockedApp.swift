// StockedApp.swift
import SwiftUI
import CoreLocation
import Combine
import os

// MARK: - Location Manager
@Observable
class LocationManager: NSObject, CLLocationManagerDelegate {
    static let shared = LocationManager()
    private let manager = CLLocationManager()
    var authStatus: CLAuthorizationStatus = .notDetermined
    var location: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        authStatus = manager.authorizationStatus
    }

    func requestPermission() {
        manager.requestWhenInUseAuthorization()
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        authStatus = m.authorizationStatus
        if authStatus == .authorizedWhenInUse || authStatus == .authorizedAlways {
            manager.requestLocation()
        }
    }
    func locationManager(_ m: CLLocationManager, didUpdateLocations locs: [CLLocation]) {
        location = locs.first
    }
    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {}
}

// MARK: - App entry

@main
struct StockedApp: App {
    @State private var session = AppSession()
    @UIApplicationDelegateAdaptor(HouseholdAppDelegate.self) private var appDelegate

    init() {
        #if DEBUG
        BuildConfigurationGuard.logIssues()
        #endif
        // #9 — start MetricKit field instrumentation (launch time, hang rate, memory,
        // crash/hang diagnostics). Additive; delivers aggregated payloads ~daily.
        StockedMetrics.shared.start()
        // #15 perf: a roomy shared URLCache lets cacheable API responses (recipe sources,
        // etc.) return from cache / revalidate with 304s instead of re-downloading.
        URLCache.shared = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                   diskCapacity: 128 * 1024 * 1024)

        // Force dark text in light mode for ALL TextFields app-wide (#1/#20)
        // This is the only reliable way to override environment-inherited colors
        UITextField.appearance().textColor = nil  // let system handle dark mode
        // We control via overrideUserInterfaceStyle instead
        
        // Global keyboard dismissal
        UIScrollView.appearance().keyboardDismissMode = .onDrag
        // Clear ALL system backgrounds so nothing bleeds through
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithTransparentBackground()
        UINavigationBar.appearance().standardAppearance   = navAppearance
        UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance    = navAppearance
        // Kill the window background color that causes the gray strip
        UIView.appearance(whenContainedInInstancesOf: [UIWindow.self]).backgroundColor = .clear
        // Suppress any tab bar system background
        UITabBar.appearance().isHidden = true
        UITabBar.appearance().backgroundColor = .clear
        UITabBar.appearance().barTintColor = .clear
    }

    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
        .onChange(of: scenePhase) { _, phase in
            // Persist any pending debounced settings writes before we lose foreground.
            if phase != .active {
                DebouncedDefaults.shared.flushAll()
                session.guestStore.flushPendingSaves()   // #4 — force batched data saves to disk
                WidgetBridge.refresh(store: session.guestStore)   // keep widgets current
            }
            // #19 — handle Siri-shortcut launch intents when we come to the foreground.
            if phase == .active {
                // Pull the latest household state right away so returning to the app shows
                // changes other members made while we were backgrounded.
                HouseholdSync.shared.syncOnForeground()
                // Remote configuration (kill switches / maintenance / min version) —
                // throttled to one fetch per 15 min, ETag-revalidated.
                Task { await StockedRemoteConfig.shared.refreshIfStale() }
                // #drift — apply any "I used X" items queued by the Siri intent.
                session.guestStore.drainPendingUsedItems()
                let ud = UserDefaults.standard
                if ud.bool(forKey: "pendingOpenGrocery") {
                    ud.set(false, forKey: "pendingOpenGrocery")
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.grocery)
                    }
                }
                if ud.bool(forKey: "pendingStartCooking") {
                    ud.set(false, forKey: "pendingStartCooking")
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.recipes)
                    }
                }
            }
        }
    }

    static func applyTextFieldAppearance(isDark: Bool) {
        // ONLY override text fields — never set UIView backgroundColor (causes blank screen)
        let textColor = isDark
            ? UIColor(red: 0.961, green: 0.949, blue: 0.922, alpha: 1)
            : UIColor(red: 0.13,  green: 0.12,  blue: 0.10,  alpha: 1)
        UITextField.appearance().textColor = textColor
        UITextField.appearance().tintColor = UIColor(red: 0.635, green: 0.447, blue: 0.102, alpha: 1)
        UITableView.appearance().backgroundColor = .clear
        UITableViewCell.appearance().backgroundColor = .clear
    }
}

struct RootView: View {
    @Environment(AppSession.self) var session
    @State private var splashDone = false

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()

            if !splashDone {
                SplashView(onFinish: { splashDone = true })
            } else if session.forceLogin {
                // User just exited guest mode / signed out. Show login even if their onboarding
                // and data were kept (quizCompleted still true) — cleared on next enterKitchen.
                LoginView()
            } else if session.isLoggedIn && session.guestStore.quizCompleted {
                // LOGIN GATE: the main app requires BOTH a completed onboarding AND an active
                // login (Apple or guest-with-name). quizCompleted alone used to be enough,
                // which let stale onboarding state bypass the login screen entirely.
                MainTabView()
                    .environment(\.stockedDevice,
                        UIDevice.current.userInterfaceIdiom == .pad ? .tablet : .regular)
                    .stockedToasts()
            } else if session.isLoggedIn && session.transferManager.isCheckingForExistingAccount {
                // A logged-in user's first-launch iCloud restore check is running. Hold on the
                // splash rather than flashing the onboarding quiz — if they have an existing
                // Stocked backup, the check will restore it and flip quizCompleted, sending them
                // straight to the app. Only if there's no backup do we fall through to the quiz.
                SplashView()
            } else if session.isLoggedIn {
                OnboardingQuiz()
            } else {
                LoginView()
            }

            // Server-driven maintenance / update-required banner (GET /configuration).
            // Renders nothing in the common case; never blocks interaction.
            VStack {
                RemoteConfigBanner()
                    .environment(session)
                    .padding(.top, 4)
                Spacer()
            }
            .zIndex(1500)
            .allowsHitTesting(true)

            // Global household-sync progress prompt — shows on whichever device is syncing
            // (creator, joiner, or a member receiving a push), with success/failure.
            HouseholdSyncProgress()
                .environment(session)
                .zIndex(2000)

        }
        // No .animation(value:) — causes CATransaction fence timeout on iPad
        // when splashDone + quizCompleted + isLoggedIn all change together.
        .preferredColorScheme(session.isDarkMode ? .dark : .light)
        // Dynamic Type support (Change 16): honor the user's system text-size setting, but clamp
        // the extreme accessibility sizes so the app's fixed-size layouts don't break. Raised to
        // accessibility3 to support larger accessibility text sizes while still capping the two
        // largest steps (accessibility4/5), which most often break dense fixed layouts. This makes
        // the app usable across the accessibility text-size range and Display Zoom (Default/Zoomed).
        .dynamicTypeSize(.xSmall ... .accessibility3)
        .onAppear {
            StockedApp.applyTextFieldAppearance(isDark: session.isDarkMode)
            // Deferred remote-config fetch (kill switches, maintenance, min version).
            StockedRemoteConfig.shared.startDeferredLaunchFetch()
            // Restored in Build 140 (these run identically on iPhone, which doesn't crash,
            // so they're not the iPad-only cause). Build 140 isolates the iPad tab-mounting.
            KitchenTransferManager.autoRestoreOnNewDeviceIfNeeded(into: session)
            // LAG FIX: image + nutrition backfills are pure background maintenance; starting
            // them on the first frame competed with initial render/sync. Defer a few seconds.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                RecipeImageResolver.backfillMissingImagesIfNeeded()
                NutritionBackfill.runIfNeeded()
            }
            SharedPantrySync.shared.startObserving(store: session.guestStore)
            // Start automatic household sync so changes from other members appear on their own,
            // with no manual sync. No-op if this device isn't in a household.
            HouseholdSync.shared.startAutoSync(store: session.guestStore)
            HouseholdShareBridge.shared.store = session.guestStore
            Task { await HouseholdCloudKit.shared.ensureSubscriptionsForCurrentRole() }
            // Checkpoint 1: copy existing data into the SwiftData store (non-destructive,
            // runs once). UserDefaults remains the source of truth until the Checkpoint 2
            // cutover; this just builds and keeps a verified parallel mirror.
            Task { @MainActor in
                DataMigration.runIfNeeded(from: session.guestStore)
            }
        }
        .onChange(of: session.isDarkMode) { _, dark in
            StockedApp.applyTextFieldAppearance(isDark: dark)
        }
        .onOpenURL { url in
            Log.app.log("onOpenURL: scheme=\(url.scheme ?? "nil", privacy: .public) host=\(url.host ?? "nil", privacy: .public)")
            // Handle Share Link deep links (stocked://import?data=…) and .stocked file opens.
            // Uses the session-retained manager so async import work isn't orphaned.
            let mgr = session.transferManager
            if url.scheme == "stocked" {
                switch url.host {
                case "shareImport":
                    session.pendingSharedRecipe = true
                case "home":
                    NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.home)
                case "inventory":
                    NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.inventory)
                case "grocery":
                    NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.grocery)
                case "cook":
                    NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.cook)
                case "recipes":
                    NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.recipes)
                default:
                    // #13 widget nav hosts handled above; anything else is an import payload.
                    mgr.importFromDeepLink(url, into: session.guestStore, merge: true)
                }
            } else if url.isFileURL {
                _ = mgr.importFromURL(url, into: session.guestStore, merge: true)
            }
        }
    }
}

#Preview { LoginView().environment(AppSession()) }

// MARK: - Global keyboard dismiss
extension UIApplication {
    func dismissKeyboard() {
        sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}
