<!-- PROJECT-KNOWLEDGE managed; do not edit this export -->
> Maintained in ProjectKnowledge: `projects/stocked/documents/docs/DESIGN_VARIANTS_2026_10_14.md`. This is a generated portable read-only export. Update the central source with `project-knowledge put`; use `project-knowledge publish` to refresh exports. Relative links and code paths below refer to this original project location.

# Optional Stocked design variants — October 14, 2026

Current is the default. New and existing users without a saved design keep the original appearance. Pastel/Tan, stored dark-mode choice and explicit font preferences remain intact; returning to Current restores them.

The optional stable identifiers are pantryJournal, kitchenStandard and eveningTable. Missing or unknown values resolve to Current. Selection is local to the device, with optional backup metadata. Evening Table uses effective dark appearance without rewriting the stored dark preference.

## Design improvements
1. Shorter illustrated heroes expose useful content earlier.
2. One main Home action and clearer action hierarchy.
3. Grouped use-first and meal sections replace repeated Home cards.
4. Editorial headings and readable control typography; native named font weights.
5. Shared control heights, padding and 16/8/12-point component families.
6. Separate action fills, label colors and status inks.
7. Explicit expiry/low-stock text; labels refresh after foregrounding and across day changes.
8. Stronger selected navigation states with existing destinations preserved.
9. Shared presentation, form, detail and cooking theme paths.
10. Deliberate dark palettes and existing adaptive wide/Dynamic Type layouts.

## Compatibility and rollout
Stocked iOS owns the preset identifiers and palette definitions; StockedMac is the native recipe-manager consumer. No Worker schema or endpoint changes. Backups use optional string metadata, old files retain the local selection, and unknown values fall back safely. Paired Watch snapshots add an optional bounded designVariant field without changing wire version 1. Old Watch builds ignore it; new Watch builds retain Current for missing/unknown values. Widgets use the existing app-group preference copy with safe fallback.

Rollout: rebuild the updated app sources, optionally update paired Watch, and choose a preset in Appearance. Rollback: choose Current; no kitchen data migration or deletion is involved. A source rollback removes only the optional design commits.

## Validation and limits
Codex and Claude implemented and cross-reviewed the changes. 21 focused hosted iOS tests passed, including preference migration/persistence/backup, actual button contrast, installed font faces and native selector renders. 97 native Watch protocol checks passed. 99 Mac design checks passed; the Mac app build passed. Existing Mac checks passed after their harness used the active SDK and matched the released 6–16-character invite contract: 7 invite and 3 hydration preservation checks.

The iOS test fixtures are retained for the app lifetime to isolate a pre-existing Swift 6.2 Intel simulator crash when nested store schedulers deallocate. The teardown defect was investigated, not fixed or marked resolved by this appearance change. A proposed scheduler-only patch was kept outside production source.

Native selector images were visually reviewed. Whole-app physical-device review, VoiceOver, Increase Contrast, a live Mac theme switch with an editor/browser open, and paired Watch appearance review remain unverified. The native Mac adapts the design to recipe-only workflows; native sidebar vibrancy and internal layouts of existing non-recipe forms are retained.

## iOS/iPadOS
Settings → Preferences → Appearance → Design offers Current (default), Pantry Journal, Kitchen Standard and Evening Table. The original Home and customizable shortcut board remain available. The new Home uses actual inventory, metrics and recipe destinations. No illustrative mockup data is included in production.

Native selector references are stored under Brand/DesignVariants.
