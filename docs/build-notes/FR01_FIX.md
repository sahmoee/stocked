# FR-01 fix — fresh-install / login flow

## The one root cause behind almost everything
On launch, `RootView.onAppear` called `KitchenTransferManager.autoRestoreOnNewDeviceIfNeeded`,
which **pulled a CloudKit backup with no consent**. That backup lives on your Apple ID and
**survives app deletion**, so a "fresh" install re-imported the old kitchen — inventory (your 94%),
preferences (dark mode), and `quizCompleted = true` (skipping onboarding). The blank screen was the
splash shown while that CloudKit fetch ran; the notification prompt landed on top of it.

## What changed, mapped to your 5 points

**1 — Permissions in context (your pivot).** No upfront-permissions coordinator was added. Camera,
Photos, Mic, Speech, Location, and Health are already requested at first use by the code that owns
each feature. Notifications are still asked once after onboarding (matches checkbook FR-05). The
only reason it felt wrong was the blank screen underneath it — which is gone now that auto-restore
is removed. The notification prompt now lands over the onboarding screen, not a blank one.

**2 — Dark mode on a fresh install → fixed.** The dark mode came from the restored preferences.
The local default is light (`ud.bool("darkMode")` is `false` when unset), so with auto-restore gone
a fresh install is light.

**3 — 94% stock after force-quit → fixed.** That was restored inventory. A fresh install now loads
empty; stock shows 0%.

**4 — Apple login must ask before restoring → done.** The unconditional restore on Sign in with
Apple is removed. Now, if the Apple ID has an iCloud backup AND this device has no local data, the
app shows a prompt: **"Restore from iCloud"** or **"Start Fresh."** Nothing is pulled unless you tap
Restore. (When you already have local guest data, the existing keep/discard prompt handles it, and
you can still restore later from Settings.)

**5 — Fresh / wipe / logout fully clean → done.** Erase All Data and Delete Account now also:
- **delete the iCloud CloudKit backup** (`deleteAlliCloudBackups`), so an erased kitchen can't come
  back on the next sign-in or restore, and
- **reset the 8 feature-store singletons in memory** (`FeatureSync.wipeAll`) — their files were
  already wiped, but the live arrays weren't, so a later edit or background-flush used to
  re-persist them. That "partial resurrection" is closed.

## Files changed
- `StockedApp.swift` — removed the launch auto-restore; added the restore-consent alert.
- `AppSession.swift` — `pendingICloudRestoreOffer` flag; CloudKit backup deletion in the erase path.
- `LoginView.swift` — Apple sign-in offers restore (with consent) instead of auto-pulling.
- `KitchenTransferManager.swift` — `latestBackupExists()` and `deleteAlliCloudBackups()`.
- `FeatureHouseholdSync.swift` — `FeatureSync.wipeAll()` resets the feature stores on erase.
- `GuestDataStore.swift` — `clearAll()` calls the feature-store wipe.

## Retest FR-01 (rebuild first — this is code-only, no data migration)
1. Delete the app, reinstall. Enter as guest → should go to **onboarding**, not a blank screen,
   in **light** mode, with **0%** stock and **no** restored data.
2. Finish onboarding → main screen, empty, light.
3. Sign in with Apple on a device that has a prior iCloud backup → you should get the
   **"Restore your Stocked data?"** prompt. Pick Start Fresh → stays empty. Pick Restore → your
   data comes back.
4. Settings → Erase All Data → reinstall/relaunch → still completely empty (the CloudKit copy is
   gone too).

## Note
This touches the launch/auth path, which I can't compile here — please build and run on device.
If anything routes oddly, the two files to look at first are `StockedApp.swift` (RootView routing)
and `LoginView.swift` (the sign-in handler).
