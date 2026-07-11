// DrawerSettingsContent.swift — DrawerContent, SettingsContent, SidebarContent
// Extracted from MainTabView.swift (#4)
import SwiftUI
import CloudKit
import os

// MARK: - Shared Settings Content
// Used by both DrawerContent and SidebarContent so settings are written once.
struct SettingsContent: View {
    @Environment(AppSession.self) var session

    var onClose: () -> Void = {}
    // When set (drawer path), these route presentation up to MainTabView's stable body,
    // which presents a real .sheet after the drawer closes — avoiding the List-recycle
    // teardown that makes a sheet attached inside the drawer flash closed. When nil
    // (iPad sidebar), the buttons fall back to a local .sheet(item:).
    var onNotifications: (() -> Void)? = nil
    // When set (drawer path), settings sheets route UP to MainTabView's stable body and
    // present after the drawer closes — the only reliable way; a sheet attached inside the
    // sliding drawer flashes shut. When nil (iPad sidebar) the local .sheet(item:) is used.
    var onQuickAction: ((DrawerQuickAction) -> Void)? = nil

    @State private var showClearAlert   = false
    @State private var showDeleteAccountAlert = false

    // One enum drives a SINGLE .sheet(item:). Stacking several .sheet(isPresented:) on the same
    // view makes SwiftUI present one then immediately dismiss it, so a sheet needed a second tap.
    private enum DrawerSheet: Int, Identifiable {
        case dataStorage, storePopout, household, recipeSources, transfer, notifications
        var id: Int { rawValue }
    }
    @State private var activeSheet: DrawerSheet? = nil

    // ── Preferences accordion expansion state ───────────────────────
    // These three fields (Preferences, Notifications, Data & Storage) are embedded in the
    // drawer's Settings list. Edit Profile is now its own screen, not an accordion.
    @State private var expandPreferences   = false
    @State private var expandNotifications = false
    @State private var expandDataStorage   = false

    private var greeting: String { StockedFormatters.timeOfDayGreeting }

