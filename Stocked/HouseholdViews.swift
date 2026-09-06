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
        self.scaledFont(16, weight: .semibold)
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
                    .scaledFont(24, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                Text("Share your pantry and grocery list with the people you trust.")
                    .scaledFont(13)
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
                    .scaledFont(14, weight: .medium)
                    .foregroundStyle(session.themeTextColor.opacity(0.6))
            }
            .padding(.bottom, 24)
        }
    }

    private func valueRow(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .scaledFont(18)
                .foregroundStyle(Color.stockedGold)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(15, weight: .semibold).foregroundStyle(session.themeTextColor)
                Text(subtitle).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
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
                        .scaledFont(52).foregroundStyle(Color.stockedGold)
                        .padding(.top, 30)
                    Text("Create your household")
                        .scaledFont(20, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text("You'll get an invite code to share with family. They join, and your pantry and grocery list sync together.")
                        .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.55))
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
                .scaledFont(56).foregroundStyle(Color.stockedGreen)
                .padding(.top, 24).padding(.bottom, 14)
            Text("Household created!")
                .scaledFont(20, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            Text("Invite others to join by sharing this code.")
                .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.55))
                .multilineTextAlignment(.center).padding(.top, 4).padding(.bottom, 22)

            // Invite code card
            VStack(spacing: 12) {
                Text("Your Invite Code")
                    .scaledFont(11, weight: .medium)
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                Text(household.joinCode ?? "—")
                    .scaledFont(30, weight: .bold, design: .monospaced)
                    .foregroundStyle(session.themeTextColor)
                    .tracking(2)
                Text("Code expires in 7 days")
                    .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.4))
                Button {
                    shareItems = ["Join my Stocked. kitchen with code \(household.joinCode ?? "")" as Any?]
                    showShare = !shareItems.isEmpty
                } label: {
                    Label("Share Code", systemImage: "square.and.arrow.up")
                        .scaledFont(15, weight: .semibold)
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
                .scaledFont(15, weight: .semibold)
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
                .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.55))
                .multilineTextAlignment(.center).padding(.top, 16).padding(.bottom, 24)

            VStack(alignment: .leading, spacing: 6) {
                Text("Enter 8-character code")
                    .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.5))
                TextField("ABCD2345", text: $code)
                    .scaledFont(22, weight: .semibold, design: .monospaced)
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
                Text(message).scaledFont(12).foregroundStyle(Color.stockedError).padding(.top, 12)
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
                .scaledFont(12, weight: .medium).foregroundStyle(session.themeTextColor.opacity(0.5))
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
                            .scaledFont(17).foregroundStyle(Color.stockedGold).frame(width: 40, height: 40)
                            .background(Color.stockedGold.opacity(0.12), in: Circle())
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Add Member").scaledFont(15, weight: .semibold).foregroundStyle(session.themeTextColor)
                            Text("Invite with code or link").scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                        Spacer()
                    }.padding(.vertical, 10)
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))

            // Household Settings links
            HStack { Text("Household Settings")
                .scaledFont(12, weight: .medium).foregroundStyle(session.themeTextColor.opacity(0.5))
                Spacer() }
            .padding(.top, 22).padding(.bottom, 10)

            VStack(spacing: 0) {
                // #4 — single entry point. Activity, Notifications, Name, Invite, and What Syncs
                // all live inside Household Settings, so there's exactly one path to each.
                NavigationLink { HouseholdSettingsView() } label: { settingRow("gearshape", "Household Settings") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
            .padding(.bottom, 24)
        }
        .task {
            // #1 — don't clobber a name the user set themselves (Settings → Your Name).
            if !household.nameIsCustom {
                household.myDisplayName = session.isNamedUser ? session.userName
                    : (session.effectiveName)   // guests: use their entered/effective name, never the device name ("iPhone")
            }
            members = await household.fetchMembers()
            loading = false
            presence = await household.fetchPresence()   // #11 last-active per member
        }
    }

    // #11 — name → seconds since that member's device last synced.
    @State private var presence: [String: TimeInterval] = [:]
    private func presenceLabel(_ name: String) -> (String, Color)? {
        guard let ago = presence[name] else { return nil }
        if ago < 90 { return ("Active now", Color.stockedGreen) }
        if ago < 3600 { return ("Active \(Int(ago / 60))m ago", Color.stockedGold) }
        if ago < 86400 { return ("Active \(Int(ago / 3600))h ago", Color.stockedGold) }
        return ("Active \(Int(ago / 86400))d ago", Color.stockedCharcoal.opacity(0.4))
    }

    private func memberRow(_ m: HouseholdMember) -> some View {
        HStack(spacing: 12) {
            avatar(m.name)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.name).scaledFont(15, weight: .semibold).foregroundStyle(session.themeTextColor)
                Text(m.displayLabel).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
                if let p = presenceLabel(m.name) {
                    HStack(spacing: 4) {
                        Circle().fill(p.1).frame(width: 6, height: 6)
                        Text(p.0).scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                }
            }
            Spacer()
            if m.isMe {
                Text("You").scaledFont(11, weight: .semibold).foregroundStyle(Color.stockedGold)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.stockedGold.opacity(0.12), in: Capsule())
            } else {
                Image(systemName: "ellipsis").foregroundStyle(session.themeTextColor.opacity(0.4))
            }
        }.padding(.vertical, 10)
    }

    private func avatar(_ name: String) -> some View {
        Text(String(name.prefix(1)).uppercased())
            .scaledFont(16, weight: .bold).foregroundStyle(Color.stockedWhite)
            .frame(width: 40, height: 40).background(Color.stockedGold, in: Circle())
    }

    private func settingRow(_ icon: String, _ title: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).scaledFont(16).foregroundStyle(Color.stockedGold).frame(width: 26)
            Text(title).scaledFont(15).foregroundStyle(session.themeTextColor)
            Spacer()
            Image(systemName: "chevron.right").scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.3))
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
                .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
                .padding(.top, 6).padding(.bottom, 14)

            // Filter chips
            HStack(spacing: 8) {
                ForEach(HouseholdActivity.Category.allCases, id: \.self) { cat in
                    Button { filter = cat } label: {
                        Text(cat.label).scaledFont(13, weight: .medium)
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
                Text("No activity yet.").scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.4)).padding(.vertical, 30)
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
            // #1 — don't clobber a name the user set themselves (Settings → Your Name).
            if !household.nameIsCustom {
                household.myDisplayName = session.isNamedUser ? session.userName
                    : (session.effectiveName)   // guests: use their entered/effective name, never the device name ("iPhone")
            }
            events = await household.fetchActivity()
            loading = false
        }
    }

    private func activityRow(_ e: HouseholdActivity) -> some View {
        HStack(spacing: 12) {
            Text(String(e.actorName.prefix(1)).uppercased())
                .scaledFont(14, weight: .bold).foregroundStyle(Color.stockedWhite)
                .frame(width: 36, height: 36).background(Color.stockedGold, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text("**\(e.actorName)** \(e.kind.verb) **\(e.phrase)**")
                    .scaledFont(13)
                    .foregroundStyle(session.themeTextColor)
                Text(e.date, style: .relative).scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.45))
            }
            Spacer()
        }.padding(.vertical, 11)
    }
}

