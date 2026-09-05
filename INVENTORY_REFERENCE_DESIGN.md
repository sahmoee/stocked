# Inventory reference implementation — September 4, 2026

## September 5 reference restoration and follow-through (current)

The reference's three action subjects are restored with individual transparent assets:
`inventory_expiring_reference` (calendar/tomato jar), `inventory_low_reference` (milk/tin basket),
and `inventory_add_reference` (wooden grocery crate). Corresponding Home actions and Inventory
destination headings use those same files. Dedicated protein/leftover cutouts extend the family;
Leftovers and Save a Portion now use the food-container illustration, not the grocery crate.
These supersede the interim substitutions documented below. The inactive atlas remains reference-only.

Action cards use equal-height measured layout at normal phone/tablet widths and stack below 350
points. Text grows naturally instead of forcing a fixed height. The three counts/actions remain
native, accessible, and connected to the existing inventory owners. Dark-gold arrows and banner
controls use charcoal foregrounds. Expiring Soon and all Inventory form hosts share inventoryCanvas.

Ten UI and ten UX improvements extend the design through the details sheet, search, reports,
add/edit/browse forms, storage selection, low-stock grocery handoff and leftover draft/date workflows.
See POLISH_UI_UX_2026_09_05.md and STOCKED_POLISH_40_2026_09_05.md. Image prompts and saved paths
are in ARTWORK_PROMPTS_2026_09_05.md. Generated art is a faithful-subject recreation, not pixel identity.

## Earlier September 5 consistency correction (superseded action mappings)

The atlas is retained as an unused reference, not rendered in production. Inventory now uses
the same individual watercolor cutouts as Home: home_kitchen_still_life, home_widget_planning,
inventory_category_fridge and home_widget_pantry, plus inventory_refrigerator_hero. The fridge
is centered and aspect-fit at a larger minimum height. No multiply blend or anisotropic stretch.
StockedKitchenArtwork owns both tabs' rendering; ImageCache prepares 720-pixel thumbnails off-main.
The attempted newly generated fridge was rejected because its checkerboard was baked into RGB,
not real alpha. No generated replacement was shipped in this correction.

QA capture now uses the committed layer tree at 1x, avoiding drawHierarchy's GPU readback;
ordinary UIKit/SwiftUI artwork and touch annotations remain, but video/Metal/live blur may differ.
Inventory presentation reservation computation uses revision-checked utility snapshots. These are
code-path fixes, not proof of a unique runtime cause: the field freeze reports lack sampled stacks.

Follow-through: category/all-item lists, shared item rows, Expiring Soon, Running Low, Leftovers,
Add Leftovers, Add Item, Edit Item, ingredient browsing and ingredient detail now reuse the
editorial palette and/or illustrated headings. Native scanner/camera and system confirmation
surfaces retain their platform interaction. Shared item rows carry the style into search results.
All is now an explicit filter; adding while viewing All defaults to the valid Fridge storage zone.
Low-stock results refresh when inventory revision changes. No schema or backend changes.

The supplied Stocked Inventory screenshot is the visual target. The landing uses native SwiftUI
text, live item counts and existing navigation rather than embedding a screenshot as the screen.
The shared header and tab bar remain owned by the app shell.

Implemented: serif greeting/title, kitchen still-life hero, appliance/category panel, explicit
Fridge/Freezer/Pantry/Leftovers destinations, All inventory destination, illustrated Expiring Soon,
Running Low and Add Items actions, and a noninteractive Coming Soon AI banner. Large accessibility
text grows the action cards and hides decorative hero art to prevent overlap. Dark mode uses the
existing semantic text/background colors.

Artwork: `Stocked/Assets .xcassets/inventory_reference_atlas.imageset/inventory_reference_atlas.png`.
Created with the imagegen skill from the user-supplied screenshot. Generation prompt: create a
3-column, 2-row atlas, with kitchen board/basil/utensils, open bronze refrigerator, calendar and
tomato jar, wire milk/tin basket, and wooden grocery crate, leaving the last cell empty; match the
reference's detailed warm antique illustration style. Follow-up prompts constrained all objects
to their cells and replaced the background with flat pure white for native multiply compositing.

Validation: generic physical iOS build-for-testing, plus whitespace checks. No simulator run or
physical-device screenshot comparison has been performed. This is a close reference recreation,
not verified pixel identity: generated illustrations and system typography differ from source pixels.
