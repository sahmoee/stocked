// QAInvariants.swift
// ─────────────────────────────────────────────────────────────────────────────
// In-process invariant probes. This is the part of QA mode that replaces manual
// work rather than merely recording it.
//
// Every probe here corresponds to a checkbook item of the form "surface A and
// surface B must agree". A human doing that item opens two screens and compares
// two numbers. A probe reads both computations directly, against the live store,
// and reports the disagreement with both values in the message.
//
// These are precisely the divergences that shipped in build 69's unification —
// ten name matchers, four allergen rules, five threshold constants, a frozen
// generated-recipe list, and a coverage struct whose count and list were built
// by different rules. Each of those bugs would have been caught on the first run
// of this suite. The probes exist so they cannot come back quietly.
//
// EXECUTION RULES
// Probes are read-only. They never mutate the store, never write to disk, and
// never call the network. They must be cheap enough to run on a timer, so
// anything expensive is capped and says so.
//
// A probe reports:
//   ok        — the surfaces agree
//   violation — they disagree; this is a bug in the app
//   blocked   — could not evaluate (no data yet); not a pass and not a failure
// ─────────────────────────────────────────────────────────────────────────────

import Foundation

nonisolated enum QAInvariantStatus: String, Codable, Sendable {
    case ok, violation, blocked
}

nonisolated struct QAInvariantResult: Identifiable, Codable, Sendable {
    var id = UUID()
    let name: String
    let status: QAInvariantStatus
    let detail: String
    /// True when a violation here should block a release. Dietary and data
    /// integrity probes are critical; cosmetic disagreements are not.
    let critical: Bool
}

@MainActor
enum QAInvariants {

    /// Async variant that yields the main actor between probes. The background
    /// runner uses THIS — running the whole suite synchronously stalled the main
    /// thread for long enough during cooking that the iOS watchdog killed the app
    /// (the "CRASH type=10 signal=9" entries in the diagnostics log).
    static func runAllYielding(store: GuestDataStore, session: CookNowSession?) async -> [QAInvariantResult] {
        var out: [QAInvariantResult] = []
        let probes: [() -> QAInvariantResult] = [
            { allergenExclusion(store: store, session: session) },
            { readyRecipesTrulyStocked(store: store, session: session) },
            { coverageInternalConsistency(store: store) },
            { homeMatchesCookExact(store: store, session: session) },
            { reservationMath(store: store) },
            { lowStockAgreement(store: store) },
            { expiringAgreement(store: store) },
            { availabilityFloorRespected(store: store) },
            { noDuplicateIdentities(store: store) },
            { discoverPoolReachingClassifier(store: store) },
            { optionalIngredientsExcluded(store: store) },
        ]
        for probe in probes {
            out.append(probe())
            await Task.yield()   // let UI/timer work interleave between probes
        }
        return out
    }

    /// Run every probe. Ordered so the critical ones surface first in the UI.
    static func runAll(store: GuestDataStore, session: CookNowSession?) -> [QAInvariantResult] {
        var out: [QAInvariantResult] = []
        out.append(allergenExclusion(store: store, session: session))
        out.append(readyRecipesTrulyStocked(store: store, session: session))
        out.append(coverageInternalConsistency(store: store))
        out.append(homeMatchesCookExact(store: store, session: session))
        out.append(reservationMath(store: store))
        out.append(lowStockAgreement(store: store))
        out.append(expiringAgreement(store: store))
        out.append(availabilityFloorRespected(store: store))
        out.append(noDuplicateIdentities(store: store))
        out.append(discoverPoolReachingClassifier(store: store))
        out.append(optionalIngredientsExcluded(store: store))
        return out
    }

    // MARK: - Critical: dietary safety

