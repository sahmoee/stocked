# Stocked artwork audit — September 5, 2026

This is the read-only intake audit, before the current implementation batch. Findings below are
not claims of physical-device verification or claims that every recommendation has shipped.
The visual target is the user's warm, detailed antique kitchen illustration: paper calendar with
tomato jar, milk/tin wire basket, and wooden pantry-grocery crate. Native text and live counts must
remain outside the raster artwork.

## Coverage and technical results

Implementation follow-up: the exact ten shipped image improvements and their executable guards
are recorded in STOCKED_POLISH_40_2026_09_05.md. Five new RGBA images are bundled, bringing
the repository to 322 image sets (73 active, 249 unbundled). KitchenArtworkAudit passes twenty
catalog/dimension/real-alpha/nonblank checks for the five new assets. Natural cutouts replace the
Cook/Recipes sticker-style navigation; real recipe/product photography is intentionally preserved.
The refrigerator hero is still the existing cream-appliance composition, not a newly verified
pixel-perfect copy of the earlier bronze-appliance screenshot. Runtime/device review remains pending.

- Checked every `Contents.json` and its named image file in all 317 repository image sets.
  No missing referenced image files were found.
- The app's synchronized `Stocked` folder contains 68 image sets, totaling 89,186,013 source bytes.
  These include 55 RGBA images and 13 RGB images. All have valid positive PNG dimensions.
- Read and decoded alpha for all 68 app image sets with ImageIO/CoreGraphics. Most cutouts have
  clear outer edges. `cook_row_use_something_up` has 52 outer-edge pixels with alpha above 8;
  its top jar and lower produce touch the frame and should be given breathing room.
- Examined representative images directly from each visual family, including every Home widget,
  Inventory category, and Recipe decorative image. This is a complete file/metadata audit with
  representative visual inspection, not a claim that all 249 unbundled ingredient icons received
  individual visual approval.
- The 249 root `Icons.xcassets` images are all 512×512 RGBA (36,054,667 source bytes). That root
  folder is not referenced by the current Xcode project, whose synchronized groups are Stocked,
  StockedWidgets, StockedShareExtension, and StockedTests. It is not currently a bundled remedy
  for missing item thumbnails. Do not add it wholesale: `protein`, `leftovers`, and `breakfast`
  collide with names in the active catalog.
- Checked the primary app-icon catalog's named files and the 64 loose alternate icon files.
  All 16 alternate families have 1024, 120, 152, and 180-pixel images. Primary/alternate app icons
  are user-facing identity choices, not decorative kitchen illustrations to silently replace.
- Five active-catalog assets have no literal Swift name references: `inventory_reference_atlas`,
  `cook_now_card`, `match_my_mood`, `pantry_favorites`, `surprise_me`. This does not by itself prove
  that dynamic item-slug lookup can never reach them, so this audit removed nothing.

## Inventory of active artwork

| Family | Complete image-set inventory | Dimensions and assessment |
| --- | --- | --- |
| Home heroes | `home_kitchen_still_life`, `home_grocery_bag`, `home_produce_crate` | 1536×1024, 1230×1278, 1484×1060 RGBA. Simpler watercolor; broad soft color haze in still life. Bag/crate also have cartoon shine marks. |
| Home widgets | `home_widget_cooking`, `home_widget_pantry`, `home_widget_planning`, `home_widget_shopping`, `home_widget_tools`, `home_widget_waste` | Six 640×426 RGBA. Detailed warm natural cutouts, usable common family. Waste is a compost bucket, not edible leftovers. |
| Inventory categories | `inventory_category_fridge`, `inventory_category_freezer`, `inventory_category_pantry`, `inventory_category_produce` | Four 512×512 RGBA. Detailed warm cutouts. Fridge is pickle jar/milk/yogurt, not a low-stock basket. |
| Inventory hero/reference | `inventory_refrigerator_hero`, `inventory_reference_atlas` | Hero is 1024×1536 RGBA cream appliance with broad haze, not reference bronze/freezer/pantry. Atlas is 1536×1024 **RGB with baked white background**. It has the correct subjects but must not be rendered as a transparent sprite. |
| Cook primary | `cook_now_hero`, `cook_later_hero` | Two 1254×1254 RGBA. Warm artwork but thick white sticker outlines conflict with reference natural edges. |
| Cook paths | `cook_row_ingredient`, `cook_row_build_food`, `cook_row_expiring`, `cook_row_leftovers`, `cook_row_mood`, `cook_row_surprise`, `cook_row_makeable_now`, `cook_row_use_something_up`, `cook_row_finish_serve` | Nine 1024×1024 RGBA. Many are photographic ingredient/meal collages. Correct category subjects, but not the antique editorial style. |
| Protein choices | `pro_beef`, `pro_chicken`, `pro_eggs`, `pro_lamb`, `pro_pork`, `pro_seafood`, `pro_tofu` | Seven 1024×1024 RGBA. Food-specific cutouts; retain selection semantics when replacing decorative variants. |
| Vegetable choices | `veg_cruciferous`, `veg_fresh_herbs`, `veg_leafy_greens`, `veg_mushrooms`, `veg_peppers_tomatoes`, `veg_root_vegetables`, `veg_squash_zucchini` | Seven 1024×1024 RGBA. Ingredient-specific cutouts. |
| Expiry choices | `exp_add_one_ingredient`, `exp_batch_prep`, `exp_flexible_meals`, `exp_freeze_or_prep`, `exp_quick_rescue`, `exp_use_whats_left` | Six 1024×1024 RGBA. Food/action-specific cutouts. |
| Leftover choices | `left_build_a_bowl`, `left_pasta_rice_remix`, `left_reinvent_it`, `left_simple_reheat`, `left_soup_or_skillet`, `left_wrap_or_sandwich` | Six 1024×1024 RGBA. Food/action-specific cutouts. |
| Recipe editorial | `recipes_hero`, `recipes_collection`, `recipes_past`, `recipes_ready` | Four 1536×1024 RGBA. Hero has natural edges; the three destination illustrations have thick white sticker outlines. |
| Legacy photo tiles | `breakfast`, `cook_now_card`, `dinner`, `expiring_soon`, `leftovers`, `lunch`, `match_my_mood`, `pantry_favorites`, `protein`, `snack`, `surprise_me`, `vegetables` | Twelve 1536×1024 RGB. Saturated full-bleed food photography. Not transparent, not the reference editorial art. |

