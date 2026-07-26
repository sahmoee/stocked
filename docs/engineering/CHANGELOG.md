# Changelog

## Build 54 — 2026-07-14 10:23 UTC

### Fixed
- **Build-number leak (root cause)**: `Stocked/Info.plist` hardcoded `CFBundleVersion = 50` with `GENERATE_INFOPLIST_FILE = NO`, so archives always shipped build 50 no matter the pbxproj. Changed to `$(CURRENT_PROJECT_VERSION)` so the build number now tracks Build Settings (mirroring how `CFBundleShortVersionString` already uses `$(MARKETING_VERSION)`).
- **Same-archive mismatch**: extensions used `GENERATE_INFOPLIST_FILE = YES` (read pbxproj = 54) while the app read the literal 50. Now unified.
- **Version drift**: `CURRENT_PROJECT_VERSION` = 54 across all six config blocks.
- **Deployment target**: unified to `IPHONEOS_DEPLOYMENT_TARGET = 26.0`.
- **Stale fallbacks**: `BuildConfig.swift` build 42 to 54, version 4.22 to 4.13.

### Note
Build 53 is already uploaded to Apple; 54 is the correct next number. Re-archive after applying — the prior Jul 14 (50) archives cannot be distributed.
