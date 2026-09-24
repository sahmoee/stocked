# Stocked pastel implementation — September 24, 2026

## Reference and recovery

Reference: `Brand/Stocked-Pastel-Mockup.png`.
Annotated restore tag: `restore/pre-pastel-2026-09-24`.
Snapshot commit: `603931bf074d5a12010a505640ff0b13e1c74973`.
The restore commit includes the approved image and every tracked source file before implementation.
For a non-destructive recovery checkout, create a new worktree from this tag. No household data,
Keychain data or local credentials are included in Git, and the redesign does not migrate records.

## Implementation

Owner: Stocked iOS repository. Consumers: iPhone, iPad, widget extension, cooking Live Activity,
and Watch accent. StockedMac and the Worker have no API/schema changes in this visual update.

- `DesignTokens.swift`: warm ivory canvas, cream elevated surfaces, cocoa text, muted honey and
  sage; dark surfaces remain readable. Pastel fills are kept separate from functional text roles.
- `PastelDesign.swift`: shared outlined matte cards, editorial hub heading and native Home layout.
- Home: real `KitchenMetrics`, real category classification, working inventory/category/ready-meal/
  expiry/recipe destinations. Counts and status copy derive from the current kitchen. The editable
  widget board, gallery, quick actions and saved layouts remain available under Your shortcuts.
- Cook, Inventory, Recipes and Grocery use the same typography hierarchy and responsive artwork.
- 140 existing card surfaces across 41 files now use the shared card component, covering planner,
  grocery, household, profile/settings, recipe details/import/editing, inventory sheets, diagnostics,
  statistics, cooking and onboarding. Lists/forms inherit cream rows and semantic text at the app
  and presentation boundaries. Controls use matte oat with accessible borders.
- Shared header: leading Stocked wordmark, context actions/back button, root gear opening the
  existing settings drawer. Shared tab bar: cream canvas, thin divider, gold selected content.
- Default typography: serif display/headings and sans body/metadata. Explicit Rounded, Monospace
  and System preferences are still respected, as are the in-app text scale and Dynamic Type.
- Widget palette and Watch/Live Activity accents match the updated brand hues.
- Feature rows stack at accessibility sizes; category tiles reflow. iPad keeps readable widths.

## Artwork

Three new assets were generated with the built-in image generation tool: `pastel_kitchen_hero`,
`pastel_ready_meal`, `pastel_fresh_produce`. The hero uses the approved mockup as a visual reference,
recreating its jars, basil, linen, pitcher and botanical frame without any UI or lettering. The two
transparent food cutouts recreate its creamy pasta and carrots/onion/tomato motifs. Prompts specify
soft natural light, warm cream/oat/sage, matte textures and no text/UI. Originals remain under
Codex generated_images; selected assets are saved in this repository's asset catalog. These are
decorative navigation illustrations, never publisher recipe images. Existing cutout art is gently
desaturated by its shared renderer; actual recipe and product photography is untouched.

## Validation

- Semantic contrast check: passed for light and dark text roles (minimum supporting-text contrast
  5.761:1 in light mode and 6.658:1 in dark mode).
- Generic iOS build, signed iPhone build and build-for-testing compilation: passed. Test bundles
  were compiled; the XCTest suite was not executed.
- iPhone 17 Pro Max review through iPhone Mirroring: Home, Cook, Inventory, Recipes, Grocery,
  Cook Now, Add Item, ingredient browser, settings drawer and Settings were opened and inspected.
  The review caught and corrected a global font override that erased serif headings, and increased
  Home food artwork size to match the reference. Real inventory counts remained intact; no records
  were added or edited during review. Appearance was set to Light and Serif for the approved design.
- Read-only native KitchenArtworkAudit: 40 checks passed, including both new transparent food cutouts.
- Five palette/contrast checks pass, including light/dark oat, sage and peach feature fills.
- The user authorized simulator verification for this task. The installed Xcode has simulator SDKs
  but CoreSimulator reports no installed runtimes. The paired iPhone 17 Pro Max and iPhone Mirroring
  were used for actual-device review. iPad and accessibility-size runtime screenshots remain
  unverified. No simulator runtime was installed.

The screenshot is a generated design reference. Native system safe areas, actual data, screen size,
font preferences and accessibility settings necessarily affect rendered positions. Exact pixel
identity is not claimed without a same-size screenshot comparison.
