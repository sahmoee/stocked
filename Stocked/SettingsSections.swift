// SettingsSections.swift — shared settings section bodies for Stocked.
import SwiftUI

/// The actual controls for each settings section, in one place.
///
/// Both the full-page settings screen and the drawer render these same views, so a
/// change to a toggle happens once and appears in both. They diverged before this
/// existed; the notifications master switch was wired two different ways depending
/// on which screen you opened.
struct PreferencesSectionView: View {
    @Environment(AppSession.self) private var session
    @AppStorage("stocked.appTextSize") private var appTextSize = AppTextSize.standard.rawValue

    var onPreferredStore: () -> Void = {}
    var onRecipeSources: () -> Void = {}
    var onAppIcon: () -> Void = {}
    var onDietaryProfile: (() -> Void)? = nil

    private let dietaryStyles = ["Omnivore", "Vegetarian", "Vegan", "Pescatarian"]

    var body: some View {
        let dark = session.isDarkMode
        VStack(alignment: .leading, spacing: StockedSpacing.md) {
            settingsGroup(dark: dark, title: "Appearance", detail: "Choose how Stocked looks while you plan, shop, and cook.") {
                toggleRow(dark: dark, icon: "moon.fill", title: "Dark Mode", isOn: Binding(
                    get: { session.isDarkMode },
                    set: { session.isDarkMode = $0 }
                ))

                segmentedRow(dark: dark, icon: "textformat", title: "App Font", selection: Binding(
                    get: { session.appFont },
                    set: { session.appFont = $0 }
                ), options: AppFont.allCases) { $0.rawValue }

                appTextSizeControl(dark: dark, selection: $appTextSize)

                RecipeTextSizeControl()
            }

            settingsGroup(dark: dark, title: "Cooking", detail: "Tune recipes and suggestions around the way your kitchen cooks.") {
                segmentedRow(dark: dark, icon: "ruler", title: "Measurements", selection: Binding(
                    get: { session.unitSystem },
                    set: { session.unitSystem = $0 }
                ), options: UnitSystem.allCases) { $0.label }

                stepperRow(dark: dark, icon: "person.2.fill", title: "Default Servings", value: Binding(
                    get: { max(1, session.guestStore.cookingProfile.householdSize) },
                    set: { newValue in
                        updateProfile { profile in
                            profile.householdSize = max(1, min(12, newValue))
                        }
                    }
                ), range: 1...12)

                segmentedStringRow(dark: dark, icon: "fork.knife", title: "Diet", selection: Binding(
                    get: { session.guestStore.cookingProfile.dietaryStyle.isEmpty ? "Omnivore" : session.guestStore.cookingProfile.dietaryStyle },
                    set: { selected in updateProfile { $0.dietaryStyle = selected == "Omnivore" ? "" : selected } }
                ), options: dietaryStyles)

                if let onDietaryProfile {
                    actionRow(dark: dark, icon: "person.text.rectangle", title: "Dietary & Brand Profile",
                              detail: "Allergens, favorite brands, and brands to avoid",
                              action: onDietaryProfile)
                }

                Text("Cuisines stay in Recipes where changes are immediately useful.")
                    .scaledFont(12)
                    .foregroundStyle(session.themeTextColor.opacity(0.62))
                    .fixedSize(horizontal: false, vertical: true)
            }

            settingsGroup(dark: dark, title: "Kitchen", detail: "Keep shopping and pantry defaults close to the tools that use them.") {
                actionRow(dark: dark, icon: "storefront", title: "Preferred Store", detail: session.preferredStore, action: onPreferredStore)

                toggleRow(dark: dark, icon: "cart.badge.plus", title: "Auto-Add Missing to Grocery", isOn: Binding(
                    get: { session.autoAddMissingToGrocery },
                    set: { session.autoAddMissingToGrocery = $0 }
                ))

                toggleRow(dark: dark, icon: "person.3.fill", title: "Improve Stocked for Everyone", detail: "Share anonymous item facts only.", isOn: Binding(
                    get: { UserDefaults.standard.bool(forKey: "crowdShareEnabled") },
                    set: { UserDefaults.standard.set($0, forKey: "crowdShareEnabled") }
                ))

                actionRow(dark: dark, icon: "globe", title: "Recipe Sources", detail: "Add websites or manage sources", action: onRecipeSources)

                actionRow(dark: dark, icon: "app.badge", title: "App Icon", detail: "Choose a Home Screen icon", action: onAppIcon)

                if HealthKitManager.shared.isAvailable {
                    toggleRow(dark: dark, icon: "heart.fill", title: "Apple Health", detail: "Log cooked-meal nutrition to Health.", isOn: Binding(
                        get: { HealthKitManager.shared.isEnabled },
                        set: { HealthKitManager.shared.isEnabled = $0 }
                    ))
                }
            }

            settingsGroup(dark: dark, title: "Interaction", detail: "Choose the feedback you use most often.") {
                segmentedRow(dark: dark, icon: "hand.tap.fill", title: "Haptics", selection: Binding(
                    get: { session.hapticIntensity },
                    set: { session.hapticIntensity = $0 }
                ), options: HapticIntensity.allCases) { $0.rawValue }
            }
        }
    }