// MARK: - 7. Member Profile

struct HouseholdMemberProfileView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    let member: HouseholdMember
    @State private var household = HouseholdSync.shared
    @State private var selectedRole: HouseholdMember.Role = .adult
    @State private var customLabel: String = ""
    @State private var selectedPermissions: Set<HouseholdPermission> = []
    @State private var saving = false
    @State private var removing = false
    @State private var confirmRemoval = false
    @State private var saveMessage: String? = nil

    private var canManageMembers: Bool { household.can(.manageMembers) }

    var body: some View {
        HHScreen("Member Profile") {
            VStack(spacing: 8) {
                Text(String(member.name.prefix(1)).uppercased())
                    .scaledFont(30, weight: .bold).foregroundStyle(Color.stockedWhite)
                    .frame(width: 84, height: 84).background(Color.stockedGold, in: Circle())
                    .padding(.top, 16)
                Text(member.name).scaledFont(20, weight: .bold, design: .serif).foregroundStyle(session.themeTextColor)
                Text(member.displayLabel).scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.5))
            }.padding(.bottom, 22)

            // ── Member-management permission: access level + custom label ─────────
            if canManageMembers && !member.isMe {
                HStack { Text("Access Level").scaledFont(12, weight: .medium).foregroundStyle(session.themeTextColor.opacity(0.5)); Spacer() }
                    .padding(.bottom, 10)
                VStack(alignment: .leading, spacing: 14) {
                    // Role picker (kid/teen/adult/manager). Owner isn't assignable here.
                    Picker("Level", selection: $selectedRole) {
                        ForEach([HouseholdMember.Role.kid, .teen, .adult, .manager], id: \.self) { r in
                            Text(r.label).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)

                    // What this level can do — plain-language summary so the owner knows.
                    Text(permissionSummary(selectedRole))
                        .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.6))

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Custom label (optional)").scaledFont(12, weight: .medium).foregroundStyle(session.themeTextColor.opacity(0.5))
                        TextField("e.g. Mom, Big Sis", text: $customLabel)
                            .scaledFont(15).foregroundStyle(session.themeTextColor)
                            .padding(10)
                            .background(session.themeBgColor, in: RoundedRectangle(cornerRadius: 8))
                    }

                    // Fine-grained grants and denials cover every collaborative capability. The
                    // Worker evaluates these after role defaults, with explicit denial winning.
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Fine-tune permissions").scaledFont(12, weight: .medium).foregroundStyle(session.themeTextColor.opacity(0.5))
                        ForEach(HouseholdPermission.allCases.filter { $0 != .transferOwnership }, id: \.self) { permission in
                            Toggle(permissionLabel(permission), isOn: permissionBinding(permission))
                                .scaledFont(14).tint(Color.stockedGold)
                        }
                    }
                    .padding(.top, 4)

                    Button {
                        Task { await saveRole() }
                    } label: {
                        HStack {
                            if saving { ProgressView().tint(Color.stockedWhite) }
                            Text(saving ? "Saving…" : "Save Access Level")
                                .scaledFont(15, weight: .semibold).foregroundStyle(Color.stockedWhite)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Color.stockedGold, in: RoundedRectangle(cornerRadius: 10))
                    }
                    .disabled(saving)

                    if let saveMessage {
                        Text(saveMessage).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.6))
                    }
                }
                .padding(14)
                .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
                .padding(.bottom, 22)
            }

            HStack { Text("Preferences").scaledFont(12, weight: .medium).foregroundStyle(session.themeTextColor.opacity(0.5)); Spacer() }
                .padding(.bottom, 10)
            VStack(spacing: 0) {
                prefRow("Dietary Preferences", member.dietaryPreference ?? "Not set")
                Divider(); prefRow("Favorite Ingredients", member.favoriteIngredients.isEmpty ? "Not set" : member.favoriteIngredients.joined(separator: ", "))
                Divider(); prefRow("Dislikes", member.dislikes.isEmpty ? "Not set" : member.dislikes.joined(separator: ", "))
                Divider(); prefRow("Allergies", member.allergies.isEmpty ? "Not set" : member.allergies.joined(separator: ", "))
            }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))

            if canManageMembers && !member.isMe {
                Button(role: .destructive) { confirmRemoval = true } label: {
                    Text(removing ? "Removing…" : "Remove from Household")
                        .scaledFont(14, weight: .medium).foregroundStyle(Color.stockedError)
                }
                .disabled(removing)
                .padding(.top, 20)
            }
        }
        .onAppear {
            selectedRole = (member.role == .owner || member.role == .member) ? .adult : member.role
            customLabel = member.customLabel ?? ""
            selectedPermissions = member.effectivePermissions
        }
        .onChange(of: selectedRole) { _, r in
            selectedPermissions = r.defaultPermissions
        }
        .alert("Remove \(member.name)?", isPresented: $confirmRemoval) {
            Button("Remove", role: .destructive) { Task { await removeMember() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They will lose access to this shared household and will need a new invite to rejoin.")
        }
    }

    private func permissionSummary(_ r: HouseholdMember.Role) -> String {
        switch r {
        case .kid:     return "Can view the pantry and lists. Cannot add, edit, or remove items."
        case .teen:    return "Can add and edit items. Cannot remove items or manage members."
        case .adult:   return "Can add, edit, and remove items. Cannot manage members."
        case .manager: return "Can add, edit, remove items, and manage members."
        default:       return ""
        }
    }

    private func saveRole() async {
        saving = true; saveMessage = nil
        let label = customLabel.trimmingCharacters(in: .whitespaces)
        let defaults = selectedRole.defaultPermissions
        let grants = selectedPermissions.subtracting(defaults)
        let denials = defaults.subtracting(selectedPermissions)
        let ok = await household.setMemberRole(memberId: member.id, role: selectedRole,
                                               label: label.isEmpty ? "" : label,
                                               permissionGrants: grants,
                                               permissionDenials: denials)
        saving = false
        saveMessage = ok ? "Saved. Changes apply on their next sync." : (household.lastError ?? "Couldn't save.")
    }

    private func permissionBinding(_ permission: HouseholdPermission) -> Binding<Bool> {
        Binding(
            get: { selectedPermissions.contains(permission) },
            set: { enabled in
                if enabled { selectedPermissions.insert(permission) }
                else { selectedPermissions.remove(permission) }
            })
    }

    private func permissionLabel(_ permission: HouseholdPermission) -> String {
        switch permission {
        case .view: return "View shared household"
        case .inventoryAdd: return "Add inventory"
        case .inventoryEdit: return "Edit inventory"
        case .inventoryRemove: return "Remove inventory"
        case .groceryAdd: return "Add grocery items"
        case .groceryEdit: return "Edit grocery items"
        case .groceryRemove: return "Remove grocery items"
        case .recipeEdit: return "Edit household recipes"
        case .mealPlanEdit: return "Edit meal plans"
        case .manageMembers: return "Manage members"
        case .manageHousehold: return "Manage household settings"
        case .transferOwnership: return "Transfer ownership"
        case .backupExport: return "Export backups"
        case .backupRestore: return "Restore backups"
        }
    }

    private func removeMember() async {
        removing = true; saveMessage = nil
        let ok = await household.removeMember(memberId: member.id)
        removing = false
        if ok { dismiss() }
        else { saveMessage = household.lastError ?? "Couldn't remove that member." }
    }
    private func prefRow(_ title: String, _ value: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(14, weight: .semibold).foregroundStyle(session.themeTextColor)
                Text(value).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
            Image(systemName: "chevron.right").scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.3))
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
                .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.55))
                .padding(.top, 14).padding(.bottom, 18)

            Text(code)
                .scaledFont(30, weight: .bold, design: .monospaced).tracking(2)
                .foregroundStyle(session.themeTextColor)
                .frame(maxWidth: .infinity).padding(.vertical, 20)
                .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 12))
            Text("Code expires in 7 days").scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.4))
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
                    .scaledFont(14, weight: .medium).foregroundStyle(Color.stockedError)
            }
            .disabled(regenerating || household.state != .owner)
            .padding(.bottom, 24)
            if household.state != .owner {
                Text("Only the household owner can regenerate the code.")
                    .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.45))
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
                Image(systemName: icon).scaledFont(16).foregroundStyle(color).frame(width: 38, height: 38)
                    .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                Text(title).scaledFont(15).foregroundStyle(session.themeTextColor)
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
    @State private var isSyncing = false

    private var statusIsHealthy: Bool { household.syncStatus.lastError == nil }
    private var statusLine: String {
        if household.isRepairingHouseholdStorage { return "Repairing household storage…" }
        if !statusIsHealthy { return "Offline. Changes will sync later." }
        return household.pendingOps.isEmpty ? "Up to date" : "\(household.pendingOps.count) change\(household.pendingOps.count == 1 ? "" : "s") waiting to sync"
    }
    private var statusIcon: String {
        if household.isRepairingHouseholdStorage { return "wrench.and.screwdriver.fill" }
        return statusIsHealthy ? (household.pendingOps.isEmpty ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath") : "wifi.slash"
    }
    private var lastSyncedText: String {
        let dates = [household.syncStatus.lastSuccessfulPush, household.syncStatus.lastSuccessfulPull].compactMap { $0 }
        guard let latest = dates.max() else { return "Never" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated
        return f.localizedString(for: latest, relativeTo: Date())
    }

    var body: some View {
        HHScreen("Household Settings") {
            VStack(spacing: 0) {
                NavigationLink { HouseholdNameEditView() } label: {
                    settingsRow("Household Name", household.householdName)
                }.buttonStyle(.plain)
                Divider()
                NavigationLink { HouseholdMyNameEditView() } label: {
                    settingsRow("Your Name", household.myDisplayName, subtitle: "How you appear to the household")
                }.buttonStyle(.plain)
                Divider()
                NavigationLink { HouseholdShareCodeView() } label: {
                    settingsRow("Invite Code", household.joinCode ?? "—", subtitle: "Share or regenerate")
                }.buttonStyle(.plain)
                Divider()
                NavigationLink { HouseholdSyncOptionsView() } label: {
                    settingsRow("What Syncs", "Choose what's shared", subtitle: "Inventory, grocery, recipes, meal plans")
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

            // ── Sync status + manual Sync Now (sync plan Drop 3, worker-adapted) ──
            HStack { Text("Sync").scaledFont(12, weight: .medium).foregroundStyle(session.themeTextColor.opacity(0.5)); Spacer() }
                .padding(.bottom, 8)
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: statusIcon)
                        .scaledFont(14, weight: .semibold)
                        .foregroundStyle(statusIsHealthy ? Color.stockedGold : Color.stockedError)
                    Text(statusLine)
                        .scaledFont(14, weight: .semibold).foregroundStyle(session.themeTextColor)
                    Spacer()
                }
                Text("Last synced: \(lastSyncedText)")
                    .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.6))
                if household.pendingOps.count > 0 {
                    Text("Pending changes: \(household.pendingOps.count)")
                        .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.6))
                }
                if let err = household.syncStatus.lastError, !err.isEmpty {
                    Text(err).scaledFont(12).foregroundStyle(Color.stockedError.opacity(0.8))
                }
                Button {
                    guard !isSyncing else { return }
                    isSyncing = true
                    Task {
                        await household.syncNow(store: session.guestStore)
                        isSyncing = false
                        if household.syncStatus.lastError == nil {
                            ToastCenter.shared.success("Synced with household")
                        } else {
                            ToastCenter.shared.info("Couldn't sync. Will retry automatically.")
                        }
                    }
                } label: {
                    HStack {
                        if isSyncing { ProgressView().tint(Color.stockedWhite) }
                        Text(household.isRepairingHouseholdStorage ? "Repairing…" : (isSyncing ? "Syncing…" : "Sync Now"))
                            .scaledFont(15, weight: .semibold).foregroundStyle(Color.stockedWhite)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Color.stockedGold, in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(isSyncing)
            }
            .padding(14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
            .padding(.bottom, 18)

            // ── Conflict review entry (sync plan Drop 5) — shown only when conflicts exist ──
            if !household.pendingConflicts.isEmpty {
                NavigationLink { HouseholdConflictReviewView() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .scaledFont(15, weight: .semibold).foregroundStyle(Color.stockedError)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Review Household Changes").scaledFont(14, weight: .semibold).foregroundStyle(session.themeTextColor)
                            Text("\(household.pendingConflicts.count) change\(household.pendingConflicts.count == 1 ? "" : "s") need your review")
                                .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                        Spacer()
                        Image(systemName: "chevron.right").scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.3))
                    }
                    .padding(14)
                    .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
                }.buttonStyle(.plain).padding(.bottom, 18)
            }

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
                Text(title).scaledFont(14, weight: .semibold).foregroundStyle(session.themeTextColor)
                Text(subtitle ?? value).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
            Image(systemName: "chevron.right").scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.3))
        }.padding(.vertical, 12)
    }
    private func destructiveRow(_ title: String, _ subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(14, weight: .semibold).foregroundStyle(Color.stockedError)
                Text(subtitle).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            Spacer()
        }.padding(.vertical, 12)
    }
}

