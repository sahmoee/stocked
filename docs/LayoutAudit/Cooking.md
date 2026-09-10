# Stocked Cook and Finder layout audit — September 9, 2026

This is a code-level structural audit. Simulator screenshot collection is implemented in
`StockedTests/LayoutVisualAuditTests.swift`; the root agent owns build, execution and actual
image review. Syntax parsing succeeded; that is not an app build or visual sign-off.

## Shared changes

- Start With Something and Finder use the shared lazy equal-height-row grid. Card surfaces
  fill the measured row height, preserving stable model identities and lazy collection work.
- Start With Something reserves three title lines in compact multiple-column summaries;
  full names remain accessible, and single-column accessibility/narrow layouts show full text.
- Redundant terminal 20/24-point spacers were removed from Cook shell content. StockedShell
  remains the single owner of tab/safe-area bottom clearance.
- Photo cards keep intentional artwork/media baselines but no longer cap text-containing
  card height. The actual content may grow at larger text sizes.
- Cook Later sheets receive the shared presentation boundary, one content gutter/bottom
  padding, and plain embedded inputs where the parent owns the input surface.

## Reviewed files and surfaces

| File | Pages/sheets reviewed | Result |
| --- | --- | --- |
| StartWithSomethingView.swift | Header/search, idea entry, expiring/protein/other inventory groups | Fixed centered unequal tile surfaces and uncontrolled five-line compact names. Standard three-line title slots; full-width accessible rows. |
| CookHubView.swift | Cook Hub, resume/presence sections, Cook Now Home and all dashboard states/pathways | Removed viewport-minimum/spacer distribution and stacked inset gaps; adaptive dashboard metrics; shared primary/secondary buttons; reclaimed excessive empty-state button inset. |
| CookComponents.swift | Illustrated hub, hero/action/category/intelligence/recipe/planner/prep cards; chips/search/step selectors; empty/loading/error states | Illustrated hub stacks in narrow/accessibility layouts. Hero/action/category text containers use minimum rather than fixed height. Media and icon geometry intentionally bounded. Compact search already embeds a plain field. |
| CookLaterCommandCenterView.swift | Plan/shop/prep workspace; Add Meal Source, Command Editor, Recipe Picker, Web Picker, Meal Detail, Substitution, Suggestions, Month Calendar sheets | All eight sheets use shared presentation surface; removed duplicate bottom padding; meal and ingredient fields no double surface; servings controls reach 44 points. Seven-column month calendar intentionally preserves weekday semantics. |
| CookLaterWorkspaceView.swift | Current wrapper and planning-model definitions | Delegates to audited Command Center. No separate active layout. |
| CookLaterFlows.swift | Stable Cook Later navigation destination | Delegates to audited workspace. |
| CookTabView.swift | Legacy Cook tab | Neutralized stub with no active view tree. |
| CookConciergeView.swift | Legacy concierge | Neutralized file; no separate active page. |
| CookNowFlows.swift | Build Around Food, Match My Mood, Recipe Results | Shared growing category/recipe components; removed redundant end spacers. Scrolling chip choices preserve long labels. |
| CookNowPrep.swift | Prep First checklist/loading/empty/action states | Natural-height single-column checklist; removed redundant end spacer. |
| CookNowResultsView.swift | Tiered ready/review/almost/more results and loading/empty/error paths | Shared natural-height recipe rows; removed redundant end spacer. Existing asynchronous classification remains untouched. |
| CookWorkspaceDestinations.swift | Makeable Now, Use Something Up | Natural-height full-width action/item rows; removed redundant end spacers. |
| CookRightNowView.swift | Ranked stocked-meal list and expiry rail | Single-column natural-height cards; removed redundant end spacer. 120-point photographic baseline remains intentional. |
| CookAheadAndFinish.swift | Cook Ahead tracker/guidance, Finish & Serve list and empty state | Natural-height rows/timeline; removed redundant end spacers. Stage connector sizes are intentional. |
| CookingFlow.swift | Recipe Overview, Cooking Flashcards, step rows, Time to Plate, ingredient deduction, rating/leftovers, mid-cook substitutions | Flashcard ingredient sidebar depends on actual width, not iPad identity. Step card background grows with text. Deduction sheet uses shared boundary/44-point portion target. Rating leftover choices stack for accessibility; duplicate field padding removed. Artwork-only heights remain intentional. |
| CookingIntentView.swift | Intent list, effort rail, Add Scope sheet | Removed end spacer; entire Add Scope content scrolls, including long anchor header; shared sheet surface and explicit Close control. |
| CookingMethodComparisonView.swift | Method cards, equipment rail, expanded comparisons | Statistics/action controls stack at accessibility/narrow widths; shared action geometry; details can stack; removed end spacer. |
| CookingSessionSummaryView.swift | Completion/paused recap, sides and suggested next steps | Natural-height full-width content. Small icon badges intentional. No fixed-height text/grid defect found. |
| FullScreenCookView.swift | Fullscreen step, voice states, progress, back/next/finish | Step text has bounded viewport with scrolling when necessary. Progress strip can scroll. Action heights are minimums. Uses active theme rather than hardcoded dark-only canvas. |
| PreparationDiscoveryView.swift | Preparation cards, loading/empty/context states | Single-column content with natural-height descriptions; removed end spacer. 130-point artwork is intentional. |
| ReadyToCookView.swift | Ready summary/header/list, empty states, recipe metadata | Header stacks for accessibility/narrow widths; action uses shared secondary style. Recipe rows remain intrinsic-height single-column content. |
| SmartRecommendationView.swift | Tonight's Pick, supporting reasons, swaps, retry/empty/exhausted states | Content-height cards and themed shell; removed redundant end spacer. Generating/empty progress padding is intentionally limited to those states. |
| RefreshKitchenView.swift | Kitchen-confirmation list, progress and completion state | Natural-height single-column review rows; removed redundant end spacer. Completion illustration spacing intentional. |
| RecipeFinderView.swift | Seven quiz sections, review, results, filters sheet, sort sheet, loading/empty/error | Shared equal-height option/result grids, accessibility-aware columns, no double padding on option minimum height, shared primary actions. Skeleton columns match actual results. Metadata remains available; no ranking/service behavior changed. |
| RecipeFinderPreview.swift | Publisher preview, original-site action, import action, error state | Both actions reuse shared controls. Existing full-width presentation and scroll remain; artwork media height intentional. |

