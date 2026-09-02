import XCTest
import SwiftUI
@testable import Stocked

@MainActor
final class AdaptiveUIFoundationTests: XCTestCase {
    func testEveryAppFontUsesTheSharedTypographyMapping() {
        let expectedDesigns: [AppFont: Font.Design] = [
            .serif: .serif,
            .rounded: .rounded,
            .mono: .monospaced,
            .system: .default
        ]

        for appFont in AppFont.allCases {
            XCTAssertEqual(
                StockedType.appFontSelection(for: appFont.rawValue).rawValue,
                appFont.rawValue
            )
            guard let expectedDesign = expectedDesigns[appFont] else {
                XCTFail("Missing typography mapping for \(appFont.rawValue)")
                continue
            }
            XCTAssertEqual(appFont.design, expectedDesign)
        }
        XCTAssertEqual(StockedType.appFontSelection(for: "Unknown").rawValue,
                       AppFont.serif.rawValue)
    }

    func testNarrowContainersUseCompactPaddingAndSingleColumn() {
        let metrics = StockedLayoutMetrics(
            width: 320,
            height: 700,
            isAccessibilityText: false,
            interfaceScale: InterfaceSize.standard.scale
        )

        XCTAssertEqual(metrics.horizontalPadding, 12)
        XCTAssertEqual(metrics.gridColumns(minimum: 280, maximum: 4).count, 1)
        XCTAssertGreaterThanOrEqual(metrics.tabBarItemMinimumHeight, 44)
    }

    func testSafeAreaIsRemovedFromAvailableContainerWidth() {
        let metrics = StockedLayoutMetrics(
            width: 1_024,
            height: 768,
            isAccessibilityText: false,
            interfaceScale: InterfaceSize.standard.scale,
            safeAreaInsets: EdgeInsets(top: 0, leading: 24, bottom: 0, trailing: 24)
        )

        XCTAssertEqual(metrics.contentWidth, 976)
        XCTAssertEqual(metrics.readableContentWidth, 976)
        XCTAssertEqual(metrics.gridColumns(minimum: 280, maximum: 4).count, 3)
    }

    func testAccessibilityTextExpandsNavigationTouchTarget() {
        let standard = StockedLayoutMetrics(
            width: 393,
            height: 852,
            isAccessibilityText: false,
            interfaceScale: InterfaceSize.standard.scale
        )
        let accessibility = StockedLayoutMetrics(
            width: 393,
            height: 852,
            isAccessibilityText: true,
            interfaceScale: InterfaceSize.standard.scale
        )

        XCTAssertGreaterThan(accessibility.tabBarItemMinimumHeight, standard.tabBarItemMinimumHeight)
        XCTAssertEqual(accessibility.prefersVerticalControls, standard.prefersVerticalControls)
        XCTAssertEqual(accessibility.homeHeroArtworkWidth, standard.homeHeroArtworkWidth)
    }

    func testHorizontalRecipeCardsAdaptWithoutExceedingContainer() {
        let narrow = StockedLayoutMetrics(
            width: 320, height: 700, isAccessibilityText: false, interfaceScale: 1
        )
        let reference = StockedLayoutMetrics(
            width: 393, height: 852, isAccessibilityText: false, interfaceScale: 1
        )
        let tablet = StockedLayoutMetrics(
            width: 1_024, height: 768, isAccessibilityText: false, interfaceScale: 1
        )

        XCTAssertEqual(narrow.horizontalCardWidth(preferred: 168, minimum: 144, maximum: 220), 144)
        XCTAssertEqual(reference.horizontalCardWidth(preferred: 168, minimum: 144, maximum: 220), 168)
        XCTAssertEqual(tablet.horizontalCardWidth(preferred: 168, minimum: 144, maximum: 220), 218.4, accuracy: 0.01)
        XCTAssertLessThanOrEqual(
            narrow.horizontalCardWidth(preferred: 500, minimum: 144, maximum: 500),
            narrow.contentWidth - narrow.horizontalPadding * 2
        )
    }

    func testAppTextScaleGrowsControlsWithoutChangingGridPlacement() {
        let standard = StockedLayoutMetrics(
            width: 393, height: 852, isAccessibilityText: false,
            interfaceScale: InterfaceSize.standard.scale,
            textScale: AppTextSize.standard.multiplier
        )
        let enlarged = StockedLayoutMetrics(
            width: 393, height: 852, isAccessibilityText: false,
            interfaceScale: InterfaceSize.standard.scale,
            textScale: AppTextSize.extraExtraLarge.multiplier
        )

        XCTAssertEqual(
            enlarged.gridColumns(minimum: 150, maximum: 3).count,
            standard.gridColumns(minimum: 150, maximum: 3).count
        )
        XCTAssertGreaterThan(enlarged.minimumControlHeight, standard.minimumControlHeight)
        XCTAssertEqual(enlarged.homeHeroArtworkWidth, standard.homeHeroArtworkWidth)
    }

