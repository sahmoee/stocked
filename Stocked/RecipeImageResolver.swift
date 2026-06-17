// RecipeImageResolver.swift
// Fills in a missing recipe image by looking the recipe title up across several
// food-image sources, in order, and returning the first working image URL.
//
// WHY NOT GOOGLE IMAGES: Google has no free, licensable image API — the legacy Image
// Search API was retired, the Custom Search API returns third-party-copyrighted images
// (an App Review / licensing risk to embed), and scraping the results page violates
// Google's ToS and breaks constantly. Instead we use sources that are free to use and
// return food photography intended for reuse:
//
//   1. TheMealDB   — search.php?s=<title> → strMealThumb (free, no key; already used elsewhere)
//   2. Spoonacular — complexSearch?query=<title> → image (uses SpoonacularAPIKey; ~150/day free)
//   3. Foodish     — a real food photo chosen by the category inferred from the title
//                    (free, no key). Last resort so a recipe never shows a bare placeholder;
//                    we map title→category first to avoid the worst mismatches.
//   4. (caller falls back to the emoji placeholder if this returns nil)
//
// Results are cached by normalized title (in memory + on disk) so we never re-hit the
// network for the same recipe, which also protects the Spoonacular daily quota.

import Foundation
import os
import UIKit

actor RecipeImageResolver {
    static let shared = RecipeImageResolver()

    // normalized title → resolved URL string ("" = looked up, found nothing)
    private var cache: [String: String] = [:]
    private let cacheKey = "recipeImageResolverCache_v4"   // v4: category-accurate MealDB fallback + no random Foodish; clears old mismatched entries
    private var loaded = false

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 10
        cfg.timeoutIntervalForResource = 15
        return URLSession(configuration: cfg)
    }()

    private func normalize(_ title: String) -> String {
        title.lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func loadCacheIfNeeded() {
        guard !loaded else { return }
        loaded = true
        if let data = UserDefaults.standard.data(forKey: cacheKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = decoded
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(cache) {
            UserDefaults.standard.set(data, forKey: cacheKey)
        }
    }

    /// Resolve an image URL for a recipe title. Returns nil if every source struck out
    /// (caller should then render the emoji placeholder). `category` optionally biases the
    /// Foodish generic fallback (e.g. "dessert", "pasta", "rice").
    func imageURL(for title: String, category: String? = nil) async -> URL? {
        loadCacheIfNeeded()
        let key = normalize(title)
        guard !key.isEmpty else { return nil }

        // Cache hit (including a remembered "nothing found" → "").
        if let hit = cache[key] {
            return hit.isEmpty ? nil : URL(string: hit)
        }

        // Try sources in order; first valid wins. Sources 1–2 return an image OF THE ACTUAL
        // DISH (MealDB, Spoonacular). Source 3 (Foodish) is a real food photo chosen by the
        // closest category we can infer from the title — used only as a last resort so a
        // recipe never shows a sterile placeholder. We map the title to a category first to
        // avoid the worst mismatches (random only when nothing maps).
        var found: String? = await mealDBThumb(title)
        // If the exact name misses, get a REAL dish photo of the right protein/category
        // (e.g. a beef dish for "Pan-Seared Steak") instead of an unrelated random photo.
        if found == nil { found = await mealDBByCategory(title) }
        if found == nil { found = await spoonacularImage(title) }

        // Validate the dish-accurate URL actually returns an image before caching it.
        if let candidate = found, !(await isReachableImage(candidate)) {
            found = nil
        }

        // Last resort: a category-matched food photo — ONLY when the title clearly maps to a
        // Foodish category. If nothing maps, leave nil so the caller shows the dish emoji rather
        // than a random, unrelated photo (the apple-pastry-on-a-steak problem).
        if found == nil, let hint = category ?? Self.foodishCategoryHint(from: title) {
            found = await foodishImage(category: hint)
        }

        // #17 — store the canonical URL (tracking params/fragment stripped) so the same
        // image from differing query-string variants resolves to one cache entry.
        let canonical = found.map { URLCanonicalizer.canonicalString($0) }
        cache[key] = canonical ?? ""   // remember misses too, so we don't retry every render
        persist()
        return canonical.flatMap { URL(string: $0) }
    }

    // MARK: - Source 1: TheMealDB (free, no key)
    private func mealDBThumb(_ title: String) async -> String? {
        guard let q = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.themealdb.com/api/json/v1/1/search.php?s=\(q)") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let meals = json["meals"] as? [[String: Any]],
                  let thumb = meals.first?["strMealThumb"] as? String,
                  !thumb.isEmpty else { return nil }
            return thumb
        } catch {
            Log.net.debug("MealDB image lookup failed for \(title, privacy: .public)")
            return nil
        }
    }

    // MARK: - Source 1b: TheMealDB filter-by-category (free, no key)
    // When the exact dish name isn't in TheMealDB, map the title to the closest real food
    // category (Beef, Chicken, Seafood, …) and pull a genuine dish photo from it. A beef dish
    // for a steak is dramatically better than a random unrelated photo.
    private func mealDBByCategory(_ title: String) async -> String? {
        guard let cat = Self.mealDBCategory(from: title),
              let q = cat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.themealdb.com/api/json/v1/1/filter.php?c=\(q)") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let meals = json["meals"] as? [[String: Any]],
                  let thumb = meals.randomElement()?["strMealThumb"] as? String,
                  !thumb.isEmpty else { return nil }
            return thumb
        } catch {
            Log.net.debug("MealDB category lookup failed for \(title, privacy: .public)")
            return nil
        }
    }

    // Map a recipe title to a real TheMealDB category. Conservative — returns nil when nothing
    // clearly fits so we don't force an unrelated category.
    static func mealDBCategory(from title: String) -> String? {
        let t = title.lowercased()
        switch true {
        case t.contains("steak"), t.contains("beef"), t.contains("brisket"), t.contains("meatball"),
             t.contains("meatloaf"), t.contains("burger"), t.contains("sirloin"), t.contains("ribeye"):
            return "Beef"
        case t.contains("chicken"), t.contains("poultry"), t.contains("wing"), t.contains("drumstick"), t.contains("turkey"):
            return "Chicken"
        case t.contains("pork"), t.contains("bacon"), t.contains("ham"), t.contains("sausage"),
             t.contains("pork chop"), t.contains("ribs"), t.contains("pulled pork"):
            return "Pork"
        case t.contains("lamb"), t.contains("mutton"):
            return "Lamb"
        case t.contains("fish"), t.contains("salmon"), t.contains("tuna"), t.contains("shrimp"),
             t.contains("prawn"), t.contains("seafood"), t.contains("cod"), t.contains("tilapia"),
             t.contains("crab"), t.contains("lobster"), t.contains("scallop"), t.contains("clam"), t.contains("mussel"):
            return "Seafood"
        case t.contains("pasta"), t.contains("spaghetti"), t.contains("lasagna"), t.contains("noodle"),
             t.contains("alfredo"), t.contains("mac and cheese"), t.contains("ravioli"), t.contains("penne"):
            return "Pasta"
        case t.contains("dessert"), t.contains("cake"), t.contains("pie"), t.contains("cookie"),
             t.contains("brownie"), t.contains("pudding"), t.contains("ice cream"), t.contains("tart"), t.contains("cheesecake"):
            return "Dessert"
        case t.contains("breakfast"), t.contains("pancake"), t.contains("omelet"), t.contains("omelette"),
             t.contains("waffle"), t.contains("french toast"), t.contains("scrambled"), t.contains("egg"):
            return "Breakfast"
        case t.contains("vegan"):
            return "Vegan"
        case t.contains("vegetarian"), t.contains("veggie"), t.contains("tofu"), t.contains("salad"):
            return "Vegetarian"
        default:
            return nil
        }
    }

    // MARK: - Source 2: Spoonacular complexSearch (uses key; quota-limited)
    private func spoonacularImage(_ title: String) async -> String? {
        let apiKey = BuildConfig.spoonacularAPIKey
        guard !apiKey.isEmpty, !apiKey.hasPrefix("YOUR_"),
              let q = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.spoonacular.com/recipes/complexSearch?query=\(q)&number=1&apiKey=\(apiKey)")
        else { return nil }
        do {
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, http.statusCode == 402 {
                Log.net.notice("Spoonacular daily quota reached; skipping image source")
                return nil
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = json["results"] as? [[String: Any]],
                  let image = results.first?["image"] as? String,
                  !image.isEmpty else { return nil }
            return image
        } catch {
            Log.net.debug("Spoonacular image lookup failed for \(title, privacy: .public)")
            return nil
        }
    }

    // MARK: - Source 3: Foodish generic food photo (free, no key)
    // Foodish returns JSON {"image":"https://…jpg"} with an appetizing real food photo.
    // It's not the exact dish, but it's far better than an emoji on a recipe card and
    // never comes back empty. We bias the category endpoint when we can.
    // Infer a Foodish category from the recipe TITLE (since suggested recipes pass a title,
    // not a category). Returns a hint string foodishImage() understands, or nil → random.
    // Conservative: only map when a keyword clearly fits, so we mostly avoid bad mismatches.
    static func foodishCategoryHint(from title: String) -> String? {
        let t = title.lowercased()
        switch true {
        case t.contains("dessert"), t.contains("cake"), t.contains("cookie"), t.contains("brownie"),
             t.contains("pie"), t.contains("ice cream"), t.contains("pudding"), t.contains("sweet"):
            return "dessert"
        case t.contains("pasta"), t.contains("noodle"), t.contains("spaghetti"), t.contains("mac and cheese"),
             t.contains("lasagna"), t.contains("ramen"), t.contains("lo mein"), t.contains("alfredo"):
            return "pasta"
        case t.contains("pizza"), t.contains("flatbread"), t.contains("calzone"):
            return "pizza"
        case t.contains("rice"), t.contains("fried rice"), t.contains("risotto"), t.contains("pilaf"),
             t.contains("stir fry"), t.contains("stir-fry"), t.contains("biryani"), t.contains("grain bowl"):
            return "rice"
        case t.contains("burger"), t.contains("sandwich"), t.contains("sliders"), t.contains("wrap"),
             t.contains("taco"), t.contains("burrito"), t.contains("quesadilla"):
            return "burger"
        case t.contains("curry"), t.contains("masala"), t.contains("tikka"), t.contains("butter chicken"):
            return "butter-chicken"
        case t.contains("samosa"), t.contains("pakora"), t.contains("fritter"):
            return "samosa"
        default:
            return nil   // nothing clearly maps → foodishImage falls to a random food photo
        }
    }

    private func foodishImage(category: String?) async -> String? {
        // Foodish categories: biryani, burger, butter-chicken, dessert, dosa, idly,
        // pasta, pizza, rice, samosa. Map our hint onto the closest one.
        let cat = (category ?? "").lowercased()
        let mapped: String?
        switch true {
        case cat.contains("dessert"), cat.contains("cake"), cat.contains("sweet"): mapped = "dessert"
        case cat.contains("pasta"), cat.contains("noodle"):                        mapped = "pasta"
        case cat.contains("pizza"):                                                mapped = "pizza"
        case cat.contains("rice"), cat.contains("grain"):                          mapped = "rice"
        case cat.contains("burger"), cat.contains("sandwich"):                     mapped = "burger"
        default: mapped = nil
        }
        // Defense in depth: never call the random Foodish endpoint. An unmapped category means
        // we'd rather return nil (→ dish emoji) than a random, unrelated food photo.
        guard let m = mapped,
              let url = URL(string: "https://foodish-api.com/api/images/\(m)") else { return nil }
        do {
            let (data, _) = try await session.data(from: url)
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let image = json["image"] as? String, !image.isEmpty else { return nil }
            return image
        } catch {
            Log.net.debug("Foodish image lookup failed")
            return nil
        }
    }

    // MARK: - Reachability (confirm the URL is actually an image)
    private func isReachableImage(_ urlString: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("bytes=0-2048", forHTTPHeaderField: "Range")   // pull just the header bytes
        do {
            let (data, response) = try await session.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else { return false }
            if let ct = http.value(forHTTPHeaderField: "Content-Type"), ct.hasPrefix("image/") { return true }
            return UIImage(data: data) != nil
        } catch {
            return false
        }
    }

    // MARK: - One-time background backfill
    // Fills missing images across the recipe DB. Runs once per install, throttled and
    // bounded so it's gentle on the Spoonacular quota (most hits are free TheMealDB/Foodish).
    static func backfillMissingImagesIfNeeded() {
        let flagKey = "didBackfillRecipeImages_v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        Task(priority: .background) {
            await shared.backfill(limit: 40)
            UserDefaults.standard.set(true, forKey: flagKey)
        }
    }

    private func backfill(limit: Int) async {
        let entries = await RecipeDatabase.shared.all()
        let missing = entries.filter { $0.imageURL.isEmpty }.prefix(limit)
        guard !missing.isEmpty else { return }
        Log.net.notice("Backfilling images for \(missing.count, privacy: .public) recipes")
        var filled = 0
        for var entry in missing {
            if let url = await imageURL(for: entry.title, category: entry.category) {
                entry.imageURL = url.absoluteString
                await RecipeDatabase.shared.upsert(entry)
                filled += 1
            }
            // Be polite — small gap between lookups so we don't burst any single source.
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        Log.net.notice("Image backfill complete: \(filled, privacy: .public) filled")
    }
}
