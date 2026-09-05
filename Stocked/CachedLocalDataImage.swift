// CachedLocalDataImage.swift
// Reusable, scroll-aware rendering for embedded inventory and recipe photos.

import SwiftUI
import UIKit

/// Only decorative navigation art is mapped here; publisher/product photos never enter this path.
nonisolated enum KitchenArtworkCatalog {
    static let inventoryActions = ["inventory_expiring_reference", "inventory_low_reference", "inventory_add_reference"]
    static func approvedAsset(for name: String) -> String {
        switch name {
        case "cook_now_hero", "recipes_ready": return "home_widget_cooking"
        case "cook_later_hero", "recipes_past": return "home_widget_planning"
        case "recipes_collection": return "recipes_hero"
        case "protein": return "kitchen_protein_reference"
        case "vegetables": return "inventory_category_produce"
        case "expiring_soon": return inventoryActions[0]
        case "leftovers": return "kitchen_leftovers_reference"
        default: return name
        }
    }
}

/// One aspect-preserving cutout renderer for Home and Inventory. Only memory hits
/// are read during layout; bundle loading and display preparation happen off-main.
struct StockedKitchenArtwork: View {
    let asset: String
    @Environment(\.stockedScrollActivity) private var scrollActivity
    @State private var image: UIImage?
    @State private var loadedAsset: String?
    @State private var failedAsset: String?
    private var resolvedAsset: String { KitchenArtworkCatalog.approvedAsset(for: asset) }

    var body: some View {
        Group {
            if let rendered = (loadedAsset == resolvedAsset ? image : nil) ?? ImageCache.shared.artwork(named: resolvedAsset) {
                Image(uiImage: rendered).renderingMode(.original).resizable().interpolation(.high).scaledToFit()
            } else if failedAsset == resolvedAsset {
                Image(systemName: "leaf.circle")
                    .font(.stocked(.largeTitle)).foregroundStyle(.secondary)
            } else {
                Color.clear
            }
        }
        .task(id: "\(resolvedAsset):\(scrollActivity.mayLoadVisibleImages)") {
            guard scrollActivity.mayLoadVisibleImages else { return }
            var completedRetries = 0
            while !Task.isCancelled {
                let result = await ImageCache.shared.prepareArtworkResult(named: resolvedAsset)
                guard !Task.isCancelled else { return }
                switch result {
                case .ready(let prepared):
                    image = prepared
                    loadedAsset = resolvedAsset
                    failedAsset = nil
                    return
                case .unavailable:
                    image = nil
                    loadedAsset = nil
                    failedAsset = resolvedAsset
                    return
                case .cancelled:
                    // Eviction is transient. Never turn it into a permanent missing-art leaf.
                    guard result.shouldRetry(completedRetries: completedRetries) else { return }
                    completedRetries += 1
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                }
            }
        }
        .accessibilityHidden(true)
    }
}

enum StockedLocalImageClip: Equatable, Sendable {
    case none
    case circle
    case roundedRectangle(cornerRadius: CGFloat)
}

private struct CachedLocalDataImageTaskID: Hashable, Sendable {
    let signature: ImageDataSignature?
    let maxDimension: Int
    let mayLoadVisibleImages: Bool
}

/// Displays embedded image data without decoding it from a SwiftUI render pass.
///
/// `ImageCache` memory hits render immediately. Cache misses follow the shared image-work
/// policy, so direct scrolling postpones decode until deceleration, then a cancellable
/// identity-keyed task downsamples off the main actor. This component never starts network
/// work and does not change the feature's image provenance or fallback order.
struct CachedLocalDataImage<Placeholder: View>: View {
    @Environment(\.stockedScrollActivity) private var scrollActivity

    let data: Data?
    let maxDimension: CGFloat
    let width: CGFloat?
    let height: CGFloat?
    let contentMode: ContentMode
    let clip: StockedLocalImageClip
    private let placeholder: Placeholder

    @State private var decodedImage: UIImage?
    @State private var decodedSignature: ImageDataSignature?
    @State private var decodedMaxDimension = 0
    @State private var activeRequestID: CachedLocalDataImageTaskID?

