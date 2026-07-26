# FR-02 / FR-03 fixes — onboarding + Apple sign-in

## FR-02 — Guest skip onboarding → blank screen until relaunch
**Cause:** the routing had a dead branch — `isLoggedIn && isCheckingForExistingAccount → SplashView()`.
That flag was only ever set by the launch iCloud auto-restore (which I removed in FR-01). With the
restore gone, the branch could only show a bare splash with no way forward — exactly your "skip →
blank until I reopen." (On relaunch, the flag was false and onboarding had completed, so it worked.)

**Fix:** removed the branch. A logged-in user whose onboarding isn't finished now always routes to
the quiz. Skipping the quiz flips `quizCompleted` and swaps to the main app, no blank.

## FR-03 (name) — Apple sign-in showed "Chef" instead of "Jessie"
**Cause:** Apple only sends your name on the **very first** authorization of an Apple ID. On every
later sign-in it sends nil. The app cached the name in `AppleProfileVault`, but that vault was
**UserDefaults-backed** — so a fresh install or "Erase All Data" wiped it. On a reinstalled app,
Apple sends nil AND the cache is gone → the app falls back to "Chef."

**Fix:** the vault is now **Keychain-backed**. Keychain survives app deletion and the UserDefaults
wipe, so a returning Apple user keeps their real name. First-time sign-ins capture it once and it
persists across every future reinstall. A one-time migration moves any existing UserDefaults vault
into the Keychain on launch, and full **Delete Account** still forgets it.

> **Important for your retest:** your Apple ID already authorized Stocked in an earlier build, before
> the Keychain vault existed — so there is no stored name anywhere, and Apple will keep sending nil.
> To see "Jessie" again you must make iOS treat it as a first-time sign-in:
> **Settings ▸ [your name] ▸ Sign in with Apple ▸ Stocked ▸ Stop Using Apple ID**, then sign in
> again. From then on the name persists. (For real new users this is automatic — they authorize
> once and the name sticks.)
>
> If you'd rather never depend on Apple for this, I can add a **name-entry step** when Apple returns
> no name, so the field is never "Chef." Say the word.

## FR-03 (onboarding) — no quiz on Apple sign-in; should show, with a restore option
**Cause:** `signIn()` force-set `quizCompleted = true`, so Apple users skipped onboarding entirely.

**Fix:** removed that. Now:
- **Sign in with Apple → the onboarding quiz is shown** (like a guest).
- If that Apple ID has an **iCloud backup**, the restore prompt appears (from FR-01): **"Restore
  your previous setup"** or **"Start Fresh."** Restore brings back inventory, settings, and your
  completed onboarding (skipping the quiz); Start Fresh takes the quiz.
- **Guests** already re-onboard every time their data was wiped — unchanged, and now the skip path
  doesn't blank.

The old reason for force-completing (finishing the quiz used to downgrade the account to
guest/"Chef") is already guarded in `enterKitchen`, so onboarding-after-sign-in is safe.

## Files changed
- `AppleProfileVault.swift` — rewritten to store the Apple name in the Keychain (survives
  reinstall/erase) with a one-time UserDefaults→Keychain migration. Same public API.
- `AppSession.swift` — `signIn` no longer force-completes onboarding; runs the vault migration at init.
- `StockedApp.swift` — removed the dead `isCheckingForExistingAccount` splash branch; restore-prompt
  copy now says it restores your previous setup + onboarding.
- `KitchenTransferManager.swift` — a successful restore now marks onboarding complete (so the
  consent "Restore" actually lands you in the app).

## Retest (rebuild first — launch/auth path, can't compile here)
- **FR-02:** guest → enter name → skip onboarding → should land on the main app (no blank).
- **FR-03 name:** revoke Stocked (steps above) → Sign in with Apple → greeting shows your Apple
  first name, not "Chef."
- **FR-03 onboarding:** Sign in with Apple with no backup → onboarding quiz appears. With a backup →
  "Restore your previous setup / Start Fresh" prompt; Restore skips the quiz, Start Fresh takes it.