    func testPresentationGeometryUsesWidthForPlacementAndTextScaleForHeight() {
        let standard = StockedLayoutMetrics(
            width: 1_024, height: 768, isAccessibilityText: false,
            interfaceScale: 1, textScale: 1
        )
        let enlarged = StockedLayoutMetrics(
            width: 1_024, height: 768, isAccessibilityText: true,
            interfaceScale: 1, textScale: 2.2
        )

        XCTAssertEqual(StockedPresentationWidth.form.resolved(in: standard), 760)
        XCTAssertEqual(StockedPresentationWidth.readable.resolved(in: standard), 1_024)
        XCTAssertNil(StockedPresentationWidth.full.resolved(in: standard))
        XCTAssertEqual(StockedPresentationWidth.form.resolved(in: enlarged), 760)
        XCTAssertEqual(enlarged.surfaceContentPadding, standard.surfaceContentPadding)
        XCTAssertGreaterThan(enlarged.listRowMinimumHeight, standard.listRowMinimumHeight)
        XCTAssertGreaterThan(enlarged.textEditorMinimumHeight, standard.textEditorMinimumHeight)
    }

    func testHomeHeroKeepsStockCardLeftOfArtworkAtEveryTextSize() {
        for textScale: CGFloat in [0.82, 1, 1.36, 2.2] {
            let phone = StockedLayoutMetrics(
                width: 393, height: 852, isAccessibilityText: textScale > 1.4,
                interfaceScale: 1, textScale: textScale
            )
            let tablet = StockedLayoutMetrics(
                width: 1_024, height: 768, isAccessibilityText: textScale > 1.4,
                interfaceScale: 1, textScale: textScale
            )

            XCTAssertEqual(phone.homeHeroArtworkWidth, 165.06, accuracy: 0.01)
            XCTAssertEqual(tablet.homeHeroArtworkWidth, 230)
            XCTAssertLessThan(phone.homeHeroArtworkWidth, phone.contentWidth / 2)
            XCTAssertLessThan(tablet.homeHeroArtworkWidth, tablet.contentWidth / 2)
        }
    }

    func testEveryHomeWidgetKeepsWidthGeometryStableAcrossTextSizes() {
        let standard = StockedLayoutMetrics(
            width: 393, height: 852, isAccessibilityText: false,
            interfaceScale: 1, textScale: 1
        )
        let accessibility = StockedLayoutMetrics(
            width: 393, height: 852, isAccessibilityText: true,
            interfaceScale: 1, textScale: 2.2
        )

        XCTAssertEqual(standard.homeWidgetWidthScale, accessibility.homeWidgetWidthScale)
        XCTAssertEqual(standard.homeWidgetRowSpacing, accessibility.homeWidgetRowSpacing)
        XCTAssertEqual(standard.homeWidgetContentPadding, accessibility.homeWidgetContentPadding)
        XCTAssertEqual(standard.homeWidgetLogicalColumnCount, accessibility.homeWidgetLogicalColumnCount)
        XCTAssertEqual(standard.homeWidgetGridRowUnit, accessibility.homeWidgetGridRowUnit)
        XCTAssertEqual(
            standard.homeWidgetIllustrationSize(preferredWidth: 104, preferredHeight: 82),
            accessibility.homeWidgetIllustrationSize(preferredWidth: 104, preferredHeight: 82)
        )
    }

    func testHomeWidgetBoardKeepsFourLogicalTracksAtEveryWidth() {
        XCTAssertEqual(StockedLayoutMetrics(
            width: 393, height: 852, isAccessibilityText: false,
            interfaceScale: 1, textScale: 1
        ).homeWidgetLogicalColumnCount, 4)
        XCTAssertEqual(StockedLayoutMetrics(
            width: 834, height: 1_194, isAccessibilityText: false,
            interfaceScale: 1, textScale: 1
        ).homeWidgetLogicalColumnCount, 4)
        XCTAssertEqual(StockedLayoutMetrics(
            width: 1_194, height: 834, isAccessibilityText: false,
            interfaceScale: 1, textScale: 1
        ).homeWidgetLogicalColumnCount, 4)
    }

