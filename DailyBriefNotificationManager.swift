// DailyBriefNotificationManager.swift
// ─────────────────────────────────────────────────────────────────────
// Schedules a daily local notification summarising expiring items
// and what you can cook tonight. Deep-links to the Daily Brief on tap.
// Time is user-configurable (default 7:30 AM).
// ─────────────────────────────────────────────────────────────────────
import Foundation
import UserNotifications

@MainActor
final class DailyBriefNotificationManager {

    static let shared = DailyBriefNotificationManager()
    private init() {}

    // MARK: - Authorization

    /// One-shot permission request. Call this the first time the user enables ANY reminder
    /// so iOS actually shows the system prompt. The completion returns on the main actor with
    /// whether permission is now granted, so the UI can reflect Allowed / Denied immediately.
    func requestAuthorization(_ completion: @escaping @MainActor (Bool) -> Void = { _ in }) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in completion(granted) }
        }
    }

    /// Reads the current system authorization status (so Settings can show whether the user
    /// has actually allowed notifications, and offer a path to the Settings app if denied).
    func authorizationStatus(_ completion: @escaping @MainActor (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in completion(settings.authorizationStatus) }
        }
    }

    private let categoryID  = "DAILY_BRIEF"
    private let requestID   = "stocked_daily_brief"
    private let hourKey     = "dailyBriefHour"
    private let minKey      = "dailyBriefMinute"
    private let enabledKey  = "dailyBriefEnabled"

    // ── Configurable fire times for the other reminder types ──────────────────
    // These used to be hardcoded (expiry 9 AM, cook 4 PM, staples 5 PM, prep 10 AM).
    // Each now reads from UserDefaults with the old hardcoded value as its default, so
    // existing behaviour is unchanged until the user picks a new time in Settings.
    private let expiryHourKey  = "expiryReminderHour"
    private let expiryMinKey   = "expiryReminderMinute"
    private let cookHourKey    = "cookSuggestionHour"
    private let cookMinKey     = "cookSuggestionMinute"
    private let stapleHourKey  = "stapleNudgeHour"
    private let stapleMinKey   = "stapleNudgeMinute"
    private let prepHourKey    = "prepReminderHour"
    private let prepMinKey     = "prepReminderMinute"

    // Helper: read an hour key that uses 0 as "unset" (fall back to the supplied default).
    private func storedHour(_ key: String, default def: Int) -> Int {
        let v = UserDefaults.standard.object(forKey: key) as? Int
        return v ?? def
    }
    private func storedMinute(_ key: String) -> Int {
        UserDefaults.standard.integer(forKey: key)
    }

    var expiryHour: Int {
        get { storedHour(expiryHourKey, default: 9) }
        set { UserDefaults.standard.set(newValue, forKey: expiryHourKey) }
    }
    var expiryMinute: Int {
        get { storedMinute(expiryMinKey) }
        set { UserDefaults.standard.set(newValue, forKey: expiryMinKey) }
    }
    var cookHour: Int {
        get { storedHour(cookHourKey, default: 16) }
        set { UserDefaults.standard.set(newValue, forKey: cookHourKey) }
    }
    var cookMinute: Int {
        get { storedMinute(cookMinKey) }
        set { UserDefaults.standard.set(newValue, forKey: cookMinKey) }
    }
    var stapleHour: Int {
        get { storedHour(stapleHourKey, default: 17) }
        set { UserDefaults.standard.set(newValue, forKey: stapleHourKey) }
    }
    var stapleMinute: Int {
        get { storedMinute(stapleMinKey) }
        set { UserDefaults.standard.set(newValue, forKey: stapleMinKey) }
    }
    var prepHour: Int {
        get { storedHour(prepHourKey, default: 10) }
        set { UserDefaults.standard.set(newValue, forKey: prepHourKey) }
    }
    var prepMinute: Int {
        get { storedMinute(prepMinKey) }
        set { UserDefaults.standard.set(newValue, forKey: prepMinKey) }
    }

    // #9 — per-item expiry reminders
    private let expiryEnabledKey = "expiryRemindersEnabled"
    private let expiryPrefix     = "stocked_expiry_"   // id prefix for per-item requests

    // #13 — batched "use it up" cook suggestion: one notification that names a recipe you
    // can make from what's expiring. More actionable than per-item "X expires tomorrow".
    private let cookSuggestEnabledKey = "cookSuggestionEnabled"
    private let cookSuggestRequestID  = "stocked_cook_suggestion"

    var cookSuggestionEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: cookSuggestEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: cookSuggestEnabledKey) }
    }

    var expiryRemindersEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: expiryEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: expiryEnabledKey) }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }
    var hour: Int {
        get { UserDefaults.standard.integer(forKey: hourKey) == 0 ? 7 : UserDefaults.standard.integer(forKey: hourKey) }
        set { UserDefaults.standard.set(newValue, forKey: hourKey) }
    }
    var minute: Int {
        get { UserDefaults.standard.integer(forKey: minKey) }
        set { UserDefaults.standard.set(newValue, forKey: minKey) }
    }

    // MARK: - Schedule

    func scheduleIfEnabled(store: GuestDataStore) {
        guard isEnabled else { cancel(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in self.schedule(store: store) }
        }
    }

    func schedule(store: GuestDataStore) {
        cancel()
        let content  = UNMutableNotificationContent()
        content.categoryIdentifier = categoryID
        content.sound = .default

        // Build a useful summary
        let expiring = store.inventoryItems.filter { item in
            guard let exp = item.expirationDate else { return false }
            return exp.timeIntervalSinceNow < 86400 * 3 && exp.timeIntervalSinceNow > 0
        }
        let lowStock = store.inventoryItems.filter { $0.level < 0.2 }

        if expiring.isEmpty && lowStock.isEmpty {
            content.title = "Good morning, your kitchen is looking good 🍳"
            content.body  = "Tap to see what you can cook tonight."
        } else {
            var parts: [String] = []
            if !expiring.isEmpty {
                parts.append("⏰ \(expiring.count) item\(expiring.count == 1 ? "" : "s") expiring soon")
            }
            if !lowStock.isEmpty {
                parts.append("📉 \(lowStock.count) running low")
            }
            content.title = "Daily Kitchen Brief"
            content.body  = parts.joined(separator: " · ")
        }
        content.userInfo = ["action": "openDailyBrief"]

        var comps        = DateComponents()
        comps.hour       = hour
        comps.minute     = minute
        let trigger      = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        let request      = UNNotificationRequest(identifier: requestID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancel() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [requestID])
    }

    // MARK: - Per-item expiry reminders (#9)

    func scheduleExpiryIfEnabled(store: GuestDataStore) {
        guard expiryRemindersEnabled else { cancelExpiry(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in self.scheduleExpiry(store: store) }
        }
    }

    // Schedules one reminder per item that expires in the future, firing the morning
    // (9 AM) of the day BEFORE its expiry. Old expiry requests are cleared first so the
    // set always reflects current inventory.
    func scheduleExpiry(store: GuestDataStore) {
        cancelExpiry()
        let cal = Calendar.current
        let now = Date()

        for item in store.inventoryItems {
            guard let exp = item.expirationDate, exp > now else { continue }
            // Fire 1 day before expiry at the user's chosen time (default 9 AM).
            guard let dayBefore = cal.date(byAdding: .day, value: -1, to: exp) else { continue }
            var comps = cal.dateComponents([.year, .month, .day], from: dayBefore)
            comps.hour = expiryHour
            comps.minute = expiryMinute
            guard let fireDate = cal.date(from: comps), fireDate > now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Expiring tomorrow"
            content.body  = "\(item.name.displayNormalized) expires tomorrow — cook or use it soon."
            content.sound = .default
            // #17 — rich actions + per-item deep link: tag the category and carry the item's
            // id + name so the delegate can run "Add to Grocery"/"Mark Used" and open this exact item.
            content.categoryIdentifier = StockedNotificationCategory.expiryItem
            content.userInfo = [
                StockedNotificationKey.action:   "openInventory",
                StockedNotificationKey.itemID:   item.id.uuidString,
                StockedNotificationKey.itemName: item.name
            ]
            // Time Sensitive: food about to spoil should break through Focus / Do Not Disturb.
            // Requires the com.apple.developer.usernotifications.time-sensitive entitlement.
            content.interruptionLevel = .timeSensitive

            let trigger = UNCalendarNotificationTrigger(
                dateMatching: cal.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                repeats: false)
            let request = UNNotificationRequest(
                identifier: expiryPrefix + item.id.uuidString, content: content, trigger: trigger)
            UNUserNotificationCenter.current().add(request)
        }
    }

    func cancelExpiry() {
        UNUserNotificationCenter.current().getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(self.expiryPrefix) }
            if !ids.isEmpty {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    func rescheduleExpiryIfNeeded(store: GuestDataStore) {
        guard expiryRemindersEnabled else { return }
        scheduleExpiry(store: store)
    }

    // MARK: - #13 "Use it up" cook suggestion

    func scheduleCookSuggestionIfEnabled(store: GuestDataStore) {
        guard cookSuggestionEnabled else { cancelCookSuggestion(); return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            Task { @MainActor in self.scheduleCookSuggestion(store: store) }
        }
    }

    /// Fires tomorrow at 4 PM (dinner-planning time) IF there are items expiring soon. Prefers a
    /// meal the user can make right now from those items; otherwise suggests one that uses them
    /// with a little shopping. Re-evaluated each time inventory changes.
    func scheduleCookSuggestion(store: GuestDataStore) {
        cancelCookSuggestion()
        let expiring = store.expiringSoonItems
        guard !expiring.isEmpty else { return }

        // Prefer a fully-makeable meal that uses expiring items; fall back to a "needs a little"
        // pick from recipesUsingExpiringItems.
        let readyPick = store.cookableRankedByExpiry().first { !$0.expiringUsed.isEmpty }
        let fallbackPick = store.recipesUsingExpiringItems(within: KitchenThresholds.expiringSoonDays, limit: 1).first

        let names = expiring.prefix(3).map { $0.name.displayNormalized }
        let itemList = names.count == 1 ? names[0]
                     : names.count == 2 ? "\(names[0]) and \(names[1])"
                     : "\(names.prefix(2).joined(separator: ", ")), and more"

        let content = UNMutableNotificationContent()
        if let ready = readyPick {
            content.title = "Cook tonight, waste nothing"
            content.body  = "Your \(itemList) \(expiring.count == 1 ? "is" : "are") expiring soon. You can make \(ready.recipe.title) right now to use \(ready.expiringUsed.count == 1 ? "it" : "them") up."
            content.userInfo = ["action": "openCookRightNow"]
        } else if let fb = fallbackPick {
            content.title = "Use it up before it's gone"
            content.body  = "\(itemList) \(expiring.count == 1 ? "is" : "are") expiring soon — \(fb.title) would put \(expiring.count == 1 ? "it" : "them") to use."
            content.userInfo = ["action": "openCookRightNow"]
        } else {
            content.title = "Expiring soon"
            content.body  = "\(itemList) \(expiring.count == 1 ? "is" : "are") expiring soon — try to use \(expiring.count == 1 ? "it" : "them") up."
            content.userInfo = ["action": "openInventory"]
        }
        content.sound = .default
        content.interruptionLevel = .timeSensitive

        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) else { return }
        var comps = cal.dateComponents([.year, .month, .day], from: tomorrow)
        comps.hour = cookHour; comps.minute = cookMinute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        let request = UNNotificationRequest(identifier: cookSuggestRequestID, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request)
    }

    func cancelCookSuggestion() {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [cookSuggestRequestID])
    }

    // Call this from MainTabView .onAppear or AppSession.init
    func rescheduleIfNeeded(store: GuestDataStore) {
        guard isEnabled else { return }
        schedule(store: store)
    }

    // MARK: - Staple nudge (#11) — fires tomorrow evening when kitchen stock is low

    private let stapleEnabledKey = "stapleNudgeEnabled"
    private let stapleRequestID  = "stocked_staple_nudge"

    var stapleNudgeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: stapleEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: stapleEnabledKey) }
    }

    func scheduleStapleNudgeIfEnabled(store: GuestDataStore) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [stapleRequestID])
        guard stapleNudgeEnabled, store.stockGoalsConfigured else { return }
        let pct = store.stockPercent
        guard pct < 50 else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your kitchen is running thin"
        content.body  = "You're at \(pct)% stocked. Tap to see which staples to pick up."
        content.sound = .default
        content.userInfo = ["action": "openGrocery"]

        // Tomorrow at the user's chosen time (default 5 PM) — evening, when a shopping run is plausible.
        let cal = Calendar.current
        guard let tomorrow = cal.date(byAdding: .day, value: 1, to: Date()) else { return }
        var comps = cal.dateComponents([.year, .month, .day], from: tomorrow)
        comps.hour = stapleHour; comps.minute = stapleMinute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: stapleRequestID, content: content, trigger: trigger))
    }

    // MARK: - Meal prep day reminder (#12) — weekly, on the profile's prep day

    private let prepEnabledKey = "prepReminderEnabled"
    private let prepRequestID  = "stocked_prep_reminder"

    var prepReminderEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: prepEnabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: prepEnabledKey) }
    }

    func scheduleMealPrepReminderIfEnabled(store: GuestDataStore) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [prepRequestID])
        guard prepReminderEnabled else { return }
        let dayName = store.cookingProfile.mealPrepDay
        let weekdays = ["Sunday": 1, "Monday": 2, "Tuesday": 3, "Wednesday": 4,
                        "Thursday": 5, "Friday": 6, "Saturday": 7]
        guard let weekday = weekdays[dayName] else { return }

        let content = UNMutableNotificationContent()
        content.title = "It's \(dayName) — meal prep day 🍳"
        content.body  = "Plan the week and build your grocery list while the kitchen's quiet."
        content.sound = .default
        content.userInfo = ["action": "openMealPlanner"]

        var comps = DateComponents()
        comps.weekday = weekday
        comps.hour = prepHour; comps.minute = prepMinute
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: prepRequestID, content: content, trigger: trigger))
    }

    /// One call at app launch refreshes every notification type against current data.
    func rescheduleAll(store: GuestDataStore) {
        rescheduleIfNeeded(store: store)
        rescheduleExpiryIfNeeded(store: store)
        scheduleStapleNudgeIfEnabled(store: store)
        scheduleMealPrepReminderIfEnabled(store: store)
        scheduleCookSuggestionIfEnabled(store: store)
    }

    var timeLabel: String {
        timeLabel(hour: hour, minute: minute)
    }

    /// Formats any hour (0–23) + minute as a 12-hour label, e.g. "7:30 AM". Used by the
    /// per-reminder time pickers in Settings.
    func timeLabel(hour h: Int, minute m: Int) -> String {
        let suffix = h < 12 ? "AM" : "PM"
        let h12    = h == 0 ? 12 : h > 12 ? h - 12 : h
        return String(format: "%d:%02d %@", h12, m, suffix)
    }
}
