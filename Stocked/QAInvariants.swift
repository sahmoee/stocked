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
        // BUILD 75 — ONE snapshot for the whole suite.
        //
        // Three probes each called `CookNowCompute.run` independently, and this
        // loop yields the main actor between every probe so UI work can
        // interleave. That combination is how the Build 69 field export ended up
        // with three full classification passes inside four hundred milliseconds
        // against unchanged data: a mounted Cook Now surface recomputed in the
        // yield window and evicted the one-entry memo the next probe was about
        // to hit.
        //
        // It was also a correctness problem, and the more serious of the two.
        // `homeMatchesCookExact` compares Home's count against Cook's count; if
        // those two numbers come from snapshots taken a hundred milliseconds
        // apart with an inventory edit in between, a real divergence and a
        // perfectly ordinary edit look exactly the same. Every probe now judges
        // the same snapshot, taken once, before the first yield.
        let snapshot = CookNowCompute.run(store: store, session: session)
        await Task.yield()

        var out: [QAInvariantResult] = []
        let probes: [() -> QAInvariantResult] = [
            { allergenExclusion(store: store, session: session, snapshot: snapshot) },
            { readyRecipesTrulyStocked(store: store, session: session, snapshot: snapshot) },
            { surfacedRecipesAreShowable(store: store, session: session, snapshot: snapshot) },
            { coverageInternalConsistency(store: store) },
            { homeMatchesCookExact(store: store, session: session, snapshot: snapshot) },
            { reservationMath(store: store) },
            { lowStockAgreement(store: store) },
            { expiringAgreement(store: store) },
            { availabilityFloorRespected(store: store) },
            { noDuplicateIdentities(store: store) },
            { discoverPoolReachingClassifier(store: store) },
            { optionalIngredientsExcluded(store: store) },
            { classificationNotRepeating() },
            { workerConfigured() },
        ]
        for probe in probes {
            out.append(probe())
            await Task.yield()   // let UI/timer work interleave between probes
        }
        return out
    }

    /// Run every probe. Ordered so the critical ones surface first in the UI.
    static func runAll(store: GuestDataStore, session: CookNowSession?) -> [QAInvariantResult] {
        let snapshot = CookNowCompute.run(store: store, session: session)
        var out: [QAInvariantResult] = []
        out.append(allergenExclusion(store: store, session: session, snapshot: snapshot))
        out.append(readyRecipesTrulyStocked(store: store, session: session, snapshot: snapshot))
        out.append(surfacedRecipesAreShowable(store: store, session: session, snapshot: snapshot))
        out.append(coverageInternalConsistency(store: store))
        out.append(homeMatchesCookExact(store: store, session: session, snapshot: snapshot))
        out.append(reservationMath(store: store))
        out.append(lowStockAgreement(store: store))
        out.append(expiringAgreement(store: store))
        out.append(availabilityFloorRespected(store: store))
        out.append(noDuplicateIdentities(store: store))
        out.append(discoverPoolReachingClassifier(store: store))
        out.append(optionalIngredientsExcluded(store: store))
        out.append(classificationNotRepeating())
        out.append(workerConfigured())
        return out
    }

    // MARK: - Critical: dietary safety

    /// No recipe presented as cookable may contain an active allergen, from the
    /// cooking profile OR from any family member marked present.
    static func allergenExclusion(store: GuestDataStore,
                                  session: CookNowSession?,
                                  snapshot: CookNowCompute.Output? = nil) -> QAInvariantResult {
        let family = FamilyProfileStore.shared
        let allergens = (store.cookingProfile.allergens + family.activeAllergens).filter { !$0.isEmpty }
        guard !allergens.isEmpty else {
            return QAInvariantResult(name: "Allergen exclusion",
                                     status: .blocked,
                                     detail: "no allergens saved — add one to a profile to exercise this probe",
                                     critical: true)
        }
        let rules = DietaryGuard.Rules(allergens: allergens)
        let snap = snapshot ?? CookNowCompute.run(store: store, session: session)
        let surfaced = snap.readyNow + snap.needsReview + snap.almostReady

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
    static func readyRecipesTrulyStocked(store: GuestDataStore,
                                         session: CookNowSession?,
                                         snapshot: CookNowCompute.Output? = nil) -> QAInvariantResult {
        let snap = snapshot ?? CookNowCompute.run(store: store, session: session)
        let exact = snap.readyNow.filter { $0.readiness == .exact }
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

    static func homeMatchesCookExact(store: GuestDataStore,
                                     session: CookNowSession?,
                                     snapshot: CookNowCompute.Output? = nil) -> QAInvariantResult {
        let home = store.availableMeals
        let snap = snapshot ?? CookNowCompute.run(store: store, session: session)
        let cook = snap.readyNow.filter { $0.readiness == .exact }.count
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
    // MARK: - Critical: a recipe Cook Now offers must be one you can cook from
    //
    // STK-69-0001, filed from the field against Build 69: "No recipe showing —
    // needs a full recipe as they appear anywhere else in the app", on the Cook
    // Now results screen.
    //
    // The cause was a Discover recipe with no method reaching the classifier.
    // `OnlineRecipesLoader.warmFromCacheIfNeeded()` — the function the Cook tab
    // calls on a cold launch — published the raw persisted cache, while every
    // other Discover path runs it through `filterByProfile`, which drops recipes
    // whose "instructions" are empty or are really just a link to the source.
    // So Cook Now could rank and offer a recipe the Recipes tab would never show,
    // and tapping it wrote that hollow copy permanently into My Collection.
    //
    // Both leaks are closed in this build. This probe is the guard that stops
    // the next one: it asks the question at the surface, where the tester asked
    // it, and does not care which upstream path let the recipe through.

    /// Every recipe Cook Now presents as cookable must have real instructions.
    static func surfacedRecipesAreShowable(store: GuestDataStore,
                                           session: CookNowSession?,
                                           snapshot: CookNowCompute.Output? = nil) -> QAInvariantResult {
        let snap = snapshot ?? CookNowCompute.run(store: store, session: session)
        let surfaced = snap.readyNow + snap.needsReview + snap.almostReady
        guard !surfaced.isEmpty else {
            return QAInvariantResult(name: "Surfaced recipes are showable",
                                     status: .blocked,
                                     detail: "nothing surfaced in Cook Now to verify — add inventory or open Recipes once",
                                     critical: true)
        }
        let hollow = surfaced.filter {
            !OnlineRecipeFacts.hasRealInstructions($0.recipe.instructions.joined(separator: "\n"))
        }
        if hollow.isEmpty {
            return QAInvariantResult(name: "Surfaced recipes are showable",
                                     status: .ok,
                                     detail: "\(surfaced.count) surfaced recipes, every one has a method",
                                     critical: true)
        }
        return QAInvariantResult(name: "Surfaced recipes are showable",
                                 status: .violation,
                                 detail: "STK-69-0001 again — Cook Now is offering \(hollow.count) recipe(s) with no instructions: "
                                     + hollow.prefix(3).map(\.recipe.title).joined(separator: "; "),
                                 critical: true)
    }

    // MARK: - The classifier must not repeat itself
    //
    // Build 69's export: "Cook Now classify — 15x · total 2.21s · avg 147ms ·
    // worst 211ms", with three passes inside four hundred milliseconds against
    // data that had not moved, and sixteen frame hitches sitting on top of them.
    // Nothing in QA said so. The rollup table showed the total and left the
    // reader to notice that fifteen was too many.
    //
    // Repeated identical work is invisible in every other diagnostic the app
    // produces — each individual pass is fast, correct, and unremarkable. It is
    // only the gap between them that gives it away, so that is what this reads.

    /// Consecutive full classification passes must not stack up against
    /// unchanged data. A gap under half a second between one pass finishing and
    /// the next starting means a cache that should have hit did not.
    static func classificationNotRepeating() -> QAInvariantResult {
        let passes = QAProcessTracker.shared.records
            .filter { $0.name == "Cook Now classify" && $0.state != .running }
            .sorted { $0.startedAt < $1.startedAt }
        guard passes.count >= 3 else {
            return QAInvariantResult(name: "Classification does not repeat",
                                     status: .blocked,
                                     detail: "\(passes.count) classification pass(es) recorded — use Cook Now for a minute to exercise this probe",
                                     critical: false)
        }
        var bursts = 0
        var closest = Double.greatestFiniteMagnitude
        for (a, b) in zip(passes, passes.dropFirst()) {
            let gap = b.startedAt.timeIntervalSince(a.endedAt ?? a.startedAt)
            guard gap >= 0 else { continue }
            if gap < 0.5 {
                bursts += 1
                closest = min(closest, gap)
            }
        }
        let totalMs = passes.reduce(0.0) { $0 + $1.duration } * 1000
        if bursts == 0 {
            return QAInvariantResult(name: "Classification does not repeat",
                                     status: .ok,
                                     detail: "\(passes.count) passes, \(Int(totalMs))ms total, none stacked on the one before · memo holding \(CookNowCompute.memoDepth) snapshot(s)",
                                     critical: false)
        }
        return QAInvariantResult(name: "Classification does not repeat",
                                 status: .violation,
                                 detail: "\(bursts) of \(passes.count - 1) passes started within half a second of the previous one finishing (closest \(Int(closest * 1000))ms) across \(Int(totalMs))ms of classification — the snapshot memo is being evicted between callers",
                                 critical: false)
    }

    /// Verifies the Worker URL is present and syntactically valid. Does NOT make
    /// a network call — probes must be offline-safe. A misconfigured Worker means
    /// every AI feature silently falls back to on-device or 503s.
    static func workerConfigured() -> QAInvariantResult {
        let url = BuildConfig.receiptWorkerURL
        guard !url.isEmpty else {
            return QAInvariantResult(name: "Worker URL configured",
                                     status: .violation,
                                     detail: "BuildConfig.receiptWorkerURL is empty — all AI routes will fail",
                                     critical: false)
        }
        guard URL(string: url) != nil, url.hasPrefix("https://") else {
            return QAInvariantResult(name: "Worker URL configured",
                                     status: .violation,
                                     detail: "URL is not a valid https address: \(url)",
                                     critical: false)
        }
        return QAInvariantResult(name: "Worker URL configured",
                                 status: .ok,
                                 detail: url,
                                 critical: false)
    }
}
