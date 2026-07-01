// AppSession.swift — top-level app session (theme, nav, cooking profile). The data store and
// settings value types now live in GuestDataStore.swift and AppSettingsTypes.swift (#8/#9 split).
import SwiftUI
import Combine
import os
@preconcurrency import UserNotifications

// MARK: - AppSession
@Observable @MainActor
class AppSession {
    var isLoggedIn:  Bool        = false
    var accountType: AccountType = .guest {
        didSet {
            // Guests never use iCloud shared-pantry sync; only registered accounts do.
            SharedPantrySync.shared.accountAllowsSync = (accountType == .registered)
        }
    }
    var displayName: String      = ""

    // Session-only routing override. Exiting guest mode / signing out should land the user on
    // the login screen even when their onboarding (quizCompleted) and data are kept on the
    // "Keep Data" path. RootView checks this before the quizCompleted gate. Not persisted: a
    // fresh launch with kept data should still go straight into the app. Reset on enterKitchen.
    var forceLogin: Bool = false

    // Set when a recipe is shared in via the Share Extension (stocked://shareImport). The
    // payload itself lives in the App Group; this flag just tells the UI "there's something
    // pending, go consume it once you're on screen." Using a durable flag (not a transient
    // NotificationCenter post) is what makes cold-launch shares work: the share can launch
    // the app from scratch, and the consumer checks this once the main UI appears — rather
    // than needing to catch a notification at the exact launch instant.
    var pendingSharedRecipe: Bool = false

    // Set by the drawer's "Import Recipe" button; consumed once by RecipeVaultView
    // when the Recipes tab appears, to open the URL import sheet. Uses the same
    // set-flag / consume-once pattern as pendingSharedRecipe (a NotificationCenter
    // approach looped: the handler re-fired on every re-render and re-presented the
    // sheet endlessly).
    var pendingRecipeImport: Bool = false

    // Set by handleAppleSignIn when a user signs in with an Apple ID while local guest data
    // exists. RootView / the login surface reads this to prompt the user: migrate the guest
    // data into the account, or discard it and start clean. Nil = no decision pending. The
    // sign-in itself has already registered the account by the time this is set; only the
    // fate of the pre-existing guest data is undecided.
    var pendingSignInMigration: Bool = false

    // Retained transfer manager. iCloud restore/backup spawn async tasks; a session-owned
    // instance (vs a transient local one) guarantees in-flight CloudKit work isn't orphaned
    // before completion — the root cause of restores silently not applying.
    @ObservationIgnored lazy var transferManager: KitchenTransferManager = {
        let m = KitchenTransferManager()
        m.session = self
        return m
    }()

