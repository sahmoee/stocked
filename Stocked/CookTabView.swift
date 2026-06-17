// CookTabView.swift — the dedicated Cook tab, 1:1 with the mockup (#246).
// "Cook." header + filter, "What would you like to do?" → dark Cook Now card /
// outlined Cook Later card, a Cook Now photo rail, and a Cook Later list of
// meals that need a few more ingredients.
import SwiftUI

struct CookTabView: View {
    @Environment(AppSession.self) var session
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }

    @State private var goCookNow    = false
    @State private var goCookLater  = false
    @State private var goSeeAllNow  = false
    @State private var goSeeAllLater = false
    @State private var goCookRightNow = false   // #14 dedicated prioritized screen
    @State private var openRecipe: UserRecipe? = nil
    @State private var goRecipe     = false
    @State private var showFilter   = false
    @State private var minutesCap: Int? = nil   // header funnel — time filter

    // Leading minutes in a "30 min" / "1 hr 20 min" style string (nil if unparseable).
    private func minutes(of recipe: UserRecipe) -> Int? {
        let digits = recipe.cookTime.compactMap { $0.isNumber ? $0 : nil }
        guard !digits.isEmpty, let n = Int(String(digits.prefix(3))) else { return nil }
        return recipe.cookTime.lowercased().contains("hr") ? n * 60 : n
    }
    private func passesFilter(_ recipe: UserRecipe) -> Bool {
        guard let cap = minutesCap else { return true }
        guard let m = minutes(of: recipe) else { return false }
        return m <= cap
    }

    // Recipes fully covered by current stock, most-cooked first.
    // #247 — matches against cookCatalog (saved recipes + starter meals), not just saved.
    private var cookableRecipes: [UserRecipe] {
        store.cookCatalog
            .filter { r in
                let m = store.stockMatch(for: r)
                return m.total > 0 && m.have == m.total && passesFilter(r)
            }
            .sorted { $0.cookCount > $1.cookCount }
    }

    // Mockup "Cook Later" — meals that need a few more ingredients (1–3 missing).
    private var almostCookable: [(recipe: UserRecipe, missing: Int)] {
        store.cookCatalog
            .compactMap { r -> (UserRecipe, Int)? in
                let m = store.stockMatch(for: r)
                let missing = m.total - m.have
                guard m.total > 0, (1...3).contains(missing), passesFilter(r) else { return nil }
                return (r, missing)
            }
            .sorted { $0.1 == $1.1 ? $0.0.cookCount > $1.0.cookCount : $0.1 < $1.1 }
    }

    var body: some View {
        StockedShell(titleText: "Cook", leadingTitle: true,
                     trailingIcon: "line.3.horizontal.decrease", trailingLabel: "Filter",
                     onTrailing: { showFilter = true }) {
            VStack(alignment: .leading, spacing: 18) {

                Text("What would you like to do?")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, 24).padding(.top, 4)

                // ── Cook Now (dark) / Cook Later (outlined) — mockup ──
                VStack(spacing: 12) {
                    cookNowCard
                    cookLaterCard
                }
                .padding(.horizontal, 24)

                // ── #14 Cook Right Now banner — only when something makeable uses expiring items ──
                if let topExpiring = store.cookableRankedByExpiry().first(where: { !$0.expiringUsed.isEmpty }) {
                    Button { goCookRightNow = true } label: {
                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(Color.stockedGreen.opacity(0.18)).frame(width: 42, height: 42)
                                Image(systemName: "leaf.fill").font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(Color.stockedGreen)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cook right now, waste nothing")
                                    .font(.system(size: 14.5, weight: .bold, design: .serif))
                                    .foregroundStyle(session.themeTextColor)
                                Text("Make \(topExpiring.recipe.title) — uses \(topExpiring.expiringUsed.prefix(2).joined(separator: ", "))")
                                    .font(.system(size: 12))
                                    .foregroundStyle(session.themeTextColor.opacity(0.6))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(session.themeTextColor.opacity(0.3))
                        }
                        .padding(14)
                        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)
                }

                // ── Cook Now rail — meals you can make right now ──────
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Cook Now")
                            .font(.system(size: 17, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Spacer()
                        Button { goSeeAllNow = true } label: {
                            Text("See All").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.stockedGold)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                    Text("Meals you can make with what you have")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .padding(.horizontal, 24)

                    if cookableRecipes.isEmpty {
                        emptyLine(minutesCap == nil
                                  ? "Add ingredients and saved meals will show up here"
                                  : "No fully-stocked meals under \(minutesCap ?? 0) min")
                            .padding(.horizontal, 24)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(cookableRecipes.prefix(8)) { recipe in
                                    Button { openRecipe = recipe; goRecipe = true } label: { mealCard(recipe) }
                                        .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 24)
                        }
                    }
                }

                // ── Cook Later list — a few ingredients away ──────────
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Cook Later")
                            .font(.system(size: 17, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Spacer()
                        Button { goSeeAllLater = true } label: {
                            Text("See All").font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Color.stockedGold)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24)
                    Text("Meals that need a few more ingredients")
                        .font(.system(size: 13))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .padding(.horizontal, 24)

                    if almostCookable.isEmpty {
                        emptyLine("Nothing is just a few ingredients away right now")
                            .padding(.horizontal, 24)
                    } else {
                        // 2-column rounded-square grid of recipe cards.
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: 12),
                                            GridItem(.flexible(), spacing: 12)],
                                  spacing: 12) {
                            ForEach(almostCookable.prefix(6), id: \.recipe.id) { entry in
                                cookLaterGridCard(entry.recipe, missing: entry.missing)
                            }
                        }
                        .padding(.horizontal, 24)
                    }
                }

                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .confirmationDialog("Show meals", isPresented: $showFilter, titleVisibility: .visible) {
                Button("All cook times") { minutesCap = nil }
                Button("20 min or less") { minutesCap = 20 }
                Button("30 min or less") { minutesCap = 30 }
                Button("45 min or less") { minutesCap = 45 }
            }
            .navigationDestination(isPresented: $goCookNow)      { ServingSizeView(isCookNow: true) }
            .navigationDestination(isPresented: $goCookLater)    { ServingSizeView(isCookNow: false) }
            .navigationDestination(isPresented: $goSeeAllNow)    { CookableMealsListView() }
            .navigationDestination(isPresented: $goSeeAllLater)  { CookLaterMealsListView() }
            .navigationDestination(isPresented: $goCookRightNow) { CookRightNowView() }
            .navigationDestination(isPresented: $goRecipe) {
                if let recipe = openRecipe { UserRecipeDetailView(recipe: recipe) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
                goCookNow = false; goCookLater = false; goSeeAllNow = false
                goSeeAllLater = false; goRecipe = false; openRecipe = nil
            }
            .onReceive(NotificationCenter.default.publisher(for: .stockedOpenCookRightNow)) { _ in
                goCookRightNow = true
            }
        }
    }

    // MARK: - Hero cards (mockup)
    // Cook Now — dark charcoal card, gold-on-cream icon, no chevron.
    private var cookNowCard: some View {
        Button { goCookNow = true } label: {
            HStack(spacing: 16) {
                ZStack {
                    Circle().fill(Color.stockedWhite).frame(width: 50, height: 50)
                    Image(systemName: "frying.pan.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.stockedGold)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cook Now")
                        .font(.system(size: 19, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedWhite)
                    Text("See meals you can make right now")
                        .font(.system(size: 13.5))
                        .foregroundStyle(Color.stockedWhite.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 20).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.stockedCharcoal)
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }
        .buttonStyle(.plain)
        .a11yButton("Cook Now", hint: "See meals you can make right now")
    }

    // Cook Later — outlined card with bookmark, no chevron (mockup).
    private var cookLaterCard: some View {
        Button { goCookLater = true } label: {
            HStack(spacing: 16) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(dark ? Color.stockedWhite.opacity(0.85) : Color.stockedCharcoal.opacity(0.8))
                    .frame(width: 50)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Cook Later")
                        .font(.system(size: 19, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Plan for later or save for the week")
                        .font(.system(size: 13.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 6)
            }
            .padding(.horizontal, 20).padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                    .stroke((dark ? Color.stockedWhite : Color.stockedCharcoal).opacity(0.35), lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        }
        .buttonStyle(.plain)
        .a11yButton("Cook Later", hint: "Plan for later or save for the week")
    }

    // MARK: - Components
    // Mockup rail card: photo flush to the card's top edge, text in a cream footer.
    private func mealCard(_ recipe: UserRecipe) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CachedAsyncImage(url: recipe.imageURL, imageData: recipe.imageData,
                             height: 96, resolveName: recipe.title)
                .frame(width: 150, height: 96)
                .clipped()

            VStack(alignment: .leading, spacing: 4) {
                Text(recipe.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(height: 34, alignment: .top)
                Text(recipe.cookTime.isEmpty ? " " : recipe.cookTime)
                    .font(.system(size: 11.5))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
            }
            .padding(10)
            .frame(width: 150, alignment: .leading)
        }
        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    // Mockup Cook Later row: round thumb · title · "N missing" in red · chevron.
    private func cookLaterRow(_ recipe: UserRecipe, missing: Int) -> some View {
        Button { openRecipe = recipe; goRecipe = true } label: {
            ZStack(alignment: .bottomLeading) {
                // Full-bleed recipe image as the cell background.
                CachedAsyncImage(url: recipe.imageURL, imageData: recipe.imageData,
                                 height: 84, resolveName: recipe.title)
                    .frame(maxWidth: .infinity)
                    .frame(height: 84)
                    .clipped()

                // Dark scrim for legibility of the overlaid text.
                LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.72)],
                               startPoint: .top, endPoint: .bottom)

                // "N missing" badge, top-right.
                VStack {
                    HStack {
                        Spacer()
                        Text("\(missing) missing")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Color.stockedError.opacity(0.92))
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding(10)

                // Title + chevron, bottom.
                HStack(spacing: 8) {
                    Text(recipe.title)
                        .font(.system(size: 15, weight: .bold, design: .serif))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .padding(.horizontal, 14).padding(.vertical, 11)
            }
            .frame(height: 84)
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
    }

    // 2-column grid card: square-ish recipe tile with image on top, title + "N missing" below.
    // Opens the recipe on tap (same action as the row).
    private func cookLaterGridCard(_ recipe: UserRecipe, missing: Int) -> some View {
        Button { openRecipe = recipe; goRecipe = true } label: {
            VStack(alignment: .leading, spacing: 0) {
                // Image with a "N missing" badge overlaid top-right.
                ZStack(alignment: .topTrailing) {
                    CachedAsyncImage(url: recipe.imageURL, imageData: recipe.imageData,
                                     height: 110, resolveName: recipe.title)
                        .frame(maxWidth: .infinity)
                        .frame(height: 110)
                        .clipped()
                    Text("\(missing) missing")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.stockedError.opacity(0.92))
                        .clipShape(Capsule())
                        .padding(8)
                }
                // Title below the image, on the card surface.
                Text(recipe.title)
                    .font(.system(size: 14, weight: .semibold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.top, 9).padding(.bottom, 12)
            }
            .background(session.themeCardColor)
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
            .overlay(
                RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                    .stroke(session.themeTextColor.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
    private func emptyLine(_ text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles").font(.system(size: 13))
                .foregroundStyle(Color.stockedGold)
            Text(text)
                .font(.system(size: 13.5))
                .foregroundStyle(session.themeTextColor.opacity(0.6))
                .lineLimit(2).minimumScaleFactor(0.85)
            Spacer()
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm + 2))
    }
}

// MARK: - See All — every fully-stocked recipe
struct CookableMealsListView: View {
    @Environment(AppSession.self) var session
    private var store: GuestDataStore { session.guestStore }
    @State private var openRecipe: UserRecipe? = nil
    @State private var goRecipe = false

    private var cookable: [UserRecipe] {
        store.cookCatalog
            .filter { r in
                let m = store.stockMatch(for: r)
                return m.total > 0 && m.have == m.total
            }
            .sorted { $0.cookCount > $1.cookCount }
    }

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cook Now")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, 24).padding(.top, 4)
                Text("\(cookable.count) meal\(cookable.count == 1 ? "" : "s") you can make with what you have")
                    .font(.system(size: 13))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.horizontal, 24)

                if cookable.isEmpty {
                    StockedEmptyState(icon: "frying.pan",
                                      title: "Nothing fully stocked yet",
                                      subtitle: "Add ingredients to your kitchen and meals you can make will show up here.")
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 10) {
                        ForEach(cookable) { recipe in
                            Button { openRecipe = recipe; goRecipe = true } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle().fill(Color.stockedGreen.opacity(0.15)).frame(width: 38, height: 38)
                                        Image(systemName: "checkmark").font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(Color.stockedGreen)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(recipe.title)
                                            .font(.system(size: 15, weight: .semibold))
                                            .foregroundStyle(session.themeTextColor)
                                            .lineLimit(1)
                                        Text(recipe.cookTime.isEmpty ? "All ingredients in stock" : "\(recipe.cookTime) · All ingredients in stock")
                                            .font(.system(size: 12))
                                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(session.themeTextColor.opacity(0.35))
                                }
                                .padding(14)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationDestination(isPresented: $goRecipe) {
                if let recipe = openRecipe { UserRecipeDetailView(recipe: recipe) }
            }
        }
    }
}

// MARK: - See All — meals that need a few more ingredients (#246)
struct CookLaterMealsListView: View {
    @Environment(AppSession.self) var session
    private var store: GuestDataStore { session.guestStore }
    @State private var openRecipe: UserRecipe? = nil
    @State private var goRecipe = false

    private var almost: [(recipe: UserRecipe, missing: Int)] {
        store.cookCatalog
            .compactMap { r -> (UserRecipe, Int)? in
                let m = store.stockMatch(for: r)
                let missing = m.total - m.have
                guard m.total > 0, (1...3).contains(missing) else { return nil }
                return (r, missing)
            }
            .sorted { $0.1 == $1.1 ? $0.0.cookCount > $1.0.cookCount : $0.1 < $1.1 }
    }

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Cook Later")
                    .font(.system(size: 22, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, 24).padding(.top, 4)
                Text("\(almost.count) meal\(almost.count == 1 ? "" : "s") that need a few more ingredients")
                    .font(.system(size: 13))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.horizontal, 24)

                if almost.isEmpty {
                    StockedEmptyState(icon: "bookmark",
                                      title: "Nothing is close right now",
                                      subtitle: "Meals that are only a few ingredients away will show up here.")
                        .padding(.top, 40)
                } else {
                    VStack(spacing: 10) {
                        ForEach(almost, id: \.recipe.id) { entry in
                            Button { openRecipe = entry.recipe; goRecipe = true } label: {
                                ZStack(alignment: .bottomLeading) {
                                    CachedAsyncImage(url: entry.recipe.imageURL, imageData: entry.recipe.imageData,
                                                     height: 96, resolveName: entry.recipe.title)
                                        .frame(maxWidth: .infinity)
                                        .frame(height: 96)
                                        .clipped()

                                    LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.72)],
                                                   startPoint: .top, endPoint: .bottom)

                                    VStack {
                                        HStack {
                                            Spacer()
                                            Text("\(entry.missing) missing")
                                                .font(.system(size: 11, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 8).padding(.vertical, 4)
                                                .background(Color.stockedError.opacity(0.92))
                                                .clipShape(Capsule())
                                        }
                                        Spacer()
                                    }
                                    .padding(10)

                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(entry.recipe.title)
                                                .font(.system(size: 15, weight: .bold, design: .serif))
                                                .foregroundStyle(.white)
                                                .lineLimit(2)
                                                .multilineTextAlignment(.leading)
                                            if !entry.recipe.cookTime.isEmpty {
                                                Text(entry.recipe.cookTime)
                                                    .font(.system(size: 12, weight: .medium))
                                                    .foregroundStyle(.white.opacity(0.85))
                                            }
                                        }
                                        Spacer(minLength: 8)
                                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                                            .foregroundStyle(.white.opacity(0.9))
                                    }
                                    .padding(.horizontal, 14).padding(.vertical, 11)
                                }
                                .frame(height: 96)
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                Spacer(minLength: 24)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .navigationDestination(isPresented: $goRecipe) {
                if let recipe = openRecipe { UserRecipeDetailView(recipe: recipe) }
            }
        }
    }
}
