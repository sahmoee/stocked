import XCTest
import SwiftUI
import UIKit
@testable import Stocked

/// Structural regression coverage for app-wide motion, scrolling, and alignment.
///
/// These tests deliberately exercise pure layout contracts instead of comparing
/// simulator pixels. That keeps the suite deterministic while still catching the
/// regressions users notice: columns moving at large type sizes, rails leaving a
/// partial card at an edge, controls losing their shared height, and widgets
/// changing identity or overlapping after a resize.
@MainActor
final class MotionAlignmentTests: XCTestCase {
    private let phoneWidths: [CGFloat] = [320, 375, 393, 430]
    private let wideWidths: [CGFloat] = [700, 834, 1_024, 1_194]
    private let textScales: [CGFloat] = [0.82, 1, 1.36, 1.52, 1.82, 2.2]

    private func metrics(
        width: CGFloat,
        height: CGFloat = 852,
        textScale: CGFloat = 1,
        safeArea: EdgeInsets = EdgeInsets()
    ) -> StockedLayoutMetrics {
        StockedLayoutMetrics(
            width: width,
            height: height,
            isAccessibilityText: textScale >= 1.5,
            interfaceScale: InterfaceSize.standard.scale,
            textScale: textScale,
            safeAreaInsets: safeArea
        )
    }

    // MARK: Container and alignment contracts

    func testDeviceWidthMatrixUsesWindowWidthRatherThanNamedHardware() {
        XCTAssertEqual(StockedDevice.current(width: 320, hSize: .compact).scale, 0.88)
        XCTAssertEqual(StockedDevice.current(width: 375, hSize: .compact).scale, 0.88)
        XCTAssertEqual(StockedDevice.current(width: 393, hSize: .compact).scale, 1)
        XCTAssertEqual(StockedDevice.current(width: 430, hSize: .compact).scale, 1.08)
        XCTAssertEqual(StockedDevice.current(width: 700, hSize: .regular).scale, 1.2)
    }

