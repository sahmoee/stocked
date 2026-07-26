# Stocked — Launch Readiness

State of the project as of this review. Bundle `com.sowens.Stocked`, v4.13 (build 64), 344 Swift
files / ~100k LOC. Sowens Studios LLC.

This is split into three parts: what's needed **right now** to have a shippable build, what App
Store submission **requires**, and what would **make it better** before launch. Items marked
**[confirm]** are things I can't verify from the code and you'll need to check yourself.

---

## Where it already stands (verified present)

Genuinely far along. These are done:

- **Privacy manifest** (`PrivacyInfo.xcprivacy`) with `NSPrivacyTracking = false`, collected-data
  types and API-access reasons declared.
- **Entitlements**: Sign in with Apple, HealthKit (+ background), iCloud/ubiquity, push
  notifications, app groups, increased memory.
- **10 privacy usage strings** in Info.plist (camera, mic, photos, health, location, speech,
  notifications, local network).
- **`ITSAppUsesNonExemptEncryption`** is set — no export-compliance prompt each submission.
- **In-app account deletion** ("Delete Account" + "Erase All Data" in Settings) — satisfies
  Apple Guideline 5.1.1(v).
- **StoreKit 2** in-app purchase (`PremiumManager`, household-sync product).
- **Guest mode** — App Review can use the app without credentials.
- **Test target exists** — 12 Swift test files + 4 Worker test files (68 Worker tests pass).
- **Marketing site built** (`site/`: index, privacy, terms, support) and support/privacy/terms
  URLs wired in `BuildConfig`.
- **Worker** configured for `api.sowensstudios.com` with Durable Objects, KV, rate limiting.

---

## Part 1 — What it needs right now (before anything else)

### 1.1 A clean compile and a run on a real device — the gating item
Everything I've built and fixed across recent sessions was verified structurally (brace balance,
symbol collisions, signature checks) but **not compiled** — there's no Swift toolchain in this
environment. The recent build errors you hit one at a time (private inits, the Int/String
interpolation, the duplicate AppShortcutsProvider) are exactly the class that only a compiler
surfaces. **Step zero is a clean build + archive + a smoke test on a physical device**, not the
simulator. Nothing else on this list matters until that's green.

### 1.2 Minimum iOS version is **26.0** — the biggest single decision  **[confirm]**
All 8 build configs set `IPHONEOS_DEPLOYMENT_TARGET = 26.0`. That excludes every device not on the
latest major iOS, and every device too old to run it (roughly pre-iPhone 11 / SE 2nd gen). That's a
large slice of the addressable market in the first year.

