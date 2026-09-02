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

// The Cook hub has one intentional control shape: the large cream illustrated card from the
// approved Stocked design. Keep this separate from generic action cards so future appearance
// settings cannot silently turn these primary choices into circles, pills, or photo tiles.
struct CookHubIllustratedButton: View {
    @Environment(AppSession.self) private var session
    @Environment(\.stockedLayout) private var layoutMetrics

    let title: String
    let primaryDetail: String
    let secondaryDetail: String
    let assetName: String
    let action: () -> Void

    private var imageWidth: CGFloat {
        min(142, max(84, 142 / min(layoutMetrics.textScale, 1.7)))
    }

    var body: some View {
        Button(action: action) {
            horizontalContent
            .padding(.horizontal, 14)
            .padding(.vertical, max(14, 10 * layoutMetrics.textScale))
            .frame(maxWidth: .infinity)
            .frame(minHeight: 182)
            .background(session.themeCardColor)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(primaryDetail) \(secondaryDetail)")
        .accessibilityAddTraits(.isButton)
    }

    private var horizontalContent: some View {
        HStack(spacing: 8) {
            illustration
                .frame(width: imageWidth, height: 148)
            copy
            chevron
        }
    }

    private var illustration: some View {
        Image(assetName)
            .resizable()
            .scaledToFit()
            .accessibilityHidden(true)
    }

    private var copy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .scaledFont(24, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
                .fixedSize(horizontal: false, vertical: true)

            Text(primaryDetail)
                .scaledFont(14)
                .foregroundStyle(session.themeTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Text(secondaryDetail)
                .scaledFont(13)
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .layoutPriority(1)
    }

    private var chevron: some View {
        Image(systemName: "chevron.right")
            .scaledFont(16, weight: .semibold)
            .foregroundStyle(session.themeTextColor.opacity(0.32))
            .accessibilityHidden(true)
    }
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
    var assetName: String? = nil
    var tint: Color = Color.stockedCharcoal
    var textOnDark: Bool = true
    var height: CGFloat = 150   // Cook Buttons size setting scales this from the call site
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let photo = cookAssetImage(assetName) {
                photoHero(photo)
            } else {
                flatHero
            }
        }
        .buttonStyle(.plain)
    }

