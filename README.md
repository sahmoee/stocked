# Stocked

Stocked is a native SwiftUI kitchen operating system for iPhone and iPad. It combines pantry inventory, receipt and barcode capture, groceries, recipes, meal planning, guided cooking, household collaboration, widgets, and internal quality assurance in one application.

## Highlights

- Inventory organized by storage zone, category, quantity, and expiration
- Receipt, barcode, document, and Live Text capture
- Recipe discovery, importing, filtering, source browsing, and offline caching
- Cook Now recommendations based on current inventory and household preferences
- Cook Later planning, reservations, grocery generation, and guided cooking
- Guest mode, Sign in with Apple, CloudKit backup, and household sharing
- Home-screen widgets and a share extension
- Internal QA tickets with screenshots, device context, automatic synchronization, fix explanations, verification, and refiling

## Requirements

- macOS with [Xcode](https://developer.apple.com/xcode/) and the iOS 26 SDK
- An Apple development team for device installation
- Optional: access to the [Unified Worker](https://github.com/sahmoee/UnifiedWorker) for household, AI, harvest-cache, and QA synchronization

Simulator use is optional. The supported command-line verification path targets a generic physical iOS device and does not create simulator data.

## Setup

```bash
git clone https://github.com/sahmoee/stocked.git
cd stocked
cp Secrets.example.xcconfig Secrets.xcconfig
open Stocked.xcodeproj
```

Fill only the values required for the services you intend to use. Never commit `Secrets.xcconfig`; the example file documents supported keys without containing credentials. Select the **Stocked** scheme, choose a connected device, configure signing, and run.

For command-line verification:

```bash
xcodebuild \
  -project Stocked.xcodeproj \
  -scheme Stocked \
  -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## Repository map

| Path | Purpose |
| --- | --- |
| [`Stocked/`](Stocked/) | Main application and QA implementation |
| [`StockedShareExtension/`](StockedShareExtension/) | Recipe/share intake extension |
| [`StockedWidgets/`](StockedWidgets/) | Home-screen widgets |
| [`StockedTests/`](StockedTests/) | Unit and regression tests |
| [`AGENTS.md`](AGENTS.md) | Mandatory workflow for coding agents |
| [`CROSS-PROJECT-SYNC.md`](CROSS-PROJECT-SYNC.md) | Shared app/Worker contract history |
| [`CHANGELOG.md`](CHANGELOG.md) | Build-level release history |

## QA and reports

Open **Settings → QA** in an internal build. Tickets automatically include the current screen, navigation breadcrumbs, runtime failures, environment details, and an optional screenshot. Saving or editing triggers synchronization immediately; offline work remains queued.

Ticket lifecycle:

1. **Open** — reported and awaiting work.
2. **Investigating** — actively diagnosed.
3. **Fixed** — includes a required “What was fixed” explanation and awaits device verification.
4. **Verified** — confirmed by the tester on the updated build.
5. **Refile** — reopens the same ticket with preserved history and fresh evidence.

Local agent intake is handled by `Documents/Reports/sync_qa_reports.py` in the multi-project workspace. See [`AGENTS.md`](AGENTS.md) for the mandatory workflow.

## Security and privacy

- Keep API keys and tokens in the ignored xcconfig file or provider secret store.
- Do not commit QA screenshots or user data.
- Review [`PRIVACY.md`](PRIVACY.md), [`SECURITY.md`](SECURITY.md), and [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) before distribution.
- CloudKit and Sign in with Apple behavior should follow [Apple privacy guidance](https://developer.apple.com/app-store/user-privacy-and-data-use/).

## Contributing

Read [`AGENTS.md`](AGENTS.md) and the unresolved QA inbox before changing code. Keep app/Worker contracts additive, add regression coverage, build for a generic physical device, update [`CHANGELOG.md`](CHANGELOG.md), and document cross-project effects in [`CROSS-PROJECT-SYNC.md`](CROSS-PROJECT-SYNC.md).

## License

See [`LICENSE.md`](LICENSE.md). App Store copy is maintained in [`APP_STORE_METADATA.md`](APP_STORE_METADATA.md).
