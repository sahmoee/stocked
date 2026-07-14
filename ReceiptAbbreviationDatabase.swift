// ReceiptAbbreviationDatabase.swift
// Shim — all logic lives in StockedDatabase.swift.
// This file replaces the old standalone database. Keep it in your Xcode project.
// AbbreviationEntry.AbbrevSource replaces the old AbbreviationEntry.AbbreviationSource.
import Foundation

// Typealias so old call sites using .AbbreviationSource still compile
extension AbbreviationEntry {
    typealias AbbreviationSource = AbbrevSource
}

final class ReceiptAbbreviationDatabase {
    static let shared = ReceiptAbbreviationDatabase()
    private init() {}

    func resolve(_ raw: String) -> String {
        StockedDatabase.shared.resolveAbbreviation(raw)
    }
    func lookup(_ raw: String) -> String? {
        StockedDatabase.shared.lookupAbbreviation(raw)
    }
    func add(_ abbr: String, resolved: String,
             source: AbbreviationEntry.AbbrevSource = .userAdded) {
        StockedDatabase.shared.addAbbreviation(abbr, resolved: resolved, source: source)
    }
    func update(id: UUID, abbreviation: String, resolved: String) {
        StockedDatabase.shared.updateAbbreviation(id: id, abbreviation: abbreviation, resolved: resolved)
    }
    func delete(ids: Set<UUID>) {
        StockedDatabase.shared.deleteAbbreviations(ids: ids)
    }
    func delete(at offsets: IndexSet) {
        StockedDatabase.shared.deleteAbbreviations(at: offsets)
    }
    func recordCorrection(raw: String, corrected: String) {
        StockedDatabase.shared.recordAbbreviationCorrection(raw: raw, corrected: corrected)
    }
    var entries: [AbbreviationEntry]         { StockedDatabase.shared.abbreviationEntries }
    var sortedEntries: [AbbreviationEntry]   { StockedDatabase.shared.sortedAbbreviationEntries }
    var userEntries: [AbbreviationEntry]     { StockedDatabase.shared.userAbbreviationEntries }
    var builtInEntries: [AbbreviationEntry]  { StockedDatabase.shared.builtInAbbreviationEntries }
}