## Prioritized live call sites

Line numbers are intake locations and may move in the implementation batch.

1. `Stocked/InventoryHubView.swift:6–15`: `InventoryReferenceArtwork` uses integer roles.
   Expiring maps to `home_widget_planning`, Running Low to `inventory_category_fridge`, and Add
   Items to `home_widget_pantry`. All three differ from the supplied subjects. Dedicated named
   assets are needed; replacing only the general art renderer does not fix the mapping.
2. `Stocked/CookHubView.swift:69,77`: primary cards use sticker-outline `cook_now_hero` and
   `cook_later_hero`. The existing `home_widget_cooking` gives the same egg/skillet subject without
   that outline. `home_widget_planning` gives the same calendar/planning subject.
3. `Stocked/RecipeVaultViews.swift:341,346,350`: My Collection, Ready to Cook, and Past Meals
   use `recipes_collection`, `recipes_ready`, and `recipes_past`. For same-family interim artwork,
   collection can reuse `recipes_hero`, cooking can reuse `home_widget_cooking`, and past meals
   can use `home_widget_planning` (calendar subject). For exact composition, regenerate the original
   three subjects with natural edges rather than discarding their meaning.
4. `Stocked/GroceryListView.swift:597,616`: meal-support cards use the same recipe sticker assets.
   The second call selects a decorative image with `meal.id.hashValue.isMultiple(of: 2)`;
   Swift's process-randomized hash makes that illustration unstable across launches. Choose the
   actual recipe image when available, otherwise one deterministic semantic fallback.
5. `Stocked/FoodsAndMoodsViews.swift:104–116` and `Stocked/CookNowFlows.swift:28–31`: Proteins,
   Vegetables, Expiring Soon, and Leftovers navigation tiles still use the legacy full-bleed photos.
   `CategoryRow.photoRow` and `CookCategoryCard` also own white-over-photo styling. Migrate these
   shared containers to themed editorial cutouts, not just their asset string.
6. `Stocked/CookComponents.swift:69,105` and `Stocked/FoodsAndMoodsViews.swift:21` still create
   named-image loads directly during layout/existence checks. Recipe/Grocery decorative artwork
   also bypasses `StockedKitchenArtwork`. Route owned decorative artwork through the shared bounded,
   scroll-aware image preparation path; do not replace actual food/publisher imagery with an alias.

## Ten concrete image-polish changes

These are implementation-ready recommendations for the current batch, not a shipped checklist.

1. Ship a dedicated RGBA **Expiring Soon calendar plus tomato jar** asset and map the action plus
   Expiring Soon destination heading to it. Keep the action title/count native and localizable.
2. Ship a dedicated RGBA **milk and tins in wire basket** asset for Running Low and its report.
3. Ship a dedicated RGBA **olive oil/pasta/tins in wooden crate** asset for Add Items and its sheet.
4. Replace Cook Now's sticker-outline skillet with the existing `home_widget_cooking` artwork.
5. Replace Cook Later's sticker-outline calendar with the existing `home_widget_planning` artwork.
6. Apply one approved semantic alias/palette policy to recipe destination artwork so the same
   My Collection/Cook/Past concept cannot revert to sticker art in Grocery support cards.
7. Change legacy Vegetables navigation to `inventory_category_produce` and Expiring Soon navigation
   to the dedicated reference calendar, using natural-edge aspect-fit cutouts and themed text.
8. Make Grocery meal fallback artwork stable by semantic role, never `hashValue`; prefer the real
   saved recipe photo when present and do not invent an unrelated dish photograph.
9. Route every owned decorative image through `StockedKitchenArtwork` with bounded prepared image
   reuse and a deliberate missing-art placeholder. Keep intrinsic aspect ratio, decorative
   accessibility hiding, and visible-layout stability while loading.
10. Add a deterministic artwork contract check: approved names resolve, dedicated action art is
    RGBA, dimensions are positive/bounded, reference atlas is not a live renderer input, and alias
    mappings do not accidentally map food photos or app icons. Preserve the source-pixel originals.

Additional art requiring new generation, not a safe subject-preserving swap: antique protein
selection, edible-leftovers container, bronze appliance/freezer/pantry hero, and natural-edge
versions of recipe-book/past-meal compositions. Root `Icons.xcassets` cannot supply these: sampled
protein/produce/leftovers/breakfast icons are glossy 3D emoji, a different style again.

## Preserve real images and validation limits

Publisher recipe photographs, user inventory photos, scanned products, receipt images, QA evidence,
and alternate app icons are not decorative style mistakes. Preserve their actual bytes, attribution,
cache policy, and domain identity. Apply consistent frames/backgrounds around them rather than
generating substitute evidence or substituting a generic dish.

No images, Swift files, project memberships, or user data were edited by this audit. No simulator,
physical-device UI test, or visual pixel-diff run was performed. New generation must be inspected for
real alpha (not a baked checkerboard/white matte) and checked on both theme surfaces before claiming
reference fidelity. Updating three action pictures alone is not proof that every screen matches.