    // Photo present: stacked — tint band with text on top, photo strip below.
    private func photoHero(_ photo: Image) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 14) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.30)).frame(width: 50, height: 50)
                    Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1).frame(width: 50, height: 50)
                    if let emoji { Text(emoji).scaledFont(25) }
                    else { Image(systemName: icon).scaledFont(21, weight: .semibold).foregroundStyle(Color.white) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).scaledFont(23, weight: .bold, design: .serif)
                        .foregroundStyle(Color.white)
                        .shadow(color: Color.black.opacity(0.6), radius: 4, y: 1)
                    if !subtitle.isEmpty {
                        Text(subtitle).scaledFont(13)
                            .foregroundStyle(Color.white.opacity(0.92))
                            .shadow(color: Color.black.opacity(0.6), radius: 3, y: 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").scaledFont(15, weight: .bold)
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.5), radius: 3, y: 1)
            }
            .padding(CookStyle.cardPadding)
        }
        .frame(height: height)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                photo.resizable().scaledToFill()
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.15),
                             Color.black.opacity(0.55), Color.black.opacity(0.82)],
                    startPoint: .top, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: CookStyle.cardCorner))
        )
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: CookStyle.cardCorner))
        .contentShape(RoundedRectangle(cornerRadius: CookStyle.cardCorner))
    }

    // No photo: the original single row.
    private var flatHero: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(textOnDark ? Color.stockedWhite.opacity(0.16) : Color.stockedGold.opacity(0.15))
                    .frame(width: 52, height: 52)
                if let emoji { Text(emoji).scaledFont(26) }
                else {
                    Image(systemName: icon).scaledFont(22, weight: .semibold)
                        .foregroundStyle(textOnDark ? Color.stockedWhite : Color.stockedGold)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .scaledFont(22, weight: .bold, design: .serif)
                    .foregroundStyle(textOnDark ? Color.stockedWhite : session.themeTextColor)
                if !subtitle.isEmpty {
                    Text(subtitle).scaledFont(13)
                        .foregroundStyle(textOnDark ? Color.stockedWhite.opacity(0.78) : session.themeTextColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").scaledFont(14, weight: .bold)
                .foregroundStyle(textOnDark ? Color.stockedWhite.opacity(0.6) : session.themeTextColor.opacity(0.3))
        }
        .padding(CookStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: CookStyle.cardCorner))
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
    var cardHeight: CGFloat = 150
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
        // Text content lives in a fixed-height container; the photo + scrim are a clipped
        // background so the image can never push the text outside the card.
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .bottom, spacing: 14) {
                ZStack {
                    Circle().fill(Color.black.opacity(0.30)).frame(width: 44, height: 44)
                    Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1).frame(width: 44, height: 44)
                    if let emoji { Text(emoji).scaledFont(21) }
                    else { Image(systemName: icon).scaledFont(18, weight: .semibold).foregroundStyle(Color.white) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .scaledFont(22, weight: .bold, design: .serif)
                        .foregroundStyle(Color.white)
                        .shadow(color: Color.black.opacity(0.6), radius: 4, y: 1)
                    if !subtitle.isEmpty {
                        Text(subtitle).scaledFont(13)
                            .foregroundStyle(Color.white.opacity(0.92))
                            .shadow(color: Color.black.opacity(0.6), radius: 3, y: 1)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").scaledFont(15, weight: .bold)
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.5), radius: 3, y: 1)
            }
            .padding(CookStyle.cardPadding)
        }
        .frame(height: cardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                photo.resizable().scaledToFill()
                LinearGradient(
                    colors: [Color.black.opacity(0.0), Color.black.opacity(0.15),
                             Color.black.opacity(0.55), Color.black.opacity(0.82)],
                    startPoint: .top, endPoint: .bottom)
            }
            .clipShape(RoundedRectangle(cornerRadius: CookStyle.cardCorner))
        )
        .background(tint)
        .clipShape(RoundedRectangle(cornerRadius: CookStyle.cardCorner))
        .contentShape(RoundedRectangle(cornerRadius: CookStyle.cardCorner))
    }

    // No photo: the original compact solid-color row.
    private var flatCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(textOnDark ? Color.stockedWhite.opacity(0.16) : Color.stockedGold.opacity(0.15))
                    .frame(width: 46, height: 46)
                if let emoji { Text(emoji).scaledFont(22) }
                else {
                    Image(systemName: icon).scaledFont(19, weight: .semibold)
                        .foregroundStyle(textOnDark ? Color.stockedWhite : Color.stockedGold)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(19, weight: .bold, design: .serif)
                    .foregroundStyle(textOnDark ? Color.stockedWhite : session.themeTextColor)
                if !subtitle.isEmpty {
                    Text(subtitle).scaledFont(12.5)
                        .foregroundStyle(textOnDark ? Color.stockedWhite.opacity(0.75) : session.themeTextColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").scaledFont(13, weight: .semibold)
                .foregroundStyle(textOnDark ? Color.stockedWhite.opacity(0.6) : session.themeTextColor.opacity(0.3))
        }
        .padding(CookStyle.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint, in: RoundedRectangle(cornerRadius: CookStyle.cardCorner))
    }
}

// MARK: - Row tone + illustrated row

/// Surface a row paints itself with. The illustrations supplied for Cook are transparent
/// cut-outs, so the card — not the image — owns the background. Never bake a fill into the PNG.
enum CookRowTone {
    case dark   // charcoal card, light text (mockup: "in your pantry" / "use tonight" rows)
    case soft   // tan / dark-surface card, theme text (mockup: "plan ahead" rows)
}

/// How a CookCategoryCard paints itself.
/// `.fullBleed` is the original treatment (photo fills the cell, scrim on the left) and stays
/// the default so Build Around Food and every existing call site are untouched.
/// `.illustrated` is the second render mode for transparent cut-out art.
enum CookCardRender {
    case fullBleed
    case illustrated
}

