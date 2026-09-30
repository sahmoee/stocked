import XCTest
import SwiftUI
import SnapshotTesting

/// No app session, account, clock or live network is created by this harness.
@MainActor
public func assertSurfaceSnapshots<V: View>(of view: V, named name: String,
                                           file: StaticString = #filePath, testName: String = #function, line: UInt = #line) throws {
    for dark in [false, true] {
        for width in [390, 820] {
            let content = view.frame(width: CGFloat(width)).padding(20)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.dynamicTypeSize, width == 390 ? .accessibility1 : .large)
            let renderer = ImageRenderer(content: content)
            renderer.scale = 1
            #if os(macOS)
            let platform = "macOS"
            let image = try XCTUnwrap(renderer.nsImage, file: file, line: line)
            #else
            let platform = "iOS"
            let image = try XCTUnwrap(renderer.uiImage, file: file, line: line)
            #endif
            assertSnapshot(of: image, as: .image, named: "\(platform)-\(name)-\(dark ? "dark" : "light")-\(width)",
                           file: file, testName: testName, line: line)
        }
    }
}
