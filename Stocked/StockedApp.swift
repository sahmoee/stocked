// StockedApp.swift
import SwiftUI
import CoreLocation
import Combine
import os
import CoreSpotlight

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
            // Feed the live window/container size to every screen. Without this wrapper,
            // `stockedLayout` stayed on its 393pt fallback, so iPad, Split View, landscape,
            // and larger iPhones all rendered a phone-width column in the middle of the
            // available canvas.
            DeviceAdaptiveRoot {
                RootView()
                    .stockedAdaptiveInterface()
                    .stockedSizeAwareScrollBounce([.vertical, .horizontal])
                    .appWideExperience()
            }
            .environment(session)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { QABackgroundRunner.shared.stop() }
            // Persist any pending debounced settings writes before we lose foreground.
            if phase != .active {
                DebouncedDefaults.shared.flushAll()
                session.guestStore.flushPendingSaves()   // #4 — force batched data saves to disk
                StockedFeatureStores.flushAll()          // #6 — same for the feature stores
                WidgetBridge.refresh(store: session.guestStore)   // keep widgets current
            }
            // #19 — handle Siri-shortcut launch intents when we come to the foreground.
            if phase == .active {
                // #14 — one data point for when this user is actually reachable. Used to nudge
                // reminder delivery toward a time they'll see it, within bounds they chose.
                NotificationEngagement.shared.recordAppOpen()
                // Keep the derived inventory index fresh so the first screen doesn't rebuild it.
                InventoryIndex.shared.refreshIfNeeded(session.guestStore)
                // Pull the latest household state right away so returning to the app shows
                // changes other members made while we were backgrounded.
                HouseholdSync.shared.syncOnForeground()
                // Pull any recipes the Mac app has harvested and approved since we last looked
                // (GET /harvest/recipes, ETag-revalidated, throttled to one pull per 5 min).
                HarvestRecipeSync.shared.syncOnForeground()
                // Remote configuration (kill switches / maintenance / min version) —
                // throttled to one fetch per 15 min, ETag-revalidated.
                Task { await StockedRemoteConfig.shared.refreshIfStale() }
                // QA automation: re-check invariants when returning to the foreground.
                if QARecorder.shared.isEnabled {
                    QABackgroundRunner.shared.start(store: session.guestStore, session: nil)
                    QABackgroundRunner.shared.runSoon()
                }
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
    @State private var nameEntry = ""   // FR-03: bound to the Apple name-entry prompt

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
                    .stockedToasts()
            } else if session.isLoggedIn {
                // FR-02 FIX: the old "isCheckingForExistingAccount → SplashView()" branch was
                // removed. It existed only to hold the screen during the launch iCloud auto-restore
                // (also removed, FR-01). With auto-restore gone that branch could only ever show a
                // bare splash with no way forward — which is the "skip onboarding → blank until
                // relaunch" bug. A logged-in user with onboarding not yet complete belongs on the
                // quiz, full stop.
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

            QATapTracker().zIndex(2400)
            QAIssueReporter().zIndex(2450)
            QAHUD().zIndex(2350)
            QATouchTrailTracker().zIndex(2410)
            QATouchOverlayMount().zIndex(2420)
            QAFloatingButtonMount().zIndex(2460)
            QAShakeMount().zIndex(2470)

            // Global household-sync progress prompt — shows on whichever device is syncing
            // (creator, joiner, or a member receiving a push), with success/failure.
            HouseholdSyncProgress()
                .environment(session)
                .zIndex(2000)

        }
        // FR-01 FIX (point 4): consent prompt for restoring an existing iCloud backup after
        // Sign in with Apple. Nothing is pulled from iCloud unless the user taps Restore.
        .alert("Restore your Stocked data?", isPresented: Binding(
            get: { session.pendingICloudRestoreOffer },
            set: { if !$0 { session.pendingICloudRestoreOffer = false } })) {
            Button("Restore from iCloud") {
                session.pendingICloudRestoreOffer = false
                // The backup carries the user's real name, so no name prompt is needed.
                session.pendingAppleNamePrompt = false
                session.transferManager.restoreFromiCloud(into: session.guestStore, merge: true)
            }
            Button("Start Fresh", role: .cancel) {
                session.pendingICloudRestoreOffer = false
            }
        } message: {
            Text("This Apple ID has a saved Stocked backup. Restore your previous setup — inventory, recipes, settings, and onboarding — or start fresh and take the quiz again.")
        }
        // FR-03 FIX: name-entry prompt when Sign in with Apple gave no name. Gated so it never
        // fights the restore prompt — if a restore is offered, we wait for that decision first
        // (restoring brings the real name back and clears this).
        .alert("What should we call you?", isPresented: Binding(
            get: { session.pendingAppleNamePrompt && !session.pendingICloudRestoreOffer },
            set: { if !$0 { session.pendingAppleNamePrompt = false } })) {
            TextField("Your name", text: $nameEntry)
                .textInputAutocapitalization(.words)
            Button("Save") {
                let n = nameEntry.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty {
                    session.updateName(n)
                    // Persist to the Keychain vault so it survives future reinstalls too.
                    if !session.appleUserID.isEmpty {
                        AppleProfileVault.remember(userID: session.appleUserID,
                                                   firstName: n, fullName: n, email: "")
                    }
                }
                session.pendingAppleNamePrompt = false
                nameEntry = ""
            }
            Button("Not now", role: .cancel) {
                session.pendingAppleNamePrompt = false
                nameEntry = ""
            }
        } message: {
            Text("Apple didn't share your name this time. Add it so Stocked can greet you properly — you can change it later in Settings.")
        }
        // No .animation(value:) — causes CATransaction fence timeout on iPad
        // when splashDone + quizCompleted + isLoggedIn all change together.
        .preferredColorScheme(session.isDarkMode ? .dark : .light)
        .task(id: session.guestStore.hasCompletedInitialHydration) {
            guard session.guestStore.hasCompletedInitialHydration else { return }
            // Wait for real local data, not the deliberately empty launch placeholders.
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            await HarvestRecipeSync.shared.backfillImported(session.guestStore.userRecipes)
        }
        // Dynamic Type support (Change 16): honor the user's system text-size setting, but clamp
        // the extreme accessibility sizes so the app's fixed-size layouts don't break. Raised to
        // accessibility3 to support larger accessibility text sizes while still capping the two
        // largest steps (accessibility4/5), which most often break dense fixed layouts. This makes
        // the app usable across the accessibility text-size range and Display Zoom (Default/Zoomed).

        .onAppear {
            StockedApp.applyTextFieldAppearance(isDark: session.isDarkMode)
            // Deferred remote-config fetch (kill switches, maintenance, min version).
            StockedRemoteConfig.shared.startDeferredLaunchFetch()
            // QA automation: if QA mode was left enabled, the invariant runner starts
            // by itself at launch — no need to visit the QA screen first.
            // Retain the weak store reference even when QA starts disabled.
            // start() does no work until enabled; otherwise the first enable's
            // resume() has no store and silently leaves autonomy idle.
            QABackgroundRunner.shared.start(store: session.guestStore, session: nil)
            // FR-01 FIX: the launch-time iCloud auto-restore was REMOVED. It ran for guests,
            // before login, with no consent, and re-imported a CloudKit backup that survives app
            // deletion — which is what made a "fresh" install come up with 94% stock, dark mode,
            // skipped onboarding, and a blank splash while the CloudKit fetch ran. A fresh install
            // must be empty and light. Restore is now explicit only: Settings ▸ Restore from
            // iCloud, or the consent prompt after Sign in with Apple (see LoginView).
            // LAG FIX: image + nutrition backfills are pure background maintenance; starting
            // them on the first frame competed with initial render/sync. Defer a few seconds.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                // Build 89 — clear out the retired recipe sources (the bundled Kaggle
                // dataset and the "Sowens" curated feed). It runs before the Spotlight
                // reindex on purpose: indexing recipes that are about to be deleted would
                // leave them showing in system search after they were gone from the app.
                // Cheap enough to run every launch — a filter over two arrays and one
                // pass of the recipe database, with a write only if something was found —
                // and running it every launch is what catches rows arriving over
                // household sync from a device still on an older build.
                await RecipePurge.run(store: session.guestStore)
                RecipeImageResolver.backfillMissingImagesIfNeeded()
                NutritionBackfill.runIfNeeded()
                Task { await FoodRecallMonitor.shared.refreshIfNeeded(items: session.guestStore.inventoryItems) }
                RetailEnrichmentMaintenance.runIfNeeded(store: session.guestStore)
                // #17 — index recipes + inventory for system Spotlight search.
                SpotlightIndexer.reindex(store: session.guestStore)
            }
            SharedPantrySync.shared.startObserving(store: session.guestStore)
            // Start automatic household sync so changes from other members appear on their own,
            // with no manual sync. No-op if this device isn't in a household.
            HouseholdSync.shared.startAutoSync(store: session.guestStore)
            // Start pulling Mac-harvested recipes from the Worker cache: once now, then every
            // 15 min (plus on each foreground). Recipes the Mac approves show up here on their
            // own. No-op if the Worker isn't configured or the device is offline.
            HarvestRecipeSync.shared.start()
            HouseholdShareBridge.shared.store = session.guestStore
            Task { await HouseholdCloudKit.shared.ensureSubscriptionsForCurrentRole() }
            // Checkpoint 1: copy existing data into the SwiftData store (non-destructive,
            // runs once). UserDefaults remains the source of truth until the Checkpoint 2
            // cutover; this just builds and keeps a verified parallel mirror.
            Task { @MainActor in
                _ = await DataMigration.runIfNeeded(from: session.guestStore)
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
        // Universal links (improvement #3): HTTPS links on the associated domain — e.g. a
        // scanned container-label QR `https://sowensstudios.com/l/<uuid>` — arrive as a
        // web-browsing user activity, not via onOpenURL. Route them to the same surfaces.
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            guard let web = activity.webpageURL,
                  web.host?.contains("sowensstudios.com") == true else { return }
            let parts = web.pathComponents.filter { $0 != "/" }
            switch parts.first {
            case "l":                                       // container label
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.inventory)
            case "grocery":
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.grocery)
            case "cook":
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.cook)
            case "recipes":
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.recipes)
            default:
                NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.home)
            }
        }
        // #17 — a tapped Spotlight result opens the matching hub.
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            NotificationCenter.default.post(name: .stockedSwitchTab, object: SpotlightIndexer.route(for: id))
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
