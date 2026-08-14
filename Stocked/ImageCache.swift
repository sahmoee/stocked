// ImageCache.swift
// • Memory + disk two-layer cache (unchanged, already solid)
// • Image prefetch queue — pre-loads next N images in scroll direction (#8)
// • NSCache count + cost limits to prevent memory pressure
// • Parallel fetch using TaskGroup

import SwiftUI
import PhotosUI
import ImageIO
import UIKit

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
final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()
    private init() {
        createCacheDir()
        memCache.countLimit = 150
        memCache.totalCostLimit = 50 * 1024 * 1024  // 50MB mem cap
        localDataCache.countLimit = 100
        localDataCache.totalCostLimit = 40 * 1024 * 1024

        // #8 — release in-memory images under memory pressure (keeps disk). Prevents the
        // large image caches from contributing to a jetsam termination during heavy scrolling.
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.evictMemory() }

        // Directory enumeration and legacy-cache deletion can be slow after an image-heavy
        // session. Running either from the singleton initializer used to freeze the first
        // recipe screen that touched ImageCache.shared.
        let directory = cacheDir
        let legacyDirectory = legacyCacheDir
        let maxBytes = maxDiskBytes
        Task.detached(priority: .background) {
            if legacyDirectory != directory {
                try? FileManager.default.removeItem(at: legacyDirectory)
            }
            Self.prune(directory: directory, maxBytes: maxBytes)
        }
    }

    private struct InFlightImageRequest {
        let id: UUID
        let task: Task<UIImage?, Never>
    }

    private let memCache = NSCache<NSString, UIImage>()
    private let localDataCache = NSCache<NSString, UIImage>()
    private let stateLock = NSLock()
    private var prefetchTasks: [String: Task<Void, Never>] = [:]
    private var inFlightRequests: [String: InFlightImageRequest] = [:]

    private func withStateLock<T>(_ body: () -> T) -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }

    private let maxDiskBytes = 250 * 1_048_576
    private let cacheDir: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("Stocked/ImageCache", isDirectory: true)
    }()
    private let legacyCacheDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return docs.appendingPathComponent("StockedDB/ImageCache", isDirectory: true)
    }()

    private func createCacheDir() {
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }

    /// Older builds used String.hashValue for filenames. That value changes each launch, so
    /// those files cannot be addressed reliably and only consume storage.
    private func removeLegacyUnstableCache() {
        guard legacyCacheDir != cacheDir else { return }
        try? FileManager.default.removeItem(at: legacyCacheDir)
    }

    private func key(for url: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in url.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16) + ".jpg"
    }
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
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
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
        let directory = cacheDir
        let maxBytes = maxDiskBytes
        Task.detached(priority: .background) {
            image.jpegData(compressionQuality: 0.80).map { try? $0.write(to: path, options: .atomic) }
            if await ImageDiskPruneGate.shared.shouldPrune() {
                Self.prune(directory: directory, maxBytes: maxBytes)
            }
        }
    }

    // MARK: - Fetch (cache-first)
    @discardableResult
    func fetchImage(url urlString: String) async -> UIImage? {
        let canonicalURL = URLCanonicalizer.canonicalString(urlString)
        if let mem = memoryImage(for: canonicalURL) { return mem }

        // Coalesce the entire disk/network pipeline. A recipe grid often contains the same
        // image in multiple rails; previously each card started its own disk read and download.
        let request: InFlightImageRequest = withStateLock {
            if let existing = inFlightRequests[canonicalURL] { return existing }
            let id = UUID()
            let task = Task(priority: .userInitiated) { [weak self] () -> UIImage? in
                guard let self else { return nil }
                return await self.loadImageUncoalesced(urlString: canonicalURL)
            }
            let created = InFlightImageRequest(id: id, task: task)
            inFlightRequests[canonicalURL] = created
            return created
        }

        let image = await request.task.value
        withStateLock {
            if inFlightRequests[canonicalURL]?.id == request.id {
                inFlightRequests.removeValue(forKey: canonicalURL)
            }
        }
        return image
    }

    private func loadImageUncoalesced(urlString: String) async -> UIImage? {
        if let disk = await diskImage(for: urlString) { return disk }
        guard !Task.isCancelled, let url = URL(string: urlString) else { return nil }

        await ImageFetchLimiter.shared.acquire()
        if Task.isCancelled {
            await ImageFetchLimiter.shared.release()
            return nil
        }

        let result: UIImage?
        do {
            let (data, response) = try await URLSession.shared.data(for: ImageCache.imageRequest(for: url))
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode),
                  response.mimeType?.lowercased().hasPrefix("image/") == true,
                  response.expectedContentLength <= 20 * 1_048_576 || response.expectedContentLength < 0,
                  data.count <= 20 * 1_048_576,
                  let image = ImageCache.downsample(data, maxDimension: 700) ?? UIImage(data: data)
            else {
                await ImageFetchLimiter.shared.release()
                return nil
            }
            store(image, for: urlString)
            result = image
        } catch {
            result = nil
        }
        await ImageFetchLimiter.shared.release()
        return result
    }

    /// A request that recipe sites will actually answer.
    ///
    /// Most recipe photos live behind a CDN configured to refuse hotlinking: a bare GET with
    /// no `Referer` and a URLSession user agent comes back 403, and the card shows a grey
    /// placeholder for a picture that loads perfectly in a browser. Sending the image's own
    /// origin as the referrer is what a page on that site would send, and a plain browser
    /// user agent stops the simpler filters. Accept is set so servers that content-negotiate
    /// hand back an image rather than an HTML error page.
    nonisolated static func imageRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        if let scheme = url.scheme, let host = url.host {
            request.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        request.setValue("image/avif,image/webp,image/jpeg,image/png,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 20
        return request
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
        for rawURL in urls.prefix(10) {
            let url = URLCanonicalizer.canonicalString(rawURL)
            guard memoryImage(for: url) == nil else { continue }

            withStateLock {
                guard prefetchTasks[url] == nil else { return }
                prefetchTasks[url] = Task(priority: .background) { [weak self] in
                    guard let self else { return }
                    _ = await self.fetchImage(url: url)
                    self.withStateLock {
                        self.prefetchTasks.removeValue(forKey: url)
                    }
                }
            }
        }
    }

    func cancelPrefetch(for rawURL: String) {
        let url = URLCanonicalizer.canonicalString(rawURL)
        let task = withStateLock { prefetchTasks.removeValue(forKey: url) }
        task?.cancel()
    }

    private func pruneDiskIfNeeded() {
        Self.prune(directory: cacheDir, maxBytes: maxDiskBytes)
    }

    private nonisolated static func prune(directory: URL, maxBytes: Int) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        )) ?? []
        var records: [(URL, Int, Date)] = files.map { url in
            let values = try? url.resourceValues(forKeys: keys)
            return (url, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast)
        }
        var total = records.reduce(0) { $0 + $1.1 }
        guard total > maxBytes else { return }
        let target = Int(Double(maxBytes) * 0.85)
        records.sort { $0.2 < $1.2 }
        for (url, size, _) in records where total > target {
            try? FileManager.default.removeItem(at: url)
            total -= size
        }
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
    /// #8 — memory-pressure eviction: drop the in-memory image caches and cancel
    /// prefetch/in-flight decodes, but KEEP the disk cache (cheap to reload, survives
    /// pressure — that's the point of the disk layer). Called on a memory warning.
    func evictMemory() {
        let tasks = withStateLock { () -> [Task<Void, Never>] in
            let t = Array(prefetchTasks.values)
            prefetchTasks.removeAll()
            inFlightRequests.values.forEach { $0.task.cancel() }
            inFlightRequests.removeAll()
            return t
        }
        tasks.forEach { $0.cancel() }
        memCache.removeAllObjects()
        localDataCache.removeAllObjects()
    }

    func clearAll() {
        let tasks = withStateLock { () -> [Task<Void, Never>] in
            let tasks = Array(prefetchTasks.values)
            prefetchTasks.removeAll()
            inFlightRequests.values.forEach { $0.task.cancel() }
            inFlightRequests.removeAll()
            return tasks
        }
        tasks.forEach { $0.cancel() }
        memCache.removeAllObjects()
        localDataCache.removeAllObjects()
        let directory = cacheDir
        Task.detached(priority: .utility) {
            ((try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)) ?? [])
                .forEach { try? FileManager.default.removeItem(at: $0) }
        }
    }
}

private actor ImageDiskPruneGate {
    static let shared = ImageDiskPruneGate()
    private var writes = 0

    func shouldPrune() -> Bool {
        writes += 1
        if writes >= 25 {
            writes = 0
            return true
        }
        return false
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
/// A deliberately uniform thumbnail for compact recipe lists.
/// Use this where mixing remote photography with placeholders makes sibling rows look broken;
/// full recipe detail and hero surfaces continue to use real photography.
struct UniformRecipeIcon: View {
    var size: CGFloat = 52

    var body: some View {
        RoundedRectangle(cornerRadius: max(10, size * 0.21))
            .fill(Color.stockedGold.opacity(0.12))
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "fork.knife")
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(Color.stockedGold)
            }
            .overlay {
                RoundedRectangle(cornerRadius: max(10, size * 0.21))
                    .stroke(Color.stockedGold.opacity(0.18), lineWidth: 1)
            }
    }
}

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
