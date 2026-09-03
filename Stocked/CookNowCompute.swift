// CookNowCompute.swift
// ─────────────────────────────────────────────────────────────────
// The one place Cook Now surfaces go to turn the live store + session into a
// classified snapshot. Keeps the engine pure (it never sees the store) and
// keeps every screen's answer consistent because they all call this.
//
// Usage discipline (matches the app's existing derived-state rules):
//   • Call from .task / .onChange(of: store.inventoryRevision) /
//     .onChange(of: store.recipeRevision) / after a session override changes —
//     NEVER from inside a view body.
//   • Store the Output in @State and render from that.
//
// Substitute lookup is pre-resolved here into a plain dictionary before the
// engine runs, so the engine's resolver closure is a pure Sendable lookup and
// the substitution source of truth stays in GuestDataStore + StockedDatabase.
//
// PERF (Cook Now freeze / watchdog signal 9, July 2026) — three fixes here:
//
//   1. Output's four tier lists WERE computed properties. Every read re-filtered
//      and re-sorted the whole catalog, and CookNowResultsView reads each list
//      2–3× per body pass (once for `isEmptyEverywhere`, again per section).
//      That is ~10 full filter+sort passes per frame over ~150 recipes. They are
//      now stored, computed exactly once in `run`.
//
//   2. `run` is memoized on a revision key. Every Cook Now surface calls it from
//      `.task` plus three `.onChange` handlers, and pushing/popping between them
//      re-ran the entire classification against unchanged data. Same key → same
//      answer, returned instantly.
//
//   3. `classify(recipe:)` used to run the ENTIRE catalog to pick one recipe —
//      an O(catalog) pass to answer an O(1) question, on the main actor, from
//      recipe detail screens. It now classifies just that recipe unless the
//      memoized full pass happens to be warm already.
// ─────────────────────────────────────────────────────────────────

import Foundation

@MainActor
enum CookNowCompute {

    /// Everything a Cook Now surface needs to render, produced in one pass.
    ///
    /// The tier lists are STORED, not computed. See the perf note above: they
    /// are read many times per frame and each read used to re-filter and re-sort
    /// the full catalog.
    nonisolated struct Output: Sendable {
        var classified: [ClassifiedRecipe] = []
        var metrics = CookNowMetrics()
        var emphasis: CookNowMetrics.Emphasis = .noMatches

        /// Recipes in Ready Now: five or fewer unresolved after substitutions.
        var readyNow: [ClassifiedRecipe] = []
        /// Recipes with an in-stock substitution awaiting review (also Ready Now).
        var needsReview: [ClassifiedRecipe] = []
        /// Almost Ready: six or more unresolved after substitutions, closest first.
        var almostReady: [ClassifiedRecipe] = []
        /// Compatibility alias for the six-plus population.
        var morePossibilities: [ClassifiedRecipe] = []

        /// True when every tier is empty — one cheap check instead of touching
        /// four lists.
        var isEmptyEverywhere: Bool {
            readyNow.isEmpty && needsReview.isEmpty
                && almostReady.isEmpty && morePossibilities.isEmpty
        }

        static let empty = Output()

        /// Derive the four tier lists from `classified`, once.
        fileprivate mutating func buildTiers() {
            readyNow = classified.filter { $0.isActionableCookNowOption }.sorted {
                if $0.unresolvedCount != $1.unresolvedCount {
                    return $0.unresolvedCount < $1.unresolvedCount
                }
                // RL-004 — reservation-touching recipes sink below equally-ready
                // free ones; they are "ready if plans change", not fully safe.
                return !$0.usesReservedIngredients && $1.usesReservedIngredients
            }
            needsReview = classified.filter { $0.readiness == .swapNeedsReview }
            almostReady = classified.filter { $0.readiness != .excluded && $0.unresolvedCount >= 6 }
                .sorted { $0.unresolvedCount < $1.unresolvedCount }
            morePossibilities = CookNowEngine.morePossibilities(in: classified)
        }
    }

