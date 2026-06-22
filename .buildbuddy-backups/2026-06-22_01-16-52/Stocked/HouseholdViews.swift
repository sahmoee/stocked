// HouseholdViews.swift — the household experience UI (mockup-styled).
//
// 12 screens from the mockup, wired to HouseholdSync (Worker-backed; replaces CloudKit CKShare)
// and the new HouseholdModels (activity, members, invites, notification prefs). New screens use
// the mockup's clean cream/serif styling; where the app already has components/flows
// (the actual shared grocery list lives in GroceryListView), these screens link to them.
//
// Entry point: HouseholdHomeView() — the intro screen that routes to everything else.

import SwiftUI
import UIKit

// MARK: - Shared style helpers (mockup look)

private enum HHStyle {
    static let corner: CGFloat = 16
    static let cardCorner: CGFloat = 14
}

private extension View {
    /// Charcoal pill primary button (mockup's "Create Your Household", "Join Household", etc.)
    func hhPrimaryButton() -> some View {
        self.font(.system(size: 16, weight: .semibold))
            .foregroundStyle(Color.stockedWhite)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Color.stockedCharcoal, in: RoundedRectangle(cornerRadius: HHStyle.corner))
    }
}

private struct HHScreen<Content: View>: View {
    @Environment(AppSession.self) private var session
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) { content }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - 1. Household intro / value prop

struct HouseholdHomeView: View {
    @Environment(AppSession.self) private var session
    @State private var household = HouseholdSync.shared

    var body: some View {
        NavigationStack {
            // If already in a household, go straight to the members/settings hub; else show intro.
            Group {
                if household.state == .owner || household.state == .member {
                    HouseholdMembersView()
                } else {
                    introContent
                }
            }
        }
    }

    private var introContent: some View {
        HHScreen("Household") {
            VStack(spacing: 8) {
                Text("Household")
                    .font(.system(size: 24, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text("Share your pantry and grocery list with the people you trust.")
                    .font(.system(size: 13))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
            .padding(.top, 16).padding(.bottom, 28)

            VStack(spacing: 20) {
                valueRow("person.2", "Share & Collaborate", "Work together on lists and recipes")
                valueRow("clock", "See Everyone's Activity", "Stay up to date in real time")
                valueRow("slider.horizontal.3", "Personalized Preferences", "Customize what you see & how you're notified")
                valueRow("lock.shield", "Safe & Secure", "Only people you invite can join")
            }
            .padding(.bottom, 36)

            NavigationLink { HouseholdCreateView() } label: {
                Text("Create Your Household").hhPrimaryButton()
            }
            .padding(.bottom, 14)

            NavigationLink { HouseholdJoinView() } label: {
                Text("I have an invite code")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
            }
            .padding(.bottom, 24)
        }
    }

    private func valueRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color.stockedGold)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(session.themeTextColor)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }
}

// MARK: - 2. Create Household (success + invite code)

struct HouseholdCreateView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var household = HouseholdSync.shared
    @State private var creating = false
    @State private var shareItems: [Any?] = []
    @State private var showShare = false

