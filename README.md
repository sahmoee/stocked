# Stocked

Stocked is a native SwiftUI kitchen operating system for iPhone and iPad. It connects pantry inventory, shopping, recipes, meal planning, guided cooking, household collaboration, and food intelligence so a household can decide what to buy and cook from one source of truth.

Current app version: **4.13**. The project targets **iOS/iPadOS 26** and includes the main app, a share extension, widgets, and Live Activities.

## Product capabilities

### Inventory and shopping

- Pantry, refrigerator, freezer, and custom storage zones
- Quantity, freshness, expiration, low-stock, confidence, and “use first” tracking
- Receipt capture, barcode scanning, shelf scanning, camera/Live Text intake, and review-before-save
- Grocery lists, multi-store organization, purchase deduplication, price intelligence, and inventory reconciliation
- Household-aware merge and conflict handling, activity history, kitchen transfer, export, and restore tools

### Recipes and meal planning

- Local recipes, bundled starter meals, remote catalogs, web/share-sheet importing, and structured recipe cleanup
- Browse, search, filters, dietary profiles, source management, classification, caching, and image fallback
- Cook Now matching based on available ingredients, substitutions, exclusions, and household preferences
- Cook Later planning, ingredient reservations, grocery generation, thaw/prep planning, leftovers, and compounding prep
- Serving-size adjustment, “before you start” checks, guided steps, timers, Live Activities, and meal history

### Intelligence and system integration

- Optional Worker-backed receipt parsing, food normalization, recipe enrichment, recommendations, and daily briefs
- Spotlight indexing, notifications, widgets, deep links, share extension, network monitoring, and offline-friendly local state
- Five adaptive widgets for kitchen status, expiring food, groceries, today's meal, and recipes, plus a cooking timer Live Activity
- Sign in with Apple, CloudKit backup/sync, guest mode, household membership, and storage diagnostics
- Internal feature flags, diagnostics, health views, synchronized QA tickets, screenshots, verification, and refiling

## User experience

The main application uses an adaptive iPhone/iPad shell. Core areas expose the kitchen overview, inventory, grocery work, recipe discovery, cooking, and planning. A global drawer provides quick capture, search, activity, statistics, database/source management, account, household, notifications, storage, and kitchen-transfer tools.

The app is designed to remain useful when optional providers are unavailable. Network-backed results should fail gracefully, preserve local work, and clearly identify stale or pending data.

## Architecture

