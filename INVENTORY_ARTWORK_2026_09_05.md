# Inventory illustration update

Created with the built-in image generator using the supplied cutting-board screenshot for subject
and the existing pantry illustration for style. Original generated output is retained; the project
copy lives in `Stocked/Assets .xcassets/inventory_kitchen_board_reference.imageset/inventory_kitchen_board_reference.png`.

Freezer reuses `inventory_category_freezer` (frozen peas/ice container), Pantry reuses
`inventory_category_pantry` (dry-goods jars), and Leftovers reuses `kitchen_leftovers_reference`
(prepared food containers). All three use leading artwork in the shared editorial heading.
No stock data, photos, backend contract or Home layout changed. Hero nonoverlap geometry remains.

## Generation prompt

Use case: illustration-story. Create one production transparent PNG cutout for Stocked kitchen app. Reference 1 is SUBJECT and composition reference only: recreate the upright warm oak cutting board with round handle at rear right, leafy basil in speckled cream ceramic pot on left, matching cream utensil crock in front holding wooden spoons and wire whisk, garlic bulb and tiny wooden salt bowl at bottom right. Reference 2 is STYLE reference: match its refined warm watercolor/gouache botanical cookbook illustration, delicate grain, hand-painted detail, natural honey wood, cream ceramic, olive greens, soft realistic shading. Isolate entire grouped still life centered with generous clear margins, all objects fully visible. Genuine transparent alpha background, no beige rectangle, no checkerboard painted in, no typography, no UI, no labels, no border, no watermark. Square 1024px image. Keep grounded soft contact shadows only, no scenery.

## Validation boundary

Artwork alpha/catalog checks and generic iOS build are run for this batch. Physical-device visual
review remains pending; no simulator or device install is performed.
