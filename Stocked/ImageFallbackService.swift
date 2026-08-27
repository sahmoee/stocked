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
                    FoodIconView(name: name, category: category, size: size * 0.9, emojiSize: size * 0.55)
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
        if let cached = ImageCache.shared.memoryImage(for: key) { loadedImage = cached; return }
        // A malformed key must never trap the app. URL(string:) returns nil on a bad
        // string (spaces, an empty path, a scheme-less relative path), so guard it and
        // route the miss through the same fallback a network failure would take.
        guard let target = URL(string: key) else {
            if allowResolveFallback { resolveAndLoad() } else { failed = true }
            return
        }
        Task {
            if let img = await ImageCache.shared.fetchImage(url: target.absoluteString) {
                await MainActor.run { loadedImage = img }
            } else {
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
            if let cached = ImageCache.shared.memoryImage(for: key) {
                await MainActor.run { loadedImage = cached }; return
            }
            if let img = await ImageCache.shared.fetchImage(url: key) {
                await MainActor.run { loadedImage = img }
            } else {
                await MainActor.run { failed = true }
            }
        }
    }
}

// MARK: - FoodIconView (bundled inventory icon → category icon → emoji)

/// Renders an item's icon from Icons.xcassets, falling back to its category icon,
/// then to the emoji placeholder. Requires ItemIcon.swift (IconResolver) + Icons.xcassets.
struct FoodIconView: View {
    let name: String
    var category: String? = nil
    /// Square size for the bundled image (the emoji uses `emojiSize`).
    var size: CGFloat = 40
    var emojiSize: CGFloat = 22

    var body: some View {
        let slug = IconResolver.slug(name)
        let catAsset = category.map { IconResolver.categoryIcon[$0.lowercased()] ?? IconResolver.slug($0) }
        if assetExists(slug) {
            Image(slug).resizable().scaledToFit().frame(width: size, height: size)
        } else if let c = catAsset, assetExists(c) {
            Image(c).resizable().scaledToFit().frame(width: size, height: size)
        } else {
            Text(ImageFallbackService.emoji(for: name)).font(.system(size: emojiSize))
        }
    }

    private func assetExists(_ n: String) -> Bool {
        // #PERF — UIImage(named:) caches HITS but a MISS walks the asset catalog every
        // call. Inventory rows call this for every item on every render, so items with
        // no bundled icon paid a catalog lookup per row per frame. Memoize misses.
        if Self.knownMissing.contains(n) { return false }
        #if canImport(UIKit)
        let exists = UIImage(named: n) != nil
        #elseif canImport(AppKit)
        let exists = NSImage(named: n) != nil
        #else
        let exists = false
        #endif
        if !exists { Self.knownMissing.insert(n) }
        return exists
    }
    @MainActor private static var knownMissing = Set<String>()
}