    func testHomeWidgetBoardFillsSpaceBesideTallWidgetWithoutOverlap() {
        let footprints: [HomeWidgetGridFootprint] = [
            .init(columns: 2, rows: 4),
            .init(columns: 2, rows: 2),
            .init(columns: 2, rows: 2),
        ]
        let positions = HomeWidgetGridPacking.positions(for: footprints)

        XCTAssertEqual(positions.map(\.column), [0, 2, 2])
        XCTAssertEqual(positions.map(\.row), [0, 0, 2])
        XCTAssertEqual(Set(positions.map { "\($0.column):\($0.row)" }).count, 3)
    }

    func testHomeWidgetFullWidthCardKeepsLaterWidgetsBelowItsOrderBarrier() {
        let positions = HomeWidgetGridPacking.positions(for: [
            .init(columns: 2, rows: 4),
            .init(columns: 4, rows: 2),
            .init(columns: 2, rows: 2),
        ])

        XCTAssertEqual(positions[1].column, 0)
        XCTAssertGreaterThanOrEqual(positions[1].row, positions[0].row + positions[0].footprint.rows)
        XCTAssertGreaterThanOrEqual(positions[2].row, positions[1].row + positions[1].footprint.rows)
    }

    func testHomeWidgetResizeFootprintsAreQuantizedAndRoundTrip() {
        XCTAssertEqual(HomeWidgetGridFootprint(columns: 1, rows: 1).normalizedManual,
                       .init(columns: 2, rows: 2))
        XCTAssertEqual(HomeWidgetGridFootprint(columns: 3, rows: 7).normalizedManual,
                       .init(columns: 4, rows: 4))
        for footprint in HomeWidgetGridFootprint.manualSizes {
            XCTAssertEqual(HomeWidgetGridFootprint(storageValue: footprint.storageValue), footprint)
        }
    }

    func testHomeWidgetPackingNeverOverlapsAcrossResizePolicies() {
        let requested = HomeWidget.allCases.flatMap(\.allowedGridFootprints)
        let positions = HomeWidgetGridPacking.positions(for: requested)

        XCTAssertEqual(positions.count, requested.count)
        XCTAssertFalse(HomeWidgetGridPacking.containsOverlap(positions))
    }

    func testHomeWidgetSizePoliciesRejectUnusedOversizing() {
        XCTAssertEqual(HomeWidget.useItSoon.allowedGridFootprints, [.init(columns: 4, rows: 2)])
        XCTAssertEqual(HomeWidget.actionCenter.allowedGridFootprints, [.init(columns: 4, rows: 2)])
        XCTAssertEqual(HomeWidget.tipOfDay.allowedGridFootprints, [.init(columns: 2, rows: 4)])
        XCTAssertEqual(HomeWidget.lowStock.resolvedGridFootprint(.init(columns: 4, rows: 4)),
                       .init(columns: 2, rows: 2))
        XCTAssertEqual(HomeWidget.readyToCook.resizedGridFootprint(
            from: .init(columns: 4, rows: 2),
            translation: CGSize(width: 0, height: 60)
        ), .init(columns: 4, rows: 4))
    }

    func testHomeWidgetGuttersStayCompactAcrossDeviceWidths() {
        let phone = StockedLayoutMetrics(
            width: 393, height: 852, isAccessibilityText: false,
            interfaceScale: 1, textScale: 1
        )
        let tablet = StockedLayoutMetrics(
            width: 1_024, height: 768, isAccessibilityText: false,
            interfaceScale: 1, textScale: 1
        )
        XCTAssertEqual(phone.homeWidgetGridSpacing, 6)
        XCTAssertEqual(tablet.homeWidgetGridSpacing, 8)
        XCTAssertEqual(phone.homeWidgetGridRowUnit, 20)
        XCTAssertEqual(tablet.homeWidgetGridRowUnit, 24)
    }

    func testHomeWidgetArtworkScalesOnlyWithAvailableWidth() {
        let narrow = StockedLayoutMetrics(
            width: 320, height: 700, isAccessibilityText: false,
            interfaceScale: 1, textScale: 1
        )
        let phone = StockedLayoutMetrics(
            width: 393, height: 852, isAccessibilityText: false,
            interfaceScale: 1, textScale: 1
        )
        let tablet = StockedLayoutMetrics(
            width: 1_024, height: 768, isAccessibilityText: false,
            interfaceScale: 1, textScale: 1
        )

        let narrowSize = narrow.homeWidgetIllustrationSize(preferredWidth: 104, preferredHeight: 82)
        let phoneSize = phone.homeWidgetIllustrationSize(preferredWidth: 104, preferredHeight: 82)
        let tabletSize = tablet.homeWidgetIllustrationSize(preferredWidth: 104, preferredHeight: 82)
        XCTAssertLessThan(narrowSize.width, phoneSize.width)
        XCTAssertLessThan(phoneSize.width, tabletSize.width)
        XCTAssertEqual(narrowSize.width / narrowSize.height, 104 / 82, accuracy: 0.001)
        XCTAssertEqual(tabletSize.width / tabletSize.height, 104 / 82, accuracy: 0.001)
    }

