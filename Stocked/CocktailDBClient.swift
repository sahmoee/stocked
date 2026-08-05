// CocktailDBClient.swift
// ─────────────────────────────────────────────────────────────────────────────
// TheCocktailDB sync — feeds StockedKnowledgeBase (ingredients) and
// RecipeDatabase (cocktail/drink recipes) silently on background sync.
// No UI. No new tabs. Data flows into predictive text and search automatically.
// ─────────────────────────────────────────────────────────────────────────────
import Foundation

nonisolated struct CocktailRecipe: Identifiable, Codable, Sendable {
    let id:           String
    let name:         String
    let category:     String
    let alcoholic:    String
    let glass:        String
    let instructions: String
    let imageURL:     String
    let ingredients:  [String]
    let measures:     [String]
}

actor CocktailDBClient {

    static let shared = CocktailDBClient()
    private init() {}

    private let syncKey = "cocktailDBLastSync"
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 8
        return URLSession(configuration: c)
    }()

    // Called from StockedKnowledgeBase.backgroundSync() — max once per 12h
    func syncIfNeeded() async {
        guard shouldSync() else { return }
        await sync()
        UserDefaults.standard.set(Date(), forKey: syncKey)
    }

    func sync() async {
        // Fetch non-alcoholic + popular categories to keep data family-friendly by default
        let categories = ["Soft Drink", "Coffee / Tea", "Shake", "Punch / Party Drink",
                          "Cocktail", "Shot", "Other / Unknown"]
        await withTaskGroup(of: Void.self) { group in
            for cat in categories {
                group.addTask { await self.fetchCategory(cat) }
            }
        }
    }

    private func fetchCategory(_ category: String) async {
        let enc = category.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? category
        guard let url = URL(string: "https://www.thecocktaildb.com/api/json/v1/1/filter.php?c=\(enc)"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let drinks = json["drinks"] as? [[String: Any]] else { return }

        for d in drinks.shuffled().prefix(4) {
            guard let id = d["idDrink"] as? String else { continue }
            if let recipe = await fetchById(id) { await ingest(recipe) }
        }
    }

    // MARK: - Discover feed
    /// Fetch a batch of cocktails as OnlineRecipe values for the Recipes "Discover"
    /// feed. Cocktails carry real instructions + ingredients, so they pass the
    /// no-steps filter and show up as proper recipes (source: "TheCocktailDB").
    /// Uses the free public key ("1"); no configuration required.
    func discoverRecipes(limit: Int = 8) async -> [OnlineRecipe] {
        // Pull drink IDs from a couple of popular categories, then look up details.
        let categories = ["Cocktail", "Ordinary_Drink"]
        var ids: [String] = []
        for cat in categories {
            guard let enc = cat.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: "https://www.thecocktaildb.com/api/json/v1/1/filter.php?c=\(enc)"),
                  let (data, _) = try? await session.data(from: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let drinks = json["drinks"] as? [[String: Any]] else { continue }
            ids += drinks.compactMap { $0["idDrink"] as? String }
            if ids.count >= limit * 2 { break }
        }
        guard !ids.isEmpty else { return [] }

        // Look up a shuffled subset for variety, in parallel.
        let pick = Array(ids.shuffled().prefix(limit))
        var out: [OnlineRecipe] = []
        await withTaskGroup(of: OnlineRecipe?.self) { group in
            for id in pick {
                group.addTask { [weak self] in
                    guard let c = await self?.fetchById(id) else { return nil }
                    return CocktailDBClient.asOnlineRecipe(c)
                }
            }
            for await r in group { if let r { out.append(r) } }
        }
        return out
    }

    /// Map a CocktailRecipe to an OnlineRecipe (steps derived from instructions).
    /// nonisolated: a pure value transform with no shared state, so it can be called
    /// from the non-isolated task-group closures in discoverRecipes().
    nonisolated private static func asOnlineRecipe(_ c: CocktailRecipe) -> OnlineRecipe {
        OnlineRecipe(
            id: "cocktail-\(c.id)",
            title: c.name,
            category: "Drink",
            area: c.category,
            instructions: c.instructions,
            imageURL: c.imageURL,
            ingredients: c.ingredients,
            measures: c.measures,
            source: "TheCocktailDB"
        )
    }

    private func fetchById(_ id: String) async -> CocktailRecipe? {
        guard let url = URL(string: "https://www.thecocktaildb.com/api/json/v1/1/lookup.php?i=\(id)"),
              let (data, _) = try? await session.data(from: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let drinks = json["drinks"] as? [[String: Any]],
              let d = drinks.first else { return nil }

        guard let id    = d["idDrink"]     as? String,
              let name  = d["strDrink"]    as? String else { return nil }

        var ings: [String] = []; var meas: [String] = []
        for i in 1...15 {
            let ing = (d["strIngredient\(i)"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let mea = (d["strMeasure\(i)"]    as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !ing.isEmpty { ings.append(ing); meas.append(mea) }
        }

        return CocktailRecipe(
            id: id, name: name,
            category:     d["strCategory"]     as? String ?? "",
            alcoholic:    d["strAlcoholic"]    as? String ?? "",
            glass:        d["strGlass"]        as? String ?? "",
            instructions: d["strInstructions"] as? String ?? "",
            imageURL:     d["strDrinkThumb"]   as? String ?? "",
            ingredients: ings, measures: meas
        )
    }

    // Feed into KB (ingredients) and RecipeDatabase (recipe)
    private func ingest(_ cocktail: CocktailRecipe) async {
        // Register each ingredient into the knowledge base → powers predictive text.
        // Only this small model mutation belongs on MainActor; network parsing stays here.
        await MainActor.run {
            let kb = StockedKnowledgeBase.shared
            for ingredient in cocktail.ingredients {
                kb.learnFromInventoryItem(name: ingredient, category: "Beverages")
            }
        }

        // Build ingredient lines: "2 oz Vodka", "Splash Lime Juice"
        let ingLines = zip(cocktail.measures, cocktail.ingredients)
            .filter { !$1.isEmpty }
            .map { "\($0.trimmingCharacters(in: .whitespaces)) \($1.trimmingCharacters(in: .whitespaces))".trimmingCharacters(in: .whitespaces) }

        let steps = cocktail.instructions
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count > 5 }

        let entry = RecipeDatabaseEntry(
            title:       cocktail.name,
            description: "\(cocktail.alcoholic) · \(cocktail.glass)",
            sourceURL:   "",
            sourceName:  "TheCocktailDB",
            prepTime:    "5 min", cookTime: "", totalTime: "5 min",
            servings:    "1",
            category:    "Cocktail",
            cuisine:     "Other",
            tags:        ["Cocktail", cocktail.alcoholic, cocktail.category].filter { !$0.isEmpty },
            ingredients: ingLines,
            steps:       steps.isEmpty ? ["Combine all ingredients. Serve in a \(cocktail.glass)."] : steps,
            imageURL:    cocktail.imageURL,
            cachedAt:    Date()
        )

        await RecipeDatabase.shared.upsert(entry)
    }

    private func shouldSync() -> Bool {
        guard let last = UserDefaults.standard.object(forKey: syncKey) as? Date else { return true }
        return Date().timeIntervalSince(last) > 3600 * 12
    }
}
