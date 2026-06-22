// CookComponents.swift — reusable component library for the Cook experience.
//
// Built from the Stocked Cook package's Component_Library spec. These are the real SwiftUI
// structs the Cook screens compose from, so the same card types are not duplicated across 12
// screens. All use the stocked palette, serif titles, system body, large corner radius, and
// tap-anywhere interaction. No GeometryReader.
//
// Components: CookHeroCard, CookActionCard, CookCategoryCard, CookIntelligenceCard,
// CookRecipeCard, CookPlannerCard, CookPrepTaskCard, CookChipSelector, CookSearchBar,
// CookStepSelector, CookEmptyState, CookLoadingState, CookErrorState.
// (Header maps to the existing StockedShell, so it is not redefined here.)

import SwiftUI

// MARK: - Shared style helpers

enum CookStyle {
    static let cardCorner: CGFloat = StockedUI.cornerRadiusLg   // 20
    static let cardPadding: CGFloat = 18
    static let sectionSpacing: CGFloat = 14
    static let screenHPad: CGFloat = 22
}

// Returns a bundled asset image only if it actually exists in the catalog, so cards can show a
// photo when one has been added and gracefully fall back to color/emoji when it has not.
func cookAssetImage(_ name: String?) -> Image? {
    guard let name, !name.isEmpty, UIImage(named: name) != nil else { return nil }
    return Image(name)
}

// MARK: - HeroCard — a large tappable card (Cook Now / Cook Later / Plan ahead)

struct CookHeroCard: View {
    @Environment(AppSession.self) private var session
    let title: String
    var subtitle: String = ""
    var icon: String = "fork.knife"
    var emoji: String? = nil
    var tint: Color = Color.stockedCharcoal
    var textOnDark: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(textOnDark ? Color.stockedWhite.opacity(0.16) : Color.stockedGold.opacity(0.15))
                        .frame(width: 52, height: 52)
                    if let emoji { Text(emoji).font(.system(size: 26)) }
                    else {
                        Image(systemName: icon).font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(textOnDark ? Color.stockedWhite : Color.stockedGold)
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(textOnDark ? Color.stockedWhite : session.themeTextColor)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 13))
                            .foregroundStyle(textOnDark ? Color.stockedWhite.opacity(0.78) : session.themeTextColor.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .bold))
                    .foregroundStyle(textOnDark ? Color.stockedWhite.opacity(0.6) : session.themeTextColor.opacity(0.3))
            }
            .padding(CookStyle.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tint, in: RoundedRectangle(cornerRadius: CookStyle.cardCorner))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ActionCard — medium card for an action (Build Around Food, Match My Mood, Surprise Me)