    var body: some View {
        Group {
            // ── PREFERENCES ─────────────────────────────────────────
            // Expandable field: Dark Mode, Measurements, Preferred Store, Auto-Add Missing,
            // Auto Backup, Household Sync. (Auto Backup lives here only; Data & Storage links
            // to the same screen without duplicating the control.)
            Section {
                DisclosureGroup(isExpanded: $expandPreferences) {
                    // Dark Mode
                    Toggle(isOn: Binding(get: { session.isDarkMode }, set: { session.isDarkMode = $0 })) {
                        Label("Dark Mode", systemImage: "moon.fill")
                            .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                    }.tint(Color.stockedGold).listRowBackground(Color.clear)

                    // Measurements (US / Metric)
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
                    .listRowBackground(Color.clear)

                    // #9 — Recipe Text Size: scales recipe titles, ingredients, and steps
                    // app-wide (fixed-size fonts don't follow the system text-size slider).
                    RecipeTextSizeControl()
                        .listRowBackground(Color.clear)

                    // Cook Buttons — shape + size for the Cook Now hub buttons (Foods, Moods,
                    // Surprise Me). Size scales them up to the width limit of the screen.
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Cook Buttons", systemImage: "circle.grid.2x1.fill")
                            .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                        Text("Applies to Cook Now, Cook Later, and the Cook hub buttons — updates live")
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
                    .listRowBackground(Color.clear)

                    // Crowd database — opt-in, anonymized shared item facts. Read features
                    // (smart defaults, pairings) work for everyone; only reporting is gated.
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
                    }.tint(Color.stockedGold).listRowBackground(Color.clear)

                    // Preferred Store (pop-out picker).
                    Button { if let onQuickAction { onQuickAction(.storePopout) } else { activeSheet = .storePopout } } label: {
                        HStack {
                            Label("Preferred Store", systemImage: "storefront")
                                .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                            Spacer()
                            Text(session.preferredStore).font(.system(size: 12, weight: .bold)).foregroundStyle(Color.stockedGold)
                            Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.35))
                        }
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color.clear)

                    // Auto-add Missing to Grocery
                    Toggle(isOn: Binding(get: { session.autoAddMissingToGrocery }, set: { session.autoAddMissingToGrocery = $0 })) {
                        Label("Auto-Add Missing to Grocery", systemImage: "cart.badge.plus")
                            .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                    }.tint(Color.stockedGold).listRowBackground(Color.clear)

                    // Auto-Backup frequency (single home for this control).
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
                    .listRowBackground(Color.clear)

                    // Household Sync — opens the existing household management screen.
                    Button { if let onQuickAction { onQuickAction(.household) } else { activeSheet = .household } } label: {
                        settingsRow(icon: "person.2.fill", color: Color.stockedInfo,
                                    title: "Household Sync",
                                    detail: session.householdCode.isEmpty ? "Share pantry with family" : "Code: \(session.householdCode)")
                    }
                    .listRowBackground(Color.clear)

                    // Recipe Sources — add your own websites or manage the built-in list.
                    Button { if let onQuickAction { onQuickAction(.recipeSources) } else { activeSheet = .recipeSources } } label: {
                        settingsRow(icon: "globe", color: Color.stockedGold,
                                    title: "Recipe Sources",
                                    detail: "Add websites or manage sources")
                    }
                    .listRowBackground(Color.clear)

                    // Apple Health — opt-in nutrition logging for cooked meals. Hidden on
                    // devices without Health data (e.g. some iPads).
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
                        }.tint(Color.stockedGold).listRowBackground(Color.clear)
                    }
                } label: {
                    fieldLabel(icon: "slider.horizontal.3", color: Color.stockedInfo, title: "Preferences")
                }
                .listRowBackground(Color.clear)
            }

            // ── NOTIFICATIONS ───────────────────────────────────────
            // Expandable field: low-stock reminders toggle + the scheduling screen
            // (daily brief / expiry / cook / prep reminders).
            Section {
                DisclosureGroup(isExpanded: $expandNotifications) {
                    // Low Stock reminders.
                    Toggle(isOn: Binding(get: { session.notificationsEnabled }, set: { session.notificationsEnabled = $0 })) {
                        Label("Low Stock Reminders", systemImage: "exclamationmark.bubble.fill")
                            .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                    }.tint(Color.stockedGold).listRowBackground(Color.clear)

                    // Reminders & Daily Brief scheduling — opens the existing settings screen.
                    Button {
                        if let onQuickAction { onQuickAction(.notifications) }
                        else { activeSheet = .notifications }
                    } label: {
                        settingsRow(icon: "bell.badge.fill", color: Color.stockedGold,
                                    title: "Reminders & Daily Brief",
                                    detail: "Schedule expiry, cook & prep reminders")
                    }
                    .listRowBackground(Color.clear)
                } label: {
                    fieldLabel(icon: "bell.fill", color: Color.stockedGold, title: "Notifications")
                }
                .listRowBackground(Color.clear)
            }

            // ── DATA & STORAGE ──────────────────────────────────────
            // Expandable field: Transfer Kitchen, Backup to iCloud, Auto Backup options,
            // Clear All App Data, and the Data & Storage detail screen.
            Section {
                DisclosureGroup(isExpanded: $expandDataStorage) {
                    // Transfer Kitchen — existing export/import screen.
                    Button { if let onQuickAction { onQuickAction(.transferKitchen) } else { activeSheet = .transfer } } label: {
                        settingsRow(icon: "arrow.left.arrow.right.square.fill", color: Color.stockedGold,
                                    title: "Transfer Kitchen", detail: "Export or import data")
                    }
                    .listRowBackground(Color.clear)

                    // Backup to iCloud (manual).
                    Button {
                        session.transferManager.backupToiCloud(store: session.guestStore)
                    } label: {
                        settingsRow(icon: "icloud.fill", color: Color.stockedInfo,
                                    title: "Backup to iCloud",
                                    detail: "Last backup: \(session.transferManager.lastBackupDate)")
                    }.listRowBackground(Color.clear)

                    // Live backup/restore status (so CloudKit failures are visible).
                    if !session.transferManager.errorMessage.isEmpty {
                        Label(session.transferManager.errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 12)).foregroundStyle(.red)
                            .listRowBackground(Color.clear)
                    } else if !session.transferManager.statusMessage.isEmpty {
                        Label(session.transferManager.statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(Color.stockedGreen)
                            .listRowBackground(Color.clear)
                    }

                    // Storage, usage, migration, and auto-backup frequency — ONE row. This
                    // used to be two rows ("Auto Backup Options" and "Data & Storage") that
                    // both opened the exact same detail screen; condensed to a single entry.
                    Button { if let onQuickAction { onQuickAction(.dataStorage) } else { activeSheet = .dataStorage } } label: {
                        settingsRow(icon: "internaldrive", color: Color.stockedCharcoal,
                                    title: "Storage & Auto Backup",
                                    detail: "Usage, migration · Backs up \(session.backupFrequency.rawValue.lowercased())")
                    }.listRowBackground(Color.clear)

                    // Erase All Data — combined destructive action. One tap now clears
                    // EVERYTHING everywhere: local device data, the iCloud Key-Value Store,
                    // the iCloud Documents backup, and all CloudKit KitchenBackup records
                    // (the old separate "Delete iCloud Data" row was folded into this).
                    // signOut(clearData: true) also forces the onboarding quiz on next entry.
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
                    }.listRowBackground(Color.clear)
                    .alert("Erase All Data?", isPresented: $showClearAlert) {
                        Button("Erase Everything", role: .destructive) { session.signOut(clearData: true) }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Permanently deletes your pantry, grocery list, meal history, recipes, and settings from this device AND removes every Stocked backup from iCloud. You'll go through setup again next time. Cannot be undone.")
                    }
                } label: {
                    fieldLabel(icon: "internaldrive.fill", color: Color.stockedCharcoal, title: "Data & Storage")
                }
                .listRowBackground(Color.clear)
            }

            // ── DELETE ACCOUNT (signed-in only) ─────────────────────
            // Sign Out / Exit Guest lives in the drawer's own Settings list. Delete Account is
            // required by the App Store for signed-in accounts and is surfaced here.
            if session.accountType != .guest {
                Section {
                    Button { showDeleteAccountAlert = true } label: {
                        settingsRow(icon: "person.crop.circle.badge.xmark", color: .red,
                                    title: "Delete Account", detail: "Permanently delete your account")
                    }
                    .listRowBackground(Color.clear)
                    .alert("Delete Account?", isPresented: $showDeleteAccountAlert) {
                        Button("Delete Account", role: .destructive) { session.deleteAccount() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This permanently deletes your account and all associated data, including your pantry, grocery list, meal history, saved recipes, settings, iCloud backup, and any shared household. This cannot be undone.")
                    }
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .dataStorage:   DataStorageView().environment(session)
            case .storePopout:   PreferredStorePopout().environment(session)
            case .household:     HouseholdHomeView().environment(session)
            case .recipeSources: RecipeSourcesManagerView().environment(session)
            case .transfer:      KitchenTransferView().environment(session)
            case .notifications: NavigationStack { DailyBriefNotificationSettingsView().environment(session) }
            }
        }
    }


    // MARK: - Helpers
    // Header label for an expandable preferences field (DisclosureGroup). Mirrors the
    // settingsRow icon-tile styling so the four fields read consistently.
    private func fieldLabel(icon: String, color: Color, title: String) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7).fill(color).frame(width: 28, height: 28)
                Image(systemName: icon).font(.system(size: 13)).foregroundStyle(.white)
            }
            Text(title)
                .font(.system(size: 15, weight: .semibold, design: .serif))
                .foregroundStyle(session.themeTextColor)
        }
    }

    // Representative background swatch for each preset

    private func settingsRow(icon: String, color: Color, title: String, detail: String,
                             trailingSystemImage: String? = nil) -> some View {
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
            if let trailingSystemImage {
                Image(systemName: trailingSystemImage).font(.system(size: 11))
                    .foregroundStyle(Color.stockedGold)
            }
            Image(systemName: "chevron.right").font(.system(size: 11))
                .foregroundStyle(session.themeTextColor.opacity(0.25))
        }
    }

    private func themeButton(_ label: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                // Active: dark text on the gold fill (not gold-on-gold, which rendered as a
                // solid block with invisible text). Inactive: themed text on a subtle fill.
                .foregroundStyle(active ? Color.stockedBlack : session.themeTextColor.opacity(0.7))
                .frame(maxWidth: .infinity).padding(.vertical, 9)
                .background(active ? Color.stockedGold : session.themeTextColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
        }.buttonStyle(.plain)
    }

    // ── Feature 46: Export function ──────────────────────────────────
    private func exportAllData() -> URL? {
        let store = session.guestStore
        let payload: [String: Any] = [
            "exportDate":  StockedFormatters.iso8601.string(from: Date()),
            "appVersion":  BuildConfig.version,
            "inventory":   ((try? JSONEncoder().encode(store.inventoryItems)).flatMap { String(data: $0, encoding: .utf8) } ?? "") as String,
            "grocery":     ((try? JSONEncoder().encode(store.groceryItems)).flatMap { String(data: $0, encoding: .utf8) } ?? "") as String,
            "pastMeals":   ((try? JSONEncoder().encode(store.pastMeals)).flatMap { String(data: $0, encoding: .utf8) } ?? "") as String,
            "userRecipes": ((try? JSONEncoder().encode(store.userRecipes)).flatMap { String(data: $0, encoding: .utf8) } ?? "") as String,
            "profile":     ((try? JSONEncoder().encode(store.cookingProfile)).flatMap { String(data: $0, encoding: .utf8) } ?? "") as String,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: .prettyPrinted) else {
            Log.app.error("Export: failed to serialize export payload to JSON")
            return nil
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Stocked_Export_\(Date().timeIntervalSince1970).json")
        do {
            try data.write(to: url)
        } catch {
            Log.app.error("Export: failed to write export file: \(error.localizedDescription, privacy: .public)")
            return nil   // don't hand the share sheet a URL to a file that isn't there
        }
        return url
    }
}

