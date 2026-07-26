// SubstitutionEngine.swift — Improvement #1: ONE answer to "what can I use instead?"
//
// The app had five independent substitution sources that never spoke to each other:
//
//   StockedDatabase.substitutions(for:)        73 entries, notes, no ratios   — cook flow, grocery
//   IngredientIntel.substitutions(_:)          12 entries, ratios, no notes   — recipe ingredient menu
//   GuestDataStore.userSubstitutions           user's own swaps               — databases screen
//   SmartClient.substitutions(for:diet:)       Worker, diet-aware             — toolbox tool ONLY
//   CookLaterCrossCheckEngine.substitutions    7 entries, inventory-aware     — cook-later
//
// The user-visible bug: a swap you add yourself ("oat milk → almond milk") only applied on the
// Databases screen. The Substitutions tool showed Worker results and nothing else. The recipe
// ingredient menu showed 12 hardcoded entries and ignored the 73-entry database sitting next to it.
//
// This layers them in priority order — your swaps first, then the built-in database, then ratios,
// then the Worker — deduplicates, and labels where each answer came from so the UI can say so.

import SwiftUI

// MARK: - Model

nonisolated enum SubstitutionSource: String, Sendable, Hashable {
    case user      // the user typed this one in
    case builtIn   // StockedDatabase / IngredientIntel
    case worker    // remote, diet-aware

    var label: String {
        switch self {
        case .user:    return "Your swap"
        case .builtIn: return "Stocked"
        case .worker:  return "Suggested"
        }
    }
    /// User entries outrank everything; the Worker is a top-up, not an authority.
    var rank: Int {
        switch self {
        case .user: return 0
        case .builtIn: return 1
        case .worker: return 2
        }
    }
}

nonisolated struct Substitution: Identifiable, Hashable, Sendable {
    let substitute: String
    /// "1:1", "¾ cup + 2 tbsp", or "" when no ratio is known.
    let ratio: String
    let notes: String
    let source: SubstitutionSource
    var vegan: Bool? = nil
    var glutenFree: Bool? = nil

    var id: String { substitute.lowercased() }

    /// One line combining ratio and notes, skipping whichever is missing.
    var detail: String {
        let parts = [ratio, notes].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Engine

@MainActor
enum SubstitutionEngine {

    /// Everything available without a network call. This is what every synchronous UI should use.
    ///
    /// Order: user entries → StockedDatabase (73, with notes) → IngredientIntel (12, with ratios).
    /// A name appearing in more than one source keeps the highest-priority version, but borrows
    /// the ratio from the lower one if it didn't have its own — so "butter → margarine" gets both
    /// the database's note and IngredientIntel's 1:1 ratio.
    static func local(for ingredient: String, userEntries: [UserSubstitutionEntry]) -> [Substitution] {
        let key = ingredient.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return [] }
        var out: [Substitution] = []

        // 1. The user's own swaps. Matched loosely in both directions, the same way the
        //    built-in database matches, so "oat milk" is found when the recipe says "milk".
        for e in userEntries {
            let ing = e.ingredient.lowercased().trimmingCharacters(in: .whitespaces)
            guard !ing.isEmpty, ing == key || key.contains(ing) || ing.contains(key) else { continue }
            out.append(Substitution(substitute: e.substitute, ratio: "", notes: e.notes, source: .user))
        }

        // 2. The 73-entry built-in database (has notes).
        if let entry = StockedDatabase.shared.substitutions(for: key) {
            for s in entry.substitutions {
                out.append(Substitution(substitute: s.substitute, ratio: "", notes: s.notes, source: .builtIn))
            }
        }

        // 3. IngredientIntel's 12 entries (has ratios) — fills in ratios above and adds anything new.
        for s in IngredientIntel.substitutions(key) {
            out.append(Substitution(substitute: s.sub, ratio: s.ratio, notes: "", source: .builtIn))
        }

        return merge(out)
    }

    /// Local results plus the Worker's diet-aware suggestions.
    ///
    /// Local results are returned to the caller first via `onLocal` so the UI can render instantly;
    /// the network is a top-up, not a gate. If the Worker is unreachable the user still sees
    /// everything offline — which is the behaviour the Substitutions tool was missing entirely.
    static func all(for ingredient: String,
                    userEntries: [UserSubstitutionEntry],
                    diet: String? = nil,
                    onLocal: (([Substitution]) -> Void)? = nil) async -> [Substitution] {
        let localResults = local(for: ingredient, userEntries: userEntries)
        onLocal?(localResults)

        let remote = await SmartClient.shared.substitutions(for: ingredient, diet: diet)
        let mapped = remote.map {
            Substitution(substitute: $0.sub, ratio: $0.ratio, notes: "", source: .worker,
                         vegan: $0.vegan, glutenFree: $0.glutenFree)
        }
        return merge(localResults + mapped)
    }

    static func hasAny(for ingredient: String, userEntries: [UserSubstitutionEntry]) -> Bool {
        !local(for: ingredient, userEntries: userEntries).isEmpty
    }

    // MARK: Merging

    /// Dedupe by substitute name, keeping the highest-priority source but salvaging ratio and
    /// notes from the discarded duplicates — otherwise consolidating would lose information.
    private static func merge(_ list: [Substitution]) -> [Substitution] {
        var best: [String: Substitution] = [:]
        for s in list {
            let k = s.id
            guard let existing = best[k] else { best[k] = s; continue }

            let winner = s.source.rank < existing.source.rank ? s : existing
            let other  = s.source.rank < existing.source.rank ? existing : s
            best[k] = Substitution(
                substitute: winner.substitute,
                ratio: winner.ratio.isEmpty ? other.ratio : winner.ratio,
                notes: winner.notes.isEmpty ? other.notes : winner.notes,
                source: winner.source,
                vegan: winner.vegan ?? other.vegan,
                glutenFree: winner.glutenFree ?? other.glutenFree)
        }
        return best.values.sorted {
            $0.source.rank == $1.source.rank ? $0.substitute < $1.substitute
                                             : $0.source.rank < $1.source.rank
        }
    }
}

// MARK: - Shared row

/// One consistent way to draw a substitution, so the four screens that show them stop diverging.
struct SubstitutionRow: View {
    @Environment(AppSession.self) private var session
    let substitution: Substitution
    var showSource = true

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(substitution.substitute)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                if showSource && substitution.source != .builtIn {
                    Text(substitution.source.label)
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(tint.opacity(0.15))
                        .foregroundStyle(tint)
                        .clipShape(Capsule())
                }
                Spacer()
                if substitution.vegan == true {
                    Image(systemName: "leaf.fill").font(.system(size: 10)).foregroundStyle(.green)
                }
                if substitution.glutenFree == true {
                    Text("GF").font(.system(size: 9, weight: .bold)).foregroundStyle(.orange)
                }
            }
            if !substitution.detail.isEmpty {
                Text(substitution.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(session.themeSecondaryText)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch substitution.source {
        case .user:    return session.accentColor
        case .worker:  return .blue
        case .builtIn: return session.themeSecondaryText
        }
    }
}