    /// No recipe presented as cookable may contain an active allergen, from the
    /// cooking profile OR from any family member marked present.
    static func allergenExclusion(store: GuestDataStore, session: CookNowSession?) -> QAInvariantResult {
        let family = FamilyProfileStore.shared
        let allergens = (store.cookingProfile.allergens + family.activeAllergens).filter { !$0.isEmpty }
        guard !allergens.isEmpty else {
            return QAInvariantResult(name: "Allergen exclusion",
                                     status: .blocked,
                                     detail: "no allergens saved — add one to a profile to exercise this probe",
                                     critical: true)
        }
        let rules = DietaryGuard.Rules(allergens: allergens)
        let snapshot = CookNowCompute.run(store: store, session: session)
        let surfaced = snapshot.readyNow + snapshot.needsReview + snapshot.almostReady

        var offenders: [String] = []
        for c in surfaced {
            let hits = DietaryGuard.allergenHits(ingredientLines: c.recipe.ingredients.map(\.name),
                                                 title: c.recipe.title,
                                                 rules: rules)
            if !hits.isEmpty {
                offenders.append("\(c.recipe.title) [\(hits.joined(separator: ", "))]")
            }
        }
        if offenders.isEmpty {
            return QAInvariantResult(name: "Allergen exclusion",
                                     status: .ok,
                                     detail: "\(surfaced.count) surfaced recipes, none hit \(allergens.count) active allergen(s)",
                                     critical: true)
        }
        return QAInvariantResult(name: "Allergen exclusion",
                                 status: .violation,
                                 detail: "RELEASE BLOCKER — surfaced recipes contain active allergens: " + offenders.prefix(3).joined(separator: "; "),
                                 critical: true)
    }

    // MARK: - Critical: a 100% recipe is truly cookable

    /// Every recipe in the exact tier must have all required ingredients in
    /// stock. This is the probe that would have caught the loose substring
    /// matcher reporting "Everything in stock" for a kitchen missing corn.
    static func readyRecipesTrulyStocked(store: GuestDataStore, session: CookNowSession?) -> QAInvariantResult {
        let snapshot = CookNowCompute.run(store: store, session: session)
        let exact = snapshot.readyNow.filter { $0.readiness == .exact }
        guard !exact.isEmpty else {
            return QAInvariantResult(name: "Ready recipes truly stocked",
                                     status: .blocked,
                                     detail: "nothing in the exact tier to verify",
                                     critical: true)
        }
        let names = store.inStockNameSet
        var offenders: [String] = []
        for c in exact {
            let cov = KitchenAvailability.coverage(
                lines: c.recipe.ingredients.map(\.name),
                optionalFlags: c.recipe.ingredients.map(\.isOptional),
                availableNames: names
            )
            if !cov.isComplete {
                offenders.append("\(c.recipe.title) missing \(cov.missingNames.joined(separator: ", "))")
            }
        }
        return offenders.isEmpty
            ? QAInvariantResult(name: "Ready recipes truly stocked", status: .ok,
                                detail: "\(exact.count) exact-tier recipes verified against inventory",
                                critical: true)
            : QAInvariantResult(name: "Ready recipes truly stocked", status: .violation,
                                detail: "claimed ready but not stocked: " + offenders.prefix(3).joined(separator: "; "),
                                critical: true)
    }

    // MARK: - Coverage is self-consistent

    /// `missingNames.count` must equal `total - have` for every recipe. These
    /// were computed by different rules before build 69, so a badge could name
    /// an ingredient it did not count.
    static func coverageInternalConsistency(store: GuestDataStore) -> QAInvariantResult {
        let names = store.inStockNameSet
        let sample = Array(store.cookCatalog.prefix(120))
        guard !sample.isEmpty else {
            return QAInvariantResult(name: "Coverage self-consistency", status: .blocked,
                                     detail: "no recipes in catalog", critical: false)
        }
        var bad: [String] = []
        for r in sample {
            let cov = KitchenAvailability.coverage(lines: r.ingredients.map(\.name),
                                                  optionalFlags: r.ingredients.map(\.isOptional),
                                                  availableNames: names)
            if cov.missingNames.count != cov.missingCount {
                bad.append("\(r.title): names \(cov.missingNames.count) vs count \(cov.missingCount)")
            }
        }
        return bad.isEmpty
            ? QAInvariantResult(name: "Coverage self-consistency", status: .ok,
                                detail: "\(sample.count) recipes: named-missing always equals counted-missing",
                                critical: false)
            : QAInvariantResult(name: "Coverage self-consistency", status: .violation,
                                detail: bad.prefix(3).joined(separator: "; "), critical: true)
    }

    // MARK: - Home agrees with Cook

