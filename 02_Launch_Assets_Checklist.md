# App Store launch assets checklist (#20)

Code is only half of a launch. This is the listing/asset work, in the order App Store Connect asks for it.

## Screenshots (required)
Apple requires **6.9" (iPhone 16 Pro Max)** and **6.5"** sizes; a 5.5" set is optional but widens device support. Aim for 5–8 screenshots.
Suggested story, one screen each:
1. Home dashboard — stock %, expiring, tonight's meal (the "peace of mind" hook).
2. Inventory with expiry coloring — the core value.
3. Receipt scan → items added — the magic moment.
4. Cook Now / Surprise Me — a real recipe from what's in stock.
5. Money Saved dashboard (new) — the retention number.
6. Household sync — two devices, same kitchen.
7. Kitchen Toolbox grid — breadth.

Add a one-line caption band per shot. Keep light-mode; ensure Dynamic Type at default.

## App preview video (optional, high-impact)
15–30s screen recording: scan a receipt → item lands → cook a suggestion → mark used. Record on-device at the exact required resolution.

## Text metadata
- **Name (30 char):** e.g. "Stocked: Kitchen & Pantry".
- **Subtitle (30 char):** e.g. "Track food, waste less".
- **Keywords (100 char):** pantry, grocery, inventory, expiry, food waste, meal plan, recipes, fridge, barcode, receipt.
- **Description:** lead with the outcome (less waste, always know what you have), then features. Avoid competitor names.
- **Promotional text (170 char):** updatable without review — use for seasonal or new-feature callouts.
- **What's New:** per-version notes.

## Compliance / review prerequisites
- **Privacy "nutrition label"** in App Store Connect must match `PrivacyInfo.xcprivacy`. You collect on-device data + CloudKit; declare accordingly. Confirm no tracking.
- **Sign in with Apple** present ✔ (guideline 5.1.1 also needs an account-deletion path — `deleteAccount()` exists ✔).
- **Privacy Policy + Terms URLs** — already linked on the login screen (`BuildConfig.privacyURL/termsURL`); make sure both resolve.
- **HealthKit** entitlement is present — App Review will ask why. Have a clear in-app explanation and only request what you use.
- **IAP** — `com.stocked.householdsync` must exist and be "Ready to Submit" in App Store Connect with the *same* product ID (note the namespace differs from the bundle).
- **Demo account / notes** for reviewers if any feature is gated.
- **Support URL** and marketing URL (the Netlify site).
- **Age rating** questionnaire.
- **Export compliance** — standard HTTPS only → usually "no" to proprietary encryption (confirm).

## Pre-submit smoke test (device)
Cold install → onboarding → add items → receipt scan → cook → household sync on a second device → notifications fire → widgets populate → universal link opens the app.
