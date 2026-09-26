// DailyBriefNotificationSettingsView.swift
import SwiftUI
import UserNotifications

struct DailyBriefNotificationSettingsView: View {
    @Environment(AppSession.self) var session
    @Environment(\.scenePhase) private var scenePhase
    @State private var isEnabled = DailyBriefNotificationManager.shared.isEnabled
    @State private var hour      = DailyBriefNotificationManager.shared.hour
    @State private var minute    = DailyBriefNotificationManager.shared.minute
    @State private var expiryOn  = DailyBriefNotificationManager.shared.expiryRemindersEnabled
    @State private var cookSuggestOn = DailyBriefNotificationManager.shared.cookSuggestionEnabled
    @State private var stapleOn  = DailyBriefNotificationManager.shared.stapleNudgeEnabled
    @State private var prepOn    = DailyBriefNotificationManager.shared.prepReminderEnabled
    @State private var scheduled = false
    @State private var saveFeedbackTask: Task<Void, Never>?

    // Per-reminder fire times (defaults come from the manager's stored values).
    @State private var expiryHour   = DailyBriefNotificationManager.shared.expiryHour
    @State private var expiryMinute = DailyBriefNotificationManager.shared.expiryMinute
    @State private var cookHour     = DailyBriefNotificationManager.shared.cookHour
    @State private var cookMinute   = DailyBriefNotificationManager.shared.cookMinute
    @State private var stapleHour   = DailyBriefNotificationManager.shared.stapleHour
    @State private var stapleMinute = DailyBriefNotificationManager.shared.stapleMinute
    @State private var prepHour     = DailyBriefNotificationManager.shared.prepHour
    @State private var prepMinute   = DailyBriefNotificationManager.shared.prepMinute

    // System authorization status, so we can show Allowed / Denied and a fix path.
    @State private var authStatus: UNAuthorizationStatus = .notDetermined

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text("Daily Brief Alerts")
                    .scaledFont(22, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 4)
                Text("A morning notification summarising expiring items and what you can cook tonight.")
                    .scaledFont(13).foregroundStyle(session.themeSecondaryText)
                    .padding(.horizontal, 20).padding(.bottom, 16)

                permissionBanner

