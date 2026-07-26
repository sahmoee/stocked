// KitchenToolboxView.swift — Hub for the Kitchen Toolbox suite (39 tools).
//
// UI/UX notes:
//  • Searchable: the search field fuzzy-filters tools by name and subtitle, so all 39
//    tools stay one keystroke away instead of buried in a long scroll.
//  • Haptics: light tap feedback on every tool open (HapticManager).
//  • Accessibility: each tile carries a combined label + hint; layout uses LazyVGrid
//    so off-screen tiles are never built (perf).
import SwiftUI

// MARK: - Tool registry

nonisolated enum ToolboxTool: String, CaseIterable, Identifiable {
    case pantryValue, expiryCalendar, wasteInsights, weeklyReview, lowStockReport, priceLookup
    case budget, batchCook, groceryTemplates, mealCost, dietaryProfile
    case roulette, timers, converter, leftoverIdeas, substitutions, nutrition
    case assistant, cartHandoff, family, leftovers, thawPlanner
    case event, splitCosts, storeLayout, preservation, garden
    case cookTogether, readiness, eatingOut, regional, labels
    case seasonal, storageTips, shelfLife, snapshot
    case duplicates, achievements, pantryAudit
    // New tools (overall improvements #5, #9, #10/#11, #13)
    case savings, reorder, activity, shelfScan

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pantryValue:      return "Pantry Value"
        case .expiryCalendar:   return "Expiry Calendar"
        case .wasteInsights:    return "Waste Insights"
        case .weeklyReview:     return "Weekly Review"
        case .lowStockReport:   return "Low Stock Report"
        case .priceLookup:      return "Price Lookup"
        case .budget:           return "Grocery Budget"
        case .batchCook:        return "Batch Cook Planner"
        case .groceryTemplates: return "List Templates"
        case .mealCost:         return "Meal Cost"
        case .dietaryProfile:   return "Dietary Profile"
        case .roulette:         return "Recipe Roulette"
        case .timers:           return "Kitchen Timers"
        case .converter:        return "Unit Converter"
        case .leftoverIdeas:    return "Leftover Ideas"
        case .substitutions:    return "Substitutions"
        case .nutrition:        return "Nutrition"
        case .assistant:        return "Kitchen Assistant"
        case .cartHandoff:      return "Send to Store"
        case .family:           return "Family"
        case .leftovers:        return "Leftovers"
        case .thawPlanner:      return "Thaw Planner"
        case .event:            return "Events"
        case .splitCosts:       return "Shared Costs"
        case .storeLayout:      return "Store Layout"
        case .preservation:     return "Save It"
        case .garden:           return "Garden"
        case .cookTogether:     return "Cook Together"
        case .readiness:        return "Readiness"
        case .eatingOut:        return "Eating Out"
        case .regional:         return "Regional"
        case .labels:           return "Container Labels"
        case .seasonal:         return "Seasonal Produce"
        case .storageTips:      return "Storage Tips"
        case .shelfLife:        return "Shelf Life Lookup"
        case .snapshot:         return "Pantry Snapshot"
        case .duplicates:       return "Duplicate Finder"
        case .achievements:     return "Achievements"
        case .pantryAudit:      return "Pantry Audit"
        case .savings:          return "Money Saved"
        case .reorder:          return "Reorder Soon"
        case .activity:         return "Household Activity"
        case .shelfScan:        return "Scan a Shelf"
        }
    }

    var subtitle: String {
        switch self {
        case .pantryValue:      return "What your kitchen is worth"
        case .expiryCalendar:   return "See expiry dates on a calendar"
        case .wasteInsights:    return "What gets thrown out, and why"
        case .weeklyReview:     return "Your kitchen week at a glance"
        case .lowStockReport:   return "Everything running low"
        case .priceLookup:      return "Best prices you have paid"
        case .budget:           return "Track monthly grocery spend"
        case .batchCook:        return "Scale a recipe and shop for it"
        case .groceryTemplates: return "Save and reuse shopping lists"
        case .mealCost:         return "Estimate a recipe's cost"
        case .dietaryProfile:   return "Diet and allergens, applied everywhere"
        case .roulette:         return "Can't decide? Spin for dinner"
        case .timers:           return "Run up to four timers at once"
        case .converter:        return "Cups, grams, ounces, and more"
        case .leftoverIdeas:    return "Turn leftovers into meals"
        case .substitutions:    return "Swap an ingredient you're out of"
        case .nutrition:        return "Estimate calories and macros"
        case .assistant:        return "Ask about your kitchen"
        case .cartHandoff:      return "Shop your list at a retailer"
        case .family:           return "Who eats here, and what they avoid"
        case .leftovers:        return "Track portions before they are lost"
        case .thawPlanner:      return "What to take out, and when"
        case .event:            return "Dinner parties and holiday meals"
        case .splitCosts:       return "Split grocery bills fairly"
        case .storeLayout:      return "Your list in the order you shop"
        case .preservation:     return "Freeze, pickle or dry before it turns"
        case .garden:           return "Log harvests into your pantry"
        case .cookTogether:     return "Time several dishes to finish at once"
        case .readiness:        return "How long could you eat without shopping"
        case .eatingOut:        return "Track takeout and restaurant spend"
        case .regional:         return "US/UK names, oven temps, gas marks"
        case .labels:           return "QR labels for mystery containers"
        case .seasonal:         return "What's in season right now"
        case .storageTips:      return "Keep food fresh longer"
        case .shelfLife:        return "How long foods really last"
        case .snapshot:         return "Share your pantry as text"
        case .duplicates:       return "Find and merge duplicate items"
        case .achievements:     return "Badges for kitchen milestones"
        case .pantryAudit:      return "Confirm what is really still there"
        case .savings:          return "What your kitchen habits saved"
        case .reorder:          return "Staples you're about to run out of"
        case .activity:         return "Recent changes and sync status"
        case .shelfScan:        return "Add items from a photo of a shelf"
        }
    }

    var icon: String {
        switch self {
        case .pantryValue:      return "dollarsign.circle"
        case .expiryCalendar:   return "calendar.badge.exclamationmark"
        case .wasteInsights:    return "trash.slash"
        case .weeklyReview:     return "calendar.badge.checkmark"
        case .lowStockReport:   return "exclamationmark.arrow.circlepath"
        case .priceLookup:      return "tag"
        case .budget:           return "chart.pie"
        case .batchCook:        return "square.stack.3d.up"
        case .groceryTemplates: return "list.bullet.rectangle"
        case .mealCost:         return "fork.knife.circle"
        case .dietaryProfile:   return "leaf.circle"
        case .roulette:         return "dice"
        case .timers:           return "timer"
        case .converter:        return "arrow.left.arrow.right"
        case .leftoverIdeas:    return "takeoutbag.and.cup.and.straw"
        case .substitutions:    return "arrow.triangle.swap"
        case .nutrition:        return "flame"
        case .assistant:        return "bubble.left.and.text.bubble.right"
        case .cartHandoff:      return "cart.badge.plus"
        case .family:           return "person.2"
        case .leftovers:        return "takeoutbag.and.cup.and.straw"
        case .thawPlanner:      return "snowflake"
        case .event:            return "party.popper"
        case .splitCosts:       return "divide.circle"
        case .storeLayout:      return "map"
        case .preservation:     return "archivebox"
        case .garden:           return "leaf.circle"
        case .cookTogether:     return "timeline.selection"
        case .readiness:        return "shield.checkered"
        case .eatingOut:        return "bag"
        case .regional:         return "globe"
        case .labels:           return "qrcode"
        case .seasonal:         return "leaf"
        case .storageTips:      return "snowflake"
        case .shelfLife:        return "hourglass"
        case .snapshot:         return "square.and.arrow.up"
        case .duplicates:       return "doc.on.doc"
        case .achievements:     return "rosette"
        case .pantryAudit:      return "checkmark.seal"
        case .savings:          return "banknote"
        case .reorder:          return "arrow.clockwise.circle"
        case .activity:         return "clock.arrow.circlepath"
        case .shelfScan:        return "camera.viewfinder"
        }
    }

    var category: String {
        switch self {
        case .pantryValue, .expiryCalendar, .wasteInsights, .weeklyReview, .lowStockReport, .priceLookup:
            return "Insights"
        case .budget, .batchCook, .groceryTemplates, .mealCost, .dietaryProfile:
            return "Planning"
        case .roulette, .timers, .converter, .leftoverIdeas, .substitutions, .nutrition, .assistant:
            return "Cooking"
        case .cartHandoff, .family, .leftovers, .thawPlanner:
            return "Planning"
        case .event, .splitCosts, .storeLayout, .preservation, .garden:
            return "Planning"
        case .cookTogether:
            return "Cooking"
        case .readiness, .eatingOut, .savings:
            return "Insights"
        case .regional:
            return "Reference"
        case .labels:
            return "Housekeeping"
        case .seasonal, .storageTips, .shelfLife, .snapshot:
            return "Reference"
        case .duplicates, .achievements, .pantryAudit, .activity, .shelfScan:
            return "Housekeeping"
        case .reorder:
            return "Planning"
        }
    }

    static let categoryOrder = ["Insights", "Planning", "Cooking", "Reference", "Housekeeping"]
}

