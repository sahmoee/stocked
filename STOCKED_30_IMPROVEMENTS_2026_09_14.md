# Stocked iOS — 10 features and 20 polish improvements

Implemented September 14, 2026. Entry: **Kitchen Toolbox → Reference → Kitchen Math**.
The existing toolbox already contained budgeting, timers, substitutions, meal costs, pantry audits,
planning, preservation and price lookup. Those existing capabilities are not counted as new.

## Ten new features

All ten have editable inputs, deterministic local calculations, an explicit worked example,
validation, an explanation of the formula, and a shareable calculation including its assumptions.
Implementation: `Stocked/KitchenMathCore.swift` and `Stocked/KitchenMathView.swift`.

1. **Unit-price comparison:** normalize two package prices to equal quantities, identify the
   cheaper package, and calculate savings against the higher unit price. Handles free items and ties.
2. **Whole-package buying:** calculate how many packs to buy, total quantity, leftovers and cost.
   Zero price is explicitly treated as unknown cost.
3. **Pan scaling:** compare rectangular and round pans using interior dimensions and intended
   batter depth; calculate a recipe multiplier without inventing a baking time.
4. **Baker’s percentages:** derive flour-relative water, salt, yeast, fat and sugar percentages
   and total dough weight from entered gram amounts.
5. **Hydration adjustment:** calculate the flour or water to add to reach a target dough hydration,
   with no impossible instruction to remove an ingredient already mixed in.
6. **Ingredient ratio scaling:** change the base ingredient while retaining the second ingredient’s
   proportion, with explicit measurement-unit labels.
7. **Edible-yield buying:** use the user’s trim-loss estimate to calculate buying weight, rounded up
   to the next gram. No inferred yield or database precision.
8. **Portion packing:** calculate full servings, remainder, containers for full servings and the
   total with a separate remainder container.
9. **Batch timing:** plan sequential rounds from per-batch capacity and simultaneous trays, adding
   turnaround only between rounds.
10. **Offer calculation:** apply percentage discount, capped fixed coupon and tax in a disclosed
    order, with line-by-line totals and savings. Store rounding/exclusions remain explicit limits.

## Twenty polish improvements

| # | Improvement | Evidence |
|---|---|---|
| 1 | Toolbox search now uses the same themed input surface as Inventory and Recipes. | `KitchenToolboxView`, `StockedSearchField` |
| 2 | Search includes categories and all ten calculator names/descriptions, with localized matching. | `ToolboxTool.searchText`, `GlobalSearchEngine` |
| 3 | Toolbox shows a live matching count and a concise pinning hint when idle. | `KitchenToolboxView.body` |
| 4 | An empty tool search has a visible “Show all tools” recovery action. | `KitchenToolboxView.body` |
| 5 | Toolbox content now honors the shared readable width on larger windows. | `KitchenToolboxView.body` |
| 6 | Toolbox scrolling dismisses the keyboard interactively. | `KitchenToolboxView.body` |
| 7 | Every tool has a visible 44-point pin/unpin control; pinning no longer requires discovering a context menu. | `KitchenToolboxView.toolGrid` |
| 8 | Pins have explicit VoiceOver action names and state; tool labels announce pinned status. | `toolGrid`, `ToolboxTile` |
| 9 | Tool cards use the shared press style and Reduce Motion behavior. | `toolGrid`, `PressableStyle` |
| 10 | Tool titles and descriptions use the larger shared headline/subheadline roles and grow vertically. | `ToolboxTile` |
| 11 | Tool outlines become stronger under Increase Contrast. | `ToolboxTile` |
| 12 | Shared toolbox section labels use readable subheadline type and heading accessibility traits. | `ToolboxSectionLabel` |
| 13 | Shared tool statistic figures use monospaced digits and center naturally wrapped values. | `ToolboxStatTile` |
| 14 | Shared empty-state titles center correctly when wrapping. | `ToolboxEmptyState` |
| 15 | Expiry chips add a meaningful glyph and readable text; speech says “recorded expiry is today” instead of “expires in Today.” | `ExpiryUrgencyChip` |
| 16 | Selecting a tool in global search now opens that actual tool, retaining search behind it, rather than dismissing to Home. | `GlobalSearchView.selectedTool` |
| 17 | Calculator inputs accept locale decimal separators and decimal digits, rejecting ambiguous grouping, partial numbers and trailing junk. | `KitchenMathCore.parse` |
| 18 | Calculator validation is attached to its field; missing inputs and out-of-range values never produce a misleading zero result. | `KitchenMathField.problem`, `KitchenMathCalculatorView.input` |
| 19 | Numeric keyboards include Next amount and Done; hidden round-pan width fields are skipped. | `focusNext`, keyboard toolbar |
| 20 | Calculations retain separate scene drafts; replacement/clearing is confirmed and example amounts are visibly labeled, including after restoration. | `KitchenMathDraft`, scene storage, confirmation dialog |

Supporting details: quantity and currency labels are explicit; changing a unit label does not pretend
to convert amounts. Results can be selected/copied and shared with the source inputs, pan shapes,
formula and assumptions. Cards and forms use existing Stocked presentation/color/type components.

## Ownership and compatibility

- Owner and sole runtime consumer: Stocked iOS/iPadOS app. New calculator inputs are small,
  per-scene device drafts, not household data, pantry truth, recipes or grocery mutations.
- No shared schema, API, provider, secret, paid model, notification, widget or extension change.
- Existing Toolbox raw identifiers stay unchanged; `kitchenMath` is additive. Existing usage and
  pins retain their owner. Unknown new tool usage IDs are already ignored by older readers.
- Global-search tool selection uses the existing destination registry and themed native sheet.
- Existing kitchen data and sync are untouched. This is not an automatic grocery/inventory update.

## Verification

- `xcrun swiftc Stocked/KitchenMathCore.swift scripts/KitchenMathChecks.swift -o /tmp/stocked-kitchen-math-checks`
  followed by that executable: **182 checks passed**.
- Fixtures cover every tool, missing/negative/infinite/over-limit inputs, locale commas and Arabic
  numerals, grouping ambiguity, whole counts, zero divisors, free-price ties, pan geometry/depth,
  hydration in both directions, trimming, partial portions, batch gaps, capped coupons and tax order.
- Decimal rounding regressions cover `0.07 / 0.01` packages and `0.3 / 0.1` portions, so binary
  floating-point noise cannot spuriously buy an extra pack or lose a full serving.
- Changed Swift sources passed parser validation; `git diff --check` passed.
- `python3 scripts/test-theme-contrast.py`: **4 tests passed**, with no palette regressions.
- Generic iOS compilation and the final incremental build both passed for the app, widget and share
  extension. Final artifacts are build **244**, marketing version unchanged. DerivedData is on the
  external Macintosh SSD at `MacStorage/Developer/DerivedData/Stocked-Polish-20260914`.
- No simulator, device UI, VoiceOver or touch/runtime verification was performed. The user is doing
  device checks; these have not been signed off by source/logic validation.