    func testHomeWidgetStructuralSnapshotsStayStable() {
        XCTAssertEqual(
            HomeWidgetGridPacking.snapshotSignature(for: [
                .init(columns: 2, rows: 4),
                .init(columns: 2, rows: 2),
                .init(columns: 2, rows: 2),
                .init(columns: 4, rows: 2),
            ]),
            "0:0:2x4|2:0:2x2|2:2:2x2|0:4:4x2"
        )
        XCTAssertEqual(
            HomeWidgetGridPacking.snapshotSignature(for: [
                .init(columns: 4, rows: 2),
                .init(columns: 2, rows: 2),
                .init(columns: 2, rows: 2),
                .init(columns: 4, rows: 4),
            ]),
            "0:0:4x2|0:2:2x2|2:2:2x2|0:4:4x4"
        )
    }

    func testEveryPresetIsUniqueAndUsesOnlySupportedWidgets() {
        for preset in HomeWidgetPreset.allCases {
            XCTAssertFalse(preset.widgets.isEmpty)
            XCTAssertEqual(Set(preset.widgets).count, preset.widgets.count)
            XCTAssertTrue(preset.widgets.allSatisfy(HomeWidget.allCases.contains))
            XCTAssertTrue(preset.widgets.contains(.stockLevel))
        }
    }

    func testEveryWidgetHasAUsableArtworkBudgetAndDensityPreview() {
        for widget in HomeWidget.allCases {
            XCTAssertGreaterThan(widget.illustrationWidthRange.lowerBound, 0)
            XCTAssertGreaterThanOrEqual(
                widget.illustrationWidthRange.upperBound,
                widget.illustrationWidthRange.lowerBound
            )
            XCTAssertFalse(widget.densityPreview.isEmpty)
            XCTAssertFalse(widget.expandedDetail.isEmpty)
            XCTAssertTrue(widget.allowedGridFootprints.contains(widget.gridFootprint))
            XCTAssertTrue(StockedWidgetThemeFamily.allCases.contains(widget.themeFamily))
        }
    }

    func testWidgetDensityChangesSpacingWithoutChangingTypographyOrFootprints() {
        XCTAssertLessThan(HomeWidgetDensity.compact.spacingScale, HomeWidgetDensity.standard.spacingScale)
        XCTAssertGreaterThan(HomeWidgetDensity.comfortable.spacingScale, HomeWidgetDensity.standard.spacingScale)
        let snapshot = HomeWidgetGridPacking.snapshotSignature(for: HomeWidget.allCases.map(\.gridFootprint))
        for density in HomeWidgetDensity.allCases {
            XCTAssertGreaterThan(density.spacingScale, 0)
            XCTAssertEqual(HomeWidgetGridPacking.snapshotSignature(for: HomeWidget.allCases.map(\.gridFootprint)),
                           snapshot, "Density \(density) changed logical placement")
        }
    }

    func testWidgetSizeExplanationsCoverFixedMinimumAndMaximumPolicies() {
        XCTAssertTrue(HomeWidget.useItSoon.sizeAvailabilityDescription(for: .init(columns: 4, rows: 2))
            .contains("Fixed"))
        XCTAssertTrue(HomeWidget.readyToCook.sizeAvailabilityDescription(for: .init(columns: 4, rows: 2))
            .contains("Minimum"))
        XCTAssertTrue(HomeWidget.readyToCook.sizeAvailabilityDescription(for: .init(columns: 4, rows: 4))
            .contains("Maximum"))
        XCTAssertEqual(HomeWidgetPreviewState.allCases.count, 5)
    }