struct CookActionCard: View {
    @Environment(AppSession.self) private var session
    let title: String
    var subtitle: String = ""
    var icon: String = "sparkles"
    var emoji: String? = nil
    var assetName: String? = nil
    var tint: Color = Color.stockedCharcoal
    var textOnDark: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let photo = cookAssetImage(assetName) {
                photoCard(photo)
            } else {
                flatCard
            }
        }
        .buttonStyle(.plain)
    }

    // Photo present: tall card, full-bleed image, tint gradient keeps the left readable.
    private func photoCard(_ photo: Image) -> some View {
        ZStack(alignment: .bottomLeading) {
            photo.resizable().scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
            LinearGradient(colors: [tint, tint.opacity(0.9), tint.opacity(0.0)],
                           startPoint: .leading, endPoint: .trailing)
            VStack {
                HStack {
                    ZStack {
                        Circle().fill(Color.stockedWhite).frame(width: 46, height: 46)
                        if let emoji { Text(emoji).font(.system(size: 22)) }
                        else { Image(systemName: icon).font(.system(size: 19, weight: .semibold)).foregroundStyle(Color.stockedGold) }
                    }
                    Spacer()
                }
                Spacer()
            }.padding(CookStyle.cardPadding)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 21, weight: .bold, design: .serif))
                        .foregroundStyle(textOnDark ? Color.stockedWhite : session.themeTextColor)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12.5))
                            .foregroundStyle(textOnDark ? Color.stockedWhite.opacity(0.8) : session.themeTextColor.opacity(0.65))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                ZStack {
                    Circle().fill(Color.stockedWhite).frame(width: 32, height: 32)
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.stockedCharcoal)
                }
            }.padding(CookStyle.cardPadding)
        }
        .frame(height: 150).frame(maxWidth: .infinity)
        .background(tint).clipShape(RoundedRectangle(cornerRadius: CookStyle.cardCorner))
    }

    // No photo: the original compact solid-color row.
    private var flatCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(textOnDark ? Color.stockedWhite.opacity(0.16) : Color.stockedGold.opacity(0.15))
                    .frame(width: 46, height: 46)
                if let emoji { Text(emoji).font(.system(size: 22)) }
                else {
                    Image(systemName: icon).font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(textOnDark ? Color.stockedWhite : Color.stockedGold)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 19, weight: .bold, design: .serif))
                    .foregroundStyle(textOnDark ? Color.stockedWhite : session.themeTextColor)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 12.5))
                        .foregroundStyle(textOnDark ? Color.stockedWhite.opacity(0.75) : session.themeTextColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(textOnDark ? Color.stockedWhite.opacity(0.6) : session.themeTextColor.opacity(0.3))
        }
        .padding(CookStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: CookStyle.cardCorner))
    }
}

// MARK: - CategoryCard — a category tile (Protein, Vegetables, Breakfast, …) with a count

struct CookCategoryCard: View {
    @Environment(AppSession.self) private var session
    let title: String
    var subtitle: String = ""
    var icon: String = "fork.knife"
    var emoji: String? = nil
    var assetName: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color.stockedGold.opacity(0.15)).frame(width: 44, height: 44)
                    if let emoji { Text(emoji).font(.system(size: 20)) }
                    else {
                        Image(systemName: icon).font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(Color.stockedGold)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12))
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                    }
                }
                Spacer()
                if let photo = cookAssetImage(assetName) {
                    photo.resizable().scaledToFill()
                        .frame(width: 56, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }
            }
            .padding(.vertical, 14).padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - IntelligenceCard — surfaces an inventory-aware insight

struct CookIntelligenceCard: View {
    @Environment(AppSession.self) private var session
    let title: String
    let detail: String
    var icon: String = "sparkles"
    var accent: Color = Color.stockedGreen
    var action: (() -> Void)? = nil

    var body: some View {
        let content = HStack(spacing: 12) {
            ZStack {
                Circle().fill(accent.opacity(0.16)).frame(width: 42, height: 42)
                Image(systemName: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14.5, weight: .bold, design: .serif))
                    .foregroundStyle(session.themeTextColor)
                Text(detail).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if action != nil {
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.3))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))

        if let action {
            Button(action: action) { content }.buttonStyle(.plain)
        } else {
            content
        }
    }
}

// MARK: - RecipeCard — a recipe row/card with optional match and time

struct CookRecipeCard: View {
    @Environment(AppSession.self) private var session
    let title: String
    var subtitle: String = ""
    var matchPercent: Int? = nil
    var imageURL: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                AsyncFoodImage(name: title, url: imageURL, size: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(session.themeTextColor).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.55))
                    }
                }
                Spacer()
                if let matchPercent {
                    Text("\(matchPercent)%").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.stockedGreen)
                }
            }
            .padding(.vertical, 10).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PlannerCard — a planned meal / day card

