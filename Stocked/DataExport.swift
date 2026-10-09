//
//  DataExport.swift
//  Stocked.
//
//  CHECKPOINT 1 — schema-versioned backup (DB #14).
//
//  Produces a single portable JSON document containing all of the user's data, and can
//  restore from one. This is the safety net for the data-layer migration: the user can
//  export a backup before any destructive cutover, and re-import if anything goes wrong.
//
//  The file carries `schemaVersion` so a future app can detect and upgrade an old backup
//  rather than failing or corrupting it.
//
//  This reads/writes AppSession's existing collections only — it does NOT depend on the
//  SwiftData store, so it works regardless of migration state.
//

import Foundation
import os.log

private let exportLog = Logger(subsystem: "com.sowens.Stocked", category: "DataExport")

/// The full backup document. Optionals so a partial/older backup still decodes.
struct StockedBackup: Codable {
    var schemaVersion: Int = StockedSchema.version
    var exportedAt: Date = .now
    var appBuild: String? = nil

    var inventory:  [LocalInventoryItem]?
    var grocery:    [LocalGroceryItem]?
    var userRecipes:[UserRecipe]?
    var generated:  [GeneratedRecipe]?
    var pastMeals:  [LocalPastMeal]?
    var planned:    [PlannedMeal]?
    var prices:     [PriceRecord]?
    var consumption:[ConsumptionRecord]?
    var subs:       [UserSubstitutionEntry]?
    var staples:    [String]?
}

@MainActor
enum DataExport {

    // MARK: - Export

    /// Build a backup document from the current session.
    static func makeBackup(from session: GuestDataStore) -> StockedBackup {
        StockedBackup(
            schemaVersion: StockedSchema.version,
            exportedAt: .now,
            appBuild: BuildConfig.displayLabel,
            inventory:   session.inventoryItems,
            grocery:     session.groceryItems,
            userRecipes: session.userRecipes,
            generated:   session.savedGeneratedRecipes,
            pastMeals:   session.pastMeals,
            planned:     session.plannedMeals,
            prices:      session.priceHistory,
            consumption: session.consumptionLog,
            subs:        session.userSubstitutions,
            staples:     session.stockStaples
        )
    }

