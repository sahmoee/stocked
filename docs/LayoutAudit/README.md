# Stocked layout audit — September 9, 2026

The reported Cook ingredient grid used independently sized cards with centered row alignment. Shared lazy equal-height rows now measure each column at its available width and align peer card surfaces. Multi-column ingredient summaries reserve three lines; accessibility layouts use a single column with full names.

Shared changes include adaptive column minimums, sheet-local width measurement without reapplying font preferences, bounded wrapping chips, top-aligned page content, a header that accommodates its44-point controls, and20-point page-end spacing instead of the former120-point duplicate navigation clearance.

Feature ledgers record source inspection, repaired screens and intentional media geometry:

- [Cooking and recipe discovery](Cooking.md)
- [Library, inventory, grocery and planning](LibraryInventoryAndPlanning.md)
- [Settings, tools and sheets](SettingsAndSheets.md)
- [View-file inventory](ViewInventory.tsv)

The inventory maps209 view-containing files to owners. Feature source audits are recorded in the ledgers; the final review of remaining shared wrappers was stopped and must not be represented as a completed visual audit.

## Validation status

The user initially authorized iPhone and iPad simulators, then requested that checks stop and said they would test on device. Simulator builds were stopped before completion. No simulator screenshots, completed integrated build or device visual sign-off are claimed for this batch. Earlier syntax-only parsing is recorded in the feature ledgers.

`LayoutConsistencyTests` covers shared row geometry and narrow/large-text columns; `LayoutVisualAuditTests` contains disposable-simulator captures of representative pages/sheets with long inventory names and accessibility text. They were saved but not run. Both audit simulator devices are shut down.

Device review should prioritize the reported Cook grid, card rows in Inventory and Recipes, medium-height add/edit/review sheets, grocery store editing, long cooking instructions, and larger-text planner/settings forms. Existing user data and prior performance fixes remain the intended behavior.