    var body: some View {
        HHScreen("Create Household") {
            if household.joinCode == nil {
                // Pre-create prompt.
                VStack(spacing: 18) {
                    Image(systemName: "house.circle")
                        .font(.system(size: 52)).foregroundStyle(Color.stockedGold)
                        .padding(.top, 30)
                    Text("Create your household")
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("You'll get an invite code to share with family. They join, and your pantry and grocery list sync together.")
                        .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.55))
                        .multilineTextAlignment(.center).padding(.horizontal, 16)
                    Button {
                        Task { creating = true; _ = await household.createHousehold(); creating = false }
                    } label: {
                        Text(creating ? "Creating…" : "Create Household").hhPrimaryButton()
                    }
                    .disabled(creating)
                    .padding(.top, 10)
                }
            } else {
                successContent
            }
        }
    }

    private var successContent: some View {
        VStack(spacing: 0) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56)).foregroundStyle(Color.stockedGreen)
                .padding(.top, 24).padding(.bottom, 14)
            Text("Household created!")
                .font(.system(size: 20, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text("Invite others to join by sharing this code.")
                .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.55))
                .multilineTextAlignment(.center).padding(.top, 4).padding(.bottom, 22)

            // Invite code card
            VStack(spacing: 12) {
                Text("Your Invite Code")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                Text(household.joinCode ?? "—")
                    .font(.system(size: 30, weight: .bold, design: .monospaced))
                    .foregroundStyle(session.themeTextColor)
                    .tracking(2)
                Text("Code expires in 7 days")
                    .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                Button {
                    shareItems = ["Join my Stocked. kitchen with code \(household.joinCode ?? "")" as Any?]
                    showShare = !shareItems.isEmpty
                } label: {
                    Label("Share Code", systemImage: "square.and.arrow.up")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Color.stockedCharcoal, in: RoundedRectangle(cornerRadius: 12))
                }
                .padding(.top, 4)
            }
            .padding(18)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
            .padding(.bottom, 20)

            Button("Done") { dismiss() }
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.stockedError)
                .padding(.bottom, 24)
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
    }
}

// MARK: - 3. Join Household (enter code)

struct HouseholdJoinView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var household = HouseholdSync.shared
    @State private var code = ""
    @State private var joining = false
    @State private var message: String?

    var body: some View {
        HHScreen("Join Household") {
            Text("Enter the invite code shared by your household member.")
                .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.55))
                .multilineTextAlignment(.center).padding(.top, 16).padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 6) {
                Text("Enter 8-character code")
                    .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.5))
                TextField("ABCD2345", text: $code)
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .keyboardType(.asciiCapable)
                    .foregroundStyle(session.themeTextColor)
                    .tracking(2)
                    .padding(.vertical, 14).padding(.horizontal, 16)
                    .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 12))
                    .onChange(of: code) { _, newValue in
                        // Strip anything that isn't a code character (A to Z, 2 to 9) as the user
                        // types, so iOS smart quotes / autocorrect can't wrap or alter the code.
                        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
                        let cleaned = String(newValue.uppercased().filter { allowed.contains($0) }.prefix(8))
                        if cleaned != newValue { code = cleaned }
                    }
            }
            .padding(.bottom, 18)

            Button {
                Task {
                    joining = true
                    let ok = await household.joinByCode(code, into: session.guestStore)
                    joining = false
                    message = ok ? nil : "Couldn't find a household with that code."
                    if ok { dismiss() }
                }
            } label: {
                Text(joining ? "Joining…" : "Join Household").hhPrimaryButton()
            }
            .disabled(joining || code.trimmingCharacters(in: .whitespaces).count < 4)

            if let message {
                Text(message).font(.system(size: 12)).foregroundStyle(Color.stockedError).padding(.top, 12)
            }
        }
    }
}

// MARK: - 5. Household Members (hub)

struct HouseholdMembersView: View {
    @Environment(AppSession.self) private var session
    @State private var household = HouseholdSync.shared
    @State private var members: [HouseholdMember] = []
    @State private var loading = true

    var body: some View {
        HHScreen("Household Members") {
            HStack { Text("People in your household")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(session.themeTextColor.opacity(0.5))
                Spacer() }
            .padding(.top, 8).padding(.bottom, 10)

            VStack(spacing: 0) {
                if loading {
                    ProgressView().padding(.vertical, 20)
                } else {
                    ForEach(members) { m in
                        NavigationLink { HouseholdMemberProfileView(member: m) } label: { memberRow(m) }
                            .buttonStyle(.plain)
                        if m.id != members.last?.id { Divider().padding(.leading, 60) }
                    }
                }
                Divider().padding(.leading, 60)
                NavigationLink { HouseholdShareCodeView() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 17)).foregroundStyle(Color.stockedGold).frame(width: 40, height: 40)
                            .background(Color.stockedGold.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Add Member").font(.system(size: 15, weight: .semibold)).foregroundStyle(session.themeTextColor)
                            Text("Invite with code or link").font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                        Spacer()
                    }.padding(.vertical, 10)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))