// MARK: - Conflict Review (sync plan Drop 5)

struct HouseholdConflictReviewView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var household = HouseholdSync.shared

    private func typeLabel(_ t: HouseholdEntityType) -> String {
        switch t {
        case .inventoryItem: return "Inventory"
        case .groceryItem:   return "Grocery"
        case .userRecipe, .generatedRecipe: return "Recipe"
        default: return "Item"
        }
    }

    var body: some View {
        HHScreen("Review Changes") {
            if household.pendingConflicts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill").scaledFont(34).foregroundStyle(Color.stockedGold)
                    Text("All caught up").scaledFont(18, weight: .bold, design: .serif).foregroundStyle(session.themeTextColor)
                    Text("There are no changes to review.").scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.6))
                }.padding(.top, 60)
            } else {
                Text("Two people changed the same thing while offline. Choose which version to keep for each one.")
                    .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.6))
                    .padding(.bottom, 14)
                ForEach(household.pendingConflicts) { c in
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 6) {
                            Text(typeLabel(c.entityType).uppercased())
                                .scaledFont(11, weight: .bold).foregroundStyle(session.themeTextColor.opacity(0.4))
                            Spacer()
                        }
                        versionRow(title: "Your version", name: c.mineTitle, detail: c.mineDetail) {
                            household.resolveConflict(c, keepMine: true, store: session.guestStore)
                        }
                        versionRow(title: "Household version", name: c.theirsTitle, detail: c.theirsDetail) {
                            household.resolveConflict(c, keepMine: false, store: session.guestStore)
                        }
                        Button { household.dismissConflict(c) } label: {
                            Text("Skip for now").scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.5))
                        }
                    }
                    .padding(14)
                    .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
                    .padding(.bottom, 12)
                }
            }
        }
    }

    private func versionRow(title: String, name: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).scaledFont(11, weight: .medium).foregroundStyle(session.themeTextColor.opacity(0.5))
                    Text(name).scaledFont(15, weight: .semibold).foregroundStyle(session.themeTextColor)
                    Text(detail).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.6))
                }
                Spacer()
                Text("Keep").scaledFont(13, weight: .semibold).foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(Color.stockedGold, in: Capsule())
            }
            .padding(12)
            .background(session.themeBgColor, in: RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain)
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
                .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.55))
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
        HStack { Text(title).scaledFont(12, weight: .medium).foregroundStyle(session.themeTextColor.opacity(0.5)); Spacer() }
            .padding(.top, 14).padding(.bottom, 8)
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
    }
    private func toggle(_ label: String, _ binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Text(label).scaledFont(14).foregroundStyle(session.themeTextColor)
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
            HStack { Text("Invites you've sent").scaledFont(12, weight: .medium).foregroundStyle(session.themeTextColor.opacity(0.5)); Spacer() }
                .padding(.top, 8).padding(.bottom, 10)
            if invites.isEmpty {
                Text("No pending invites.").scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.4)).padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(invites) { inv in
                        HStack(spacing: 12) {
                            Text(String(inv.inviteeName.prefix(1))).scaledFont(14, weight: .bold).foregroundStyle(Color.stockedWhite)
                                .frame(width: 36, height: 36).background(Color.stockedGold, in: Circle())
                            VStack(alignment: .leading, spacing: 1) {
                                Text(inv.inviteeName).scaledFont(15, weight: .semibold).foregroundStyle(session.themeTextColor)
                                Text("Invited \(inv.sentAt, style: .date)").scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
                            }
                            Spacer()
                            Text(inv.isExpired ? "Expired" : "Pending").scaledFont(12, weight: .medium)
                                .foregroundStyle(inv.isExpired ? Color.stockedError : Color.stockedGold)
                        }.padding(.vertical, 10)
                        if inv.id != invites.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 14)
                .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
            }
            Text("Invite links and codes expire in 7 days.")
                .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.4))
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
            Image(systemName: icon).scaledFont(18).foregroundStyle(Color.stockedGold).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(15, weight: .semibold).foregroundStyle(session.themeTextColor)
                Text(subtitle).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
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
            HStack { Text("Common Questions").scaledFont(12, weight: .medium).foregroundStyle(session.themeTextColor.opacity(0.5)); Spacer() }
                .padding(.top, 8).padding(.bottom, 10)
            VStack(spacing: 0) {
                ForEach(faqs, id: \.self) { q in
                    HStack {
                        Text(q).scaledFont(14).foregroundStyle(session.themeTextColor)
                        Spacer()
                        Image(systemName: "chevron.right").scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.3))
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
    @State private var household = HouseholdSync.shared
    @State private var name = HouseholdSync.shared.householdName

    var body: some View {
        HHScreen("Household Name") {
            Text("This name is shown to everyone in your household.")
                .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.55))
                .padding(.top, 12).padding(.bottom, 18)
            TextField("Household name", text: $name)
                .scaledFont(17)
                .foregroundStyle(session.themeTextColor)
                .padding(.vertical, 14).padding(.horizontal, 16)
                .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 18)
            Button {
                // Persists locally AND syncs to every device (rides on the next push).
                household.setHouseholdName(name, store: session.guestStore)
                dismiss()
            } label: { Text("Save").hhPrimaryButton() }
                .padding(.bottom, 24)
        }
    }
}