    static func homeMatchesCookExact(store: GuestDataStore, session: CookNowSession?) -> QAInvariantResult {
        let home = store.availableMeals
        let snapshot = CookNowCompute.run(store: store, session: session)
        let cook = snapshot.readyNow.filter { $0.readiness == .exact }.count
        // availableMeals also counts fully-stocked saved generated recipes, which
        // the exact tier includes too, so these are defined to be equal.
        return home == cook
            ? QAInvariantResult(name: "Home meals equals Cook exact", status: .ok,
                                detail: "both report \(home)", critical: false)
            : QAInvariantResult(name: "Home meals equals Cook exact", status: .violation,
                                detail: "Home says \(home), Cook exact tier says \(cook) — the two surfaces have diverged again",
                                critical: true)
    }

    // MARK: - Reservation arithmetic

    static func reservationMath(store: GuestDataStore) -> QAInvariantResult {
        let ledger = ReservationLedger.shared
        ledger.refreshIfNeeded(store: store)
        var bad: [String] = []
        var checked = 0
        for item in store.inventoryItems {
            guard let reserved = ledger.reserved(for: item), reserved > 0,
                  let available = ledger.available(for: item) else { continue }
            checked += 1
            // item.quantity is Int (container count); the ledger deals in Double amounts.
            let expected = max(0, Double(item.quantity) - reserved)
            if abs(available - expected) > 0.001 {
                bad.append("\(item.name): available \(available), expected \(expected)")
            }
        }
        if checked == 0 {
            return QAInvariantResult(name: "Reservation arithmetic", status: .blocked,
                                     detail: "nothing reserved — plan a meal to exercise this probe",
                                     critical: false)
        }
        return bad.isEmpty
            ? QAInvariantResult(name: "Reservation arithmetic", status: .ok,
                                detail: "\(checked) reserved items: available equals total minus reserved",
                                critical: false)
            : QAInvariantResult(name: "Reservation arithmetic", status: .violation,
                                detail: bad.prefix(3).joined(separator: "; "), critical: true)
    }

    // MARK: - Threshold agreement

    /// Every surface that lists low stock must select the same items. Before
    /// build 69 these used 0.2, 0.25 and 0.33, and one read the raw level.
    static func lowStockAgreement(store: GuestDataStore) -> QAInvariantResult {
        let canonical = Set(store.inventoryItems.filter { KitchenAvailability.isRunningLow($0) }.map(\.id))
        let storeSide = Set(store.lowStockItems.map(\.id))
        if canonical == storeSide {
            return QAInvariantResult(name: "Low-stock threshold agreement", status: .ok,
                                     detail: "\(canonical.count) items, all surfaces agree", critical: false)
        }
        let extra = storeSide.subtracting(canonical).count
        let missing = canonical.subtracting(storeSide).count
        return QAInvariantResult(name: "Low-stock threshold agreement", status: .violation,
                                 detail: "store list differs from the shared rule by \(extra) extra and \(missing) missing — a hardcoded threshold has crept back in",
                                 critical: true)
    }

    static func expiringAgreement(store: GuestDataStore) -> QAInvariantResult {
        let canonical = Set(store.inventoryItems.filter {
            guard let d = $0.daysUntilExpiry else { return false }
            return d >= 0 && d <= KitchenThresholds.expiringSoonDays
        }.map(\.id))
        let storeSide = Set(store.expiringSoonItems.filter { ($0.daysUntilExpiry ?? -1) >= 0 }.map(\.id))
        return canonical == storeSide
            ? QAInvariantResult(name: "Expiring-soon window agreement", status: .ok,
                                detail: "\(canonical.count) items within \(KitchenThresholds.expiringSoonDays) days",
                                critical: false)
            : QAInvariantResult(name: "Expiring-soon window agreement", status: .violation,
                                detail: "two different day windows are in use (\(canonical.count) vs \(storeSide.count) items)",
                                critical: true)
    }