            // Household Settings links
            HStack { Text("Household Settings")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(session.themeTextColor.opacity(0.5))
                Spacer() }
            .padding(.top, 22).padding(.bottom, 10)

            VStack(spacing: 0) {
                NavigationLink { HouseholdActivityView() } label: { settingRow("clock.arrow.circlepath", "Household Activity") }.buttonStyle(.plain)
                Divider().padding(.leading, 50)
                NavigationLink { HouseholdSettingsView() } label: { settingRow("gearshape", "Edit Household Info") }.buttonStyle(.plain)
                Divider().padding(.leading, 50)
                NavigationLink { HouseholdNotificationsView() } label: { settingRow("bell", "Manage Notifications") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
            .padding(.bottom, 24)
        }
        .task {
            household.myDisplayName = session.userName
            members = await household.fetchMembers()
            loading = false
        }
    }

    private func memberRow(_ m: HouseholdMember) -> some View {
        HStack(spacing: 12) {
            avatar(m.name)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name).font(.system(size: 15, weight: .semibold)).foregroundStyle(session.themeTextColor)
                Text(m.role.label).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
            if m.isMe {
                Text("You").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.stockedGold)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.stockedGold.opacity(0.12), in: Capsule())
            } else {
                Image(systemName: "ellipsis").foregroundStyle(session.themeTextColor.opacity(0.4))
            }
        }.padding(.vertical, 10)
    }

    private func avatar(_ name: String) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .font(.system(size: 16, weight: .bold)).foregroundStyle(Color.stockedWhite)
            .frame(width: 40, height: 40).background(Color.stockedGold, in: Circle())
    }

    private func settingRow(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Color.stockedGold).frame(width: 26)
            Text(title).font(.system(size: 15)).foregroundStyle(session.themeTextColor)
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.3))
        }.padding(.vertical, 12)
    }
}

// MARK: - 6. Household Activity (feed)

struct HouseholdActivityView: View {
    @Environment(AppSession.self) private var session
    @State private var household = HouseholdSync.shared
    @State private var events: [HouseholdActivity] = []
    @State private var filter: HouseholdActivity.Category = .all
    @State private var loading = true

    private var filtered: [HouseholdActivity] {
        filter == .all ? events : events.filter { $0.kind.category == filter }
    }

    var body: some View {
        HHScreen("Household Activity") {
            Text("All recent activity in your household")
                .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                .padding(.top, 6).padding(.bottom, 14)

            // Filter chips
            HStack(spacing: 8) {
                ForEach(HouseholdActivity.Category.allCases, id: \.self) { cat in
                    Button { filter = cat } label: {
                        Text(cat.label).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(filter == cat ? Color.stockedWhite : session.themeTextColor.opacity(0.6))
                            .padding(.horizontal, 14).padding(.vertical, 7)
                            .background(filter == cat ? Color.stockedCharcoal : session.themeCardColor, in: Capsule())
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(.bottom, 16)

            if loading {
                ProgressView().padding(.vertical, 30)
            } else if filtered.isEmpty {
                Text("No activity yet.").font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.4)).padding(.vertical, 30)
            } else {
                VStack(spacing: 0) {
                    ForEach(filtered) { e in
                        activityRow(e)
                        if e.id != filtered.last?.id { Divider().padding(.leading, 56) }
                    }
                }
                .padding(.horizontal, 14)
                .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
                .padding(.bottom, 24)
            }
        }
        .task {
            household.myDisplayName = session.userName
            events = await household.fetchActivity()
            loading = false
        }
    }

    private func activityRow(_ e: HouseholdActivity) -> some View {
        HStack(spacing: 12) {
            Text(String(e.actorName.prefix(1)).uppercased())
                .font(.system(size: 14, weight: .bold)).foregroundStyle(Color.stockedWhite)
                .frame(width: 36, height: 36).background(Color.stockedGold, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                (Text(e.actorName).font(.system(size: 13, weight: .semibold))
                 + Text(" \(e.kind.verb) ").font(.system(size: 13))
                 + Text(e.phrase).font(.system(size: 13, weight: .semibold)))
                    .foregroundStyle(session.themeTextColor)
                Text(e.date, style: .relative).font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
            }
            Spacer()
        }.padding(.vertical, 11)
    }
}

// MARK: - 7. Member Profile

struct HouseholdMemberProfileView: View {
    @Environment(AppSession.self) private var session
    let member: HouseholdMember
    var body: some View {
        HHScreen("Member Profile") {
            VStack(spacing: 8) {
                Text(String(member.name.prefix(1)).uppercased())
                    .font(.system(size: 30, weight: .bold)).foregroundStyle(Color.stockedWhite)
                    .frame(width: 84, height: 84).background(Color.stockedGold, in: Circle())
                    .padding(.top, 16)
                Text(member.name).font(.system(size: 20, weight: .bold, design: .serif)).foregroundStyle(session.themeTextColor)
                Text(member.role.label).font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.5))
            }.padding(.bottom, 22)

