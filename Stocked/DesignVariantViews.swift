// DesignVariantViews.swift — Shared components for the optional design variants:
// the variant Home composition, explicit item-status labels, section headers and the
// Settings picker. The Current design never renders these (except the picker).
import SwiftUI
import UIKit
import Combine

// MARK: - Explicit item status (improvement 7: never color alone)

nonisolated enum StockedItemAttention: Equatable, Sendable {
    case expired
    case expiresToday
    case expiresIn(days: Int)
    case lowStock

    /// Expiry wins over low stock; items beyond the expiring-soon window with normal
    /// stock need no label.
    static func evaluate(expirationDate: Date?, isLow: Bool, now: Date = Date(),
                         calendar: Calendar = .current,
                         windowDays: Int = KitchenThresholds.expiringSoonDays) -> StockedItemAttention? {
        if let expirationDate {
            let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                               to: calendar.startOfDay(for: expirationDate)).day ?? 0
            if days < 0 { return .expired }
            if days == 0 { return .expiresToday }
            if days <= windowDays { return .expiresIn(days: days) }
        }
        return isLow ? .lowStock : nil
    }

    var label: String {
        switch self {
        case .expired: return "Expired"
        case .expiresToday: return "Use today"
        case .expiresIn(let days): return days == 1 ? "1 day left" : "\(days) days left"
        case .lowStock: return "Low stock"
        }
    }

    var symbol: String {
        switch self {
        case .expired: return "exclamationmark.triangle.fill"
        case .expiresToday, .expiresIn: return "clock"
        case .lowStock: return "arrow.down.circle"
        }
    }

    var role: StockedColorRole {
        switch self {
        case .expired: return .danger
        case .expiresToday, .expiresIn, .lowStock: return .warn
        }
    }

    /// Sort key: most urgent first.
    var urgency: Int {
        switch self {
        case .expired: return 0
        case .expiresToday: return 1
        case .expiresIn(let days): return 1 + days
        case .lowStock: return 100
        }
    }
}

struct StockedVariantStatusBadge: View {
    @Environment(AppSession.self) private var session
    let attention: StockedItemAttention

    var body: some View {
        let color = session.variantPalette?.color(attention.role) ?? Color.stockedWarningInk
        Label(attention.label, systemImage: attention.symbol)
            .font(.stockedSans(11, weight: .semibold, relativeTo: .caption))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm, style: .continuous)
                .strokeBorder(color.opacity(0.55), lineWidth: 1))
            .fixedSize()
    }
}

// MARK: - Type hierarchy helpers

/// Small uppercase label above titles (improvement 4: expressive type only for headings).
struct StockedVariantEyebrow: View {
    @Environment(AppSession.self) private var session
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.stockedSans(11, weight: .semibold, relativeTo: .caption2))
            .tracking(1.1)
            .foregroundStyle(session.themeSecondaryText)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Grouped-section heading (improvement 3). Kitchen Standard draws it as a compact bar.
struct StockedVariantSectionHeader: View {
    @Environment(AppSession.self) private var session
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        let compact = session.variantGeometry?.compactSections ?? false
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.stockedSans(compact ? 15 : 17, weight: .semibold, relativeTo: .headline))
                .foregroundStyle(session.themeTextColor)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(actionTitle)
                        Image(systemName: "arrow.right").accessibilityHidden(true)
                    }
                    .font(.stockedSans(13, weight: .semibold, relativeTo: .subheadline))
                    .foregroundStyle(session.accentColor)
                    .frame(minHeight: 44)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, compact ? 10 : 0)
        .padding(.vertical, compact ? 2 : 0)
        .background {
            if compact {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(session.variantPalette?.color(.soft) ?? StockedPastel.oat(session.isDarkMode))
            }
        }
    }
}

// MARK: - Variant Home (improvements 1, 2, 3, 7)

/// Data-backed Home composition for the three optional designs. It uses the same metrics,
/// inventory, recipe picks and destinations as the Current Home; the customizable widget
/// board continues below it in HomeView.
struct StockedVariantHome: View {
    @Environment(AppSession.self) private var session
    @Environment(\.stockedLayout) private var layout
    var metrics: KitchenMetrics
    var readyPicks: [UserRecipe]
    var onExpiring: () -> Void
    var onLowStock: () -> Void
    var onRecipes: () -> Void
    var onAdd: () -> Void

    nonisolated struct AttentionRow: Identifiable, Equatable, Sendable {
        let id: UUID
        let name: String
        let detail: String
        let attention: StockedItemAttention
    }

