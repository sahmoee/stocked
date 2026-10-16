// Shared settings home for the swipeable drawer and iPad presentation.
// Section controls keep their existing owners; one item-driven presenter opens details.
import SwiftUI
import UIKit

struct SettingsPageView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.stockedMotion) private var motion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("stocked.qa.enabled") private var qaEnabled = false

    var onClose: (() -> Void)? = nil
    var onBack: (() -> Void)? = nil

    // ── Accordion state — one section open at a time ────────────────
    private enum SettingsSection: String, CaseIterable {
        case appearance, cooking, kitchen, interaction, notifications, dataStorage, account, help, testing
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
        var id: Int { rawValue }
    }
    @State private var activeSheet: Sheet? = nil

    // ── Destructive confirmations ───────────────────────────────────
    @State private var showClearAlert = false
    @State private var showDeleteAccountAlert = false
    @State private var showLogoutConfirm = false

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 12) {
                    profileCard
                    sectionHeading("MAKE IT YOURS", detail: "A kitchen that feels like you.")
                    accordion(.appearance, icon: "paintpalette.fill", tint: session.accentColor,
                              title: "Appearance", subtitle: "Theme, app icon & optional text settings") {
                        preferencesContent(.appearance)
                    }
                    accordion(.interaction, icon: "hand.tap.fill", tint: Color.stockedInfo,
                              title: "Touch & Feedback", subtitle: "Haptics and interaction") {
                        preferencesContent(.interaction)
                    }
                    sectionHeading("YOUR KITCHEN", detail: "Small defaults. Smoother everyday cooking.")
                    accordion(.cooking, icon: "fork.knife", tint: Color.stockedGreen,
                              title: "Cooking & Diet", subtitle: "Servings, measurements & dietary profile") {
                        preferencesContent(.cooking)
                    }
                    accordion(.kitchen, icon: "basket.fill", tint: session.accentColor,
                              title: "Shopping & Sources", subtitle: "Your store, recipe sources & grocery defaults") {
                        preferencesContent(.kitchen)
                    }
                    accordion(.notifications, icon: "bell.fill", tint: session.accentColor,
                              title: "Notifications", subtitle: "Reminders and the Daily Brief") {
                        notificationsContent
                    }
                    sectionHeading("KEEP IT CONNECTED", detail: "Your people, your kitchen, safely together.")
                    settingsSectionRow(icon: "person.2.fill", tint: Color.stockedInfo,
                                       title: "Household",
                                       subtitle: session.householdCode.isEmpty ? "Share your pantry with family" : "Sharing · Code \(session.householdCode)") {
                        activeSheet = .household
                    }
                    accordion(.dataStorage, icon: "internaldrive.fill", tint: session.themeContrastAccent,
                              title: "Data & Storage", subtitle: "Backups, transfer, and erasing") {
                        dataStorageContent
                    }
                    sectionHeading("HELP & MORE", detail: "A little guidance when you need it.")
                    accordion(.help, icon: "questionmark.circle.fill", tint: session.accentColor,
                              title: "Help & Support", subtitle: "Guides and getting unstuck") {
                        helpContent
                    }
                    accordion(.testing, icon: "checklist", tint: session.themeContrastAccent,
                              title: "Testing & Diagnostics", subtitle: qaEnabled ? "Stocked QA is enabled" : "Optional tools for testing builds") {
                        Toggle("Enable Stocked QA", isOn: $qaEnabled)
                            .tint(session.accentColor)
                        if qaEnabled {
                            settingsSectionRow(icon: "checklist", tint: session.themeContrastAccent,
                                               title: "Open Stocked QA",
                                               subtitle: "Recipe imports, pantry, grocery, sync, tickets & reports") {
                                activeSheet = .qa
                            }
                        }
                        Text("Disabled by default. Enable only on builds being tested.")
                            .scaledFont(11).foregroundStyle(session.themeSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    sectionHeading("ACCOUNT", detail: "Manage your access and account data.")
                    accordion(.account, icon: "person.crop.circle", tint: Color.stockedGreen,
                              title: "Account", subtitle: accountSubtitle) {
                        accountContent
                    }

                    BuildInfoFooter()
                        .padding(.top, 10)
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
            }
        }
        .stockedPresentationSurface()
        .navigationTitle("Settings")
        .qaScreen("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let onBack {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .foregroundStyle(session.themeTextColor)
                            .frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Back to menu")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { if let onClose { onClose() } else { dismiss() } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .scaledFont(20)
                        .foregroundStyle(session.themeSecondaryText)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .a11yButton("Close settings")
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .storePopout:   PreferredStorePopout().environment(session)
            case .household:     HouseholdHomeView().environment(session)
            case .recipeSources: RecipeSourcesManagerView().environment(session)
            case .appIcon:       NavigationStack { AppIconPickerView().environment(session) }.stockedPresentationSurface()
            case .dietaryProfile: NavigationStack { DietaryProfileView().environment(session) }.stockedPresentationSurface()
            case .transfer:      KitchenTransferView().environment(session)
            case .notifications: NavigationStack { DailyBriefNotificationSettingsView().environment(session) }.stockedPresentationSurface()
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
            Text("This permanently deletes your account and all associated data, including your pantry, grocery list, meal history, saved recipes, settings, iCloud backup, and any shared household. Copies held by our sync service can be removed through the deletion request in Help & Support. This cannot be undone.")
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

    private var profileCard: some View {
        Button { activeSheet = .editProfile } label: {
            let arrangement = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 14))
                : AnyLayout(HStackLayout(alignment: .center, spacing: 14))
            arrangement {
                ProfileAvatarView(size: 52)
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.userName.isEmpty ? "Your kitchen" : session.userName)
                        .scaledFont(24, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text(accountSubtitle)
                        .scaledFont(12).foregroundStyle(session.themeSecondaryText)
                    Text("View & edit profile")
                        .scaledFont(12, weight: .semibold).foregroundStyle(session.themeContrastAccent)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundStyle(session.themeSecondaryText).accessibilityHidden(true)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(session.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
            .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(session.accentColor.opacity(0.16)))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Edit your profile")
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).scaledFont(11, weight: .bold).tracking(1.6)
                .foregroundStyle(session.themeContrastAccent)
            Text(detail).scaledFont(13).foregroundStyle(session.themeSecondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 18).padding(.bottom, 4)
        .accessibilityAddTraits(.isHeader)
    }

    private var accountSubtitle: String {
        session.accountType == .guest ? "Guest kitchen" : "Stocked member"
    }

    // MARK: - Accordion card

    // Direct destinations share the accordion header layout.
    private func settingsSectionRow(icon: String, tint: Color, title: String, subtitle: String,
                                    action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: icon).scaledFont(15, weight: .semibold).foregroundStyle(session.themeTextColor)
                        .padding(9).frame(minWidth: 36, minHeight: 36)
                        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).scaledFont(16, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text(subtitle).scaledFont(12)
                        .foregroundStyle(session.themeSecondaryText).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right").scaledFont(13, weight: .semibold)
                    .foregroundStyle(session.themeSecondaryText)
                    .accessibilityHidden(true)
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(session.themeCardColor)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(session.accentColor.opacity(session.isDarkMode ? 0.12 : 0.08), lineWidth: 1)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
                    if !dynamicTypeSize.isAccessibilitySize {
                        Image(systemName: icon).scaledFont(15, weight: .semibold).foregroundStyle(session.themeTextColor)
                            .padding(9).frame(minWidth: 36, minHeight: 36)
                            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9))
                            .accessibilityHidden(true)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title)
                            .scaledFont(16, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                        Text(subtitle)
                            .scaledFont(12)
                            .foregroundStyle(session.themeSecondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .scaledFont(13, weight: .semibold)
                        .foregroundStyle(session.themeSecondaryText)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .accessibilityHidden(true)
                }
                .padding(16)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .a11yButton(title, hint: isOpen ? "Collapse" : "Expand")
            .accessibilityValue(isOpen ? "Expanded" : "Collapsed")

            if isOpen {
                Divider().padding(.horizontal, 16)
                VStack(alignment: .leading, spacing: 16) {
                    content()
                }
                .padding(16)
                .transition(.opacity.combined(with: .stockedMove(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(session.themeCardColor)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(session.accentColor.opacity(session.isDarkMode ? 0.12 : 0.08), lineWidth: 1)
                )
        )
    }

    // MARK: - Preferences

    private func preferencesContent(_ category: PreferencesSectionView.Category) -> some View {
        PreferencesSectionView(
            onPreferredStore: { activeSheet = .storePopout },
            onRecipeSources: { activeSheet = .recipeSources },
            onAppIcon: { activeSheet = .appIcon },
            onDietaryProfile: { activeSheet = .dietaryProfile },
            category: category
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
}