## Simulator artifact coverage

`LayoutVisualAuditTests/testCapturePagesAndSheetsForVisualReview` hosts actual views in a
real simulator UIWindow with DeviceAdaptiveRoot and the app's shared theme. It captures
standard and accessibility3 variants on the executing phone/tablet screen, plus a dark
inventory-entry view. Synthetic names mirror the reported long-title spacing case.
The harness also includes Add/Edit Item, Edit Profile, Dietary Profile, Import Kitchen,
Ingredient Deduction, Toolbox, Settings and Statistics. It attaches images and writes
PNG copies beneath the simulator app's temporary StockedLayoutAudit directory.

The harness refuses authenticated/household simulator state, restores its original inventory
and appearance, and pauses full-catalogue hydration. It invokes no save/import/destructive
button. Images use committed-layer capture; glass/live-media fidelity can differ from the
interactive device compositor. Captured images require manual review and do not prove
navigation, keyboard, VoiceOver or actual device scrolling performance.

## Additional cook-adjacent presentation audit (11 files)

| File | Reviewed presentations / findings and action |
| --- | --- |
| `CookConsumption.swift` | `CookCompletionSheet` scrollable List and footer reviewed. Primary pantry action now shared button style; list background follows active sheet surface. `.stockedPresentationSurface(width: .form)` establishes sheet sizing/theme. Proposal building and mutations untouched. |
| `HouseholdCookCoordination.swift` | `HouseholdCookingCard` header, claim labels and member names previously competed in one row at large text. Header/task layouts now stack for accessibility/narrow layouts with no flexible spacers in the vertical variant; existing 44-point task targets retained. Coordination store untouched. |
| `SubstitutionEngine.swift` | `SubstitutionRow` title/source/diet flags adapt vertically at accessibility/narrow widths; combined accessibility description retained. Substitution engine untouched. |
| `CompoundingPrepView.swift` | Removed terminal shell spacer, added 44-point minimum action target, readable active-theme text and adaptive ingredient/badge header. Single-column opportunity cards already expand for text. Media-only emoji sizes retained. |
| `SubstitutionReviewSheet.swift` | Previously fixed header and Done button consumed medium detent while only cards scrolled. Entire sheet now scrolls, with shared surface, primary action, 44-point swap controls and adaptive text/action rows. Classification unchanged. |
| `CookSessionPersistence.swift` | `CookSessionResumeCard` formerly forced a dark card in light themes. Uses current card/text theme; header/actions stack for large text/narrow cards and both controls meet 44-point target. Persistence untouched. |
| `PlannedMealCookTransition.swift` | Whole transition sheet scrolls at short detents/large text, removing flexible terminal spacer; shared form presentation surface. 40-point artwork tiles remain because whole padded row is interactive. Meal transition semantics unchanged. |
| `MultiRecipeTimeline.swift` | Empty state now scrollable with compact gutters/shared primary action; timeline time labels use minimum width and adaptive vertical rows so AM/PM/large text is not clipped in 58 points. AddTimelineDishSheet step entry bounded to 3–8 visible lines instead of unbounded editor growth; form already scrolls. Pure scheduling engine untouched. |
| `BeforeYouStartView.swift` | Removed terminal spacer, equipment status Menu now meets 44-point target, shared primary Start action. Checklist cards already have expandable text and no fixed content heights. |
| `HandsOffOpportunityView.swift` | Removed terminal spacer; side-selection sheet's complete heading/list/Done content now scrolls, with shared button/sheet surface. Options' 40-point artwork intentionally retained. |
| `ReservationOverrideSheet.swift` | Removed terminal spacer and normalized one content inset; shared form surface. Trailing amount/date text wraps rather than requiring unbounded intrinsic width. Gold primary button now uses dark foreground for contrast. Existing all-content scroll and grouped ingredient rows retained. |

All eleven additional files passed Swift frontend syntax parsing. This is source-level coverage, not a claim that every state has been visually exercised. Root owns simulator builds, attachments and review.