| Area | Key implementation |
| --- | --- |
| App lifecycle and navigation | [`Stocked/StockedApp.swift`](Stocked/StockedApp.swift), [`Stocked/MainTabView.swift`](Stocked/MainTabView.swift) |
| Domain state and persistence | [`Stocked/Models.swift`](Stocked/Models.swift), [`Stocked/AppSession.swift`](Stocked/AppSession.swift), store and CloudKit services under [`Stocked/`](Stocked/) |
| Inventory and groceries | [`Stocked/InventoryHubView.swift`](Stocked/InventoryHubView.swift), [`Stocked/InventoryView.swift`](Stocked/InventoryView.swift), [`Stocked/GroceryListView.swift`](Stocked/GroceryListView.swift) |
| Recipes and importing | [`Stocked/RecipeSupport.swift`](Stocked/RecipeSupport.swift), [`Stocked/RecipeCatalogImportView.swift`](Stocked/RecipeCatalogImportView.swift), [`StockedShareExtension/`](StockedShareExtension/) |
| Cooking and planning | [`Stocked/CookHubView.swift`](Stocked/CookHubView.swift), [`Stocked/CookLaterWorkspaceView.swift`](Stocked/CookLaterWorkspaceView.swift), [`Stocked/ReservationEngine.swift`](Stocked/ReservationEngine.swift) |
| Remote services | [`Stocked/StockedWorkerClient.swift`](Stocked/StockedWorkerClient.swift), [`Stocked/RemoteContentClient.swift`](Stocked/RemoteContentClient.swift), [Unified Worker](https://github.com/sahmoee/UnifiedWorker) |
| Extensions | [`StockedWidgets/`](StockedWidgets/), [`StockedShareExtension/`](StockedShareExtension/) |
| Tests | [`StockedTests/`](StockedTests/) |

User data is local-first. CloudKit and the Unified Worker add cross-device, household, AI, catalog, and reporting functions; they are not substitutes for local persistence.

## Requirements

- macOS with [Xcode](https://developer.apple.com/xcode/) and the iOS 26 SDK
- An Apple development team and matching capabilities for installation on a physical device
- Optional provider accounts for recipe/food data
- Optional access to the [Unified Worker](https://github.com/sahmoee/UnifiedWorker)

Simulator use is not required. The standard command-line verification path targets a generic physical iOS device and avoids creating simulator data on the development Mac.

## Setup

```bash
git clone https://github.com/sahmoee/stocked.git
cd stocked
cp Secrets.example.xcconfig Secrets.xcconfig
open Stocked.xcodeproj
```

In Xcode:

1. Select the **Stocked** scheme.
2. Assign the correct development team to the app, widget, and share-extension targets.
3. Confirm required iCloud, Sign in with Apple, App Groups, notifications, and associated capabilities for the selected bundle identifiers.
4. Choose a connected iPhone or iPad and run.

### Configuration

[`Secrets.example.xcconfig`](Secrets.example.xcconfig) documents the supported local values:

| Setting | Purpose | Required? |
| --- | --- | --- |
| `SPOONACULAR_API_KEY` | Optional recipe provider | No |
| `EDAMAM_APP_ID`, `EDAMAM_APP_KEY` | Optional recipe provider | No |
| `USDA_API_KEY` | Optional nutrition/food lookup | No |
| `MEALDB_BASE_URL` | MealDB endpoint | Has a safe default |
| `NETWORK_TIMEOUT_REQUEST` | Request timeout | Has a default |
| `STOCKED_ENV` | Runtime environment label | Has a default |
| `HOMEBASE_URL`, `HOMEBASE_API_KEY` | Optional private development server | No |

The app’s AI traffic is routed through the Worker; provider secrets must not ship in the application. Keep `Secrets.xcconfig` ignored and use Cloudflare secrets for server-side credentials. See the Worker’s [`SECRETS.md`](https://github.com/sahmoee/UnifiedWorker/blob/main/SECRETS.md).

## Build and test

Generic device build:

```bash
xcodebuild \
  -project Stocked.xcodeproj \
  -scheme Stocked \
  -destination 'generic/platform=iOS' \
  -skipPackagePluginValidation \
  CODE_SIGNING_ALLOWED=NO \
  clean build
```

Unit tests live in [`StockedTests/`](StockedTests/) and cover core logic including household merging, reservations, receipt processing, adaptive cooking, feature behavior, Codable compatibility, and sync conflicts. Run tests from Xcode on a suitable device/simulator or in hosted CI. [`swift6_concurrency_guard.sh`](swift6_concurrency_guard.sh) performs the repository’s concurrency guard.

## Backend and data flows

Production requests are served by `https://api.sowensstudios.com` through the [Unified Worker](https://github.com/sahmoee/UnifiedWorker). Stocked uses it for selected AI/normalization operations, household collaboration, product/crowd data, remote content, daily briefs, rate limiting, and QA synchronization.

When changing an endpoint:

1. Keep existing request/response fields backward compatible.
2. Update the Worker and app consumers together.
3. Add regression coverage for decoding defaults and offline/error behavior.
4. Record cross-project implications in [`CROSS-PROJECT-SYNC.md`](CROSS-PROJECT-SYNC.md).

## QA and diagnostics

Internal builds expose **Settings → QA**. Tickets include screen/navigation context, runtime failures, environment details, optional screenshots, local-first persistence, and automatic retry. The lifecycle is **Open → Investigating → Fixed → Verified**, with a required “What was fixed” explanation and a history-preserving **Refile** action.

Report synchronization is an internal development operation and is intentionally not documented in the public repository.

## Release process

- Update [`CHANGELOG.md`](CHANGELOG.md) and user-facing [`Stocked/AppChangelog.swift`](Stocked/AppChangelog.swift).
- Confirm version/build numbers for the app and extensions.
- Run unit checks and a generic device build; then test on a real iPhone/iPad.
- Validate widgets, share intake, notifications, CloudKit/sign-in, offline behavior, and migrations.
- Review [`APP_STORE_METADATA.md`](APP_STORE_METADATA.md), [`PRIVACY.md`](PRIVACY.md), privacy manifests, and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
- Archive and distribute through Xcode/TestFlight. TestFlight is a distribution channel; Xcode’s generic-device build is the local CI-style compile check.

## Troubleshooting

- **Missing `Secrets.xcconfig`:** copy the example file; placeholder values are sufficient for compile-only builds.
- **Signing/capability errors:** verify the team, bundle identifiers, App Group, iCloud container, and extension profiles.
- **Provider requests fail:** confirm the provider is configured, inspect network diagnostics, and verify Worker health at [`/_unified/health`](https://api.sowensstudios.com/_unified/health).
- **Data is not syncing:** check authentication, CloudKit availability, household membership, network state, conflict logs, and storage health before deleting local data.
- **QA reports are absent locally:** run the shared Reports sync and verify the Worker QA key; do not manually copy screenshots into Git.

## Security, privacy, and legal

Never commit credentials, private exports, receipt images, household data, or QA screenshots. Use Keychain/xcconfig for client configuration and the provider’s secret store for server credentials. Review [`SECURITY.md`](SECURITY.md), [`PRIVACY.md`](PRIVACY.md), [`SUPPORT.md`](SUPPORT.md), and Apple’s [privacy guidance](https://developer.apple.com/app-store/user-privacy-and-data-use/).

## Contributing and project resources

- [`CONTRIBUTING.md`](CONTRIBUTING.md) — contribution process
- [`CHANGELOG.md`](CHANGELOG.md) — release history
- [`APP_STORE_METADATA.md`](APP_STORE_METADATA.md) — store-facing copy
- [`LICENSE.md`](LICENSE.md) — license

Preserve backward-compatible persisted data and network contracts, add tests for behavioral changes, and document any migration or cross-project dependency.