    // MARK: - Theme stored properties (computed color vars + methods are in ThemeEngine.swift)
    // Only light/dark is supported now; theme colors derive from isDarkMode in ThemeEngine.
    var isDarkMode: Bool {
        didSet {
            UserDefaults.standard.set(isDarkMode, forKey: DBKey.darkMode.rawValue)
        }
    }
    var cookButtonShape: CookButtonShape {
        didSet { UserDefaults.standard.set(cookButtonShape.rawValue, forKey: DBKey.cookButtonShape.rawValue) }
    }
    var cookButtonSize: Double {
        didSet { DebouncedDefaults.shared.set(cookButtonSize, forKey: DBKey.cookButtonSize.rawValue) }
    }
    var menuTabHeight: Double {
        didSet { DebouncedDefaults.shared.set(menuTabHeight, forKey: DBKey.menuTabHeight.rawValue) }
    }
    var menuTabWidth: Double {
        didSet { DebouncedDefaults.shared.set(menuTabWidth, forKey: DBKey.menuTabWidth.rawValue) }
    }
    var menuFontOffset: Double {
        didSet { DebouncedDefaults.shared.set(menuFontOffset, forKey: DBKey.menuFontOffset.rawValue) }
    }
    var menuFontSize: Double {
        didSet { DebouncedDefaults.shared.set(menuFontSize, forKey: DBKey.menuFontSize.rawValue) }
    }
    // Font placement (shifts global font positioning — useful for custom fonts)
    var fontVerticalOffset: Double {
        didSet { DebouncedDefaults.shared.set(fontVerticalOffset, forKey: DBKey.fontVerticalOffset.rawValue) }
    }
    var fontHorizontalOffset: Double {
        didSet { DebouncedDefaults.shared.set(fontHorizontalOffset, forKey: DBKey.fontHorizontalOffset.rawValue) }
    }
    var appBackground: AppBackground {
        didSet {
            if let data = try? JSONEncoder().encode(appBackground) {
                UserDefaults.standard.set(data, forKey: "appBackground")
            }
        }
    }
    var preferredStore: String {
        didSet { UserDefaults.standard.set(preferredStore, forKey: DBKey.preferredStore.rawValue) }
    }
    var appleUserID: String {
        didSet { UserDefaults.standard.set(appleUserID, forKey: DBKey.appleUserID.rawValue) }
    }
    /// #20 — a human-readable name for who added an item in a shared household.
    /// Uses the saved Apple display name if present, else the device name.
    var householdMemberName: String {
        let saved = UserDefaults.standard.string(forKey: "householdMemberName_v1") ?? ""
        if !saved.isEmpty { return saved }
        return UIDevice.current.name
    }
    var autoAddMissingToGrocery: Bool {
        didSet { UserDefaults.standard.set(autoAddMissingToGrocery, forKey: DBKey.autoAddMissing.rawValue) }
    }
    var notificationsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(notificationsEnabled, forKey: DBKey.notifications.rawValue)
            if notificationsEnabled { guestStore.requestNotificationPermission() }
        }
    }
    var homeButtonLayout: HomeButtonLayout {
        didSet { UserDefaults.standard.set(homeButtonLayout.rawValue, forKey: DBKey.homeLayout.rawValue) }
    }
    // Bolt button position: "bottomRight" | "bottomLeft" | "bottomCenter"
    var boltPosition: String {
        didSet { UserDefaults.standard.set(boltPosition, forKey: DBKey.boltPosition.rawValue) }
    }

    // ── New settings (Build 80) ─────────────────────────────────────
    var hapticIntensity: HapticIntensity {
        didSet { UserDefaults.standard.set(hapticIntensity.rawValue, forKey: DBKey.hapticIntensity.rawValue) }
    }
    var preferredRecipeTab: Int {
        didSet { UserDefaults.standard.set(preferredRecipeTab, forKey: DBKey.preferredRecipeTab.rawValue) }
    }
    var backupFrequency: BackupFrequency {
        didSet { UserDefaults.standard.set(backupFrequency.rawValue, forKey: DBKey.backupFrequency.rawValue) }
    }
    var householdCode: String {
        didSet { UserDefaults.standard.set(householdCode, forKey: DBKey.householdCode.rawValue) }
    }

    // ── Cook Streak ─────────────────────────────────────────────────
    var cookStreak: Int {
        didSet { UserDefaults.standard.set(cookStreak, forKey: DBKey.cookStreak.rawValue) }
    }

    // ── Active cook (#228) ──────────────────────────────────────────
    // The recipe currently mid-cook, so the floating "In Progress" pill can resume it
    // from anywhere. Set when the cook flow appears; cleared on finish or explicit stop.
    nonisolated struct ActiveCookSession: Codable, Identifiable {
        var title: String
        var ingredients: [String]
        var steps: [String]
        var servings: Int
        var startedAt: Date
        var id: String { title }
    }
    var activeCook: ActiveCookSession? = AppSession.loadActiveCook() {
        didSet {
            if let cook = activeCook, let data = try? JSONEncoder().encode(cook) {
                UserDefaults.standard.set(data, forKey: "activeCookSession")
            } else {
                UserDefaults.standard.removeObject(forKey: "activeCookSession")
            }
        }
    }
    // ── Recently viewed recipes (#240) ──────────────────────────────
    var recentlyViewedRecipeIDs: [UUID] = (UserDefaults.standard.array(forKey: "recentlyViewedRecipes") as? [String])?.compactMap(UUID.init) ?? [] {
        didSet { UserDefaults.standard.set(recentlyViewedRecipeIDs.map(\.uuidString), forKey: "recentlyViewedRecipes") }
    }
    func recordRecipeView(_ id: UUID) {
        var ids = recentlyViewedRecipeIDs.filter { $0 != id }
        ids.insert(id, at: 0)
        recentlyViewedRecipeIDs = Array(ids.prefix(10))
    }

    nonisolated private static func loadActiveCook() -> ActiveCookSession? {
        guard let data = UserDefaults.standard.data(forKey: "activeCookSession"),
              let cook = try? JSONDecoder().decode(ActiveCookSession.self, from: data) else { return nil }
        // Stale after 2h — matches the cook flow's own progress TTL.
        return Date().timeIntervalSince(cook.startedAt) < 7200 ? cook : nil
    }

    var longestStreak: Int {
        didSet { UserDefaults.standard.set(longestStreak, forKey: DBKey.longestStreak.rawValue) }
    }
    var lastCookDate: Date? {
        didSet { UserDefaults.standard.set(lastCookDate, forKey: DBKey.lastCookDate.rawValue) }
    }
    var newMilestone: Int = 0   // set briefly when a milestone is hit
    var appTheme: AppTheme {
        didSet { UserDefaults.standard.set(appTheme.rawValue, forKey: DBKey.appTheme.rawValue) }
    }
    var appFont: AppFont {
        didSet { UserDefaults.standard.set(appFont.rawValue, forKey: DBKey.appFont.rawValue) }
    }

    // Measurement system for recipe display + conversion (US ⇄ Metric). Read by CookingFlow
    // and the Drawer settings; persisted like the other single-choice preferences.
    var unitSystem: UnitSystem = .us {
        didSet { UserDefaults.standard.set(unitSystem.rawValue, forKey: DBKey.unitSystem.rawValue) }
    }


    let guestStore = GuestDataStore()

    // MARK: - Recipe/grocery facade (#7)
    // Single, unambiguous entry point. These forward to the guest store so callers write
    // `session.renameUserRecipe(…)` and never have to know which object owns the method —
    // the confusion that caused a rename to be called on the wrong type. Additive: the
    // GuestDataStore methods (and `session.guestStore.…`) still work unchanged.
    func addUserRecipe(_ r: UserRecipe)            { guestStore.addUserRecipe(r) }
    func updateUserRecipe(_ r: UserRecipe)         { guestStore.updateUserRecipe(r) }
    func renameUserRecipe(id: UUID, name: String)  { guestStore.renameUserRecipe(id: id, name: name) }
    func deleteUserRecipe(id: UUID)                { guestStore.deleteUserRecipe(id: id) }
    @discardableResult
    func addRecipeIngredientsToGrocery(_ ingredients: [RecipeIngredient], recipeName: String) -> Int {
        guestStore.addRecipeIngredientsToGrocery(ingredients, recipeName: recipeName)
    }

    var hasExistingSession: Bool {
        let hasName  = !guestStore.displayName.isEmpty
        let hasItems = !guestStore.inventoryItems.isEmpty || !guestStore.groceryItems.isEmpty
        return UserDefaults.standard.bool(forKey: "wasGuest") && (hasName || hasItems)
    }
    var isNamedUser: Bool {
        !displayName.trimmingCharacters(in: .whitespaces).isEmpty && displayName.lowercased() != "guest"
    }
    var userName: String { isNamedUser ? displayName : "Chef" }
    // Convenience
    func applyTheme(_ theme: AppTheme) {
        appTheme = theme
        isDarkMode = (theme == .custom)
    }

    // MARK: - Backup / restore of preferences
    // Capture all user-facing settings into a Codable payload for kitchen backups.
    func capturePreferences() -> KitchenPreferences {
        KitchenPreferences(
            appTheme: appTheme.rawValue,
            appFont: appFont.rawValue,
            isDarkMode: isDarkMode,
            preferredStore: preferredStore,
            autoAddMissingToGrocery: autoAddMissingToGrocery,
            notificationsEnabled: notificationsEnabled,
            homeButtonLayout: homeButtonLayout.rawValue,
            cookButtonShape: cookButtonShape.rawValue,
            cookButtonSize: cookButtonSize,
            preferredRecipeTab: preferredRecipeTab,
            cookStreak: cookStreak,
            longestStreak: longestStreak
        )
    }

    // Apply a restored preferences payload. Each didSet persists to UserDefaults.
    func applyPreferences(_ p: KitchenPreferences) {
        if let t = AppTheme(rawValue: p.appTheme) { appTheme = t }
        if let f = AppFont(rawValue: p.appFont) { appFont = f }
        isDarkMode = p.isDarkMode
        if !p.preferredStore.isEmpty { preferredStore = p.preferredStore }
        autoAddMissingToGrocery = p.autoAddMissingToGrocery
        notificationsEnabled = p.notificationsEnabled
        if let l = HomeButtonLayout(rawValue: p.homeButtonLayout) { homeButtonLayout = l }
        if let s = CookButtonShape(rawValue: p.cookButtonShape) { cookButtonShape = s }
        if p.cookButtonSize > 0 { cookButtonSize = p.cookButtonSize }
        preferredRecipeTab = p.preferredRecipeTab
        cookStreak = max(cookStreak, p.cookStreak)
        longestStreak = max(longestStreak, p.longestStreak)
    }


    // Call from RatingView.finishMeal() every time a meal is logged
    func recordCookToday() {
        let cal      = Calendar.current
        let today    = cal.startOfDay(for: Date())
        let lastDay  = lastCookDate.map { cal.startOfDay(for: $0) }

        if let last = lastDay, cal.isDate(last, inSameDayAs: today) {
            // Already cooked today — no streak change
            return
        } else if let last = lastDay,
                  let yesterday = cal.date(byAdding: .day, value: -1, to: today),
                  cal.isDate(last, inSameDayAs: yesterday) {
            // Cooked yesterday — extend streak
            cookStreak    += 1
        } else {
            // Gap or first cook — reset to 1
            cookStreak     = 1
        }
        lastCookDate   = Date()
        longestStreak  = max(longestStreak, cookStreak)
        AppAnalytics.shared.log(.cookCompleted)

        // Check milestones
        let milestones = [3, 7, 14, 30, 50, 100]
        if milestones.contains(cookStreak) {
            newMilestone = cookStreak
            // Auto-clear after 4 s
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4000000000)
                self?.newMilestone = 0
            }
        }
    }

    func streakEmoji(_ days: Int) -> String {
        switch days {
        case 0:      return "🍽️"
        case 1...2:  return "🔥"
        case 3...6:  return "🔥🔥"
        case 7...13: return "⚡️🔥"
        case 14...29: return "🌟🔥"
        case 30...49: return "💥🌟🔥"
        default:     return "👨‍🍳🏆🔥"
        }
    }

    var backgroundView: AnyView {
        switch appBackground {
        case .defaultTan:             return AnyView(Color.stockedBg)
        case .color(let r,let g,let b): return AnyView(Color(red:r,green:g,blue:b))
        case .photo(let data):
            if let ui = UIImage(data: data) { return AnyView(Image(uiImage:ui).resizable().scaledToFill()) }
            return AnyView(Color.stockedBg)
        }
    }
    var backgroundColor: Color {
        switch appBackground {
        case .defaultTan:             return Color.stockedBg
        case .color(let r,let g,let b): return Color(red:r,green:g,blue:b)
        case .photo:                  return Color.clear
        }
    }

    init() {
        let ud = UserDefaults.standard
        self.isDarkMode           = ud.bool(forKey: DBKey.darkMode.rawValue)
        let savedFontV            = ud.object(forKey: DBKey.fontVerticalOffset.rawValue)
        self.fontVerticalOffset   = savedFontV != nil ? ud.double(forKey: DBKey.fontVerticalOffset.rawValue) : 0
        let savedFontH            = ud.object(forKey: DBKey.fontHorizontalOffset.rawValue)
        self.fontHorizontalOffset = savedFontH != nil ? ud.double(forKey: DBKey.fontHorizontalOffset.rawValue) : 0
        let savedTabH             = ud.double(forKey: DBKey.menuTabHeight.rawValue)
        self.menuTabHeight        = (savedTabH >= 60 && savedTabH <= 200) ? savedTabH : 112
        let savedTabW             = ud.double(forKey: DBKey.menuTabWidth.rawValue)
        self.menuTabWidth         = (savedTabW >= 16 && savedTabW <= 60) ? savedTabW : 28
        let shapeName             = ud.string(forKey: DBKey.cookButtonShape.rawValue) ?? ""
        self.cookButtonShape      = CookButtonShape(rawValue: shapeName) ?? .circle
        let savedSize             = ud.double(forKey: DBKey.cookButtonSize.rawValue)
        let deviceDefault         = StockedScreen.defaultCookButtonSize(forWidth: StockedScreen.width)
        self.cookButtonSize       = (savedSize >= 150 && savedSize <= 500) ? savedSize : deviceDefault
        let savedLayout           = ud.string(forKey: DBKey.homeLayout.rawValue) ?? ""
        self.homeButtonLayout     = HomeButtonLayout(rawValue: savedLayout) ?? .vertical
        let savedFontOffset       = ud.double(forKey: DBKey.menuFontOffset.rawValue)
        self.menuFontOffset       = (savedFontOffset >= -60 && savedFontOffset <= 60) ? savedFontOffset : 0
        let savedFontSize         = ud.double(forKey: DBKey.menuFontSize.rawValue)
        self.menuFontSize         = (savedFontSize >= 8 && savedFontSize <= 28) ? savedFontSize : 11
        self.autoAddMissingToGrocery  = ud.bool(forKey: DBKey.autoAddMissing.rawValue)
        self.notificationsEnabled     = ud.bool(forKey: DBKey.notifications.rawValue)
        self.boltPosition             = ud.string(forKey: DBKey.boltPosition.rawValue) ?? "bottomRight"
        self.hapticIntensity          = HapticIntensity(rawValue: ud.string(forKey: DBKey.hapticIntensity.rawValue) ?? "") ?? .medium
        self.preferredRecipeTab       = ud.integer(forKey: DBKey.preferredRecipeTab.rawValue)   // default 0 = Ready to Cook
        self.backupFrequency          = BackupFrequency(rawValue: ud.string(forKey: DBKey.backupFrequency.rawValue) ?? "") ?? .manual
        self.householdCode            = ud.string(forKey: DBKey.householdCode.rawValue) ?? ""
        self.cookStreak               = ud.integer(forKey: DBKey.cookStreak.rawValue)
        self.longestStreak            = ud.integer(forKey: DBKey.longestStreak.rawValue)
        self.lastCookDate             = ud.object(forKey: DBKey.lastCookDate.rawValue) as? Date
        // appTheme is always .custom — all colors come from the 6 channel vars
        self.appTheme                 = .custom
        let savedFont                 = ud.string(forKey: DBKey.appFont.rawValue) ?? ""
        self.appFont                  = AppFont(rawValue: savedFont) ?? .serif
        self.unitSystem               = UnitSystem(rawValue: ud.string(forKey: DBKey.unitSystem.rawValue) ?? "") ?? .us

        if let bgData = ud.data(forKey: "appBackground"),
           let decoded = try? JSONDecoder().decode(AppBackground.self, from: bgData) {
            self.appBackground = decoded
        } else {
            self.appBackground = .defaultTan
        }
        self.preferredStore = ud.string(forKey: DBKey.preferredStore.rawValue) ?? "Walmart"
        self.appleUserID    = ud.string(forKey: DBKey.appleUserID.rawValue) ?? ""

        if ud.bool(forKey: "wasGuest") {
            accountType = .guest
            displayName = guestStore.displayName
            if hasExistingSession { isLoggedIn = true }
        } else if !self.appleUserID.isEmpty {
            // A stored Apple credential with no guest marker means a previously signed-in
            // registered user. Restore them as registered so relaunch doesn't silently drop
            // them back to guest (which would re-gate iCloud sync off).
            accountType = .registered
            let stored = ud.string(forKey: DBKey.appleFirstName.rawValue) ?? ""
            displayName = stored.isEmpty ? guestStore.displayName : stored
            isLoggedIn  = true
        }

        // didSet does not fire during init, so set the sync gate explicitly to match the
        // account type we just resolved. Guests never use iCloud shared-pantry sync.
        SharedPantrySync.shared.accountAllowsSync = (accountType == .registered)
    }

    func enterKitchen(name: String = "") {
        let n = name.trimmingCharacters(in: .whitespaces)
        accountType = .guest
        displayName = n.isEmpty ? "" : n
        if !n.isEmpty { guestStore.displayName = n }
        isLoggedIn = true
        forceLogin = false
        UserDefaults.standard.set(true, forKey: "wasGuest")
        guestStore.requestNotificationPermission()
    }
    func continueAsGuest() { enterKitchen() }

    /// Sign in with an Apple ID. THIS is what actually registers the account — the previous
    /// path routed Apple sign-in through enterKitchen(), which hard-set accountType to .guest
    /// and wasGuest=true, so a signed-in user stayed a guest forever (guest greeting, sync
    /// gated off). Here we set accountType to .registered, clear the guest marker, persist the
    /// Apple credential, and let the accountType didSet enable iCloud sync.
    ///
    /// hadGuestData: whether local guest data existed at sign-in time. When true we flag
    /// pendingSignInMigration so the UI can ask the user whether to migrate or discard it —
    /// we do NOT auto-wipe or auto-merge here, per the "ask at sign-in" decision.
    func signIn(appleUserID userID: String, name: String, hadGuestData: Bool) {
        let n = name.trimmingCharacters(in: .whitespaces)
        appleUserID = userID
        accountType = .registered            // didSet enables accountAllowsSync
        displayName = n
        if !n.isEmpty { guestStore.displayName = n }
        isLoggedIn  = true
        forceLogin  = false

        // No longer a guest session. Clearing this marker is what stops the app from
        // resolving back to guest on the next cold launch (init reads wasGuest).
        UserDefaults.standard.set(false, forKey: "wasGuest")

        // Belt-and-suspenders: didSet already ran, but set the gate explicitly too.
        SharedPantrySync.shared.accountAllowsSync = true

        pendingSignInMigration = hadGuestData
        guestStore.requestNotificationPermission()
    }

    /// User chose to KEEP their guest data on sign-in: nothing to move (the data already lives
    /// in guestStore and now belongs to the registered account). Just clear the prompt.
    func resolveSignInMigration(keepGuestData: Bool) {
        if !keepGuestData {
            // Discard: wipe the pre-sign-in guest data so the account starts clean. This does
            // not sign the user out — they remain registered.
            guestStore.clearAll()
            displayName = ""
        }
        pendingSignInMigration = false
    }

    // Convenience helpers used by DailyBriefView
    var effectiveName: String {
        let n = displayName.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? (guestStore.displayName.trimmingCharacters(in: .whitespaces).isEmpty ? "Chef" : guestStore.displayName) : n
    }

    func updateName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        displayName = trimmed
        guestStore.displayName = trimmed
    }

    func signOut(clearData: Bool = false) {
        if clearData {
            // Wipe all GuestDataStore data and caches
            guestStore.clearAll()

            // Reset all AppSession preferences to factory defaults
            isDarkMode           = false
            preferredStore       = "Walmart"
            appleUserID          = ""
            cookStreak           = 0
            longestStreak        = 0
            lastCookDate         = nil
            appTheme             = .tan
            appFont              = .serif
            unitSystem           = .us
            appBackground        = .defaultTan
            notificationsEnabled = true
            menuTabHeight        = 112
            menuTabWidth         = 28
            cookButtonShape      = .circle
            cookButtonSize       = 240
            homeButtonLayout     = .vertical
            menuFontOffset       = 0
            menuFontSize         = 11
            hapticIntensity      = .medium
            preferredRecipeTab   = 0
            backupFrequency      = .manual
            householdCode        = ""

            // Ensure UserDefaults is fully cleared (belt-and-suspenders)
            if let bundleID = Bundle.main.bundleIdentifier {
                UserDefaults.standard.removePersistentDomain(forName: bundleID)
            }
        }

        // Always reset login state. forceLogin sends RootView to the login screen even on the
        // "Keep Data" path, where quizCompleted stays true so the user's onboarding + data are
        // preserved for when they sign back in. (clearData wipes quizCompleted via clearAll, so
        // that path would route to login regardless; this makes Keep Data behave the same way.)
        isLoggedIn   = false
        accountType  = .guest
        displayName  = ""
        forceLogin   = true
    }

    /// Full account deletion (Apple App Store requirement for apps with accounts).
    /// Severs CloudKit household membership, then erases ALL local data, preferences, and the
    /// stored Apple credential — returning the app to a clean first-launch state. The user's
    /// Apple ID itself is managed by Apple (we can only stop using it and delete our data).
    func deleteAccount() {
        // Leave any shared household so this device stops syncing and is removed as a participant.
        HouseholdCloudKit.shared.leaveHousehold()
        // Reuse the thorough local wipe (data, caches, prefs, UserDefaults domain, Apple ID).
        signOut(clearData: true)
        Log.transfer.notice("Account deleted: local data and credentials cleared")
    }
}
