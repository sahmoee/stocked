// StoredPhoto.swift
// Photos are kept inside the recipe / inventory models and therefore sit in memory for the
// whole session and are rewritten with every save. Downscale them once, on import, to a size
// that still looks sharp on an iPad but is a fraction of a camera original.
import Foundation
import ImageIO
import UniformTypeIdentifiers

nonisolated enum StoredPhoto {
    /// Longest edge kept for stored photos (points × 2–3 on the largest card they appear in).
    static let maxDimension = 1600
    /// Photos already under this size are left untouched.
    static let migrationThresholdBytes = 700_000

    /// Returns a JPEG no larger than `maxDimension` on its longest edge, or the original
    /// bytes when they can't be decoded (never loses the user's photo).
    static func prepared(_ data: Data, maxDimension: Int = StoredPhoto.maxDimension,
                         quality: Double = 0.72) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,   // honour EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return data }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return data }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return data }
        let result = output as Data
        return result.count < data.count ? result : data
    }

    /// Off-main convenience for SwiftUI photo pickers.
    static func preparedAsync(_ data: Data) async -> Data {
        await Task.detached(priority: .userInitiated) { prepared(data) }.value
    }
}

// MARK: - Duplicate-tolerant dictionaries
nonisolated extension Dictionary {
    /// Like `init(uniqueKeysWithValues:)` but never traps on a duplicate key (last wins).
    /// User data (merged household rows, imported archives) can legitimately contain
    /// duplicate IDs or names; a trap there crashed the app instead of degrading.
    init<S: Sequence>(lastWins pairs: S) where S.Element == (Key, Value) {
        self.init(pairs, uniquingKeysWith: { _, last in last })
    }
}