    // MARK: - Memo
    //
    // Cook Now surfaces call `run` from `.task` and from three `.onChange`
    // handlers. Navigating in and out of "See meals" re-ran a full classification
    // of ~150 recipes x ~10 ingredients against ~60 inventory items against
    // completely unchanged data. The revision counters the store already
    // maintains are exactly the right cache key.
    //
    // BUILD 75 — one entry was not enough, and the key was wrong.
    //
    // The Build 69 field export recorded fifteen full classification passes in
    // seven minutes — 2.21s of main-actor work, avg 147ms, worst 211ms — and all
    // sixteen frame hitches in that session (worst 321ms) sat on top of them.
    // Three of the passes landed inside four hundred milliseconds of each other
    // against data that had not moved:
    //
    //     20:14:45.987 · 178 ms · 134 recipes · 3 ready
    //     20:14:46.170 · 136 ms · 134 recipes · 3 ready
    //     20:14:46.349 · 134 ms · 134 recipes · 3 ready
    //
    // Identical inputs, identical outputs, three full passes. Two causes:
    //
    //   1. `session: nil` and an EMPTY `CookNowSession` produced different keys
    //      ("|-" versus "|0|0") and identical output. The engine reads only
    //      `confirmedSubstitutionKeys` and `overrides` off the session, and both
    //      are empty either way, so the two calls are the same computation.
    //      `QABackgroundRunner` passes nil at all four of its start sites and
    //      `RefreshKitchenView` passes nil too, while every Cook Now surface
    //      passes the live session — so the two alternated and each evicted the
    //      other on every pass. The session component is now normalized: absent
    //      and empty are the same key.
    //
    //   2. Even with that fixed, a one-entry memo thrashes as soon as two callers
    //      hold genuinely different sessions. `QAInvariants.runAllYielding` yields
    //      the main actor between probes precisely so other work can interleave —
    //      which is exactly the window in which a mounted Cook Now surface
    //      recomputes and drops the entry the next probe was about to hit. The
    //      memo now keeps a few entries in least-recently-used order, so
    //      alternating callers hit instead of evicting.
    //
    // The cap is deliberately small. Each `Output` holds the whole classified
    // catalog, and the number of distinct sessions alive at one time is two or
    // three, never four.

    private struct MemoEntry {
        let key: String
        let value: Output
    }

    private static var memo: [MemoEntry] = []
    private static var memoGeneration: UInt64 = 0
    private static let memoCap = 4

    /// The part of the cache key that describes the session.
    ///
    /// Written so a nil session and an empty session are byte-identical, because
    /// they are byte-identical as classifier input. Contents rather than counts:
    /// swapping one override for another leaves the count unchanged and changes
    /// the answer, which the old count-only key could not see. Both collections
    /// are small — a handful of ingredient names — so building this is cheap
    /// next to the pass it avoids.
    private static func sessionComponent(_ session: CookNowSession?) -> String {
        let subs: [String] = (session?.confirmedSubstitutionKeys).map { Array($0).sorted() } ?? []
        let overrideKeys: [String] = session.map {
            $0.overridesSnapshotForEngine.map { "\($0.key)=\($0.value.rawValue)" }.sorted()
        } ?? []
        return "\(subs.count):\(subs.joined(separator: ","))"
            + "|\(overrideKeys.count):\(overrideKeys.joined(separator: ","))"
    }

