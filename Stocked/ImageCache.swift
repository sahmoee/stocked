// ImageCache.swift
// • Memory + disk two-layer cache (unchanged, already solid)
// • Image prefetch queue — pre-loads next N images in scroll direction (#8)
// • NSCache count + cost limits to prevent memory pressure
// • Parallel fetch using TaskGroup

import SwiftUI
import PhotosUI
import ImageIO

// MARK: - ImageCache
final class ImageCache {
    static let shared = ImageCache()
    private init() {
        createCacheDir()
        memCache.countLimit = 150
        memCache.totalCostLimit = 50 * 1024 * 1024  // 50MB mem cap
    }

    private let memCache = NSCache<NSString, UIImage>()
    private var prefetchTasks: [String: Task<Void, Never>] = [:]

    private let cacheDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("StockedDB/ImageCache", isDirectory: true)
    }()

    private func createCacheDir() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    private func key(for url: String) -> String { "\(abs(url.hashValue)).jpg" }

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
        if let cached = image(for: urlString) { return cached }
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

    var body: some View {
        ZStack {
            if let data = imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
                    .opacity(appeared ? 1 : 0)
                    .onAppear { withAnimation(.easeOut(duration: 0.35)) { appeared = true } }
            } else if let img = loadedImage {
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
        .task(id: url) { await loadImage() }
    }

    private func loadImage() async {
        isLoading = true
        defer { isLoading = false }
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