// MARK: - Your Name editor (#1 — your own household display name)

struct HouseholdMyNameEditView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var household = HouseholdSync.shared
    @State private var name = HouseholdSync.shared.myDisplayName

    var body: some View {
        HHScreen("Your Name") {
            Text("How you appear to everyone in your household — in the member list, the activity feed, and the Daily Brief. Syncs to every device.")
                .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.55))
                .padding(.top, 12).padding(.bottom, 18)
            TextField("Your name", text: $name)
                .scaledFont(17)
                .foregroundStyle(session.themeTextColor)
                .padding(.vertical, 14).padding(.horizontal, 16)
                .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: 12))
                .padding(.bottom, 18)
            Button {
                household.setMyName(name, store: session.guestStore)
                dismiss()
            } label: { Text("Save").hhPrimaryButton() }
                .padding(.bottom, 24)
        }
    }
}

// MARK: - What Syncs (#2 — selective sync)

struct HouseholdSyncOptionsView: View {
    @Environment(AppSession.self) private var session
    private let household = HouseholdSync.shared
    @State private var inv = HouseholdSync.shared.syncInventory
    @State private var gro = HouseholdSync.shared.syncGrocery
    @State private var rec = HouseholdSync.shared.syncRecipes
    @State private var mp  = HouseholdSync.shared.syncMealPlans