// MARK: - Hub view

struct KitchenToolboxView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    /// Improvement #4 — usage-based ranking, pinning, and a Recent row.
    private let usage = ToolboxUsageStore.shared

    private var filtered: [ToolboxTool] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ToolboxTool.allCases }
        return ToolboxTool.allCases.filter {
            FuzzyMatch.matches(q, $0.title) || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
    }

    /// Improvement #4 — within each category, tools you actually open float to the top.
    /// Untouched tools keep declaration order so a new tool isn't buried before it's been seen.
    private var grouped: [(category: String, tools: [ToolboxTool])] {
        let tools = filtered
        return ToolboxTool.categoryOrder.compactMap { cat in
            let inCat = tools.filter { $0.category == cat }
            return inCat.isEmpty ? nil : (cat, usage.ranked(inCat))
        }
    }

    /// Pinned + recently used, shown above everything else. Hidden while searching (the search
    /// results ARE the answer then) and until there's any history to show.
    private var quickAccess: [(label: String, tools: [ToolboxTool])] {
        guard search.trimmingCharacters(in: .whitespaces).isEmpty, usage.hasHistory else { return [] }
        var out: [(String, [ToolboxTool])] = []
        let favs = usage.favorites
        if !favs.isEmpty { out.append(("Pinned", favs)) }
        let recent = usage.recent()
        if !recent.isEmpty { out.append(("Recent", recent)) }
        return out
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if grouped.isEmpty {
                    ToolboxEmptyState(icon: "magnifyingglass",
                                      title: "No tools match",
                                      message: "Try a different search — every tool is listed by name and what it does.")
                }
                ForEach(quickAccess, id: \.label) { group in
                    ToolboxSectionLabel(text: group.label)
                    toolGrid(group.tools)
                }
                ForEach(grouped, id: \.category) { group in
                    ToolboxSectionLabel(text: group.category)
                    toolGrid(group.tools)
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .stockedScreen()
        .navigationTitle("Kitchen Toolbox")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $search, prompt: "Search tools")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .foregroundStyle(session.accentColor)
            }
        }
        .navigationDestination(for: ToolboxTool.self) { tool in
            destination(for: tool)
        }
    }

    /// One grid, used by both the quick-access rows and the category sections.
    @ViewBuilder
    private func toolGrid(_ tools: [ToolboxTool]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                  spacing: 10) {
            ForEach(tools) { tool in
                NavigationLink(value: tool) {
                    ToolboxTile(tool: tool, isFavorite: usage.isFavorite(tool))
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    HapticManager.light()
                    usage.recordOpen(tool)
                })
                .contextMenu {
                    Button {
                        usage.toggleFavorite(tool)
                    } label: {
                        Label(usage.isFavorite(tool) ? "Unpin" : "Pin to top",
                              systemImage: usage.isFavorite(tool) ? "pin.slash" : "pin")
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func destination(for tool: ToolboxTool) -> some View {
        switch tool {
        case .pantryValue:      PantryValueView()
        case .expiryCalendar:   ExpiryCalendarView()
        case .wasteInsights:    WasteInsightsView()
        case .weeklyReview:     WeeklyReviewView()
        case .lowStockReport:   LowStockReportView()
        case .priceLookup:      PriceLookupView()
        case .budget:           BudgetTrackerView()
        case .batchCook:        BatchCookPlannerView()
        case .groceryTemplates: GroceryTemplatesView()
        case .mealCost:         MealCostView()
        case .dietaryProfile:   DietaryProfileView()
        case .roulette:         RecipeRouletteView()
        case .timers:           MultiTimerView()
        case .converter:        MeasurementConverterView()
        case .leftoverIdeas:    LeftoverIdeasView()
        case .substitutions:    SubstitutionsToolView()
        case .nutrition:        NutritionToolView()
        case .assistant:        KitchenAssistantView()
        case .cartHandoff:      GroceryCartHandoffView(items: session.guestStore.groceryItems.map { $0.name })
        case .family:           FamilyProfilesView()
        case .leftovers:        LeftoversView()
        case .thawPlanner:      ThawPlannerView()
        case .event:            EventPlannerView()
        case .splitCosts:       CostSplittingView()
        case .storeLayout:      StoreLayoutView()
        case .preservation:     PreservationPlannerView()
        case .garden:           GardenHarvestView()
        case .cookTogether:     MultiRecipeTimelineView()
        case .readiness:        EmergencyPantryView()
        case .eatingOut:        TakeoutLogView()
        case .regional:         RegionalFoodView()
        case .labels:           ContainerLabelsView()
        case .seasonal:         SeasonalProduceView()
        case .storageTips:      StorageTipsView()
        case .shelfLife:        ShelfLifeLookupView()
        case .snapshot:         PantrySnapshotView()
        case .duplicates:       DuplicateFinderView()
        case .achievements:     AchievementsView()
        case .pantryAudit:      PantryAuditView()
        case .savings:          MoneySavedView()
        case .reorder:          ReorderSoonView()
        case .activity:         KitchenActivityView()
        case .shelfScan:        ShelfScanView()
        }
    }
}

// MARK: - Tile

private struct ToolboxTile: View {
    @Environment(AppSession.self) private var session
    let tool: ToolboxTool
    var isFavorite: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 0) {
                Image(systemName: tool.icon)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(session.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(session.accentColor.opacity(session.isDarkMode ? 0.16 : 0.12)))
                Spacer(minLength: 0)
                if isFavorite {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(session.accentColor.opacity(0.7))
                        .padding(.top, 2)
                }
            }
            Text(tool.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(session.themeTextColor)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(tool.subtitle)
                .font(.system(size: 11))
                .foregroundStyle(session.themeSecondaryText)
                .lineLimit(2, reservesSpace: true)
                .multilineTextAlignment(.leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(session.themeCardColor)
        )
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.subtitle)
    }
}
