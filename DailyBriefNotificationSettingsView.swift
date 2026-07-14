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
            VStack(alignment: .leading, spacing: 0) {
                Text("Daily Brief Alerts")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 4)
                Text("A morning notification summarising expiring items and what you can cook tonight.")
                    .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.horizontal, 24).padding(.bottom, 24)

                permissionBanner

                VStack(spacing: 0) {
                    // Enable toggle
                    HStack {
                        Text("Enable daily brief")
                            .font(.system(size: 15, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Spacer()
                        Toggle("", isOn: $isEnabled)
                            .tint(Color.stockedGold)
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

                        // Time picker
                        HStack {
                            Text("Notify at")
                                .font(.system(size: 15, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            Spacer()
                            Picker("Hour", selection: $hour) {
                                ForEach(0..<24, id: \.self) { h in
                                    let suffix = h < 12 ? "AM" : "PM"
                                    let h12    = h == 0 ? 12 : h > 12 ? h - 12 : h
                                    Text("\(h12) \(suffix)").tag(h)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(Color.stockedGold)
                            Text(":")
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                            Picker("Minute", selection: $minute) {
                                ForEach([0, 15, 30, 45], id: \.self) { m in
                                    Text(String(format: "%02d", m)).tag(m)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(Color.stockedGold)
                        }
                        .padding(.horizontal, 20).padding(.vertical, 14)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                        .onChange(of: hour) { _, _ in save() }
                        .onChange(of: minute) { _, _ in save() }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 20)

                if scheduled {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedGreen)
                        Text("Daily brief scheduled for \(DailyBriefNotificationManager.shared.timeLabel)")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.6))
                    }
                    .padding(.horizontal, 24).padding(.top, 16)
                    .transition(.opacity)
                }

                // #9 — Per-item expiry reminders
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Expiry reminders")
                                .font(.system(size: 15, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            Text("Get a reminder the day before an item expires")
                                .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                        Spacer()
                        Toggle("", isOn: $expiryOn)
                            .tint(Color.stockedGold)
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
                                .font(.system(size: 15, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            Text("When items are expiring, suggest a recipe that uses them up")
                                .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                        Spacer()
                        Toggle("", isOn: $cookSuggestOn)
                            .tint(Color.stockedGold)
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
                                .font(.system(size: 15, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            Text("A heads-up when your kitchen drops below 50% stocked")
                                .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                        Spacer()
                        Toggle("", isOn: $stapleOn)
                            .tint(Color.stockedGold)
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
                                .font(.system(size: 15, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            Text("Every \(session.guestStore.cookingProfile.mealPrepDay) at \(DailyBriefNotificationManager.shared.timeLabel(hour: prepHour, minute: prepMinute))")
                                .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                        Spacer()
                        Toggle("", isOn: $prepOn)
                            .tint(Color.stockedGold)
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

                Spacer()
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { refreshAuthStatus() }
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
                    .foregroundStyle(Color.red)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notifications are turned off")
                        .font(.system(size: 14, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Reminders can't be delivered until you allow notifications in Settings.")
                        .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.6))
                }
                Spacer()
                Button("Open") { openSystemSettings() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.stockedGold)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Color.red.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal, 20).padding(.bottom, 16)

        case .authorized, .provisional, .ephemeral:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.stockedGreen)
                Text("Notifications allowed — reminders will arrive even when the app is closed.")
                    .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.6))
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

    @ViewBuilder
    private func timeRow(label: String, hour: Binding<Int>, minute: Binding<Int>,
                         onChange: @escaping () -> Void) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 15, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Spacer()
            Picker("Hour", selection: hour) {
                ForEach(0..<24, id: \.self) { h in
                    let suffix = h < 12 ? "AM" : "PM"
                    let h12    = h == 0 ? 12 : h > 12 ? h - 12 : h
                    Text("\(h12) \(suffix)").tag(h)
                }
            }
            .pickerStyle(.menu)
            .tint(Color.stockedGold)
            Text(":").foregroundStyle(session.themeTextColor.opacity(0.5))
            Picker("Minute", selection: minute) {
                ForEach([0, 15, 30, 45], id: \.self) { m in
                    Text(String(format: "%02d", m)).tag(m)
                }
            }
            .pickerStyle(.menu)
            .tint(Color.stockedGold)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
        .onChange(of: hour.wrappedValue) { _, _ in onChange() }
        .onChange(of: minute.wrappedValue) { _, _ in onChange() }
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
        withAnimation { scheduled = true }
        Task {
            try? await Task.sleep(nanoseconds: 2000000000)
            withAnimation { scheduled = false }
        }
    }
}
