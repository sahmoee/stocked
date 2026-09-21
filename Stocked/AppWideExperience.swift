import SwiftUI
import os

// MARK: - App-wide experience contract

enum AppContentState: String, CaseIterable, Identifiable, Codable {
    case content, loading, empty, stale, offline, permissionDenied, failure
    var id: String { rawValue }

    var title: String {
        switch self {
        case .content: "Ready"
        case .loading: "Loading"
        case .empty: "Nothing here yet"
        case .stale: "Update available"
        case .offline: "Saved on this device"
        case .permissionDenied: "Permission needed"
        case .failure: "Something went wrong"
        }
    }

    var symbol: String {
        switch self {
        case .content: "checkmark.circle.fill"
        case .loading: "arrow.trianglehead.2.clockwise.rotate.90"
        case .empty: "tray"
        case .stale: "clock.badge.exclamationmark"
        case .offline: "wifi.slash"
        case .permissionDenied: "hand.raised.fill"
        case .failure: "exclamationmark.triangle.fill"
        }
    }
}

struct AppStatePanel: View {
    @Environment(AppSession.self) private var session
    @Environment(\.stockedMotion) private var motion
    let state: AppContentState
    var detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: state.symbol)
                .scaledFont(26, weight: .semibold)
                .foregroundStyle(state == .failure ? Color.stockedError : session.accentColor)
                .symbolEffect(
                    .rotate,
                    options: .repeating,
                    isActive: state == .loading && motion.permitsContinuousMotion
                )
            Text(state.title).scaledFont(18, weight: .bold, design: .serif)
            Text(detail).scaledFont(14).multilineTextAlignment(.center)
                .foregroundStyle(session.themeTextColor.opacity(0.65))
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(StockedPrimaryButtonStyle())
            }
        }
        .foregroundStyle(session.themeTextColor)
        .frame(maxWidth: .infinity)
        .stockedCard(isDark: session.isDarkMode, padding: 18, radius: StockedUI.cornerRadiusMd)
        .accessibilityElement(children: .combine)
    }
}

enum StockedDestination: String, CaseIterable, Codable, Identifiable {
    case home, cook, inventory, recipes, grocery, search, settings, activity, onboarding
    var id: String { rawValue }

    var tab: StockedTab? {
        switch self {
        case .home: .home
        case .cook: .cook
        case .inventory: .inventory
        case .recipes: .recipes
        case .grocery: .grocery
        default: nil
        }
    }
}

@Observable @MainActor
final class AppRouteCoordinator {
    static let shared = AppRouteCoordinator()
    private(set) var lastDestination: StockedDestination
    private let key = "app.last.destination.v1"

    private init() {
        lastDestination = StockedDestination(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .home
    }

    func open(_ destination: StockedDestination) {
        lastDestination = destination
        UserDefaults.standard.set(destination.rawValue, forKey: key)
        if let tab = destination.tab {
            InterHubCoordinator.shared.open(.tab(InterHubTab(tab)), source: .app)
        } else if destination == .search {
            InterHubCoordinator.shared.open(.search(query: nil), source: .app)
        }
    }

    func destination(for url: URL) -> StockedDestination? {
        guard url.scheme?.lowercased() == "stocked" else { return nil }
        return StockedDestination(rawValue: (url.host ?? url.pathComponents.dropFirst().first ?? "").lowercased())
    }
}

struct AppCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbol: String
    let destination: StockedDestination
}

enum AppCommandCatalog {
    static let all: [AppCommand] = [
        .init(id: "search", title: "Search everything", subtitle: "Recipes, pantry, grocery, and tools", symbol: "magnifyingglass", destination: .search),
        .init(id: "inventory", title: "Open inventory", subtitle: "Review what is in your kitchen", symbol: "shippingbox", destination: .inventory),
        .init(id: "recipes", title: "Find a recipe", subtitle: "Search the complete recipe catalogue", symbol: "fork.knife", destination: .recipes),
        .init(id: "grocery", title: "Open grocery list", subtitle: "Shop and check off items", symbol: "cart", destination: .grocery),
        .init(id: "cook", title: "Start cooking", subtitle: "Choose Cook Now or Cook Later", symbol: "frying.pan", destination: .cook)
    ]
}