            HStack { Text("Preferences").font(.system(size: 12, weight: .medium)).foregroundStyle(session.themeTextColor.opacity(0.5)); Spacer() }
                .padding(.bottom, 10)
            VStack(spacing: 0) {
                prefRow("Dietary Preferences", member.dietaryPreference ?? "Not set")
                Divider(); prefRow("Favorite Ingredients", member.favoriteIngredients.isEmpty ? "Not set" : member.favoriteIngredients.joined(separator: ", "))
                Divider(); prefRow("Dislikes", member.dislikes.isEmpty ? "Not set" : member.dislikes.joined(separator: ", "))
                Divider(); prefRow("Allergies", member.allergies.isEmpty ? "Not set" : member.allergies.joined(separator: ", "))
            }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))

            if !member.isMe {
                Button(role: .destructive) { } label: {
                    Text("Remove from Household").font(.system(size: 14, weight: .medium)).foregroundStyle(Color.stockedError)
                }.padding(.top, 20)
            }
        }
    }
    private func prefRow(_ title: String, _ value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(session.themeTextColor)
                Text(value).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.3))
        }.padding(.vertical, 12)
    }
}

// MARK: - 8. Share Code

struct HouseholdShareCodeView: View {
    @Environment(AppSession.self) private var session
    @State private var household = HouseholdSync.shared
    @State private var shareItems: [Any?] = []
    @State private var showShare = false
    @State private var regenerating = false

    private var code: String { household.joinCode ?? "—" }

    var body: some View {
        HHScreen("Share Code") {
            Text("Invite someone to your household")
                .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.55))
                .padding(.top, 14).padding(.bottom, 18)

            Text(code)
                .font(.system(size: 30, weight: .bold, design: .monospaced)).tracking(2)
                .foregroundStyle(session.themeTextColor)
                .frame(maxWidth: .infinity).padding(.vertical, 20)
                .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 12))
            Text("Code expires in 7 days").font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                .padding(.top, 6).padding(.bottom, 18)

            VStack(spacing: 0) {
                shareOption("message.fill", "Messages", Color.stockedGreen)
                Divider().padding(.leading, 52)
                shareOption("phone.bubble.fill", "WhatsApp", Color.stockedGreen)
                Divider().padding(.leading, 52)
                shareOption("envelope.fill", "Email", Color.stockedInfo)
                Divider().padding(.leading, 52)
                shareOption("doc.on.doc.fill", "Copy Code", session.themeTextColor.opacity(0.6))
            }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
            .padding(.bottom, 18)

            Button {
                Task {
                    regenerating = true
                    _ = await household.regenerateCode()
                    regenerating = false
                }
            } label: {
                Text(regenerating ? "Regenerating…" : "Regenerate Code")
                    .font(.system(size: 14, weight: .medium)).foregroundStyle(Color.stockedError)
            }
            .disabled(regenerating || household.state != .owner)
            .padding(.bottom, 24)
            if household.state != .owner {
                Text("Only the household owner can regenerate the code.")
                    .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.45))
                    .padding(.bottom, 12)
            }
        }
        .sheet(isPresented: $showShare) { ShareSheet(items: shareItems) }
    }
    private func shareOption(_ icon: String, _ title: String, _ color: Color) -> some View {
        Button {
            if title == "Copy Code" {
                UIPasteboard.general.string = code
            } else {
                shareItems = ["Join my Stocked. kitchen with code \(code)" as Any?]; showShare = true
            }
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 16)).foregroundStyle(color).frame(width: 38, height: 38)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                Text(title).font(.system(size: 15)).foregroundStyle(session.themeTextColor)
                Spacer()
            }.padding(.vertical, 8)
        }.buttonStyle(.plain)
    }
}

