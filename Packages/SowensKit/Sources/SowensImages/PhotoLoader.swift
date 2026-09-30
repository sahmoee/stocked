import Foundation
import Kingfisher
import SowensKit

/// Disposable public-image cache. Existing apps with authoritative photo stores retain their owners.
public actor SowensPhotoLoader {
    public static let shared = SowensPhotoLoader()
    private let cache: Kingfisher.ImageCache
    private let fetcher: @Sendable (URL) async -> KFCrossPlatformImage?
    private struct Pending {
        let id: UUID
        let task: Task<KFCrossPlatformImage?, Never>
        var waiters: Set<UUID>
    }
    private var pending: [URL: Pending] = [:]
    private var generation = 0

    public init() {
        fetcher = { await Self.download($0) }
        cache = Kingfisher.ImageCache(name: "sowens-public-photos-v1")
        cache.memoryStorage.config.totalCostLimit = 32 * 1_024 * 1_024
        cache.memoryStorage.config.countLimit = 60
        cache.diskStorage.config.sizeLimit = 100 * 1_024 * 1_024
        cache.diskStorage.config.expiration = .days(7)
    }

    init(cache: Kingfisher.ImageCache, fetcher: @escaping @Sendable (URL) async -> KFCrossPlatformImage?) {
        self.cache = cache
        self.fetcher = fetcher
    }

    public func image(for url: URL) async -> KFCrossPlatformImage? {
        guard !Task.isCancelled, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        let revision = generation
        if let cached = try? await cache.retrieveImage(forKey: url.absoluteString).image {
            return Task.isCancelled || revision != generation ? nil : cached
        }
        guard !Task.isCancelled, revision == generation else { return nil }
        // Keep rapid scrolling from creating an unbounded number of downloads/decoders.
        while pending[url] == nil && pending.count >= 6 {
            do { try await Task.sleep(for: .milliseconds(50)) } catch { return nil }
            guard revision == generation else { return nil }
        }
        guard !Task.isCancelled else { return nil }
        if let cached = cache.retrieveImageInMemoryCache(forKey: url.absoluteString) { return cached }
        let waiter = UUID()
        let request: Pending
        if var existing = pending[url] {
            existing.waiters.insert(waiter)
            pending[url] = existing
            request = existing
        } else {
            let fetcher = self.fetcher
            let task = Task.detached(priority: .utility) { await fetcher(url) }
            request = Pending(id: UUID(), task: task, waiters: [waiter])
            pending[url] = request
        }
        let image = await withTaskCancellationHandler {
            await request.task.value
        } onCancel: {
            Task { await self.cancelWaiter(waiter, url: url, requestID: request.id) }
        }
        guard revision == generation, !request.task.isCancelled else { return nil }
        if pending[url]?.id == request.id {
            pending[url] = nil
            if let image {
                // Enqueue storage before clear can run, so an old write cannot repopulate a cleared cache.
                cache.store(image, forKey: url.absoluteString, completionHandler: nil)
            }
        }
        return Task.isCancelled ? nil : image
    }

    private func cancelWaiter(_ waiter: UUID, url: URL, requestID: UUID) {
        guard var request = pending[url], request.id == requestID else { return }
        request.waiters.remove(waiter)
        if request.waiters.isEmpty {
            request.task.cancel()
            pending[url] = nil
        } else {
            pending[url] = request
        }
    }

    public func clear() async {
        generation += 1
        pending.values.forEach { $0.task.cancel() }
        pending.removeAll()
        cache.clearMemoryCache()
        await cache.clearDiskCache()
    }

    private static func download(_ url: URL) async -> KFCrossPlatformImage? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration, delegate: HTTPSRedirectGuard(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let started = ProcessInfo.processInfo.systemUptime
        var size = 0
        var response: URLResponse?
        do {
            let (stream, received) = try await session.bytes(from: url)
            response = received
            guard let http = received as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  received.expectedContentLength <= 8_000_000 else { throw URLError(.badServerResponse) }
            var data = Data()
            for try await byte in stream {
                if size % 16_384 == 0 { try Task.checkCancellation() }
                guard size < 8_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
                data.append(byte)
                size += 1
            }
            try Task.checkCancellation()
            let processor = DownsamplingImageProcessor(size: CGSize(width: 1_200, height: 1_200))
            guard let image = processor.process(item: .data(data), options: KingfisherParsedOptionsInfo([])) else {
                throw URLError(.cannotDecodeContentData)
            }
            NetworkDiagnostics.record(.init(request: URLRequest(url: url), response: received, bytes: size,
                                            elapsed: ProcessInfo.processInfo.systemUptime - started))
            return image
        } catch {
            NetworkDiagnostics.record(.init(request: URLRequest(url: url), response: response, bytes: size,
                                            elapsed: ProcessInfo.processInfo.systemUptime - started, error: error))
            return nil
        }
    }
}

private final class HTTPSRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let url = request.url
        completionHandler(url?.scheme?.lowercased() == "https" && url?.user == nil && url?.password == nil ? request : nil)
    }
}
