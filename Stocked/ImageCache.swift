// ImageCache.swift
// • Memory + disk two-layer cache (unchanged, already solid)
// • Image prefetch queue — pre-loads next N images in scroll direction (#8)
// • NSCache count + cost limits to prevent memory pressure
// • Parallel fetch using TaskGroup

import SwiftUI
import PhotosUI
import ImageIO

/// Lightweight identity for locally stored image data. Sampling a few bytes avoids
/// hashing or decoding the entire JPEG every time SwiftUI reevaluates a view.
nonisolated struct ImageDataSignature: Hashable, Sendable {
    let byteCount: Int
    let fingerprint: UInt64

    init?(_ data: Data?) {
        guard let data, !data.isEmpty else { return nil }
        byteCount = data.count

        var hash: UInt64 = 14_695_981_039_346_656_037
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            let sampleCount = min(32, bytes.count)
            guard sampleCount > 0 else { return }
            for sample in 0..<sampleCount {
                let index = sampleCount == 1
                    ? 0
                    : (sample * (bytes.count - 1)) / (sampleCount - 1)
                hash ^= UInt64(bytes[index])
                hash &*= 1_099_511_628_211
            }
        }
        fingerprint = hash
    }
}

private nonisolated struct CachedImageLoadID: Hashable, Sendable {
    let url: String?
    let dataSignature: ImageDataSignature?
    let resolveName: String?
    let resolveCategory: String?
}

// MARK: - ImageCache
final class ImageCache {
    static let shared = ImageCache()
    private init() {
        createCacheDir()
        memCache.countLimit = 150
        memCache.totalCostLimit = 50 * 1024 * 1024  // 50MB mem cap
        localDataCache.countLimit = 100
        localDataCache.totalCostLimit = 40 * 1024 * 1024
    }

    private let memCache = NSCache<NSString, UIImage>()
    private let localDataCache = NSCache<NSString, UIImage>()
    private var prefetchTasks: [String: Task<Void, Never>] = [:]

