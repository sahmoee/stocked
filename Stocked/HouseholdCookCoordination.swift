import SwiftUI
import Observation

/// A deliberately small household projection of an active cook. Recipe instructions,
/// ingredient quantities, notes, and timers remain on the cook's device; the household
/// receives only enough state to coordinate and avoid doing the same job twice.
nonisolated struct HouseholdCookPresence: HouseholdSyncable, Equatable {
    var id: UUID
    var recipeTitle: String
    var memberID: String
    var memberName: String
    var status: ActiveCookSessionStatus
    var completedStepCount: Int
    var totalStepCount: Int
    var availableTasks: [String]
    var claimedTasks: [String: String]
    var lastHeartbeatAt: Date
    var updatedAt: Double
    var lastWriterID: String

    init(snapshot: ActiveCookSessionSnapshot, memberID: String, memberName: String,
         existingClaims: [String: String] = [:]) {
        id = snapshot.id
        recipeTitle = snapshot.recipeTitle
        self.memberID = memberID
        self.memberName = memberName.isEmpty ? "Household member" : memberName
        status = snapshot.status
        completedStepCount = Set(snapshot.completedSteps).count
        totalStepCount = snapshot.steps.count
        let tasks = Self.coordinationTasks(for: snapshot)
        availableTasks = tasks
        claimedTasks = existingClaims.filter { tasks.contains($0.key) }
        lastHeartbeatAt = Date()
        updatedAt = Date().timeIntervalSince1970 * 1_000
        lastWriterID = memberID
    }

    var isFresh: Bool {
        (status == .active || status == .paused) && Date().timeIntervalSince(lastHeartbeatAt) < 12 * 3600
    }

    var progressLabel: String {
        "\(min(completedStepCount, totalStepCount)) of \(totalStepCount) steps"
    }

    private static func coordinationTasks(for snapshot: ActiveCookSessionSnapshot) -> [String] {
        var tasks = snapshot.selectedComponents.map { "Prepare \($0)" }
        if snapshot.ingredients.count >= 4 { tasks.append("Gather ingredients") }
        if snapshot.steps.count >= 4 { tasks.append("Help with prep") }
        if snapshot.steps.count >= 7 { tasks.append("Set the table") }
        var seen = Set<String>()
        return tasks.filter { seen.insert($0.localizedLowercase).inserted }.prefix(6).map { $0 }
    }
}

@MainActor
@Observable
final class HouseholdCookStore {
    static let shared = HouseholdCookStore()

    private let store = FeatureStore<HouseholdCookPresence>(key: FeatureStoreKeys.householdCookPresence)
    @ObservationIgnored private var stamping = false

    var entries: [HouseholdCookPresence] = [] {
        didSet {
            store.save(entries)
            guard !stamping else { return }
            stamping = true
            let stamped = FeatureSync.shared.stampMutation(
                FeatureSync.Keys.activeCookSessions, old: oldValue, current: entries)
            if stamped != entries { entries = stamped }
            stamping = false
        }
    }

    private init() {
        stamping = true
        entries = store.load().filter(\.isFresh)
        stamping = false
    }

    var visibleEntries: [HouseholdCookPresence] {
        entries.filter(\.isFresh).sorted { $0.lastHeartbeatAt > $1.lastHeartbeatAt }
    }

    func publish(_ snapshot: ActiveCookSessionSnapshot) {
        let household = HouseholdSync.shared
        guard household.state == .owner || household.state == .member else { return }
        let existing = entries.first(where: { $0.id == snapshot.id })
        let claims = existing?.claimedTasks ?? [:]
        let value = HouseholdCookPresence(snapshot: snapshot, memberID: household.memberId,
                                          memberName: household.myDisplayName,
                                          existingClaims: claims)
        if let existing,
           existing.status == value.status,
           existing.completedStepCount == value.completedStepCount,
           existing.totalStepCount == value.totalStepCount,
           existing.availableTasks == value.availableTasks,
           Date().timeIntervalSince(existing.lastHeartbeatAt) < 60 {
            return
        }
        if let index = entries.firstIndex(where: { $0.id == value.id }) { entries[index] = value }
        else {
            entries.append(value)
            AppAnalytics.shared.log(.householdCookShared)
        }
    }

    func end(sessionID: UUID) {
        entries.removeAll { $0.id == sessionID }
    }

    func pruneStale() {
        entries.removeAll { !$0.isFresh }
    }

    func claim(task: String, in sessionID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == sessionID }),
              entries[index].availableTasks.contains(task) else { return }
        let member = HouseholdSync.shared.myDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        entries[index].claimedTasks[task] = member.isEmpty ? "Household member" : member
        entries[index].lastHeartbeatAt = Date()
        AppAnalytics.shared.log(.householdCookTaskClaimed)
    }

    func release(task: String, in sessionID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == sessionID }) else { return }
        entries[index].claimedTasks.removeValue(forKey: task)
        entries[index].lastHeartbeatAt = Date()
        AppAnalytics.shared.log(.householdCookTaskReleased)
    }

    func flush() { store.flush() }
}

struct HouseholdCookingCard: View {
    @Environment(AppSession.self) private var session
    let presence: HouseholdCookPresence
    private let store = HouseholdCookStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Cooking together", systemImage: "person.2.fill")
                    .scaledFont(12, weight: .bold)
                    .foregroundStyle(Color.stockedGold)
                Spacer()
                Text(presence.status == .paused ? "Paused" : presence.progressLabel)
                    .scaledFont(11)
                    .foregroundStyle(session.themeSecondaryText)
            }
            Text(presence.recipeTitle)
                .scaledFont(17, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            Text("\(presence.memberName) is cooking")
                .scaledFont(13)
                .foregroundStyle(session.themeSecondaryText)

            ForEach(presence.availableTasks, id: \.self) { task in
                let claimant = presence.claimedTasks[task]
                Button {
                    if claimant == nil { store.claim(task: task, in: presence.id) }
                    else if claimant == HouseholdSync.shared.myDisplayName {
                        store.release(task: task, in: presence.id)
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: claimant == nil ? "circle" : "checkmark.circle.fill")
                        Text(task).scaledFont(13, weight: .semibold)
                        Spacer()
                        if let claimant { Text(claimant).scaledFont(11) }
                    }
                    .foregroundStyle(claimant == nil ? session.themeTextColor : Color.stockedGold)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(claimant != nil && claimant != HouseholdSync.shared.myDisplayName)
                .accessibilityLabel(claimant.map { "\(task), claimed by \($0)" } ?? "Claim \(task)")
            }
        }
        .padding(14)
        .background(session.themeCardColor)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
            .stroke(Color.stockedGold.opacity(0.35), lineWidth: 1))
    }
}