    var body: some View {
        HHScreen("What Syncs") {
            Text("Choose what this device shares with your household. Turning something off keeps it private to you — others won't see your changes for it, and you won't receive theirs.")
                .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.55))
                .padding(.top, 12).padding(.bottom, 16)
            VStack(spacing: 0) {
                toggleRow("Inventory", "shippingbox.fill", $inv) { household.syncInventory = $0 }
                Divider()
                toggleRow("Grocery list", "cart.fill", $gro) { household.syncGrocery = $0 }
                Divider()
                toggleRow("Recipes", "book.fill", $rec) { household.syncRecipes = $0 }
                Divider()
                toggleRow("Meal plans", "calendar", $mp) { household.syncMealPlans = $0 }
            }
            .padding(.horizontal, 14)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: HHStyle.cardCorner))
            .padding(.bottom, 20)
        }
    }

    private func toggleRow(_ title: String, _ icon: String, _ binding: Binding<Bool>, _ persist: @escaping (Bool) -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).scaledFont(15).foregroundStyle(Color.stockedGold).frame(width: 26)
            Text(title).scaledFont(15, weight: .semibold).foregroundStyle(session.themeTextColor)
            Spacer()
            Toggle("", isOn: binding).labelsHidden().tint(Color.stockedGold)
                .onChange(of: binding.wrappedValue) { _, v in persist(v) }
        }
        .padding(.vertical, 12)
    }
}