    private let cacheDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("StockedDB/ImageCache", isDirectory: true)
    }()

    private func createCacheDir() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func key(for url: String) -> String { "\(abs(url.hashValue)).jpg" }
    private func localDataKey(for signature: ImageDataSignature, maxDimension: CGFloat) -> NSString {
        "\(signature.byteCount)-\(signature.fingerprint)-\(Int(maxDimension.rounded()))" as NSString
    }

    func localImage(for signature: ImageDataSignature, maxDimension: CGFloat) -> UIImage? {
        localDataCache.object(forKey: localDataKey(for: signature, maxDimension: maxDimension))
    }

    func storeLocal(_ image: UIImage, for signature: ImageDataSignature, maxDimension: CGFloat) {
        let cost = Int(image.size.width * image.size.height * 4)
        localDataCache.setObject(
            image,
            forKey: localDataKey(for: signature, maxDimension: maxDimension),
            cost: cost
        )
    }

    // MARK: - Read
    func image(for url: String) -> UIImage? {
        let k = key(for: url) as NSString
        if let mem = memCache.object(forKey: k) { return mem }
        let path = cacheDir.appendingPathComponent(String(k))
        guard let data = try? Data(contentsOf: path),
              let img  = UIImage(data: data) else { return nil }
        let cost = Int(img.size.width * img.size.height * 4)
        memCache.setObject(img, forKey: k, cost: cost)
        return img
    }

    /// #PERF — memory-only lookup (no disk touch). Safe on the main thread.
    func memoryImage(for url: String) -> UIImage? {
        memCache.object(forKey: key(for: url) as NSString)
    }

    /// #PERF — the disk half of `image(for:)`, run off the caller's thread. The old path
    /// did a synchronous Data(contentsOf:) inside fetchImage, which is awaited from
    /// SwiftUI's MainActor — so every cache-hit-on-disk read blocked the main thread and
    /// stuttered image-heavy scrolls. This hops the file read to a background task and
    /// only touches the memory cache back on return.
    private func diskImage(for url: String) async -> UIImage? {
        let k = key(for: url)
        let path = cacheDir.appendingPathComponent(k)
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: path) else { return nil }
            return UIImage(data: data)
        }.value
        if let img {
            let cost = Int(img.size.width * img.size.height * 4)
            memCache.setObject(img, forKey: k as NSString, cost: cost)
        }
        return img
    }

    // MARK: - Write
    func store(_ image: UIImage, for url: String) {
        let k    = key(for: url) as NSString
        let cost = Int(image.size.width * image.size.height * 4)
        memCache.setObject(image, forKey: k, cost: cost)
        let path = cacheDir.appendingPathComponent(String(k))
        Task.detached(priority: .background) {
            image.jpegData(compressionQuality: 0.80).map { try? $0.write(to: path, options: .atomic) }
        }
    }

    // MARK: - Fetch (cache-first)
    @discardableResult
    func fetchImage(url urlString: String) async -> UIImage? {
        // #PERF — split the cache probe: memory is instant (fine on main); the disk read
        // hops off-thread so scrolling image grids never blocks on file IO.
        if let mem = memoryImage(for: urlString) { return mem }
        if let disk = await diskImage(for: urlString) { return disk }
        guard let url = URL(string: urlString) else { return nil }
        // #16: limit concurrent network fetches so a grid appearing doesn't saturate things.
        await ImageFetchLimiter.shared.acquire()
        defer { Task { await ImageFetchLimiter.shared.release() } }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            // #14 perf: downsample to a sensible max dimension before caching. Recipe images
            // display at ≤280pt; 700px covers retina while using a fraction of the memory of
            // a full-resolution decode, so far more images fit under the cache's cost cap.
            guard let img = ImageCache.downsample(data, maxDimension: 700) ?? UIImage(data: data) else { return nil }
            store(img, for: urlString)
            return img
        } catch { return nil }
    }

    /// Decode an image directly at a reduced size using ImageIO (much cheaper than decoding
    /// full-res then resizing). Returns nil if the data isn't a decodable image.
    nonisolated static func downsample(_ data: Data, maxDimension: CGFloat) -> UIImage? {
        let srcOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOptions) else { return nil }
        // UIScreen.main is deprecated in iOS 26 and unavailable from this nonisolated context.
        // Thumbnails are decoded off the main actor, so use the max modern Retina scale (3x):
        // slightly over-sampling a thumbnail is harmless, whereas under-sampling would blur it.
        let scale: CGFloat = 3.0
        let maxPixels = Int(maxDimension * scale)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
    // MARK: - Prefetch next N images (#8)
    /// Call from scroll view's onAppear with the upcoming URLs.
    func prefetch(urls: [String]) {
        for url in urls.prefix(10) {
            guard image(for: url) == nil, prefetchTasks[url] == nil else { continue }
            let urlCopy = url
            prefetchTasks[url] = Task(priority: .background) {
                _ = await ImageCache.shared.fetchImage(url: urlCopy)
                self.prefetchTasks.removeValue(forKey: urlCopy)
            }
        }
    }

    func cancelPrefetch(for url: String) {
        prefetchTasks[url]?.cancel()
        prefetchTasks.removeValue(forKey: url)
    }

    // MARK: - Stats & Clear
    var diskCacheSizeBytes: Int {
        ((try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.fileSizeKey])) ?? [])
            .reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
    }
    var diskCacheSizeString: String {
        let mb = Double(diskCacheSizeBytes) / 1_048_576
        return mb < 1 ? "\(diskCacheSizeBytes / 1024) KB" : String(format: "%.1f MB", mb)
    }
    func clearAll() {
        memCache.removeAllObjects()
        localDataCache.removeAllObjects()
        ((try? FileManager.default.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: nil)) ?? [])
            .forEach { try? FileManager.default.removeItem(at: $0) }
    }
}

// MARK: - #16 Image fetch concurrency limiter
// When a grid appears, dozens of CachedAsyncImage tasks fire at once, saturating the
// network and main-thread decode. This actor caps simultaneous fetches to keep scrolling
// smooth; queued requests run as slots free up.
actor ImageFetchLimiter {
    static let shared = ImageFetchLimiter(maxConcurrent: 5)
    private let maxConcurrent: Int
    private var active = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(maxConcurrent: Int) { self.maxConcurrent = maxConcurrent }

    func acquire() async {
        if active < maxConcurrent { active += 1; return }
        await withCheckedContinuation { waiters.append($0) }
        active += 1
    }
    func release() {
        active -= 1
        if !waiters.isEmpty { waiters.removeFirst().resume() }
    }
}

