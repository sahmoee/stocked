# Dark-mode artwork and review — September 24, 2026

## Scope and recovery

Stocked iOS owns this change. Existing light-mode assets remain intact. Dark variants are selected
after decorative aliases resolve, with separate ImageCache keys, so a live theme change cannot reuse
the wrong prepared image. Publisher and user photography are not remapped. No data/schema or backend
changes. Pre-dark-mode source: `76877e2`; original redesign restore tag: `restore/pre-pastel-2026-09-24`.

## Findings and fixes

- Home retained the daylight hero in dark mode. Added an evening kitchen image and semantic cream
  heading/supporting text. Removed the old dimming overlay.
- Older pages used fixed brown gold and green foregrounds on dark cards. Foreground expressions now
  use `stockedAccentInk` and `stockedSuccessInk`, including conditional states. Fixed brand button
  fills remain fixed, with ivory labels where they previously had dark-on-dark text.
- Corrected the expiry selector, receipt quantity controls, planning/prep actions, selected profile
  and onboarding chips, database pills, and the celebration card's light-only background.
- Recipe ingredient heading now keeps its word intact beside the secondary controls.
- Statistics foregrounds and graph accents use readable dark-mode hues.
- Secondary buttons in Cook, recipe previews and method comparison now use text ink instead of
  the button-fill color. Inventory's computed fill-status colors use the adaptive palette too.
- The independently hosted QA composer now explicitly inherits the saved appearance and an opaque
  theme canvas; it previously appeared as a pale translucent sheet over the dark app.

## Device review

iPhone 17 Pro Max, native app through iPhone Mirroring. Dark mode was already enabled when reconnecting.
Inspected Home; Cook; Cook Later Plan, Shop, Prep and calendar; Inventory hub and Fridge list; item
details including quantity, fill level, category, storage and expiry controls; Recipes hub, saved
library and recipe detail with expanded ingredients; Grocery and Choose Store; drawer; Kitchen
Toolbox and Low Stock Report; Kitchen Report; Databases; Settings and Household. Cook Now's empty
state and populated almost-ready results, plus the unsent QA report composer, were also inspected.

Also scanned the entire iOS Swift source for fixed foreground/background color usage and reviewed
the shared sheet/form/control and theme boundaries. Intentional white QR/print canvases and real
food photographs remain light. Camera capture, destructive actions, invitation submission, purchase,
live cooking completion and data mutations are not exercised by this visual review. Source coverage
does not mean every possible data-dependent screen state was manually opened. No iPad simulator
runtime is installed; iPad visual acceptance remains outstanding.

## Artwork provenance and final prompts

Built-in imagegen was used, with the corresponding existing light PNG as the edit target. All three
outputs are persisted in `Stocked/Assets .xcassets/` under identically named `.imageset` directories:

- `pastel_kitchen_hero_dark.imageset/pastel_kitchen_hero_dark.png`
- `pastel_ready_meal_dark.imageset/pastel_ready_meal_dark.png`
- `pastel_fresh_produce_dark.imageset/pastel_fresh_produce_dark.png`

### Kitchen

Use case: lighting-weather. Edit target: the supplied Stocked kitchen hero. Create its matching
dark-mode evening version, 1536x1024 landscape. Preserve the exact composition, jars and contents,
basil, linen, pitcher with branches, botanical print, bowl and countertop placement. Change lighting
and materials' tones for a cozy softly lit evening kitchen: deep warm charcoal/espresso matte wall
and counter, muted sage foliage, soft honey highlights, smoky taupe ceramics and linen. Keep food
recognizable and beautifully softly illuminated. Top left 60% width by 40% height must be an
uncluttered evenly dark charcoal area so native cream heading text will read clearly. Gentle diffuse
warm light on lower objects, no bright hotspot behind text. Photorealistic natural editorial still
life, quiet pastel hues adapted to dark mode, no oversaturation, no heavy vignette. No text,
lettering, UI, logos, borders or watermarks. Same objects and framing; do not add lamps or candles.

### Meal

Use case: lighting-weather. Edit target: supplied creamy chicken and orzo bowl cutout. Create a
matching dark-mode version for a warm charcoal and muted sage app card. Preserve bowl angle,
chicken/orzo/spinach/parmesan ingredients, herb sprig left, full silhouette and composition. Change
ceramic bowl to matte smoky taupe with subtly illuminated rim. Softer evening studio lighting,
gentle honey highlights, muted sage greens, appetizing clearly visible food with lower highlights
than daylight reference. Truly transparent RGBA background around bowl and herb; no solid background,
no checkerboard, no haze or colored glow around edges, no ground plane, no text, no UI. Landscape
1536x1024 with full objects uncropped and a small transparent margin.

### Produce

Use case: lighting-weather. Edit target: supplied carrot/onion/tomato cutout. Create matching dark-mode
artwork for warm charcoal and muted peach-brown app cards. Preserve exact grouping, angle and silhouette:
carrots with leafy tops, two onions, tomato front left. Photorealistic produce with soft evening studio
light and restrained honey edge highlights, muted terracotta carrots/tomato, sage foliage, warm taupe
onion skins. Keep food recognizable and readable at small sizes; gently lower daylight highlights,
no dramatic hard contrast. Truly transparent RGBA background, fully cut out with no backdrop, no
haze/glow around edges, no ground plane, no checkerboard, text, UI or watermark. Landscape1536x1024,
full uncropped subjects and small transparent margin.

## Validation

- Six contrast checks passed, including actual adaptive foreground values and ivory-on-gold labels.
- KitchenArtworkAudit: 48 checks passed; dark food cutouts contain meaningful alpha transparency.
- Signed build-for-testing compilation passed. XCTest execution is separate and was not performed.
- Build 320 installed and launched on the physical iPhone. Final corrective checks confirmed the
  dark Home artwork, Inventory hub, readable Fridge fill-status labels, Cook Now populated summary,
  and Kitchen Report's sage/gold statistics. Code signature verification passed.
- The QA composer appearance fix compiled in build 320; its corrected presentation has not yet
  been reopened for a final visual check. The original defect was observed on the device.