// MARK: - Sidebar Content (iPad)
struct SidebarContent: View {
    @Environment(AppSession.self) var session
    @Binding var selected:      StockedTab
    @Binding var showReceipt:   Bool
    @Binding var showAddItems:  Bool
    @Binding var showSearch:    Bool
    @Binding var showStats:     Bool
    @Binding var showDatabases: Bool

    var body: some View {
        List(selection: Binding(get: { selected }, set: { if let v = $0 { selected = v } })) {

            Section {
                ForEach(StockedTab.allCases, id: \.self) { tab in
                    iPadNavRow(tab)
                }
            }

            Section {
                sidebarButton("Scan Receipt",      icon: "camera.viewfinder") { showReceipt   = true }
                sidebarButton("Add Items",          icon: "plus.circle")       { showAddItems  = true }
                sidebarButton("Global Search",      icon: "magnifyingglass")   { showSearch    = true }
                sidebarButton("Stats",              icon: "chart.bar")         { showStats     = true }
                sidebarButton("Databases",          icon: "cylinder.split.1x2"){ showDatabases = true }
            } header: { sidebarHeader("Quick Actions") }

            Section {
                DisclosureGroup {
                    SettingsContent()
                } label: {
                    Label("Settings", systemImage: "slider.horizontal.3")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                }
                .listRowBackground(Color.clear)
            }

            // ── Build Info — standalone, below Settings ──────────────
            Section {
                BuildInfoFooter()
            }
            .listRowBackground(Color.clear)

        }
        .listStyle(.sidebar)
        .navigationTitle("Stocked.")
        .navigationBarTitleDisplayMode(.large)
        .scrollContentBackground(.hidden)
        .background(session.themeBgColor)
    }

