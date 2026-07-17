// CookSessionPersistence.swift
// ─────────────────────────────────────────────────────────────────
// RL-001 / RL-002 — Pause, resume, and cancel for active cooking sessions.
//
// One durable, local record of the cook that is currently underway (or paused).
// The snapshot captures everything needed to put the user back at the EXACT
// step they left — completed steps, checked ingredients, serving count,
// session substitutions, appliances/components, notes, and every timer with
// real wall-clock semantics (a running timer stores its fire DATE, so a device
// locked longer than the timer resumes showing the timer as finished).
//
// Design rules, straight from the spec:
//   • Persisted with immediate write-through on every mutation so force-close,
//     relaunch, backgrounding, and offline all keep the session intact.
//   • Inventory is NEVER deducted on start/pause/background/close/resume —
//     only once, on explicit completion, guarded by an idempotent completion
//     token so repeated Finish taps / resume-after-complete can't deduct twice.
//   • Canceling clears the record and consumes the tokens (no meal history, no
//     streaks, no deduction) but never touches a planned meal.
//   • Completed and canceled sessions never reappear as resumable.
//
// Pure value types are nonisolated + Sendable (same stance as
// CookingSessionModel / the CookLater cross-check engine DTOs); the store is
// @MainActor @Observable so Cook hub cards and Home/Daily Brief can render
// `ActiveCookSessionStore.shared.resumable` directly.
// ─────────────────────────────────────────────────────────────────

import SwiftUI
import Observation

// MARK: - Session status

/// Lifecycle of one recorded cooking session. Only `active` and `paused` are
/// ever offered for resume; `completed` / `canceled` are terminal.
nonisolated enum ActiveCookSessionStatus: String, Codable, Sendable {
    case active     // user is (or was, before a force-close) mid-cook
    case paused     // user explicitly paused and left
    case completed  // finished — deduction/history handled exactly once
    case canceled   // deliberately discarded — nothing recorded anywhere
}

// MARK: - Timer state (wall-clock aware)

/// One step timer, captured so it survives relaunch with real-world semantics:
///   • running  → `endDate` holds the wall-clock fire date; on restore the
///     remaining time is recomputed (and a timer that would have finished
///     while away restores as finished/ready).
///   • paused   → `pausedRemaining` holds the frozen remaining seconds.
///   • finished → `isFinished` short-circuits both.
nonisolated struct CookSessionTimerState: Codable, Sendable {
    var stepIndex: Int
    var stepText: String        // needed to rebuild notifications / Live Activity
    var totalSeconds: Int
    var endDate: Date? = nil          // set only while running
    var pausedRemaining: Int? = nil   // set only while paused mid-count
    var isFinished: Bool = false
}

// MARK: - Session snapshot (persisted form)

/// The Codable projection of an in-flight cook that survives anything short of
/// deleting the app. Carries the full recipe payload (title/ingredients/steps)
/// so resume can rebuild the cooking screen directly — never bouncing the user
/// through the recipe detail page first.
nonisolated struct ActiveCookSessionSnapshot: Codable, Sendable, Identifiable {
    var id: UUID = UUID()
    var recipeID: UUID? = nil
    var recipeTitle: String
    var ingredients: [String]
    var steps: [String]
    /// The step the user was on (swipe-mode card / expanded row).
    var currentStep: Int = 0
    var completedSteps: [Int] = []
    var checkedIngredientIndexes: [Int] = []
    var servings: Int
    /// ingredient → in-stock substitute chosen for this session (guidance only).
    var substitutions: [String: String] = [:]
    /// Appliances/equipment selected for this cook (from the Cook Now workspace).
    var selectedAppliances: [String] = []
    /// Sides / extra components attached to the session.
    var selectedComponents: [String] = []
    var notes: String = ""
    var timers: [CookSessionTimerState] = []
    /// Planned-meal coupling — kept so cancel can explicitly NOT remove the plan.
    var plannedMealID: UUID? = nil
    var startedAt: Date = Date()
    var pausedAt: Date? = nil
    var lastSavedAt: Date = Date()
    var status: ActiveCookSessionStatus = .active
    /// Idempotency key for completion. Consumed exactly once for the inventory
    /// deduction and once for the meal-history record — see ActiveCookSessionStore.
    var completionToken: UUID = UUID()

    /// "Step 3 of 8" — for the paused-session card.
    var stepProgressLabel: String {
        let done = Set(completedSteps).count
        return "\(min(done, steps.count)) of \(steps.count) steps done"
    }

    /// "Paused 12m ago" / "In progress" — for the paused-session card.
    var pausedAgoLabel: String {
        let reference = pausedAt ?? lastSavedAt
        let mins = max(0, Int(Date().timeIntervalSince(reference) / 60))
        let when: String
        if mins < 1 { when = "just now" }
        else if mins < 60 { when = "\(mins)m ago" }
        else { when = "\(mins / 60)h \(mins % 60)m ago" }
        return status == .paused ? "Paused \(when)" : "In progress · left \(when)"
    }
}

