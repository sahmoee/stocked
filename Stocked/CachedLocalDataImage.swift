// CachedLocalDataImage.swift
// Reusable, scroll-aware rendering for embedded inventory and recipe photos.

import SwiftUI
import UIKit

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
