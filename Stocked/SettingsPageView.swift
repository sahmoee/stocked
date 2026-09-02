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
    @Environment(\.stockedMotion) private var motion
    @AppStorage("stocked.qa.enabled") private var qaEnabled = false

    // ── Accordion state — one section open at a time ────────────────
    private enum SettingsSection: String, CaseIterable {
        case preferences, notifications, dataStorage, account, help
    }
    // Accordions start closed and remain mutually exclusive: opening one closes another.
    @State private var expanded: SettingsSection? = nil

    // ── Detail sheets — single item-driven presenter ────────────────
    private enum Sheet: Int, Identifiable {
        case storePopout, household, recipeSources, appIcon, dietaryProfile
        case transfer, notifications, dataStorage
        case helpCenter, editProfile
        case qa
        case catalogImport
        case appExperience
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
                    settingsSectionRow(icon: "sparkles.rectangle.stack", tint: Color.stockedGreen,
                                       title: "App Experience",
                                       subtitle: "Setup, activity, notifications, privacy, accessibility, and QA") {
                        activeSheet = .appExperience
                    }

                    VStack(spacing: 8) {
                        Toggle("Enable Stocked QA", isOn: $qaEnabled)
                            .tint(Color.stockedGold)
                        if qaEnabled {
                            settingsSectionRow(icon: "checklist", tint: Color.stockedCharcoal,
                                               title: "Open Stocked QA",
                                               subtitle: "Recipe imports, pantry, grocery, sync, tickets & reports") {
                                activeSheet = .qa
                            }
                        }
                        Text("Disabled by default. Enable only on builds being tested.")
                            .scaledFont(11).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Color.stockedWhite.opacity(0.08), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                    BuildInfoFooter()
                        .padding(.top, 10)
                    Color.clear.frame(height: 30)
                }
                .padding(.horizontal, 18).padding(.top, 12)
            }
        }
        .navigationTitle("Settings")
        .qaScreen("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(20)
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
            case .dietaryProfile: NavigationStack { DietaryProfileView().environment(session) }
            case .transfer:      KitchenTransferView().environment(session)
            case .notifications: NavigationStack { DailyBriefNotificationSettingsView().environment(session) }
            case .dataStorage:   DataStorageView().environment(session)
            case .helpCenter:    HelpCenterSheet().environment(session)
            case .editProfile:   EditProfileView().environment(session)
            case .qa:            StockedQAEntryView().environment(session)
            case .catalogImport:
                #if targetEnvironment(macCatalyst)
                RecipeCatalogImportView().environment(session)
                #else
                EmptyView()
                #endif
            case .appExperience:
                NavigationStack { AppExperienceCenterView().environment(session) }
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
                        Image(systemName: icon).scaledFont(15).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).scaledFont(16, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Text(subtitle).scaledFont(11.5)
                            .foregroundStyle(session.themeTextColor.opacity(0.45)).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").scaledFont(13, weight: .semibold)
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
                motion.animate(.standard, intent: .spatial) {
                    expanded = isOpen ? nil : section
                }
                HapticManager.light()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9).fill(tint).frame(width: 34, height: 34)
                        Image(systemName: icon).scaledFont(15).foregroundStyle(.white)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .scaledFont(16, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        if !isOpen {
                            Text(subtitle)
                                .scaledFont(11.5)
                                .foregroundStyle(session.themeTextColor.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .scaledFont(13, weight: .semibold)
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
        PreferencesSectionView(
            onPreferredStore: { activeSheet = .storePopout },
            onRecipeSources: { activeSheet = .recipeSources },
            onAppIcon: { activeSheet = .appIcon },
            onDietaryProfile: { activeSheet = .dietaryProfile }
        )
    }

    // MARK: - Notifications

    @ViewBuilder private var notificationsContent: some View {
        NotificationsSectionView(onNotificationSettings: { activeSheet = .notifications })
    }

    // MARK: - Data & Storage

    @ViewBuilder private var dataStorageContent: some View {
        DataStorageSectionView(
            onTransferKitchen: { activeSheet = .transfer },
            onDataStorage: { activeSheet = .dataStorage },
            onCatalogImport: { activeSheet = .catalogImport },
            onEraseAllData: { showClearAlert = true }
        )
    }

    // MARK: - Account

    @ViewBuilder private var accountContent: some View {
        AccountSectionView(
            onEditProfile: { activeSheet = .editProfile },
            onLogOut: { showLogoutConfirm = true },
            onDeleteAccount: { showDeleteAccountAlert = true }
        )
    }

    // MARK: - Help

    @ViewBuilder private var helpContent: some View {
        HelpSectionView(
            onHelpCenter: { activeSheet = .helpCenter },
            onContactSupport: { if let u = supportMailtoURL { openURL(u) } },
            onPrivacyPolicy: { if let u = URL(string: BuildConfig.privacyURL) { openURL(u) } },
            onTermsOfService: { if let u = URL(string: BuildConfig.termsURL) { openURL(u) } },
            onWebsite: { if let u = URL(string: BuildConfig.websiteURL) { openURL(u) } }
        )
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
                    Image(systemName: icon).scaledFont(13).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).scaledFont(14, design: .serif).foregroundStyle(session.themeTextColor)
                    if !detail.isEmpty {
                        Text(detail).scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").scaledFont(11)
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
                .scaledFont(13, weight: .semibold)
                .foregroundStyle(active ? Color.stockedBlack : session.themeTextColor.opacity(0.7))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(active ? Color.stockedGold : session.themeTextColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
        }.buttonStyle(.plain)
    }
}
