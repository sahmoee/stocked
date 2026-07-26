// ToolboxUsage.swift — Improvement #4: 39 tools, ranked by what you actually use.
//
// The Toolbox grew from 20 tools to 39. A flat grid of five fixed categories means the 39th tile is
// functionally invisible: nobody scrolls a utility screen to the bottom. Capability stopped being
// the bottleneck and discovery started.
//
// Rather than guess a better fixed order, this learns one. Opens are counted, the last-used tools
// get a row at the top, and within each category the tools you reach for float up. Starring pins a
// tool regardless of frequency, because "I use this rarely but it's important" is a real case that
// frequency alone gets wrong.

import SwiftUI

// MARK: - Model

nonisolated struct ToolUsageRecord: Codable, Identifiable, Sendable {
    var id: String          // ToolboxTool.rawValue
    var opens: Int = 0
    var lastOpened: Date = Date()
    var isFavorite: Bool = false
}

// MARK: - Store

@MainActor
@Observable
final class ToolboxUsageStore {
    static let shared = ToolboxUsageStore()
    private let persistence = FeatureStore<ToolUsageRecord>(key: FeatureStoreKeys.toolboxUsage)

    private(set) var records: [ToolUsageRecord] = []

    private init() { records = persistence.load() }

    func flush() { persistence.flush() }

    // MARK: Recording

    func recordOpen(_ tool: ToolboxTool) {
        if let i = records.firstIndex(where: { $0.id == tool.rawValue }) {
            records[i].opens += 1
            records[i].lastOpened = Date()
        } else {
            records.append(ToolUsageRecord(id: tool.rawValue, opens: 1))
        }
        persistence.save(records)
    }

    func toggleFavorite(_ tool: ToolboxTool) {
        if let i = records.firstIndex(where: { $0.id == tool.rawValue }) {
            records[i].isFavorite.toggle()
        } else {
            records.append(ToolUsageRecord(id: tool.rawValue, opens: 0, isFavorite: true))
        }
        persistence.save(records)
        HapticManager.select()
    }

    // MARK: Reading

    func opens(_ tool: ToolboxTool) -> Int {
        records.first { $0.id == tool.rawValue }?.opens ?? 0
    }
    func isFavorite(_ tool: ToolboxTool) -> Bool {
        records.first { $0.id == tool.rawValue }?.isFavorite ?? false
    }

    var favorites: [ToolboxTool] {
        records.filter(\.isFavorite)
            .compactMap { ToolboxTool(rawValue: $0.id) }
    }

    /// Most recently opened, newest first. Deliberately excludes favourites — they already have
    /// their own row, and showing a tool twice above the fold wastes the scarcest space on screen.
    func recent(limit: Int = 4) -> [ToolboxTool] {
        records
            .filter { $0.opens > 0 && !$0.isFavorite }
            .sorted { $0.lastOpened > $1.lastOpened }
            .prefix(limit)
            .compactMap { ToolboxTool(rawValue: $0.id) }
    }

    /// Sort within a category: most-used first, untouched tools keep their declaration order so a
    /// brand-new tool doesn't get buried before it has had a chance to be discovered.
    func ranked(_ tools: [ToolboxTool]) -> [ToolboxTool] {
        tools.enumerated().sorted { a, b in
            let oa = opens(a.element), ob = opens(b.element)
            if oa != ob { return oa > ob }
            return a.offset < b.offset
        }.map(\.element)
    }

    var hasHistory: Bool { records.contains { $0.opens > 0 || $0.isFavorite } }
}
