# Spacing and alignment review — September 24, 2026

## Scope

Stocked iOS presentation only. Baseline commit `582f958`; the original pastel restore tag remains
`restore/pre-pastel-2026-09-24`. No data, persistence, backend, artwork or shared chrome changes.

## Device findings and corrections

- Recipe hub: equal-height destination cards had arrows at different vertical positions. A flexible
  spacer anchors each footer to the bottom of its row while keeping headings and artwork aligned.
- Inventory hub: descriptions competed with arrows for narrow columns. Descriptions now use the
  full card width with natural wrapping and supporting sans text; arrows share a bottom footer.
- Inventory list: Edit occupied its own mostly empty row. Scan Barcode, Scan Receipt and Edit now
  share one adaptive toolbar, with a vertical fallback when horizontal content does not fit.
- Grocery: the empty weekly-plan card stopped short of the content column. It now fills that width.
  The empty-list icon, heading and Add Item action share a compact row; narrow/accessibility layouts
  stack. This removes unnecessary vertical travel between the list and suggested items.
- Kitchen Report: a large centered ring and several separate caption rows consumed the first half
  of the report. A smaller ring sits beside a more legible health explanation, vertically centered.
  Narrow/accessibility layouts stack; natural text growth is retained.

## Verification

Reviewed on the physical iPhone 17 Pro Max through iPhone Mirroring in dark mode: Home, Cook hub,
Cook Later Plan/Shop/Prep, Inventory hub and Fridge list, Recipes hub, saved collection and recipe
detail, Grocery, drawer and Kitchen Report. Reopened each changed surface after installation and
confirmed the corrected placement and wrapping. No inventory, recipe, grocery or plan data was edited.

Build 322 compiled, installed and launched successfully. Code-signature verification and
`git diff --check` passed. Layout-only changes were checked visually; no new implementation-mirroring
tests were added. No iPad simulator runtime is installed. iPad, accessibility text sizes and every
possible data-dependent state were not visually exercised in this pass.
