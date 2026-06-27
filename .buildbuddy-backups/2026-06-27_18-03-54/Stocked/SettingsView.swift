// SettingsView.swift — Full preferences with Kitchen Transfer section
import SwiftUI
import Combine

struct SettingsView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    @State private var nameInput      = ""
    @State private var editingName    = false
    @State private var showSignOut    = false
    @State private var showClear      = false
    @State private var showTransfer   = false
    @State private var notifications  = true
    @State private var defaultServ    = 2.0
    @State private var showQuizRedo   = false
    @State private var showQuizConfirm = false

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                // Header
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                    }
                    Spacer()
                    Text("Stocked.")
                        .font(.system(size: 26, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Color.clear.frame(width: 24)
                }
                .padding(.horizontal, 20).padding(.top, 52).padding(.bottom, 8)

                Text("Settings")
                    .font(.system(size: 14, weight: .light))
                    .foregroundStyle(session.themeTextColor.opacity(0.45))
                    .padding(.bottom, 20)

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {

                        // ── Profile ─────────────────────────────────────
                        settingSection("Profile") {
                            settingRow {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text(session.displayName.isEmpty ? "Guest" : session.displayName)
                                        .font(.system(size: 17, weight: .bold, design: .serif))
                                        .foregroundStyle(session.themeTextColor)
                                    Text(session.accountType == .guest ? "Guest Account" : "Registered Account")
                                        .font(.system(size: 12))
                                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                                }
                                Spacer()
                                Button("Change") { nameInput = session.displayName; editingName = true }
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.stockedGold)
                            }
                        }

                        // ── Kitchen ──────────────────────────────────────
                        settingSection("Kitchen") {
                            NavigationLink(destination: KitchenTransferView().environment(session)) {
                                settingNavRow(
                                    icon: "arrow.left.arrow.right.square.fill",
                                    iconColor: Color.stockedGold,
                                    title: "Transfer Kitchen",
                                    subtitle: "Export, import, backup & QR transfer"
                                )
                            }
                            .buttonStyle(.plain)

                            Divider().padding(.leading, 52)

                            settingButtonRow(
                                icon: "square.and.arrow.up.fill",
                                iconColor: Color.stockedInfo,
                                title: "Export Kitchen",
                                subtitle: "Save kitchen as a .stocked file"
                            ) {
                                showTransfer = true
                            }

                            Divider().padding(.leading, 52)

                            settingButtonRow(
                                icon: "square.and.arrow.down.fill",
                                iconColor: Color.stockedSuccess,
                                title: "Import Kitchen",
                                subtitle: "Load from file or iCloud"
                            ) {
                                showTransfer = true
                            }

                            Divider().padding(.leading, 52)

                            settingButtonRow(
                                icon: "icloud.fill",
                                iconColor: Color.stockedInfo,
                                title: "Backup to iCloud",
                                subtitle: "Store privately in your iCloud"
                            ) {
                                showTransfer = true
                            }
                        }

                        // ── Preferences ──────────────────────────────────
                        settingSection("Preferences") {
                            settingRow {
                                Text("Notifications")
                                    .font(.system(size: 15)).foregroundStyle(session.themeTextColor)
                                Spacer()
                                Toggle("", isOn: $notifications).labelsHidden().tint(Color.stockedGold)
                            }
                            Divider().padding(.leading, 16)
                            settingRow {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text("Default Servings")
                                            .font(.system(size: 15)).foregroundStyle(session.themeTextColor)
                                        Spacer()
                                        Text("\(Int(defaultServ))")
                                            .font(.system(size: 15, weight: .bold))
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                    Slider(value: $defaultServ, in: 1...8, step: 1)
                                        .tint(Color.stockedCharcoal)
                                }
                            }
                        }

                        // ── Security ─────────────────────────────────────
                        // ── Personality Quiz ──────────────────────────────
                        settingSection("Personalisation") {
                            settingRow {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("Cooking Profile")
                                        .font(.system(size: 15)).foregroundStyle(session.themeTextColor)
                                    let p = session.guestStore.cookingProfile
                                    Text(p.completedSetup ? "\(p.skillLevel) · \(p.dietaryStyle)" : "Not completed")
                                        .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.45))
                                }
                                Spacer()
                                Button("Edit") { showQuizRedo = true }
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.stockedGold)
                            }
                        }
                        .sheet(isPresented: $showQuizRedo) {
                            QuizEditView().environment(session)
                        }

                        // ── Data ─────────────────────────────────────────
                        settingSection("Data") {
                            settingRow {
                                Text("Clear App Cache")
                                    .font(.system(size: 15)).foregroundStyle(session.themeTextColor)
                                Spacer()
                                Button("Clear") {
                                    URLCache.shared.removeAllCachedResponses()
                                }
                                .font(.system(size: 14)).foregroundStyle(Color.stockedGold)
                            }
                            if session.accountType == .guest {
                                Divider().padding(.leading, 16)
                                settingRow {
                                    Button("Clear All Guest Data") { showClear = true }
                                        .font(.system(size: 15)).foregroundStyle(.red)
                                    Spacer()
                                }
                            }
                        }

                        // ── Account ──────────────────────────────────────
                        settingSection("Account") {
                            settingRow {
                                Button(session.accountType == .guest ? "Exit Guest Mode" : "Sign Out") {
                                    showSignOut = true
                                }
                                .font(.system(size: 15, weight: .semibold)).foregroundStyle(.red)
                                Spacer()
                            }
                        }

                        // ── About ─────────────────────────────────────────
                        settingSection("About") {
                            settingRow {
                                Text("Version 1.0").font(.system(size: 15)).foregroundStyle(session.themeTextColor)
                                Spacer()
                                Text("Stocked.").font(.system(size: 13, design: .serif))
                                    .foregroundStyle(session.themeTextColor.opacity(0.35))
                            }
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.bottom, 40)
                }
            }
        }
        // Kitchen Transfer full screen
        .fullScreenCover(isPresented: $showTransfer) {
            KitchenTransferView().environment(session)
        }
        // Edit name sheet
        .sheet(isPresented: $editingName) {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(spacing: 24) {
                    Capsule().fill(Color.stockedCharcoal.opacity(0.15)).frame(width: 40, height: 4).padding(.top, 14)
                    Text("Change Name")
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    TextField("Your name", text: $nameInput)
                    .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                        .font(.system(size: 16)).foregroundStyle(session.themeTextColor)
                        .padding(14).background(Color.stockedWhite.opacity(0.45))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)).padding(.horizontal, 28)
                    HStack(spacing: 16) {
                        Button("Cancel") { editingName = false }
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                        Button("Save") {
                            let n = nameInput.trimmingCharacters(in: .whitespaces)
                            session.displayName = n.isEmpty ? "Guest" : n
                            if session.accountType == .guest { session.guestStore.displayName = session.displayName }
                            editingName = false
                        }
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.stockedWhite)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    }
                    Spacer()
                }
            }
            .presentationDetents([.height(290)])
        }
        // Sign out
        .alert(session.accountType == .guest ? "Exit Guest Mode?" : "Sign Out?",
               isPresented: $showSignOut) {
            if session.accountType == .guest {
                Button("Keep Data") { session.signOut(clearData: false) }
                Button("Erase & Exit", role: .destructive) { session.signOut(clearData: true) }
            } else {
                Button("Sign Out", role: .destructive) { session.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if session.accountType == .guest {
                Text("\"Erase & Exit\" permanently deletes all pantry, grocery, and session data including iCloud backups. \"Keep Data\" saves your data for next time.")
            }
        }
        // Clear data — nuclear wipe
        .alert("Erase All Data?", isPresented: $showClear) {
            Button("Erase Everything", role: .destructive) {
                session.signOut(clearData: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your entire pantry, grocery list, meal history, recipes, price records, settings, and sign-in session. iCloud backups for this app will also be removed. This cannot be undone.")
        }
    }

    // MARK: - Layout helpers
    func settingSection<V: View>(_ title: String, @ViewBuilder content: () -> V) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).tracking(0.8)
                .foregroundStyle(session.themeTextColor.opacity(0.38))
                .padding(.bottom, 8).padding(.top, 22).padding(.horizontal, 4)
            VStack(spacing: 0) { content() }
                .background(Color.stockedWhite.opacity(0.28)).clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    func settingRow<V: View>(@ViewBuilder content: () -> V) -> some View {
        HStack { content() }.padding(.horizontal, 16).padding(.vertical, 14)
    }

    func settingNavRow(icon: String, iconColor: Color, title: String, subtitle: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm).fill(iconColor).frame(width: 32, height: 32)
                Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(session.themeTextColor)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.45))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12))
                .foregroundStyle(session.themeTextColor.opacity(0.3))
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
    }

    func settingButtonRow(icon: String, iconColor: Color, title: String, subtitle: String,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm).fill(iconColor).frame(width: 32, height: 32)
                    Image(systemName: icon).font(.system(size: 14)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(session.themeTextColor)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.45))
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 12))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        SettingsView().environment(AppSession())
    }
}