// MARK: - 9. Household Settings

struct HouseholdSettingsView: View {
    @Environment(AppSession.self) private var session
    @State private var household = HouseholdSync.shared
    @State private var confirmLeave = false

    var body: some View {
        HHScreen("Household Settings") {
            VStack(spacing: 0) {
                NavigationLink { HouseholdNameEditView() } label: {
                    settingsRow("Household Name", "My Stocked. Kitchen")
                }.buttonStyle(.plain)
                Divider()
                NavigationLink { HouseholdShareCodeView() } label: {
                    settingsRow("Invite Code", household.joinCode ?? "—", subtitle: "Share or regenerate")
                }.buttonStyle(.plain)
                Divider()
                NavigationLink { HouseholdNotificationsView() } label: {
                    settingsRow("Notifications", "Customize what you're notified about")
                }.buttonStyle(.plain)
                Divider()
                NavigationLink { HouseholdActivityView() } label: {
                    settingsRow("Household Activity", "See who did what")
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
            .padding(.top, 10).padding(.bottom, 18)

            VStack(spacing: 0) {
                Button { confirmLeave = true } label: {
                    destructiveRow("Leave Household", "You will need a new invite to rejoin")
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
            .padding(.bottom, 24)
        }
        .alert("Leave this household?", isPresented: $confirmLeave) {
            Button("Leave", role: .destructive) { household.leaveHousehold() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("You'll stop seeing the shared pantry and grocery list. You can rejoin with a new invite code.") }
    }
    private func settingsRow(_ title: String, _ value: String, subtitle: String? = nil) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(session.themeTextColor)
                Text(subtitle ?? value).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.3))
        }.padding(.vertical, 12)
    }
    private func destructiveRow(_ title: String, _ subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.stockedError)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
        }.padding(.vertical, 12)
    }
}

// MARK: - 4. Customize Notifications

struct HouseholdNotificationsView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var prefs = HouseholdNotificationPrefs.load()
    @State private var savedConfirm = false

    var body: some View {
        HHScreen("Customize Notifications") {
            Text("Choose what you want to be notified about in this household.")
                .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.55))
                .padding(.top, 8).padding(.bottom, 16)

            group("List & Inventory") {
                toggle("Items added to grocery list", $prefs.groceryAdded)
                toggle("Items removed from grocery list", $prefs.groceryRemoved)
                toggle("Items added to inventory", $prefs.inventoryAdded)
                toggle("Items updated in inventory", $prefs.inventoryUpdated)
                toggle("Low stock alerts", $prefs.lowStock)
            }
            group("Recipes") {
                toggle("New recipes added", $prefs.recipesAdded)
                toggle("Recipes updated", $prefs.recipesUpdated)
            }
            group("Reminders") {
                toggle("Reminders created or changed", $prefs.remindersChanged)
            }

            Button {
                prefs.save()
                savedConfirm = true
            } label: { Text(savedConfirm ? "Saved ✓" : "Save Preferences").hhPrimaryButton() }
                .padding(.top, 8).padding(.bottom, 24)
        }
        // Persist immediately on any change so a toggle "sticks" even without tapping Save.
        .onChange(of: prefs) { _, newValue in
            newValue.save()
            savedConfirm = false
        }
    }
    @ViewBuilder private func group<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack { Text(title).font(.system(size: 12, weight: .medium)).foregroundStyle(session.themeTextColor.opacity(0.5)); Spacer() }
            .padding(.top, 14).padding(.bottom, 8)
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
    }
    private func toggle(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(label).font(.system(size: 14)).foregroundStyle(session.themeTextColor)
        }
        .tint(Color.stockedGreen)
        .padding(.vertical, 9)
    }
}