    private func updateProfile(_ edit: (inout UserCookingProfile) -> Void) {
        var profile = session.guestStore.cookingProfile
        edit(&profile)
        session.guestStore.cookingProfile = profile
    }
}

struct NotificationsSectionView: View {
    @Environment(AppSession.self) private var session

    var onNotificationSettings: () -> Void = {}

    var body: some View {
        let dark = session.isDarkMode
        VStack(alignment: .leading, spacing: StockedSpacing.md) {
            settingsGroup(dark: dark, title: "Notifications", detail: "Control kitchen reminders and the Daily Brief from one place.") {
                toggleRow(dark: dark, icon: "exclamationmark.bubble.fill", title: "Low Stock Reminders", isOn: Binding(
                    get: { session.notificationsEnabled },
                    set: { session.updateNotificationsEnabledFromUser($0) }
                ))

                actionRow(dark: dark, icon: "bell.badge.fill", title: "Reminders & Daily Brief", detail: "Schedule expiry, cook and prep reminders", action: onNotificationSettings)
            }
        }
    }
}

struct DataStorageSectionView: View {
    @Environment(AppSession.self) private var session

    var onTransferKitchen: () -> Void = {}
    var onDataStorage: () -> Void = {}
    var onCatalogImport: () -> Void = {}
    var onEraseAllData: () -> Void = {}

    var body: some View {
        let dark = session.isDarkMode
        VStack(alignment: .leading, spacing: StockedSpacing.md) {
            settingsGroup(dark: dark, title: "Data & Storage", detail: "Back up your kitchen, move it between devices, and manage app data.") {
                segmentedRow(dark: dark, icon: "clock.arrow.2.circlepath", title: "Auto Backup", selection: Binding(
                    get: { session.backupFrequency },
                    set: { session.backupFrequency = $0 }
                ), options: BackupFrequency.allCases) { $0.rawValue }

                actionRow(dark: dark, icon: "arrow.left.arrow.right.square.fill", title: "Transfer Kitchen", detail: "Export or import data", action: onTransferKitchen)

                #if targetEnvironment(macCatalyst)
                actionRow(dark: dark, icon: "square.and.arrow.down.on.square.fill", title: "Recipe Catalog Import", detail: "Bulk-load CSV for the catalog", action: onCatalogImport)
                #endif

                actionRow(dark: dark, icon: "icloud.fill", title: "Backup to iCloud", detail: "Last backup: \(session.transferManager.lastBackupDate)") {
                    session.transferManager.backupToiCloud(store: session.guestStore)
                }

                transferStatus

                actionRow(dark: dark, icon: "internaldrive", title: "Storage & Auto Backup", detail: "Usage, migration and backup details", action: onDataStorage)

                NavigationLink {
                    StockedHealthView()
                } label: {
                    navigationRow(dark: dark, icon: "waveform.path.ecg", title: "App Health", detail: "Server, stability, sync and cache", color: Color.stockedGreen)
                }
                .buttonStyle(.plain)

                destructiveRow(dark: dark, icon: "trash.fill", title: "Erase All Data", detail: "This device and iCloud", action: onEraseAllData)
            }
        }
    }

