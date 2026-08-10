# Stocked

A SwiftUI kitchen operating system for iPhone and iPad: inventory, groceries, receipts,
recipes, meal planning, household sync, cooking tools, and widgets in one app.

Supports guest use and Sign in with Apple, private iCloud/CloudKit data, an App Group
for widgets and sharing, and an optional Cloudflare Worker for authenticated household
and intelligence features.

## Features

- Pantry inventory with barcode and receipt scanning
- Recipe vault, meal planning, and grocery lists
- Household sync and sharing
- Home-screen widgets and a share extension
- Optional AI-assisted features via a user-controlled Worker

## Requirements

- Xcode 16 or later
- iOS 26 SDK

## Getting started

```bash
git clone https://github.com/sahmoee/stocked.git
cd stocked
cp Secrets.example.xcconfig Secrets.xcconfig   # fill in your values
open Stocked.xcodeproj
```

Select the **Stocked** scheme and run. Never commit production secrets — configure
provider and Worker credentials through the xcconfig pipeline.

## Project structure

- `Stocked/` — app sources
- `StockedShareExtension/` — share extension
- `StockedWidgets/` — widgets
- `StockedTests/` — unit tests

## License

See [LICENSE.md](LICENSE.md). App Store details in [APP_STORE_METADATA.md](APP_STORE_METADATA.md);
privacy in [PRIVACY.md](PRIVACY.md); third-party notices in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
