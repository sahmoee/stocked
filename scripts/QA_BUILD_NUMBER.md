# Automatic QA build numbers

Stocked owns this script; these five QA-enabled Xcode repositories vendor the same code:
Stocked, Atlas, Nova (iOS and tvOS), The SESH, and ReelPromo-iOS. Mac-only projects are excluded.

- Use a checked-in shared scheme for Xcode Run/Build/Test/Profile/Archive or `xcodebuild -scheme …`.
- A pre-action clears its DerivedData reservation, then reserves one integer above every project
  configuration and the ignored local `.qa-build/number` high-water mark. A file lock protects
  concurrent reservations; different DerivedData directories keep separate captured numbers.
- Every app, extension and test target stamps its generated Info.plist with that reservation after
  plist generation and before signing. Xcode caches settings before pre-actions, so updating only
  the project would otherwise leave this build with yesterday's number.
- The plist is a declared mutable input/output plus a completion marker. Script sandboxing stays
  enabled. Scripts perform no network requests and do not alter app sandboxing or entitlements.
- Public `MARKETING_VERSION` values are never edited. Change them manually in Xcode, keeping each
  shipping app and its extensions aligned. ReelPromo now reads that setting instead of a literal.
- TestFlight wrappers rely on the scheme, read the actual archive number, and reject any marketing
  version change before upload. Running the wrapper still uploads; do not run it merely to validate.
- Missing/invalid reservations fail instead of silently shipping an old number. Failed builds may
  consume numbers; gaps are intentional. Commit project/script/scheme changes together.
- Do not invoke a direct `-target` build without the shared scheme's reservation. Do not manually
  edit the ignored counter. New targets require the same phase and new schemes require the pre-action.

## Verification

Run `/usr/bin/python3 scripts/test_qa_build_number.py` for native fixture tests: version preservation,
dotted-build migration, concurrent reservations, restoring an older checkout, separate DerivedData,
missing-reservation failure, and stamping only CFBundleVersion. No simulator or upload is involved.

Device-target builds have verified all five apps and embedded extensions. A local unsigned ReelPromo
archive verifies that archive metadata and the app's CFBundleVersion agree while version stays 1.0.
Unsigned validation does not verify App Store signing/upload. Simulator builds/tests remain paused
unless the user explicitly approves them.

Xcode 27 may emit an intermediate embedded-version warning while it compares an extension against
its parent's pre-stamp plist. Final bundle values match; verify the final app and each PlugIns/*.appex
Info.plist (and the archive Info.plist), not this intermediate value. Existing compiler warnings are
not automatically cleared or reported as new product defects by this build-number change.
