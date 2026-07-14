// KitchenToolboxView.swift — Hub for the Kitchen Toolbox suite (20 tools).
//
// UI/UX notes:
//  • Searchable: the search field fuzzy-filters tools by name and subtitle, so all 20
//    tools stay one keystroke away instead of buried in a long scroll.
//  • Haptics: light tap feedback on every tool open (HapticManager).
//  • Accessibility: each tile carries a combined label + hint; layout uses LazyVGrid
//    so off-screen tiles are never built (perf).
import SwiftUI

// MARK: - Tool registry

nonisolated enum ToolboxTool: String, CaseIterable, Identifiable {
    case pantryValue, expiryCalendar, wasteInsights, weeklyReview, lowStockReport, priceLookup
    case budget, batchCook, groceryTemplates, mealCost, dietaryProfile
    case roulette, timers, converter, leftoverIdeas
    case seasonal, storageTips, shelfLife, snapshot
    case duplicates, achievements, pantryAudit

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
        case .seasonal:         return "Seasonal Produce"
        case .storageTips:      return "Storage Tips"
        case .shelfLife:        return "Shelf Life Lookup"
        case .snapshot:         return "Pantry Snapshot"
        case .duplicates:       return "Duplicate Finder"
        case .achievements:     return "Achievements"
        case .pantryAudit:      return "Pantry Audit"
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
        case .seasonal:         return "What's in season right now"
        case .storageTips:      return "Keep food fresh longer"
        case .shelfLife:        return "How long foods really last"
        case .snapshot:         return "Share your pantry as text"
        case .duplicates:       return "Find and merge duplicate items"
        case .achievements:     return "Badges for kitchen milestones"
        case .pantryAudit:      return "Confirm what is really still there"
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
        case .seasonal:         return "leaf"
        case .storageTips:      return "snowflake"
        case .shelfLife:        return "hourglass"
        case .snapshot:         return "square.and.arrow.up"
        case .duplicates:       return "doc.on.doc"
        case .achievements:     return "rosette"
        case .pantryAudit:      return "checkmark.seal"
        }
    }

    var category: String {
        switch self {
        case .pantryValue, .expiryCalendar, .wasteInsights, .weeklyReview, .lowStockReport, .priceLookup:
            return "Insights"
        case .budget, .batchCook, .groceryTemplates, .mealCost, .dietaryProfile:
            return "Planning"
        case .roulette, .timers, .converter, .leftoverIdeas:
            return "Cooking"
        case .seasonal, .storageTips, .shelfLife, .snapshot:
            return "Reference"
        case .duplicates, .achievements, .pantryAudit:
            return "Housekeeping"
        }
    }

    static let categoryOrder = ["Insights", "Planning", "Cooking", "Reference", "Housekeeping"]
}

// MARK: - Hub view

struct KitchenToolboxView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [ToolboxTool] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return ToolboxTool.allCases }
        return ToolboxTool.allCases.filter {
            FuzzyMatch.matches(q, $0.title) || $0.subtitle.localizedCaseInsensitiveContains(q)
        }
    }

    private var grouped: [(category: String, tools: [ToolboxTool])] {
        let tools = filtered
        return ToolboxTool.categoryOrder.compactMap { cat in
            let inCat = tools.filter { $0.category == cat }
            return inCat.isEmpty ? nil : (cat, inCat)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if grouped.isEmpty {
                    ToolboxEmptyState(icon: "magnifyingglass",
                                      title: "No tools match",
                                      message: "Try a different search — every tool is listed by name and what it does.")
                }
                ForEach(grouped, id: \.category) { group in
                    ToolboxSectionLabel(text: group.category)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                              spacing: 10) {
                        ForEach(group.tools) { tool in
                            NavigationLink(value: tool) {
                                ToolboxTile(tool: tool)
                            }
                            .buttonStyle(.plain)
                            .simultaneousGesture(TapGesture().onEnded { HapticManager.light() })
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 24)
        }
        .background(session.themeBgColor.ignoresSafeArea())
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
        case .seasonal:         SeasonalProduceView()
        case .storageTips:      StorageTipsView()
        case .shelfLife:        ShelfLifeLookupView()
        case .snapshot:         PantrySnapshotView()
        case .duplicates:       DuplicateFinderView()
        case .achievements:     AchievementsView()
        case .pantryAudit:      PantryAuditView()
        }
    }
}

// MARK: - Tile

private struct ToolboxTile: View {
    @Environment(AppSession.self) private var session
    let tool: ToolboxTool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: tool.icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(session.accentColor)
                .frame(width: 34, height: 34)
                .background(Circle().fill(session.accentColor.opacity(session.isDarkMode ? 0.16 : 0.12)))
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
