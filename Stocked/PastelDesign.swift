import SwiftUI

/// The approved September 24 reference: matte ivory, honey, sage and soft peach.
/// Decorative fills never double as small-text colors.
enum StockedPastel {
    static let honey = Color(red: 0.824, green: 0.686, blue: 0.416)
    static let sage = Color(red: 0.565, green: 0.635, blue: 0.502)
    static func oat(_ dark: Bool) -> Color {
        dark ? Color(red: 0.24, green: 0.21, blue: 0.17) : Color(red: 0.945, green: 0.894, blue: 0.812)
    }
    static func garden(_ dark: Bool) -> Color {
        dark ? Color(red: 0.18, green: 0.22, blue: 0.16) : Color(red: 0.914, green: 0.925, blue: 0.863)
    }
    static func peach(_ dark: Bool) -> Color {
        dark ? Color(red: 0.26, green: 0.20, blue: 0.16) : Color(red: 0.980, green: 0.918, blue: 0.839)
    }
    static func border(_ dark: Bool) -> Color {
        dark ? Color(red: 0.35, green: 0.32, blue: 0.27) : Color(red: 0.866, green: 0.827, blue: 0.765)
    }
}

private struct StockedPastelCardModifier: ViewModifier {
    @Environment(AppSession.self) private var session
    @Environment(\.colorSchemeContrast) private var contrast
    var fill: Color?
    var radius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(fill ?? session.themeCardColor, in: shape)
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(contrast == .increased ? session.themeSecondaryText : StockedPastel.border(session.isDarkMode),
                                   lineWidth: contrast == .increased ? 1.5 : 0.65)
                    .allowsHitTesting(false)
            }
            .shadow(color: Color.stockedCharcoal.opacity(session.isDarkMode ? 0.14 : 0.035), radius: 3, y: 2)
    }
}

extension View {
    func stockedPastelCard(fill: Color? = nil, radius: CGFloat = 18) -> some View {
        modifier(StockedPastelCardModifier(fill: fill, radius: radius))
    }
}

/// Shared editorial hierarchy for the four destination hubs and their subpages.
struct StockedEditorialHero: View {
    @Environment(AppSession.self) private var session
    @Environment(\.stockedLayout) private var layout
    var eyebrow: String
    var title: String
    var subtitle: String
    var artwork: String

    var body: some View {
        let arrangement = layout.isAccessibilityText || layout.contentWidth < 350
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        arrangement {
            VStack(alignment: .leading, spacing: 8) {
                Text(eyebrow)
                    .font(.stockedSans(12, weight: .medium))
                    .foregroundStyle(session.accentColor)
                Text(title)
                    .font(.stockedSerif(30, weight: .bold, relativeTo: .largeTitle))
                    .tracking(-0.6)
                    .foregroundStyle(session.themeTextColor)
                Text(subtitle)
                    .font(.stockedSans(14, relativeTo: .body))
                    .foregroundStyle(session.themeSecondaryText)
                    .lineSpacing(3)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            StockedKitchenArtwork(asset: artwork)
                .saturation(0.72)
                .frame(width: layout.isAccessibilityText ? 100 : min(150, layout.contentWidth * 0.32), height: 138)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 12)
    }
}

/// Native, data-backed recreation of the approved Home composition.
struct StockedPastelHome: View {
    @Environment(AppSession.self) private var session
    @Environment(\.stockedLayout) private var layout
    var metrics: KitchenMetrics
    var onExpiring: () -> Void
    var onRecipes: () -> Void
    @State private var counts: [MockCategory: Int] = [:]

    private var dark: Bool { session.isDarkMode }
    private var otherCount: Int { [.dairy, .beverages, .leftovers].reduce(0) { $0 + counts[$1, default: 0] } }