@Observable @MainActor
final class AppUndoJournal {
    static let shared = AppUndoJournal()
    struct Entry: Identifiable {
        let id = UUID()
        let title: String
        let createdAt = Date()
        let undo: () -> Void
    }
    private(set) var entries: [Entry] = []

    func record(_ title: String, undo: @escaping () -> Void) {
        entries.insert(Entry(title: title, undo: undo), at: 0)
        entries = Array(entries.prefix(20))
    }

    func undoLatest() {
        guard !entries.isEmpty else { return }
        let entry = entries.removeFirst()
        entry.undo()
    }
}

enum BackgroundActivityKind: String, Codable, CaseIterable {
    case recipeImport, inventory, sync, indexing, household, backup, qa
}

@Observable @MainActor
final class BackgroundActivityCenter {
    static let shared = BackgroundActivityCenter()
    struct Item: Identifiable, Codable {
        let id: UUID
        var kind: BackgroundActivityKind
        var title: String
        var detail: String
        var progress: Double?
        var updatedAt: Date
        var failed: Bool
    }
    private(set) var items: [Item] = []

    func report(id: UUID = UUID(), kind: BackgroundActivityKind, title: String,
                detail: String, progress: Double? = nil, failed: Bool = false) {
        let item = Item(id: id, kind: kind, title: title, detail: detail,
                        progress: progress, updatedAt: Date(), failed: failed)
        if let index = items.firstIndex(where: { $0.id == id }) { items[index] = item }
        else { items.insert(item, at: 0) }
        items = Array(items.prefix(50))
    }

    func clearCompleted() { items.removeAll { ($0.progress ?? 0) >= 1 && !$0.failed } }
}

enum AppPerformanceBudget {
    static let launch: TimeInterval = 2.0
    static let tabSwitch: TimeInterval = 0.25
    static let firstContent: TimeInterval = 1.0
    static let search: TimeInterval = 0.4
    static let largeListFrameMilliseconds = 16.7
}

struct DataProvenance: Hashable, Codable {
    enum Confidence: String, Codable { case confirmed, likely, uncertain }
    var source: String
    var updatedAt: Date
    var confidence: Confidence
}

struct ProvenanceLabel: View {
    let provenance: DataProvenance
    var body: some View {
        Label("\(provenance.source) · \(provenance.confidence.rawValue.capitalized)",
              systemImage: provenance.confidence == .confirmed ? "checkmark.seal.fill" : "info.circle")
            .scaledFont(11, weight: .medium)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Source \(provenance.source), confidence \(provenance.confidence.rawValue)")
    }
}

struct RecommendationReason: Hashable, Codable {
    var title: String
    var facts: [String]
    var preferenceAction: String
}

