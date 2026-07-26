# Accessibility audit (#14)

A blind edit across 341 files would do more harm than good. This is the targeted findings list — each is a small, safe fix best done with the view visible in Xcode's Accessibility Inspector.

## Highest priority
1. **Icon-only buttons need labels.** Many tiles/toolbar buttons are `Image(systemName:)` with no text. VoiceOver reads them as "button" or the SF Symbol name. Add `.accessibilityLabel("…")` to: toolbox tiles (the tile already shows a title — mark the image `.accessibilityHidden(true)` and label the tile), the bolt/menu button, notification-action glyphs, QR share buttons, and the widget deep-link chevrons. The project already has a `stockedRowAccessibility(_:hint:)` helper — reuse it.
2. **Color-only status.** Expiry uses red/amber/green fills. Pair color with a shape/text cue (e.g. an icon or "Expired" text) so it survives color-blindness and grayscale. The new Money Saved view already labels each stat with text — mirror that pattern in inventory rows.
3. **Contrast in dark mode.** `themeSecondaryText` on dark backgrounds is close to the 4.5:1 line for body text. Verify with the Accessibility Inspector's contrast check on Home, Inventory, and the new tool views; bump opacity where it fails.

## Medium
4. **Dynamic Type.** The app clamps at `.accessibility3` (good), but several fixed-height rows (48–52pt) will clip at that size. Spot-check Grocery rows, toolbox tiles, and the settings accordion at the largest allowed size; let heights grow or reduce `lineLimit`.
5. **Touch targets.** Some inline toggle/close glyphs are < 44pt. The `stockedTouchTarget()` helper exists — apply it to small tap targets (label delete, chip removal).
6. **VoiceOver grouping.** Multi-line cards (stat tiles, activity rows) read as separate fragments. Wrap each in `.accessibilityElement(children: .combine)` so they read as one phrase.

## Low
7. **Announce async results.** After "Build Grocery List", "Add N to inventory", and Sync Now, post an `.accessibilityNotification(.announcement:)` so VoiceOver users hear the outcome (the toasts are visual-only).
8. **Reduce Motion.** The login `animateIn` and skeleton shimmer should check `@Environment(\.accessibilityReduceMotion)` and skip/att­enuate.

## Quick wins already in place
- Dynamic Type is enabled app-wide with a sensible clamp.
- `.stockedScreen()` sets a consistent foreground/tint, which helps contrast baseline.
- New tool views (Money Saved, Reorder, Activity) use text + icon together rather than color alone.
