// HealthKitManager.swift — opt-in Apple Health sync for cooked meals.
//
// When the user enables Apple Health in Preferences and grants write access, every meal
// finished through the cooking flow logs its estimated per-serving nutrition (energy,
// protein, carbohydrates, fat) to Health as consumed dietary samples, stamped with the
// recipe title. Everything is guarded: HealthKit unavailable (iPad without Health, or the
// capability missing) → the toggle hides; not authorized → writes are skipped silently.
//
// Requires the HealthKit entitlement plus NSHealthShareUsageDescription and
// NSHealthUpdateUsageDescription in Info.plist (shipped alongside this file). The HealthKit
// capability must also be enabled for the App ID in the Apple Developer portal.
import Foundation
import HealthKit
import os

@Observable
@MainActor
final class HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    private static let enabledKey = DefaultsKey.healthSyncEnabled

    /// Whether Health data exists on this device at all.
    var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// User's opt-in switch (separate from system authorization).
    var isEnabled: Bool = UserDefaults.standard.bool(forKey: DefaultsKey.healthSyncEnabled) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { requestAuthorization() }
        }
    }

    private(set) var statusMessage = ""

    private var writeTypes: Set<HKSampleType> {
        var set = Set<HKSampleType>()
        for id: HKQuantityTypeIdentifier in [.dietaryEnergyConsumed, .dietaryProtein,
                                             .dietaryCarbohydrates, .dietaryFatTotal] {
            if let t = HKQuantityType.quantityType(forIdentifier: id) { set.insert(t) }
        }
        return set
    }

    private init() {}

    /// Ask Health for write access to the nutrition types. Safe to call repeatedly.
    func requestAuthorization() {
        guard isAvailable else { return }
        store.requestAuthorization(toShare: writeTypes, read: []) { [weak self] ok, error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.statusMessage = "Health access failed: \(error.localizedDescription)"
                    Log.app.error("HealthKit auth error: \(error.localizedDescription, privacy: .public)")
                } else {
                    self.statusMessage = ok ? "Connected to Apple Health" : ""
                }
            }
        }
    }

    /// Log a cooked meal's estimated per-serving nutrition to Health. No-ops unless the user
    /// opted in, Health is available, and there is at least one non-zero value to write.
    func logCookedMeal(title: String, nutrition totals: NutritionFacts?, servings: Int) {
        guard isEnabled, isAvailable, let totals else { return }
        let s = Double(max(1, servings))

        // Per-serving values — the cook eats one serving; whole-recipe totals would wildly
        // overstate intake.
        let energy  = Double(totals.calories) / s
        let protein = totals.protein / s
        let carbs   = totals.totalCarbs / s
        let fat     = totals.totalFat / s
        guard energy > 0 || protein > 0 || carbs > 0 || fat > 0 else { return }

        let now = Date()
        let meta: [String: Any] = [HKMetadataKeyFoodType: title]
        var samples: [HKQuantitySample] = []

        func add(_ id: HKQuantityTypeIdentifier, _ value: Double, _ unit: HKUnit) {
            guard value > 0, let type = HKQuantityType.quantityType(forIdentifier: id) else { return }
            samples.append(HKQuantitySample(type: type,
                                            quantity: HKQuantity(unit: unit, doubleValue: value),
                                            start: now, end: now, metadata: meta))
        }

        add(.dietaryEnergyConsumed, energy,  .kilocalorie())
        add(.dietaryProtein,        protein, .gram())
        add(.dietaryCarbohydrates,  carbs,   .gram())
        add(.dietaryFatTotal,       fat,     .gram())
        guard !samples.isEmpty else { return }

        store.save(samples) { ok, error in
            if let error {
                Log.app.error("HealthKit meal save failed: \(error.localizedDescription, privacy: .public)")
            } else if ok {
                Log.app.notice("HealthKit: logged meal to Health")
            }
        }
    }

    /// Sum the nutrition of a recipe's ingredients into recipe-wide totals. Returns nil when
    /// no ingredient carries nutrition facts, so callers can skip the write entirely.
    nonisolated static func totals(for recipe: UserRecipe) -> NutritionFacts? {
        let facts = recipe.ingredients.compactMap { $0.nutrition }
        guard !facts.isEmpty else { return nil }
        var t = NutritionFacts()
        for f in facts {
            t.calories   += f.calories
            t.protein    += f.protein
            t.totalCarbs += f.totalCarbs
            t.totalFat   += f.totalFat
        }
        return t
    }
}