    private func iPadNavRow(_ tab: StockedTab) -> some View {
        let isSelected = selected == tab
        return Label(tab.label, systemImage: isSelected ? tab.iconFilled : tab.icon)
            .tag(tab)
            .font(.system(size: 16, weight: .semibold, design: .serif))
            .foregroundStyle(isSelected ? Color.stockedGold : session.themeTextColor)
            .listRowBackground(isSelected ? AnyView(Color.stockedCharcoal.clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))) : AnyView(Color.clear))
            .padding(.vertical, 4)
    }

    private func sidebarButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 15, weight: .medium, design: .serif))
                .foregroundStyle(session.themeTextColor)
        }.listRowBackground(Color.clear)
    }

    private func sidebarHeader(_ t: String) -> some View {
        SectionHeader(text: t, padded: false)
    }
}

// MARK: - Drawer Content (iPhone)
// Quick actions the drawer can request; MainTabView performs them after closing the drawer.
enum DrawerQuickAction { case scanReceipt, scanBarcode, quickUpdate, addItems, search, stats, databases, editProfile, notifications, household, activity, dataStorage, transferKitchen, recipeSources, storePopout }

struct DrawerContent: View {
    // One enum drives a SINGLE .sheet(item:) (see DrawerSheet note above) so these present
    // reliably on the first tap instead of flashing open then closed.
    private enum HomeSheet: Int, Identifiable {
        case helpCenter, usageInsights, toolbox, profileHub
        var id: Int { rawValue }
    }
    @State private var activeHomeSheet: HomeSheet? = nil
    @State private var showLogoutConfirm = false
    @State private var orderStore = DrawerOrderStore.shared   // rearrangeable drawer rows
    @Environment(AppSession.self) var session
    @Binding var selected:       StockedTab
    @Binding var showDrawer:     Bool
    @Binding var showReceipt:    Bool
    @Binding var showAddItems:   Bool
    @Binding var showSearch:     Bool
    @Binding var showStats:      Bool
    @Binding var showDatabases:  Bool
    var onNavigate: ((StockedTab) -> Void)? = nil  // shared navigate(to:) from MainTabView
    var onQuickAction: ((DrawerQuickAction) -> Void)? = nil  // parent closes drawer + runs action

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                StockedWordmark(size: 26)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3)) { showDrawer = false }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22)).foregroundStyle(session.themeTextColor.opacity(0.3))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 22).padding(.top, 56).padding(.bottom, 16)

            // Profile card — the chef avatar, name, account status, and cook streak, wrapped in
            // a rounded surface so it reads as a distinct profile element rather than a bare row.
            // Tapping it opens Edit Profile. Secondary text uses the themeSecondaryText token for
            // legible contrast in both light and dark mode.
            Button {
                activeHomeSheet = .profileHub
            } label: {
                HStack(spacing: 13) {
                    ProfileAvatarView(size: 50)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.userName)
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(session.themeTextColor)
                        HStack(spacing: 6) {
                            // Account status pill
                            Text(session.accountType == .guest ? "Guest" : "Member")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(session.accentColor)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(
                                    Capsule().fill(session.accentColor.opacity(session.isDarkMode ? 0.18 : 0.14))
                                )
                            // Cook streak, only when there is one to celebrate
                            if session.cookStreak > 0 {
                                HStack(spacing: 3) {
                                    Image(systemName: "flame.fill").font(.system(size: 10))
                                    Text("\(session.cookStreak) day\(session.cookStreak == 1 ? "" : "s")")
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(session.themeSecondaryText)
                            }
                        }
                        Text("Edit Profile")
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeSecondaryText)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(session.themeSecondaryText.opacity(0.7))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(session.themeCardColor)
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(session.accentColor.opacity(session.isDarkMode ? 0.14 : 0.10), lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            Divider()

            // Full scrollable list — mockup drawer: Kitchen Tools / Insights / Settings.
            // Tab navigation lives in the tab bar; the drawer is tools + settings only.
            List {
                // Kitchen Tools — rearrangeable. Long-press any row and drag to reorder;
                // the order is remembered. Kitchen Toolbox lives here by default now.
                Section {
                    ForEach(orderStore.rows(in: .kitchenTools), id: \.self) { row in
                        drawerRow(for: row)
                    }
                    .onMove { source, destination in
                        orderStore.move(in: .kitchenTools, from: source, to: destination)
                    }
                } header: { drawerHeader("Kitchen Tools") }

                // Insights — also rearrangeable.
                Section {
                    ForEach(orderStore.rows(in: .insights), id: \.self) { row in
                        drawerRow(for: row)
                    }
                    .onMove { source, destination in
                        orderStore.move(in: .insights, from: source, to: destination)
                    }
                } header: { drawerHeader("Insights") }

                Section {
                    drawerButton("Help Center",   icon: "questionmark.circle") { activeHomeSheet = .helpCenter }
                    drawerButton(session.accountType == .guest ? "Exit Guest Mode" : "Log Out",
                                 icon: "rectangle.portrait.and.arrow.right") { showLogoutConfirm = true }
                } header: { drawerHeader("Settings") }

                // Preferences / Notifications / Data & Storage accordions (and Delete Account)
                // now live here in the drawer's Settings list, below the Help Center / Log Out
                // rows. Edit Profile is reached from the chef row above, not here.
                SettingsContent(onQuickAction: onQuickAction)

                // ── Build Info — standalone, below Settings ──────────────
                Section {
                    BuildInfoFooter()
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))

            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(session.themeBgColor.ignoresSafeArea())
        .shadow(color: .black.opacity(0.2), radius: 20, x: 8, y: 0)
        // Edit Profile opens from the chef row. All four present via one .sheet(item:).
        .sheet(item: $activeHomeSheet) { sheet in
            switch sheet {
            case .helpCenter:    HelpCenterSheet().environment(session)
            case .usageInsights: NavigationStack { UsageInsightsView().environment(session) }
            case .toolbox:       NavigationStack { KitchenToolboxView().environment(session) }
            case .profileHub:    EditProfileView().environment(session)
            }
        }
        .alert(session.accountType == .guest ? "Exit Guest Mode?" : "Log Out?", isPresented: $showLogoutConfirm) {
            if session.accountType == .guest {
                Button("Keep Data") { session.signOut(clearData: false) }
                Button("Erase & Exit", role: .destructive) { session.signOut(clearData: true) }
            } else {
                Button("Log Out", role: .destructive) { session.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // Prefer the parent's handler (it closes the drawer AND runs the action from
    // MainTabView's own context, avoiding a detached Task mutating parent bindings —
    // the source of the receipt-from-drawer crash). Falls back to local behavior.
    private func runQuick(_ action: DrawerQuickAction, fallback: @escaping () -> Void) {
        if let handler = onQuickAction {
            handler(action)
        } else {
            closeAndRun(fallback)
        }
    }

    private func closeAndRun(_ action: @escaping () -> Void) {
        withAnimation(.spring(response: 0.3)) { showDrawer = false }
        Task {
            try? await Task.sleep(nanoseconds: 300000000)
            action()
        }
    }

    private func drawerNavRow(_ tab: StockedTab) -> some View {
        let isSelected = selected == tab
        return Button {
            HapticManager.select()
            if let nav = onNavigate {
                nav(tab)          // uses same navigate(to:) as global nav bar
            } else {
                withAnimation { selected = tab }
                withAnimation(.spring(response: 0.3)) { showDrawer = false }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isSelected ? tab.iconFilled : tab.icon)
                    .font(.system(size: 18)).foregroundStyle(isSelected ? Color.stockedGold : session.themeTextColor.opacity(0.7)).frame(width: 26)
                Text(tab.label)
                    .font(.system(size: 16, weight: isSelected ? .bold : .semibold, design: .serif))
                    .foregroundStyle(isSelected ? Color.stockedGold : session.themeTextColor)
                Spacer()
                if isSelected { Circle().fill(Color.stockedGold).frame(width: 6, height: 6) }
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .background(isSelected ? Color.stockedCharcoal.opacity(0.1) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
    }

    // Maps a stable row identifier to its labelled button + action. Used by the reorderable
    // Kitchen Tools and Insights sections so a saved order can drive which row appears where.
    @ViewBuilder
    private func drawerRow(for row: DrawerRowID) -> some View {
        switch row {
        case .scanReceipt:
            drawerButton("Scan Receipt", icon: "camera.viewfinder") { runQuick(.scanReceipt) { showReceipt = true } }
        case .addItems:
            drawerButton("Add Items", icon: "plus.circle") { runQuick(.addItems) { showAddItems = true } }
        case .quickUpdate:
            drawerButton("Quick Update", icon: "list.clipboard") { runQuick(.quickUpdate) {} }
        case .importRecipe:
            drawerButton("Import Recipe", icon: "square.and.arrow.down") {
                closeAndRun {
                    // Switch to the Recipes tab, then flag the URL import for it to consume
                    // once on appear. (A NotificationCenter trigger looped previously — the
                    // flag is consumed exactly once.)
                    session.pendingRecipeImport = true
                    NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.recipes)
                }
            }
        case .globalSearch:
            drawerButton("Global Search", icon: "magnifyingglass") { runQuick(.search) { showSearch = true } }
        case .kitchenToolbox:
            drawerButton("Kitchen Toolbox", icon: "wrench.and.screwdriver") { activeHomeSheet = .toolbox }
        case .stats:
            drawerButton("Stats", icon: "chart.bar") { runQuick(.stats) { showStats = true } }
        case .databases:
            drawerButton("Databases", icon: "cylinder.split.1x2") { runQuick(.databases) { showDatabases = true } }
        case .usageInsights:
            drawerButton("Usage Insights", icon: "chart.pie") { activeHomeSheet = .usageInsights }
        }
    }

    private func drawerButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 16))
                    .foregroundStyle(session.themeTextColor.opacity(0.65)).frame(width: 26)
                Text(title).font(.system(size: 15, weight: .medium, design: .serif)).foregroundStyle(session.themeTextColor)
                Spacer()
            }.padding(.vertical, 8).padding(.horizontal, 14)
        }
        .buttonStyle(.plain)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets(top: 2, leading: 4, bottom: 2, trailing: 4))
    }

    private func drawerHeader(_ t: String) -> some View {
        SectionHeader(text: t, padded: false)
    }
}

