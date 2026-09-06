import Foundation

nonisolated struct RecipeMigrationIdentity: Sendable {
    var id: UUID
    var title: String
    var sourceURL: String?
    var contentHash: String?

    var keys: Set<String> {
        var keys: Set<String> = []
        let title = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if !title.isEmpty { keys.insert("title:\(title)") }
        if let contentHash, !contentHash.isEmpty { keys.insert("content:\(contentHash)") }
        if let sourceURL, var url = URLComponents(string: sourceURL),
           ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil {
            url.scheme = "https"; url.host = url.host?.lowercased(); url.fragment = nil
            url.queryItems = url.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && !["fbclid", "gclid"].contains($0.name.lowercased()) }
            if url.queryItems?.isEmpty == true { url.queryItems = nil }
            if let normalized = url.string { keys.insert("source:\(normalized)") }
        }
        return keys
    }
}

nonisolated enum RecipeMigrationSafety {
    static let maximumUndoRecords = 250

    /// Keep deterministic insertion order. Forgetting an undo fingerprint never deletes a recipe.
    static func retainingNewest(_ ids: [UUID], appending id: UUID) -> [UUID] {
        let withoutRepeat = ids.filter { $0 != id }
        return Array((withoutRepeat + [id]).suffix(maximumUndoRecords))
    }

    /// The first unique candidate wins. Later duplicate rows remain reviewable but unselected.
    static func duplicateReasons(incoming: [RecipeMigrationIdentity], existing: [RecipeMigrationIdentity]) -> [UUID: String] {
        var known: [String: String] = [:]
        for item in existing { for key in item.keys { known[key] = "Already saved: \(item.title)" } }
        var result: [UUID: String] = [:]
        for item in incoming {
            if let reason = item.keys.sorted().compactMap({ known[$0] }).first { result[item.id] = reason }
            for key in item.keys where known[key] == nil { known[key] = "Repeated in these files: \(item.title)" }
        }
        return result
    }

    static func unchangedAdditionIDs(saved: [UUID: String], current: [UUID: String]) -> Set<UUID> {
        Set(saved.compactMap { id, fingerprint in current[id] == fingerprint ? id : nil })
    }
}
