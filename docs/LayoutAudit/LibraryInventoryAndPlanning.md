# Stocked library, inventory, grocery and import layout audit

Source audit performed September 9, 2026. Scope: visible page/sheet composition, card bounds, intrinsic text sizing, grid sizing, padding ownership, scrolling and touch targets. This is not physical-device verification. Root agent owns the shared layout primitives, integrated builds and approved iPhone/iPad simulator inspection.

## Findings repaired

- Recipe collection, Web/Online browse, Quick Picks, source recipe grids, Inventory categories/icon grid, Home action grid and Recipes destinations now share `StockedEqualHeightGrid`. A short card fills the tallest sibling's row; later rows retain their own natural height. Recipe metadata surfaces expand with the row. Large text follows the shared column policy.
- Removed Quick Picks' fixed 32-point title box, which clipped longer and enlarged titles.
- Ingredient picker categories use adaptive, equal-height cards instead of three fixed narrow tracks. Category labels wrap fully.
- The quantity editor no longer treats stepper/unit/label/remove button as independent grid cards. Quantity + unit and units-per-container are coherent rows with 44-point controls and a wrapping fallback.
- Inventory item/edit/add/browse/detail/pairing sheet content and headings align to 20-point gutters instead of mixed24/28. Recipe portions uses the same20-point alignment. Create Recipe section headings now align with their panels and the photo toolbar no longer has a second horizontal gutter.
- Removed redundant110-point Grocery/Inventory/expiry footer gaps and120-point reconciliation footer. Root shell/tab bar or safeAreaInset already reserves action space. Inventory's collection insets now use a12-point bottom buffer, matching empty state.
- Barcode confirmation, duplicate recipe review, missing ingredient choices, duplicate purchase review and post-cook Inventory review can scroll through their entire content at medium height and large text. No clipped pinned explanatory header/button stack.
- Receipt instructions now scroll on compact-height/large-text containers. Scanner landing headers and assistant headers no longer add a hardcoded52-point or duplicate safe-top gap. Assistant close control is44pt. Camera/live-scanner areas remain purpose-built media views.
- Zip-code, manual barcode and AI text fields embedded inside their own panel explicitly use plain text-field style to avoid a second inherited field background/padding.

## File-by-file coverage