// MARK: - Quick Menu environment
extension View {
    func withQuickMenu(
        onScanReceipt:  @escaping () -> Void = {},
        onAddItems:     @escaping () -> Void = {},
        onShoppingList: @escaping () -> Void = {}
    ) -> some View {
        self.environment(\.quickMenuCallbacks, QuickMenuCallbacks(
            onScanReceipt:  onScanReceipt,
            onAddItems:     onAddItems,
            onShoppingList: onShoppingList))
    }
}

struct QuickMenuCallbacks {
    var onScanReceipt:  () -> Void = {}
    var onAddItems:     () -> Void = {}
    var onShoppingList: () -> Void = {}
}
struct QuickMenuCallbacksKey: EnvironmentKey {
    static let defaultValue = QuickMenuCallbacks()
}
extension EnvironmentValues {
    var quickMenuCallbacks: QuickMenuCallbacks {
        get { self[QuickMenuCallbacksKey.self] }
        set { self[QuickMenuCallbacksKey.self] = newValue }
    }
}

// MARK: - Build Info Footer
// Standalone view placed below Settings — not inside any DisclosureGroup.
// Updates automatically from BuildConfig — no manual sync required.
struct BuildInfoFooter: View {
    @Environment(AppSession.self) var session
    @State private var showWhatsNew = false

