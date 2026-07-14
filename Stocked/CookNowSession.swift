// CookNowSession.swift
// ─────────────────────────────────────────────────────────────────
// The single source of truth for one Cook Now cooking session.
//
// A session is created when the user begins moving toward a meal (choosing an
// ingredient, opening Smart Recommendation, etc.) and carries everything the
// downstream screens need so nothing is lost between the dashboard, Smart
// Recommendation, Recipe Detail, Kitchen Check, Prep, cooking, and Finish:
//
//   • Serving count — defaults SILENTLY to the saved household size, is
//     session-scoped, and never overwrites the household profile unless the
//     user explicitly asks to (makeHouseholdDefault).
//   • Temporary ingredient overrides — "I have this" / "I'm out" / "not sure" /
//     quantity-enough corrections that affect THIS meal's readiness only and do
//     NOT mutate permanent inventory.
//   • Confirmed substitutions — swaps the user approved for this session.
//   • Try-Another exclusions — a small ring so refreshing doesn't immediately
//     repeat the same recipe when alternatives exist.
//   • Prep completion — which prep tasks are done.
//   • Staged inventory changes — permanent updates the user asked to save,
//     held for the Inventory Update Review and applied exactly once.
//
// The session is @Observable (in-memory truth) with a small Codable snapshot
// persisted to UserDefaults on change, using the same debounce discipline as
// the rest of the app. Exactly ONE active session exists at a time; starting a
// new recipe while one is active is a product decision surfaced by the UI
// (resume vs discard), not a silent overwrite.
// ─────────────────────────────────────────────────────────────────

import Foundation
import Observation

// MARK: - Temporary override

/// A meal-only correction to an ingredient's availability. Never written to
/// permanent inventory unless separately staged.
nonisolated enum IngredientOverride: String, Codable, Sendable {
    case haveIt        // user physically has it (even if not logged / logged empty)
    case out           // user does not have it (even if logged in stock)
    case notSure       // uncertain — blocks "Kitchen Confirmed", does not resolve
    case enough        // has enough quantity for this meal
    case notEnough     // does not have enough for this meal
}

// MARK: - Staged permanent change

/// A permanent inventory change the user asked to save, queued for the
/// Inventory Update Review. Kept as intent (not applied) until reviewed.
nonisolated struct StagedInventoryChange: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case markAvailable   // confirm/add an item as present
        case markEmpty       // mark a logged item empty
        case reduceQuantity  // reduce quantity after use
        case addItem         // add a new (previously unlogged) item
        case markDiscarded   // discarded / thrown away
        case recordSubstitute// record that a substitute was used
    }
    var id = UUID()
    var ingredientName: String
    var kind: Kind
    var note: String = ""        // human-readable detail, e.g. "half and half"
    var applied: Bool = false    // guards against double application
}

// MARK: - Session snapshot (persisted form)

/// The Codable projection of a session that survives relaunch.
nonisolated struct CookNowSessionSnapshot: Codable, Sendable {
    var recipeID: UUID?
    var selectedIngredient: String?
    var servings: Int
    var overrides: [String: IngredientOverride]         // ingredient(lowercased) → override
    var confirmedSubstitutionKeys: [String]             // CookNowEngine.substitutionKey values
    var excludedRecipeIDs: [UUID]                        // Try-Another ring
    var completedPrepKeys: [String]
    var stagedChanges: [StagedInventoryChange]
    var startedAt: Date
    var lastActiveAt: Date
}

// MARK: - Session

@Observable
@MainActor
final class CookNowSession {

    // MARK: Persistence configuration
    private static let storageKey = "cookNowSession_v1"
    /// How long a dormant session's CONTEXT is kept before it is considered
    /// expired and discarded on next launch (servings, overrides, subs).
    private static let contextExpiry: TimeInterval = 12 * 3600
    /// How long after last activity we still offer to RESUME an in-progress cook
    /// (mirrors the existing 2-hour step-progress resume window).
    static let resumeWindow: TimeInterval = 2 * 3600

    // MARK: Live state
    /// The recipe currently being cooked/considered (nil = dashboard only).
    var recipeID: UUID?
    /// The primary ingredient the user is building around (nil = none).
    var selectedIngredient: String?
    /// Session serving count. Defaults to household size; session-scoped.
    var servings: Int
    /// Meal-only ingredient corrections.
    private(set) var overrides: [String: IngredientOverride] = [:]
    /// Confirmed substitution keys (CookNowEngine.substitutionKey).
    private(set) var confirmedSubstitutionKeys: Set<String> = []
    /// Recipes to deprioritize on the next Try-Another (most-recent-first ring).
    private(set) var excludedRecipeIDs: [UUID] = []
    /// Completed prep task keys.
    private(set) var completedPrepKeys: Set<String> = []
    /// Permanent changes queued for review.
    private(set) var stagedChanges: [StagedInventoryChange] = []

    let startedAt: Date
    private(set) var lastActiveAt: Date

    private var saveWorkItem: DispatchWorkItem?

    // MARK: Init

    /// Start a fresh session. `householdSize` seeds the default serving count.
    init(householdSize: Int) {
        self.servings = max(1, householdSize)
        self.startedAt = Date()
        self.lastActiveAt = Date()
    }

