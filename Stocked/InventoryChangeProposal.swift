// InventoryChangeProposal.swift
// ─────────────────────────────────────────────────────────────────────────────
// Shared "apply inventory changes" primitive used by THREE features:
//   1. Decrement     — after cooking / when an item ages out, propose using it up.
//   2. Drift-correct  — "do you still have these?" reconciliation for stale items.
//   3. Conversational — "I used the rest of the broccoli" parsed (via Worker) into changes.
//
// All three produce a [ProposedChange]; the user confirms/rejects each in ReconcileSheet;
// confirmed changes are applied through the EXISTING GuestDataStore mutators
// (updateInventoryLevel / removeInventoryItem / addInventoryItem) so there's one code path
// for actually touching inventory.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

// MARK: - Model

enum InventoryChangeAction: Equatable {
    case remove                 // set to empty / remove the row
    case setLevel(Double)       // reduce (or set) the fill level 0.0–1.0
    case add(name: String, quantity: Int)   // new item the user says they bought
}

struct ProposedChange: Identifiable, Equatable {
    let id = UUID()
    var itemID: UUID?           // existing inventory item (nil for .add)
    var displayName: String     // what to show the user
    var action: InventoryChangeAction
    var reason: String          // short why ("Used while cooking", "You said you finished it")
    var isConfirmed: Bool = true  // pre-checked; user can toggle off

    /// One-line human summary of the effect.
    var effectText: String {
        switch action {
        case .remove:             return "Remove \(displayName)"
        case .setLevel(let l):    return "\(displayName) → \(Int((l * 100).rounded()))% left"
        case .add(_, let q):      return "Add \(displayName)\(q > 1 ? " ×\(q)" : "")"
        }
    }
    var iconName: String {
        switch action {
        case .remove:   return "trash"
        case .setLevel: return "arrow.down.circle"
        case .add:      return "plus.circle"
        }
    }
}

// MARK: - Apply (single code path to mutate inventory)

extension GuestDataStore {
    /// Applies the confirmed changes through existing mutators. Returns a count applied.
    @discardableResult
    func applyProposedChanges(_ changes: [ProposedChange]) -> Int {
        var applied = 0
        for change in changes where change.isConfirmed {
            switch change.action {
            case .remove:
                if let id = change.itemID { removeInventoryItem(id: id); applied += 1 }
            case .setLevel(let level):
                if let id = change.itemID {
                    updateInventoryLevel(id: id, level: max(0, min(1, level))); applied += 1
                }
            case .add(let name, let qty):
                var item = LocalInventoryItem(name: name, level: 1.0, quantity: max(1, qty))
                item.purchaseDate = Date()
                addInventoryItem(item); applied += 1
            }
        }
        return applied
    }
}

// MARK: - Conversational intent → proposals (via the receipt Worker's intent path)

@Observable
final class InventoryIntentParser {
    var isParsing = false
    var lastError: String?

    /// Sends the utterance + current inventory (name+id) to the Worker, returns proposed changes.
    /// Falls back to nil (caller shows an error) if offline or the Worker isn't configured.
    @MainActor
    func parse(_ utterance: String, store: GuestDataStore) async -> [ProposedChange]? {
        lastError = nil
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard ConnectivityMonitor.isOnlineFlag else { lastError = "You're offline — try again with a connection."; return nil }

        let urlString = BuildConfig.receiptWorkerURL
        guard !urlString.contains("REPLACE-WITH-YOUR-WORKER"), let url = URL(string: urlString) else {
            lastError = "Natural-language updates need the receipt Worker configured."; return nil
        }

        let inv = store.inventoryItems.map { ["id": $0.id.uuidString, "name": $0.name] }
        let payload: [String: Any] = ["intent": trimmed, "inventory": inv]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { lastError = "Couldn't build request."; return nil }

        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&req)   // X-Stocked-Key shared secret
        req.httpBody = body; req.timeoutInterval = 30

        isParsing = true
        defer { isParsing = false }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { lastError = "The assistant couldn't process that. Try rephrasing."; return nil }
            return Self.decodeChanges(from: data, store: store)
        } catch {
            lastError = "Something went wrong. Try again."; return nil
        }
    }

    /// Parses the Worker's JSON array (possibly wrapped in a content envelope) into ProposedChanges.
    static func decodeChanges(from data: Data, store: GuestDataStore) -> [ProposedChange] {
        // The Worker may return either the raw array or {content:[{type:text,text:"..."}]}.
        var jsonText: String = String(data: data, encoding: .utf8) ?? ""
        if let env = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let content = env["content"] as? [[String: Any]] {
            jsonText = content.compactMap { $0["text"] as? String }.joined()
        }
        let clean = jsonText
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let arr = try? JSONSerialization.jsonObject(with: Data(clean.utf8)) as? [[String: Any]] else { return [] }

        return arr.compactMap { obj -> ProposedChange? in
            let action = (obj["action"] as? String ?? "").lowercased()
            let idStr  = obj["id"] as? String ?? ""
            let name   = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let itemID = UUID(uuidString: idStr)
            // Resolve a display name from the store if we matched an id.
            let resolvedName: String = {
                if let itemID, let it = store.inventoryItems.first(where: { $0.id == itemID }) { return it.name }
                return name
            }()
            guard !resolvedName.isEmpty || action == "add" else { return nil }

            switch action {
            case "remove":
                guard let itemID else { return nil }   // can't remove what we didn't match
                return ProposedChange(itemID: itemID, displayName: resolvedName,
                                      action: .remove, reason: "You said you finished it")
            case "setlevel":
                guard let itemID else { return nil }
                let level = (obj["level"] as? Double) ?? 0.5
                return ProposedChange(itemID: itemID, displayName: resolvedName,
                                      action: .setLevel(max(0, min(1, level))),
                                      reason: "You said you used some")
            case "add":
                guard !name.isEmpty else { return nil }
                let qty = (obj["quantity"] as? Int) ?? 1
                return ProposedChange(itemID: nil, displayName: name,
                                      action: .add(name: name, quantity: max(1, qty)),
                                      reason: "You said you bought it")
            default:
                return nil
            }
        }
    }
}