                VStack(spacing: 0) {
                    // Enable toggle
                    HStack {
                        Text("Enable daily brief")
                            .scaledFont(15, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Spacer()
                        Toggle("Daily kitchen brief", isOn: $isEnabled).labelsHidden()
                            .tint(session.accentColor)
                            .onChange(of: isEnabled) { _, v in
                                DailyBriefNotificationManager.shared.isEnabled = v
                                if v {
                                    ensureAuthThen {
                                        DailyBriefNotificationManager.shared.scheduleIfEnabled(store: session.guestStore)
                                    }
                                } else {
                                    DailyBriefNotificationManager.shared.cancel()
                                }
                            }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))

                    if isEnabled {
                        Divider().padding(.leading, 20)

                        timeRow(label: "Notify at", hour: $hour, minute: $minute, onChange: save)

                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)

                if scheduled {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedSuccessInk)
                        Text("Reminder preference saved for \(DailyBriefNotificationManager.shared.timeLabel)")
                            .scaledFont(13).foregroundStyle(session.themeSecondaryText)
                    }
                    .padding(.horizontal, 24).padding(.top, 16)
                    .transition(.opacity)
                }

                // #9 — Per-item expiry reminders
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Expiry reminders")
                                .scaledFont(15, design: .serif)
                                .foregroundStyle(session.themeTextColor)
                            Text("Get a reminder the day before an item expires")
                                .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                        }
                        Spacer()
                        Toggle("Expiry reminders", isOn: $expiryOn).labelsHidden()
                            .tint(session.accentColor)
                            .onChange(of: expiryOn) { _, v in
                                DailyBriefNotificationManager.shared.expiryRemindersEnabled = v
                                if v {
                                    ensureAuthThen {
                                        DailyBriefNotificationManager.shared.scheduleExpiryIfEnabled(store: session.guestStore)
                                    }
                                } else {
                                    DailyBriefNotificationManager.shared.cancelExpiry()
                                }
                            }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))

                    if expiryOn {
                        Divider().padding(.leading, 20)
                        timeRow(label: "Remind me at", hour: $expiryHour, minute: $expiryMinute) {
                            DailyBriefNotificationManager.shared.expiryHour   = expiryHour
                            DailyBriefNotificationManager.shared.expiryMinute = expiryMinute
                            DailyBriefNotificationManager.shared.scheduleExpiryIfEnabled(store: session.guestStore)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20).padding(.top, 20)

                // #13 — "use it up" cook suggestion
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Cook suggestions")
                                .scaledFont(15, design: .serif)
                                .foregroundStyle(session.themeTextColor)
                            Text("When items are expiring, suggest a recipe that uses them up")
                                .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                        }
                        Spacer()
                        Toggle("Cook suggestions", isOn: $cookSuggestOn).labelsHidden()
                            .tint(session.accentColor)
                            .onChange(of: cookSuggestOn) { _, v in
                                DailyBriefNotificationManager.shared.cookSuggestionEnabled = v
                                if v {
                                    ensureAuthThen {
                                        DailyBriefNotificationManager.shared.scheduleCookSuggestionIfEnabled(store: session.guestStore)
                                    }
                                } else {
                                    DailyBriefNotificationManager.shared.cancelCookSuggestion()
                                }
                            }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))

                    if cookSuggestOn {
                        Divider().padding(.leading, 20)
                        timeRow(label: "Suggest at", hour: $cookHour, minute: $cookMinute) {
                            DailyBriefNotificationManager.shared.cookHour   = cookHour
                            DailyBriefNotificationManager.shared.cookMinute = cookMinute
                            DailyBriefNotificationManager.shared.scheduleCookSuggestionIfEnabled(store: session.guestStore)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20).padding(.top, 12)
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Low staples nudge")
                                .scaledFont(15, design: .serif)
                                .foregroundStyle(session.themeTextColor)
                            Text("A heads-up when your kitchen drops below 50% stocked")
                                .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                        }
                        Spacer()
                        Toggle("Low staples nudge", isOn: $stapleOn).labelsHidden()
                            .tint(session.accentColor)
                            .onChange(of: stapleOn) { _, v in
                                DailyBriefNotificationManager.shared.stapleNudgeEnabled = v
                                if v {
                                    ensureAuthThen {
                                        DailyBriefNotificationManager.shared.scheduleStapleNudgeIfEnabled(store: session.guestStore)
                                    }
                                } else {
                                    DailyBriefNotificationManager.shared.scheduleStapleNudgeIfEnabled(store: session.guestStore)
                                }
                            }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))

                    if stapleOn {
                        Divider().padding(.leading, 20)
                        timeRow(label: "Notify at", hour: $stapleHour, minute: $stapleMinute) {
                            DailyBriefNotificationManager.shared.stapleHour   = stapleHour
                            DailyBriefNotificationManager.shared.stapleMinute = stapleMinute
                            DailyBriefNotificationManager.shared.scheduleStapleNudgeIfEnabled(store: session.guestStore)
                        }
                    }

                    Divider().padding(.leading, 20)

                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Meal prep day reminder")
                                .scaledFont(15, design: .serif)
                                .foregroundStyle(session.themeTextColor)
                            Text("Every \(session.guestStore.cookingProfile.mealPrepDay) at \(DailyBriefNotificationManager.shared.timeLabel(hour: prepHour, minute: prepMinute))")
                                .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                        }
                        Spacer()
                        Toggle("Meal prep reminder", isOn: $prepOn).labelsHidden()
                            .tint(session.accentColor)
                            .onChange(of: prepOn) { _, v in
                                DailyBriefNotificationManager.shared.prepReminderEnabled = v
                                if v {
                                    ensureAuthThen {
                                        DailyBriefNotificationManager.shared.scheduleMealPrepReminderIfEnabled(store: session.guestStore)
                                    }
                                } else {
                                    DailyBriefNotificationManager.shared.scheduleMealPrepReminderIfEnabled(store: session.guestStore)
                                }
                            }
                    }
                    .padding(.horizontal, 20).padding(.vertical, 14)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))

                    if prepOn {
                        Divider().padding(.leading, 20)
                        timeRow(label: "Remind me at", hour: $prepHour, minute: $prepMinute) {
                            DailyBriefNotificationManager.shared.prepHour   = prepHour
                            DailyBriefNotificationManager.shared.prepMinute = prepMinute
                            DailyBriefNotificationManager.shared.scheduleMealPrepReminderIfEnabled(store: session.guestStore)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20).padding(.top, 20)

            }
            .padding(.bottom, 20)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshAuthStatus() }
        .onDisappear { saveFeedbackTask?.cancel(); saveFeedbackTask = nil }
        .onChange(of: scenePhase) { _, phase in
            // Coming back from the Settings app (where the user may have toggled permission)
            // should refresh the Allowed / Denied banner.
            if phase == .active { refreshAuthStatus() }
        }
    }

    // MARK: - Permission banner

    @ViewBuilder
    private var permissionBanner: some View {
        switch authStatus {
        case .denied:
            HStack(spacing: 10) {
                Image(systemName: "bell.slash.fill")
                    .foregroundStyle(Color.stockedErrorInk)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications are turned off")
                        .scaledFont(14, weight: .semibold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text("Reminders can't be delivered until you allow notifications in Settings.")
                        .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                }
                Spacer()
                Button("Open Settings") { openSystemSettings() }
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(session.accentColor)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.red.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20).padding(.bottom, 16)

        case .authorized, .provisional, .ephemeral:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedSuccessInk)
                Text("Notifications are allowed. Focus settings and notification summaries can affect delivery.")
                    .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                Spacer()
            }
            .padding(.horizontal, 24).padding(.bottom, 16)

        case .notDetermined:
            EmptyView()

        @unknown default:
            EmptyView()
        }
    }

    // MARK: - Reusable inline time row

    private func timeRow(label: String, hour: Binding<Int>, minute: Binding<Int>,
                         onChange: @escaping () -> Void) -> some View {
        DatePicker(label, selection: Binding(get: {
            Calendar.current.date(from: DateComponents(year: 2001, month: 1, day: 1,
                hour: ReminderClockPolicy.hour(hour.wrappedValue),
                minute: ReminderClockPolicy.minute(minute.wrappedValue))) ?? .now
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            hour.wrappedValue = ReminderClockPolicy.hour(parts.hour)
            minute.wrappedValue = ReminderClockPolicy.minute(parts.minute)
            onChange()
        }), displayedComponents: .hourAndMinute)
        .datePickerStyle(.compact)
        .scaledFont(15, design: .serif)
        .tint(session.accentColor)
        .foregroundStyle(session.themeTextColor)
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(session.themeCardColor)
    }

    // MARK: - Authorization helpers

    /// Requests permission if needed, then runs the scheduling work and refreshes the banner.
    private func ensureAuthThen(_ schedule: @escaping () -> Void) {
        DailyBriefNotificationManager.shared.requestAuthorization { _ in
            schedule()
            refreshAuthStatus()
        }
    }

    private func refreshAuthStatus() {
        DailyBriefNotificationManager.shared.authorizationStatus { status in
            authStatus = status
        }
    }

    private func openSystemSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
    }

    private func save() {
        DailyBriefNotificationManager.shared.hour   = hour
        DailyBriefNotificationManager.shared.minute = minute
        DailyBriefNotificationManager.shared.scheduleIfEnabled(store: session.guestStore)
        refreshAuthStatus()
        scheduled = true
        saveFeedbackTask?.cancel()
        saveFeedbackTask = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            scheduled = false
        }
    }
}