| File | Reviewed sections and outcome |
| --- | --- |
| HomeView.swift | Root hero, reference actions, Action Center, widget board, activity sheet, widget gallery/preview. Action Center fixed to shared equal rows. Custom widget grid footprints and intentional illustration sizes retained. |
| InventoryHubView.swift | Hero/appliance/actions, editorial kitchen/category cards, category detail/compact/icons, expiry list, use-first rows. Category/icon grids and footer gaps fixed. Reference action artwork/panel geometry retained. |
| InventoryView.swift | Header/zone/filter/search, empty/seed grid, reused UICollectionView rows, split detail pane, toasts. Empty/list footer gaps fixed; transient toast clearance intentionally retained. |
| InventoryItemSheets.swift | EditItemSheet, AddItemSheet, IngredientBrowserSheet, ItemDetailPopup, ExpiryDateRow, IngredientPairingsSheet. Gutters unified and edit quantity controls reorganized; list/detail content already scrollable. |
| InventoryDetailsSheet.swift | Zone cards, reservations, shortages, low/out/expiring sections, nested edit. Already scrollable with20pt gutter and shared form width; no fixed text height. |
| InventoryUpdateReviewView.swift | Post-cook review rows, empty state, apply/skip. Whole-form scroll fixed. |
| InventoryChangeProposal.swift | ReconcileSheet and change rows only (data policy untouched). Redundant120pt bottom gap removed; pinned Apply uses safeAreaInset. |
| InventoryViews.swift | Live inventory zone/card, receipt review, stash. Live rows naturally size; Stash and LiveInventoryZone have no production call sites, so legacy/demo layout not promoted or changed. |
| InventorySpatialView.swift | Zone pager/grid. Only preview/no production call site; fixed320pt demonstration pager noted as unreachable legacy and left unchanged. |
| IngredientFormViews.swift | IngredientFormRow/nutrition, picker, detail form. Adaptive equal category cards; detail gutters aligned. |
| GroceryListView.swift | Active editorial Grocery, trip card/store picker, weekly meal rails, list/suggestion cards, legacy presentation, hand-written scanner. Removed duplicate footer padding. Store-change behavior preserved. Camera overlay intentionally fills view. |
| GroceryStoreFinderView.swift | ZIP/location search, results/list/map and embedded mode. Plain embedded ZIP field fixed. Map's240pt media viewport retained; embedded mode avoids nested scroll. |
| RecipeVaultViews.swift | Recipe hub/hero/destinations, rails/search/dropdown, My Collection, duplicate merge sheet, past meals, preview/list/collections. Equal destinations/collection rows; whole merge sheet scroll. Preview width300 is system context-menu preview only. Disabled `if false` legacy hub grid not changed. |
| UserRecipeViews.swift | Shared card/detail, photo, ingredients, cook/nutrition, substitutions/tips. Card surfaces fill equal row; detail image220pt is intentional artwork viewport, full text naturally wraps. |
| WebRecipesView.swift | Search/filter/results/card, recipe detail, steps/stat/info rows, source picker and URL import. Equal adaptive grid/cards. Detail image260pt retained; source/URL sheets already scrollable. |
| OnlineRecipesView.swift | Browsing/filter state, cards, filter sheet, detail. Equal adaptive grid/card surfaces. Metadata/allergen facts still wrap; no hidden or dropped fields. |
| QuickPickListView.swift | Empty/recipe results. Equal adaptive grid; removed32pt title clipping; aligned20pt gutters. |
| SourcesBrowserView.swift | Source list, source recipe results, Drinks sections. Source grid shares equal rows/theme surfaces. Horizontal Drinks artwork rail retains96pt image size. |
| FoodsAndMoodsViews.swift | Food/mood category and option pages, recipe handoff, flow/tag rows, unstocked sheet. Removed arbitrary vertical spacer distribution on Foods; heading28pt,20pt gutters; missing-item sheet scrolls. Shared illustrated row artwork remains intentional. |
| CreateRecipeView.swift | Imported-content review, photo, fields/ingredients/steps, metadata/dietary, attachments, save. Aligned section headings and removed double photo-toolbar gutter.200pt photo picker is an intentional media surface. |
| RecipeCreateOptions.swift | Add options, URL, screenshots, manual text. All scrollable; action rows use natural text height and20pt gutters. Screenshot upload panel's generous media affordance retained. |
| RecipePortionsEditSheet.swift | Ingredient status, amount controls, Add Pantry, Done, nested add.20pt gutters aligned; existing scroll list retained. |
| RecipeSubstitutionPickerSheet.swift | Candidate/notes/ingredient alternatives, confirmation. Scrollable,20pt gutters; naturally varying content rows retained (single-column detail, not peer grid cards). |
| RecipeBrowserView.swift | Web content, URL toolbar, find/recent menu, progress/import/errors. Existing bounded adaptive scrolling chrome retained; WebKit owns media/page scrolling. |
| RecipePredictiveTextField.swift | Field/suggestions/autofill banner. Already uses bounded horizontal suggestion rails and44pt targets; latest performance cancellation preserved. |
| RecipeCatalogImportView.swift | CSV selection/progress/error Form. Native Form sizing, no hardcoded field/card dimensions; shared boundary theme retained. |
| RecipeMigrationView.swift | Migration file list, warning/review rows and undo. Scrollable20pt content, naturally growing cards; no edits needed. |
| RecipeMigrationReview.swift | Reviewed for nested view ownership; model/draft conversion only, no page geometry. |
| PortableRecipeFilesView.swift | File selection, preview/review/metadata/export actions. Scrollable20pt layout and44pt controls; no edits needed. |
| RecipeCreditsView.swift | Publisher/source/license/attribution rows. Natural text, full available width; no edits needed. |
| CooklangRecipeConnectionView.swift | Shared connection-panel integration and draft sheet. Styling parameters supplied from session; shared reusable panel owns scrolling. |
| AIInventoryScanView.swift | Proposal header/rows and apply/cancel. Gutters aligned20pt; existing lazy proposal scroll preserved. |
| AIInventoryAssistantView.swift | Assistant header, freeform field, examples, apply/scan flows. Removed duplicate safe-top gap,44pt close target, plain embedded field. |
| AIRecipeGeneratorView.swift | Header, prompt/ingredients, choices/servings/results. Same header/field fixes; visible recipe hub's disabled AI entry retained. |
| ReceiptScannerView.swift | Camera/instructions/processing/review/completion, review rows, archive. Instructions scrolling/compact header and aligned review CTA. Physical-camera viewport/shutter sizes intentionally retained. |
| BarcodeScannerView.swift | Live/permission/denied/simulator/manual, confirmation, bulk summary, expiry camera. Plain manual field, compact landing header, scrollable confirmation. Scanner media sizes retained. |
| PurchaseDedupReviewView.swift | Evidence/skip-merge-keep chips, clean summary, apply/cancel. Whole-form scroll prevents header/action clipping. |
| UIKitBridge/LiveScannerView.swift and DocumentScannerView.swift | UIKit scanner adapters, no custom card/page layout; system camera/scanner controller geometry retained. |