    @ViewBuilder private var transferStatus: some View {
        if !session.transferManager.errorMessage.isEmpty {
            Label(session.transferManager.errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.stockedSans(12, weight: .semibold))
                .foregroundStyle(Color.stockedError)
                .fixedSize(horizontal: false, vertical: true)
        } else if !session.transferManager.statusMessage.isEmpty {
            Label(session.transferManager.statusMessage, systemImage: "checkmark.circle.fill")
                .font(.stockedSans(12, weight: .semibold))
                .foregroundStyle(Color.stockedSuccess)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AccountSectionView: View {
    @Environment(AppSession.self) private var session

    var showsProfileActions = true
    var onEditProfile: () -> Void = {}
    var onLogOut: () -> Void = {}
    var onDeleteAccount: () -> Void = {}

    var body: some View {
        let dark = session.isDarkMode
        VStack(alignment: .leading, spacing: StockedSpacing.md) {
            settingsGroup(dark: dark, title: "Account", detail: "Manage your profile and sign-in state for this kitchen.") {
                if showsProfileActions {
                    actionRow(dark: dark, icon: "person.crop.circle.badge.checkmark", title: "Edit Profile", detail: "Name, avatar and account details", action: onEditProfile)
                    actionRow(dark: dark, icon: "rectangle.portrait.and.arrow.right", title: session.accountType == .guest ? "Exit Guest Mode" : "Log Out", detail: session.accountType == .guest ? "Leave guest mode" : "Sign out of this device", action: onLogOut)
                }

                if session.accountType != .guest {
                    destructiveRow(dark: dark, icon: "person.crop.circle.badge.xmark", title: "Delete Account", detail: "Permanently delete your account", action: onDeleteAccount)
                }
            }
        }
    }
}

struct HelpSectionView: View {
    @Environment(AppSession.self) private var session

    var onHelpCenter: () -> Void = {}
    var onContactSupport: () -> Void = {}
    var onPrivacyPolicy: () -> Void = {}
    var onTermsOfService: () -> Void = {}
    var onWebsite: () -> Void = {}

    var body: some View {
        let dark = session.isDarkMode
        VStack(alignment: .leading, spacing: StockedSpacing.md) {
            settingsGroup(dark: dark, title: "Help & Support", detail: "Find guides, contact support, and review Stocked policies.") {
                actionRow(dark: dark, icon: "questionmark.circle", title: "Help Center", detail: "Guides for every part of Stocked", action: onHelpCenter)
                actionRow(dark: dark, icon: "envelope.fill", title: "Contact Support", detail: BuildConfig.supportEmail, action: onContactSupport)
                actionRow(dark: dark, icon: "lock.shield.fill", title: "Privacy Policy", detail: "How your data is handled", action: onPrivacyPolicy)
                actionRow(dark: dark, icon: "doc.text.fill", title: "Terms of Service", detail: "The rules for using Stocked", action: onTermsOfService)
                actionRow(dark: dark, icon: "globe", title: "Website", detail: "sowensstudios.com", action: onWebsite)
            }
        }
    }
}

private extension AppBackground {
    var isDefaultTan: Bool {
        if case .defaultTan = self { return true }
        return false
    }
}

@ViewBuilder
private func settingsGroup<Content: View>(dark: Bool, title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
    VStack(alignment: .leading, spacing: StockedSpacing.xs) {
        Text(title.uppercased())
            .font(.stockedSans(10, weight: .bold))
            .foregroundStyle(Color.appSubtext(dark))
            .textCase(.uppercase)

        VStack(alignment: .leading, spacing: StockedSpacing.sm) {
            Text(detail)
                .font(.stockedSans(12))
                .foregroundStyle(Color.appSubtext(dark))
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(StockedSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.appSurface(dark))
        .clipShape(RoundedRectangle(cornerRadius: StockedRadius.md, style: .continuous))
    }
}

private func toggleRow(dark: Bool, icon: String, title: String, detail: String? = nil, isOn: Binding<Bool>) -> some View {
    StockedAlignedControlLabel(
        icon: icon,
        title: title,
        subtitle: detail,
        tint: isOn.wrappedValue ? Color.stockedGold : Color.appSubtext(dark),
        titleColor: Color.appText(dark)
    ) {
        Toggle("", isOn: isOn)
            .labelsHidden()
            .tint(Color.stockedGold)
    }
    .frame(minHeight: 44)
}

private func actionRow(dark: Bool, icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        navigationRow(dark: dark, icon: icon, title: title, detail: detail, color: Color.stockedGold)
    }
    .buttonStyle(.plain)
    .a11yButton(title, hint: detail)
}

private func destructiveRow(dark: Bool, icon: String, title: String, detail: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
        navigationRow(dark: dark, icon: icon, title: title, detail: detail, color: Color.stockedError, destructive: true)
    }
    .buttonStyle(.plain)
    .a11yButton(title, hint: detail)
}

private func navigationRow(dark: Bool, icon: String, title: String, detail: String, color: Color, destructive: Bool = false) -> some View {
    StockedAlignedControlLabel(
        icon: icon,
        title: title,
        subtitle: detail,
        tint: color,
        titleColor: destructive ? Color.stockedError : Color.appText(dark)
    ) {
        Image(systemName: "chevron.right")
            .font(.stockedSans(11, weight: .bold))
            .foregroundStyle(Color.appSubtext(dark))
    }
    .contentShape(Rectangle())
    .frame(minHeight: 44)
}

private func segmentedStringRow(dark: Bool, icon: String, title: String, selection: Binding<String>, options: [String]) -> some View {
    segmentedRow(dark: dark, icon: icon, title: title, selection: selection, options: options) { $0 }
}

private func appTextSizeControl(dark: Bool, selection: Binding<String>) -> some View {
    VStack(alignment: .leading, spacing: StockedSpacing.xs) {
        rowTitle(dark: dark, icon: "textformat.size", title: "App Text Size", active: true)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 76), spacing: 6)], spacing: 6) {
            ForEach(AppTextSize.allCases) { option in
                let selected = selection.wrappedValue == option.rawValue
                Button {
                    selection.wrappedValue = option.rawValue
                    HapticManager.select()
                } label: {
                    Text(option.rawValue)
                        .font(.stockedSans(12, weight: .bold))
                        .foregroundStyle(selected ? Color.stockedWhite : Color.appText(dark))
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .padding(.horizontal, 8)
                        .background(selected ? Color.stockedGold : Color.appText(dark).opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        Text("Adjusts text throughout pages, sheets, buttons, widgets, and cooking flows. Your system text size still applies.")
            .font(.stockedSans(11, relativeTo: .caption))
            .foregroundStyle(Color.appSubtext(dark))
            .fixedSize(horizontal: false, vertical: true)
    }
}

private func segmentedRow<Option: Hashable>(dark: Bool, icon: String, title: String, selection: Binding<Option>, options: [Option], label: @escaping (Option) -> String) -> some View {
    VStack(alignment: .leading, spacing: StockedSpacing.xs) {
        rowTitle(dark: dark, icon: icon, title: title, active: true)
        AdaptiveSettingsPicker(title: title, selection: selection, options: options, label: label)
    }
    .frame(minHeight: 44)
}

private struct AdaptiveSettingsPicker<Option: Hashable>: View {
    @Environment(\.stockedLayout) private var layoutMetrics
    let title: String
    @Binding var selection: Option
    let options: [Option]
    let label: (Option) -> String

    var body: some View {
        if layoutMetrics.width < 360 {
            Picker(title, selection: $selection) { pickerOptions }
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, minHeight: layoutMetrics.minimumControlHeight, alignment: .leading)
        } else {
            Picker(title, selection: $selection) { pickerOptions }
                .pickerStyle(.segmented)
        }
    }

    @ViewBuilder private var pickerOptions: some View {
        ForEach(options, id: \.self) { option in
            Text(label(option)).tag(option)
        }
    }
}

private func stepperRow(dark: Bool, icon: String, title: String, value: Binding<Int>, range: ClosedRange<Int>) -> some View {
    HStack(alignment: .center, spacing: StockedSpacing.sm) {
        rowIcon(dark: dark, icon, active: true)
        Stepper(value: value, in: range) {
            Text("\(title): \(value.wrappedValue)")
                .font(.stockedSerif(14, weight: .semibold))
                .foregroundStyle(Color.appText(dark))
        }
    }
    .frame(minHeight: 44)
}

private func sliderRow(dark: Bool, icon: String, title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
    VStack(alignment: .leading, spacing: StockedSpacing.xs) {
        rowTitle(dark: dark, icon: icon, title: title, active: true)
        Slider(value: value, in: range, step: 10)
            .tint(Color.stockedGold)
    }
    .frame(minHeight: 44)
}

private func chipPicker(dark: Bool, title: String, icon: String, options: [String], selected: [String], onToggle: @escaping (String) -> Void) -> some View {
    VStack(alignment: .leading, spacing: StockedSpacing.xs) {
        rowTitle(dark: dark, icon: icon, title: title, active: !selected.isEmpty)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: StockedSpacing.xs)], alignment: .leading, spacing: StockedSpacing.xs) {
            ForEach(options, id: \.self) { option in
                let isSelected = selected.contains { $0.caseInsensitiveCompare(option) == .orderedSame }
                Button { onToggle(option) } label: {
                    Text(option)
                        .font(.stockedSans(12, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.stockedWhite : Color.appText(dark))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity, minHeight: 34)
                        .padding(.horizontal, StockedSpacing.xs)
                        .background(isSelected ? Color.stockedGold : Color.appText(dark).opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: StockedRadius.pill, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private func rowTitle(dark: Bool, icon: String, title: String, active: Bool) -> some View {
    HStack(spacing: StockedSpacing.sm) {
        rowIcon(dark: dark, icon, active: active)
        Text(title)
            .font(.stockedSerif(14, weight: .semibold))
            .foregroundStyle(Color.appText(dark))
    }
}

private func rowIcon(dark: Bool, _ icon: String, active: Bool, color: Color? = nil) -> some View {
    ZStack {
        RoundedRectangle(cornerRadius: StockedRadius.sm, style: .continuous)
            .fill(color ?? (active ? Color.stockedGold : Color.appSubtext(dark)))
            .frame(width: 30, height: 30)
        Image(systemName: icon)
            .font(.stockedSans(13, weight: .semibold))
            .foregroundStyle(Color.stockedWhite)
    }
}