    var body: some View {
        VStack(spacing: 8) {
            let headerLayout = layout.contentWidth >= 760 && !layout.isAccessibilityText
                ? AnyLayout(HStackLayout(alignment: .center, spacing: 18))
                : AnyLayout(VStackLayout(spacing: 8))
            headerLayout {
                hero.frame(maxWidth: 700)
                kitchenCard.frame(maxWidth: .infinity)
            }
            let cardLayout = layout.isAccessibilityText
                ? AnyLayout(VStackLayout(spacing: 8))
                : AnyLayout(StockedEqualHeightRow(spacing: 8))
            cardLayout {
                NavigationLink {
                    CookNowResultsView(focus: .readyFirst)
                } label: {
                    featureCard(title: "Ready to cook", detail: "\(metrics.mealsReady) meals you can make\nwith what you have.",
                                artwork: "pastel_ready_meal", fill: StockedPastel.garden(dark))
                }
                .buttonStyle(StockedWidgetButtonStyle())
                Button(action: onExpiring) {
                    featureCard(title: "Expiring soon", detail: "\(metrics.expiringSoonCount) items to use up\nin the next few days.",
                                artwork: "pastel_fresh_produce", fill: StockedPastel.peach(dark))
                }
                .buttonStyle(StockedWidgetButtonStyle())
            }
            Button(action: onRecipes) {
                HStack(spacing: 12) {
                    Image(systemName: "lightbulb")
                        .font(.stockedSystem(size: 24))
                        .foregroundStyle(session.accentColor)
                        .frame(width: 42, height: 42)
                        .background(StockedPastel.oat(dark), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Try a recipe with what you have")
                            .font(.stockedSerif(16, weight: .semibold))
                            .foregroundStyle(session.themeTextColor)
                        Text("Turn your ingredients into something great.")
                            .font(.stockedSans(12))
                            .foregroundStyle(session.themeSecondaryText)
                    }
                    Spacer(minLength: 0)
                    arrow
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .stockedPastelCard()
            }
            .buttonStyle(StockedWidgetButtonStyle())
        }
        .task(id: session.guestStore.inventoryRevision) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            var result: [MockCategory: Int] = [:]
            for item in session.guestStore.inventoryItems { result[MockCategory.classify(item), default: 0] += 1 }
            counts = result
        }
    }

