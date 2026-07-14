# Changelog

## Build 54 — 2026-07-14 10:11 UTC

### Fixed
- **Version drift**: all targets pinned to CURRENT_PROJECT_VERSION = 54 (was 53 on disk vs 54 in Xcode UI).
- **Deployment target mismatch**: main app was 26.0 (fixed to match) — unified all targets and project default to IPHONEOS_DEPLOYMENT_TARGET = 26.0.
- **Stale BuildConfig fallbacks**: fallbackBuildNumber 42 -> 54, fallbackVersion "4.22" -> "4.13".

### Unchanged
- MARKETING_VERSION remains 4.13 (already consistent across targets).