    @State private var attentionRows: [AttentionRow] = []
    @State private var attentionDay = Calendar.current.startOfDay(for: Date())
    private let dayRefresh = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private var attentionRevision: String {
        "\(session.guestStore.inventoryRevision):\(attentionDay.timeIntervalSince1970)"
    }
    private func refreshAttentionDay() {
        let day = Calendar.current.startOfDay(for: Date())
        if day != attentionDay { attentionDay = day }
    }

    private var variant: StockedDesignVariant { session.designVariant }
    private var isWide: Bool { layout.contentWidth >= 700 && !layout.isAccessibilityText }

    var body: some View {
        VStack(alignment: .leading, spacing: variant == .kitchenStandard ? 16 : 22) {
            hero
            metricsRow
            if isWide {
                HStack(alignment: .top, spacing: 24) {
                    firstSection.frame(maxWidth: .infinity, alignment: .topLeading)
                    secondSection.frame(maxWidth: .infinity, alignment: .topLeading)
                }
            } else {
                firstSection
                secondSection
            }
            Button(action: onAdd) {
                Label("Add to your kitchen", systemImage: "plus")
            }
            .stockedPrimary()
            .accessibilityHint("Choose an inventory item, grocery item or recipe to add")
        }
        .onReceive(dayRefresh) { _ in refreshAttentionDay() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            refreshAttentionDay()
        }
        .task(id: attentionRevision) {
            await Task.yield()
            let items = session.guestStore.inventoryItems
            let worker = Task.detached(priority: .utility) { Self.attentionRows(from: items, limit: 4) }
            let rows = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            attentionRows = rows
        }
    }

    // Evening Table leads with the meal; the other designs lead with what to use first.
    @ViewBuilder private var firstSection: some View {
        if variant == .eveningTable { tonightSection } else { useFirstSection }
    }
    @ViewBuilder private var secondSection: some View {
        if variant == .eveningTable { useFirstSection } else { tonightSection }
    }

    // MARK: Hero — short, text-led; Journal keeps a small illustration.

    private var headline: String {
        switch variant {
        case .pantryJournal: return "Good things on hand."
        case .kitchenStandard: return "Your kitchen, ready."
        case .eveningTable: return "Something good for tonight."
        case .current: return ""
        }
    }

    private var summary: String {
        switch metrics.totalItems {
        case 0: return "Add a few ingredients to see what you can make."
        case 1: return "1 ingredient in your kitchen."
        default: return "\(metrics.totalItems) ingredients in your kitchen."
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                StockedVariantEyebrow(text: Date().formatted(.dateTime.weekday(.wide).month(.wide).day()))
                Text(headline)
                    .font(.stockedSerif(variant == .kitchenStandard ? 28 : 32,
                                        weight: variant == .kitchenStandard ? .bold : .regular,
                                        relativeTo: .largeTitle))
                    .tracking(-0.6)
                    .foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text(summary)
                    .font(.stockedSans(14, relativeTo: .body))
                    .foregroundStyle(session.themeSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let geometry = session.variantGeometry, geometry.showsHeroArtwork, !layout.isAccessibilityText {
                StockedKitchenArtwork(asset: "home_kitchen_still_life")
                    .frame(width: min(120, layout.contentWidth * 0.3), height: geometry.heroArtworkHeight)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, variant == .kitchenStandard ? 14 : 0)
        .overlay(alignment: .leading) {
            if variant == .kitchenStandard {
                Rectangle().fill(session.accentColor).frame(width: 3).accessibilityHidden(true)
            }
        }
        .padding(.top, 4)
        .coachmarkAnchor("home.greeting")
    }

    // MARK: Metrics — one row of real counts, each a real destination.

    private var metricsRow: some View {
        let arrangement = layout.isAccessibilityText
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 8))
        let boxed = variant != .pantryJournal
        return arrangement {
            NavigationLink { InventoryView(initialZone: "All") } label: {
                metric(metrics.totalItems, "In your kitchen")
            }
            NavigationLink { CookNowResultsView(focus: .readyFirst) } label: {
                metric(metrics.mealsReady, "Ready to cook")
            }
            Button(action: onExpiring) { metric(metrics.expiringSoonCount, "Use this week") }
        }
        .buttonStyle(.plain)
        .padding(.vertical, boxed ? 14 : 14)
        .padding(.horizontal, boxed ? 14 : 0)
        .background {
            if boxed {
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd, style: .continuous)
                    .fill(session.themeCardColor)
            }
        }
        .overlay {
            if boxed {
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd, style: .continuous)
                    .strokeBorder(StockedPastel.border(session.isDarkMode), lineWidth: 1)
            } else {
                VStack {
                    Rectangle().fill(StockedPastel.border(session.isDarkMode)).frame(height: 1)
                    Spacer()
                    Rectangle().fill(StockedPastel.border(session.isDarkMode)).frame(height: 1)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func metric(_ value: Int, _ title: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.stockedCompactCount)
                .font(.stockedSerif(28, weight: variant == .kitchenStandard ? .semibold : .regular, relativeTo: .title))
                .monospacedDigit()
                .foregroundStyle(session.themeTextColor)
            Text(title)
                .font(.stockedSans(12, relativeTo: .caption))
                .foregroundStyle(session.themeSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(value) \(title.lowercased())")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: First, use these — grouped list with explicit labels.

    private var useFirstSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            StockedVariantSectionHeader(title: "First, use these",
                                        actionTitle: attentionRows.isEmpty ? nil : "See all",
                                        action: onExpiring)
            if attentionRows.isEmpty {
                Text(metrics.totalItems == 0
                     ? "Items with best-before dates will appear here."
                     : "Nothing needs using up right now.")
                    .font(.stockedSans(14, relativeTo: .body))
                    .foregroundStyle(session.themeSecondaryText)
                    .padding(.vertical, 12)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 0) {
                    ForEach(attentionRows) { row in
                        Button {
                            if row.attention == .lowStock { onLowStock() } else { onExpiring() }
                        } label: {
                            attentionRow(row)
                        }
                        .buttonStyle(.plain)
                        if row.id != attentionRows.last?.id {
                            Rectangle().fill(StockedPastel.border(session.isDarkMode)).frame(height: 1)
                        }
                    }
                }
            }
        }
    }

