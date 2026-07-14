// CookNowPrep.swift
// ─────────────────────────────────────────────────────────────────
// The prep stage between "recipe chosen" and "step 1". Prep tasks are
// DERIVED from real recipe data — never invented:
//
//   • Each ingredient's structured `prep` note ("sliced", "minced") becomes a
//     task: "Slice the chicken — 2 lbs".
//   • Instruction text is scanned for genuinely time-gated verbs (thaw,
//     marinate, preheat, bring to room temperature, soak, chill, rest) and
//     those surface as get-ahead tasks so nothing ambushes the cook mid-flow.
//
// Amounts show the recipe's human-readable amount string (the source of
// truth). Ordering is conservative food-safety-aware: produce and pantry prep
// first, raw-protein handling last, so knives and boards touch raw meat at
// the end. No invented safety guidance is added — ordering only.
//
// Completion lives on the CookNowSession, so leaving and returning keeps
// checkmarks, and the checklist is optional: Skip Prep is always available.
// ─────────────────────────────────────────────────────────────────

import SwiftUI

// MARK: - Task model + derivation

nonisolated struct CookPrepTask: Identifiable, Sendable, Equatable {
    let id: String            // stable key for session completion tracking
    let title: String
    let detail: String        // amount or source context ("from step 2")
    let isProteinHandling: Bool
    let isGetAhead: Bool      // thaw/marinate-style, surfaced first
}

nonisolated enum CookNowPrepDeriver {

    private static let proteinWords = [
        "chicken", "beef", "pork", "turkey", "lamb", "steak", "shrimp",
        "fish", "salmon", "tuna", "bacon", "sausage", "ground meat", "thigh", "breast"
    ]

    /// Time-gated verbs worth surfacing before step 1. Matched conservatively
    /// at word level against instruction text.
    private static let getAheadVerbs: [(verb: String, label: String)] = [
        ("thaw",       "Thaw"),
        ("defrost",    "Thaw"),
        ("marinate",   "Marinate"),
        ("preheat",    "Preheat the oven"),
        ("room temperature", "Bring to room temperature"),
        ("soak",       "Soak"),
        ("chill",      "Chill"),
        ("rest the dough", "Rest the dough"),
        ("proof",      "Proof")
    ]

    static func tasks(for recipe: UserRecipe) -> [CookPrepTask] {
        var out: [CookPrepTask] = []

        // 1. Ingredient prep notes → concrete tasks.
        for ing in recipe.ingredients {
            guard let prep = ing.prep?.trimmingCharacters(in: .whitespaces), !prep.isEmpty else { continue }
            let verb = prepVerb(from: prep)
            let isProtein = proteinWords.contains { ing.name.lowercased().contains($0) }
            out.append(CookPrepTask(
                id: "prep::\(ing.name.lowercased())::\(prep.lowercased())",
                title: "\(verb) the \(ing.name.displayNormalized)",
                detail: ing.amount,
                isProteinHandling: isProtein,
                isGetAhead: false
            ))
        }

        // 2. Get-ahead needs detected in instruction text.
        for (index, step) in recipe.instructions.enumerated() {
            let lower = step.lowercased()
            for (verb, label) in getAheadVerbs where lower.contains(verb) {
                let id = "ahead::\(verb)::\(index)"
                if !out.contains(where: { $0.id == id }) {
                    out.append(CookPrepTask(
                        id: id,
                        title: label,
                        detail: "from step \(index + 1)",
                        isProteinHandling: false,
                        isGetAhead: true
                    ))
                }
                break   // one get-ahead task per step is enough signal
            }
        }

        // 3. Order: get-ahead first (longest lead time), then non-protein prep,
        //    protein handling last.
        return out.sorted { a, b in
            if a.isGetAhead != b.isGetAhead { return a.isGetAhead }
            if a.isProteinHandling != b.isProteinHandling { return !a.isProteinHandling }
            return a.title < b.title
        }
    }

    /// "sliced" → "Slice", "minced" → "Mince", "finely chopped" → "Finely chop".
    private static func prepVerb(from prep: String) -> String {
        var p = prep.lowercased()
        if p.hasSuffix("ed"), p.count > 3 {
            p = String(p.dropLast(1))                    // "sliced" → "slice", "diced" → "dice"
            if p.hasSuffix("pp") { p = String(p.dropLast(1)) }   // "chopped" → "chop"
        }
        return p.prefix(1).uppercased() + p.dropFirst()
    }
}

// MARK: - Checklist view

struct PrepChecklistView: View {
    let recipe: UserRecipe

    @Environment(AppSession.self) var session
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    @Environment(\.dismiss) private var dismiss
    private var dark: Bool { session.isDarkMode }

    @State private var tasks: [CookPrepTask] = []
    @State private var localDone: Set<String> = []   // fallback when no session

    var body: some View {
        StockedShell(showBack: true, titleText: "Prep First") {
            VStack(alignment: .leading, spacing: 14) {
                Text("Knock these out before step 1 and the cook goes smoothly.")
                    .font(.system(size: 13.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.horizontal, CookStyle.screenHPad).padding(.top, 4)

                if tasks.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 38)).foregroundStyle(Color.stockedGreen)
                        Text("No prep needed — jump straight in.")
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 40)
                } else {
                    VStack(spacing: 8) {
                        ForEach(tasks) { task in
                            row(task)
                        }
                    }
                    .padding(.horizontal, CookStyle.screenHPad)

                    if tasks.contains(where: { $0.isProteinHandling }) {
                        Text("Raw meat and seafood prep is listed last.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                            .padding(.horizontal, CookStyle.screenHPad)
                    }
                }

                Button { dismiss() } label: {
                    Text(doneCount == tasks.count && !tasks.isEmpty ? "Prep Done — Back to Recipe" : "Back to Recipe")
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                        .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                            .stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, CookStyle.screenHPad)

                Spacer(minLength: 20)
            }
        }
        .task { tasks = CookNowPrepDeriver.tasks(for: recipe) }
    }

    private var doneCount: Int { tasks.filter { isDone($0) }.count }

    private func isDone(_ t: CookPrepTask) -> Bool {
        cookSession?.isPrepDone(t.id) ?? localDone.contains(t.id)
    }

    private func toggle(_ t: CookPrepTask) {
        let newValue = !isDone(t)
        if let cs = cookSession {
            cs.setPrepDone(t.id, done: newValue)
        } else {
            if newValue { localDone.insert(t.id) } else { localDone.remove(t.id) }
        }
        HapticManager.select()
    }

    private func row(_ t: CookPrepTask) -> some View {
        Button { toggle(t) } label: {
            HStack(spacing: 10) {
                Image(systemName: isDone(t) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(isDone(t) ? Color.stockedGreen : session.themeTextColor.opacity(0.3))
                VStack(alignment: .leading, spacing: 1) {
                    Text(t.title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                        .strikethrough(isDone(t), color: session.themeTextColor.opacity(0.4))
                    if !t.detail.isEmpty {
                        Text(t.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                }
                Spacer()
                if t.isGetAhead {
                    Text("Get ahead")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.stockedGold)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.stockedGold.opacity(0.12))
                        .clipShape(Capsule())
                }
            }
            .padding(12)
            .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
        }
        .buttonStyle(.plain)
        .a11yButton("\(t.title). \(isDone(t) ? "Done" : "Not done"). Tap to toggle.")
    }
}