// MARK: - Shared reconcile sheet (the one UI all three sources use)

struct ReconcileSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    let title: String
    let subtitle: String
    @State var changes: [ProposedChange]
    var onApply: (Int) -> Void = { _ in }

    private var confirmedCount: Int { changes.filter { $0.isConfirmed }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(subtitle)
                        .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20).padding(.top, 8)

                    if changes.isEmpty {
                        emptyState
                    } else {
                        ForEach($changes) { $change in
                            changeRow($change)
                        }
                    }
                }
                .padding(.bottom, 120)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(session.themeTextColor.opacity(0.6))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !changes.isEmpty {
                    Button {
                        let n = session.guestStore.applyProposedChanges(changes)
                        HapticManager.success()
                        onApply(n)
                        dismiss()
                    } label: {
                        Text(confirmedCount == 0 ? "Nothing selected"
                                                 : "Apply \(confirmedCount) \(confirmedCount == 1 ? "change" : "changes")")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(confirmedCount == 0 ? Color.gray.opacity(0.5) : session.themeButtonColor)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(confirmedCount == 0)
                    .padding(.horizontal, 20).padding(.bottom, 12)
                    .background(.ultraThinMaterial)
                }
            }
        }
    }

    private func changeRow(_ change: Binding<ProposedChange>) -> some View {
        Button {
            withAnimation(.spring(response: 0.2)) { change.wrappedValue.isConfirmed.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: change.wrappedValue.isConfirmed ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(change.wrappedValue.isConfirmed ? Color.stockedGreen : session.themeTextColor.opacity(0.3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.wrappedValue.effectText)
                        .font(.system(size: 15, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text(change.wrappedValue.reason)
                        .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.45))
                }
                Spacer()
                Image(systemName: change.wrappedValue.iconName)
                    .font(.system(size: 16)).foregroundStyle(session.themeTextColor.opacity(0.35))
            }
            .padding(14)
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(change.wrappedValue.isConfirmed ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40)).foregroundStyle(session.themeTextColor.opacity(0.3))
            Text("Nothing to update")
                .font(.system(size: 16, design: .serif)).foregroundStyle(session.themeTextColor.opacity(0.6))
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

// MARK: - Conversational Quick Update (Source 3)
// A text box where the user types what changed in plain language; we parse it (via the
// Worker) into proposed changes and hand off to ReconcileSheet to confirm + apply.
struct QuickUpdateSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    @State private var text = ""
    @State private var parser = InventoryIntentParser()
    @State private var proposals: [ProposedChange]?
    @State private var showReconcile = false
    @State private var noChangesNote = false
    @FocusState private var focused: Bool

    private let examples = [
        "I used the rest of the broccoli",
        "Finished the milk and eggs",
        "Bought tofu, rice, and oat milk",
        "Down to about half the rice"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Tell me what you bought, used, or ran out of — in your own words. I'll suggest the changes and you confirm them.")
                        .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    // Input
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("e.g. \"I finished the milk and used half the rice\"")
                                .font(.system(size: 15)).foregroundStyle(session.themeTextColor.opacity(0.35))
                                .padding(.horizontal, 14).padding(.vertical, 14)
                        }
                        TextEditor(text: $text)
                            .font(.system(size: 15))
                            .foregroundStyle(session.themeTextColor)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 110)
                            .padding(.horizontal, 10).padding(.vertical, 8)
                            .focused($focused)
                    }
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    if let err = parser.lastError {
                        Text(err).font(.system(size: 13)).foregroundStyle(.red)
                    }
                    if noChangesNote {
                        Text("I couldn't find anything to change from that. Try naming specific items.")
                            .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.6))
                    }

                    // Examples
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TRY").font(.system(size: 10, weight: .bold)).tracking(1)
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                        ForEach(examples, id: \.self) { ex in
                            Button { text = ex; focused = false } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "quote.bubble").font(.system(size: 12))
                                    Text(ex).font(.system(size: 13))
                                    Spacer()
                                }
                                .foregroundStyle(session.themeTextColor.opacity(0.7))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(session.themeTextColor.opacity(0.05))
                                .clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Quick Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(session.themeTextColor.opacity(0.6))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { Task { await runParse() } } label: {
                    HStack {
                        if parser.isParsing { ProgressView().tint(.white) }
                        Text(parser.isParsing ? "Reading…" : "Review changes")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(text.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray.opacity(0.5) : session.themeButtonColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(parser.isParsing || text.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            .sheet(isPresented: $showReconcile) {
                ReconcileSheet(
                    title: "Confirm Changes",
                    subtitle: "Here's what I understood. Uncheck anything that's wrong, then apply.",
                    changes: proposals ?? [],
                    onApply: { _ in dismiss() }   // close the whole flow after applying
                ).environment(session)
            }
        }
    }

    private func runParse() async {
        noChangesNote = false
        focused = false
        let result = await parser.parse(text, store: session.guestStore)
        guard let result else { return }   // parser.lastError is shown
        if result.isEmpty { noChangesNote = true; return }
        proposals = result
        showReconcile = true
    }
}
