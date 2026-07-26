// KitchenAssistant.swift — Feature 1: Conversational Kitchen Assistant (first slice).
//
// Ask the kitchen questions in plain language and get an answer grounded in YOUR pantry:
// "what's expiring?", "do I have butter?", "what's in the freezer?", "what should I use up?"
//
// This slice is deterministic and fully offline — it reads inventory directly, so it's instant,
// costs nothing, and can't hallucinate. `escalateToAI` marks the single seam where a future
// version can hand an unmatched question to the Worker's AI routes.

import SwiftUI

// MARK: - Intent engine (pure, testable, offline)

nonisolated struct AssistantAnswer: Identifiable, Sendable {
    let id = UUID()
    let question: String
    let text: String
    let items: [String]        // supporting detail lines (may be empty)
}

/// `nonisolated` so App Intents (#17) can call it off the main actor while the app is closed.
/// Everything here is pure over value types, so there is nothing to isolate.
nonisolated enum KitchenAssistantEngine {

    /// Answer a free-text question from the pantry. Returns nil when nothing matched
    /// (the caller can then offer AI escalation).
    static func answer(_ raw: String, items: [LocalInventoryItem]) -> AssistantAnswer? {
        let q = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }

        // — expiring / use up —
        if q.contains("expir") || q.contains("use up") || q.contains("going bad") || q.contains("spoil") {
            let soon = expiringSoon(items, within: 7)
            if soon.isEmpty {
                return AssistantAnswer(question: raw, text: "Nothing is expiring in the next week. Nice.", items: [])
            }
            return AssistantAnswer(
                question: raw,
                text: soon.count == 1 ? "1 item needs using soon:" : "\(soon.count) items need using soon:",
                items: soon.map { line($0) })
        }

        // — what's in <zone> —
        if let zone = zoneMentioned(q) {
            let inZone = items.filter { $0.storageCategory == zone }
            return AssistantAnswer(
                question: raw,
                text: inZone.isEmpty ? "Your \(zone.rawValue.lowercased()) is empty."
                                     : "\(inZone.count) items in your \(zone.rawValue.lowercased()):",
                items: inZone.prefix(25).map { line($0) })
        }

        // — counts —
        if q.contains("how many") && (q.contains("item") || q.contains("thing") || q.contains("total")) {
            return AssistantAnswer(question: raw, text: "You're tracking \(items.count) items.", items: [])
        }

        // — do I have / how much <thing> —
        if let term = searchTerm(in: q) {
            let hits = items.filter { $0.name.lowercased().contains(term) }
            if hits.isEmpty {
                return AssistantAnswer(question: raw, text: "No — nothing matching “\(term)” is in your kitchen.", items: [])
            }
            let total = hits.reduce(0) { $0 + max(0, $1.quantity) }
            return AssistantAnswer(
                question: raw,
                text: hits.count == 1 ? "Yes — \(hits[0].name)." : "Yes — \(hits.count) matches (\(total) total).",
                items: hits.prefix(12).map { line($0) })
        }

        return nil
    }

    /// Marks where a future version hands off to the Worker's AI for open-ended questions.
    static let escalateToAI = false

    // MARK: helpers

    static func expiringSoon(_ items: [LocalInventoryItem], within days: Int) -> [LocalInventoryItem] {
        let cutoff = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
        return items
            .filter { if let d = $0.expirationDate { return d <= cutoff } else { return false } }
            .sorted { ($0.expirationDate ?? .distantFuture) < ($1.expirationDate ?? .distantFuture) }
    }

    private static func zoneMentioned(_ q: String) -> StorageCategory? {
        if q.contains("freezer") || q.contains("frozen") { return .freezer }
        if q.contains("fridge") || q.contains("refrigerat") { return .fridge }
        if q.contains("pantry") { return .pantry }
        if q.contains("staple") || q.contains("spice") { return .staples }
        return nil
    }

    /// Pull the subject out of "do I have X" / "how much X" / "any X left".
    private static func searchTerm(in q: String) -> String? {
        let leads = ["do i have any ", "do i have ", "how much ", "how many ", "any ", "is there any ", "got any "]
        for lead in leads where q.hasPrefix(lead) {
            var t = String(q.dropFirst(lead.count))
            for tail in [" left", " right now", " in the fridge", " in the freezer", " in the pantry", "?"] {
                t = t.replacingOccurrences(of: tail, with: "")
            }
            let cleaned = t.trimmingCharacters(in: CharacterSet(charactersIn: " ?."))
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    private static func line(_ i: LocalInventoryItem) -> String {
        var s = i.name
        if i.quantity > 1 { s += " ×\(i.quantity)" }
        if let d = i.expirationDate {
            let days = Calendar.current.dateComponents([.day], from: Date(), to: d).day ?? 0
            s += days < 0 ? " · expired" : (days == 0 ? " · today" : " · \(days)d")
        }
        return s
    }
}

// MARK: - UI

struct KitchenAssistantView: View {
    @Environment(AppSession.self) private var session
    @State private var input = ""
    @State private var thread: [AssistantAnswer] = []
    @State private var unmatched = false

    private let suggestions = ["What's expiring?", "What's in the freezer?", "Do I have butter?", "What should I use up?"]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if thread.isEmpty {
                        Text("Ask about your kitchen")
                            .font(.system(size: 20, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text("Answers come straight from your inventory — instant, and always accurate.")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.6))
                    }
                    ForEach(thread) { a in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(a.question)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                            Text(a.text)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(session.themeTextColor)
                            ForEach(Array(a.items.enumerated()), id: \.offset) { _, line in
                                HStack(spacing: 8) {
                                    Circle().fill(session.accentColor).frame(width: 5, height: 5)
                                    Text(line).font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.85))
                                }
                            }
                        }
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(session.themeTextColor.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    if unmatched {
                        Text("I can answer questions about what you have, what's expiring, and what's in each zone.")
                            .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                }
                .padding(18)
            }

            // Suggestion chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(suggestions, id: \.self) { s in
                        Button { ask(s) } label: {
                            Text(s).font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(session.accentColor.opacity(0.14))
                                .foregroundStyle(session.accentColor)
                                .clipShape(Capsule())
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 18)
            }
            .padding(.bottom, 8)

            HStack(spacing: 10) {
                TextField("Ask about your kitchen…", text: $input)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(session.themeTextColor.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .onSubmit { ask(input) }
                Button { ask(input) } label: {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28)).foregroundStyle(session.accentColor)
                }
                .buttonStyle(.plain)
                .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 18).padding(.bottom, 14)
        }
        .stockedScreen()
        .withInventoryIndex(session.guestStore)
        .navigationTitle("Kitchen Assistant")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func ask(_ text: String) {
        let q = text.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        HapticManager.light()
        if let a = KitchenAssistantEngine.answer(q, items: session.guestStore.inventoryItems) {
            thread.append(a); unmatched = false
        } else {
            thread.append(AssistantAnswer(question: q, text: "I'm not sure about that one yet.", items: []))
            unmatched = true
        }
        input = ""
    }
}