struct RecommendationReasonView: View {
    @Environment(AppSession.self) private var session
    let reason: RecommendationReason
    var onCorrect: (() -> Void)?
    var body: some View {
        DisclosureGroup("Why this?") {
            VStack(alignment: .leading, spacing: 7) {
                Text(reason.title).scaledFont(13, weight: .semibold)
                ForEach(reason.facts, id: \.self) { Label($0, systemImage: "checkmark").scaledFont(12) }
                if let onCorrect { Button(reason.preferenceAction, action: onCorrect).scaledFont(12, weight: .semibold) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .tint(session.accentColor)
    }
}

enum SetupMilestone: String, CaseIterable, Identifiable {
    case profile, dietarySafety, firstInventory, firstRecipe, notifications, household
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profile: "Complete your cooking profile"
        case .dietarySafety: "Confirm allergies and exclusions"
        case .firstInventory: "Add your first pantry item"
        case .firstRecipe: "Save your first recipe"
        case .notifications: "Choose reminder preferences"
        case .household: "Invite your household"
        }
    }
}

/// Setup progress is derived from the existing owners of each piece of data. It is deliberately
/// not another checklist store: opening a row cannot claim that profile, pantry, notification, or
/// household setup happened when the corresponding feature still has no saved state.
@MainActor
enum OnboardingProgressCenter {
    static func isComplete(_ milestone: SetupMilestone, session: AppSession,
                           household: HouseholdSync = .shared,
                           notifications: DailyBriefNotificationManager = .shared) -> Bool {
        let store = session.guestStore
        switch milestone {
        case .profile:
            return store.cookingProfile.completedSetup
        case .dietarySafety:
            return !store.cookingProfile.dietaryStyle
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .firstInventory:
            return !store.inventoryItems.isEmpty
        case .firstRecipe:
            return !store.userRecipes.isEmpty || !store.savedGeneratedRecipes.isEmpty
        case .notifications:
            return notifications.isEnabled
                || notifications.expiryRemindersEnabled
                || notifications.cookSuggestionEnabled
                || notifications.stapleNudgeEnabled
                || notifications.prepReminderEnabled
        case .household:
            return household.state == .owner || household.state == .member
        }
    }
}

struct ContextualHelpTip: Identifiable, Hashable, Codable {
    var id: String
    var title: String
    var detail: String
    var symbol: String
}

@Observable @MainActor
final class ContextualHelpCenter {
    static let shared = ContextualHelpCenter()
    private(set) var dismissed: Set<String>
    private let key = "app.help.dismissed.v1"
    private init() { dismissed = Set(UserDefaults.standard.stringArray(forKey: key) ?? []) }
    func dismiss(_ tip: ContextualHelpTip) {
        dismissed.insert(tip.id); UserDefaults.standard.set(Array(dismissed), forKey: key)
    }
    func reset() { dismissed.removeAll(); UserDefaults.standard.removeObject(forKey: key) }
}

struct HouseholdActivityEntry: Identifiable, Codable {
    let id: UUID
    var member: String
    var action: String
    var date: Date
    var conflict: Bool
}

enum AppFormValidation {
    static func required(_ value: String, name: String) -> String? {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "\(name) is required." : nil
    }
    static func positive(_ value: Double?, name: String) -> String? {
        guard let value, value > 0 else { return "\(name) must be greater than zero." }
        return nil
    }
}

struct AutosaveIndicator: View {
    enum State { case saved, saving, failed }
    var state: State
    var body: some View {
        Label(state == .saved ? "Saved" : state == .saving ? "Saving…" : "Not saved",
              systemImage: state == .saved ? "checkmark.circle" : state == .saving ? "arrow.clockwise" : "exclamationmark.circle")
            .scaledFont(11, weight: .medium).foregroundStyle(.secondary)
    }
}

@Observable @MainActor
final class PrivacyControlCenter {
    static let shared = PrivacyControlCenter()
    var allowOnDeviceAnalytics: Bool {
        didSet { AppAnalytics.shared.isEnabled = allowOnDeviceAnalytics }
    }
    var allowPersonalization: Bool { didSet { UserDefaults.standard.set(allowPersonalization, forKey: "privacy.personalization") } }
    var allowHouseholdActivity: Bool { didSet { UserDefaults.standard.set(allowHouseholdActivity, forKey: "privacy.householdActivity") } }
    private init() {
        allowOnDeviceAnalytics = AppAnalytics.shared.isEnabled
        allowPersonalization = UserDefaults.standard.object(forKey: "privacy.personalization") as? Bool ?? true
        allowHouseholdActivity = UserDefaults.standard.object(forKey: "privacy.householdActivity") as? Bool ?? true
    }
}

enum LocalizationAudit {
    static let pseudolocalizationMarkers = (prefix: "［", suffix: "］")
    static func pseudolocalize(_ text: String) -> String {
        "［" + text.replacingOccurrences(of: "a", with: "áá").replacingOccurrences(of: "e", with: "éé") + "］"
    }
}

enum AutonomousQAJourney: String, CaseIterable, Identifiable {
    case onboarding, inventory, recipes, cooking, grocery, widgets, accessibility, offline, sync, deepLinks
    var id: String { rawValue }
}

struct AppAccessibilityMatrix {
    static let widths: [CGFloat] = [320, 375, 393, 430, 744, 1024]
    static let contentSizes: [ContentSizeCategory] = [.extraSmall, .large, .extraExtraExtraLarge, .accessibilityExtraExtraExtraLarge]
    static let appearances = ["light", "dark", "increased-contrast", "reduced-transparency"]
}

// MARK: - App experience center

struct AppExperienceCenterView: View {
    @Environment(AppSession.self) private var session
    @State private var activities = BackgroundActivityCenter.shared
    @State private var privacy = PrivacyControlCenter.shared
    @State private var household = HouseholdSync.shared
    @State private var setupSheet: SetupMilestone?

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            List {
                Section("Continue setup") {
                    if SetupMilestone.allCases.allSatisfy({ setupIsComplete($0) }) {
                        Label("Setup complete", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Color.stockedSuccess)
                    }
                    ForEach(SetupMilestone.allCases) { milestone in
                        setupRow(milestone)
                    }
                }
                Section("Background activity") {
                    if activities.items.isEmpty { Text("No active imports, syncs, indexing, backups, or QA runs.") }
                    ForEach(activities.items) { item in
                        VStack(alignment: .leading, spacing: 5) {
                            Label(item.title, systemImage: item.failed ? "exclamationmark.triangle" : "arrow.trianglehead.2.clockwise.rotate.90")
                            Text(item.detail).scaledFont(12).foregroundStyle(.secondary)
                            if let progress = item.progress { ProgressView(value: progress) }
                        }
                    }
                    if !activities.items.isEmpty { Button("Clear completed") { activities.clearCompleted() } }
                }
                Section("Notifications") {
                    NavigationLink {
                        DailyBriefNotificationSettingsView()
                            .environment(session)
                    } label: {
                        Label("Reminders & Daily Brief", systemImage: "bell.badge.fill")
                    }
                    Text("Choose real Daily Brief, expiry, cook, staple, and meal-prep reminders.")
                        .scaledFont(11)
                        .foregroundStyle(.secondary)
                }
                Section("Privacy") {
                    Toggle("On-device usage insights", isOn: $privacy.allowOnDeviceAnalytics)
                    Toggle("Personalized recommendations", isOn: $privacy.allowPersonalization)
                    Toggle("Household activity", isOn: $privacy.allowHouseholdActivity)
                    Text("Stocked keeps these controls on this device. Provider credentials never enter the app.")
                        .scaledFont(11).foregroundStyle(.secondary)
                }
                Section("Accessibility and language QA") {
                    LabeledContent("Test widths", value: "\(AppAccessibilityMatrix.widths.count)")
                    LabeledContent("Text scales", value: "\(AppAccessibilityMatrix.contentSizes.count)")
                    LabeledContent("Appearance modes", value: "\(AppAccessibilityMatrix.appearances.count)")
                    LabeledContent("Autonomous journeys", value: "\(AutonomousQAJourney.allCases.count)")
                    Button("Show coach marks again") { ContextualHelpCenter.shared.reset() }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .navigationTitle("App Experience")
        .navigationBarTitleDisplayMode(.inline)
        .qaScreen("App Experience")
        .sheet(item: $setupSheet) { milestone in
            setupDestination(for: milestone)
                .environment(session)
        }
    }

    @ViewBuilder
    private func setupRow(_ milestone: SetupMilestone) -> some View {
        let complete = setupIsComplete(milestone)
        Button {
            openSetup(milestone)
        } label: {
            HStack(spacing: 10) {
                Label(milestone.title,
                      systemImage: complete ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(complete ? Color.stockedSuccess : session.themeTextColor)
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(session.themeSecondaryText)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint(complete ? "Review or change this setup" : "Open this setup flow")
    }

    private func setupIsComplete(_ milestone: SetupMilestone) -> Bool {
        OnboardingProgressCenter.isComplete(
            milestone, session: session, household: household,
            notifications: DailyBriefNotificationManager.shared
        )
    }

    private func openSetup(_ milestone: SetupMilestone) {
        setupSheet = milestone
    }

    @ViewBuilder
    private func setupDestination(for milestone: SetupMilestone) -> some View {
        switch milestone {
        case .profile:
            EditProfileView()
        case .dietarySafety:
            NavigationStack { DietaryProfileView() }
        case .notifications:
            NavigationStack { DailyBriefNotificationSettingsView() }
        case .household:
            HouseholdHomeView()
        case .firstInventory:
            AddItemSheet(defaultZone: "Fridge")
        case .firstRecipe:
            CreateRecipeView()
        }
    }
}

struct AppWideExperienceModifier: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    func body(content: Content) -> some View {
        content
            .stockedThemeEnvironment()
            .onChange(of: scenePhase) { _, phase in
                // Real sync owners report their own stable lifecycle IDs. Do not synthesize a
                // fresh zero-progress row on every foreground activation; those rows never had a
                // corresponding completion and accumulated as phantom activity.
                if phase == .background {
                    UserDefaults.standard.set(Date(), forKey: "app.last.backgrounded")
                }
            }
    }
}

extension View {
    func appWideExperience() -> some View { modifier(AppWideExperienceModifier()) }
}
