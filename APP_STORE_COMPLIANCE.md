# Stocked App Store compliance

Sources: see `/Users/key/Documents/StudioCompliance/APP_STORE_COMPLIANCE_TEMPLATE.md` for Apple references and the current Studio checklist.

- Platforms: iOS, watchOS, widgets/share extension
- Privacy manifest: Stocked/PrivacyInfo.xcprivacy; StockedShareExtension/PrivacyInfo.xcprivacy
- Privacy Policy URL: use the current Sowens Studios privacy policy URL before App Store submission.
- User Privacy Choices URL: optional unless this app has a live account/data-deletion page.
- Tracking: No, unless a future build adds cross-app/site tracking. Re-review before upload.
- Encryption/export compliance: Set in project/Info configuration; verify before upload.
- QA access code: `6352`
- QA suite/evidence: Stocked/QA*.swift, StockedTests, scripts, fastlane snapshots

## App Store Connect answers to confirm per build

- Data collection categories match the shipped features and any enabled server/API providers.
- Diagnostics/logs are declared if uploaded off-device.
- User content, photos, location, financial, health, contact, account, or purchase data are declared only if the current build actually collects them.
- Privacy manifest and App Store Connect privacy nutrition answers agree.
- Export compliance answer still matches current encryption use.

## Current limitation

This file is a compliance working record. Final App Store Connect answers must be checked against the exact archived build before submission.
