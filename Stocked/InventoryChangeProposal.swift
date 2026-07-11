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
    // New item the user bought. Carries the parsed quantity (number of containers) plus the
    // optional container type ("can", "bag") and pack size ("24 oz"), so "bought 3 cans of
    // black beans" and "got a 12 oz bag of rice" record the same detail a manual add would.
    case add(name: String, quantity: Int, containerType: String?, sizeAmount: Double?, sizeUnit: String?)
    // Change the quantity of an existing item by a signed delta ("used 2 cans" → -2).
    case adjustQuantity(delta: Int)
    case clearAll               // remove every inventory item (destructive; always needs confirm)
}

struct ProposedChange: Identifiable, Equatable {
    let id = UUID()
    var itemID: UUID?           // existing inventory item (nil for .add)
    var displayName: String     // what to show the user
    var action: InventoryChangeAction
    var reason: String          // short why ("Used while cooking", "You said you finished it")
    var isConfirmed: Bool = true  // pre-checked; user can toggle off
    /// Provenance of this proposed change, so the shared review UI can badge it and so an
    /// applied .add carries its badge into inventory. nil for changes to existing items where
    /// provenance is unchanged (remove / setLevel).
    var sourceBadge: SourceBadge? = nil

    /// One-line human summary of the effect.
    var effectText: String {
        switch action {
        case .remove:             return "Remove \(displayName)"
        case .setLevel(let l):    return "\(displayName) → \(Int((l * 100).rounded()))% left"
        case .add(_, let q, let ct, let amt, let unit):
            var s = "Add \(displayName)"
            if q > 1 { s += " ×\(q)" }
            if let ct, !ct.isEmpty, ct != "item" { s += " (\(q > 1 ? ct + "s" : ct)" }
            else if let amt, let unit { s += " (\(amt.clean) \(unit)" }
            if let amt, let unit, let ct, !ct.isEmpty, ct != "item" { s += ", \(amt.clean) \(unit) each" }
            if s.contains("(") && !s.hasSuffix(")") { s += ")" }
            return s
        case .adjustQuantity(let d):
            return d < 0 ? "\(displayName) −\(abs(d))" : "\(displayName) +\(d)"
        case .clearAll:           return "Clear ALL inventory items"
        }
    }
    var iconName: String {
        switch action {
        case .remove:         return "trash"
        case .setLevel:       return "arrow.down.circle"
        case .add:            return "plus.circle"
        case .adjustQuantity(let d): return d < 0 ? "minus.circle" : "plus.circle"
        case .clearAll:       return "trash.fill"
        }
    }

    /// Which grouped-review section this change belongs in. clearAll is always surfaced for a
    /// second look; otherwise it follows the badge (defaulting to Confident when unbadged, since
    /// remove/setLevel act on items the user already has).
    var reviewGroup: ReviewGroup {
        if case .clearAll = action { return .needsReview }
        return sourceBadge?.reviewGroup ?? .confident
    }
}

// MARK: - Shared grouped-review helper

/// Groups any badge-carrying, identifiable review items into the three ReviewGroup buckets in
/// display order. Used by receipt review, AI inventory review, recipe-import review, and grocery
/// reconciliation so they all render the same "Confident / Needs review / Ignored" sections
/// instead of each hand-rolling its own grouping. Returns only non-empty groups, ordered.
nonisolated func groupedForReview<Item: Identifiable>(
    _ items: [Item],
    by group: (Item) -> ReviewGroup
) -> [(group: ReviewGroup, items: [Item])] {
    Dictionary(grouping: items, by: group)
        .sorted { $0.key < $1.key }
        .map { (group: $0.key, items: $0.value) }
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
            case .add(let name, let qty, let containerType, let sizeAmount, let sizeUnit):
                var item = LocalInventoryItem(name: name, level: 1.0, quantity: max(1, qty),
                                              containerType: containerType ?? "item",
                                              sizeAmount: sizeAmount, sizeUnit: sizeUnit)
                item.purchaseDate = Date()
                item.sourceBadge  = change.sourceBadge ?? .aiParsed  // assistant-added → AI parsed
                addInventoryItem(item); applied += 1
            case .adjustQuantity(let delta):
                if let id = change.itemID,
                   let idx = inventoryItems.firstIndex(where: { $0.id == id }) {
                    let newQty = inventoryItems[idx].quantity + delta
                    if newQty <= 0 {
                        // Used the last one → remove the row entirely.
                        removeInventoryItem(id: id)
                    } else {
                        withAnimation { inventoryItems[idx].quantity = newQty }
                    }
                    applied += 1
                }
            case .clearAll:
                let count = inventoryItems.count
                // IMPORTANT: only empty the inventory list. Do NOT call the store's clearAll(),
                // which is the nuclear reset (wipes recipes, grocery, profile, and UserDefaults).
                // Restorable via the undo toast the caller shows.
                inventoryItems = []
                applied += count
            }
        }
        return applied
    }
}

