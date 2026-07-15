//
//  CookAheadCoordinator.swift
//  Stocked
//
//  Owns the *rules* for advancing a cooked-ahead meal through its lifecycle
//  without losing its place on the calendar. Views (CookAheadStatusView,
//  FinishAndServeView, PlannedMealCookTransitionView) call into this instead of
//  hand-rolling status transitions, so the ordering stays consistent and
//  testable.
//
//  Key invariant from the spec: cooking a planned dinner early NEVER removes it
//  from tonight and NEVER marks it eaten. Only the status moves; the planned day
//  is untouched here.
//
//  Pure & non-isolated: transition logic is data-in/data-out.
//

import Foundation

nonisolated enum CookAheadCoordinator {

    /// The forward lifecycle order for a meal being cooked ahead. `.none` is the
    /// resting/planned state; `.served` is terminal.
    static let forwardOrder: [CookAheadStatus] = [
        .none, .prepped, .marinating, .cookingEarly, .cooked, .cooling, .stored, .readyToReheat, .served
    ]

    /// The status that should follow `current` when the user taps "advance".
    /// Returns nil at the terminal state.
    static func next(after current: CookAheadStatus) -> CookAheadStatus? {
        guard let i = forwardOrder.firstIndex(of: current), i + 1 < forwardOrder.count else { return nil }
        return forwardOrder[i + 1]
    }

    /// The status immediately before `current` (for an undo / step-back).
    static func previous(before current: CookAheadStatus) -> CookAheadStatus? {
        guard let i = forwardOrder.firstIndex(of: current), i > 0 else { return nil }
        return forwardOrder[i - 1]
    }

    /// When the user chooses "Cook Ahead Now" from the planner, this is the
    /// status the meal enters. If they've already prepped/marinated we respect
    /// that and don't regress.
    static func statusForCookingEarly(from current: CookAheadStatus) -> CookAheadStatus {
        switch current {
        case .none, .prepped, .marinating: return .cookingEarly
        default: return current   // already cooking or further along — leave it
        }
    }

    /// Whether this meal should appear in the "Finish & Serve" list: it has been
    /// cooked ahead and is not yet served.
    static func isAwaitingFinish(_ status: CookAheadStatus) -> Bool {
        status.isCookedAhead && status != .none
    }

    /// Whether a status represents food that is physically cooked (for inventory
    /// output creation / storage prompts).
    static func isCooked(_ status: CookAheadStatus) -> Bool {
        switch status {
        case .cooked, .cooling, .stored, .readyToReheat, .served: return true
        case .none, .prepped, .marinating, .cookingEarly:         return false
        }
    }

    /// A short, honest next-action label for the current status, used by the
    /// status tracker's primary button.
    static func primaryActionLabel(for status: CookAheadStatus) -> String? {
        switch status {
        case .none:          return "Start prep"
        case .prepped:       return "Start marinating"
        case .marinating:    return "Cook now"
        case .cookingEarly:  return "Mark cooked"
        case .cooked:        return "Start cooling"
        case .cooling:       return "Move to storage"
        case .stored:        return "Ready to reheat"
        case .readyToReheat: return "Finish & serve"
        case .served:        return nil
        }
    }
}
