<!-- PROJECT-KNOWLEDGE managed; do not edit this export -->
> Maintained in ProjectKnowledge: `projects/stocked/documents/README.md`. This is a generated portable read-only export. Update the central source with `project-knowledge put`; use `project-knowledge publish` to refresh exports. Relative links and code paths below refer to this original project location.

# Stocked

Stocked is a native kitchen app for iPhone, iPad and Apple Watch. Track food, manage groceries, save recipes, plan meals and cook with the ingredients you already have.

## Features

- **Inventory:** storage zones, quantities, expiration dates, low-stock reminders and reviewed receipt, barcode and camera imports.
- **Groceries:** shared lists, store grouping, purchase review and price comparisons.
- **Recipes:** personal collections, website and screenshot imports, recipe files, discovery and ingredient matching.
- **Cooking:** meal planning, ingredient reservations, guided steps, timers, leftovers and meal history.
- **Households:** invite codes, member roles, food preferences, activity and shared kitchen data.
- **Apple integrations:** widgets, Live Activities, share extension, Spotlight, notifications and a Watch companion.

Local records remain available offline. Optional network services support household synchronization, public recipe discovery and food intelligence. Results that need a connection retain their error and freshness state.

## Design

Pastel and Tan palettes each support light and dark appearance. Tan retains the original charcoal, tan and gold colors. Shared typography, cards, search fields and navigation controls support Dynamic Type. Reduce Motion, Reduce Transparency and Increase Contrast use the corresponding accessibility fallbacks.

## Requirements

- macOS with Xcode and the iOS 26 SDK
- An Apple development team with the capabilities needed for physical-device installation
- Optional recipe provider configuration and access to the [Unified Worker](https://github.com/sahmoee/UnifiedWorker)

## Get started

```sh
git clone https://github.com/sahmoee/stocked.git
cd stocked
cp Secrets.example.xcconfig Secrets.xcconfig
open Stocked.xcodeproj
```

Select the **Stocked** shared scheme. Set your development team for the app, share extension, widgets and Watch targets. Configure your own bundle identifiers, App Groups, iCloud containers, Sign in with Apple and associated domains before installing on a device. Keep the related target identifiers and capabilities consistent.

`Secrets.example.xcconfig` lists optional recipe-provider and development-server settings. Leave unused providers unconfigured. Store real values in ignored local configuration; never commit them. Hosted intelligence requests use the Worker, whose provider credentials belong in the server's secret store.

## Build and validate

Compile the app and embedded targets without device signing:

```sh
xcodebuild \
  -project Stocked.xcodeproj \
  -scheme Stocked \
  -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Use `-derivedDataPath /path/to/build-cache` when build output should live on another disk. The shared scheme reserves the build number; do not build individual targets or manually increment it in wrappers.

Useful local checks:

```sh
python3 scripts/check-household-features.py /path/to/check-output
python3 scripts/quality.py
```

The formatting check requires the tools listed in `Brewfile`. Unit tests are in `StockedTests`; select an available test destination in Xcode. Compilation, logic checks and source-level contrast checks do not replace testing rendered screens, VoiceOver, sync, notifications or migrations on a device.

## Code map

| Area | Location |
| --- | --- |
| App and navigation | `Stocked/StockedApp.swift`, `Stocked/MainTabView.swift` |
| Theme and controls | `Stocked/DesignTokens.swift`, `Stocked/PastelDesign.swift`, `Stocked/DesignSystem.swift`, `Stocked/GlassUI.swift` |
| State and persistence | `Stocked/Models.swift`, `Stocked/AppSession.swift`, `Stocked/GuestDataStore.swift` |
| Household sharing | `Stocked/HouseholdSync.swift`, `Stocked/HouseholdViews.swift` |
| Recipe intake | `Stocked/RecipeCreateOptions.swift`, `Stocked/RecipeCatalogImportView.swift` |
| Cooking and planning | `Stocked/CookHubView.swift`, `Stocked/CookLaterWorkspaceView.swift`, `Stocked/ReservationEngine.swift` |
| Network services | `Stocked/StockedWorkerClient.swift`, `Stocked/RemoteContentClient.swift` |
| Extensions | `StockedShareExtension/`, `StockedWidgets/`, `StockedWatch/` |
| Tests and release tools | `StockedTests/`, `scripts/`, `fastlane/` |

## Making changes

Check the working tree and remote branches before editing. Keep changes focused, preserve existing local work and add meaningful regression coverage for behavior changes. Stored records, household JSON, URLs and extension payloads are compatibility surfaces; migrations must preserve existing data and be safe to retry.

For an API change, update its owning Worker and affected consumers together. Keep older clients working, test offline and failure paths, and review deployment order. The [Unified Worker](https://github.com/sahmoee/UnifiedWorker) owns hosted service contracts.

## Release checks

Before archiving, review the app and extension versions, tests, device behavior and `Stocked/AppChangelog.swift`. Verify widgets, share intake, notifications, sign-in, household synchronization, offline use and data migrations. Review [store metadata](APP_STORE_METADATA.md), [compliance](APP_STORE_COMPLIANCE.md), [privacy](PRIVACY.md) and [third-party notices](THIRD_PARTY_NOTICES.md).

Archive and upload through Xcode or the repository's release tooling. A successful compile is not evidence of a completed TestFlight upload or device acceptance.

## Troubleshooting

- **Build configuration:** copy the example configuration and verify the selected team, target identifiers and capabilities.
- **Provider failures:** confirm the optional provider is configured and inspect the relevant diagnostic error.
- **Sync failures:** check household membership, authentication, connectivity and storage health before changing local data.
- **Asset errors:** fully download the checkout before building if it is stored in iCloud Drive or another file-provider folder.

## Security and support

Keep credentials, receipt images, household records, private exports and QA captures out of Git. Report vulnerabilities privately using [SECURITY.md](SECURITY.md). See [support](SUPPORT.md), [contribution guidance](CONTRIBUTING.md) and [license](LICENSE.md).