// MARK: - 10. Pending Invites

struct HouseholdPendingInvitesView: View {
    @Environment(AppSession.self) private var session
    @State private var invites: [HouseholdInvite] = []
    var body: some View {
        HHScreen("Pending Invites") {
            HStack { Text("Invites you've sent").font(.system(size: 12, weight: .medium)).foregroundStyle(session.themeTextColor.opacity(0.5)); Spacer() }
                .padding(.top, 8).padding(.bottom, 10)
            if invites.isEmpty {
                Text("No pending invites.").font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.4)).padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(invites) { inv in
                        HStack(spacing: 12) {
                            Text(String(inv.inviteeName.prefix(1))).font(.system(size: 14, weight: .bold)).foregroundStyle(Color.stockedWhite)
                                .frame(width: 36, height: 36).background(Color.stockedGold, in: Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(inv.inviteeName).font(.system(size: 15, weight: .semibold)).foregroundStyle(session.themeTextColor)
                                Text("Invited \(inv.sentAt, style: .date)").font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                            }
                            Spacer()
                            Text(inv.isExpired ? "Expired" : "Pending").font(.system(size: 12, weight: .medium))
                                .foregroundStyle(inv.isExpired ? Color.stockedError : Color.stockedGold)
                        }.padding(.vertical, 10)
                        if inv.id != invites.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
            }
            Text("Invite links and codes expire in 7 days.")
                .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                .padding(.top, 14)
        }
    }
}

// MARK: - 11. What's New in Household

struct HouseholdWhatsNewView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        HHScreen("What's New in Household") {
            VStack(spacing: 20) {
                feature("clock", "Activity Feed", "See what everyone is doing")
                feature("person.2", "Member Profiles", "Customize preferences for better suggestions")
                feature("checklist", "Smarter Lists", "Collaborate in real time")
                feature("sparkles", "More Coming Soon", "We're always improving")
            }.padding(.top, 20).padding(.bottom, 28)
            Button { dismiss() } label: { Text("Got It").hhPrimaryButton() }.padding(.bottom, 24)
        }
    }
    private func feature(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Color.stockedGold).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(session.themeTextColor)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
        }
    }
}

// MARK: - 12. Need Help?

struct HouseholdHelpView: View {
    @Environment(AppSession.self) private var session
    private let faqs = [
        "How do I invite someone?",
        "Can I change the invite code?",
        "How do notifications work?",
        "How do I leave a household?"
    ]
    var body: some View {
        HHScreen("Need Help?") {
            HStack { Text("Common Questions").font(.system(size: 12, weight: .medium)).foregroundStyle(session.themeTextColor.opacity(0.5)); Spacer() }
                .padding(.top, 8).padding(.bottom, 10)
            VStack(spacing: 0) {
                ForEach(faqs, id: \.self) { q in
                    HStack {
                        Text(q).font(.system(size: 14)).foregroundStyle(session.themeTextColor)
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.3))
                    }.padding(.vertical, 13)
                    if q != faqs.last { Divider() }
                }
            }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
            .padding(.bottom, 24)
        }
    }
}

// MARK: - Household Name editor (from Settings)

struct HouseholdNameEditView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var name = UserDefaults.standard.string(forKey: "hh_display_name") ?? "My Stocked. Kitchen"

    var body: some View {
        HHScreen("Household Name") {
            Text("This name is shown to everyone in your household.")
                .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.55))
                .padding(.top, 12).padding(.bottom, 18)
            TextField("Household name", text: $name)
                .font(.system(size: 17))
                .foregroundStyle(session.themeTextColor)
                .padding(.vertical, 14).padding(.horizontal, 16)
                .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 18)
            Button {
                UserDefaults.standard.set(name, forKey: "hh_display_name")
                dismiss()
            } label: { Text("Save").hhPrimaryButton() }
                .padding(.bottom, 24)
        }
    }
}