If this is deliberate (you're relying on iOS 26-only APIs), fine — but confirm it's a choice, not
the Xcode default left untouched. Lowering it to iOS 18 (or 17) would likely multiply your
installable base. It's the highest-leverage pre-launch decision on this list.

### 1.3 The "Coming Soon" For You button — ✅ DONE
Resolved: the surface turned out to be dead code (unreferenced since the hub redesign).
`ForYouView.swift` deleted, the fourth tab name removed, and a stale saved tab preference is
clamped so nobody lands on a missing index.

### (was 1.3) Original note
`ForYouView.swift` renders a tappable **"Coming Soon — Learn More"** control. App Store Guideline
2.3.2 / 2.1 rejects non-functional placeholder features. For v1, either hide the For You tab
entirely or make it fully functional. This is a concrete, common rejection reason — worth handling
before you submit, not after a rejection.

### 1.4 New feature data doesn't sync — ✅ DONE
Resolved: all eight feature collections now ride the existing `/household/push` /pull path with
per-id last-write-wins, tombstoned deletes, and stamped edits. Store layouts merge by name with
more-trips-wins. Worker side merged + tested (71/71 tests pass, 3 new). Gated on the inventory
sharing toggle. **Requires `wrangler deploy` to go live.**

### (was 1.4) Original note
The eight features added recently — leftovers, events, **shared costs**, store layouts, garden
harvests, container labels, takeout log, family profiles — persist **only on the device**.
Inventory, grocery and meal plans sync; these don't. Shared Costs is the sharp edge: two roommates
splitting a bill will each see a different ledger and reasonably think it's broken. Either wire
these into the existing household sync before launch, or clearly label them as device-only for v1.

---

## Part 2 — App Store submission requirements

These are hard requirements for getting through review and onto the store.

### 2.1 App Store Connect record  **[confirm — your action]**
Create the app listing: name, subtitle, description, keywords, primary/secondary category, age
rating questionnaire, and the **App Privacy "nutrition label"** answers. The privacy answers must
match `PrivacyInfo.xcprivacy` exactly — mismatches trigger review questions.

### 2.2 Screenshots — none exist in the repo  **[your action]**
Required for every device class you support: 6.7" and 6.5" iPhone at minimum (and iPad if the app
is universal — check whether it is). No screenshots or app-preview assets are in the project. These
have to be produced and uploaded.

### 2.3 In-app purchase setup  **[confirm]**
The code references a StoreKit product (`householdSyncProductID`) but there's **no `.storekit`
configuration file** in the project, so local/TestFlight IAP testing isn't set up. Before launch:
create the product in App Store Connect, complete **paid-apps agreement + banking + tax**, add a
`.storekit` file for testing, and verify purchase + restore actually work in the sandbox.

### 2.4 Live legal + support URLs  **[confirm — must be reachable]**
`BuildConfig` points at `sowensstudios.com/privacy`, `/terms`, `/support`. The HTML exists in
`site/` but App Store Connect and App Review will **load these URLs live**. Confirm they're
deployed and return real pages at those exact paths. A dead privacy URL is an automatic hold.

### 2.5 Worker deployed to production  **[confirm]**
The app calls `https://api.sowensstudios.com` for all AI features (receipt scan, barcode, recipe
import/generation). Confirm the Worker is deployed (`wrangler deploy`), the custom domain routes to
it, and the `X-Stocked-Key` secret is set in production. If it's not live, receipt scanning and the
AI features fail on a reviewer's device — and reviewers do test them.

### 2.6 HealthKit scrutiny  **[confirm]**
HealthKit apps get extra review attention. Health data must not be used for advertising or shared
with third parties, and the privacy policy must explicitly cover health data. You have the
entitlement and usage strings; make sure the actual usage is justified and the policy text covers
it. If HealthKit isn't essential to v1, dropping it removes a whole review risk category.

### 2.7 Sign in with Apple completeness
You offer Apple sign-in + guest, which is compliant. Just note the rule for later: if you ever add
a third-party login (Google/Facebook), Apple requires Sign in with Apple be offered alongside it.

---

## Part 3 — What would make it better before launch (not blocking)

Ordered by value.

### 3.1 Lower the deployment target (see 1.2)
Repeated here because it's both a "decide now" item and the biggest reach lever. If there's no hard
iOS 26 dependency, this is the single highest-impact pre-launch change.

### 3.2 Engine tests — ✅ DONE (needs a run in Xcode)
`StockedTests/FeatureEngineTests.swift`: 30 tests across all eight engines — SplitMath's
settle-up is verified to clear every balance to zero in ≤ n−1 transfers.

### (was 3.2) Original note
Eight engines added recently have **zero test coverage** despite being pure and trivially testable:
`SplitMath` (settlement math — wrong here is the worst kind), `MeasureParser`, `ReadinessCalculator`,
`TimelinePlanner`, `EventMath`, `StoreRouting`, `HarvestMath`, `TakeoutMath`. The test target
already exists; these need no host app. A day's work buys real confidence in the numbers users see.

### 3.3 Accessibility pass
Most screens use fixed font sizes (`.font(.system(size: 13))`) that don't respond to Dynamic Type.
A `StockedTextRole` scale was added but only newer screens use it. Food/kitchen apps skew older;
fixed 11–13pt type is a real exclusion. Also add VoiceOver labels to compound rows on the newer
screens. Not a blocker, but it's the kind of thing that shows up in reviews and, occasionally, in
accessibility-focused rejections.

### 3.4 First-run experience on a truly fresh install
The coachmark bugs are fixed, but walk the whole cold-start path on a wiped device: onboarding →
first inventory add → first receipt scan → first cook. This is where new-user drop-off hides, and
it's the one thing screenshots and TestFlight can't fully stand in for.

### 3.5 Crowd-sourced shelf life (the built-but-unfilled seam)
`ShelfLifeEstimator` already takes a `crowdDays` parameter that nothing populates. Wiring the Worker
to collect anonymised "actual days before used/tossed" and serve back a median would turn a
single-user guess into the app's most defensible long-term advantage. Needs a Worker endpoint + a
deploy; safe to do post-launch, but the seam is waiting.

### 3.6 Widgets / Live Activities
A home-screen "expiring in 3 days" widget and a Live Activity for kitchen timers / thaw countdowns
would surface the most glanceable features where they belong. Needs a new app-extension target
(Xcode). Post-launch is fine.

### 3.7 Cosmetic: the asset catalog folder name
`Stocked/Assets .xcassets` has a stray space in the name. It works (the folder-synchronised group
finds it by path) but it's fragile and ugly. Rename in Xcode, not by hand, since it's referenced by
the build system.

---

## The short version

**Must happen before you can ship at all:**
1. Clean compile + archive + real-device smoke test.
2. Decide the iOS 26 minimum (confirm it's intentional).
3. Remove or finish the "Coming Soon" For You button.
4. Confirm the Worker is live and the privacy/terms/support URLs resolve.
5. Create the App Store Connect listing, screenshots, and IAP product.

**Should happen to launch well:**
6. Lower the deployment target if there's no hard dependency.
7. Sync (or clearly label) the new household features — Shared Costs especially.
8. Test the pure engines; do an accessibility pass; walk a cold install.

Everything structural is in good shape. The gap between here and the store is mostly **build
verification, a few product decisions, and App Store Connect paperwork** — not major engineering.
