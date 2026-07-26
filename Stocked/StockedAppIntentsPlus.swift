// StockedAppIntentsPlus.swift — Improvement #17: hands-free answers for the new features.
//
// The hard part of a voice answer is having a deterministic, offline, one-sentence response ready.
// Features 1–15 already built exactly that — `ReadinessCalculator`, `ThawCalculator`,
// `LeftoversStore`, `KitchenAssistantEngine` all return plain values with no network and no AI.
// These intents are thin wrappers over them.
//
// Hands-free matters specifically in a kitchen: the user's hands are wet, floury or holding a pan.
//
// Follows the existing file's conventions exactly:
//   • `nonisolated static var` computed metadata (NOT `static let`) — required under
//     SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor, and the exact thing that broke the build when
//     these were declared as stored properties.
//   • No `@Parameter` on `nonisolated struct` intents — that combination fails on this toolchain.
//   • Reads go through nonisolated readers over raw storage keys, never the live @MainActor store,
//     because an intent can run while the app isn't in the foreground.

import AppIntents
import Foundation

// MARK: - Readers (nonisolated, storage-level)

/// Feature data read straight from the FeatureStore files, so intents work with the app closed.
@available(iOS 16.0, *)
nonisolated enum StockedFeatureReader {

    private static func decode<T: Decodable>(_ type: T.Type, key: String) -> [T] {
        // FeatureStore writes through LocalDatabase; fall back to the legacy UserDefaults blob
        // for anyone who hasn't launched since the migration.
        if let rows = LocalDatabase.shared.loadArray(type, key: key) { return rows }
        guard let data = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([T].self, from: data)) ?? []
    }

    static func leftovers() -> [LeftoverEntry] {
        decode(LeftoverEntry.self, key: FeatureStoreKeys.leftovers)
            .sorted { $0.expiresAt < $1.expiresAt }
    }

    static func householdSize() -> Int {
        max(1, decode(EaterProfile.self, key: FeatureStoreKeys.familyProfiles)
            .filter(\.isPresent).count)
    }

    /// Full inventory, for the readiness calculation. Uses the same raw key the existing
    /// `StockedInventoryReader` uses.
    static func inventory() -> [LocalInventoryItem] {
        if let rows = LocalDatabase.shared.loadArray(LocalInventoryItem.self, key: "inventory_items") {
            return rows
        }
        guard let data = UserDefaults.standard.data(forKey: "inventory_items") else { return [] }
        return (try? JSONDecoder().decode([LocalInventoryItem].self, from: data)) ?? []
    }
}

// MARK: - Leftovers

@available(iOS 16.0, *)
nonisolated struct WhatLeftoversIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "What leftovers do I have" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Ask Stocked what's in the fridge from previous meals, and what needs eating first.")
    }
    nonisolated static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let queue = StockedFeatureReader.leftovers()
        guard !queue.isEmpty else {
            return .result(dialog: "You don't have any leftovers tracked right now.")
        }
        let urgent = queue.filter { !$0.isFrozen && $0.daysLeft <= 1 }
        if let first = urgent.first {
            let others = urgent.count > 1 ? " There are \(urgent.count - 1) more that need eating too." : ""
            return .result(dialog: IntentDialog("Eat the \(first.title) first — it's got about a day left.\(others)"))
        }
        let names = queue.prefix(3).map(\.title).joined(separator: ", ")
        let extra = queue.count > 3 ? ", and \(queue.count - 3) more" : ""
        return .result(dialog: IntentDialog("You have \(names)\(extra)."))
    }
}

// MARK: - Thawing

@available(iOS 16.0, *)
nonisolated struct WhatToThawIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "What should I thaw" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Ask Stocked what to take out of the freezer for tomorrow, and how long it needs.")
    }
    nonisolated static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let frozen = StockedFeatureReader.inventory().filter { $0.storageCategory == .freezer }
        guard let item = frozen.first else {
            return .result(dialog: "There's nothing in your freezer right now.")
        }
        let pounds = ThawCalculator.pounds(for: item)
        let hours = ThawCalculator.hours(pounds: pounds, method: .fridge)
        let readable = hours >= 24
            ? "about \(String(format: "%.1f", hours / 24)) days"
            : "about \(Int(hours)) hours"
        let more = frozen.count > 1 ? " You've got \(frozen.count - 1) other things frozen." : ""
        return .result(dialog: IntentDialog(
            "Take out the \(item.name) — it needs \(readable) to thaw in the fridge.\(more)"))
    }
}

// MARK: - Readiness

@available(iOS 16.0, *)
nonisolated struct HowManyDaysOfFoodIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "How many days of food do I have" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Ask Stocked how long your household could eat without shopping.")
    }
    nonisolated static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let result = ReadinessCalculator.assess(items: StockedFeatureReader.inventory(),
                                                people: StockedFeatureReader.householdSize())
        let people = result.people == 1 ? "you" : "your household of \(result.people)"
        guard result.days > 0 else {
            return .result(dialog: IntentDialog("There isn't enough shelf-stable food logged to estimate that yet."))
        }
        let days = String(format: result.days < 10 ? "%.1f" : "%.0f", result.days)
        var dialog = "About \(days) days of food and water for \(people)."
        if result.daysOfWater < result.daysOfFood {
            dialog += " Water is the limit — that's what to stock up on."
        }
        return .result(dialog: IntentDialog(stringLiteral: dialog))
    }
}

// MARK: - Pantry question

@available(iOS 16.0, *)
nonisolated struct WhatCanIUseUpIntent: AppIntent {
    nonisolated static var title: LocalizedStringResource { "What should I use up" }
    nonisolated static var description: IntentDescription {
        IntentDescription("Ask Stocked which food to cook with next, based on what's closest to turning.")
    }
    nonisolated static var openAppWhenRun: Bool { false }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let items = StockedFeatureReader.inventory()
        let soon = KitchenAssistantEngine.expiringSoon(items, within: 5)
        guard !soon.isEmpty else {
            return .result(dialog: "Nothing's close to turning — your kitchen is in good shape.")
        }
        let names = soon.prefix(3).map(\.name).joined(separator: ", ")
        let extra = soon.count > 3 ? ", and \(soon.count - 3) more" : ""
        return .result(dialog: IntentDialog("Use up \(names)\(extra) — they're closest to their date."))
    }
}

// MARK: - Shortcut registration
//
// There is deliberately NO `AppShortcutsProvider` in this file.
//
// AppIntents permits exactly one conformance per app, and it's enforced at build time
// ("Only 1 'AppIntents.AppShortcutsProvider' conformance is allowed per app"). The four
// intents above are registered in `StockedShortcuts` in StockedAppIntents.swift, alongside
// the original five.
//
// Apple also caps a provider at 10 shortcuts. Stocked now declares 9, so there is room for
// one more before something has to be dropped.