    var body: some View {
        Button {
            showWhatsNew = true
            HapticManager.select()
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.stockedCharcoal.opacity(0.65))
                        .frame(width: 28, height: 28)
                    Image(systemName: "hammer.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.stockedGold)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(BuildConfig.displayLabel)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced))
                        .foregroundStyle(session.themeTextColor.opacity(0.75))
                    Text("Tap to see what's new")
                        .font(.system(size: 10))
                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.25))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showWhatsNew) {
            AppVersionView().environment(session)
        }
    }
}


// MARK: - Household Sync Sheet
struct HouseholdSyncSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @State private var codeInput = ""
    @State private var showCopied = false
    // CloudKit cross-account sharing (Session 2).
    // Identity-driven share payload — .sheet(item:) presents reliably on the first tap,
    // unlike a Bool + optional pair that can race.
    private struct SharePayload: Identifiable { let id = UUID(); let share: CKShare }
    @State private var sharePayload: SharePayload? = nil
    @State private var ckBusy = false
    @State private var ckJoinCode = ""
    @State private var ckJoining = false

    private var generatedCode: String {
        // Stable per-device code based on device name hash
        let base = UIDevice.current.name.hash
        return String(abs(base) % 900000 + 100000)   // 6-digit code
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 16)

                Text("Household Sync")
                    .font(.system(size: 20, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor).padding(.bottom, 8)
                Text("Share your pantry and grocery list with family — each person uses their own Apple ID.")
                    .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    .multilineTextAlignment(.center).padding(.horizontal, 28).padding(.bottom, 24)

                VStack(spacing: 16) {
                    // ── CloudKit: share across DIFFERENT Apple IDs ──────────────
                    VStack(spacing: 10) {
                        Text("SHARE ACROSS ACCOUNTS")
                            .font(.system(size: 10, weight: .bold)).tracking(1.2)
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                        Text("Invite people with their own Apple ID. They tap your link to join — no shared account needed.")
                            .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                            .multilineTextAlignment(.center)
                        Button {
                            Task {
                                ckBusy = true
                                if let share = await HouseholdCloudKit.shared.createHousehold() {
                                    // Push our current pantry into the shared zone first.
                                    await HouseholdCloudKit.shared.push(store: session.guestStore)
                                    sharePayload = SharePayload(share: share)
                                }
                                ckBusy = false
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if ckBusy { ProgressView().scaleEffect(0.7) }
                                Image(systemName: "person.2.badge.plus")
                                Text(ckBusy ? "Preparing…" : "Create & Share Household")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .foregroundStyle(Color.stockedWhite)
                            .padding(.horizontal, 18).padding(.vertical, 12)
                            .frame(maxWidth: .infinity)
                            .background(session.themeButtonColor)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        .disabled(ckBusy)
                        if let err = HouseholdCloudKit.shared.lastError {
                            Text(err).font(.system(size: 11)).foregroundStyle(.red.opacity(0.7))
                                .multilineTextAlignment(.center)
                        }

                        // Owner's shareable code (the "both" join option).
                        if let code = HouseholdCloudKit.shared.joinCode {
                            Divider().background(session.themeTextColor.opacity(0.1))
                            VStack(spacing: 4) {
                                Text("OR SHARE THIS CODE")
                                    .font(.system(size: 9, weight: .bold)).tracking(1.2)
                                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                                HStack(spacing: 10) {
                                    Text(code)
                                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                                        .foregroundStyle(Color.stockedGold)
                                    Button {
                                        UIPasteboard.general.string = code
                                        HapticManager.light()
                                    } label: {
                                        Image(systemName: "doc.on.doc").font(.system(size: 16))
                                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                                    }.buttonStyle(.plain)
                                }
                            }
                        }

                        // Join an account-based household by code.
                        Divider().background(session.themeTextColor.opacity(0.1))
                        VStack(spacing: 6) {
                            Text("JOIN BY CODE")
                                .font(.system(size: 9, weight: .bold)).tracking(1.2)
                                .foregroundStyle(session.themeTextColor.opacity(0.4))
                            HStack(spacing: 10) {
                                TextField("8-character code", text: $ckJoinCode)
                                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(session.themeTextColor)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.characters)
                                    .padding(10)
                                    .background(session.isDarkMode ? Color.stockedCharcoal.opacity(0.3) : Color.stockedWhite.opacity(0.5))
                                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                                Button {
                                    Task {
                                        ckJoining = true
                                        _ = await HouseholdCloudKit.shared.joinByCode(ckJoinCode, into: session.guestStore)
                                        ckJoining = false
                                        if HouseholdCloudKit.shared.state == .member { dismiss() }
                                    }
                                } label: {
                                    if ckJoining { ProgressView().scaleEffect(0.7).frame(width: 44) }
                                    else {
                                        Text("Join").font(.system(size: 13, weight: .bold))
                                            .foregroundStyle(Color.stockedWhite)
                                            .padding(.horizontal, 16).padding(.vertical, 10)
                                            .background(ckJoinCode.count >= 6 ? session.themeButtonColor : Color.stockedCharcoal.opacity(0.3))
                                            .clipShape(Capsule())
                                    }
                                }
                                .buttonStyle(.plain)
                                .disabled(ckJoinCode.count < 6 || ckJoining)
                            }
                        }
                    }
                    .padding(16)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))

                    // Sync status + leave — only shown once you're actually in a CloudKit household.
                    if HouseholdCloudKit.shared.state == .member
                        || HouseholdCloudKit.shared.state == .owner {
                        let sync = SharedPantrySync.shared
                        VStack(spacing: 10) {
                            HStack(spacing: 8) {
                                if sync.isSyncing {
                                    ProgressView().scaleEffect(0.7)
                                    Text("Syncing…")
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(session.themeTextColor.opacity(0.7))
                                } else {
                                    Image(systemName: "checkmark.icloud")
                                        .font(.system(size: 14)).foregroundStyle(Color.stockedGreen)
                                    Text(sync.lastSyncedAt == nil
                                         ? "Not synced yet"
                                         : "Last synced \(StockedFormatters.shortDateTime.string(from: sync.lastSyncedAt!))")
                                        .font(.system(size: 12))
                                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                                }
                                Spacer()
                                Button {
                                    Task { await HouseholdCloudKit.shared.syncNow(store: session.guestStore) }
                                } label: {
                                    Text("Sync now")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.stockedWhite)
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(session.themeButtonColor)
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .disabled(sync.isSyncing)
                            }
                            Text(HouseholdCloudKit.shared.state == .owner
                                 ? "You own this household."
                                 : "You've joined a shared household.")
                                .font(.system(size: 11))
                                .foregroundStyle(session.themeTextColor.opacity(0.4))
                        }
                        .padding(14)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))

                        Button {
                            session.householdCode = ""
                            SharedPantrySync.shared.leave()
                            HouseholdCloudKit.shared.leaveHousehold()
                        } label: {
                            Text("Leave Household")
                                .font(.system(size: 13)).foregroundStyle(.red.opacity(0.7))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                Spacer()
            }
        }
        .presentationDetents([.large])
        .onAppear { codeInput = session.householdCode }
        .dismissKeyboardOnTap()
        .sheet(item: $sharePayload) { payload in
            CloudSharingView(share: payload.share,
                             container: CKContainer(identifier: "iCloud.Stocked"))
        }
    }
}