    /// Encode a backup to pretty JSON Data, ready to write to a file / share sheet.
    static func exportData(from session: GuestDataStore) -> Data? {
        let backup = makeBackup(from: session)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            return try encoder.encode(backup)
        } catch {
            exportLog.error("Backup encode failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Write a backup to a temporary file and return its URL (for the share sheet).
    static func writeBackupFile(from session: GuestDataStore) -> URL? {
        guard let data = exportData(from: session) else { return nil }
        let stamp = StockedFormatters.iso8601.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Stocked-Backup-\(stamp).json")
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            exportLog.error("Backup file write failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Import / restore

    enum RestoreError: LocalizedError {
        case unreadable
        case newerSchema(Int)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This file isn't a valid Stocked backup."
            case .newerSchema(let v): return "This backup was made by a newer version of Stocked (format v\(v)). Update the app to restore it."
            }
        }
    }

    /// Decode a backup document. Throws if unreadable or from a newer schema than we know.
    static func decodeBackup(_ data: Data) throws -> StockedBackup {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let backup: StockedBackup
        if let strict = try? decoder.decode(StockedBackup.self, from: data) {
            backup = strict
        } else if let lenient = try? decoder.decode(LenientBackup.self, from: data) {
            // One malformed record (hand-edited file, a field from a future build with an
            // incompatible type) used to reject the WHOLE backup. Skip just that record.
            exportLog.notice("Backup decoded leniently; malformed records were skipped.")
            backup = lenient.backup
        } else {
            throw RestoreError.unreadable
        }
        if backup.schemaVersion > StockedSchema.version {
            throw RestoreError.newerSchema(backup.schemaVersion)
        }
        return backup
    }

    /// Restore strategy.
    enum RestoreMode {
        case merge    // keep existing, add/overwrite by id from the backup
        case replace  // replace each collection wholesale with the backup's
    }

    /// Apply a backup to the session. Defaults to MERGE (non-destructive-ish: existing
    /// items with ids not in the backup are kept). Only collections present in the backup
    /// are touched, so an older/partial backup won't wipe newer collections.
    static func restore(_ backup: StockedBackup, into session: GuestDataStore, mode: RestoreMode = .merge) {
        func apply<T: Identifiable>(_ incoming: [T]?, _ current: [T], assign: ([T]) -> Void) where T.ID: Hashable {
            guard let incoming else { return }   // collection absent in backup → leave as-is
            switch mode {
            case .replace:
                assign(incoming)
            case .merge:
                // Dictionary iteration order is random, so rebuilding from `byID.values`
                // shuffled every list (grocery order, meal history, plans) on each restore.
                assign(mergedPreservingOrder(current: current, incoming: incoming))
            }
        }

        apply(backup.inventory,   session.inventoryItems) { session.inventoryItems = $0 }
        apply(backup.grocery,     session.groceryItems) { session.groceryItems = $0 }
        apply(backup.userRecipes, session.userRecipes) { session.userRecipes = $0 }
        apply(backup.generated,   session.savedGeneratedRecipes) { session.savedGeneratedRecipes = $0 }
        apply(backup.pastMeals,   session.pastMeals) { session.pastMeals = $0 }
        apply(backup.planned,     session.plannedMeals) { session.plannedMeals = $0 }
        apply(backup.prices,      session.priceHistory) { session.priceHistory = $0 }
        apply(backup.consumption, session.consumptionLog) { session.consumptionLog = $0 }
        apply(backup.subs,        session.userSubstitutions) { session.userSubstitutions = $0 }
        if let staples = backup.staples {
            switch mode {
            case .replace: session.stockStaples = staples
            case .merge:
                // Merge means "keep existing": union instead of replacing the staples list.
                var seen = Set(session.stockStaples)
                session.stockStaples += staples.filter { seen.insert($0).inserted }
            }
        }
        // Commit now: a restore is a deliberate durability point, and the debounced writes
        // would otherwise be lost if the app is suspended/killed right after "Backup restored."
        session.flushPendingSaves()

        exportLog.info("Restore complete (mode: \(String(describing: mode))).")
    }

    /// Merge by id keeping the existing order: existing items stay where they are (replaced in
    /// place when the backup has a newer copy), new backup items are appended in backup order,
    /// and duplicate ids collapse to one entry (the backup's copy wins).
    static func mergedPreservingOrder<T: Identifiable>(current: [T], incoming: [T]) -> [T] where T.ID: Hashable {
        var incomingByID: [T.ID: T] = [:]
        for item in incoming { incomingByID[item.id] = item }   // last duplicate in backup wins
        var result: [T] = []
        result.reserveCapacity(current.count + incoming.count)
        var emitted = Set<T.ID>()
        for item in current where emitted.insert(item.id).inserted {
            result.append(incomingByID[item.id] ?? item)
        }
        for item in incoming where emitted.insert(item.id).inserted {
            result.append(incomingByID[item.id] ?? item)
        }
        return result
    }

    /// Convenience: decode + restore from raw file Data.
    static func restore(from data: Data, into session: GuestDataStore, mode: RestoreMode = .merge) throws {
        let backup = try decodeBackup(data)
        restore(backup, into: session, mode: mode)
    }
}

/// Per-record tolerant twin of `StockedBackup`, used only when the strict decode fails.
private struct LenientBackup: Decodable {
    var schemaVersion: Int?
    var exportedAt: Date?
    var appBuild: String?
    var inventory:  [FailableDecodable<LocalInventoryItem>]?
    var grocery:    [FailableDecodable<LocalGroceryItem>]?
    var userRecipes:[FailableDecodable<UserRecipe>]?
    var generated:  [FailableDecodable<GeneratedRecipe>]?
    var pastMeals:  [FailableDecodable<LocalPastMeal>]?
    var planned:    [FailableDecodable<PlannedMeal>]?
    var prices:     [FailableDecodable<PriceRecord>]?
    var consumption:[FailableDecodable<ConsumptionRecord>]?
    var subs:       [FailableDecodable<UserSubstitutionEntry>]?
    var staples:    [FailableDecodable<String>]?

    var backup: StockedBackup {
        StockedBackup(
            schemaVersion: schemaVersion ?? StockedSchema.version,
            exportedAt: exportedAt ?? .now,
            appBuild: appBuild,
            inventory:   inventory?.compactMap(\.value),
            grocery:     grocery?.compactMap(\.value),
            userRecipes: userRecipes?.compactMap(\.value),
            generated:   generated?.compactMap(\.value),
            pastMeals:   pastMeals?.compactMap(\.value),
            planned:     planned?.compactMap(\.value),
            prices:      prices?.compactMap(\.value),
            consumption: consumption?.compactMap(\.value),
            subs:        subs?.compactMap(\.value),
            staples:     staples?.compactMap(\.value)
        )
    }
}
