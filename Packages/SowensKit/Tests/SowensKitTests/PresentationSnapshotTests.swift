import XCTest
import SwiftUI
import SnapshotTesting
@testable import SowensKit

@MainActor
final class PresentationSnapshotTests: XCTestCase {
    func testStatusSurfaces() throws {
        for dark in [false, true] {
            for width in [390, 820] {
                let content = VStack(spacing: 16) {
                    Text("Saved collection").font(.system(.largeTitle, design: .serif))
                    SowensStatusView("Nothing saved yet", detail: "Items you save appear here.", symbol: "tray")
                        .sowensSurface(fill: dark ? Color(white: 0.16) : Color(white: 0.94), border: .secondary.opacity(0.3))
                    SowensStatusView("You're offline", detail: "Saved items remain available. Try again when connected.", symbol: "wifi.slash", state: .offline)
                        .sowensSurface(fill: dark ? Color(white: 0.16) : Color(white: 0.94))
                    SowensStatusView("Photo unavailable", detail: "Retry photo", symbol: "photo", state: .failed)
                }
                .padding(24)
                .frame(width: CGFloat(width))
                .background(dark ? Color(white: 0.075) : .white)
                .environment(\.colorScheme, dark ? .dark : .light)
                .environment(\.dynamicTypeSize, width == 390 ? .xxxLarge : .large)
                let renderer = ImageRenderer(content: content)
                renderer.scale = 1
                #if os(macOS)
                let platform = "macOS"
                let image = try XCTUnwrap(renderer.nsImage)
                #else
                let platform = "iOS"
                let image = try XCTUnwrap(renderer.uiImage)
                #endif
                assertSnapshot(of: image, as: .image, named: "\(platform)-\(dark ? "dark" : "light")-\(width)")
            }
        }
    }
}