// MARK: - Store

/// The single source of truth for the persisted active-cook record. Exactly one
/// session is tracked at a time (starting a new cook replaces the old record).
/// Every mutation writes through to UserDefaults immediately — no debounce —
/// so a force-close a moment later loses nothing.
@MainActor
@Observable
final class ActiveCookSessionStore {

    static let shared = ActiveCookSessionStore()

    // Storage keys (new keys — the legacy "activeCookSession" pill record in
    // AppSession is untouched and still drives the floating pill).
    private static let sessionKey     = "activeCookSessionSnapshot_v1"
    private static let deductLedgerKey = "cookSessionDeductedTokens_v1"
    private static let recordLedgerKey = "cookSessionRecordedTokens_v1"
    /// Paused/abandoned sessions older than this stop being offered for resume.
    private static let staleAfter: TimeInterval = 24 * 3600
    /// Bounded token ledgers — enough to cover any realistic zombie UI, tiny on disk.
    private static let ledgerCap = 32

    /// The tracked session, if any (any status until explicitly cleared).
    private(set) var current: ActiveCookSessionSnapshot?

    // Consumed idempotency tokens, persisted so relaunch can't re-consume.
    private var deductedTokens: [UUID]
    private var recordedTokens: [UUID]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.sessionKey),
           let snap = try? JSONDecoder().decode(ActiveCookSessionSnapshot.self, from: data) {
            current = snap
        } else {
            current = nil
        }
        deductedTokens = Self.loadLedger(Self.deductLedgerKey)
        recordedTokens = Self.loadLedger(Self.recordLedgerKey)
        clearIfStale()
    }

    // MARK: Resumable

    /// The session a Cook hub card (or Home / Daily Brief) should offer to
    /// resume. Completed/canceled sessions and anything stale return nil.
    var resumable: ActiveCookSessionSnapshot? {
        guard let snap = current,
              snap.status == .active || snap.status == .paused,
              Date().timeIntervalSince(snap.lastSavedAt) < Self.staleAfter
        else { return nil }
        return snap
    }

    // MARK: Mutations (each writes through immediately)

    /// Record/replace the tracked session. Called on cook start and on every
    /// progress capture (step change, timer change, backgrounding).
    func save(_ snapshot: ActiveCookSessionSnapshot) {
        var snap = snapshot
        snap.lastSavedAt = Date()
        current = snap
        persistSession()
    }

    /// Explicit pause: freeze the given state and mark it paused.
    func pause(_ snapshot: ActiveCookSessionSnapshot) {
        var snap = snapshot
        snap.status = .paused
        snap.pausedAt = Date()
        snap.lastSavedAt = Date()
        current = snap
        persistSession()
    }

    /// Safety-net pause for unexpected exits (swipe-back, view teardown). Only
    /// flips an ACTIVE session to paused; explicit pauses/cancels/completes win.
    func pauseCurrentIfActive() {
        guard var snap = current, snap.status == .active else { return }
        snap.status = .paused
        snap.pausedAt = Date()
        snap.lastSavedAt = Date()
        current = snap
        persistSession()
    }

    /// Adopt a snapshot the user chose to resume: it becomes the live session
    /// again (status active, pause cleared). Same id + completion token, so the
    /// idempotency guarantees carry across the resume.
    func adoptResumed(_ snapshot: ActiveCookSessionSnapshot) {
        var snap = snapshot
        snap.status = .active
        snap.pausedAt = nil
        snap.lastSavedAt = Date()
        current = snap
        persistSession()
    }

    // MARK: Completion (idempotent)

    /// Consume the DEDUCTION side of a completion token. Returns true exactly
    /// once per token — callers deduct inventory only on true. Resume, relaunch,
    /// and repeated Finish taps all return false after the first consumption.
    func markCompleted(token: UUID) -> Bool {
        guard !deductedTokens.contains(token) else { return false }
        deductedTokens.append(token)
        if deductedTokens.count > Self.ledgerCap { deductedTokens.removeFirst(deductedTokens.count - Self.ledgerCap) }
        Self.saveLedger(deductedTokens, key: Self.deductLedgerKey)
        markCurrentCompleted()
        return true
    }

    /// Consume the MEAL-HISTORY side of a completion token (past meal, streak,
    /// achievements). Separate ledger so "skip deduction" still records the meal
    /// exactly once.
    func markMealRecorded(token: UUID) -> Bool {
        guard !recordedTokens.contains(token) else { return false }
        recordedTokens.append(token)
        if recordedTokens.count > Self.ledgerCap { recordedTokens.removeFirst(recordedTokens.count - Self.ledgerCap) }
        Self.saveLedger(recordedTokens, key: Self.recordLedgerKey)
        markCurrentCompleted()
        return true
    }

    /// Convenience: consume the current session's deduction token. When no
    /// session is tracked (legacy entry paths), returns true so those flows
    /// behave exactly as before this feature existed.
    func completeCurrentSession() -> Bool {
        guard let snap = current else { return true }
        return markCompleted(token: snap.completionToken)
    }

    /// Convenience: consume the current session's meal-history token.
    func recordMealForCurrentSession() -> Bool {
        guard let snap = current else { return true }
        return markMealRecorded(token: snap.completionToken)
    }

    /// Mark the tracked session completed WITHOUT consuming any token (used by
    /// "skip deduction" so the session stops being resumable but a later,
    /// deliberate deduction of a different cook isn't blocked).
    func markCurrentCompleted() {
        guard var snap = current, snap.status != .canceled else { return }
        snap.status = .completed
        snap.lastSavedAt = Date()
        current = snap
        persistSession()
    }

    // MARK: Cancel / clear

    /// RL-002 — deliberate cancel. Clears the record and consumes BOTH token
    /// sides, so a zombie Finish screen can never deduct or record a canceled
    /// meal. Never touches planned meals: a meal cooked from a plan stays planned.
    func cancel() {
        if let snap = current {
            if !deductedTokens.contains(snap.completionToken) {
                deductedTokens.append(snap.completionToken)
                Self.saveLedger(deductedTokens, key: Self.deductLedgerKey)
            }
            if !recordedTokens.contains(snap.completionToken) {
                recordedTokens.append(snap.completionToken)
                Self.saveLedger(recordedTokens, key: Self.recordLedgerKey)
            }
        }
        current = nil
        persistSession()
    }

    /// Remove a finished session's record entirely (called after the rating /
    /// history step wraps up). The consumed tokens stay in the ledgers.
    func clearFinished() {
        guard let status = current?.status, status == .completed || status == .canceled else { return }
        current = nil
        persistSession()
    }

    /// Drop terminal or too-old records so canceled/completed/ancient sessions
    /// never reappear as resumable. Safe to call any time (hub onAppear, launch).
    func clearIfStale() {
        guard let snap = current else { return }
        let terminal = snap.status == .completed || snap.status == .canceled
        let tooOld = Date().timeIntervalSince(snap.lastSavedAt) >= Self.staleAfter
        if terminal || tooOld {
            current = nil
            persistSession()
        }
    }

    // MARK: Persistence plumbing (immediate write-through)

    private func persistSession() {
        if let snap = current, let data = try? JSONEncoder().encode(snap) {
            UserDefaults.standard.set(data, forKey: Self.sessionKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        }
    }

    private nonisolated static func loadLedger(_ key: String) -> [UUID] {
        (UserDefaults.standard.array(forKey: key) as? [String])?.compactMap(UUID.init) ?? []
    }

    private nonisolated static func saveLedger(_ tokens: [UUID], key: String) {
        UserDefaults.standard.set(tokens.map(\.uuidString), forKey: key)
    }
}