## Regression checks supplied

`StockedTests/LayoutConsistencyTests.swift` covers narrow-sheet column minimum clamping; larger text reflow and accessibility one-column choices; rendered shared rows at320 and768 points; equal sibling geometry,12pt row/column gaps, independent row heights, trailing partial-row width; legacy three-action row column inference. Updated the obsolete grid-column-count assertion in AdaptiveUIFoundationTests to match the new accessibility policy. Both test files parse successfully; root must execute on simulator.

Swift frontend parse passed all24 changed app files; `git diff --check` passed before handoff. No simulator or app build was run by this agent. Live camera, personal-data-dependent workflows and device frame rate are not claimed verified.


## Complete-inventory follow-up

Compared the complete `209` Swift view-bearing file inventory with the three domain ledgers and root shared infrastructure. `/tmp/stocked-view-coverage.tsv` gives one owner for every file, with no unassigned files: library63, sheets89, cook34, root shared23. These are source-review counts, not a claim that every data-dependent workflow was visually exercised. Source files outside the inventory (model-only files, preview stubs and scanner adapters) are recorded above when reviewed. Cook confirmed its11 extra files; sheets confirmed its19 extra files.

| Additional file | Reviewed sections and outcome |
| --- | --- |
| DatabasesView.swift | Browse/search/category tabs/detail; CustomSubstitutionSheet and AddAbbreviationSheet. Shared search field replaces nested custom field. Both editors scroll fully and their panel fields use plain style. |
| CooklangConnectionPanel.swift | Endpoint disclosure, query/results/pagination, selected result/private import review. Shared iOS/Mac component is already scrollable, content-capped720pt with20pt gutters, natural text and44pt actions. No layout edit. |
| MealPlannerView.swift | Header/list/calendar toggle, calendar cells, plan sheets, summary and toasts. Toggle no longer forces text into52×44pt; it keeps those as minimums. Header aligned20pt. Toast's130pt clearance intentional. |
| GroceryCartHandoff.swift | Retailer rail, cart rows, empty list and Open All footer. Bounded native list scrolling and natural-height actions. Empty-state spacers intentional, no card grid. |
| MealPlanToolsView.swift | Repeat meals, templates, export, scheduling tools and cards. Whole page scrolls with20pt gutter; single-column cards naturally fit content. |
| ShelfScanView.swift | Photo selection, loading, candidates and Add. Already one scroll container, natural rows. Photo picker/scanner content intentionally owns media sizing. |
| InventoryExporter.swift | ExportDataButton system menu only; no page/card geometry or changes. |
| QuantityInputView.swift | Natural input, count/container and per-item quantity, compact NaturalQuantityField. Reflow structured controls vertically for large text/narrow layouts; picker width now minimum; plain compact panel field avoids nested padding. |
| MealPrepView.swift | Planned recipes/prep lists and action overlays. Existing rows size naturally;100pt transient-toast clearance is deliberate, not a permanent footer gap. |
| PlanAheadEditors.swift | Template, repeat rule, scheduled meal, entry, date and recipe-picker editors. Shared editor shell already scrollable/capped680pt. Plain custom-panel title/ingredients fields remove inherited double padding. |
| CuisineBrowseView.swift | Cuisine list and recipe results. Result cards now use shared adaptive equal-height rows. |
| StoreLayoutLearning.swift | Store name, learning status, walking-order list, active trip and Finish/Cancel. Native List sizing;22pt column is a short ordinal marker, not a text content box. |
| RecipeBudgetStatus.swift | Conditional budget banner only. Natural wrapped explanation, no fixed-height text, no edits. |
| WeekMealPlannerView.swift | Day cards, meal rows, add/type editor and planned-meal handoff. Inline meal-name field uses plain style inside its custom panel; native menu/segmented controls retained. |
| SocialImportView.swift | Import URL, screenshot/video preview, source attribution and review/results. Whole page scrolls;190pt media preview intentional. |
| RecipeCSV.swift | Removal-review List, ambiguous matches, unmatched rows, error/empty state, confirmation and remove bar. List remains scrollable with action footer sized to content. No title/description height caps. |
| SmartKitchenView.swift | Substitution tool/diet toggles and nutrition result cards. Toggles reflow for large text; four fixed horizontal macro cards now use equal adaptive rows and fill sibling height.20pt gutters. |
| IngredientIntel.swift | IngredientActionsButton and contextual conversion/substitution menu. Menu-only wrapper, no new page or fixed card dimensions. |
| PlanAheadView.swift | Plan timeline/templates/rules tabs, empty states, template/rule cards and editor sheets.20pt ScrollView content with natural cards; no edit. |
| MealPlannerSubViews.swift | RecipePickerSheet, meal-detail/planned-meal rows and missing-ingredient review. Removed40pt blank footer from recipe selection (16pt buffer); remaining content natural and scrollable. |
| ReorderSoonView.swift | Reorder cards, status/add actions, empty explanation. Reduced80pt empty-state top gap to24pt vertical spacing and20pt text gutters. |
| MultiStoreViews.swift | Store-selection system menu and per-store transfer footer. Natural labels/full-width action; no grid or fixed text height. |
| SmartCookbookViews.swift | Smart cookbook rules/Form, empty state and recipe results. Native scroll/Form and single-column lazy rows; no layout changes. |
| PantryAuditView.swift | Inventory check/audit rows and follow-up flow. Removed40pt blank footer,16pt buffer retained. |
| StarIngredientRecipesView.swift | Shell results header/Refresh, loading/empty states, recipe rows and navigation. Natural text rows,62pt artwork only; status badge remains compact. No fixed-height card text. |
| BrandPriceView.swift | Conditional brand/store/price metadata. Hidden when no data; natural text with vertical wrapping. Inline capsule deliberately compact, no card sizing changes. |
| CustomRecipeSources.swift | Source manager List/add form, discovery rows and configured sources. System list/form owns scrolling;60pt emoji input is a short symbol field, not a recipe title/search box. |

The follow-up changed10 additional app files. Swift frontend parse passed these plus both regression test files. The current selected-tab test now asserts the semantic accent tokens used by TabBarView, removing obsolete expectations for the old charcoal selected-fill helpers. No builds or simulator runs by this agent; root performs integrated validation. The complete inventory's UIKitBridge/CollectionGrid and shared theme/layout/image wrappers belong to root's final review.