#Preview { MainTabView().environment(AppSession()) }

// MARK: - Preferred Store pop-out (Row 5)
// Combines the preferred-store picker with the nearby-stores finder (moved here from the
// Grocery tab) into a single focused screen.
struct PreferredStorePopout: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    private let stores = [
        "Walmart","Target","Kroger","Safeway","Amazon Fresh",
        "Costco","Sam's Club","BJ's Wholesale",
        "Whole Foods","Trader Joe's","Sprouts","The Fresh Market",
        "Earth Fare","Bristol Farms","Gelson's",
        "Aldi","Lidl","WinCo Foods","Grocery Outlet","Save-A-Lot","Food 4 Less",
        "H-E-B","Publix","Winn-Dixie","Piggly Wiggly","Food Lion",
        "Brookshire's","Ingles Markets","Bi-Lo",
        "Meijer","Hy-Vee","Schnucks","Jewel-Osco","Mariano's",
        "Aldi (Midwest)","Dillons","Baker's","Ruler Foods",
        "Wegmans","Stop & Shop","Market Basket","ShopRite","Giant",
        "Price Chopper","Hannaford","Stew Leonard's","Key Food",
        "Fred Meyer","QFC","Vons","Ralphs","Stater Bros",
        "Smart & Final","Bashas'","Fry's Food","Winco Foods",
        "Instacart","DoorDash Grocery","Shipt","FreshDirect"
    ]

    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 8)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Current selection
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SHOPPING AT")
                            .font(.system(size: 10, weight: .bold)).tracking(1)
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                        Text(session.preferredStore)
                            .font(.system(size: 22, weight: .bold, design: .serif))
                            .foregroundStyle(Color.stockedGold)
                    }.padding(.horizontal, 20).padding(.top, 8)

                    // Picker grid
                    VStack(alignment: .leading, spacing: 8) {
                        Text("CHOOSE A STORE")
                            .font(.system(size: 10, weight: .bold)).tracking(1)
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                            .padding(.horizontal, 20)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(stores, id: \.self) { store in
                                Button {
                                    withAnimation(.spring(response: 0.2)) { session.preferredStore = store }
                                } label: {
                                    Text(store)
                                        .font(.system(size: 12, weight: session.preferredStore == store ? .bold : .regular))
                                        .foregroundStyle(session.preferredStore == store ? Color.stockedCharcoal : session.themeTextColor)
                                        .frame(maxWidth: .infinity).padding(.vertical, 9)
                                        .background(session.preferredStore == store ? Color.stockedGold : Color.stockedWhite.opacity(0.3))
                                        .clipShape(Capsule())
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 20)
                    }

                    // Nearby stores (moved here from the Grocery tab)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("NEARBY STORES")
                            .font(.system(size: 10, weight: .bold)).tracking(1)
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                            .padding(.horizontal, 20)
                        GroceryStoreFinderView()
                            .environment(session)
                            .frame(minHeight: 320)
                    }
                    .padding(.bottom, 24)
                }
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Preferred Store")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(Color.stockedGold)
                }
            }
        }
    }
}