struct CookPlannerCard: View {
    @Environment(AppSession.self) private var session
    let title: String
    var subtitle: String = ""
    var mealType: String = ""
    var isCooked: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if !mealType.isEmpty {
                        Text(mealType.uppercased()).font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.stockedGold)
                    }
                    Text(title).font(.system(size: 15.5, weight: .semibold))
                        .foregroundStyle(session.themeTextColor).lineLimit(1)
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.55))
                    }
                }
                Spacer()
                if isCooked {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 18))
                        .foregroundStyle(Color.stockedGreen)
                } else {
                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PrepTaskCard — a single prep checklist row

struct CookPrepTaskCard: View {
    @Environment(AppSession.self) private var session
    let title: String
    let isDone: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 12) {
                Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(isDone ? Color.stockedGreen : session.themeTextColor.opacity(0.3))
                Text(title).font(.system(size: 15))
                    .foregroundStyle(session.themeTextColor)
                    .strikethrough(isDone, color: session.themeTextColor.opacity(0.4))
                Spacer()
            }
            .padding(.vertical, 11).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - ChipSelector — a labeled row of single-select chips

struct CookChipSelector: View {
    @Environment(AppSession.self) private var session
    let label: String
    let options: [String]
    @Binding var selection: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(session.themeTextColor)
            StockedFlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(options, id: \.self) { opt in
                    let isSel = selection == opt
                    Button { selection = opt } label: {
                        Text(opt).font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isSel ? Color.stockedWhite : session.themeTextColor)
                            .padding(.vertical, 8).padding(.horizontal, 14)
                            .background(isSel ? Color.stockedGold : session.themeCardColor,
                                        in: Capsule())
                            .overlay(Capsule().stroke(isSel ? Color.clear : session.themeTextColor.opacity(0.12), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - SearchBar — a simple bound search field

struct CookSearchBar: View {
    @Environment(AppSession.self) private var session
    var placeholder: String = "Search"
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 15))
                .foregroundStyle(session.themeTextColor.opacity(0.45))
            TextField(placeholder, text: $text)
                .font(.system(size: 15)).foregroundStyle(session.themeTextColor)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 15))
                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 11).padding(.horizontal, 14)
        .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }
}

// MARK: - StepSelector — a segmented two-or-more option picker

struct CookStepSelector: View {
    @Environment(AppSession.self) private var session
    let label: String
    let options: [String]
    @Binding var selection: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !label.isEmpty {
                Text(label).font(.system(size: 14, weight: .semibold)).foregroundStyle(session.themeTextColor)
            }
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { opt in
                    let isSel = selection == opt
                    Button { selection = opt } label: {
                        Text(opt).font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isSel ? Color.stockedWhite : session.themeTextColor)
                            .frame(maxWidth: .infinity).padding(.vertical, 11)
                            .background(isSel ? Color.stockedCharcoal : session.themeCardColor,
                                        in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - State views (empty / loading / error)

struct CookEmptyState: View {
    @Environment(AppSession.self) private var session
    var icon: String = "fork.knife"
    let title: String
    var message: String = ""
    var ctaTitle: String? = nil
    var ctaAction: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 38))
                .foregroundStyle(session.themeTextColor.opacity(0.3))
            Text(title).font(.system(size: 18, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            if !message.isEmpty {
                Text(message).font(.system(size: 13))
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            if let ctaTitle, let ctaAction {
                Button(action: ctaAction) {
                    Text(ctaTitle).font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stockedWhite)
                        .padding(.vertical, 12).padding(.horizontal, 22)
                        .background(Color.stockedCharcoal, in: Capsule())
                }.buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
    }
}

struct CookLoadingState: View {
    @Environment(AppSession.self) private var session
    var count: Int = 3

    var body: some View {
        VStack(spacing: 12) {
            ForEach(0..<count, id: \.self) { _ in
                RoundedRectangle(cornerRadius: CookStyle.cardCorner)
                    .fill(session.themeCardColor)
                    .frame(height: 76)
                    .opacity(0.6)
            }
        }
    }
}

struct CookErrorState: View {
    @Environment(AppSession.self) private var session
    var message: String = "Something went wrong."
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 34))
                .foregroundStyle(Color.stockedWarning)
            Text(message).font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.7))
                .multilineTextAlignment(.center)
            Button(action: retry) {
                Text("Try Again").font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.vertical, 12).padding(.horizontal, 22)
                    .background(Color.stockedCharcoal, in: Capsule())
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
    }
}