// MARK: - Conversational intent → proposals (via the receipt Worker's intent path)

// Dependency-free "all ranges of a substring" — avoids relying on the regex-backed
// String.ranges(of:) overload, so behavior is identical across OS versions.
private extension String {
    func allRanges(of needle: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let r = range(of: needle, options: [], range: searchStart..<endIndex) {
            result.append(r)
            searchStart = r.upperBound
        }
        return result
    }
}

@Observable
final class InventoryIntentParser {
    var isParsing = false
    var lastError: String?

    /// Whether the Worker endpoint is configured (shared with the recipe features).
    static var isAvailable: Bool { StockedWorkerClient.isConfigured }

    /// Sends the utterance + current inventory (name+id) to the Worker, returns proposed changes.
    /// Falls back to nil (caller shows an error) if offline or the Worker isn't configured.
    @MainActor
    func parse(_ utterance: String, store: GuestDataStore) async -> [ProposedChange]? {
        lastError = nil
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        // Local-first: clear-all and other common phrasings are handled entirely on-device, so
        // they work instantly, offline, and even if the Worker is unconfigured. If the local
        // pass already fully covers the request (e.g. "clear all inventory"), skip the network.
        let localChanges = Self.localFallback(trimmed, store: store)
        if localChanges.contains(where: { if case .clearAll = $0.action { return true } else { return false } }) {
            return localChanges
        }

        guard ConnectivityMonitor.isOnlineFlag else {
            // Offline: return whatever the local pass found rather than a hard error.
            if !localChanges.isEmpty { return localChanges }
            lastError = "You're offline — try again with a connection."; return nil
        }

        let urlString = BuildConfig.receiptWorkerURL
        guard !urlString.contains("REPLACE-WITH-YOUR-WORKER"), let url = URL(string: urlString) else {
            if !localChanges.isEmpty { return localChanges }
            lastError = "Natural-language updates need the receipt Worker configured."; return nil
        }

        let inv = store.inventoryItems.map { ["id": $0.id.uuidString, "name": $0.name] }
        let payload: [String: Any] = ["intent": trimmed, "inventory": inv]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else {
            if !localChanges.isEmpty { return localChanges }
            lastError = "Couldn't build request."; return nil
        }

        var req = URLRequest(url: url); req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        BuildConfig.authorizeWorkerRequest(&req)   // X-Stocked-Key shared secret
        req.httpBody = body; req.timeoutInterval = 30

        isParsing = true
        defer { isParsing = false }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 else {
                if !localChanges.isEmpty { return localChanges }
                // Prefer the Worker's own error text (it now says exactly what's wrong —
                // missing secret, upstream failure with status, etc.), else map the code.
                if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let serverError = obj["error"] as? String, !serverError.isEmpty {
                    let upstream = obj["upstreamStatus"] as? Int
                    lastError = upstream != nil ? "\(serverError) (upstream \(upstream!))" : serverError
                    return nil
                }
                switch status {
                case 401:      lastError = "The kitchen assistant rejected the app key — check the Worker's shared key."
                case 422:      lastError = "The kitchen assistant server is out of date — redeploy the Worker."
                case 429:      lastError = "Too many requests right now — try again in a minute."
                case 500...599: lastError = "The kitchen assistant had a server problem. Try again shortly."
                default:       lastError = "The assistant couldn't process that. Try rephrasing."
                }
                return nil
            }
            let changes = Self.decodeChanges(from: data, store: store)
            // If the Worker found nothing, fall back to the local pass (branded-name matching
            // catches things the Worker missed, like "lemon pepper" → the branded row).
            if changes.isEmpty && !localChanges.isEmpty { return localChanges }
            // Merge: keep Worker results, add any local changes it didn't already cover —
            // both removals/level-sets on items the Worker missed (matched by id) and new
            // additions the Worker didn't propose (matched by normalized name).
            if !localChanges.isEmpty {
                let coveredIDs = Set(changes.compactMap { $0.itemID })
                let coveredAddNames = Set(changes.compactMap { change -> String? in
                    if case .add(let name, _, _, _, _) = change.action { return Self.normalize(name) }
                    return nil
                })
                let extra = localChanges.filter { c in
                    if let id = c.itemID { return !coveredIDs.contains(id) }
                    if case .add(let name, _, _, _, _) = c.action { return !coveredAddNames.contains(Self.normalize(name)) }
                    return false
                }
                return changes + extra
            }
            return changes
        } catch {
            if !localChanges.isEmpty { return localChanges }
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
            var itemID = UUID(uuidString: idStr)
            // If the Worker named an item but couldn't resolve its id (very common with
            // branded names — "lemon pepper" vs the stored "Hill Country Fare Lemon Pepper"),
            // resolve it locally against the real inventory before giving up.
            if itemID == nil, !name.isEmpty, action != "add",
               let match = Self.bestInventoryMatch(for: name, in: store.inventoryItems) {
                itemID = match.id
            }
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
                let ct  = (obj["containerType"] as? String)?.trimmingCharacters(in: .whitespaces)
                let amt = obj["sizeAmount"] as? Double
                let unit = (obj["sizeUnit"] as? String)?.trimmingCharacters(in: .whitespaces)
                return ProposedChange(itemID: nil, displayName: name,
                                      action: .add(name: name, quantity: max(1, qty),
                                                   containerType: (ct?.isEmpty ?? true) ? nil : ct,
                                                   sizeAmount: amt,
                                                   sizeUnit: (unit?.isEmpty ?? true) ? nil : unit),
                                      reason: "You said you bought it")
            case "adjustquantity", "adjust":
                guard let itemID else { return nil }
                let delta = (obj["delta"] as? Int) ?? -1
                guard delta != 0 else { return nil }
                return ProposedChange(itemID: itemID, displayName: resolvedName,
                                      action: .adjustQuantity(delta: delta),
                                      reason: delta < 0 ? "You said you used some" : "You said you added some")
            case "clearall", "clear":
                return ProposedChange(itemID: nil, displayName: "Everything",
                                      action: .clearAll, reason: "You asked to clear all items")
            default:
                return nil
            }
        }
    }

    // MARK: - Local matching + fallback (works even when the Worker misses)

    /// Resolve a spoken item name to a real inventory row, tolerant of brand prefixes and
    /// extra words. "lemon pepper" → "Hill Country Fare Lemon Pepper"; "minced onion" →
    /// "Great Value Kosher Minced Onion". Returns nil if nothing is a confident match.
    static func bestInventoryMatch(for spoken: String, in items: [LocalInventoryItem]) -> LocalInventoryItem? {
        let q = normalize(spoken)
        guard !q.isEmpty else { return nil }
        let qWords = Set(q.split(separator: " ").map(String.init))

        var best: (item: LocalInventoryItem, score: Double)?
        for item in items {
            let cand = normalize(item.name)
            guard !cand.isEmpty else { continue }
            let candWords = Set(cand.split(separator: " ").map(String.init))

            var score = 0.0
            // Whole spoken phrase appears in the item name (strongest signal).
            if cand.contains(q) { score = 0.95 }
            // Or every spoken word appears somewhere in the item name (brand words extra).
            else if !qWords.isEmpty && qWords.isSubset(of: candWords) { score = 0.9 }
            else {
                // Word overlap ratio, with fuzzy word matching for typos/plurals.
                let overlap = qWords.filter { qw in
                    candWords.contains(where: { FuzzyMatch.matches(qw, $0) || $0.contains(qw) || qw.contains($0) })
                }.count
                if !qWords.isEmpty { score = Double(overlap) / Double(qWords.count) * 0.85 }
            }
            if score > (best?.score ?? 0) { best = (item, score) }
        }
        // Require a reasonably confident match so we never remove the wrong thing.
        if let best, best.score >= 0.6 { return best.item }
        return nil
    }

    /// Lowercased, punctuation-stripped, whitespace-collapsed.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // Number words → value, for "two cans", "a dozen eggs".
    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "dozen": 12, "couple": 2, "few": 3, "half": 1
    ]
    private static let containerWords: Set<String> = [
        "can","cans","bag","bags","box","boxes","bottle","bottles","jar","jars",
        "carton","cartons","case","cases","pack","packs","package","packages",
        "bunch","bunches","loaf","loaves","dozen","container","containers","tub","tubs",
        "stick","sticks","block","blocks","clove","cloves","head","heads"
    ]
    private static let measureUnits: Set<String> = [
        "oz","ounce","ounces","lb","lbs","pound","pounds","g","gram","grams","kg",
        "ml","l","liter","liters","litre","litres","gallon","gallons","qt","quart",
        "quarts","pint","pints","cup","cups","count","ct","pack"
    ]

    /// Parses a leading quantity / container / size out of a spoken noun phrase.
    /// "3 cans of black beans"   → (qty 3, container "can", size nil, name "black beans")
    /// "a 24 oz bag of rice"     → (qty 1, container "bag", size 24 oz, name "rice")
    /// "2 lbs of chicken"        → (qty 1, container nil, size 2 lb, name "chicken", removeQtyNil)
    static func parseQuantityUnit(_ phrase: String)
        -> (quantity: Int, containerType: String?, sizeAmount: Double?, sizeUnit: String?, name: String) {
        var tokens = phrase.lowercased()
            .split(separator: " ").map(String.init)
            .filter { $0 != "of" }
        var quantity = 1
        var container: String?
        var sizeAmount: Double?
        var sizeUnit: String?

        func singular(_ w: String) -> String {
            if w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
            if w.hasSuffix("es") && (w.hasSuffix("xes") || w.hasSuffix("ses") || w.hasSuffix("ches")) { return String(w.dropLast(2)) }
            if w.hasSuffix("s") && w.count > 3 { return String(w.dropLast()) }
            return w
        }

        var i = 0
        var consumed = 0
        while i < tokens.count && i < 4 {
            let t = tokens[i]
            if let n = Int(t) {
                // Bare number: could be a count (2 cans) or a size (24 oz) — decided by the next word.
                if i + 1 < tokens.count, measureUnits.contains(singular(tokens[i+1])) {
                    sizeAmount = Double(n); sizeUnit = tokens[i+1]; consumed = i + 2; i += 2; continue
                }
                quantity = max(1, n); consumed = i + 1; i += 1; continue
            }
            if let d = Double(t), i + 1 < tokens.count, measureUnits.contains(singular(tokens[i+1])) {
                sizeAmount = d; sizeUnit = tokens[i+1]; consumed = i + 2; i += 2; continue
            }
            if let n = numberWords[t] { quantity = max(1, n); consumed = i + 1; i += 1; continue }
            if containerWords.contains(t) {
                container = singular(t); consumed = i + 1; i += 1; continue
            }
            break
        }
        let name = tokens[min(consumed, tokens.count)...].joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (quantity, container, sizeAmount, sizeUnit, name.isEmpty ? phrase : name)
    }

    /// A best-effort LOCAL parse used when the Worker is unavailable or returns nothing.
    /// Handles the common phrasings entirely on-device so the assistant is never dead:
    ///   • "clear all / wipe everything / empty my inventory" → clearAll
    ///   • "used the rest of X / finished X / out of X / ran out of X" → remove X
    ///   • "used some X / half the X / running low on X" → setLevel
    ///   • "bought X / picked up X / got X" → add X
    static func localFallback(_ utterance: String, store: GuestDataStore) -> [ProposedChange] {
        let lower = " " + utterance.lowercased() + " "

        // Clear-all intent.
        let clearPhrases = ["clear all", "clear everything", "clear my inventory", "clear the inventory",
                            "wipe everything", "wipe all", "wipe my inventory", "empty my inventory",
                            "empty the inventory", "empty everything", "remove everything",
                            "delete everything", "delete all", "start over", "reset my inventory",
                            "reset inventory", "clear out everything", "get rid of everything"]
        if clearPhrases.contains(where: { lower.contains($0) }) {
            return [ProposedChange(itemID: nil, displayName: "Everything",
                                   action: .clearAll, reason: "You asked to clear all items")]
        }

        var out: [ProposedChange] = []
        var usedIDs = Set<UUID>()

        // Removal phrasings: capture the noun after the phrase and match it to inventory.
        let removePhrases = ["used the rest of", "used up the", "used up", "finished the", "finished off the",
                             "finished", "ran out of", "run out of", "out of the", "out of",
                             "used all the", "used all", "no more", "gone", "empty on"]
        for phrase in removePhrases {
            for range in lower.allRanges(of: phrase) {
                let tail = String(lower[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if tail.isEmpty { continue }
                // Take up to the next few words as the candidate noun.
                let candidate = tail.split(separator: " ").prefix(5).joined(separator: " ")
                let parsed = parseQuantityUnit(candidate)
                // Match on the noun with the quantity stripped off.
                if let m = bestInventoryMatch(for: parsed.name, in: store.inventoryItems), !usedIDs.contains(m.id) {
                    usedIDs.insert(m.id)
                    // "used 2 cans of X" with an explicit count and more than one on hand →
                    // decrement rather than delete. "used the rest / finished" → full remove.
                    let saidCount = parsed.quantity > 0 && (parsed.containerType != nil || candidate.first(where: { $0.isNumber }) != nil)
                    let isRest = phrase.contains("rest") || phrase.contains("all") || phrase.contains("finished")
                                 || phrase.contains("ran out") || phrase.contains("run out")
                                 || phrase.contains("no more") || phrase == "gone"
                    if saidCount && !isRest && m.quantity > parsed.quantity {
                        out.append(ProposedChange(itemID: m.id, displayName: m.name,
                                                  action: .adjustQuantity(delta: -parsed.quantity),
                                                  reason: "You said you used \(parsed.quantity)"))
                    } else {
                        out.append(ProposedChange(itemID: m.id, displayName: m.name,
                                                  action: .remove, reason: "You said you finished it"))
                    }
                }
            }
        }

        // Low / partial phrasings → set to a low level.
        let lowPhrases = ["running low on", "low on", "almost out of", "half the", "halfway through the",
                          "getting low on", "used some", "used some of the"]
        for phrase in lowPhrases {
            for range in lower.allRanges(of: phrase) {
                let tail = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let candidate = tail.split(separator: " ").prefix(4).joined(separator: " ")
                if candidate.isEmpty { continue }
                if let m = bestInventoryMatch(for: candidate, in: store.inventoryItems), !usedIDs.contains(m.id) {
                    usedIDs.insert(m.id)
                    let level = phrase.contains("half") ? 0.5 : 0.25
                    out.append(ProposedChange(itemID: m.id, displayName: m.name,
                                              action: .setLevel(level), reason: "You said you used some"))
                }
            }
        }

        // Add phrasings: "bought / picked up / got / added / grabbed / restocked X, Y, and Z".
        // The tail after the phrase is split on commas and "and" into individual new items.
        let addPhrases = ["just bought", "bought", "picked up", "i got", "grabbed", "added",
                          "restocked", "got some", "purchased", "stocked up on"]
        var addedNames = Set<String>()
        for phrase in addPhrases {
            for range in lower.allRanges(of: " " + phrase + " ") {
                let tail = String(lower[range.upperBound...])
                // Stop the item list at a clause boundary so we don't swallow the whole sentence.
                let clause = tail.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? tail
                let names = clause
                    .replacingOccurrences(of: " and ", with: ",")
                    .replacingOccurrences(of: "&", with: ",")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .prefix(8)
                for raw in names {
                    // Trim leading filler, then parse quantity/container/size out of the phrase.
                    let stripped = raw
                        .split(separator: " ")
                        .drop(while: { ["the","my","more"].contains(String($0)) })
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespaces)
                    let phrase = stripped.isEmpty ? raw : stripped
                    let parsed = parseQuantityUnit(phrase)
                    let title = parsed.name.trimmingCharacters(in: .whitespaces)
                    guard title.count >= 2 else { continue }
                    let key = normalize(title)
                    guard !key.isEmpty, addedNames.insert(key).inserted else { continue }
                    // If it already resolves to an existing item, skip — that's a restock the
                    // user can do explicitly; here we only propose genuinely new additions.
                    if bestInventoryMatch(for: title, in: store.inventoryItems) != nil { continue }
                    out.append(ProposedChange(itemID: nil, displayName: title.capitalized,
                                              action: .add(name: title.capitalized,
                                                           quantity: parsed.quantity,
                                                           containerType: parsed.containerType,
                                                           sizeAmount: parsed.sizeAmount,
                                                           sizeUnit: parsed.sizeUnit),
                                              reason: "You said you bought it"))
                }
            }
        }

        return out
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
    // Identity-driven sheet payload — .sheet(item:) presents reliably on the first tap,
    // unlike a separate Bool plus optional pair, which could open a blank sheet and require
    // sending the message twice.
    private struct ReviewPayload: Identifiable { let id = UUID(); let changes: [ProposedChange] }
    @State private var reviewPayload: ReviewPayload?
    @State private var noChangesNote = false
    @FocusState private var focused: Bool

    private let examples = [
        "I used the rest of the lemon pepper",
        "Finished the milk and eggs",
        "Bought tofu, rice, and oat milk",
        "Down to about half the rice",
        "Clear all my inventory"
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
            .sheet(item: $reviewPayload) { payload in
                ReconcileSheet(
                    title: "Confirm Changes",
                    subtitle: "Here's what I understood. Uncheck anything that's wrong, then apply.",
                    changes: payload.changes,
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
        reviewPayload = ReviewPayload(changes: result)
    }
}
