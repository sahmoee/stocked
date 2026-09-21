import XCTest
import SwiftUI
import UIKit
@testable import Stocked

@MainActor
final class LayoutConsistencyTests: XCTestCase {
    func testNarrowSheetDoesNotKeepAnOversizedMinimumColumnWidth() {
        for width: CGFloat in [180, 240, 320] {
            let metrics = StockedLayoutMetrics(width: width, height: 600,
                isAccessibilityText: false, interfaceScale: 1, textScale: 1.5,
                safeAreaInsets: EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 8))
            let columns = metrics.gridColumns(minimum: 500, maximum: 4)
            XCTAssertEqual(columns.count, 1)
            guard case let .flexible(minimum, _) = columns[0].size else {
                return XCTFail("Expected an adaptive flexible column")
            }
            XCTAssertLessThanOrEqual(minimum, metrics.contentWidth - 2 * metrics.horizontalPadding)
            XCTAssertGreaterThan(minimum, 0)
        }
    }

    func testLargerTextGetsWiderCardsAndAccessibilityUsesOneColumn() {
        let normal = StockedLayoutMetrics(width: 393, height: 852,
            isAccessibilityText: false, interfaceScale: 1, textScale: 1)
        var enlarged = normal
        enlarged.textScale = 1.5
        XCTAssertEqual(normal.gridColumns(minimum: 150, maximum: 3).count, 2)
        XCTAssertEqual(enlarged.gridColumns(minimum: 150, maximum: 3).count, 1)
        for width: CGFloat in [320, 430, 768, 1_024] {
            let accessible = StockedLayoutMetrics(width: width, height: 852,
                isAccessibilityText: true, interfaceScale: 1, textScale: 2)
            XCTAssertEqual(accessible.gridColumns(minimum: 100, maximum: 4).count, 1)
            XCTAssertGreaterThanOrEqual(accessible.minimumControlHeight, 44)
        }
    }

    func testRenderedGridSharesHeightOnlyWithinEachRowAndKeepsLastColumnWidth() async throws {
        for width: CGFloat in [320, 768] {
            let frames = try await renderedFrames(width: width, controlRow: false)
            let first = try XCTUnwrap(frames[0])
            let second = try XCTUnwrap(frames[1])
            let third = try XCTUnwrap(frames[2])
            let fourth = try XCTUnwrap(frames[3])
            let last = try XCTUnwrap(frames[4])
            XCTAssertEqual(first.minY, second.minY, accuracy: 0.5)
            XCTAssertEqual(first.height, second.height, accuracy: 0.5)
            XCTAssertEqual(first.height, 100, accuracy: 0.5)
            XCTAssertEqual(third.minY, fourth.minY, accuracy: 0.5)
            XCTAssertEqual(third.height, fourth.height, accuracy: 0.5)
            XCTAssertEqual(third.height, 80, accuracy: 0.5)
            XCTAssertEqual(third.minY - first.maxY, 12, accuracy: 0.5)
            XCTAssertEqual(last.minY - third.maxY, 12, accuracy: 0.5)
            XCTAssertEqual(last.height, 50, accuracy: 0.5)
            XCTAssertEqual(last.width, first.width, accuracy: 0.5)
            XCTAssertEqual(second.minX - first.maxX, 12, accuracy: 0.5)
        }
    }

    func testExistingThreeActionRowStillUsesAllThreeChildren() async throws {
        let frames = try await renderedFrames(width: 393, controlRow: true)
        let first = try XCTUnwrap(frames[0])
        let second = try XCTUnwrap(frames[1])
        let third = try XCTUnwrap(frames[2])
        XCTAssertEqual(first.height, 100, accuracy: 0.5)
        XCTAssertEqual(first.height, third.height, accuracy: 0.5)
        XCTAssertEqual(first.width, second.width, accuracy: 0.5)
        XCTAssertEqual(first.width, third.width, accuracy: 0.5)
        XCTAssertEqual(third.maxX, 393, accuracy: 0.5)
    }

    private func renderedFrames(width: CGFloat, controlRow: Bool) async throws -> [Int: CGRect] {
        let ready = expectation(description: "SwiftUI row geometry")
        let recorder = LayoutFrameRecorder()
        let cards: [LayoutTestCard] = [
            .init(id: 0, minimumHeight: 40), .init(id: 1, minimumHeight: 100),
            .init(id: 2, minimumHeight: 60), .init(id: 3, minimumHeight: 80),
            .init(id: 4, minimumHeight: 50)
        ]
        let content = LayoutTestCanvas(cards: controlRow ? Array(cards.prefix(3)) : cards,
            controlRow: controlRow) { frames in
                recorder.frames = frames
                if !recorder.fulfilled && frames.count == (controlRow ? 3 : 5) {
                    recorder.fulfilled = true
                    ready.fulfill()
                }
            }
        let host = UIHostingController(rootView: content)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: width, height: 700))
        window.rootViewController = host
        window.isHidden = false
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        await fulfillment(of: [ready], timeout: 3)
        return recorder.frames
    }
}

private struct LayoutTestCard: Identifiable {
    let id: Int
    let minimumHeight: CGFloat
}

@MainActor
private final class LayoutFrameRecorder {
    var frames: [Int: CGRect] = [:]
    var fulfilled = false
}

private struct LayoutFramesPreference: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct LayoutTestCanvas: View {
    let cards: [LayoutTestCard]
    let controlRow: Bool
    let onFrames: ([Int: CGRect]) -> Void

    var body: some View {
        ScrollView {
            Group {
                if controlRow {
                    StockedEqualHeightRow(spacing: 12) {
                        ForEach(cards) { card($0) }
                    }
                } else {
                    StockedEqualHeightGrid(items: cards, columns: 2) { card($0) }
                }
            }
            .coordinateSpace(name: "cards")
            .onPreferenceChange(LayoutFramesPreference.self, perform: onFrames)
        }
        .ignoresSafeArea()
    }

    private func card(_ item: LayoutTestCard) -> some View {
        Color.clear
            .frame(minHeight: item.minimumHeight, maxHeight: .infinity)
            .background(Color.orange)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: LayoutFramesPreference.self,
                        value: [item.id: geometry.frame(in: .named("cards"))])
                }
            }
    }
}