    init(
        data: Data?,
        maxDimension: CGFloat,
        width: CGFloat? = nil,
        height: CGFloat? = nil,
        contentMode: ContentMode = .fill,
        clip: StockedLocalImageClip = .none,
        @ViewBuilder placeholder: () -> Placeholder
    ) {
        self.data = data
        self.maxDimension = maxDimension
        self.width = width
        self.height = height
        self.contentMode = contentMode
        self.clip = clip
        self.placeholder = placeholder()
    }

    private var signature: ImageDataSignature? { ImageDataSignature(data) }

    private var normalizedMaxDimension: CGFloat {
        CGFloat(max(1, Int(maxDimension.rounded())))
    }

    private var taskID: CachedLocalDataImageTaskID {
        CachedLocalDataImageTaskID(
            signature: signature,
            maxDimension: Int(normalizedMaxDimension),
            // Deceleration and idle both permit visible work. Keeping one gate for
            // both avoids cancelling a valid decode at the deceleration-to-idle edge.
            mayLoadVisibleImages: scrollActivity.mayLoadVisibleImages
        )
    }

    /// NSCache lookup is memory-only and safe to perform while SwiftUI evaluates the view.
    private var immediatelyAvailableImage: UIImage? {
        guard let signature else { return nil }
        if decodedSignature == signature,
           decodedMaxDimension == Int(normalizedMaxDimension),
           let decodedImage {
            return decodedImage
        }
        return ImageCache.shared.localImage(
            for: signature,
            maxDimension: normalizedMaxDimension
        )
    }

    var body: some View {
        Group {
            if let image = immediatelyAvailableImage {
                renderedImage(image)
            } else {
                placeholder
            }
        }
        .task(id: taskID) {
            await loadImage(for: taskID, activity: scrollActivity)
        }
    }

    @ViewBuilder
    private func renderedImage(_ image: UIImage) -> some View {
        let content = Image(uiImage: image)
            .resizable()
            .aspectRatio(contentMode: contentMode)
            .frame(width: width, height: height)

        switch clip {
        case .none:
            content.clipped()
        case .circle:
            content.clipShape(Circle())
        case .roundedRectangle(let cornerRadius):
            content.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
    }

    @MainActor
    private func loadImage(
        for requestID: CachedLocalDataImageTaskID,
        activity: StockedScrollActivity
    ) async {
        activeRequestID = requestID
        guard let data, let signature = requestID.signature else {
            decodedImage = nil
            decodedSignature = nil
            decodedMaxDimension = 0
            return
        }

        let targetDimension = CGFloat(requestID.maxDimension)
        if let cached = ImageCache.shared.localImage(
            for: signature,
            maxDimension: targetDimension
        ) {
            guard activeRequestID == requestID else { return }
            decodedImage = cached
            decodedSignature = signature
            decodedMaxDimension = requestID.maxDimension
            return
        }

        let directive = StockedImageWorkPolicy().directive(
            for: .init(source: .localEncoded, purpose: .visible),
            activity: activity,
            remoteAccessAllowed: false
        )
        guard case .loadNow(let priority) = directive else { return }

        guard await ImageFetchLimiter.shared.acquire(priority: priority.taskPriority) else { return }
        guard !Task.isCancelled else {
            await ImageFetchLimiter.shared.release()
            return
        }
        let decodeTask = Task.detached(priority: priority.taskPriority) {
            guard !Task.isCancelled else { return nil as UIImage? }
            return ImageCache.downsample(data, maxDimension: targetDimension)
                ?? UIImage(data: data)
        }
        let decoded = await withTaskCancellationHandler {
            await decodeTask.value
        } onCancel: {
            decodeTask.cancel()
        }
        await ImageFetchLimiter.shared.release()

        guard !Task.isCancelled,
              activeRequestID == requestID,
              ImageDataSignature(data) == signature,
              let decoded else { return }

        ImageCache.shared.storeLocal(
            decoded,
            for: signature,
            maxDimension: targetDimension
        )
        decodedImage = decoded
        decodedSignature = signature
        decodedMaxDimension = requestID.maxDimension
    }
}