    private var hero: some View {
        VStack(spacing: 0) {
            if layout.isAccessibilityText {
                greeting.padding(.horizontal, 10).padding(.bottom, 12)
            }
            ZStack(alignment: .topLeading) {
                StockedKitchenArtwork(asset: "pastel_kitchen_hero")
                    .aspectRatio(1.5, contentMode: .fit)
                    if !layout.isAccessibilityText {
                        greeting
                            .frame(maxWidth: min(300, layout.contentWidth * 0.62), alignment: .leading)
                            .padding(.leading, 10)
                            .padding(.top, 8)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .coachmarkAnchor("home.greeting")
    }

    private var greeting: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(StockedFormatters.timeOfDayGreeting.prefix(1) + StockedFormatters.timeOfDayGreeting.dropFirst().lowercased())
                .font(.stockedSerif(29, weight: .bold, relativeTo: .largeTitle))
                .tracking(-0.7)
            Text("A well-stocked kitchen\nmakes good days easier.")
                .font(.stockedSans(14, relativeTo: .body))
                .foregroundStyle(session.themeSecondaryText)
        }
        .foregroundStyle(session.themeTextColor)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityLabel("\(StockedFormatters.timeOfDayGreeting), \(session.effectiveName). A well-stocked kitchen makes good days easier.")
    }

    private var kitchenCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your kitchen").font(.stockedSerif(27, weight: .bold, relativeTo: .title))
                    Text("\(metrics.totalItems) items").font(.stockedSans(15)).foregroundStyle(session.themeSecondaryText)
                }
                Spacer(minLength: 4)
                NavigationLink { InventoryView(initialZone: "All") } label: {
                    HStack(spacing: 6) {
                        Text("View all")
                        Image(systemName: "arrow.right")
                    }
                    .font(.stockedSans(12))
                    .padding(.horizontal, 12)
                    .frame(minHeight: 44)
                    .background(StockedPastel.oat(dark), in: Capsule())
                }.buttonStyle(.plain)
            }
            let columns = layout.isAccessibilityText ? 2 : 5
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 10) {
                category(.produce, title: "Produce", icon: "leaf.fill")
                category(.pantry, title: "Pantry", icon: "cabinet")
                category(.frozen, title: "Frozen", icon: "snowflake")
                category(.meatSeafood, title: "Protein", icon: "fish.fill")
                NavigationLink { StockedOtherKitchenCategories() } label: {
                    categoryLabel("Other", icon: "waterbottle.fill", count: otherCount)
                }.buttonStyle(.plain)
            }
            Rectangle().fill(StockedPastel.border(dark)).frame(height: 0.6)
            stockSummary
        }
        .foregroundStyle(session.themeTextColor)
        .padding(15)
        .stockedPastelCard(radius: 18)
    }

    private func category(_ category: MockCategory, title: String, icon: String) -> some View {
        NavigationLink { CategoryItemsView(category: category) } label: {
            categoryLabel(title, icon: icon, count: counts[category, default: 0])
        }.buttonStyle(.plain)
    }

    private func categoryLabel(_ title: String, icon: String, count: Int) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.stockedSystem(size: 21, weight: .medium))
                .foregroundStyle(dark ? StockedPastel.sage : Color.stockedSuccessInk)
                .frame(width: 39, height: 39)
                .background(StockedPastel.garden(dark), in: Circle())
            Text("\(count)").font(.stockedSans(14, weight: .medium))
            Text(title).font(.stockedSans(11)).foregroundStyle(session.themeSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 70)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(count) items")
    }

    private var stockSummary: some View {
        let arrangement = layout.isAccessibilityText
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 10))
        return arrangement {
            Image(systemName: "refrigerator")
                .font(.stockedSystem(size: 21))
                .foregroundStyle(session.accentColor)
                .frame(width: 34, height: 34)
                .background(StockedPastel.oat(dark), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Your kitchen is \(metrics.stockPercent)% stocked")
                    .font(.stockedSans(11))
                ProgressView(value: Double(metrics.stockPercent), total: 100)
                    .tint(StockedPastel.sage)
                    .accessibilityLabel("Kitchen stock level")
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 3) {
                Text(metrics.stockPercent >= 80 ? "Looks good!" : "Room to grow")
                    .font(.stockedSerif(14, weight: .medium))
                Text(metrics.stockPercent >= 80 ? "You’re all set\nfor the week." : "A few additions\ncan help.")
                    .font(.stockedSans(10))
                    .foregroundStyle(session.themeSecondaryText)
            }
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right")
            .font(.stockedSystem(size: 12))
            .foregroundStyle(session.themeTextColor)
            .frame(width: 27, height: 27)
            .background(session.themeCardColor.opacity(0.9), in: Circle())
            .accessibilityHidden(true)
    }

    private func featureCard(title: String, detail: String, artwork: String, fill: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 2) {
                Text(title).font(.stockedSerif(20, weight: .semibold, relativeTo: .title3))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                arrow
            }
            Text(detail).font(.stockedSans(11.5)).foregroundStyle(session.themeSecondaryText)
                .fixedSize(horizontal: false, vertical: true)
            StockedKitchenArtwork(asset: artwork)
                .frame(maxWidth: .infinity)
                .frame(height: layout.isAccessibilityText || layout.contentWidth >= 760 ? 110 : 65, alignment: .bottomTrailing)
                .scaleEffect(1.35, anchor: .bottomTrailing)
                .offset(x: 12, y: 12)
                .accessibilityHidden(true)
        }
        .foregroundStyle(session.themeTextColor)
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .stockedPastelCard(fill: fill)
        .accessibilityElement(children: .combine)
    }
}

private struct StockedOtherKitchenCategories: View {
    @Environment(AppSession.self) private var session

    var body: some View {
        StockedShell(showBack: true, titleText: "Other kitchen items") {
            VStack(alignment: .leading, spacing: 12) {
                StockedEditorialHero(eyebrow: "Your kitchen", title: "The other essentials.",
                    subtitle: "Dairy, drinks and leftovers, all in one place.", artwork: "inventory_category_fridge")
                ForEach([MockCategory.dairy, .beverages, .leftovers]) { category in
                    NavigationLink { CategoryItemsView(category: category) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: category.icon).frame(width: 32)
                            Text(category.title).font(.stockedSerif(20, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                        .foregroundStyle(session.themeTextColor)
                        .padding(18)
                        .stockedPastelCard()
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 16)
        }
    }
}