    func testPageGuttersRemainAlignedAcrossPhoneAndWideWidths() {
        for width in phoneWidths + wideWidths {
            let layout = metrics(
                width: width,
                safeArea: EdgeInsets(top: 0, leading: 11, bottom: 0, trailing: 17)
            )
            let leftEdge = layout.safeAreaInsets.leading + layout.horizontalPadding
            let rightEdge = layout.width - layout.safeAreaInsets.trailing - layout.horizontalPadding

            XCTAssertEqual(rightEdge - leftEdge,
                           layout.contentWidth - layout.horizontalPadding * 2,
                           accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(leftEdge, layout.safeAreaInsets.leading)
            XCTAssertLessThanOrEqual(rightEdge, layout.width - layout.safeAreaInsets.trailing)
        }
    }

    func testReadableAndFormContainersCanBeCenteredWithoutOverflow() {
        for width in phoneWidths + wideWidths {
            let layout = metrics(width: width)
            let readableInset = (layout.contentWidth - layout.readableContentWidth) / 2
            let formInset = (layout.contentWidth - layout.formContentWidth) / 2

            XCTAssertGreaterThanOrEqual(readableInset, 0)
            XCTAssertGreaterThanOrEqual(formInset, 0)
            XCTAssertLessThanOrEqual(layout.formContentWidth, layout.readableContentWidth)
            XCTAssertLessThanOrEqual(layout.readableContentWidth, layout.contentWidth)
        }
    }

    func testDynamicTypeDoesNotMoveControlsToDifferentColumns() {
        for width in phoneWidths + wideWidths {
            let baseline = metrics(width: width, textScale: 1)
            for textScale in textScales {
                let enlarged = metrics(width: width, textScale: textScale)
                XCTAssertEqual(enlarged.prefersVerticalControls, baseline.prefersVerticalControls)
                XCTAssertEqual(enlarged.gridColumns(minimum: 148, maximum: 4).count,
                               baseline.gridColumns(minimum: 148, maximum: 4).count)
                XCTAssertEqual(enlarged.homeWidgetLogicalColumnCount,
                               baseline.homeWidgetLogicalColumnCount)
                XCTAssertEqual(enlarged.homeHeroArtworkWidth, baseline.homeHeroArtworkWidth)
            }
        }
    }

    func testDynamicTypeGrowsSharedControlHeightMonotonically() {
        for width in phoneWidths + wideWidths {
            let heights = textScales.map { metrics(width: width, textScale: $0).minimumControlHeight }
            XCTAssertEqual(heights, heights.sorted())
            XCTAssertGreaterThanOrEqual(heights.first ?? 0, 44)
            XCTAssertGreaterThan(heights.last ?? 0, heights.first ?? 0)
        }
    }

    func testPairedControlsReceiveTheSameHeightFloorAndColumnGeometry() {
        for width in phoneWidths + wideWidths {
            for textScale in textScales {
                let layout = metrics(width: width, textScale: textScale)
                let pairedColumns = layout.gridColumns(minimum: 150, maximum: 2, spacing: 8)

                XCTAssertGreaterThanOrEqual(layout.minimumControlHeight, 44)
                XCTAssertTrue((1...2).contains(pairedColumns.count))
                XCTAssertTrue(pairedColumns.allSatisfy { $0.spacing == 8 })
            }
        }
    }

    func testSharedEqualHeightAndAlignedLabelPrimitivesCompileTogether() {
        _ = AnyView(
            StockedEqualHeightRow(spacing: 8) {
                Button("Short") {}
                Button("A longer action that wraps") {}
            }
        )
        _ = AnyView(
            StockedAlignedControlLabel(
                icon: "bell",
                title: "Notifications",
                subtitle: "A longer accessibility-sized explanation"
            ) {
                Image(systemName: "chevron.right")
            }
        )
    }

    // MARK: Horizontal rails and settling

    func testHorizontalCardsStayInsideAlignedPageEdges() {
        for width in phoneWidths + wideWidths {
            let layout = metrics(width: width)
            let cardWidth = layout.horizontalCardWidth(
                preferred: 248,
                minimum: 180,
                maximum: 320
            )
            let available = layout.contentWidth - layout.horizontalPadding * 2

            XCTAssertGreaterThan(cardWidth, 0)
            XCTAssertLessThanOrEqual(cardWidth, available)
            XCTAssertLessThanOrEqual(cardWidth, 320)
        }
    }

    func testWideRailCardsFillReadableCanvasWithoutTrailingDeadSpace() {
        for width in wideWidths {
            let layout = metrics(width: width)
            let spacing: CGFloat = 12
            let cardWidth = layout.wideRailCardWidth(
                itemCount: 3,
                preferred: 220,
                minimum: 180,
                maximum: 320,
                spacing: spacing
            )
            let occupied = cardWidth * 3 + spacing * 2

            XCTAssertEqual(occupied, layout.readableContentWidth - 36, accuracy: 0.001)
        }
    }

    func testAccessibilityWideRailsUseTwoReadableColumns() {
        for width in wideWidths {
            let layout = metrics(width: width, textScale: 2.2)
            let spacing: CGFloat = 12
            let cardWidth = layout.wideRailCardWidth(
                itemCount: 4,
                preferred: 220,
                minimum: 180,
                maximum: 320,
                spacing: spacing
            )

            XCTAssertEqual(cardWidth * 2 + spacing,
                           layout.readableContentWidth - 36,
                           accuracy: 0.001)
        }
    }

    func testCenteredRailMarginsPlaceEdgeCardCentersAtViewportCenter() {
        for width in phoneWidths + wideWidths {
            let layout = metrics(width: width)
            let cardWidth = layout.horizontalCardWidth(
                preferred: 168,
                minimum: 144,
                maximum: 320
            )
            let margin = layout.centeredRailContentMargin(cardWidth: cardWidth)

            XCTAssertEqual(margin + cardWidth / 2,
                           layout.contentWidth / 2,
                           accuracy: 0.001)
            XCTAssertGreaterThanOrEqual(margin, layout.horizontalPadding)
        }
    }

    func testCenteredRailMarginKeepsPageGutterForOversizedCards() {
        let layout = metrics(width: 320)
        XCTAssertEqual(
            layout.centeredRailContentMargin(cardWidth: 500),
            layout.horizontalPadding
        )
    }

    func testRecipeFeatureHeroGrowsVerticallyWithTextScale() {
        let standard = metrics(width: 393, textScale: 1)
        let accessibility = metrics(width: 393, textScale: 2.2)

        XCTAssertEqual(standard.recipeFeatureHeroMinimumHeight, 190)
        XCTAssertGreaterThan(accessibility.recipeFeatureHeroMinimumHeight,
                             standard.recipeFeatureHeroMinimumHeight)
        XCTAssertEqual(accessibility.horizontalPadding, standard.horizontalPadding)
    }

    func testHorizontalSnapModifierRemainsAvailableToEveryRail() {
        // Compilation is the contract here: horizontal rails must share one modifier
        // rather than silently reverting to ad-hoc target and bounce behavior.
        _ = AnyView(
            HStack { Text("First"); Text("Second") }
                .stockedScrollTargetLayout()
                .stockedHorizontalSnap()
        )
    }

    // MARK: Motion accessibility and magnetic resizing

    func testMotionHelperMatchesSystemReduceMotionPreference() {
        let animation = Animation.stockedMotion(.spring(response: 0.3, dampingFraction: 0.8))
        if UIAccessibility.isReduceMotionEnabled {
            XCTAssertNil(animation)
        } else {
            XCTAssertNotNil(animation)
        }
    }

    func testResizeMagnetIgnoresMovementInsideDeadZone() {
        let start = HomeWidgetGridFootprint(columns: 2, rows: 2)
        for translation in [
            CGSize(width: 31, height: 0),
            CGSize(width: -31, height: 0),
            CGSize(width: 0, height: 31),
            CGSize(width: 0, height: -31),
        ] {
            XCTAssertEqual(HomeWidget.lowStock.resizedGridFootprint(
                from: start,
                translation: translation
            ), start)
        }
    }

    func testResizeMagnetSnapsOncePastThreshold() {
        XCTAssertEqual(HomeWidget.lowStock.resizedGridFootprint(
            from: .init(columns: 2, rows: 2),
            translation: CGSize(width: 33, height: 0)
        ), .init(columns: 4, rows: 2))

        XCTAssertEqual(HomeWidget.readyToCook.resizedGridFootprint(
            from: .init(columns: 4, rows: 2),
            translation: CGSize(width: 0, height: 33)
        ), .init(columns: 4, rows: 4))

        XCTAssertEqual(HomeWidget.readyToCook.resizedGridFootprint(
            from: .init(columns: 4, rows: 4),
            translation: CGSize(width: 0, height: -33)
        ), .init(columns: 4, rows: 2))
    }

    // MARK: Widget alignment and stable scroll identity

    func testMixedWidgetFootprintsPackWithoutOverlap() {
        let footprints: [HomeWidgetGridFootprint] = [
            .init(columns: 2, rows: 4),
            .init(columns: 2, rows: 2),
            .init(columns: 2, rows: 2),
            .init(columns: 4, rows: 2),
            .init(columns: 2, rows: 2),
            .init(columns: 4, rows: 4),
        ]
        let positions = HomeWidgetGridPacking.positions(for: footprints)

        XCTAssertEqual(positions.count, footprints.count)
        XCTAssertFalse(HomeWidgetGridPacking.containsOverlap(positions))
    }

    func testFullWidthWidgetsAlwaysAlignToLeadingGridColumn() {
        let requested = HomeWidget.allCases.map(\.gridFootprint)
        let positions = HomeWidgetGridPacking.positions(for: requested)

        XCTAssertTrue(positions
            .filter { $0.footprint.columns == 4 }
            .allSatisfy { $0.column == 0 })
    }

    func testWidgetPackingIdentityIsStableAcrossRepeatedLayoutPasses() {
        let requested = HomeWidget.allCases.map(\.gridFootprint)
        let expected = HomeWidgetGridPacking.snapshotSignature(for: requested)

        for _ in 0..<20 {
            XCTAssertEqual(HomeWidgetGridPacking.snapshotSignature(for: requested), expected)
        }
    }

    func testWidgetIDsRemainUniqueAndStableForScrollRestoration() {
        let identifiers = HomeWidget.allCases.map(\.rawValue)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
        XCTAssertEqual(identifiers.compactMap(HomeWidget.init(rawValue:)), HomeWidget.allCases)
    }

    func testArtworkKeepsAspectRatioWhileCenterColumnScales() {
        let expectedRatio: CGFloat = 104 / 82
        for width in phoneWidths + wideWidths {
            for textScale in textScales {
                let size = metrics(width: width, textScale: textScale)
                    .homeWidgetIllustrationSize(preferredWidth: 104, preferredHeight: 82)

                XCTAssertEqual(size.width / size.height, expectedRatio, accuracy: 0.001)
            }
        }
    }

    // MARK: Shared app-wide motion and scroll APIs

    func testSemanticSpringTokensHaveOrderedSettlingCharacteristics() {
        XCTAssertEqual(StockedMotion.Spring.allCases.map(\.rawValue), [
            "press", "selection", "standard", "navigation", "settle",
        ])
        XCTAssertLessThan(StockedMotion.Spring.press.response,
                          StockedMotion.Spring.standard.response)
        XCTAssertLessThan(StockedMotion.Spring.standard.response,
                          StockedMotion.Spring.settle.response)
        XCTAssertGreaterThan(StockedMotion.Spring.settle.dampingFraction,
                             StockedMotion.Spring.press.dampingFraction)
    }

    func testSharedPolicyDisablesSpatialAndDecorativeMotionUnderReduceMotion() {
        let policy = StockedMotionPolicy(reduceMotion: true)

        XCTAssertFalse(policy.permitsSpatialMotion)
        XCTAssertFalse(policy.permitsDecorativeMotion)
        XCTAssertFalse(policy.permitsContinuousMotion)
        XCTAssertNil(policy.animation(.settle, intent: .spatial))
        XCTAssertNil(policy.animation(.selection, intent: .decorative))
        XCTAssertNil(policy.animation(.standard, intent: .continuous))
        XCTAssertNotNil(policy.animation(.standard, intent: .opacity))
    }

    func testSharedPolicyKeepsSemanticMotionWhenReduceMotionIsOff() {
        let policy = StockedMotionPolicy(reduceMotion: false)

        XCTAssertTrue(policy.permitsSpatialMotion)
        XCTAssertTrue(policy.permitsDecorativeMotion)
        XCTAssertTrue(policy.permitsContinuousMotion)
        XCTAssertNotNil(policy.animation(.press, intent: .spatial))
        XCTAssertNotNil(policy.animation(.navigation, intent: .opacity))
    }

    func testEverySharedScrollBehaviorCompilesForPageAndRailAdoption() {
        _ = AnyView(
            LazyVStack { Text("Section") }
                .stockedSnapTargetLayout()
                .stockedSectionSnapping()
                .stockedSizeAwareScrollBounce(.vertical)
        )
        _ = AnyView(
            LazyHStack { Text("Card") }
                .stockedSnapTargetLayout()
                .stockedRailSnapping()
                .stockedSizeAwareScrollBounce(.horizontal)
        )
        _ = AnyView(
            LazyHStack { Text("Card wrapper") }
                .stockedSnapTargetLayout()
                .stockedCardRailSnap()
        )
        _ = AnyView(
            LazyHStack { Text("Filter") }
                .stockedSnapTargetLayout()
                .stockedChipRailSnapping()
                .stockedHorizontalSnap()
        )
        _ = AnyView(
            HStack { Text("Page") }
                .stockedSnapTargetLayout()
                .stockedPageSnapping(.horizontal)
        )
        _ = AnyView(
            ScrollView {
                CachedLocalDataImage(
                    data: nil,
                    maxDimension: 64,
                    width: 44,
                    height: 44,
                    clip: .circle
                ) {
                    Color.clear.frame(width: 44, height: 44)
                }
            }
            .stockedTrackedScrollScope()
        )
    }

    func testIdleScrollActivityHasNoVelocityOrDeferredWork() {
        let activity = StockedScrollActivity.idle

        XCTAssertEqual(activity.phase, .idle)
        XCTAssertFalse(activity.isScrolling)
        XCTAssertFalse(activity.isDirectInteraction)
        XCTAssertFalse(activity.shouldDeferExpensiveWork)
        XCTAssertTrue(activity.mayLoadVisibleImages)
        XCTAssertTrue(activity.mayPrefetchRemoteImages)
        XCTAssertEqual(activity.velocity(along: .horizontal), 0)
        XCTAssertEqual(activity.velocity(along: .vertical), 0)
    }

    func testInteractingScrollActivityDefersExpensiveWork() {
        let activity = StockedScrollActivity(
            phase: .interacting,
            horizontalVelocity: 640,
            verticalVelocity: -120,
            transitionSequence: 4
        )

        XCTAssertTrue(activity.isScrolling)
        XCTAssertTrue(activity.isDirectInteraction)
        XCTAssertTrue(activity.shouldDeferExpensiveWork)
        XCTAssertFalse(activity.mayLoadVisibleImages)
        XCTAssertFalse(activity.mayPrefetchRemoteImages)
        XCTAssertEqual(activity.velocity(along: .horizontal), 640)
        XCTAssertEqual(activity.velocity(along: .vertical), -120)
    }

    func testVelocitySnapUsesDistanceForSlowDragsAndVelocityForFlicks() {
        let policy = StockedVelocitySnapPolicy()

        XCTAssertEqual(policy.targetIndex(
            currentIndex: 2, currentOffset: 220, itemExtent: 100,
            velocity: 0, itemCount: 6
        ), 2)
        XCTAssertEqual(policy.targetIndex(
            currentIndex: 2, currentOffset: 229, itemExtent: 100,
            velocity: 0, itemCount: 6
        ), 3)
        XCTAssertEqual(policy.targetIndex(
            currentIndex: 2, currentOffset: 200, itemExtent: 100,
            velocity: 500, itemCount: 6
        ), 3)
        XCTAssertEqual(policy.targetIndex(
            currentIndex: 2, currentOffset: 200, itemExtent: 100,
            velocity: -500, itemCount: 6
        ), 1)
    }

    func testVelocitySnapClampsAtRailEdgesAndAdvancesOnlyOneCard() {
        let policy = StockedVelocitySnapPolicy()

        XCTAssertEqual(policy.targetIndex(
            currentIndex: 0, currentOffset: 0, itemExtent: 100,
            velocity: -2_000, itemCount: 5
        ), 0)
        XCTAssertEqual(policy.targetIndex(
            currentIndex: 4, currentOffset: 400, itemExtent: 100,
            velocity: 2_000, itemCount: 5
        ), 4)
        XCTAssertEqual(policy.targetIndex(
            currentIndex: 1, currentOffset: 100, itemExtent: 100,
            velocity: 8_000, itemCount: 5
        ), 2)
        XCTAssertEqual(policy.targetOffset(
            currentIndex: 1, currentOffset: 129, itemExtent: 100,
            velocity: 0, itemCount: 5, leadingInset: 16
        ), 216)
    }

    func testMagneticAlignmentQuantizesAndClampsValues() {
        let policy = StockedVelocitySnapPolicy()

        XCTAssertEqual(policy.magneticValue(47, increment: 16), 48)
        XCTAssertEqual(policy.magneticValue(53, increment: 16, origin: 4), 52)
        XCTAssertEqual(policy.magneticValue(111, increment: 16, bounds: 0...96), 96)
        XCTAssertEqual(policy.magneticValue(-20, increment: 16, bounds: 0...96), 0)
    }

    func testImageWorkPausesDuringInteractionAndResumesAtDeceleration() {
        let policy = StockedImageWorkPolicy()
        let visibleRemote = StockedImageWorkRequest(source: .remote, purpose: .visible)
        let interacting = StockedScrollActivity(
            phase: .interacting,
            horizontalVelocity: 800,
            verticalVelocity: 0,
            transitionSequence: 1
        )
        let decelerating = StockedScrollActivity(
            phase: .decelerating,
            horizontalVelocity: 180,
            verticalVelocity: 0,
            transitionSequence: 2
        )

        XCTAssertEqual(policy.directive(
            for: visibleRemote, activity: interacting, remoteAccessAllowed: true
        ), .deferUntilDeceleration)
        XCTAssertEqual(policy.directive(
            for: visibleRemote, activity: decelerating, remoteAccessAllowed: true
        ), .loadNow(priority: .userInitiated))
        XCTAssertEqual(policy.directive(
            for: visibleRemote, activity: .idle, remoteAccessAllowed: false
        ), .localOnly)
    }

    func testLocalImageSignatureIsStableAndChangesWithContent() {
        let first = Data((0..<96).map(UInt8.init))
        var changed = first
        // ImageDataSignature deliberately samples evenly spaced bytes instead of
        // hashing every JPEG byte during SwiftUI updates. Mutate a sampled index.
        changed[49] = 255

        XCTAssertEqual(ImageDataSignature(first), ImageDataSignature(first))
        XCTAssertNotEqual(ImageDataSignature(first), ImageDataSignature(changed))
        XCTAssertNil(ImageDataSignature(nil))
        XCTAssertNil(ImageDataSignature(Data()))
    }

    func testPrefetchPolicyKeepsDebounceAndBatchBounded() {
        let policy = StockedImageWorkPolicy()

        XCTAssertGreaterThan(policy.idleDebounce, 0)
        XCTAssertLessThanOrEqual(policy.idleDebounce, 0.5)
        XCTAssertGreaterThan(policy.maximumPrefetchBatchSize, 0)
        XCTAssertLessThanOrEqual(policy.maximumPrefetchBatchSize, 12)
        XCTAssertLessThanOrEqual(policy.lookAheadCount + policy.lookBehindCount,
                                 policy.maximumPrefetchBatchSize)
    }

    func testImageFetchLimiterCancelsQueuedWorkAndTransfersSlotsByPriority() async {
        let limiter = ImageFetchLimiter(maxConcurrent: 2)

        let firstSlot = await limiter.acquire(priority: .utility)
        let secondSlot = await limiter.acquire(priority: .utility)
        XCTAssertTrue(firstSlot)
        XCTAssertTrue(secondSlot)
        var snapshot = await limiter.snapshot()
        XCTAssertEqual(snapshot.active, 2)
        XCTAssertEqual(snapshot.maximum, 2)

        let cancelled = Task { await limiter.acquire(priority: .background) }
        for _ in 0..<100 {
            let current = await limiter.snapshot()
            if current.queued == 1 { break }
            await Task.yield()
        }
        snapshot = await limiter.snapshot()
        XCTAssertEqual(snapshot.queued, 1)

        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertFalse(cancelledResult)
        snapshot = await limiter.snapshot()
        XCTAssertEqual(snapshot.active, 2)
        XCTAssertEqual(snapshot.queued, 0)

        let lowPriority = Task { await limiter.acquire(priority: .background) }
        for _ in 0..<100 {
            let current = await limiter.snapshot()
            if current.queued == 1 { break }
            await Task.yield()
        }
        let visible = Task { await limiter.acquire(priority: .userInitiated) }
        for _ in 0..<100 {
            let current = await limiter.snapshot()
            if current.queued == 2 { break }
            await Task.yield()
        }
        snapshot = await limiter.snapshot()
        XCTAssertEqual(snapshot.queued, 2)

        await limiter.release()
        let visibleResult = await visible.value
        XCTAssertTrue(visibleResult, "Visible work must receive the transferred slot first")
        snapshot = await limiter.snapshot()
        XCTAssertEqual(snapshot.active, 2, "A slot transfer must never exceed the concurrency cap")
        XCTAssertEqual(snapshot.queued, 1)

        await limiter.release()
        let lowPriorityResult = await lowPriority.value
        XCTAssertTrue(lowPriorityResult)
        snapshot = await limiter.snapshot()
        XCTAssertEqual(snapshot.active, 2)
        XCTAssertEqual(snapshot.queued, 0)

        await limiter.release()
        await limiter.release()
        snapshot = await limiter.snapshot()
        XCTAssertEqual(snapshot.active, 0)
    }

    func testPrefetchCandidatesFollowVelocityAndExcludeCachedItems() {
        let policy = StockedImageWorkPolicy()
        let forward = StockedScrollActivity(
            phase: .decelerating,
            horizontalVelocity: 300,
            verticalVelocity: 0,
            transitionSequence: 1
        )
        let backward = StockedScrollActivity(
            phase: .decelerating,
            horizontalVelocity: -300,
            verticalVelocity: 0,
            transitionSequence: 1
        )

        XCTAssertEqual(policy.candidateIndices(
            itemCount: 20,
            visibleRange: 5..<8,
            axis: .horizontal,
            activity: forward,
            excluding: [9]
        ), [8, 10, 11, 12, 13, 4, 3])
        XCTAssertEqual(policy.candidateIndices(
            itemCount: 20,
            visibleRange: 5..<8,
            axis: .horizontal,
            activity: backward
        ), [4, 3, 8, 9, 10, 11, 12, 13])
    }

    func testIdlePrefetchCanRetainLastSettledDirection() {
        let policy = StockedImageWorkPolicy()
        let settledBackward = StockedScrollActivity(
            phase: .idle,
            horizontalVelocity: -260,
            verticalVelocity: 0,
            transitionSequence: 3
        )

        XCTAssertTrue(settledBackward.mayPrefetchRemoteImages)
        XCTAssertEqual(Array(policy.candidateIndices(
            itemCount: 20,
            visibleRange: 5..<8,
            axis: .horizontal,
            activity: settledBackward
        ).prefix(2)), [4, 3])
    }
}