/// A row that composites a transparent illustration over the card's own fill at runtime:
/// cut-out art at the leading edge, then title, subtitle, an optional gold "In pantry" pill or
/// cart glyph, then the chevron. Used by the Cook sub-option screens and the Cook Now pathways.
struct CookIllustratedRow: View {
    @Environment(AppSession.self) private var session
    let title: String
    var subtitle: String = ""
    var assetName: String? = nil
    var fallbackEmoji: String? = nil
    var fallbackIcon: String = "fork.knife"
    var tone: CookRowTone = .dark
    var artSize: CGFloat = 68
    /// Gold "In pantry" pill on the trailing edge.
    var showPantryPill: Bool = false
    /// cart.badge.plus glyph on the trailing edge (shown for items not in the pantry).
    var showCartGlyph: Bool = false
    /// Softens the whole row for items that are not in the pantry.
    var dimmed: Bool = false
    var action: (() -> Void)? = nil

    private var onDark: Bool { tone == .dark }
    private var ink: Color { onDark ? Color.stockedWhite : session.themeTextColor }
    private var fill: Color {
        switch tone {
        case .dark: return Color.stockedCharcoal.opacity(dimmed ? 0.45 : 1.0)
        case .soft: return session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.6)
        }
    }

    var body: some View {
        if let action {
            Button(action: action) { rowVisual }
                .buttonStyle(.plain)
                .accessibilityLabel(subtitle.isEmpty ? title : "\(title). \(subtitle)")
        } else {
            rowVisual
                .accessibilityElement(children: .combine)
                .accessibilityLabel(subtitle.isEmpty ? title : "\(title). \(subtitle)")
        }
    }

    private var rowVisual: some View {
        HStack(spacing: 14) {
            art
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .scaledFont(16.5, weight: .semibold, design: .serif)
                    .foregroundStyle(ink.opacity(dimmed ? 0.6 : 1.0))
                    .fixedSize(horizontal: false, vertical: true)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .scaledFont(12)
                        .foregroundStyle(ink.opacity(dimmed ? 0.4 : 0.6))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if showPantryPill {
                HStack(spacing: 4) {
                    Circle().fill(Color.stockedGold).frame(width: 7, height: 7)
                    Text("In pantry")
                        .scaledFont(10, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                }
            } else if showCartGlyph {
                Image(systemName: "cart.badge.plus")
                    .scaledFont(13)
                    .foregroundStyle(ink.opacity(0.35))
            }
            Image(systemName: "chevron.right")
                .scaledFont(12, weight: .semibold)
                .foregroundStyle(ink.opacity(onDark ? 0.45 : 0.3))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(fill, in: RoundedRectangle(cornerRadius: CookStyle.cardCorner))
        // Hit area == the visible rounded card, nothing more — same guarantee the full-bleed
        // treatment makes, so a tap never bleeds onto the neighbouring row.
        .contentShape(RoundedRectangle(cornerRadius: CookStyle.cardCorner))
    }

    // scaledToFit inside a fixed frame never overflows, so the art cannot extend the row's
    // layout or hit-test bounds the way a scaledToFill photo can.
    @ViewBuilder private var art: some View {
        if let photo = cookAssetImage(assetName) {
            photo
                .resizable()
                .scaledToFit()
                .frame(width: artSize, height: artSize)
                .opacity(dimmed ? 0.55 : 1.0)
        } else {
            ZStack {
                Circle()
                    .fill(onDark ? Color.stockedWhite.opacity(0.10) : Color.stockedGold.opacity(0.15))
                    .frame(width: artSize * 0.72, height: artSize * 0.72)
                if let fallbackEmoji {
                    Text(fallbackEmoji).font(.stockedSystem(size: artSize * 0.34))
                } else {
                    Image(systemName: fallbackIcon)
                        .font(.stockedSystem(size: artSize * 0.30, weight: .semibold))
                        .foregroundStyle(onDark ? Color.stockedWhite : Color.stockedGold)
                }
            }
            .frame(width: artSize, height: artSize)
            .opacity(dimmed ? 0.55 : 1.0)
        }
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
    var cardHeight: CGFloat = 92
    /// Defaults to the original full-bleed photo treatment. Pass `.illustrated` for the
    /// transparent cut-out row style.
    var render: CookCardRender = .fullBleed
    var tone: CookRowTone = .dark
    var action: (() -> Void)? = nil

    @ViewBuilder private var cardVisual: some View {
        if render == .illustrated {
            CookIllustratedRow(title: title, subtitle: subtitle, assetName: assetName,
                               fallbackEmoji: emoji, fallbackIcon: icon, tone: tone)
        } else if let photo = cookAssetImage(assetName) {
            photoCell(photo)
        } else {
            flatRow
        }
    }

    var body: some View {
        // When an action is provided, behave as a tappable button. When nil, render the visual
        // only, so this can serve as a NavigationLink label without an inner Button swallowing
        // the tap (that inner Button, plus allowsHitTesting(false), previously killed the tap).
        if let action {
            Button(action: action) { cardVisual }
                .buttonStyle(.plain)
        } else {
            cardVisual
        }
    }

    // Photo present: full-bleed image fills the whole cell, dark scrim on the left keeps the
    // emoji badge and title readable.
    private func photoCell(_ photo: Image) -> some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Color.black.opacity(0.28)).frame(width: 42, height: 42)
                Circle().strokeBorder(Color.white.opacity(0.55), lineWidth: 1).frame(width: 42, height: 42)
                if let emoji { Text(emoji).scaledFont(19) }
                else { Image(systemName: icon).scaledFont(17, weight: .semibold).foregroundStyle(Color.white) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(17, weight: .bold, design: .serif)
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.55), radius: 3, y: 1)
                if !subtitle.isEmpty {
                    Text(subtitle).scaledFont(12)
                        .foregroundStyle(Color.white.opacity(0.9))
                        .shadow(color: Color.black.opacity(0.55), radius: 2, y: 1)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").scaledFont(13, weight: .bold)
                .foregroundStyle(Color.white.opacity(0.9))
                .shadow(color: Color.black.opacity(0.5), radius: 2, y: 1)
        }
        .padding(.horizontal, 16)
        .frame(height: cardHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                photo.resizable().scaledToFill()
                LinearGradient(
                    colors: [Color.black.opacity(0.66), Color.black.opacity(0.34), Color.black.opacity(0.0)],
                    startPoint: .leading, endPoint: .trailing)
            }
            // Clip the scaledToFill image to the card BEFORE it becomes part of the layout /
            // hit-test bounds. Without this, the overflowing image extended the tappable area
            // past the visible card, so tapping the bottom of one card triggered the next.
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        )
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        // Hit area == the visible rounded card, nothing more. Enforced so a tap anywhere on
        // the card works, but never bleeds onto a neighboring card.
        .contentShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    // No photo: the clean icon + text row.
    private var flatRow: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().fill(Color.stockedGold.opacity(0.15)).frame(width: 44, height: 44)
                if let emoji { Text(emoji).scaledFont(20) }
                else {
                    Image(systemName: icon).scaledFont(18, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(16, weight: .semibold)
                    .foregroundStyle(session.themeTextColor)
                if !subtitle.isEmpty {
                    Text(subtitle).scaledFont(12)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                }
            }
            Spacer()
            Image(systemName: "chevron.right").scaledFont(13, weight: .semibold)
                .foregroundStyle(session.themeTextColor.opacity(0.3))
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: cardHeight, alignment: .leading)
        .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
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
                Image(systemName: icon).scaledFont(17, weight: .semibold).foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).scaledFont(14.5, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                Text(detail).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if action != nil {
                Image(systemName: "chevron.right").scaledFont(13, weight: .semibold)
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
    var usesUniformIcon: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                // `resolveOnline` defaults to FALSE, so a recipe with no stored
                // imageURL — every starter meal — went straight to the emoji
                // placeholder instead of looking an image up by name. That is the
                // wrong default for this card: it is the app's main recipe row.
                // Online recipes carry a URL and load it directly; the rest now
                // resolve through TheMealDB / Spoonacular / Foodish like the
                // Ready-to-Cook thumbnails already did.
                // Build 84 (STK-77-0005, from the field) - "all icons should be
                // bigger and match the style". The art was 56 pt in a 10 pt
                // corner while every illustrated Cook row runs bigger art in the
                // shared card corner with a serif title. Same language here now,
                // so a results row no longer reads as a different app from the
                // screen that led to it.
                if usesUniformIcon {
                    RoundedRectangle(cornerRadius: 14)
                        .fill(Color.stockedGold.opacity(0.12))
                        .frame(width: 68, height: 68)
                        .overlay {
                            Image(systemName: "fork.knife")
                                .scaledFont(24, weight: .semibold)
                                .foregroundStyle(Color.stockedGold)
                        }
                        .overlay {
                            RoundedRectangle(cornerRadius: 14)
                                .stroke(Color.stockedGold.opacity(0.18), lineWidth: 1)
                        }
                } else {
                    AsyncFoodImage(name: title, url: imageURL, size: 68, resolveOnline: true)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).scaledFont(16, weight: .semibold, design: .serif)
                        .foregroundStyle(session.themeTextColor).fixedSize(horizontal: false, vertical: true)
                    if !subtitle.isEmpty {
                        Text(subtitle).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.55))
                    }
                }
                Spacer()
                if let matchPercent {
                    Text("\(matchPercent)%").scaledFont(13, weight: .bold)
                        .foregroundStyle(Color.stockedGreen)
                }
            }
            .padding(.vertical, 12).padding(.horizontal, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(session.themeCardColor, in: RoundedRectangle(cornerRadius: CookStyle.cardCorner))
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
                        Text(mealType.uppercased()).scaledFont(10, weight: .bold)
                            .foregroundStyle(Color.stockedGold)
                    }
                    Text(title).scaledFont(15.5, weight: .semibold)
                        .foregroundStyle(session.themeTextColor).fixedSize(horizontal: false, vertical: true)
                    if !subtitle.isEmpty {
                        Text(subtitle).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.55))
                    }
                }
                Spacer()
                if isCooked {
                    Image(systemName: "checkmark.circle.fill").scaledFont(18)
                        .foregroundStyle(Color.stockedGreen)
                } else {
                    Image(systemName: "chevron.right").scaledFont(13, weight: .semibold)
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
                    .scaledFont(20)
                    .foregroundStyle(isDone ? Color.stockedGreen : session.themeTextColor.opacity(0.3))
                Text(title).scaledFont(15)
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
            Text(label).scaledFont(14, weight: .semibold).foregroundStyle(session.themeTextColor)
            StockedFlowLayout(spacing: 8, lineSpacing: 8) {
                ForEach(options, id: \.self) { opt in
                    let isSel = selection == opt
                    Button { selection = opt } label: {
                        Text(opt).scaledFont(13, weight: .medium)
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
            Image(systemName: "magnifyingglass").scaledFont(15)
                .foregroundStyle(session.themeTextColor.opacity(0.45))
            TextField(placeholder, text: $text)
                .scaledFont(15).foregroundStyle(session.themeTextColor)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").scaledFont(15)
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
                Text(label).scaledFont(14, weight: .semibold).foregroundStyle(session.themeTextColor)
            }
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { opt in
                    let isSel = selection == opt
                    Button { selection = opt } label: {
                        Text(opt).scaledFont(13, weight: .semibold)
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
            Image(systemName: icon).scaledFont(38)
                .foregroundStyle(session.themeTextColor.opacity(0.3))
            Text(title).scaledFont(18, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
            if !message.isEmpty {
                Text(message).scaledFont(13)
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            if let ctaTitle, let ctaAction {
                Button(action: ctaAction) {
                    Text(ctaTitle).scaledFont(15, weight: .semibold)
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
            Image(systemName: "exclamationmark.triangle.fill").scaledFont(34)
                .foregroundStyle(Color.stockedWarning)
            Text(message).scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.7))
                .multilineTextAlignment(.center)
            Button(action: retry) {
                Text("Try Again").scaledFont(15, weight: .semibold)
                    .foregroundStyle(Color.stockedWhite)
                    .padding(.vertical, 12).padding(.horizontal, 22)
                    .background(Color.stockedCharcoal, in: Capsule())
            }.buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40).padding(.horizontal, 24)
    }
}