    /// Rehydrate from a snapshot (used on resume).
    init(snapshot: CookNowSessionSnapshot) {
        self.recipeID = snapshot.recipeID
        self.selectedIngredient = snapshot.selectedIngredient
        self.servings = max(1, snapshot.servings)
        self.overrides = snapshot.overrides
        self.confirmedSubstitutionKeys = Set(snapshot.confirmedSubstitutionKeys)
        self.excludedRecipeIDs = snapshot.excludedRecipeIDs
        self.completedPrepKeys = Set(snapshot.completedPrepKeys)
        self.stagedChanges = snapshot.stagedChanges
        self.startedAt = snapshot.startedAt
        self.lastActiveAt = snapshot.lastActiveAt
    }

    // MARK: Snapshot

    var snapshot: CookNowSessionSnapshot {
        CookNowSessionSnapshot(
            recipeID: recipeID,
            selectedIngredient: selectedIngredient,
            servings: servings,
            overrides: overrides,
            confirmedSubstitutionKeys: Array(confirmedSubstitutionKeys),
            excludedRecipeIDs: excludedRecipeIDs,
            completedPrepKeys: Array(completedPrepKeys),
            stagedChanges: stagedChanges,
            startedAt: startedAt,
            lastActiveAt: lastActiveAt
        )
    }

    // MARK: Mutations (each touches lastActive + persists)

    func setServings(_ n: Int) {
        servings = max(1, min(n, 99))
        touch()
    }

    func setOverride(_ override: IngredientOverride?, for ingredient: String) {
        let key = ingredient.lowercased().trimmingCharacters(in: .whitespaces)
        if let override { overrides[key] = override } else { overrides.removeValue(forKey: key) }
        touch()
    }

    func override(for ingredient: String) -> IngredientOverride? {
        overrides[ingredient.lowercased().trimmingCharacters(in: .whitespaces)]
    }

    func confirmSubstitution(ingredient: String, substitute: String) {
        confirmedSubstitutionKeys.insert(CookNowEngine.substitutionKey(ingredient: ingredient, substitute: substitute))
        touch()
    }

    func unconfirmSubstitution(ingredient: String, substitute: String) {
        confirmedSubstitutionKeys.remove(CookNowEngine.substitutionKey(ingredient: ingredient, substitute: substitute))
        touch()
    }

    func isSubstitutionConfirmed(ingredient: String, substitute: String) -> Bool {
        confirmedSubstitutionKeys.contains(CookNowEngine.substitutionKey(ingredient: ingredient, substitute: substitute))
    }

    /// Record the current recommendation so Try-Another deprioritizes it. Keeps
    /// a bounded ring so refresh eventually cycles back only after exhausting
    /// the alternatives.
    func excludeFromNext(_ id: UUID, ringSize: Int = 8) {
        excludedRecipeIDs.removeAll { $0 == id }
        excludedRecipeIDs.insert(id, at: 0)
        if excludedRecipeIDs.count > ringSize { excludedRecipeIDs = Array(excludedRecipeIDs.prefix(ringSize)) }
        touch()
    }

    func setPrepDone(_ key: String, done: Bool) {
        if done { completedPrepKeys.insert(key) } else { completedPrepKeys.remove(key) }
        touch()
    }

    func isPrepDone(_ key: String) -> Bool { completedPrepKeys.contains(key) }

    // MARK: Staged changes

    func stage(_ change: StagedInventoryChange) {
        // De-dupe by ingredient+kind so repeated taps don't pile up.
        stagedChanges.removeAll { $0.ingredientName.lowercased() == change.ingredientName.lowercased() && $0.kind == change.kind }
        stagedChanges.append(change)
        touch()
    }

    func unstage(_ id: UUID) {
        stagedChanges.removeAll { $0.id == id }
        touch()
    }

    /// Mark specific staged changes applied (called by the Inventory Update
    /// Review AFTER the store mutation succeeds). Idempotent.
    func markApplied(ids: Set<UUID>) {
        for i in stagedChanges.indices where ids.contains(stagedChanges[i].id) {
            stagedChanges[i].applied = true
        }
        touch()
    }

    /// Staged changes not yet applied.
    var pendingChanges: [StagedInventoryChange] { stagedChanges.filter { !$0.applied } }

    // MARK: Lifecycle

    private func touch() {
        lastActiveAt = Date()
        scheduleSave()
    }

    /// Whether an in-progress cook is recent enough to offer a resume prompt.
    var isResumable: Bool {
        recipeID != nil && Date().timeIntervalSince(lastActiveAt) < Self.resumeWindow
    }

    // MARK: Debounced persistence (mirrors the store's saveDebounced pattern)

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snap = snapshot
        let work = DispatchWorkItem { CookNowSession.persist(snap) }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private static func persist(_ snap: CookNowSessionSnapshot) {
        guard let data = try? JSONEncoder().encode(snap) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    /// Immediately clear the persisted session (called on discard / finish).
    static func clearPersisted() {
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    /// Load a persisted session if one exists AND its context has not expired.
    /// Expired sessions are cleared. Returns nil when there is nothing usable.
    static func loadPersisted() -> CookNowSessionSnapshot? {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let snap = try? JSONDecoder().decode(CookNowSessionSnapshot.self, from: data)
        else { return nil }
        if Date().timeIntervalSince(snap.lastActiveAt) > contextExpiry {
            clearPersisted()
            return nil
        }
        return snap
    }

    /// Discard this session's state and its persisted copy. The caller drops the
    /// reference; overrides and staged (unapplied) changes are intentionally lost.
    func discard() {
        overrides.removeAll()
        confirmedSubstitutionKeys.removeAll()
        excludedRecipeIDs.removeAll()
        completedPrepKeys.removeAll()
        stagedChanges.removeAll()
        recipeID = nil
        selectedIngredient = nil
        saveWorkItem?.cancel()
        Self.clearPersisted()
    }
}
