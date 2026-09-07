# Stocked UI polish

## Scope

- Removed the black icon backplates from Home's stock gauge and Scan/Add/Log glyphs. The primary Scan card and selected root tab retain their deliberate charcoal surfaces.
- Preserved the transparent watercolor artwork, aspect-fit rendering, and shared image cache. Home's widget picker shows the same illustration family as the live widgets.
- Added `StockedGlassKit`, `StockedGlassGroup`, and `stockedGlassSurface` in `Stocked/GlassUI.swift`. These are original shared components built with [Apple's Liquid Glass APIs](https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views); there is no additional package, subscription, or asset license.
- Applied glass to the root tab bar, header actions, sheet close buttons, secondary buttons, Home customization controls, and selected cooking/grocery/recipe controls. Reading cards, forms, and canvases remain matte.
- Added opaque themed glass fallbacks for Reduce Transparency and Increase Contrast. Shared button scaling and interactive glass follow the existing Reduce Motion policy. Disabled buttons have visible feedback.
- Improved light-theme action/supporting-text contrast without changing decorative gold artwork. Migrated 335 reviewed supporting-text foregrounds across 62 View/Sheet files; icon, status, selection, and overlay treatments were reviewed separately.
- Unified settings and recipe-import fields, section icons, presentation backgrounds, secondary text, and action sizing. Cooking serving controls remain separately accessible.

No account, household, persistence, import, navigation destination, or service contracts change in this pass.

## Validation

`python3 scripts/test-theme-contrast.py` reads the actual RGB tokens and semantic helper routing. It checks 60 text/surface pairs and both selected-tab appearances at a minimum ratio of 4.5:1. The minimum supporting-text ratio is 4.742:1 and the minimum functional-accent ratio is 4.748:1. These are solid-surface measurements, not a claim that every rendered screen or glass backdrop has passed an accessibility audit.

The artwork checks cover 32 reference assertions and 36 Home alpha assertions. Swift syntax and whitespace checks cover the edited files. The shared Stocked scheme supplies the generic iOS build validation, including app extensions. Existing concurrency and deprecation warnings remain outside this presentation-only change.

Validation on September 7, 2026: the signed generic-device build succeeds. The built app, share extension, and widget extension all report version 5, build 202. The app installs on the paired Key iPhone and Key iPad. The iPhone launch succeeds; screenshot capture times out. The iPad launch is blocked by its lock screen. Installation and compilation alone are not interaction tests, and this run does not establish visual approval on either device.

Device screenshots, largest text sizes, dark appearance, VoiceOver, multitasking, and accessibility glass fallbacks need separate on-device review. Stocked currently has no isolated UI-test workspace: launching the app starts its real local stores and normal background services. Do not call source checks or generic compilation end-to-end household QA.

## Ten release priorities

1. Add a separate test kitchen so automated UI checks cannot affect anyone's real groceries or household.
2. Check every main screen on iPhone and iPad, including landscape and narrow Split View.
3. Test the largest text sizes and VoiceOver reading order, especially headers, menus, and longer button labels.
4. Review light/dark appearance, Reduce Motion, Reduce Transparency, and Increase Contrast on real devices.
5. Exercise household invitations, permissions, offline edits, and conflicting changes from two devices.
6. Test receipt, barcode, photo, and recipe imports with duplicates, cancellation, and denied permissions.
7. Prove backup and restore work on a fresh install, including larger recipe/photo libraries.
8. Measure scrolling, launch time, memory, and battery use with a large kitchen; resolve remaining compiler warnings before release.
9. Verify timers, notifications, widgets, Live Activities, share intake, and deep links after backgrounding or restarting.
10. Update App Store screenshots, privacy details, and help, then run a small TestFlight round with the resulting build.