    private func attentionRow(_ row: AttentionRow) -> some View {
        let arrangement = layout.isAccessibilityText
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return arrangement {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.stockedSans(15, weight: .semibold, relativeTo: .body))
                    .foregroundStyle(session.themeTextColor)
                Text(row.detail)
                    .font(.stockedSans(12, relativeTo: .caption))
                    .foregroundStyle(session.themeSecondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            StockedVariantStatusBadge(attention: row.attention)
        }
        .padding(.vertical, variant == .kitchenStandard ? 10 : 13)
        .padding(.horizontal, variant == .kitchenStandard ? 10 : 0)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint(row.attention == .lowStock ? "Opens low stock" : "Opens expiring items")
    }

    nonisolated static func attentionRows(from items: [LocalInventoryItem], limit: Int,
                                          now: Date = Date()) -> [AttentionRow] {
        var rows: [AttentionRow] = []
        for item in items where item.effectiveLevel > 0 {
            if Task.isCancelled { return [] }
            guard let attention = StockedItemAttention.evaluate(
                expirationDate: item.expirationDate, isLow: item.isLow, now: now) else { continue }
            let amount = item.quantity > 1 ? "\(item.quantity) on hand" : "1 on hand"
            rows.append(AttentionRow(id: item.id, name: item.name.displayNormalized,
                                     detail: "\(item.zone) · \(amount)", attention: attention))
        }
        rows.sort {
            $0.attention.urgency != $1.attention.urgency
                ? $0.attention.urgency < $1.attention.urgency
                : $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return Array(rows.prefix(limit))
    }

    // MARK: On the table tonight — recipe/meal emphasis.

    private var tonightSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            StockedVariantSectionHeader(title: "On the table tonight",
                                        actionTitle: metrics.mealsReady > 0 ? "See \(metrics.mealsReady) meals" : "Find a meal",
                                        action: onRecipes)
            if let recipe = readyPicks.first {
                NavigationLink { UserRecipeDetailView(recipe: recipe) } label: {
                    recipeCard(recipe)
                }
                .buttonStyle(StockedWidgetButtonStyle())
            } else {
                Button(action: onRecipes) {
                    HStack(spacing: 12) {
                        Image(systemName: "fork.knife")
                            .font(.stockedSystem(size: 20))
                            .foregroundStyle(session.accentColor)
                            .frame(width: 44, height: 44)
                            .background(session.variantPalette?.color(.soft) ?? StockedPastel.oat(session.isDarkMode),
                                        in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Cook with what you have")
                                .font(.stockedSerif(18, weight: .semibold, relativeTo: .headline))
                            Text("See meals ready from your kitchen.")
                                .font(.stockedSans(13, relativeTo: .subheadline))
                                .foregroundStyle(session.themeSecondaryText)
                        }
                        .foregroundStyle(session.themeTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .stockedPastelCard()
                }
                .buttonStyle(StockedWidgetButtonStyle())
            }
        }
    }

    private func recipeCard(_ recipe: UserRecipe) -> some View {
        let sideBySide = variant == .kitchenStandard && !layout.isAccessibilityText
        let image = RecipeHeroImage(imageData: recipe.imageData, imageURL: recipe.imageURL,
                                    recipeName: recipe.title,
                                    height: variant == .eveningTable ? 180 : (sideBySide ? 132 : 128))
            .accessibilityHidden(true)
        let text = VStack(alignment: .leading, spacing: 6) {
            StockedVariantEyebrow(text: "Uses what you have")
            Text(recipe.title.recipeDisplayTitle)
                .font(.stockedSerif(variant == .eveningTable ? 26 : 21, weight: variant == .kitchenStandard ? .semibold : .regular,
                                    relativeTo: .title2))
                .foregroundStyle(session.themeTextColor)
                .fixedSize(horizontal: false, vertical: true)
            if let meta = recipeMeta(recipe) {
                Text(meta)
                    .font(.stockedSans(13, relativeTo: .subheadline))
                    .foregroundStyle(session.themeSecondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)

        return Group {
            if sideBySide {
                HStack(spacing: 0) {
                    image.frame(width: 104).clipped()
                    text
                }
            } else {
                VStack(spacing: 0) {
                    image.frame(maxWidth: .infinity).clipped()
                    text
                }
            }
        }
        .stockedPastelCard()
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the recipe")
    }

    private func recipeMeta(_ recipe: UserRecipe) -> String? {
        var parts: [String] = []
        if !recipe.cookTime.isEmpty { parts.append(recipe.cookTime) }
        if recipe.servings > 0 { parts.append(recipe.servings == 1 ? "1 serving" : "\(recipe.servings) servings") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Settings picker

/// Appearance → Design. Lists every design with its description; selection is explicit
/// (checkmark + selected trait), not color alone.
struct StockedDesignVariantPicker: View {
    @Environment(AppSession.self) private var session
    @Environment(\.stockedLayout) private var layout

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Design", systemImage: "square.on.square")
                .font(.stockedSans(15, weight: .semibold, relativeTo: .body))
                .foregroundStyle(session.themeTextColor)
            ForEach(StockedDesignVariant.allCases) { variant in
                option(variant)
            }
        }
    }

    private func option(_ variant: StockedDesignVariant) -> some View {
        let selected = session.designVariant == variant
        return Button {
            session.designVariant = variant
            HapticManager.select()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                swatch(variant)
                VStack(alignment: .leading, spacing: 3) {
                    Text(variant == .current ? "Current (default)" : variant.title)
                        .font(.stockedSans(15, weight: .semibold, relativeTo: .body))
                        .foregroundStyle(session.themeTextColor)
                    Text(variant.summary)
                        .font(.stockedSans(12, relativeTo: .caption))
                        .foregroundStyle(session.themeSecondaryText)
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.stockedSystem(size: 20))
                    .foregroundStyle(selected ? session.accentColor : session.themeSecondaryText)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: layout.minimumControlHeight, alignment: .leading)
            .background(session.themeBgColor.opacity(0.6), in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                .strokeBorder(selected ? session.accentColor : StockedPastel.border(session.isDarkMode),
                              lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(variant == .current ? "Current design, default" : "\(variant.title) design")
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityHint(variant.summary)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    /// Fixed preview colors so each option shows its own palette regardless of the active one.
    private func swatch(_ variant: StockedDesignVariant) -> some View {
        let colors: [Color]
        if let palette = variant.palette(dark: variant.forcesDarkAppearance) {
            colors = [palette.color(.bg), palette.color(.surface), palette.color(.accent)]
        } else {
            colors = [Color(uiColor: UIColor(stockedHex: 0xFDF7EF)), Color(uiColor: UIColor(stockedHex: 0xD2AF6A)),
                      Color(uiColor: UIColor(stockedHex: 0x43392F))]
        }
        return HStack(spacing: -6) {
            ForEach(colors.indices, id: \.self) { index in
                Circle().fill(colors[index])
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.15), lineWidth: 0.5))
                    .frame(width: 18, height: 18)
            }
        }
        .padding(.top, 2)
        .accessibilityHidden(true)
    }
}
