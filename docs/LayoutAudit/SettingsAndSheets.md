# Stocked miscellaneous pages and sheets layout audit — 2026-09-09

Scope: code review of presentation roots, scroll ownership, repeated card/choice geometry, text constraints, spacers and padding. The list below is a structural layout audit, not a claim that every branch was visually exercised. Root owns iPhone/iPad runtime checks and shared layout primitives. No user data, service configuration, or QA outcome records were changed.

Validation: Swift parser checks passed for changed sources; repository whitespace checks passed. Full app build and simulator screenshot verification are owned by the root agent.

| File | Review / change |
| --- | --- |
| `Stocked/AppChangelog.swift` | Reduced the version-history trailing blank filler from 40 to 16 points; change entries and artwork slots preserved. |
| `Stocked/AppIconManager.swift` | Reduced 30-point trailing filler to 16. Fixed 66-point thumbnails remain intentional icon previews, with labels below them. |
| `Stocked/AppWideExperience.swift` | App Experience uses themed List sections and natural-height setup/activity rows; no card-height override needed. |
| `Stocked/CommunityPriceWatchesView.swift` | List cards use natural-height text, 44-point actions; editor is a Form. Preserved local request state and actual prices. |
| `Stocked/CommunityPricesView.swift` | Scrollable, themed, natural-height provider result cards and explicit lookup controls; no fixed card dimensions. |
| `Stocked/ContainerLabels.swift` | Scrollable label list/detail and Form editor. White printed-label preview and square QR geometry are intentional output-preview exceptions. |
| `Stocked/CostSplitting.swift` | Themed list/detail Form and natural-height expense rows; currency/data ownership unchanged. |
| `Stocked/CrowdShareToggle.swift` | Small Toggle label inherits shared app control style; no forced height or page filler. |
| `Stocked/DailyBriefNotificationSettingsView.swift` | FIX: long non-scrollable root VStack is now inside a size-aware ScrollView; lower reminder controls remain reachable. Tightened duplicated top/subtitle gaps, removed stretch Spacer. |
| `Stocked/DailyBriefView.swift` | Inspected Daily Brief overlay bounds and ExpiringItems destination rows. Limited-height overlay is intentional overlay scrolling. Root/cooking audit also covers expiry/inventory route styling; no behavioral change here. |
| `Stocked/DataStorageView.swift` | Settings uses Form with natural-height usage and backup sections; no nested card grid. Cache scans and import data untouched. |
| `Stocked/DeliverySettingsView.swift` | Scrollable settings and connection review cards; no fixed card geometry. Authentication/action behavior untouched. |
| `Stocked/DietaryProfileView.swift` | FIX: shared StockedSearchField for brand search, equal-height diet/allergen and brand-preference controls, natural wrapping, at least44-point targets. Removed trailing filler rows. |
| `Stocked/DrawerSettingsContent.swift` | FIX: legacy HouseholdSync sheet becomes scrollable; Preferred Store replaces nested forced320-point finder viewport with an explicit finder destination; store choices wrap and retain44-point targets. |
| `Stocked/EditPreferencesView.swift` | Themed List settings naturally expand; retained existing selection semantics, save action, and kitchen-goal sheet. |
| `Stocked/EditProfileView.swift` | FIX: removed private GeometryReader/alignment-guide/DispatchQueue height feedback layout and reused StockedFlowLayout. Reduced field spacing24→16 and bottom60→20; chips preserve44-point targets. |
| `Stocked/EmergencyPantry.swift` | Scrollable readiness rows with native tools; no forced per-item heights. |
| `Stocked/EventPlanner.swift` | Scrollable collection and Form/new-event/dish editors; empty-state fill is conditional only. Event cards retain natural text height. |
| `Stocked/FamilyProfiles.swift` | Scrollable people list and Form eater editor; natural labels, no fixed card heights. |
| `Stocked/FreeKitchenConnectionsView.swift` | Shared ConnectionCanvas scrolls with a readable max700-point form; setup editors and import reviews remain scrollable and themed. Preserved all credential boundaries. |
| `Stocked/FreeKitchenHubView.swift` | Scrollable navigation hub uses ToolboxCards with minimum44-point action labels; no fixed maximum heights. |
| `Stocked/GardenHarvest.swift` | Scrollable harvest sections and Form editor; retained conditional full-area empty state and produce icon slots. |
| `Stocked/HouseholdViews.swift` | FIX: shared HHScreen gains consistent20-point bottom inset and size-based bouncing; large60-point conflict empty-state top filler becomes24-point vertical. Reviewed all household destinations sharing this container. |
| `Stocked/HouseholdSharingUI.swift` | Reviewed presentation/bridging boundary; system sharing UI is intentionally system-managed. |
| `Stocked/KitchenActivityView.swift` | Scrollable event cards and natural-height rows; no constrained card heights. |
| `Stocked/KitchenAssistant.swift` | Scrollable suggestion cards with natural-height copy; no layout-sizing state loop. |
| `Stocked/KitchenCheckView.swift` | Shared shell and cooking result rows; code scanner found no fixed text height. Delegated cooking root handles classification/progress routes. |
| `Stocked/KitchenStatsView.swift` | FIX: matched stat pairs now use shared equal-height rows; each stat surface fills its assigned row height with top-aligned contents. |
| `Stocked/KitchenToolboxView.swift` | FIX: Toolbox grids now share equal-height rows and wider-window column adaptation; complete title/subtitle visible, card surfaces align at their top edges. |
| `Stocked/KitchenTransferView.swift` | FIX: QR/iCloud/import choice sheets now scroll only when needed; removed stretch spacers and excessive gaps, QR image uses bounded flexible width, main transfer trailing gap is16. Actions/data flow unchanged. |
| `Stocked/KitchenWrappedView.swift` | FIX: recap statistics use equal-height rows with top-aligned interiors; removed dedicated30-point trailing filler in favor of20-point inset. |
| `Stocked/LeftoversLifecycle.swift` | Reviewed scrollable leftover cards, action grid and Form add sheet; uses InventoryEditorialCard. No persistence/expiry changes. |
| `Stocked/LoginView.swift` | FIX: readable max480-point form scrolls for keyboard/large text; eliminated vertical spacer centering and52-point logo gap; guest control uses shared type/minimum height. Native Apple sign-in54-point slot retained. |
| `Stocked/MoneySavedView.swift` | FIX: metric cards now equal-height, top-aligned; empty-state top80-point gap reduced to24-point vertical padding. |
| `Stocked/NutritionDatabase.swift` | Reviewed RecipeNutritionSummary UI; collapsible body/rows natural-height, narrow fixed dividers intentional. Nutrition data and aggregate cache not modified. |
| `Stocked/OnboardingQuiz.swift` | FIX: question choice grids use shared equal-height rows, labels grow naturally, controls minimum44 points. Existing scrollable card, gesture sequencing and profile persistence retained. |
| `Stocked/OpenKitchenCreditsView.swift` | Themed Form/static credits; no forced text/card height. |
| `Stocked/PremiumManager.swift` | Reviewed HouseholdPaywallView only: ScrollView with readable content and native purchase behavior. StoreKit logic not modified. |
| `Stocked/PreservationPlanner.swift` | Scrollable guide collection/detail; fixed full empty-area container only conditional empty state, not repeated cards. |
| `Stocked/ProfileAvatar.swift` | Image/emoji circle sizes intentionally follow requested avatar size; picker remains separate. No generic text card bounds. |
| `Stocked/QAAIOverrideView.swift` | Themed Form options, no fixed text card geometry. QA action boundaries retained. |
| `Stocked/QACheckTickets.swift` | QACheckTicketSheet uses natural-height section content; no giant search or card frames. |
| `Stocked/QADuplicateFinder.swift` | QA recurring ticket list retains icon/count slot width34; text column natural height. |
| `Stocked/QAEntry.swift` | FIX: unlock pane scrolls at larger text/keyboard; secure field opts into plain text styling to avoid duplicated inset/backplate; reduced24→20 padding. |
| `Stocked/QAHUD.swift` | HUD/zero-sized capture anchor and tiny status visuals are intentionally overlay geometry; no user page card sizing. |
| `Stocked/QAIssueReporter.swift` | Ticket list/detail/edit sheets use scrolling native containers; attachment preview max220-point geometry is intentional media. |
| `Stocked/QAMemoryWatch.swift` | Memory chart90-point frame and GeometryReader are intentional plot geometry; surrounding log content scrolls. |
| `Stocked/QAModeView.swift` | Reviewed QA dashboard/finding/report presentation structure; lists and report scroll containers natural-height. No test states altered. |
| `Stocked/QARunLog.swift` | Run-history List sections/rows; no forced card heights or blank spacers. |
| `Stocked/QASyncDestinations.swift` | Settings Form fields and explanatory copy; no fixed card dimensions. Credentials unchanged. |
| `Stocked/QASyncQueue.swift` | Native queue List, sections and toolbar; small status icon widths intentional, no oversized text field wrapper. |
| `Stocked/RegionalFoodData.swift` | Regional reference browse uses natural-height scrollable cards; data definitions unchanged. |
| `Stocked/SettingsPageView.swift` | FIX: removed standalone30-point bottom blank element, retained12-point stack spacing and symmetric content inset; accordion ownership preserved. |
| `Stocked/SettingsSections.swift` | Reviewed shared groups/aligned row labels; intrinsic-height section controls and existing minimum44-point targets. Segmented picker remains native; no provider preference changes. |
| `Stocked/StockGoalsSetupView.swift` | FIX: staple chips now equal-height rows and at least44-point control height while preserving natural text wrapping and explicit-save behavior. |
| `Stocked/StockedHealthView.swift` | Themed List metrics/settings; diagnostics log sheet scrolls; no fixed body card heights. |
| `Stocked/StockedQAView.swift` | Reviewed QA gate, section home and checklist List flows. No fabricated QA validation or ticket status changes. |
| `Stocked/StockedRemoteConfig.swift` | Remote banner has intentional dismiss icon slot and natural text content; no repeated grid. |
| `Stocked/SyncConflictLog.swift` | Conditional banner and native conflict review List; natural-height metadata rows. |
| `Stocked/SyncDiagnosticsView.swift` | Scrollable diagnostic cards and rows with natural text height; no forced full-card minimum. |
| `Stocked/TakeoutLog.swift` | Scrollable entry cards/Form editor; conditional empty state retained. Cost values untouched. |
| `Stocked/ThawPlanner.swift` | Scrollable thaw entries, guidance rows and optional empty-state presentation; no repeated fixed-height cards. |
| `Stocked/ToolboxCooking.swift` | Reviewed Roulette, MultiTimer, converter and leftover ideas. FIX: timer cancel/done icons now44-point targets. Roulette140-point staging minimum is intentional to avoid animated result layout jump. |
| `Stocked/ToolboxInsights.swift` | FIX: Pantry Value/Waste Insights/Weekly Review stat rows now share natural row height. Remaining lookup/cost/list cards already natural-height; explicit8-point progress bar geometry retained. |
| `Stocked/ToolboxKit.swift` | FIX: shared stat tile accepts proposed row height and includes equal padding; shared empty-state vertical padding40→24. Common ToolboxCard continues natural height. |
| `Stocked/ToolboxMaintenance.swift` | FIX: achievement grid now equal-height rows with top-aligned surfaces; duplicate-review data logic intentionally unchanged. |
| `Stocked/ToolboxPlanning.swift` | FIX: calendar days40-point fixed height become minimum44-point height, so text can grow. Seven columns and tiny dot/progress chart geometry intentionally retained. |
| `Stocked/ToolboxReference.swift` | Seasonal/storage/shelf-life/snapshot pages have natural-height scroll rows and cards; no fixed body heights. |
| `Stocked/UsageInsightsView.swift` | FIX: summary metrics share equal-height rows and top-aligned surfaces; following detail rows retain natural wrapping. |
| `Stocked/QuizEditView.swift` | FIX: expanded profile option grids use shared equal-height rows with natural wrapping and minimum44-point chips; explicit Save/Cancel preserved. |
| `Stocked/StatsView.swift` | FIX: Kitchen Health labels/explanation moved outside fixed180-point ring; percentage has a minimum-size background ring and natural content growth. Accessible Button replaces plain tap gesture; goals sheet unchanged. |

