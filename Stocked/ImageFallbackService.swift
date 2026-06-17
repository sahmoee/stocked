// ImageFallbackService.swift
// Provides online image fallback for recipe/food items with no local image.
// Strategy (in order of preference):
//   1. Stored imageURL on the item — load directly
//   2. Open Food Facts CDN — for branded grocery items (barcode lookup)
//   3. System emoji placeholder — always available, zero network, zero attribution requirements
//
// NOTE: source.unsplash.com was removed — it was deprecated by Unsplash in 2022
// and their API terms require per-photo attribution which this app does not implement.
// Use the official Unsplash API (api.unsplash.com) with a registered API key if
// photo backgrounds are needed in a future build.

import SwiftUI

// MARK: - Memory-Aware Image Cache

final class StockedImageCache {
    static let shared = StockedImageCache()

    // NSCache auto-evicts on memory pressure — perfect for images
    private let cache = NSCache<NSString, UIImage>()
    private let maxImages = 200

    // #13: Tiered eviction — thumbnails purged first, detail images kept longer
    private let thumbnailSizeThreshold: Int = 100 * 100 * 4  // ~40KB
    private var thumbnailKeys: [String] = []
    private var detailKeys:    [String] = []

    private init() {
        cache.countLimit     = maxImages
        cache.totalCostLimit = 80 * 1024 * 1024  // 80 MB cap (raised — tiered eviction handles pressure)
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // Tier 1: remove thumbnails first
            self.thumbnailKeys.forEach { self.cache.removeObject(forKey: $0 as NSString) }
            self.thumbnailKeys.removeAll()
            // Tier 2: only remove detail images if still under pressure
            if ProcessInfo.processInfo.physicalMemory < 200_000_000 {
                self.detailKeys.forEach { self.cache.removeObject(forKey: $0 as NSString) }
                self.detailKeys.removeAll()
            }
        }
    }

    func get(_ url: String) -> UIImage?    { cache.object(forKey: url as NSString) }
    func set(_ image: UIImage, for url: String, isThumbnail: Bool = false) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSString, cost: cost)
        // #13: Track by tier for eviction ordering
        if isThumbnail || cost < thumbnailSizeThreshold { thumbnailKeys.append(url) }
        else { detailKeys.append(url) }
    }
    func clear() { cache.removeAllObjects() }
}

// MARK: - Fallback URL Builder

enum ImageFallbackService {

    /// Returns the best image URL for a given item name and optional stored URL.
    /// Falls back to Open Food Facts CDN for barcode products; otherwise returns nil
    /// so the caller renders the emoji placeholder instead.
    static func imageURL(for name: String, storedURL: String? = nil) -> URL? {
        // 1. Use stored URL if valid
        if let stored = storedURL, !stored.isEmpty, let url = URL(string: stored) {
            return url
        }
        // No reliable free food-image API without attribution requirements.
        // Return nil → AsyncFoodImage renders the emoji placeholder.
        return nil
    }

    /// Returns the Open Food Facts image URL for a barcode-identified product.
    static func openFoodFactsImageURL(barcode: String) -> URL? {
        let padded = String(barcode.suffix(9))
        let p1 = String(padded.prefix(3))
        let p2 = String(padded.dropFirst(3).prefix(3))
        let p3 = String(padded.dropFirst(6).prefix(3))
        let urlStr = "https://images.openfoodfacts.org/images/products/\(p1)/\(p2)/\(p3)/front_en.400.jpg"
        return URL(string: urlStr)
    }