    private static func key(store: GuestDataStore, session: CookNowSession?) -> String {
        var k = "\(ObjectIdentifier(store))|\(store.inventoryRevision)|\(store.recipeRevision)|\(store.planRevision)"
        k += "|\(OnlineRecipesLoader.shared.revision)|\(OnlineRecipesLoader.shared.recipes.count)"
        k += "|" + store.cookingProfile.allergens.sorted().joined(separator: ",")
        let substitutionKey = store.userSubstitutions
            .map { "\($0.ingredient.lowercased())::\($0.substitute.lowercased())" }
            .sorted().joined(separator: ",")
        k += "|subs:\(substitutionKey)"
        k += "|" + FamilyProfileStore.shared.activeAllergens.sorted().joined(separator: ",")
        k += "|" + FamilyProfileStore.shared.profiles.filter(\.isPresent)
            .flatMap(\.dislikes).sorted().joined(separator: ",")
        k += "|" + sessionComponent(session)
        return k
    }

    /// Drop every memoized snapshot. Call when something changes that the
    /// revision counters do not cover (a profile edit, a memory warning, a QA
    /// reset).
    static func invalidate() {
        memoGeneration &+= 1
        memo.removeAll()
    }

    /// The memoized snapshot for exactly these inputs, WITHOUT computing one.
    ///
    /// `QAInvariants` uses this to judge every probe against one snapshot rather
    /// than calling `run` three times across a suite that yields the main actor
    /// between probes. That is a correctness fix as much as a performance one:
    /// probes that compare two surfaces were comparing snapshots taken at
    /// different moments, so a genuine disagreement and an inventory edit
    /// mid-suite were indistinguishable.
    static func cached(store: GuestDataStore, session: CookNowSession?) -> Output? {
        let k = key(store: store, session: session)
        return memo.first(where: { $0.key == k })?.value
    }

    /// How many snapshots are held right now. QA reads this; nothing else should.
    static var memoDepth: Int { memo.count }

    /// Classify the current catalog against the current inventory, profile, and
    /// (optionally) a Cook Now session's overrides + confirmed substitutions.
    static func run(store: GuestDataStore, session: CookNowSession?) -> Output {
        let k = key(store: store, session: session)
        if let i = memo.firstIndex(where: { $0.key == k }) {
            // Move to front. With a cap this small, LRU ordering is the whole
            // point — it is what stops two alternating callers from evicting
            // each other's entry on every pass.
            let hit = memo.remove(at: i)
            memo.insert(hit, at: 0)
            return hit.value
        }

        let process = QAProcessTracker.shared.begin("Cook Now classify",
                                                    detail: "catalog + inventory pass")
        let out = compute(store: store, session: session)
        process.finish(detail: "\(out.classified.count) recipes · \(out.readyNow.count) ready")

        memo.insert(MemoEntry(key: k, value: out), at: 0)
        if memo.count > memoCap { memo.removeLast(memo.count - memoCap) }
        return out
    }

    /// Snapshot live state on the main actor, then classify on a utility executor.
    /// Yielding on the main actor was insufficient: one substitution scan could
    /// exceed the watchdog budget before the next yield was reached.
    static func runYielding(store: GuestDataStore, session: CookNowSession?) async -> Output? {
        guard !Task.isCancelled else { return nil }
        if let hit = cached(store: store, session: session) { return hit }
        let revision = key(store: store, session: session)
        let generation = memoGeneration
        let input = snapshot(store: store, session: session)
        let work = Task.detached(priority: .utility) {
            compute(input, cancellable: true)
        }
        let result = await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
        guard let out = result else { return nil }
        guard generation == memoGeneration,
              revision == key(store: store, session: session), !Task.isCancelled else { return nil }
        memo.removeAll { $0.key == revision }
        memo.insert(MemoEntry(key: revision, value: out), at: 0)
        if memo.count > memoCap { memo.removeLast(memo.count - memoCap) }
        return out
    }

    nonisolated private struct Input: Sendable {
        let recipes: [UserRecipe]
        let inStock: [String]
        let substituteStock: [String]
        let availableNames: Set<String>
        let allergens: [String]
        let dislikes: [String]
        let userEntries: [UserSubstitutionEntry]
        let builtInEntries: [SubstitutionEntry]
        let confirmed: Set<String>
        let overrides: [String: IngredientOverride]
        let reservedNames: Set<String>
        let inventoryEmpty: Bool
    }