// MARK: - #245 — Help Center (mockup Settings row)
struct HelpCenterSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    helpSection("Adding items")
                    helpRow(icon: "viewfinder", title: "Scan receipts",
                            detail: "Open Scan Receipt from Home or the drawer, photograph your receipt, and confirm the detected items — they're added with store context automatically. Store-brand abbreviations (like HEB and Walmart) are expanded for you.")
                    helpRow(icon: "barcode.viewfinder", title: "Scan barcodes",
                            detail: "Point the camera at any product barcode to look it up and add it. No camera? Type the barcode number in manually.")
                    helpRow(icon: "scribble.variable", title: "Quick Update",
                            detail: "Tell Stocked what changed in plain words — \"used the milk, bought eggs\" — and review the proposed changes before they apply. Works offline with a built-in parser.")
                    helpRow(icon: "plus.circle", title: "Add by hand",
                            detail: "Add an item directly from Inventory, set its quantity, unit, zone, and use-by date, or browse the ingredient list to add common staples fast.")

                    helpSection("Your kitchen")
                    helpRow(icon: "refrigerator", title: "Zones & expiry",
                            detail: "Items live in Fridge, Pantry, Freezer, or Staples. Expiring items surface on Home, in the Daily Brief, and in the Kitchen Report. Swipe any row to delete it.")
                    helpRow(icon: "exclamationmark.triangle", title: "Low-stock alerts",
                            detail: "Running low on a staple? Stocked flags it and can add it to your grocery list so you never run out mid-recipe.")
                    helpRow(icon: "cart", title: "Grocery list",
                            detail: "The list groups by store section. Check items off as you shop, then move everything checked into your pantry from the ··· menu.")
                    helpRow(icon: "chart.pie", title: "Reports & insights",
                            detail: "The Kitchen Report and Usage Insights show what you have, what's expiring, and how you cook over time — all computed on your device.")

                    helpSection("Cooking & recipes")
                    helpRow(icon: "sparkles", title: "Discover recipes",
                            detail: "Browse recipes pulled from many free and keyed sources. Everything you fetch is saved to your on-device library, so search and suggestions work offline too.")
                    helpRow(icon: "globe", title: "Recipe & drink sources",
                            detail: "Turn sources on or off in Recipe Sources, add your own websites, and explore the Drinks section. Keyed sources (like Spoonacular or Suggestic) appear once configured.")
                    helpRow(icon: "flame", title: "Cook tab",
                            detail: "Cook Now, Cook Later, Build Around Food, and Match My Mood help you decide what to make from what you already have. Finishing a cook updates your inventory.")
                    helpRow(icon: "wrench.and.screwdriver", title: "Kitchen Toolbox",
                            detail: "A hub of tools for planning, conversions, cooking, and reference — reachable from the drawer under Kitchen Tools.")
                    helpRow(icon: "heart", title: "Apple Health",
                            detail: "Opt in from Preferences to log a cooked meal's nutrition to Apple Health. It's off until you enable it, and never shared with anyone else.")

                    helpSection("Sharing & backup")
                    helpRow(icon: "person.2", title: "Household Sync",
                            detail: "Share your kitchen with the people you live with — inventory, the weekly meal planner, and leftovers stay in step across everyone's devices, even after going offline. Set per-member permissions.")
                    helpRow(icon: "icloud", title: "iCloud & Auto Backup",
                            detail: "Your kitchen syncs through your own private iCloud. Storage & Auto Backup lets you back up on demand and choose how often auto-backup runs.")
                    helpRow(icon: "arrow.left.arrow.right.square", title: "Transfer Kitchen",
                            detail: "Export your data to move to a new device, or import a previously exported kitchen.")

                    helpSection("Reminders")
                    helpRow(icon: "sun.max", title: "Daily Brief",
                            detail: "A once-a-day summary of what's expiring, what to cook, and what to restock. Tap it on Home to expand.")
                    helpRow(icon: "bell.badge", title: "Reminders",
                            detail: "Schedule expiry, cook, and prep reminders — and low-stock nudges — from Notifications in Settings.")

                    helpSection("Reference")
                    helpRow(icon: "books.vertical", title: "Databases",
                            detail: "Look up ingredient substitutions, receipt abbreviations, ingredient info, and kitchen tips from the Databases hub in the drawer.")

                    helpSection("Account & privacy")
                    helpRow(icon: "person.crop.circle", title: "Sign in or guest",
                            detail: "Use Sign in with Apple to sync and share, or continue as a guest on just this device. Your Apple name and email stay on your device.")
                    helpRow(icon: "lock.shield", title: "Your data is yours",
                            detail: "No ads and no tracking. Data lives on your device and in your own iCloud. Erase All Data (device and iCloud together) or Delete Account are available in Settings.")

                    Text("Need more help? Reach out from your App Store review or the support link on the product page.")
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .padding(.top, 6)
                }
                .padding(20)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Help Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func helpSection(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .bold, design: .serif))
            .foregroundStyle(session.themeTextColor.opacity(0.45))
            .tracking(0.8)
            .padding(.top, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func helpRow(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color.stockedGold.opacity(0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: icon).font(.system(size: 14)).foregroundStyle(Color.stockedGold)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14.5, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text(detail).font(.system(size: 13))
                    .foregroundStyle(session.themeTextColor.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }
}


