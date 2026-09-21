// FamilyProfiles.swift — Feature 3: per-person eater profiles.
//
// Household members today are accounts (roles/sync). This makes them *eaters*: each person gets
// allergies, dislikes, a diet tag and a portion multiplier, so meal suggestions can satisfy
// everyone actually at the table — and a recipe can be checked against the whole household at once.
//
// Self-contained storage (Codable → UserDefaults) so it doesn't disturb the existing sync models;
// it can be folded into household sync later by serializing `FamilyProfileStore.profiles`.

import SwiftUI

// MARK: - Model

nonisolated struct EaterProfile: Codable, Identifiable, Hashable, Sendable, HouseholdSyncable {
    // ── Household sync (launch readiness 1.4) ────────────────────────────────
    // Defaulted so entries saved before sync existed still decode. Same epoch-ms
    // last-write-wins convention as LocalInventoryItem.
    var updatedAt: Double = 0
    var lastWriterID: String = ""

    var id: UUID = UUID()
    var name: String = ""
    var allergies: [String] = []       // hard constraints — never suggest
    var dislikes: [String] = []        // soft constraints — avoid when possible
    var diet: String = "None"          // None | Vegetarian | Vegan | Pescatarian | Gluten-free | Dairy-free
    var portionMultiplier: Double = 1  // 0.5 for a small child, 1.5 for a big eater
    var isPresent: Bool = true         // uncheck when someone's away — scaling adapts

    static let diets = ["None", "Vegetarian", "Vegan", "Pescatarian", "Gluten-free", "Dairy-free"]
}

/// Result of checking a recipe against everyone in the household.
nonisolated struct HouseholdFitResult: Sendable {
    let blockedBy: [(person: String, ingredient: String)]   // allergy hits — hard blocks
    let dislikedBy: [(person: String, ingredient: String)]  // soft warnings
    var isSafe: Bool { blockedBy.isEmpty }
}

// MARK: - Store

@MainActor
@Observable
final class FamilyProfileStore {
    static let shared = FamilyProfileStore()
    /// Improvement #6 — file-backed, debounced, and migrated automatically from the old
    /// UserDefaults blob on first load. See FeatureStore.swift for why.
    private let store = FeatureStore<EaterProfile>(key: FeatureStoreKeys.familyProfiles)
    /// Re-entrancy guard for the sync stamping pass (see the didSet). Not observed.
    @ObservationIgnored private var _stamping = false

    var profiles: [EaterProfile] = [] { didSet {
        store.save(profiles)
        // CRASH FIX (build 65): assign the stamped array once, guarded, so the
        // follow-up didSet is a no-op instead of recursing forever (see FeatureSync).
        guard !_stamping else { return }
        _stamping = true
        let _stamped = FeatureSync.shared.stampMutation(FeatureSync.Keys.familyProfiles, old: oldValue, current: profiles)
        if _stamped != profiles { profiles = _stamped }
        _stamping = false
    } }

    private init() {
        _stamping = true
        profiles = store.load()
        _stamping = false
    }

    /// Push any pending write to disk immediately (call before backgrounding).
    func flush() { store.flush() }

    /// Total servings needed for everyone present (rounded up, minimum 1).
    var servingsNeeded: Int {
        let total = profiles.filter(\.isPresent).reduce(0.0) { $0 + $1.portionMultiplier }
        return max(1, Int(total.rounded(.up)))
    }

    /// Every allergen across people who are present — the household's hard constraints.
    var activeAllergens: [String] {
        Array(Set(profiles.filter(\.isPresent).flatMap(\.allergies).map { $0.lowercased() })).sorted()
    }

    /// Check a recipe's ingredient lines against everyone present.
    /// Routed through DietaryGuard so this check, Cook Now's exclusion, Discover's
    /// allergen filter, Surprise Me, and the AI generator all apply ONE rule.
    /// WAS: raw substring containment on lowercased text.
    func check(ingredients: [String]) -> HouseholdFitResult {
        var blocked: [(String, String)] = []
        var disliked: [(String, String)] = []
        for p in profiles where p.isPresent {
            let rules = DietaryGuard.Rules(allergens: p.allergies, dislikes: p.dislikes)
            for a in DietaryGuard.allergenHits(ingredientLines: ingredients, rules: rules) {
                blocked.append((p.name, a))
            }
            for d in DietaryGuard.dislikeHits(ingredientLines: ingredients, rules: rules) {
                disliked.append((p.name, d))
            }
        }
        return HouseholdFitResult(blockedBy: blocked, dislikedBy: disliked)
    }
}

