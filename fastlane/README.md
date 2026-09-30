fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

### verify

```sh
[bundle exec] fastlane verify
```

Check the selected release Xcode and changed Swift sources

### build_all

```sh
[bundle exec] fastlane build_all
```

Compile every declared scheme without signing or uploading

### archive_app

```sh
[bundle exec] fastlane archive_app
```

Create and validate a signed archive; scheme and archive_path are required

### presentation

```sh
[bundle exec] fastlane presentation
```

Compare presentation snapshots on an explicitly selected simulator or Mac destination

### testflight

```sh
[bundle exec] fastlane testflight
```

Explicitly export a validated archive and upload it to TestFlight

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
