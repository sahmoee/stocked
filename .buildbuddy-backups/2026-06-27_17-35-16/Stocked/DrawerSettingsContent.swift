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
    var onEditProfile: (() -> Void)? = nil
    var onNotifications: (() -> Void)? = nil

    @State private var editingName      = false
    @State private var nameInput        = ""
    @State private var showClearAlert   = false
    @State private var showStorePopout    = false

    @State private var showSignOutAlert = false
    @State private var showDeleteAccountAlert = false
    @State private var showTransfer     = false
    @State private var activeAccountSheet: AccountSheet? = nil   // identity-driven: no open/close race
    @State private var showDataStorage  = false   // Checkpoint 1 verification & backup

    private enum AccountSheet: Int, Identifiable {
        case editProfile, notifications
        var id: Int { rawValue }
    }
    @State private var showHouseholdSheet = false

    private var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        switch h { case 5..<12: return "Good Morning"; case 12..<17: return "Good Afternoon"; default: return "Good Evening" }
    }

    var body: some View {
        Group {
            // ── ONBOARDING ──────────────────────────────────────────
            // The onboarding quiz (dietary style, skill, cuisines). Renamed from
            // "Edit Profile" to "Adjust onboarding" so it reads as re-running the
            // onboarding questions rather than editing an account profile.
            Section {
                Button {
                    if let onEditProfile { onEditProfile() }
                    else { activeAccountSheet = .editProfile }
                } label: {
                    settingsRow(icon: "checklist", color: .orange,
                                title: "Adjust onboarding", detail: "Dietary style, skill, cuisines & more")
                }
                .listRowBackground(Color.clear)
            } header: { sectionHeader("Onboarding") }

            // ── ACCOUNT ─────────────────────────────────────────────
            Section {
                if editingName {
                    HStack {
                        TextField("Display name", text: $nameInput)
                            .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                            .font(.system(size: 14, design: .serif))
                        Button("Save") {
                            session.displayName = nameInput.trimmingCharacters(in: .whitespaces)
                            editingName = false
                        }.foregroundStyle(Color.stockedGold).font(.system(size: 13, weight: .bold))
                        Button("Cancel") { editingName = false }
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                            .font(.system(size: 13))
                    }
                    .listRowBackground(Color.stockedGold.opacity(0.08))
                } else {
                    Button {
                        nameInput = session.displayName; editingName = true
                    } label: {
                        settingsRow(icon: "person.text.rectangle.fill", color: Color.stockedInfo,
                                    title: "Change Name", detail: session.userName)
                    }
                    .listRowBackground(Color.clear)
                }

                // Preferred Store (pop-out picker).
                Button { showStorePopout = true } label: {
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
                .sheet(isPresented: $showStorePopout) { PreferredStorePopout().environment(session) }
            } header: { sectionHeader("Account") }

            // ── APPEARANCE ──────────────────────────────────────────
            Section {
                // Dark Mode
                HStack {
                    Label("Dark Mode", systemImage: "moon.fill")
                        .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { session.isDarkMode },
                        set: { session.isDarkMode = $0 }
                    ))
                    .tint(Color.stockedGold)
                    .labelsHidden()
                }
                .listRowBackground(Color.clear)

                // Measurement system (US / Metric) — affects recipe scaling display
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
            } header: { sectionHeader("Appearance") }

            // ── NOTIFICATIONS ───────────────────────────────────────
            // All notification controls in one place. "Notifications" opens the daily-brief /
            // expiry / prep scheduling screen; the toggle below is the separate low-stock alert.
            Section {
                Button {
                    if let onNotifications { onNotifications() }
                    else { activeAccountSheet = .notifications }
                } label: {
                    settingsRow(icon: "bell.badge.fill", color: Color.stockedGold,
                                title: "Reminders & Daily Brief", detail: "Schedule expiry, cook & prep reminders")
                }
                .listRowBackground(Color.clear)

                Toggle(isOn: Binding(get: { session.notificationsEnabled }, set: { session.notificationsEnabled = $0 })) {
                    Label("Low Stock Alerts", systemImage: "exclamationmark.bubble.fill")
                        .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                }.tint(Color.stockedGold).listRowBackground(Color.clear)
            } header: { sectionHeader("Notifications") }

            // ── KITCHEN ─────────────────────────────────────────────
            Section {
                Toggle(isOn: Binding(get: { session.autoAddMissingToGrocery }, set: { session.autoAddMissingToGrocery = $0 })) {
                    Label("Auto-add Missing to Grocery", systemImage: "cart.badge.plus")
                        .font(.system(size: 14, design: .serif)).foregroundStyle(session.themeTextColor)
                }.tint(Color.stockedGold).listRowBackground(Color.clear)

                Button { showTransfer = true } label: {
                    settingsRow(icon: "arrow.left.arrow.right.square.fill", color: Color.stockedGold,
                                title: "Transfer Kitchen", detail: "Export or import data")
                }.listRowBackground(Color.clear)
                .sheet(isPresented: $showTransfer) { KitchenTransferView().environment(session) }
            } header: { sectionHeader("Kitchen") }

            // ── SHARING ─────────────────────────────────────────────
            // Single household entry point (previously duplicated as a drawer "Household"
            // button and a "Household Sync" settings row).
            Section {
                Button {
                    showHouseholdSheet = true
                } label: {
                    settingsRow(icon: "person.2.fill", color: Color.stockedInfo,
                                title: "Household Sync",
                                detail: session.householdCode.isEmpty ? "Share pantry with family" : "Code: \(session.householdCode)",
                                trailingSystemImage: nil)
                }
                .listRowBackground(Color.clear)
                .sheet(isPresented: $showHouseholdSheet) {
                    HouseholdHomeView().environment(session)
                }
            } header: { sectionHeader("Sharing") }

            // ── BACKUP & STORAGE ────────────────────────────────────
            Section {
                Button {
                    // Use the session-retained manager so its async result + status/error
                    // survive (a throwaway local manager gets deallocated, hiding failures).
                    session.transferManager.backupToiCloud(store: session.guestStore)
                } label: {
                    settingsRow(icon: "icloud.fill", color: Color.stockedInfo,
                                title: "Backup to iCloud",
                                detail: "Last backup: \(session.transferManager.lastBackupDate)")
                }.listRowBackground(Color.clear)

                // Live backup/restore status — so a CloudKit failure is visible instead of
                // looking like a silent success.
                if !session.transferManager.errorMessage.isEmpty {
                    Label(session.transferManager.errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                        .listRowBackground(Color.clear)
                } else if !session.transferManager.statusMessage.isEmpty {
                    Label(session.transferManager.statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.stockedGreen)
                        .listRowBackground(Color.clear)
                }

                // ── Backup Frequency ─────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    Label("Auto-Backup", systemImage: "clock.arrow.2.circlepath")
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

                // Data & Storage — migration check + backup/restore (Checkpoint 1).
                Button { showDataStorage = true } label: {
                    Label("Data & Storage", systemImage: "internaldrive")
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                }.listRowBackground(Color.clear)
            } header: { sectionHeader("Backup & Storage") }

            // ── ACCOUNT MANAGEMENT ──────────────────────────────────
            Section {
                Button { showClearAlert = true } label: {
                    HStack(spacing: 12) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 7).fill(Color.red).frame(width: 28, height: 28)
                            Image(systemName: "trash.fill").font(.system(size: 13)).foregroundStyle(.white)
                        }
                        Text("Clear All App Data").font(.system(size: 14, design: .serif)).foregroundStyle(.red)
                        Spacer()
                    }
                }.listRowBackground(Color.clear)
                .alert("Erase All Data?", isPresented: $showClearAlert) {
                    Button("Erase Everything", role: .destructive) { session.signOut(clearData: true) }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Permanently deletes your pantry, grocery list, meal history, recipes, settings, and iCloud backup. Cannot be undone.")
                }

                Button { showSignOutAlert = true } label: {
                    Text(session.accountType == .guest ? "Exit Guest Mode" : "Sign Out")
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(session.themeTextColor.opacity(0.6))
                }.listRowBackground(Color.clear)
                .alert(session.accountType == .guest ? "Exit Guest Mode?" : "Sign Out?", isPresented: $showSignOutAlert) {
                    if session.accountType == .guest {
                        Button("Keep Data") { session.signOut(clearData: false) }
                        Button("Erase & Exit", role: .destructive) { session.signOut(clearData: true) }
                    } else {
                        Button("Sign Out", role: .destructive) { session.signOut() }
                    }
                    Button("Cancel", role: .cancel) {}
                }

                // Delete Account — required by App Store for accounts with identifiable data.
                // Only shown for signed-in (Apple) accounts; guests have no account to delete.
                if session.accountType != .guest {
                    Button { showDeleteAccountAlert = true } label: {
                        Text("Delete Account")
                            .font(.system(size: 14, design: .serif))
                            .foregroundStyle(.red)
                    }.listRowBackground(Color.clear)
                    .alert("Delete Account?", isPresented: $showDeleteAccountAlert) {
                        Button("Delete Account", role: .destructive) { session.deleteAccount() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This permanently deletes your account and all associated data — pantry, grocery list, meal history, saved recipes, settings, iCloud backup, and any shared household. This cannot be undone.")
                    }
                }
            } header: { sectionHeader("Account Management") }
        }
        .sheet(isPresented: $showDataStorage) {
            DataStorageView().environment(session)
        }
        .sheet(item: $activeAccountSheet) { sheet in
            switch sheet {
            case .editProfile:
                QuizEditView().environment(session)
            case .notifications:
                NavigationStack { DailyBriefNotificationSettingsView().environment(session) }
            }
        }
    }


    // MARK: - Helpers
    private func sectionHeader(_ t: String) -> some View {
        Text(t).font(.system(size: 10, weight: .bold)).tracking(1)
            .foregroundStyle(session.themeTextColor.opacity(0.35))
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
            "exportDate":  ISO8601DateFormatter().string(from: Date()),
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
        Text(t).font(.system(size: 10, weight: .bold)).tracking(1)
            .foregroundStyle(session.themeTextColor.opacity(0.35))
    }
}

