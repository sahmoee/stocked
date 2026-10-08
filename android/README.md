# Stocked for Android

Native Kotlin/Compose edition for Android 8.0 (API 26) and newer. Includes offline inventory, groceries, recipes and meal plans, reviewed backup imports, recipe file/web imports, food/receipt image recognition and household sync. This edition is still being validated and does not yet match every iOS feature.

## Install

Use a signed release APK supplied by the project owner. Open it on Android and permit installation from that file manager when prompted. Updates require the same application ID and signing key; export a backup before replacing a differently signed build. No paid app store account is needed for direct APK distribution.

On a Steam Deck with Waydroid already initialized:

```sh
waydroid app install /path/to/Stocked.apk
waydroid app launch com.sowens.stocked
```

Waydroid setup depends on SteamOS kernel/container support. APK installation alone does not install Waydroid or guarantee its networking, image picker or notification support.

## Develop and check

Install JDK 17 and Android SDK platform 36. Android Studio is optional. SDK and build tools are free; the SDK license must be accepted locally. Set `ANDROID_HOME` or an ignored `local.properties` containing `sdk.dir`.

```sh
cd android
./gradlew :app:testDebugUnitTest :app:lintDebug :app:assembleDebug :app:assembleRelease
```

The committed Gradle wrapper checks the distribution checksum. GitHub Actions runs unit tests, lint and compilation with cached dependencies and uploads reports. Release compilation is unsigned when no signing configuration is supplied. CI does not generate or publish private signing keys or signed application files.

For a signed release, put all four values in ignored `android/signing.properties`:

```properties
storeFile=/absolute/private/path/stocked-release.jks
storePassword=YOUR_LOCAL_PASSWORD
keyAlias=stocked
keyPassword=YOUR_LOCAL_PASSWORD
```

Alternatively set `STOCKED_ANDROID_KEYSTORE`, `STOCKED_ANDROID_STORE_PASSWORD`, `STOCKED_ANDROID_KEY_ALIAS` and `STOCKED_ANDROID_KEY_PASSWORD` in the local build environment. Environment values take precedence. Never commit keys or passwords. Preserve the signing key securely: it is required for compatible updates.

## Data and privacy

Kitchen changes are committed atomically to internal app storage. Export readable JSON from Settings for recovery or compatible iOS imports. Unknown imported fields are preserved where supported. Household credentials and the private sync journal are excluded from exported backups; credentials are encrypted using this device's Android Keystore and cannot be transferred by restoring kitchen JSON.

Joining a household sends shared kitchen data to the configured Stocked HTTPS service. Offline changes remain local until synced. Network-constrained retries and background checks use Android WorkManager; Android may delay the approximately 15-minute periodic checks. Tap **Sync now** for a manual check. There is no WebSocket live-update connection in this edition. Conflict and membership errors preserve local records rather than silently replacing them.

Recipe website imports contact the selected site. Optional barcode product-name lookup contacts Open Food Facts; its database is available under ODbL, with individual contents under DbCL ([terms](https://world.openfoodfacts.org/terms-of-use)). Product names are reviewed before saving. Image/barcode recognition uses bundled ML Kit models; review recognition results before saving. File exports can contain personal kitchen data; share them deliberately. App uninstall or clearing storage removes local data and device credentials.

## Current limits

No Google Play listing or store acceptance is claimed. Home-screen widgets, full iOS feature parity, broad physical-device coverage and end-to-end cross-platform sync validation remain release work. Encrypted `.stocked` backups require readable JSON export from iOS first. New household memberships, custom permissions and unresolved tombstone conflicts can require owner review. Timers/notifications require Android permissions and may be constrained by battery settings or Waydroid.