// MARK: - CachedAsyncImage
struct CachedAsyncImage: View {
    let url:       String?
    let imageData: Data?
    var height:    CGFloat = 180
    var onUpdate:  ((Data) -> Void)? = nil
    // When set, and the URL is empty or fails to load, resolve an image online by this
    // recipe name (TheMealDB → Spoonacular → Foodish) before showing the placeholder.
    var resolveName: String? = nil
    var resolveCategory: String? = nil

    @State private var loadedImage: UIImage?
    @State private var isLoading   = false
    @State private var showPicker  = false
    @State private var appeared    = false   // #10 fade-in once the image is shown

    private var loadID: CachedImageLoadID {
        CachedImageLoadID(
            url: url,
            dataSignature: ImageDataSignature(imageData),
            resolveName: resolveName,
            resolveCategory: resolveCategory
        )
    }

    var body: some View {
        ZStack {
            if let img = loadedImage {
                Image(uiImage: img).resizable().scaledToFill()
                    .opacity(appeared ? 1 : 0)
                    .onAppear { withAnimation(.easeOut(duration: 0.35)) { appeared = true } }
            } else {
                ZStack {
                    // #10 — soft shimmering placeholder block instead of a flat color, so the
                    // gap before an image loads reads as "loading" rather than broken.
                    LinearGradient(
                        colors: [Color.stockedGold.opacity(0.18),
                                 Color.stockedGold.opacity(0.32),
                                 Color.stockedGold.opacity(0.18)],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                    if isLoading {
                        ProgressView().tint(Color.stockedGold)
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: "fork.knife")
                                .font(.system(size: 28)).foregroundStyle(Color.stockedGold)
                            Text("Meal Photo").font(.stockedSans(12))
                                .foregroundStyle(Color.primary.opacity(0.5))
                        }
                    }
                }
            }
            if onUpdate != nil {
                VStack { Spacer(); HStack { Spacer(); PhotoUpdateButton { showPicker = true } } }
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height)
        .clipped()
        .sheet(isPresented: $showPicker) { PhotoPickerSheet { onUpdate?($0) } }
        .task(id: loadID) { await loadImage() }
    }

    private func loadImage() async {
        loadedImage = nil
        appeared = false
        isLoading = true
        defer { isLoading = false }

        // User-selected recipe photos used to call UIImage(data:) directly from body,
        // causing a full JPEG decode on every render. Decode once off the main actor.
        if let data = imageData, let signature = ImageDataSignature(data) {
            let targetHeight = max(height, 96)
            if let cached = ImageCache.shared.localImage(for: signature, maxDimension: targetHeight) {
                loadedImage = cached
                return
            }
            let decoded = await Task.detached(priority: .userInitiated) {
                ImageCache.downsample(data, maxDimension: targetHeight) ?? UIImage(data: data)
            }.value
            guard !Task.isCancelled else { return }
            if let decoded {
                ImageCache.shared.storeLocal(decoded, for: signature, maxDimension: targetHeight)
                loadedImage = decoded
                return
            }
        }

        // Try the stored URL first.
        if let u = url, !u.isEmpty {
            if let img = await ImageCache.shared.fetchImage(url: u) {
                loadedImage = img; return
            }
        }
        // No URL, or it failed — resolve online by recipe name if we were given one.
        if let name = resolveName, !name.isEmpty,
           let resolved = await RecipeImageResolver.shared.imageURL(for: name, category: resolveCategory) {
            loadedImage = await ImageCache.shared.fetchImage(url: resolved.absoluteString)
        }
    }
}

// MARK: - Helpers
private struct PhotoUpdateButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "camera.fill").font(.system(size: 11))
                Text("Change").font(.stockedSans(11, weight: .semibold))
            }
            .foregroundStyle(Color.stockedWhite).padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.stockedCharcoal.opacity(0.75)).clipShape(RoundedRectangle(cornerRadius: StockedRadius.xl))
        }.buttonStyle(.plain).padding(10)
    }
}

struct PhotoPickerSheet: View {
    let onSelect: (Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItem: PhotosPickerItem?
    var body: some View {
        PhotosPicker("Select Photo", selection: $selectedItem, matching: .images)
            .onChange(of: selectedItem) { _, item in
                Task {
                    if let data = try? await item?.loadTransferable(type: Data.self) {
                        onSelect(data); dismiss()
                    }
                }
            }
    }
}