    private static func compute(store: GuestDataStore, session: CookNowSession?, recipes suppliedRecipes: [UserRecipe]? = nil) -> Output {
        compute(snapshot(store: store, session: session, recipes: suppliedRecipes), cancellable: false)!
    }

    private static func snapshot(store: GuestDataStore, session: CookNowSession?, recipes suppliedRecipes: [UserRecipe]? = nil) -> Input {
        // WAS: `store.cookCatalog` — saved recipes plus starter meals only, so
        // Discover recipes and saved AI-generated recipes could never receive a
        // readiness tier. Now the full classifiable catalog, with the Discover
        // pool read straight from the loader that the Recipes tab uses, so both
        // tabs are scoring the same recipes from one source of truth.
        let recipes = suppliedRecipes ?? store.classifiableCatalog(discover: OnlineRecipesLoader.shared.recipes)

        // In-stock names: same availability rule the rest of the app uses.
        let inStock = KitchenAvailability.availableItems(in: store.inventoryItems).map { $0.name }

        // PERF: hoisted out of the ingredient loop below. `store.ingredientInStock`
        // rebuilt the available-name Set from `inventoryItems` on EVERY call —
        // roughly 700 times per pass, once per distinct ingredient in the catalog.
        // Reading the store's memoized set once means the loop reuses one Set
        // instance, which also lets `KitchenAvailability`'s token index memo hit
        // instead of rebuilding an index per ingredient.
        let availableNames = store.inStockNameSet

        // Allergens: the saved cooking profile PLUS the allergies recorded on the
        // family profiles of everyone currently present.
        let family = FamilyProfileStore.shared
        let allergens = (store.cookingProfile.allergens + family.activeAllergens)
            .filter { !$0.isEmpty }
        // Dislikes are the household's soft constraints — excluded like allergens
        // by the engine, which is the behaviour the model documents.
        let dislikes = Array(Set(
            family.profiles.filter(\.isPresent).flatMap(\.dislikes).map { $0.lowercased() }
        )).filter { !$0.isEmpty }

        let ledger = ReservationLedger.shared
        ledger.refreshIfNeeded(store: store)
        return Input(recipes: recipes, inStock: inStock,
                     substituteStock: store.inventoryItems.filter { $0.level > 0 }.map { $0.name.lowercased() },
                     availableNames: availableNames, allergens: allergens, dislikes: dislikes,
                     userEntries: store.userSubstitutions,
                     builtInEntries: StockedDatabase.shared.substitutionEntries,
                     confirmed: session?.confirmedSubstitutionKeys ?? [],
                     overrides: session?.overridesSnapshotForEngine ?? [:],
                     reservedNames: ledger.snapshot.reservedNames,
                     inventoryEmpty: store.inventoryItems.isEmpty)
    }

