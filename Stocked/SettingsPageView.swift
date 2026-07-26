// SettingsPageView.swift — the redesigned, full-page Settings home.
//
// Everything settings-shaped moved here from the drawer: Preferences, Notifications,
// Data & Storage, Account (Log Out + Delete Account), and Help & Support, each an
// accordion card — tap a header to expand it (one open at a time), controls live
// inline, detail screens open in sheets. The drawer keeps tools and insights only,
// plus a single Settings row that opens this page.
//
// Sheet discipline: ONE .sheet(item:) with an Identifiable enum for every detail
// screen — never Bool+optional — so each opens correctly on the FIRST tap.
import SwiftUI
import UIKit

struct SettingsPageView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    // ── Accordion state — one section open at a time ────────────────
    private enum SettingsSection: String, CaseIterable {
        case preferences, notifications, dataStorage, account, help
    }
    // Accordions start closed and remain mutually exclusive: opening one closes another.
    @State private var expanded: SettingsSection? = nil

    // ── Detail sheets — single item-driven presenter ────────────────
    private enum Sheet: Int, Identifiable {
        case storePopout, household, recipeSources, appIcon
        case transfer, notifications, dataStorage
        case helpCenter, editProfile
        case qa
        var id: Int { rawValue }
    }
    @State private var activeSheet: Sheet? = nil

    // ── Destructive confirmations ───────────────────────────────────
    @State private var showClearAlert = false
    @State private var showDeleteAccountAlert = false
    @State private var showLogoutConfirm = false

    // ── Hidden QA unlock ────────────────────────────────────────────

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    accordion(.preferences, icon: "slider.horizontal.3", tint: Color.stockedInfo,
                              title: "Preferences", subtitle: "Appearance, units, cook buttons, sources") {
                        preferencesContent
                    }
                    accordion(.notifications, icon: "bell.fill", tint: Color.stockedGold,
                              title: "Notifications", subtitle: "Reminders and the Daily Brief") {
                        notificationsContent
                    }
                    settingsSectionRow(icon: "person.2.fill", tint: Color.stockedInfo,
                                       title: "Household",
                                       subtitle: session.householdCode.isEmpty ? "Share your pantry with family" : "Sharing · Code \(session.householdCode)") {
                        activeSheet = .household
                    }
                    accordion(.dataStorage, icon: "internaldrive.fill", tint: Color.stockedCharcoal,
                              title: "Data & Storage", subtitle: "Backups, transfer, and erasing") {
                        dataStorageContent
                    }
                    accordion(.account, icon: "person.crop.circle", tint: Color.stockedGreen,
                              title: "Account", subtitle: accountSubtitle) {
                        accountContent
                    }
                    accordion(.help, icon: "questionmark.circle.fill", tint: Color.stockedGold,
                              title: "Help & Support", subtitle: "Guides and getting unstuck") {
                        helpContent
                    }

                    // QA — code-gated release checklist (Checkbook v4.13.69) with the
                    // Worker bridge to the StockedQA companion app. Deliberately last.
                    settingsSectionRow(icon: "checklist", tint: Color.stockedCharcoal,
                                       title: "QA",
                                       subtitle: "Release checklist · testers only") {
                        activeSheet = .qa
                    }

                    BuildInfoFooter()
                        .padding(.top, 10)
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 18).padding(.top, 12)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }
                .a11yButton("Close settings")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .storePopout:   PreferredStorePopout().environment(session)
            case .household:     HouseholdHomeView().environment(session)
            case .recipeSources: RecipeSourcesManagerView().environment(session)
            case .appIcon:       NavigationStack { AppIconPickerView().environment(session) }
            case .transfer:      KitchenTransferView().environment(session)
            case .notifications: NavigationStack { DailyBriefNotificationSettingsView().environment(session) }
            case .dataStorage:   DataStorageView().environment(session)
            case .helpCenter:    HelpCenterSheet().environment(session)
            case .editProfile:   EditProfileView().environment(session)
            case .qa:            StockedQAGateView().environment(session)
            }
        }
        .alert("Erase All Data?", isPresented: $showClearAlert) {
            Button("Erase Everything", role: .destructive) { session.signOut(clearData: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Permanently deletes your pantry, grocery list, meal history, recipes, and settings from this device AND removes every Stocked backup from iCloud. You'll go through setup again next time. Cannot be undone.")
        }
        .alert("Delete Account?", isPresented: $showDeleteAccountAlert) {
            Button("Delete Account", role: .destructive) { session.deleteAccount() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your account and all associated data, including your pantry, grocery list, meal history, saved recipes, settings, iCloud backup, and any shared household. This cannot be undone.")
        }
        .alert(session.accountType == .guest ? "Exit Guest Mode?" : "Log Out?", isPresented: $showLogoutConfirm) {
            if session.accountType == .guest {
                Button("Keep Data") { session.signOut(clearData: false) }
                Button("Erase & Exit", role: .destructive) { session.signOut(clearData: true) }
            } else {
                Button("Log Out") { session.signOut(clearData: false) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var accountSubtitle: String {
        session.accountType == .guest ? "Guest · \(session.userName)" : "Member · \(session.userName)"
    }

    // MARK: - Accordion card

    @ViewBuilder
    // A top-level settings entry that looks like the accordion headers but opens a sheet
    // directly instead of expanding inline. Used for Household, which has its own full screen.
    // Uses AnyView to sidestep opaque-return-type inference (the -> some View form was
    // failing to infer here). Functionally identical; AnyView just erases the concrete type.
    private func settingsSectionRow(icon: String, tint: Color, title: String, subtitle: String,
                                    action: @escaping () -> Void) -> AnyView {
        AnyView(
            Button(action: action) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(tint).frame(width: 34, height: 34)
                        Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 16, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text(subtitle).font(.system(size: 11.5))
                            .foregroundStyle(session.themeTextColor.opacity(0.45)).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(session.themeCardColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(session.accentColor.opacity(session.isDarkMode ? 0.12 : 0.08), lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        )
    }

    private func accordion<Content: View>(_ section: SettingsSection, icon: String, tint: Color,
                                          title: String, subtitle: String,
                                          @ViewBuilder content: () -> Content) -> some View {
        let isOpen = expanded == section
        // Explicit return required: implicit return only applies to single-expression
        // bodies, and the let above makes this a multi-statement body. Without it the
        // compiler reports no return statements and discards the VStack (the unused
        // background(_:alignment:) warning).
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                    expanded = isOpen ? nil : section
                }
                HapticManager.light()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(tint).frame(width: 34, height: 34)
                        Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .font(.system(size: 16, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        if !isOpen {
                            Text(subtitle)
                                .font(.system(size: 11.5))
                                .foregroundStyle(session.themeTextColor.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11yButton(title, hint: isOpen ? "Collapse" : "Expand")

            if isOpen {
                Divider().padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 16) {
                    content()
                }
                .padding(16)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(session.themeCardColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(session.accentColor.opacity(session.isDarkMode ? 0.12 : 0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Preferences

    @ViewBuilder private var preferencesContent: some View {
        Toggle(isOn: Binding(get: { session.isDarkMode }, set: { session.isDarkMode = $0 })) {
            Label("Dark Mode", systemImage: "moon.fill")
                .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
        }.tint(Color.stockedGold)

        VStack(alignment: .leading, spacing: 8) {
            Label("Measurements", systemImage: "ruler")
                .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
            HStack(spacing: 8) {
                ForEach(UnitSystem.allCases, id: \.self) { sys in
                    themeButton(sys.label, active: session.unitSystem == sys) {
                        withAnimation(.spring(response: 0.25)) { session.unitSystem = sys }
                    }
                }
            }
        }

        RecipeTextSizeControl()

        VStack(alignment: .leading, spacing: 8) {
            Label("Cook Buttons", systemImage: "circle.grid.2x1.fill")
                .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
            Text("Shape picks the Cook page look (Circle, Pill rows, Rounded photo cards); size scales it — updates live")
                .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
            HStack(spacing: 6) {
                ForEach(CookButtonShape.allCases, id: \.self) { shape in
                    themeButton(shape.rawValue, active: session.cookButtonShape == shape) {
                        withAnimation(.spring(response: 0.25)) { session.cookButtonShape = shape }
                    }
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "minus.magnifyingglass")
                    .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.4))
                Slider(value: Binding(get: { session.cookButtonSize },
                                      set: { session.cookButtonSize = $0 }),
                       in: 150...400, step: 10)
                    .tint(Color.stockedGold)
                Image(systemName: "plus.magnifyingglass")
                    .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.4))
            }
        }

        Toggle(isOn: Binding(
            get: { UserDefaults.standard.bool(forKey: "crowdShareEnabled") },
            set: { UserDefaults.standard.set($0, forKey: "crowdShareEnabled") }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Improve Stocked for Everyone", systemImage: "person.3.fill")
                    .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                Text("Share anonymized item facts (name, unit, container, quantity) — never your identity, account, or location")
                    .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
            }
        }.tint(Color.stockedGold)

        Button { activeSheet = .storePopout } label: {
            HStack {
                Label("Preferred Store", systemImage: "storefront")
                    .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                Spacer()
                Text(session.preferredStore).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.stockedGold)
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.35))
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)

        Toggle(isOn: Binding(get: { session.autoAddMissingToGrocery }, set: { session.autoAddMissingToGrocery = $0 })) {
            Label("Auto-Add Missing to Grocery", systemImage: "cart.badge.plus")
                .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
        }.tint(Color.stockedGold)

        VStack(alignment: .leading, spacing: 8) {
            Label("Auto Backup", systemImage: "clock.arrow.2.circlepath")
                .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
            HStack(spacing: 6) {
                ForEach(BackupFrequency.allCases, id: \.self) { freq in
                    themeButton(freq.rawValue, active: session.backupFrequency == freq) {
                        session.backupFrequency = freq
                    }
                }
            }
        }

        settingsButton(icon: "globe", color: Color.stockedGold,
                       title: "Recipe Sources", detail: "Add websites or manage sources") {
            activeSheet = .recipeSources
        }
        settingsButton(icon: "app.badge", color: Color.stockedGold,
                       title: "App Icon", detail: "Choose an alternate Home Screen icon") {
            activeSheet = .appIcon
        }

        if HealthKitManager.shared.isAvailable {
            Toggle(isOn: Binding(
                get: { HealthKitManager.shared.isEnabled },
                set: { HealthKitManager.shared.isEnabled = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Apple Health", systemImage: "heart.fill")
                        .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                    Text("Log cooked-meal nutrition to Health")
                        .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
                }
            }.tint(Color.stockedGold)
        }
    }

    // MARK: - Notifications

    @ViewBuilder private var notificationsContent: some View {
        Toggle(isOn: Binding(get: { session.notificationsEnabled }, set: { session.notificationsEnabled = $0 })) {
            Label("Low Stock Reminders", systemImage: "exclamationmark.bubble.fill")
                .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
        }.tint(Color.stockedGold)

        settingsButton(icon: "bell.badge.fill", color: Color.stockedGold,
                       title: "Reminders & Daily Brief",
                       detail: "Schedule expiry, cook & prep reminders") {
            activeSheet = .notifications
        }
    }

    // MARK: - Data & Storage

    @ViewBuilder private var dataStorageContent: some View {
        settingsButton(icon: "arrow.left.arrow.right.square.fill", color: Color.stockedGold,
                       title: "Transfer Kitchen", detail: "Export or import data") {
            activeSheet = .transfer
        }
        settingsButton(icon: "icloud.fill", color: Color.stockedInfo,
                       title: "Backup to iCloud",
                       detail: "Last backup: \(session.transferManager.lastBackupDate)") {
            session.transferManager.backupToiCloud(store: session.guestStore)
        }
        if !session.transferManager.errorMessage.isEmpty {
            Label(session.transferManager.errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(.red)
        } else if !session.transferManager.statusMessage.isEmpty {
            Label(session.transferManager.statusMessage, systemImage: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(Color.stockedGreen)
        }
        settingsButton(icon: "internaldrive", color: Color.stockedCharcoal,
                       title: "Storage & Auto Backup",
                       detail: "Usage, migration · Backs up \(session.backupFrequency.rawValue.lowercased())") {
            activeSheet = .dataStorage
        }
        // Improvement #20 — one screen over the Worker, crash/hang history, sync conflicts, cache
        // and storage. Also the only route to SyncDiagnosticsView, which was built and never linked.
        NavigationLink {
            StockedHealthView()
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.stockedGreen).frame(width: 28, height: 28)
                    Image(systemName: "waveform.path.ecg").font(.system(size: 13)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("App Health").font(.system(size: 14, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Server, stability, sync and cache")
                        .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
        }
        .buttonStyle(.plain)
        Button { showClearAlert = true } label: {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(Color.red).frame(width: 28, height: 28)
                    Image(systemName: "trash.fill").font(.system(size: 13)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Erase All Data").font(.system(size: 14, design: .serif)).foregroundStyle(.red)
                    Text("This device and iCloud").font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }.buttonStyle(.plain)
    }

    // MARK: - Account

    @ViewBuilder private var accountContent: some View {
        settingsButton(icon: "person.crop.circle.badge.checkmark", color: Color.stockedGreen,
                       title: "Edit Profile", detail: "Name, avatar, and account details") {
            activeSheet = .editProfile
        }
        settingsButton(icon: "rectangle.portrait.and.arrow.right", color: Color.stockedGold,
                       title: session.accountType == .guest ? "Exit Guest Mode" : "Log Out",
                       detail: session.accountType == .guest ? "Leave guest mode" : "Sign out of this device") {
            showLogoutConfirm = true
        }
        if session.accountType != .guest {
            settingsButton(icon: "person.crop.circle.badge.xmark", color: .red,
                           title: "Delete Account", detail: "Permanently delete your account") {
                showDeleteAccountAlert = true
            }
        }
    }

    // MARK: - Help

    @ViewBuilder private var helpContent: some View {
        settingsButton(icon: "questionmark.circle", color: Color.stockedGold,
                       title: "Help Center", detail: "Guides for every part of Stocked") {
            activeSheet = .helpCenter
        }
        settingsButton(icon: "envelope.fill", color: Color.stockedInfo,
                       title: "Contact Support", detail: BuildConfig.supportEmail) {
            if let u = supportMailtoURL { openURL(u) }
        }
        settingsButton(icon: "lock.shield.fill", color: Color.stockedGreen,
                       title: "Privacy Policy", detail: "How your data is handled") {
            if let u = URL(string: BuildConfig.privacyURL) { openURL(u) }
        }
        settingsButton(icon: "doc.text.fill", color: Color.stockedCharcoal,
                       title: "Terms of Service", detail: "The rules for using Stocked") {
            if let u = URL(string: BuildConfig.termsURL) { openURL(u) }
        }
        settingsButton(icon: "globe", color: Color.stockedGold,
                       title: "Website", detail: "sowensstudios.com") {
            if let u = URL(string: BuildConfig.websiteURL) { openURL(u) }
        }
    }

    /// Pre-filled support email with app version + device context (no personal data).
    private var supportMailtoURL: URL? {
        let subject = "Stocked Support — \(BuildConfig.displayLabel)"
        let body = "\n\n\n—\nApp: Stocked \(BuildConfig.version) (\(BuildConfig.buildNumber))"
            + "\nDevice: \(UIDevice.current.model)"
            + "\niOS: \(UIDevice.current.systemVersion)"
        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = BuildConfig.supportEmail
        comps.queryItems = [URLQueryItem(name: "subject", value: subject),
                            URLQueryItem(name: "body", value: body)]
        return comps.url
    }

    // MARK: - Row helpers (mirrors the drawer's settingsRow visual language)

    private func settingsButton(icon: String, color: Color, title: String, detail: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7).fill(color).frame(width: 28, height: 28)
                    Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                    if !detail.isEmpty {
                        Text(detail).font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11))
                    .foregroundStyle(session.themeTextColor.opacity(0.25))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .a11yButton(title, hint: detail)
    }

    private func themeButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(active ? Color.stockedBlack : session.themeTextColor.opacity(0.7))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(active ? Color.stockedGold : session.themeTextColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
        }.buttonStyle(.plain)
    }
}
