# Inventory UI and UX polish — September 5, 2026

Scope: the Inventory destinations and add/edit/browse sheets. Native controls, the shared
header/tab chrome, existing stores, reservation engine, and reference-family artwork renderer
remain authoritative. This is not a claim of physical-device visual verification.

## 10 UI improvements implemented

1. **Continuous parchment presentation canvas.** The shared `stockedPresentationSurface`
   accepts an optional canvas; Inventory detail, add, edit, browser, ingredient detail, and
   leftover forms use it so the sheet host and readable-width margins match the page.
   Owner: `Stocked/DesignSystem.swift`; adopters in the inventory sheet files.
2. **Editorial Inventory Details.** The formerly separate status sheet now reuses
   `InventoryEditorialHeading`, the reference artwork, serif headings, gold statistics, and
   `InventoryEditorialCard`. Owner: `Stocked/InventoryDetailsSheet.swift`.
3. **Readable reservation hierarchy.** Item totals, held/available quantities, meal titles,
   dates, and claimed amounts use vertically wrapping labels instead of competing fixed-width
   row text. Owner: `Stocked/InventoryDetailsSheet.swift`.
4. **Adaptive scanner actions.** Barcode/receipt actions use a width-fit horizontal or vertical
   layout, reference serif typography, equal treatment, and 44-point minimum targets.
   Owner: `Stocked/InventoryView.swift`.
5. **Consistent zone filter rail.** Selected and unselected chips use parchment/gold borders,
   theme-aware selected text, minimum targets, and a selected accessibility trait.
   Owner: `Stocked/InventoryView.swift`.
6. **Themed inventory search.** The translucent white-on-dark input is replaced with the semantic
   card surface, gold border/icon, readable primary/secondary colors, and a larger clear control.
   Owner: `Stocked/InventoryView.swift`.
7. **Shared adaptive storage picker.** Add and edit use one native adaptive grid with wrapping
   labels and 44-point targets instead of cramped segmented/fixed-row selectors.
   Owner: `Stocked/DesignSystem.swift`; adopter: `Stocked/InventoryItemSheets.swift`.
8. **Responsive quantity editing.** Quantity, units, and optional per-container fields reflow
   in a width-adaptive grid; container steppers gain 44-point targets and explicit labels.
   Owner: `Stocked/InventoryItemSheets.swift`.
9. **Readable wizard chrome.** Add Item's title/close and scan/browse controls have separate
   rows; progress markers use appearance-aware colors and a single spoken step description.
   Owner: `Stocked/InventoryItemSheets.swift`.
10. **Consistent report cards.** Leftover titles/status/date wrap above an adaptive action grid;
    Low Stock moves its status beneath the title instead of squeezing it into a trailing pill.
    Both retain the same editorial card and semantic text treatment.
    Owners: `Stocked/LeftoversLifecycle.swift`, `Stocked/ToolboxInsights.swift`.

## 10 UX improvements implemented

1. **No hidden inventory search.** Closing search clears the active query, opening it focuses
   input, Return dismisses the keyboard, and no-match state offers Clear Search or an explicit
   Search All Inventory action. Owner: `Stocked/InventoryView.swift`.
2. **Recoverable ingredient browsing.** The catalogue displays its actual result count,
   provides a clear-search control and a no-match reset, and labels per-item add controls.
   Owner: `Stocked/InventoryItemSheets.swift`.
3. **Manual storage choice wins.** Subsequent typing or suggestion selection no longer moves
   a manually chosen Freezer/Pantry/etc. item back to an inferred zone.
   Owners: `Stocked/InventoryFormPolicy.swift`, `Stocked/InventoryItemSheets.swift`.
4. **Editing does not silently restock empty items.** Zero quantity and zero fill survive
   editor initialization/save; invalid non-finite fill values are normalized in the draft,
   without writing merely because an editor opened. Same owners as item 3.
5. **Coherent, permission-aware edits.** Save applies one assembled item instead of a store
   mutation per field; removed items show an actionable warning instead of a false successful
   dismissal, untouched fields retain newer household values, no-op saves do not emit another
   mutation, and household edit permission is checked at action time.
   Owner: `Stocked/InventoryItemSheets.swift`.
6. **Safer removal controls.** Item deletion is undoable and permission-gated, restores only
   an absent identity, and photo removal no longer sits inside the photo-picker button.
   Leftover toss undo also refuses duplicate restoration. Owners: inventory sheets/leftovers.
7. **Draft loss protection.** Add Item and Add Leftovers disable swipe dismissal for meaningful
   drafts and offer Discard/Keep Editing on close/cancel. Owners: inventory sheets/leftovers.
8. **Actual cooked date for leftovers.** The user can record a past cooked date and preview
   its reminder date; saving uses that date instead of always assuming today. Existing expiry
   intervals remain unchanged. Empty whitespace titles are rejected by the store.
   Owner: `Stocked/LeftoversLifecycle.swift`.
9. **Complete, actionable inventory details.** Expiry/reservation counts reflect the full
   collection; Show All exposes rows beyond ten, every reservation claim is visible, and
   health rows open the existing item editor. Reservation refresh is cancellable/revision-keyed.
   Owner: `Stocked/InventoryDetailsSheet.swift`.
10. **Truthful restock handoff.** Low Stock rows open the editor; the add action counts only
    deduplicated missing names, uses structured grocery mutation outcomes/provenance, respects
    add permission, and becomes Open Grocery List when nothing remains to add.
    Owner: `Stocked/ToolboxInsights.swift`.

## Verification

- `git diff --check`: passed after this batch.
- Swift frontend syntax parse: passed for the changed shared/forms/report/detail files.
- `scripts/InventoryFormPolicyChecks.swift`: **19 native pure-logic checks passed** against
  the actual `Stocked/InventoryFormPolicy.swift` source.
- `StockedTests/InventoryPolishTests.swift`: six XCTest cases added for whitespace names,
  explicit storage overrides, preserving empty items, non-finite/range draft repair, concurrent
  household field preservation, and using the recorded cooked date for reminder calculations.
- QA section 48 adds eleven stable device journeys without marking them passed. The complete
  native `QAFeatureChecks` runner passes **47 contracts**, including the appended-section guard;
  it defines 123 device checks across the appended sections, not the complete legacy checkbook.
- Parent task owns generic-device compilation and all joint validation; no simulator or
  Xcode builds were started by this subtask. XCTest cases are not claimed executed here.
- Device follow-up: iPhone/iPad light/dark, largest Dynamic Type, keyboard/rotation,
  incomplete drafts, read-only household role, 11+ report rows/5+ reservation claims,
  stale removed-item editing, offline restock, and reference screenshot comparison.