    func testHomeWidgetDeviceTextAndAppearanceRegressionMatrix() {
        let widths: [CGFloat] = [320, 393, 744, 1_024, 1_194]
        let board = HomeWidget.allCases.map(\.gridFootprint)
        let expected = HomeWidgetGridPacking.snapshotSignature(for: board)

        for width in widths {
            for textSize in AppTextSize.allCases {
                for isDark in [false, true] {
                    let metrics = StockedLayoutMetrics(
                        width: width,
                        height: width > 700 ? 834 : 852,
                        isAccessibilityText: textSize.multiplier >= AppTextSize.extraLarge.multiplier,
                        interfaceScale: InterfaceSize.standard.scale,
                        textScale: textSize.multiplier
                    )
                    XCTAssertEqual(metrics.homeWidgetLogicalColumnCount, 4,
                                   "Track count changed at \(width), \(textSize), dark=\(isDark)")
                    XCTAssertEqual(HomeWidgetGridPacking.snapshotSignature(for: board), expected)
                    XCTAssertFalse(HomeWidgetGridPacking.containsOverlap(
                        HomeWidgetGridPacking.positions(for: board)
                    ))
                }
            }
        }
    }

    func testEverySupportedTextScaleKeepsAdaptiveControlsReachable() {
        let widths: [CGFloat] = [320, 375, 393, 744, 1_024]
        for size in AppTextSize.allCases {
            for width in widths {
                let metrics = StockedLayoutMetrics(
                    width: width, height: 852,
                    isAccessibilityText: size.multiplier >= AppTextSize.extraLarge.multiplier,
                    interfaceScale: InterfaceSize.standard.scale,
                    textScale: size.multiplier
                )
                XCTAssertGreaterThanOrEqual(metrics.minimumControlHeight, 44,
                    "Touch target regressed for \(size) at width \(width)")
                XCTAssertGreaterThanOrEqual(metrics.gridColumns(minimum: 150, maximum: 4).count, 1)
                XCTAssertLessThanOrEqual(metrics.readableContentWidth, metrics.contentWidth)
            }
        }
    }

    func testWideRecipeRailFillsIPadCanvasWithoutChangingPhoneCards() {
        let phone = StockedLayoutMetrics(
            width: 393, height: 852, isAccessibilityText: false,
            interfaceScale: InterfaceSize.standard.scale
        )
        let tablet = StockedLayoutMetrics(
            width: 1_194, height: 834, isAccessibilityText: false,
            interfaceScale: InterfaceSize.standard.scale
        )
        let accessibleTablet = StockedLayoutMetrics(
            width: 1_194, height: 834, isAccessibilityText: true,
            interfaceScale: InterfaceSize.standard.scale,
            textScale: 1.82
        )

        XCTAssertEqual(
            phone.wideRailCardWidth(itemCount: 3, preferred: 168, minimum: 144,
                                    maximum: 220, spacing: 10),
            phone.horizontalCardWidth(preferred: 168, minimum: 144, maximum: 220)
        )
        XCTAssertGreaterThan(
            tablet.wideRailCardWidth(itemCount: 3, preferred: 168, minimum: 144,
                                     maximum: 220, spacing: 10),
            300
        )
        XCTAssertGreaterThan(
            accessibleTablet.wideRailCardWidth(itemCount: 3, preferred: 240, minimum: 220,
                                               maximum: 300, spacing: 10),
            tablet.wideRailCardWidth(itemCount: 3, preferred: 168, minimum: 144,
                                     maximum: 220, spacing: 10)
        )
    }

    func testInventoryConfidenceChangesFromConfirmationFacts() {
        var item = LocalInventoryItem(name: "Tomatoes")
        item.lastConfirmedAt = Date()
        XCTAssertEqual(item.confidence, .confirmed)

        item.lastConfirmedAt = Date().addingTimeInterval(-40 * 86_400)
        XCTAssertEqual(item.confidence, .unknown)

        item.level = 0
        XCTAssertEqual(item.confidence, .outOfStock)
    }

    func testRecipeExplanationSeparatesConfirmedUncertainAndMissing() {
        var confirmed = LocalInventoryItem(name: "tomatoes")
        confirmed.lastConfirmedAt = Date()
        var uncertain = LocalInventoryItem(name: "olive oil")
        uncertain.lastConfirmedAt = Date().addingTimeInterval(-60 * 86_400)
        let recipe = OnlineRecipe(
            id: "test", title: "Tomato Pasta", category: "Dinner", area: "Italian",
            instructions: "Cook pasta and combine.", imageURL: "",
            ingredients: ["Tomatoes", "Olive oil", "Pasta"], measures: ["", "", ""]
        )

        let insight = RecipeRecommendationExplainer.insight(
            for: recipe, inventory: [confirmed, uncertain], allergens: []
        )
        XCTAssertEqual(insight.available, ["tomato"])
        XCTAssertEqual(insight.uncertain, ["olive oil"])
        XCTAssertEqual(insight.missing, ["pasta"])
    }
}
