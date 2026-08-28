import XCTest
import SwiftUI
@testable import Stocked

@MainActor
final class AdaptiveUIFoundationTests: XCTestCase {
    func testNarrowContainersUseCompactPaddingAndSingleColumn() {
        let metrics = StockedLayoutMetrics(
            width: 320,
            height: 700,
            isAccessibilityText: false,
            interfaceScale: InterfaceSize.comfortable.scale
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
            interfaceScale: InterfaceSize.comfortable.scale,
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
            interfaceScale: InterfaceSize.comfortable.scale
        )
        let accessibility = StockedLayoutMetrics(
            width: 393,
            height: 852,
            isAccessibilityText: true,
            interfaceScale: InterfaceSize.comfortable.scale
        )

        XCTAssertGreaterThan(accessibility.tabBarItemMinimumHeight, standard.tabBarItemMinimumHeight)
        XCTAssertTrue(accessibility.prefersVerticalControls)
    }
}