// MARK: - UI

struct FamilyProfilesView: View {
    @Environment(AppSession.self) private var session
    private let store = FamilyProfileStore.shared
    @State private var editing: EaterProfile?

    var body: some View {
        List {
            Section {
                ForEach(store.profiles) { p in
                    Button { editing = p } label: { row(p) }.buttonStyle(.plain)
                }
                .onDelete { idx in store.profiles.remove(atOffsets: idx) }

                Button {
                    let new = EaterProfile(name: "New person")
                    store.profiles.append(new); editing = new
                } label: {
                    Label("Add a person", systemImage: "person.badge.plus").foregroundStyle(session.accentColor)
                }
            } header: {
                Text("Who eats here")
            } footer: {
                Text(store.profiles.isEmpty
                     ? "Add the people you cook for. Recipes get checked against their allergies, and portions scale to who's home."
                     : "Cooking for \(store.servingsNeeded) serving\(store.servingsNeeded == 1 ? "" : "s") tonight.")
            }
        }
        // #8 — this screen applied NO theming and inherited whatever the parent had. That is the
        // exact shape of the QA Workbook bug: correct at the root, wrong once pushed.
        .stockedScreen()
        .navigationTitle("Family")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { p in EaterEditor(profile: p) }
    }

    private func row(_ p: EaterProfile) -> some View {
        HStack(spacing: 12) {
            Image(systemName: p.isPresent ? "person.fill" : "person")
                .foregroundStyle(p.isPresent ? session.accentColor : session.themeTextColor.opacity(0.3))
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name.isEmpty ? "Unnamed" : p.name).scaledFont(15, weight: .semibold)
                    .foregroundStyle(session.themeTextColor)
                let detail = [p.diet == "None" ? nil : p.diet,
                              p.allergies.isEmpty ? nil : "avoids \(p.allergies.joined(separator: ", "))"]
                    .compactMap { $0 }.joined(separator: " · ")
                if !detail.isEmpty {
                    Text(detail).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.55))
                }
            }
            Spacer()
            Text("×\(p.portionMultiplier == p.portionMultiplier.rounded() ? String(Int(p.portionMultiplier)) : String(format: "%.1f", p.portionMultiplier))")
                .scaledFont(12, weight: .semibold).foregroundStyle(session.themeTextColor.opacity(0.45))
        }
    }
}

private struct EaterEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let store = FamilyProfileStore.shared
    @State var profile: EaterProfile
    @State private var allergyText = ""
    @State private var dislikeText = ""

    init(profile: EaterProfile) {
        _profile = State(initialValue: profile)
        _allergyText = State(initialValue: profile.allergies.joined(separator: ", "))
        _dislikeText = State(initialValue: profile.dislikes.joined(separator: ", "))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") { TextField("Name", text: $profile.name) }
                Section("Diet") {
                    Picker("Diet", selection: $profile.diet) {
                        ForEach(EaterProfile.diets, id: \.self) { Text($0).tag($0) }
                    }
                    Toggle("Eating here tonight", isOn: $profile.isPresent)
                }
                Section {
                    TextField("peanuts, shellfish", text: $allergyText)
                } header: { Text("Allergies") } footer: {
                    Text("Comma separated. Recipes containing these are flagged as unsafe for the household.")
                }
                Section {
                    TextField("mushrooms, olives", text: $dislikeText)
                } header: { Text("Dislikes") } footer: { Text("Soft — used to rank suggestions, not block them.") }
                Section {
                    Stepper(value: $profile.portionMultiplier, in: 0.25...3, step: 0.25) {
                        Text("Portion ×\(String(format: "%.2g", profile.portionMultiplier))")
                    }
                } footer: { Text("0.5 for a small child, 1.5 for a big eater. Meal scaling uses this.") }
            }
            .navigationTitle(profile.name.isEmpty ? "Person" : profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") { save(); dismiss() }.font(.stocked(.body).bold())
                }
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
            }
        }
        .stockedPresentationSurface(width: .form)
    }

    private func save() {
        var p = profile
        p.allergies = splitList(allergyText)
        p.dislikes = splitList(dislikeText)
        if let i = store.profiles.firstIndex(where: { $0.id == p.id }) { store.profiles[i] = p }
        else { store.profiles.append(p) }
    }
    private func splitList(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}