## Remaining infrastructure and presentation coverage

The following19 files were reviewed after the cross-agent coverage comparison. Four received bounded UI changes and passed Swift parser plus whitespace checks; other entries distinguish infrastructure from real pages.

| File | Review / change |
| --- | --- |
| `Stocked/QATouchTrail.swift` | Infrastructure: zero-size mounts capture touch coordinates and a separate hit-test-transparent overlay draws trails. Fixed coordinates intentionally match touch locations; no page/card content. |
| `Stocked/QAMode.swift` | Infrastructure: QA state and QAScreenModifier recording. No standalone page or card layout in this file. |
| `Stocked/HouseholdSyncProgress.swift` | Transient progress overlay with max320-point card and natural-height status text. Explicit terminal dismissal retained; progress icon size is intentional. No repeated-card geometry. |
| `Stocked/OfflineQueueBadge.swift` | Conditional slim pending-sync strip. Text grows naturally and hidden state occupies no height; callback/poll cadence unchanged. |
| `Stocked/PreviewStates.swift` | Debug/preview fixture wrapper only: chooses appearance and Dynamic Type for previews; no production presentation geometry. |
| `Stocked/QASearchIndex.swift` | QA search destination is a native List with section grouping and native searchable control. No fixed text height or double wrapper. |
| `Stocked/NetworkMonitor.swift` | Connectivity observer plus naturally wrapping conditional OfflineBanner. Invisible state contributes no height; no code changes. |
| `Stocked/QAShakeToReport.swift` | Invisible UIKit mounting bridge and shake events; zero-size footprint intentionally does not occupy page layout. |
| `Stocked/QAIdentityStore.swift` | Tester/device section with native Picker and LabeledContent rows; no fixed card heights. Identity/persistence semantics untouched. |
| `Stocked/Coachmark.swift` | FIX: large-text/short-window guides use a centered scrollable card rather than trying to fit inside the190-point spotlight height estimate. Ordinary spotlight anchors remain intact; card fallback scrolls only when necessary. |
| `Stocked/SuccessView.swift` | Unreferenced except its own preview. Transient auth animation intentionally centers a fixed checkmark artwork; no text-entry or collection surface. Existing session advance not changed. |
| `Stocked/QAAccessibilitySweep.swift` | Native List findings and toolbar actions, natural-height detail copy; the view-tree inspection implementation is not layout state and remains unchanged. |
| `Stocked/QAFloatingBubble.swift` | Separate54-point floating button and zero-size mount are intentional overlay geometry. Modal root already delegates to shared QAUnlockGate, which was fixed earlier in this audit. |
| `Stocked/SwipeToDelete.swift` | Gesture modifier: fixed84-point revealed destructive action zone is intentional swipe geometry; content retains its own natural row height. Gesture semantics unchanged. |
| `Stocked/SplashView.swift` | Intentional centered transient wordmark/tagline, tap-to-skip and timed advance; no cards or editable fields. Theme inherited. |
| `Stocked/QuickAccessMenu.swift` | FIX: QuickGrocery compound field opts into plain styling; FontPicker options now equal-height rows with44-point targets; reduced empty/trailing fillers. Existing grocery/font owners retained. |
| `Stocked/QATapTracker.swift` | Zero-size observation bridge only; no user-facing page content or cards. |
| `Stocked/FeatureFiles.swift` | FIX: legacy URL-import sheet scrolls at compact detents/keyboard instead of pushing Import offscreen; plain styling for compound URL/OCR fields,44-point close targets; action padding moved outside shared button style. OCR list remains independently scrollable; data/import paths untouched. |
| `Stocked/RecipeTextSize.swift` | FIX: recipe text-size choices use equal-height rows; read-aloud target grows26→44 points. Timer state and recipe scaling/storage remain unchanged. |
