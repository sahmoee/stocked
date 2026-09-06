// RecipeMediaStore.swift
// Stocked — Durable, lossless storage for recipe photos supplied as local image data.

import CryptoKit
import Foundation
import ImageIO

/// Failures are deliberately specific so ingestion can quarantine a recipe with an
/// actionable reason instead of silently dropping it at an image guard.
nonisolated enum RecipeMediaFailure: Error, Equatable, Sendable {
    case missingReference
    case invalidRemoteURL
    case invalidImageData
    case retainedAssetMissing
    case retainedAssetInvalid
}

nonisolated enum RecipeMediaReference: Equatable, Sendable {
    case remote(URL)
    case retained(reference: URL, fileURL: URL)

    var storedValue: String {
        switch self {
        case .remote(let url), .retained(let url, _):
            return url.absoluteString
        }
    }
}

/// Stores original user-selected image bytes without recompression. References use a
/// container-independent custom URL rather than an absolute sandbox path, because iOS can
/// relocate an app container across installs/restores. Files are content-addressed so saving
/// the same photo repeatedly does not create duplicate assets.
nonisolated struct RecipeMediaStore: Sendable {
    static let shared = RecipeMediaStore()

    static let scheme = "stocked-recipe-media"
    private static let host = "originals"

    let rootDirectory: URL

    init(rootDirectory: URL = RecipeMediaStore.defaultRootDirectory()) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    /// Returns an HTTPS reference when one is valid, otherwise durably retains supplied
    /// image bytes. This lets image-data-only UserRecipe records enter the canonical store.
    func resolvedReference(remoteURL: String?, imageData: Data?) throws -> RecipeMediaReference {
        if let remoteURL,
           !remoteURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           case .success(let reference) = validateReference(remoteURL) {
            return reference
        }
        guard let imageData else {
            if remoteURL?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                throw RecipeMediaFailure.invalidRemoteURL
            }
            throw RecipeMediaFailure.missingReference
        }
        return try retain(imageData)
    }

    func retain(_ data: Data) throws -> RecipeMediaReference {
        guard Self.isDecodableImage(data) else { throw RecipeMediaFailure.invalidImageData }

        try FileManager.default.createDirectory(
            at: rootDirectory,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let filename = "\(digest).image"
        let fileURL = rootDirectory.appendingPathComponent(filename, isDirectory: false)

        if !FileManager.default.fileExists(atPath: fileURL.path)
            || !Self.isDecodableImageFile(at: fileURL) {
            try data.write(to: fileURL, options: [.atomic])
        }

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.path = "/\(filename)"
        guard let reference = components.url else { throw RecipeMediaFailure.retainedAssetInvalid }
        return .retained(reference: reference, fileURL: fileURL)
    }

    func validateReference(_ raw: String) -> Result<RecipeMediaReference, RecipeMediaFailure> {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let url = URL(string: trimmed) else {
            return .failure(.missingReference)
        }

        if url.scheme?.lowercased() == "https", url.host?.isEmpty == false,
           url.user == nil, url.password == nil {
            return .success(.remote(url))
        }

        guard url.scheme?.lowercased() == Self.scheme,
              url.host?.lowercased() == Self.host,
              let fileURL = retainedFileURL(for: url) else {
            return .failure(.invalidRemoteURL)
        }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return .failure(.retainedAssetMissing)
        }
        guard Self.isDecodableImageFile(at: fileURL) else {
            return .failure(.retainedAssetInvalid)
        }
        return .success(.retained(reference: url, fileURL: fileURL))
    }

    /// Reads a validated retained original. ImageCache calls this off the main actor.
    func retainedData(for raw: String) throws -> Data {
        switch validateReference(raw) {
        case .success(.retained(_, let fileURL)):
            let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
            guard Self.isDecodableImage(data) else { throw RecipeMediaFailure.retainedAssetInvalid }
            return data
        case .success(.remote):
            throw RecipeMediaFailure.invalidRemoteURL
        case .failure(let failure):
            throw failure
        }
    }

    private func retainedFileURL(for reference: URL) -> URL? {
        let components = reference.pathComponents.filter { $0 != "/" }
        guard components.count == 1,
              components[0].hasSuffix(".image"),
              !components[0].contains("..") else { return nil }

        let candidate = rootDirectory
            .appendingPathComponent(components[0], isDirectory: false)
            .standardizedFileURL
        let rootPath = rootDirectory.standardizedFileURL.path + "/"
        guard candidate.path.hasPrefix(rootPath) else { return nil }
        return candidate
    }

    private static func isDecodableImageFile(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else { return false }
        return isDecodableImage(data)
    }

    static func isDecodableImage(_ data: Data) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return false }
        return width.intValue > 0 && height.intValue > 0
    }

    private static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("Stocked", isDirectory: true)
            .appendingPathComponent("RecipeMediaOriginalsV1", isDirectory: true)
    }
}