    /// Emoji fallback based on item name — works offline, zero latency.
    static func emoji(for name: String) -> String {
        let n = name.lowercased()
        let map: [(String, String)] = [
            ("chicken", "🍗"), ("beef", "🥩"), ("pork", "🥓"), ("fish", "🐟"),
            ("salmon", "🐟"), ("shrimp", "🦐"), ("egg", "🥚"), ("tofu", "🫘"),
            ("apple", "🍎"), ("banana", "🍌"), ("orange", "🍊"), ("lemon", "🍋"),
            ("strawberr", "🍓"), ("grape", "🍇"), ("peach", "🍑"), ("mango", "🥭"),
            ("avocado", "🥑"), ("tomato", "🍅"), ("carrot", "🥕"), ("corn", "🌽"),
            ("broccoli", "🥦"), ("spinach", "🥬"), ("lettuce", "🥬"), ("kale", "🥬"),
            ("onion", "🧅"), ("garlic", "🧄"), ("potato", "🥔"), ("sweet potato", "🍠"),
            ("mushroom", "🍄"), ("pepper", "🌶"), ("cucumber", "🥒"), ("eggplant", "🍆"),
            ("milk", "🥛"), ("cheese", "🧀"), ("butter", "🧈"), ("yogurt", "🥛"),
            ("bread", "🍞"), ("rice", "🍚"), ("pasta", "🍝"), ("noodle", "🍜"),
            ("cake", "🎂"), ("cookie", "🍪"), ("pie", "🥧"), ("chocolate", "🍫"),
            ("ice cream", "🍦"), ("candy", "🍬"), ("coffee", "☕"), ("tea", "🍵"),
            ("beer", "🍺"), ("wine", "🍷"), ("juice", "🧃"), ("water", "💧"),
            ("oil", "🫙"), ("vinegar", "🫙"), ("salt", "🧂"), ("sugar", "🍬"),
            ("sauce", "🥫"), ("soup", "🍲"), ("salad", "🥗"), ("pizza", "🍕"),
            ("burger", "🍔"), ("sandwich", "🥪"), ("taco", "🌮"), ("sushi", "🍱"),
        ]
        for (keyword, emoji) in map where n.contains(keyword) { return emoji }
        return "🫙"
    }
}

// MARK: - AsyncFoodImage View

/// Drop-in image view with automatic fallback chain.
/// Usage: AsyncFoodImage(name: "Chicken Breast", url: item.imageURL, size: 60)
struct AsyncFoodImage: View {
    let name:    String
    let url:     String?
    var size:    CGFloat    = 56
    var radius:  CGFloat    = 10
    var showEmojiFallback = true
    // When true, and no stored URL works, look the image up online by recipe name
    // (TheMealDB → Spoonacular → Foodish) before falling back to the emoji placeholder.
    var resolveOnline = false
    var category: String? = nil

    @State private var loadedImage: UIImage? = nil
    @State private var failed = false

    var body: some View {
        Group {
            if let img = loadedImage {
                Image(uiImage: img)
                    .resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: radius))
            } else if failed && showEmojiFallback {
                ZStack {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(Color.stockedWhite.opacity(0.3))
                    Text(ImageFallbackService.emoji(for: name))
                        .font(.system(size: size * 0.55))
                }
                .frame(width: size, height: size)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: radius)
                        .fill(Color.stockedWhite.opacity(0.2))
                    if !failed {
                        ProgressView().scaleEffect(0.6)
                    }
                }
                .frame(width: size, height: size)
            }
        }
        .onAppear { loadImage() }
    }

    private func loadImage() {
        // Fast path: a usable stored URL (or barcode-derived URL).
        if let target = ImageFallbackService.imageURL(for: name, storedURL: url) {
            loadFrom(target.absoluteString, allowResolveFallback: resolveOnline)
        } else if resolveOnline {
            // No stored image — resolve one online by recipe name.
            resolveAndLoad()
        } else {
            failed = true
        }
    }

    private func loadFrom(_ key: String, allowResolveFallback: Bool) {
        if let cached = StockedImageCache.shared.get(key) { loadedImage = cached; return }
        Task {
            do {
                let (data, _) = try await URLSession.shared.data(from: URL(string: key)!)
                guard let img = UIImage(data: data) else { throw URLError(.badServerResponse) }
                StockedImageCache.shared.set(img, for: key)
                await MainActor.run { loadedImage = img }
            } catch {
                if allowResolveFallback {
                    resolveAndLoad()
                } else {
                    await MainActor.run { failed = true }
                }
            }
        }
    }

    private func resolveAndLoad() {
        Task {
            guard let resolved = await RecipeImageResolver.shared.imageURL(for: name, category: category) else {
                await MainActor.run { failed = true }; return
            }
            let key = resolved.absoluteString
            if let cached = StockedImageCache.shared.get(key) {
                await MainActor.run { loadedImage = cached }; return
            }
            do {
                let (data, _) = try await URLSession.shared.data(from: resolved)
                guard let img = UIImage(data: data) else { throw URLError(.badServerResponse) }
                StockedImageCache.shared.set(img, for: key)
                await MainActor.run { loadedImage = img }
            } catch {
                await MainActor.run { failed = true }
            }
        }
    }
}
