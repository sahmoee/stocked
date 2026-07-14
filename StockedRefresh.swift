// StockedRefresh.swift — one standard pull-to-refresh action for the whole app.
//
// StockedShell wraps nearly every post-login screen in its own ScrollView, so attaching
// .refreshable there gives pull-to-refresh app-wide in one place. This helper defines what a
// "standard" refresh means so every screen behaves the same:
//   1. If the user is in a household, pull the latest household document (inventory, grocery,
//      recipes, planner) from the Worker.
//   2. Reset the store's derived caches so recomputed values (pantry set, indexes) rebuild
//      from fresh data.
//   3. Confirm with a light haptic.
// Screens with extra needs (e.g. re-hitting a network feed) pass their own onRefresh to
// StockedShell, which replaces the standard action for that screen only.
import SwiftUI

@MainActor
enum StockedRefresh {
    /// The default action behind pull-to-refresh on every StockedShell screen.
    static func standard(session: AppSession) async {
        let store = session.guestStore

        // Household pull — only when actually in a household (owner or member).
        switch HouseholdSync.shared.state {
        case .owner, .member, .syncing:
            await HouseholdSync.shared.pullNow(into: store)
        default:
            break
        }

        // Rebuild derived caches from current data.
        await store.refreshInventory()

        HapticManager.light()
    }
}
