// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "SowensKit",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .watchOS(.v10)],
    products: [.library(name: "SowensSearch", targets: ["SowensSearch"]), .library(name: "SowensImages", targets: ["SowensImages"]), .library(name: "SowensKit", targets: ["SowensKit"]), .library(name: "SowensTestSupport", targets: ["SowensTestSupport"])],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", exact: "7.11.1"),
        .package(url: "https://github.com/onevcat/Kingfisher", exact: "8.13.0"),
        .package(url: "https://github.com/kean/Pulse", exact: "5.2.3"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing", exact: "1.19.6")
    ],
    targets: [
        .target(name: "SowensSearch", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "SowensSearchTests", dependencies: ["SowensSearch"]),
        .testTarget(name: "SowensImagesTests", dependencies: ["SowensImages", .product(name: "Kingfisher", package: "Kingfisher")]),
        .target(name: "SowensImages", dependencies: ["SowensKit", .product(name: "Kingfisher", package: "Kingfisher")]),
        .target(name: "SowensKit", dependencies: [.product(name: "Pulse", package: "Pulse"), .product(name: "PulseUI", package: "Pulse")], resources: [.copy("ThirdPartyNotices.txt")]),
        .target(name: "SowensTestSupport", dependencies: ["SowensKit", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")]),
        .testTarget(name: "SowensKitTests", dependencies: ["SowensKit", .product(name: "SnapshotTesting", package: "swift-snapshot-testing")])
    ]
)