    /// An item scraped to a smear must not count as available.
    static func availabilityFloorRespected(store: GuestDataStore) -> QAInvariantResult {
        let smears = store.inventoryItems.filter {
            $0.effectiveLevel > 0 && $0.effectiveLevel <= KitchenAvailability.availableFillFloor
        }
        guard !smears.isEmpty else {
            return QAInvariantResult(name: "Availability floor respected", status: .blocked,
                                     detail: "no near-empty items to test — set one below 5 percent",
                                     critical: false)
        }
        let names = store.inStockNameSet
        let leaked = smears.filter { names.contains($0.name.lowercased()) }
        return leaked.isEmpty
            ? QAInvariantResult(name: "Availability floor respected", status: .ok,
                                detail: "\(smears.count) near-empty items correctly excluded", critical: false)
            : QAInvariantResult(name: "Availability floor respected", status: .violation,
                                detail: "near-empty items counted as in stock: " + leaked.prefix(3).map(\.name).joined(separator: ", "),
                                critical: false)
    }

    // MARK: - Data integrity

    static func noDuplicateIdentities(store: GuestDataStore) -> QAInvariantResult {
        var problems: [String] = []
        let invIDs = store.inventoryItems.map(\.id)
        if Set(invIDs).count != invIDs.count {
            problems.append("inventory has \(invIDs.count - Set(invIDs).count) duplicate id(s)")
        }
        let recipeIDs = store.userRecipes.map(\.id)
        if Set(recipeIDs).count != recipeIDs.count {
            problems.append("recipes have \(recipeIDs.count - Set(recipeIDs).count) duplicate id(s)")
        }
        let titles = store.userRecipes.map { OnlineRecipeFacts.normalizedTitle($0.title) }
        let dupTitles = titles.count - Set(titles).count
        if dupTitles > 0 { problems.append("\(dupTitles) duplicate recipe title(s)") }

        return problems.isEmpty
            ? QAInvariantResult(name: "No duplicate identities", status: .ok,
                                detail: "\(invIDs.count) items and \(recipeIDs.count) recipes, all unique",
                                critical: false)
            : QAInvariantResult(name: "No duplicate identities", status: .violation,
                                detail: problems.joined(separator: "; "), critical: true)
    }

    // MARK: - The build 69 corpus fix stays fixed

    static func discoverPoolReachingClassifier(store: GuestDataStore) -> QAInvariantResult {
        let pool = OnlineRecipesLoader.shared.recipes
        guard !pool.isEmpty else {
            return QAInvariantResult(name: "Discover pool reaches classifier", status: .blocked,
                                     detail: "Discover cache empty — open Recipes once, or this is the cold-launch hydration bug",
                                     critical: false)
        }
        let catalog = store.classifiableCatalog(discover: pool)
        let own = store.cookCatalog.count
        let added = catalog.count - own - store.savedGeneratedRecipes.filter { !$0.isHidden }.count
        return added > 0
            ? QAInvariantResult(name: "Discover pool reaches classifier", status: .ok,
                                detail: "\(pool.count) cached, \(max(0, added)) entered the classifiable catalog",
                                critical: false)
            : QAInvariantResult(name: "Discover pool reaches classifier", status: .violation,
                                detail: "\(pool.count) Discover recipes cached but none reached the classifier — Cook is back to starter meals only",
                                critical: true)
    }

    static func optionalIngredientsExcluded(store: GuestDataStore) -> QAInvariantResult {
        let withOptional = store.cookCatalog.first { r in
            r.ingredients.contains(where: \.isOptional)
                || r.ingredients.contains { KitchenAvailability.isOptionalLine($0.name) }
        }
        guard let recipe = withOptional else {
            return QAInvariantResult(name: "Optional ingredients excluded", status: .blocked,
                                     detail: "no recipe with an optional ingredient to test",
                                     critical: false)
        }
        let cov = KitchenAvailability.coverage(lines: recipe.ingredients.map(\.name),
                                               optionalFlags: recipe.ingredients.map(\.isOptional),
                                               availableNames: store.inStockNameSet)
        let required = recipe.ingredients.filter {
            !$0.isOptional && !KitchenAvailability.isOptionalLine($0.name)
        }.count
        return cov.total == required
            ? QAInvariantResult(name: "Optional ingredients excluded", status: .ok,
                                detail: "\(recipe.title): denominator \(cov.total) equals required count",
                                critical: false)
            : QAInvariantResult(name: "Optional ingredients excluded", status: .violation,
                                detail: "\(recipe.title): denominator \(cov.total) but \(required) required — garnishes are being counted",
                                critical: true)
    }
}