// MARK: - Drawer Content (iPhone)
// Quick actions the drawer can request; MainTabView performs them after closing the drawer.
enum DrawerQuickAction { case scanReceipt, scanBarcode, quickUpdate, addItems, search, stats, databases, editProfile, notifications, household, activity }

struct DrawerContent: View {
    @State private var showHelpCenter = false      // #245 — mockup Settings rows
    @State private var showUsageInsights = false    // #20 — local usage insights
    @State private var showProfileHub = false      // chef row → Profile & Preferences hub
    @State private var showLogoutConfirm = false
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

            // Profile — the chef icon chosen during onboarding, sitting directly under
            // the Stocked wordmark. Opens a Profile & Preferences hub (edit profile,
            // preferences, household, notifications) — these moved here from the
            // drawer's Settings list.
            Button {
                showProfileHub = true
            } label: {
                HStack(spacing: 12) {
                    Text(session.guestStore.cookingProfile.avatarEmoji)
                        .font(.system(size: 30))
                        .frame(width: 46, height: 46)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 1) {
                        Text(session.userName)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(session.themeTextColor)
                        Text("View profile & preferences")
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }
                .padding(.horizontal, 22).padding(.vertical, 10)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)
            .padding(.bottom, 8)

            Divider()

            // Full scrollable list — mockup drawer: Kitchen Tools / Insights / Settings.
            // Tab navigation lives in the tab bar; the drawer is tools + settings only.
            List {
                Section {
                    drawerButton("Scan Receipt",  icon: "camera.viewfinder")     { runQuick(.scanReceipt) { showReceipt = true } }
                    drawerButton("Add Items",     icon: "plus.circle")           { runQuick(.addItems)    { showAddItems = true } }
                    drawerButton("Quick Update",  icon: "list.clipboard")        { runQuick(.quickUpdate) {} }
                    drawerButton("Import Recipe", icon: "square.and.arrow.down") {
                        closeAndRun {
                            // Switch to the Recipes tab, then flag the URL import for it
                            // to consume once on appear. (A NotificationCenter trigger
                            // looped — the handler re-fired on re-render and re-presented
                            // the sheet endlessly. The flag is consumed exactly once.)
                            session.pendingRecipeImport = true
                            NotificationCenter.default.post(name: .stockedSwitchTab, object: StockedTab.recipes)
                        }
                    }
                    drawerButton("Global Search", icon: "magnifyingglass")       { runQuick(.search)      { showSearch = true } }
                } header: { drawerHeader("Kitchen Tools") }

                Section {
                    drawerButton("Stats",     icon: "chart.bar")          { runQuick(.stats)     { showStats = true } }
                    drawerButton("Databases", icon: "cylinder.split.1x2") { runQuick(.databases) { showDatabases = true } }
                    drawerButton("Usage Insights", icon: "chart.pie")     { showUsageInsights = true }
                } header: { drawerHeader("Insights") }

                Section {
                    drawerButton("Help Center",   icon: "questionmark.circle") { showHelpCenter = true }
                    drawerButton(session.accountType == .guest ? "Exit Guest Mode" : "Log Out",
                                 icon: "rectangle.portrait.and.arrow.right") { showLogoutConfirm = true }
                } header: { drawerHeader("Settings") }

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
        .sheet(isPresented: $showHelpCenter) {
            HelpCenterSheet().environment(session)   // #245
        }
        .sheet(isPresented: $showUsageInsights) {
            NavigationStack { UsageInsightsView().environment(session) }   // #20
        }
        // Profile & Preferences hub — opened from the chef row. Shows the full, expanded
        // settings list inline (categorised), so everything lives on one screen instead of
        // behind a separate "Preferences" sub-sheet. Edit Profile / Notifications are now
        // sections within SettingsContent (no duplicate rows here).
        .sheet(isPresented: $showProfileHub) {
            NavigationStack {
                List {
                    Section {
                        HStack(spacing: 12) {
                            Text(session.guestStore.cookingProfile.avatarEmoji)
                                .font(.system(size: 34))
                                .frame(width: 54, height: 54)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                                .clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(session.userName)
                                    .font(.system(size: 18, weight: .bold))
                                    .foregroundStyle(session.themeTextColor)
                                Text(session.accountType == .guest ? "Guest" : "Signed in")
                                    .font(.system(size: 12))
                                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                            }
                            Spacer()
                        }
                        .padding(.vertical, 4)
                        .listRowBackground(Color.clear)
                    }

                    // Full expanded settings — uses SettingsContent's own internal sheets
                    // (onEditProfile / onNotifications left nil), which present fine from a
                    // normal sheet's List (the flash issue is specific to the drawer's
                    // recycling List, not this one).
                    SettingsContent(onEditProfile: nil, onNotifications: nil)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(session.themeBgColor.ignoresSafeArea())
                .navigationTitle("Profile & Preferences")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showProfileHub = false }
                            .foregroundStyle(Color.stockedGold)
                    }
                }
            }
            .environment(session)
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
        Text(t).font(.system(size: 10, weight: .bold)).tracking(1)
            .foregroundStyle(session.themeTextColor.opacity(0.35))
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
    @State private var ckShare: CKShare? = nil
    @State private var showShareSheet = false
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
                                    ckShare = share
                                    showShareSheet = true
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
        .sheet(isPresented: $showShareSheet) {
            if let share = ckShare {
                CloudSharingView(share: share,
                                 container: CKContainer(identifier: "iCloud.Stocked"))
            }
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
                VStack(alignment: .leading, spacing: 16) {
                    helpRow(icon: "viewfinder", title: "Scanning receipts",
                            detail: "Open Scan Receipt from Home or the drawer, photograph your receipt, and confirm the detected items — they're added with store context automatically.")
                    helpRow(icon: "scribble.variable", title: "Quick Update",
                            detail: "Tell Stocked what changed in plain words — \"used the milk, bought eggs\" — and review the proposed changes before they apply.")
                    helpRow(icon: "refrigerator", title: "Zones & expiry",
                            detail: "Items live in Fridge, Pantry, Freezer, or Staples. Expiring items surface on Home, in the Daily Brief, and in the Kitchen Report.")
                    helpRow(icon: "cart", title: "Grocery list",
                            detail: "The list groups by store section. Check items off as you shop, then move everything checked into your pantry from the ··· menu.")
                    helpRow(icon: "person.2", title: "Household Sync",
                            detail: "Share your kitchen with the people you live with — inventory and lists stay in step across devices.")
                    Text("Need more help? Reach out from your App Store review or the support link on the product page.")
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .padding(.top, 4)
                }
                .padding(20)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Help Center")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
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