    nonisolated private static func compute(_ input: Input, cancellable: Bool) -> Output? {
        let recipes = input.recipes

        // Pre-resolve in-stock substitutes for every ingredient the classifier
        // might ask about (anything not directly in stock). One store pass;
        // the engine then does pure dictionary lookups.
        //
        // PERF: `seen` short-circuits the repeat work. The old loop checked
        // `subMap[key] == nil` but still called `store.ingredientInStock(ing.name)`
        // — a full fuzzy scan of the inventory — for every ingredient of every
        // recipe, including the thousands of duplicates ("salt" appears in half
        // the catalog). Now each distinct ingredient name is resolved once.
        var subMap: [String: [String]] = [:]
        var seen = Set<String>()
        for r in recipes {
            if cancellable && Task.isCancelled { return nil }
            for ing in r.ingredients where !ing.isOptional {
                let key = ing.name.lowercased().trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                if !KitchenAvailability.isPresent(ing.name, inNames: input.availableNames) {
                    subMap[key] = SubstitutionEngine.local(for: ing.name,
                        userEntries: input.userEntries, builtInEntries: input.builtInEntries)
                        .map(\.substitute).filter { substitute in
                            let lower = substitute.lowercased()
                            return input.substituteStock.contains { $0.contains(lower) || lower.contains($0) }
                        }
                }
            }
        }
        let lookup = subMap  // immutable copy captured by the Sendable resolver

        let engine = CookNowEngine(
            recipes: recipes,
            inStockNames: input.inStock,
            allergens: input.allergens,
            dislikes: input.dislikes,
            confirmedSubstitutions: input.confirmed,
            overrides: input.overrides
        )

        var classified: [ClassifiedRecipe] = []
        classified.reserveCapacity(recipes.count)
        for recipe in recipes {
            if cancellable && Task.isCancelled { return nil }
            classified.append(engine.classify(recipe) { name in
                lookup[name.lowercased().trimmingCharacters(in: .whitespaces), default: []]
            })
        }

        // RL-004 — stamp recipes that would consume reservations held by the
        // meal plan, so no surface presents them as fully safe. The ledger is
        // revision-cached, so this is a no-op unless the plan/inventory moved.
        let annotated = CookNowEngine.annotatingReservations(classified,
                                                             reservedNames: input.reservedNames)

        var out = Output()
        out.classified = annotated
        out.metrics = CookNowEngine.metrics(from: annotated)
        out.emphasis = CookNowEngine.emphasis(for: out.metrics,
                                              inventoryEmpty: input.inventoryEmpty)
        out.buildTiers()
        return out
    }

    /// The classification for one specific recipe under the current snapshot.
    ///
    /// PERF: this used to call `run(...)` — the entire catalog — to answer a
    /// question about one recipe, from recipe detail screens that open constantly.
    /// It now reuses the full pass only when it is already memoized, and
    /// otherwise classifies the single recipe.
    static func classify(recipe: UserRecipe, store: GuestDataStore, session: CookNowSession?) -> ClassifiedRecipe {
        if let hit = cached(store: store, session: session)?
            .classified.first(where: { $0.recipe.id == recipe.id }) {
            return hit
        }

        let process = QAProcessTracker.shared.begin("Cook Now classify one",
                                                    detail: recipe.title)
        defer { process.finish() }

        let inStock = KitchenAvailability.availableItems(in: store.inventoryItems).map { $0.name }
        let availableNames = store.inStockNameSet
        var subMap: [String: [String]] = [:]
        for ing in recipe.ingredients where !ing.isOptional {
            let key = ing.name.lowercased().trimmingCharacters(in: .whitespaces)
            guard subMap[key] == nil else { continue }
            if !KitchenAvailability.isPresent(ing.name, inNames: availableNames) {
                subMap[key] = store.inStockSubstitutes(for: ing.name)
            }
        }
        let lookup = subMap
        let family = FamilyProfileStore.shared
        let engine = CookNowEngine(
            recipes: [recipe],
            inStockNames: inStock,
            allergens: (store.cookingProfile.allergens + family.activeAllergens).filter { !$0.isEmpty },
            confirmedSubstitutions: session?.confirmedSubstitutionKeys ?? [],
            overrides: session?.overridesSnapshotForEngine ?? [:]
        )
        let classified = engine.classify(recipe) { name in
            lookup[name.lowercased().trimmingCharacters(in: .whitespaces), default: []]
        }
        let ledger = ReservationLedger.shared
        ledger.refreshIfNeeded(store: store)
        return CookNowEngine.annotatingReservations([classified],
                                                    reservedNames: ledger.snapshot.reservedNames).first ?? classified
    }
}

// MARK: - Session bridge

extension CookNowSession {
    /// The overrides dictionary in the exact shape the engine consumes.
    var overridesSnapshotForEngine: [String: IngredientOverride] { overrides }
}