// MARK: - Paused-session card (shared by Cook Hub + Cook Now Home)

/// The visible resumable-session banner. Resuming returns directly to the exact
/// saved step (never the recipe detail page); the trailing option discards via
/// the RL-002 cancel confirmation owned by the presenting screen.
struct CookSessionResumeCard: View {
    let snapshot: ActiveCookSessionSnapshot
    let onResume: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: snapshot.status == .paused ? "pause.circle.fill" : "flame.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.stockedGold)
                Text(snapshot.status == .paused ? "Paused cooking session" : "Cooking in progress")
                    .font(.system(size: 12, weight: .bold))
                    .kerning(0.6)
                    .foregroundStyle(Color.stockedGold)
                Spacer()
                Text(snapshot.pausedAgoLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.stockedWhite.opacity(0.55))
            }
            Text(snapshot.recipeTitle)
                .font(.system(size: 17, weight: .bold, design: .serif))
                .foregroundStyle(Color.stockedWhite)
                .lineLimit(2)
            Text("\(snapshot.stepProgressLabel) · serves \(snapshot.servings)")
                .font(.system(size: 12))
                .foregroundStyle(Color.stockedWhite.opacity(0.65))
            HStack(spacing: 10) {
                Button(action: onResume) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill").font(.system(size: 11, weight: .bold))
                        Text("Resume Cooking")
                            .font(.system(size: 13.5, weight: .semibold, design: .serif))
                    }
                    .foregroundStyle(Color.stockedCharcoal)
                    .padding(.horizontal, 16).padding(.vertical, 9)
                    .background(Color.stockedGold)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .a11yButton("Resume cooking \(snapshot.recipeTitle)",
                            hint: "Returns to the exact step you left")
                Button(action: onDiscard) {
                    Text("Cancel Meal")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite.opacity(0.7))
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(Color.white.opacity(0.10))
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .a11yButton("Cancel this meal", hint: "Discards progress without recording the meal")
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stockedCharcoal)
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
            .stroke(Color.stockedGold.opacity(0.4), lineWidth: 1))
    }
}
