// RecipeBudgetStatus.swift — #15 Spoonacular budget visibility.
//
// The Spoonacular 150/day quota lives in the Cloudflare worker, not the app, so the app can't
// read the exact remaining count without the worker returning it. This file provides a small,
// self-contained piece the app can use NOW:
//   • RecipeBudgetState — a tiny on-device flag the app flips when the worker reports the daily
//     quota is exhausted (e.g. on an HTTP 429 from the recipe endpoint). It auto-resets each day.
//   • RecipeBudgetBanner — a graceful "online recipe ideas are paused until tomorrow" view, so
//     thinning results feel intentional instead of broken.
//
// To wire later (small, when you touch the recipe client): on a quota error, call
// `RecipeBudgetState.shared.markExhausted()`. Show `RecipeBudgetBanner()` where online recipes
// render. No existing files are modified by this delivery.

import SwiftUI
import Observation

@Observable
final class RecipeBudgetState {
    static let shared = RecipeBudgetState()

    private let key = "spoonacular_exhausted_day"

    private init() {}

    /// True if the daily online-recipe quota is known to be exhausted for *today*.
    var isExhaustedToday: Bool {
        guard let day = UserDefaults.standard.string(forKey: key) else { return false }
        return day == Self.todayKey
    }

    /// Mark the quota exhausted for today (call on a worker 429 / quota error).
    func markExhausted() {
        UserDefaults.standard.set(Self.todayKey, forKey: key)
    }

    /// Clear the flag (e.g. if a later request unexpectedly succeeds).
    func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }

    private static var todayKey: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}

/// Drop this where online recipe results render; it shows only when the quota is spent.
struct RecipeBudgetBanner: View {
    private let state = RecipeBudgetState.shared

    var body: some View {
        if state.isExhaustedToday {
            HStack(spacing: 10) {
                Image(systemName: "clock.badge.checkmark")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fresh online recipe ideas are paused")
                        .font(.system(size: 13, weight: .semibold))
                    Text("You've reached today's limit for new online suggestions — they'll refresh tomorrow. Your saved recipes and what's in your kitchen are still fully available.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}
