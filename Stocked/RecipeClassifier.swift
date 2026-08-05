import Foundation

/// The one place a recipe's cuisine, category and styles are decided.
///
/// Everything that creates or imports a recipe calls `classify` and takes the answer.
/// Nothing else writes `cuisine`, `tags` or `mealCategory` from a raw source string.
nonisolated enum RecipeClassifier {

    struct Classification: Sendable {
        var cuisine: String
        var category: String
        var styles: [String]
        var tags: [String]
    }

    private struct TitleSignal: Sendable {
        let phrase: String
        let cuisine: String?
        let category: String?
        let styles: [String]
    }

    private struct IngredientSignal: Sendable {
        let phrase: String
        let cuisine: String?
        let category: String?
        let styles: [String]
    }

    static func classify(
        title: String,
        rawCuisine: String?,
        rawCategory: String?,
        keywords: [String],
        ingredients: [RecipeIngredient],
        instructions: [String]
    ) -> Classification {
        var cuisine = canonicalCuisine(rawCuisine)
        var category = canonicalCategory(rawCategory)
        var styles: [String] = []

        for keyword in keywords {
            if cuisine == nil {
                let hit = RecipeTaxonomy.canonicalCuisine(keyword)
                if hit != "Other" { cuisine = hit }
            }
            if category == nil {
                let hit = RecipeTaxonomy.canonicalCategory(keyword)
                if hit != "Other" { category = hit }
            }
            if let style = RecipeTaxonomy.canonicalStyle(keyword) {
                appendUnique(style, to: &styles)
            }
        }

        let foldedTitle = SearchNormalization.fold(title)
        for signal in titleSignals where foldedTitle.contains(signal.phrase) {
            if cuisine == nil, let hit = signal.cuisine { cuisine = hit }
            if category == nil, let hit = signal.category { category = hit }
            for style in signal.styles { appendUnique(style, to: &styles) }
            if cuisine != nil, category != nil { break }
        }

        let ingredientText = ingredients.map { SearchNormalization.fold($0.name) }.joined(separator: " ")
        for signal in ingredientSignals where ingredientText.contains(signal.phrase) {
            if cuisine == nil, let hit = signal.cuisine { cuisine = hit }
            if category == nil, let hit = signal.category { category = hit }
            for style in signal.styles { appendUnique(style, to: &styles) }
        }

        if cuisine == nil {
            if ingredientText.contains("fish sauce") && ingredientText.contains("lemongrass") { cuisine = "Thai" }
            else if ingredientText.contains("gochujang") { cuisine = "Korean" }
            else if ingredientText.contains("miso") || ingredientText.contains("dashi") { cuisine = "Japanese" }
            else if ingredientText.contains("masa") || ingredientText.contains("tomatillo") { cuisine = "Mexican" }
            else if ingredientText.contains("andouille") || ingredientText.contains("file powder") { cuisine = "Cajun & Creole" }
            else if ingredientText.contains("garam masala") { cuisine = "Indian" }
            else if ingredientText.contains("ricotta") || ingredientText.contains("pancetta") { cuisine = "Italian" }
            else if ingredientText.contains("harissa") || ingredientText.contains("tahini") { cuisine = "Middle Eastern" }
        }

        if category == nil {
            category = inferredCategory(title: foldedTitle, ingredients: ingredientText, instructions: instructions)
        }

        let finalCuisine = cuisine ?? "Other"
        let finalCategory = category ?? "Other"
        var tags: [String] = []
        appendUnique(finalCuisine, to: &tags)
        if let parent = RecipeTaxonomy.parentCuisine(finalCuisine) { appendUnique(parent, to: &tags) }
        appendUnique(finalCategory, to: &tags)
        for style in styles { appendUnique(style, to: &tags) }

        return Classification(cuisine: finalCuisine, category: finalCategory, styles: styles, tags: tags)
    }

    @MainActor
    static func backfillIfNeeded(store: GuestDataStore) {
        let flagKey = "didClassifyRecipes_v1"
        guard !UserDefaults.standard.bool(forKey: flagKey) else { return }
        let userRecipes = store.userRecipes
        let generatedRecipes = store.savedGeneratedRecipes

        Task.detached(priority: .background) {
            let validCuisines = Set(RecipeTaxonomy.cuisines)
            var changed = false

            let classifiedUsers = userRecipes.map { recipe in
                guard recipe.cuisine.isEmpty || !validCuisines.contains(recipe.cuisine) else { return recipe }
                let classification = classify(
                    title: recipe.title,
                    rawCuisine: recipe.cuisine,
                    rawCategory: nil,
                    keywords: recipe.tags,
                    ingredients: recipe.ingredients,
                    instructions: recipe.instructions
                )
                var updated = recipe
                updated.cuisine = classification.cuisine
                updated.tags = classification.tags
                changed = true
                return updated
            }

            let classifiedGenerated = generatedRecipes.map { recipe in
                guard recipe.cuisine.isEmpty || !validCuisines.contains(recipe.cuisine) else { return recipe }
                let classification = classify(
                    title: recipe.title,
                    rawCuisine: recipe.cuisine,
                    rawCategory: recipe.mealCategory,
                    keywords: [],
                    ingredients: recipe.ingredients.map { RecipeIngredient(name: $0.name, amount: $0.amount) },
                    instructions: recipe.steps
                )
                var updated = recipe
                updated.cuisine = classification.cuisine
                updated.mealCategory = classification.category
                changed = true
                return updated
            }

            await MainActor.run {
                if changed {
                    store.userRecipes = classifiedUsers
                    store.savedGeneratedRecipes = classifiedGenerated
                }
                UserDefaults.standard.set(true, forKey: flagKey)
            }
        }
    }

    private static func canonicalCuisine(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hit = RecipeTaxonomy.canonicalCuisine(raw)
        return hit == "Other" ? nil : hit
    }

    private static func canonicalCategory(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let hit = RecipeTaxonomy.canonicalCategory(raw)
        return hit == "Other" ? nil : hit
    }

    private static func appendUnique(_ value: String, to values: inout [String]) {
        guard !value.isEmpty else { return }
        let folded = SearchNormalization.fold(value)
        if !values.contains(where: { SearchNormalization.fold($0) == folded }) {
            values.append(value)
        }
    }

    private static func inferredCategory(title: String, ingredients: String, instructions: [String]) -> String {
        let instructionText = SearchNormalization.fold(instructions.joined(separator: " "))
        if title.contains("smoothie") || title.contains("juice") || title.contains("latte") { return "Beverage" }
        if title.contains("cocktail") || title.contains("margarita") || title.contains("martini") { return "Cocktail" }
        if title.contains("salad") || ingredients.contains("lettuce") || ingredients.contains("arugula") { return "Salad" }
        if title.contains("sandwich") || title.contains("burger") || title.contains("wrap") { return "Sandwich" }
        if title.contains("soup") || title.contains("stew") || title.contains("chowder") { return "Soup" }
        if ingredients.contains("broth") && (ingredients.contains("cup") || ingredients.contains("stock")) { return "Soup" }
        if ingredients.contains("chicken") || ingredients.contains("turkey") { return "Chicken" }
        if ingredients.contains("beef") || ingredients.contains("steak") || ingredients.contains("brisket") { return "Beef" }
        if ingredients.contains("pork") || ingredients.contains("bacon") || ingredients.contains("ham") { return "Pork" }
        if ingredients.contains("salmon") || ingredients.contains("shrimp") || ingredients.contains("cod") || ingredients.contains("tuna") { return "Seafood" }
        if (ingredients.contains("sugar") && ingredients.contains("flour") && instructionText.contains("bake")) && !hasSavoryProtein(ingredients) { return "Dessert" }
        return "Other"
    }

    private static func hasSavoryProtein(_ ingredients: String) -> Bool {
        ["chicken", "beef", "pork", "salmon", "shrimp", "turkey", "sausage", "bacon"].contains { ingredients.contains($0) }
    }

    private static let titleSignals: [TitleSignal] = [
        TitleSignal(phrase: "shrimp and grits", cuisine: "Southern", category: "Seafood", styles: ["Comfort"]),
        TitleSignal(phrase: "chicken pot pie", cuisine: "American", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "pot pie", cuisine: "American", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "pad thai", cuisine: "Thai", category: "Pasta", styles: []),
        TitleSignal(phrase: "beef bourguignon", cuisine: "French", category: "Beef", styles: ["Comfort"]),
        TitleSignal(phrase: "tikka masala", cuisine: "Indian", category: "Chicken", styles: []),
        TitleSignal(phrase: "peach cobbler", cuisine: "Southern", category: "Dessert", styles: ["Comfort"]),
        TitleSignal(phrase: "cobbler", cuisine: "American", category: "Dessert", styles: ["Comfort"]),
        TitleSignal(phrase: "miso glazed salmon", cuisine: "Japanese", category: "Seafood", styles: []),
        TitleSignal(phrase: "texas brisket", cuisine: "BBQ", category: "Beef", styles: ["Grilled"]),
        TitleSignal(phrase: "green bean casserole", cuisine: "American", category: "Side", styles: ["Holiday"]),
        TitleSignal(phrase: "overnight oats", cuisine: "American", category: "Breakfast", styles: ["Meal-Prep"]),
        TitleSignal(phrase: "gumbo", cuisine: "Cajun & Creole", category: "Soup", styles: ["Comfort"]),
        TitleSignal(phrase: "jambalaya", cuisine: "Cajun & Creole", category: "Dinner", styles: ["One-Pot"]),
        TitleSignal(phrase: "etouffee", cuisine: "Cajun & Creole", category: "Seafood", styles: ["Comfort"]),
        TitleSignal(phrase: "red beans and rice", cuisine: "Cajun & Creole", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "po boy", cuisine: "Cajun & Creole", category: "Sandwich", styles: []),
        TitleSignal(phrase: "beignet", cuisine: "Cajun & Creole", category: "Dessert", styles: []),
        TitleSignal(phrase: "dirty rice", cuisine: "Cajun & Creole", category: "Side", styles: []),
        TitleSignal(phrase: "hush puppies", cuisine: "Southern", category: "Side", styles: []),
        TitleSignal(phrase: "fried chicken", cuisine: "Southern", category: "Chicken", styles: ["Comfort"]),
        TitleSignal(phrase: "biscuits and gravy", cuisine: "Southern", category: "Breakfast", styles: ["Comfort"]),
        TitleSignal(phrase: "collard greens", cuisine: "Southern", category: "Side", styles: []),
        TitleSignal(phrase: "chicken fried steak", cuisine: "Southern", category: "Beef", styles: ["Comfort"]),
        TitleSignal(phrase: "banana pudding", cuisine: "Southern", category: "Dessert", styles: []),
        TitleSignal(phrase: "pecan pie", cuisine: "Southern", category: "Dessert", styles: ["Holiday"]),
        TitleSignal(phrase: "cornbread", cuisine: "Southern", category: "Bread", styles: []),
        TitleSignal(phrase: "pulled pork", cuisine: "BBQ", category: "Pork", styles: ["Grilled"]),
        TitleSignal(phrase: "burnt ends", cuisine: "BBQ", category: "Beef", styles: ["Grilled"]),
        TitleSignal(phrase: "baby back ribs", cuisine: "BBQ", category: "Pork", styles: ["Grilled"]),
        TitleSignal(phrase: "smoked ribs", cuisine: "BBQ", category: "Pork", styles: ["Grilled"]),
        TitleSignal(phrase: "barbecue chicken", cuisine: "BBQ", category: "Chicken", styles: ["Grilled"]),
        TitleSignal(phrase: "bbq chicken", cuisine: "BBQ", category: "Chicken", styles: ["Grilled"]),
        TitleSignal(phrase: "clam chowder", cuisine: "New England", category: "Soup", styles: ["Comfort"]),
        TitleSignal(phrase: "lobster roll", cuisine: "New England", category: "Sandwich", styles: []),
        TitleSignal(phrase: "boston baked beans", cuisine: "New England", category: "Side", styles: []),
        TitleSignal(phrase: "tex mex", cuisine: "Tex-Mex", category: "Dinner", styles: []),
        TitleSignal(phrase: "fajitas", cuisine: "Tex-Mex", category: "Dinner", styles: ["Quick"]),
        TitleSignal(phrase: "nachos", cuisine: "Tex-Mex", category: "Appetizer", styles: ["Party"]),
        TitleSignal(phrase: "queso", cuisine: "Tex-Mex", category: "Appetizer", styles: ["Party"]),
        TitleSignal(phrase: "chili con carne", cuisine: "Tex-Mex", category: "Beef", styles: ["Comfort"]),
        TitleSignal(phrase: "breakfast burrito", cuisine: "Tex-Mex", category: "Breakfast", styles: []),
        TitleSignal(phrase: "enchiladas", cuisine: "Mexican", category: "Dinner", styles: []),
        TitleSignal(phrase: "tacos", cuisine: "Mexican", category: "Dinner", styles: ["Quick"]),
        TitleSignal(phrase: "taco", cuisine: "Mexican", category: "Dinner", styles: ["Quick"]),
        TitleSignal(phrase: "tamales", cuisine: "Mexican", category: "Dinner", styles: ["Holiday"]),
        TitleSignal(phrase: "pozole", cuisine: "Mexican", category: "Soup", styles: ["Comfort"]),
        TitleSignal(phrase: "mole", cuisine: "Mexican", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "chilaquiles", cuisine: "Mexican", category: "Breakfast", styles: []),
        TitleSignal(phrase: "elote", cuisine: "Mexican", category: "Side", styles: []),
        TitleSignal(phrase: "guacamole", cuisine: "Mexican", category: "Appetizer", styles: ["Party"]),
        TitleSignal(phrase: "salsa verde", cuisine: "Mexican", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "ceviche", cuisine: "Latin American", category: "Seafood", styles: []),
        TitleSignal(phrase: "empanadas", cuisine: "Latin American", category: "Appetizer", styles: []),
        TitleSignal(phrase: "arepas", cuisine: "Latin American", category: "Bread", styles: []),
        TitleSignal(phrase: "ropa vieja", cuisine: "Caribbean", category: "Beef", styles: ["Comfort"]),
        TitleSignal(phrase: "jerk chicken", cuisine: "Caribbean", category: "Chicken", styles: ["Grilled"]),
        TitleSignal(phrase: "rice and peas", cuisine: "Caribbean", category: "Side", styles: []),
        TitleSignal(phrase: "plantains", cuisine: "Caribbean", category: "Side", styles: []),
        TitleSignal(phrase: "carbonara", cuisine: "Italian", category: "Pasta", styles: []),
        TitleSignal(phrase: "bolognese", cuisine: "Italian", category: "Pasta", styles: ["Comfort"]),
        TitleSignal(phrase: "lasagna", cuisine: "Italian", category: "Pasta", styles: ["Comfort"]),
        TitleSignal(phrase: "risotto", cuisine: "Italian", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "gnocchi", cuisine: "Italian", category: "Pasta", styles: []),
        TitleSignal(phrase: "cacio e pepe", cuisine: "Italian", category: "Pasta", styles: ["Quick"]),
        TitleSignal(phrase: "fettuccine alfredo", cuisine: "Italian", category: "Pasta", styles: ["Comfort"]),
        TitleSignal(phrase: "minestrone", cuisine: "Italian", category: "Soup", styles: []),
        TitleSignal(phrase: "bruschetta", cuisine: "Italian", category: "Appetizer", styles: []),
        TitleSignal(phrase: "caprese", cuisine: "Italian", category: "Salad", styles: []),
        TitleSignal(phrase: "tiramisu", cuisine: "Italian", category: "Dessert", styles: []),
        TitleSignal(phrase: "panna cotta", cuisine: "Italian", category: "Dessert", styles: []),
        TitleSignal(phrase: "margherita pizza", cuisine: "Italian", category: "Dinner", styles: []),
        TitleSignal(phrase: "pizza", cuisine: "Italian", category: "Dinner", styles: ["Party"]),
        TitleSignal(phrase: "pesto", cuisine: "Italian", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "ratatouille", cuisine: "French", category: "Vegetarian", styles: []),
        TitleSignal(phrase: "coq au vin", cuisine: "French", category: "Chicken", styles: ["Comfort"]),
        TitleSignal(phrase: "quiche", cuisine: "French", category: "Brunch", styles: []),
        TitleSignal(phrase: "croque monsieur", cuisine: "French", category: "Sandwich", styles: []),
        TitleSignal(phrase: "nicoise", cuisine: "French", category: "Salad", styles: []),
        TitleSignal(phrase: "bouillabaisse", cuisine: "French", category: "Seafood", styles: []),
        TitleSignal(phrase: "cassoulet", cuisine: "French", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "creme brulee", cuisine: "French", category: "Dessert", styles: []),
        TitleSignal(phrase: "profiteroles", cuisine: "French", category: "Dessert", styles: []),
        TitleSignal(phrase: "crepes", cuisine: "French", category: "Breakfast", styles: []),
        TitleSignal(phrase: "paella", cuisine: "Spanish", category: "Seafood", styles: ["One-Pot"]),
        TitleSignal(phrase: "gazpacho", cuisine: "Spanish", category: "Soup", styles: []),
        TitleSignal(phrase: "tortilla espanola", cuisine: "Spanish", category: "Breakfast", styles: []),
        TitleSignal(phrase: "patatas bravas", cuisine: "Spanish", category: "Side", styles: []),
        TitleSignal(phrase: "churros", cuisine: "Spanish", category: "Dessert", styles: []),
        TitleSignal(phrase: "tapas", cuisine: "Spanish", category: "Appetizer", styles: ["Party"]),
        TitleSignal(phrase: "gyro", cuisine: "Greek", category: "Sandwich", styles: []),
        TitleSignal(phrase: "souvlaki", cuisine: "Greek", category: "Dinner", styles: ["Grilled"]),
        TitleSignal(phrase: "moussaka", cuisine: "Greek", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "spanakopita", cuisine: "Greek", category: "Appetizer", styles: []),
        TitleSignal(phrase: "tzatziki", cuisine: "Greek", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "greek salad", cuisine: "Greek", category: "Salad", styles: []),
        TitleSignal(phrase: "baklava", cuisine: "Middle Eastern", category: "Dessert", styles: ["Holiday"]),
        TitleSignal(phrase: "falafel", cuisine: "Middle Eastern", category: "Vegetarian", styles: []),
        TitleSignal(phrase: "hummus", cuisine: "Middle Eastern", category: "Appetizer", styles: []),
        TitleSignal(phrase: "shawarma", cuisine: "Middle Eastern", category: "Sandwich", styles: []),
        TitleSignal(phrase: "kebab", cuisine: "Middle Eastern", category: "Dinner", styles: ["Grilled"]),
        TitleSignal(phrase: "tabbouleh", cuisine: "Middle Eastern", category: "Salad", styles: []),
        TitleSignal(phrase: "baba ganoush", cuisine: "Middle Eastern", category: "Appetizer", styles: []),
        TitleSignal(phrase: "shakshuka", cuisine: "Middle Eastern", category: "Breakfast", styles: ["One-Pot"]),
        TitleSignal(phrase: "tagine", cuisine: "Moroccan", category: "Dinner", styles: ["One-Pot"]),
        TitleSignal(phrase: "couscous", cuisine: "Moroccan", category: "Side", styles: []),
        TitleSignal(phrase: "harira", cuisine: "Moroccan", category: "Soup", styles: []),
        TitleSignal(phrase: "biryani", cuisine: "Indian", category: "Dinner", styles: ["One-Pot"]),
        TitleSignal(phrase: "butter chicken", cuisine: "Indian", category: "Chicken", styles: ["Comfort"]),
        TitleSignal(phrase: "chana masala", cuisine: "Indian", category: "Vegetarian", styles: []),
        TitleSignal(phrase: "palak paneer", cuisine: "Indian", category: "Vegetarian", styles: []),
        TitleSignal(phrase: "saag paneer", cuisine: "Indian", category: "Vegetarian", styles: []),
        TitleSignal(phrase: "dal", cuisine: "Indian", category: "Soup", styles: ["Comfort"]),
        TitleSignal(phrase: "samosa", cuisine: "Indian", category: "Appetizer", styles: []),
        TitleSignal(phrase: "naan", cuisine: "Indian", category: "Bread", styles: []),
        TitleSignal(phrase: "vindaloo", cuisine: "Indian", category: "Dinner", styles: []),
        TitleSignal(phrase: "korma", cuisine: "Indian", category: "Dinner", styles: []),
        TitleSignal(phrase: "rogan josh", cuisine: "Indian", category: "Dinner", styles: []),
        TitleSignal(phrase: "pakora", cuisine: "Indian", category: "Appetizer", styles: []),
        TitleSignal(phrase: "mango lassi", cuisine: "Indian", category: "Beverage", styles: []),
        TitleSignal(phrase: "tom yum", cuisine: "Thai", category: "Soup", styles: []),
        TitleSignal(phrase: "tom kha", cuisine: "Thai", category: "Soup", styles: []),
        TitleSignal(phrase: "green curry", cuisine: "Thai", category: "Dinner", styles: []),
        TitleSignal(phrase: "red curry", cuisine: "Thai", category: "Dinner", styles: []),
        TitleSignal(phrase: "massaman", cuisine: "Thai", category: "Dinner", styles: []),
        TitleSignal(phrase: "pad see ew", cuisine: "Thai", category: "Pasta", styles: []),
        TitleSignal(phrase: "drunken noodles", cuisine: "Thai", category: "Pasta", styles: []),
        TitleSignal(phrase: "larb", cuisine: "Thai", category: "Salad", styles: []),
        TitleSignal(phrase: "som tam", cuisine: "Thai", category: "Salad", styles: []),
        TitleSignal(phrase: "mango sticky rice", cuisine: "Thai", category: "Dessert", styles: []),
        TitleSignal(phrase: "pho", cuisine: "Vietnamese", category: "Soup", styles: []),
        TitleSignal(phrase: "banh mi", cuisine: "Vietnamese", category: "Sandwich", styles: []),
        TitleSignal(phrase: "bun cha", cuisine: "Vietnamese", category: "Dinner", styles: []),
        TitleSignal(phrase: "goi cuon", cuisine: "Vietnamese", category: "Appetizer", styles: []),
        TitleSignal(phrase: "spring rolls", cuisine: "Vietnamese", category: "Appetizer", styles: []),
        TitleSignal(phrase: "com tam", cuisine: "Vietnamese", category: "Dinner", styles: []),
        TitleSignal(phrase: "adobo", cuisine: "Filipino", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "pancit", cuisine: "Filipino", category: "Pasta", styles: []),
        TitleSignal(phrase: "lumpia", cuisine: "Filipino", category: "Appetizer", styles: ["Party"]),
        TitleSignal(phrase: "sinigang", cuisine: "Filipino", category: "Soup", styles: []),
        TitleSignal(phrase: "lechon", cuisine: "Filipino", category: "Pork", styles: ["Party"]),
        TitleSignal(phrase: "halo halo", cuisine: "Filipino", category: "Dessert", styles: []),
        TitleSignal(phrase: "fried rice", cuisine: "Chinese", category: "Dinner", styles: ["Quick"]),
        TitleSignal(phrase: "lo mein", cuisine: "Chinese", category: "Pasta", styles: ["Quick"]),
        TitleSignal(phrase: "chow mein", cuisine: "Chinese", category: "Pasta", styles: ["Quick"]),
        TitleSignal(phrase: "kung pao", cuisine: "Chinese", category: "Chicken", styles: []),
        TitleSignal(phrase: "mapo tofu", cuisine: "Chinese", category: "Vegetarian", styles: []),
        TitleSignal(phrase: "dan dan", cuisine: "Chinese", category: "Pasta", styles: []),
        TitleSignal(phrase: "hot and sour soup", cuisine: "Chinese", category: "Soup", styles: []),
        TitleSignal(phrase: "wonton soup", cuisine: "Chinese", category: "Soup", styles: []),
        TitleSignal(phrase: "dumplings", cuisine: "Chinese", category: "Appetizer", styles: ["Party"]),
        TitleSignal(phrase: "egg rolls", cuisine: "Chinese", category: "Appetizer", styles: []),
        TitleSignal(phrase: "char siu", cuisine: "Chinese", category: "Pork", styles: []),
        TitleSignal(phrase: "peking duck", cuisine: "Chinese", category: "Dinner", styles: []),
        TitleSignal(phrase: "sushi", cuisine: "Japanese", category: "Seafood", styles: []),
        TitleSignal(phrase: "ramen", cuisine: "Japanese", category: "Soup", styles: ["Comfort"]),
        TitleSignal(phrase: "udon", cuisine: "Japanese", category: "Pasta", styles: []),
        TitleSignal(phrase: "soba", cuisine: "Japanese", category: "Pasta", styles: []),
        TitleSignal(phrase: "teriyaki", cuisine: "Japanese", category: "Dinner", styles: []),
        TitleSignal(phrase: "katsu", cuisine: "Japanese", category: "Pork", styles: []),
        TitleSignal(phrase: "tonkatsu", cuisine: "Japanese", category: "Pork", styles: []),
        TitleSignal(phrase: "okonomiyaki", cuisine: "Japanese", category: "Dinner", styles: []),
        TitleSignal(phrase: "yakitori", cuisine: "Japanese", category: "Chicken", styles: ["Grilled"]),
        TitleSignal(phrase: "onigiri", cuisine: "Japanese", category: "Snack", styles: []),
        TitleSignal(phrase: "tempura", cuisine: "Japanese", category: "Dinner", styles: []),
        TitleSignal(phrase: "bibimbap", cuisine: "Korean", category: "Dinner", styles: []),
        TitleSignal(phrase: "bulgogi", cuisine: "Korean", category: "Beef", styles: ["Grilled"]),
        TitleSignal(phrase: "kimchi stew", cuisine: "Korean", category: "Soup", styles: ["Comfort"]),
        TitleSignal(phrase: "kimchi", cuisine: "Korean", category: "Side", styles: []),
        TitleSignal(phrase: "japchae", cuisine: "Korean", category: "Pasta", styles: []),
        TitleSignal(phrase: "tteokbokki", cuisine: "Korean", category: "Snack", styles: []),
        TitleSignal(phrase: "galbi", cuisine: "Korean", category: "Beef", styles: ["Grilled"]),
        TitleSignal(phrase: "korean fried chicken", cuisine: "Korean", category: "Chicken", styles: ["Party"]),
        TitleSignal(phrase: "bangers and mash", cuisine: "British", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "shepherds pie", cuisine: "British", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "fish and chips", cuisine: "British", category: "Seafood", styles: ["Comfort"]),
        TitleSignal(phrase: "toad in the hole", cuisine: "British", category: "Dinner", styles: []),
        TitleSignal(phrase: "scones", cuisine: "British", category: "Baked Goods", styles: []),
        TitleSignal(phrase: "irish stew", cuisine: "Irish", category: "Soup", styles: ["Comfort"]),
        TitleSignal(phrase: "soda bread", cuisine: "Irish", category: "Bread", styles: []),
        TitleSignal(phrase: "colcannon", cuisine: "Irish", category: "Side", styles: []),
        TitleSignal(phrase: "schnitzel", cuisine: "German", category: "Pork", styles: []),
        TitleSignal(phrase: "spaetzle", cuisine: "German", category: "Pasta", styles: []),
        TitleSignal(phrase: "bratwurst", cuisine: "German", category: "Pork", styles: ["Grilled"]),
        TitleSignal(phrase: "sauerbraten", cuisine: "German", category: "Beef", styles: ["Comfort"]),
        TitleSignal(phrase: "pierogi", cuisine: "Eastern European", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "borscht", cuisine: "Eastern European", category: "Soup", styles: []),
        TitleSignal(phrase: "goulash", cuisine: "Eastern European", category: "Beef", styles: ["Comfort"]),
        TitleSignal(phrase: "cabbage rolls", cuisine: "Eastern European", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "shakshouka", cuisine: "Middle Eastern", category: "Breakfast", styles: ["One-Pot"]),
        TitleSignal(phrase: "jollof", cuisine: "African", category: "Dinner", styles: ["One-Pot"]),
        TitleSignal(phrase: "injera", cuisine: "African", category: "Bread", styles: []),
        TitleSignal(phrase: "doro wat", cuisine: "African", category: "Chicken", styles: ["Comfort"]),
        TitleSignal(phrase: "berbere", cuisine: "African", category: "Dinner", styles: []),
        TitleSignal(phrase: "feijoada", cuisine: "Brazilian", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "pao de queijo", cuisine: "Brazilian", category: "Bread", styles: []),
        TitleSignal(phrase: "brigadeiro", cuisine: "Brazilian", category: "Dessert", styles: []),
        TitleSignal(phrase: "poke", cuisine: "Hawaiian", category: "Seafood", styles: ["Healthy"]),
        TitleSignal(phrase: "loco moco", cuisine: "Hawaiian", category: "Beef", styles: ["Comfort"]),
        TitleSignal(phrase: "kalua pork", cuisine: "Hawaiian", category: "Pork", styles: []),
        TitleSignal(phrase: "mac and cheese", cuisine: "American", category: "Pasta", styles: ["Comfort"]),
        TitleSignal(phrase: "meatloaf", cuisine: "American", category: "Beef", styles: ["Comfort"]),
        TitleSignal(phrase: "hamburger", cuisine: "American", category: "Sandwich", styles: ["Quick"]),
        TitleSignal(phrase: "cheeseburger", cuisine: "American", category: "Sandwich", styles: ["Quick"]),
        TitleSignal(phrase: "hot dog", cuisine: "American", category: "Sandwich", styles: ["Quick"]),
        TitleSignal(phrase: "sloppy joe", cuisine: "American", category: "Sandwich", styles: ["Comfort"]),
        TitleSignal(phrase: "tuna melt", cuisine: "American", category: "Sandwich", styles: ["Quick"]),
        TitleSignal(phrase: "cobb salad", cuisine: "American", category: "Salad", styles: []),
        TitleSignal(phrase: "waldorf salad", cuisine: "American", category: "Salad", styles: []),
        TitleSignal(phrase: "caesar salad", cuisine: "American", category: "Salad", styles: []),
        TitleSignal(phrase: "deviled eggs", cuisine: "American", category: "Appetizer", styles: ["Party"]),
        TitleSignal(phrase: "buffalo wings", cuisine: "American", category: "Chicken", styles: ["Party"]),
        TitleSignal(phrase: "chicken noodle soup", cuisine: "American", category: "Soup", styles: ["Comfort"]),
        TitleSignal(phrase: "tomato soup", cuisine: "American", category: "Soup", styles: ["Comfort"]),
        TitleSignal(phrase: "grilled cheese", cuisine: "American", category: "Sandwich", styles: ["Comfort"]),
        TitleSignal(phrase: "pancakes", cuisine: "American", category: "Breakfast", styles: []),
        TitleSignal(phrase: "waffles", cuisine: "American", category: "Breakfast", styles: []),
        TitleSignal(phrase: "french toast", cuisine: "American", category: "Breakfast", styles: []),
        TitleSignal(phrase: "eggs benedict", cuisine: "American", category: "Brunch", styles: []),
        TitleSignal(phrase: "breakfast casserole", cuisine: "American", category: "Breakfast", styles: ["Meal-Prep"]),
        TitleSignal(phrase: "granola", cuisine: "American", category: "Breakfast", styles: ["Meal-Prep"]),
        TitleSignal(phrase: "apple pie", cuisine: "American", category: "Dessert", styles: ["Holiday"]),
        TitleSignal(phrase: "pumpkin pie", cuisine: "American", category: "Dessert", styles: ["Holiday"]),
        TitleSignal(phrase: "brownies", cuisine: "American", category: "Dessert", styles: []),
        TitleSignal(phrase: "chocolate chip cookies", cuisine: "American", category: "Dessert", styles: []),
        TitleSignal(phrase: "cheesecake", cuisine: "American", category: "Dessert", styles: []),
        TitleSignal(phrase: "cupcakes", cuisine: "American", category: "Dessert", styles: ["Party"]),
        TitleSignal(phrase: "banana bread", cuisine: "American", category: "Bread", styles: []),
        TitleSignal(phrase: "zucchini bread", cuisine: "American", category: "Bread", styles: []),
        TitleSignal(phrase: "meatballs", cuisine: "Italian", category: "Beef", styles: ["Comfort"]),
        TitleSignal(phrase: "pasta primavera", cuisine: "Italian", category: "Pasta", styles: []),
        TitleSignal(phrase: "macaroni salad", cuisine: "American", category: "Salad", styles: ["Party"]),
        TitleSignal(phrase: "potato salad", cuisine: "American", category: "Side", styles: ["Party"]),
        TitleSignal(phrase: "coleslaw", cuisine: "American", category: "Side", styles: []),
        TitleSignal(phrase: "stuffing", cuisine: "American", category: "Side", styles: ["Holiday"]),
        TitleSignal(phrase: "cranberry sauce", cuisine: "American", category: "Sauce & Condiment", styles: ["Holiday"]),
        TitleSignal(phrase: "gravy", cuisine: "American", category: "Sauce & Condiment", styles: ["Holiday"]),
        TitleSignal(phrase: "roast turkey", cuisine: "American", category: "Dinner", styles: ["Holiday"]),
        TitleSignal(phrase: "prime rib", cuisine: "American", category: "Beef", styles: ["Holiday"]),
        TitleSignal(phrase: "salmon cakes", cuisine: "American", category: "Seafood", styles: []),
        TitleSignal(phrase: "crab cakes", cuisine: "American", category: "Seafood", styles: []),
        TitleSignal(phrase: "clam bake", cuisine: "New England", category: "Seafood", styles: ["Party"]),
        TitleSignal(phrase: "lobster mac", cuisine: "New England", category: "Pasta", styles: ["Comfort"]),
        TitleSignal(phrase: "chicken parmesan", cuisine: "Italian", category: "Chicken", styles: ["Comfort"]),
        TitleSignal(phrase: "eggplant parmesan", cuisine: "Italian", category: "Vegetarian", styles: ["Comfort"]),
        TitleSignal(phrase: "chicken marsala", cuisine: "Italian", category: "Chicken", styles: []),
        TitleSignal(phrase: "osso buco", cuisine: "Italian", category: "Beef", styles: ["Comfort"]),
        TitleSignal(phrase: "cioppino", cuisine: "Italian", category: "Seafood", styles: []),
        TitleSignal(phrase: "banh xeo", cuisine: "Vietnamese", category: "Dinner", styles: []),
        TitleSignal(phrase: "satay", cuisine: "Thai", category: "Appetizer", styles: ["Grilled"]),
        TitleSignal(phrase: "laksa", cuisine: "Fusion", category: "Soup", styles: []),
        TitleSignal(phrase: "curry", cuisine: "Indian", category: "Dinner", styles: []),
        TitleSignal(phrase: "noodle bowl", cuisine: "Fusion", category: "Pasta", styles: ["Quick"]),
        TitleSignal(phrase: "grain bowl", cuisine: "Fusion", category: "Vegetarian", styles: ["Healthy"]),
        TitleSignal(phrase: "buddha bowl", cuisine: "Fusion", category: "Vegan", styles: ["Healthy"]),
        TitleSignal(phrase: "smoothie bowl", cuisine: "American", category: "Breakfast", styles: ["Healthy"]),
        TitleSignal(phrase: "acai bowl", cuisine: "Brazilian", category: "Breakfast", styles: ["Healthy"]),
        TitleSignal(phrase: "avocado toast", cuisine: "American", category: "Breakfast", styles: ["Quick"]),
        TitleSignal(phrase: "veggie burger", cuisine: "American", category: "Vegetarian", styles: []),
        TitleSignal(phrase: "lentil soup", cuisine: "Mediterranean", category: "Soup", styles: ["Healthy"]),
        TitleSignal(phrase: "greek bowl", cuisine: "Greek", category: "Dinner", styles: ["Healthy"]),
        TitleSignal(phrase: "tuna salad", cuisine: "American", category: "Salad", styles: ["Quick"]),
        TitleSignal(phrase: "chicken salad", cuisine: "American", category: "Salad", styles: ["Quick"]),
        TitleSignal(phrase: "pasta salad", cuisine: "American", category: "Pasta", styles: ["Party"]),
        TitleSignal(phrase: "bean chili", cuisine: "American", category: "Vegetarian", styles: ["Comfort"]),
        TitleSignal(phrase: "white chicken chili", cuisine: "Tex-Mex", category: "Chicken", styles: ["Comfort"]),
        TitleSignal(phrase: "turkey chili", cuisine: "American", category: "Dinner", styles: ["Comfort"]),
        TitleSignal(phrase: "beef stew", cuisine: "American", category: "Beef", styles: ["Comfort"]),
        TitleSignal(phrase: "pot roast", cuisine: "American", category: "Beef", styles: ["Comfort", "Slow-Cooker"]),
        TitleSignal(phrase: "roast chicken", cuisine: "American", category: "Chicken", styles: ["Baked"]),
        TitleSignal(phrase: "chicken casserole", cuisine: "American", category: "Chicken", styles: ["Comfort", "Baked"]),
        TitleSignal(phrase: "tuna casserole", cuisine: "American", category: "Seafood", styles: ["Comfort", "Baked"]),
        TitleSignal(phrase: "breakfast tacos", cuisine: "Tex-Mex", category: "Breakfast", styles: ["Quick"]),
        TitleSignal(phrase: "huevos rancheros", cuisine: "Mexican", category: "Breakfast", styles: []),
        TitleSignal(phrase: "frittata", cuisine: "Italian", category: "Breakfast", styles: []),
        TitleSignal(phrase: "omelet", cuisine: "French", category: "Breakfast", styles: ["Quick"]),
        TitleSignal(phrase: "omelette", cuisine: "French", category: "Breakfast", styles: ["Quick"]),
        TitleSignal(phrase: "muffins", cuisine: "American", category: "Baked Goods", styles: []),
        TitleSignal(phrase: "scones", cuisine: "British", category: "Baked Goods", styles: []),
        TitleSignal(phrase: "quick bread", cuisine: "American", category: "Bread", styles: ["Quick"]),
        TitleSignal(phrase: "sourdough", cuisine: "American", category: "Bread", styles: []),
        TitleSignal(phrase: "focaccia", cuisine: "Italian", category: "Bread", styles: []),
        TitleSignal(phrase: "baguette", cuisine: "French", category: "Bread", styles: []),
        TitleSignal(phrase: "pita", cuisine: "Middle Eastern", category: "Bread", styles: []),
        TitleSignal(phrase: "tortillas", cuisine: "Mexican", category: "Bread", styles: []),
        TitleSignal(phrase: "sangria", cuisine: "Spanish", category: "Cocktail", styles: ["Party"]),
        TitleSignal(phrase: "margarita", cuisine: "Mexican", category: "Cocktail", styles: ["Party"]),
        TitleSignal(phrase: "mojito", cuisine: "Caribbean", category: "Cocktail", styles: ["Party"]),
        TitleSignal(phrase: "mai tai", cuisine: "Hawaiian", category: "Cocktail", styles: ["Party"]),
        TitleSignal(phrase: "smoothie", cuisine: "American", category: "Beverage", styles: ["Healthy"]),
        TitleSignal(phrase: "lemonade", cuisine: "American", category: "Beverage", styles: []),
        TitleSignal(phrase: "iced tea", cuisine: "Southern", category: "Beverage", styles: []),
        TitleSignal(phrase: "hot chocolate", cuisine: "American", category: "Beverage", styles: ["Kid-Friendly"]),
        TitleSignal(phrase: "apple crisp", cuisine: "American", category: "Dessert", styles: ["Baked"]),
        TitleSignal(phrase: "fruit crumble", cuisine: "British", category: "Dessert", styles: ["Baked"]),
        TitleSignal(phrase: "bread pudding", cuisine: "Southern", category: "Dessert", styles: ["Comfort"]),
        TitleSignal(phrase: "rice pudding", cuisine: "British", category: "Dessert", styles: ["Comfort"]),
        TitleSignal(phrase: "flan", cuisine: "Latin American", category: "Dessert", styles: []),
        TitleSignal(phrase: "tres leches", cuisine: "Latin American", category: "Dessert", styles: []),
        TitleSignal(phrase: "dulce de leche", cuisine: "Latin American", category: "Dessert", styles: []),
        TitleSignal(phrase: "chicken satay", cuisine: "Thai", category: "Chicken", styles: ["Grilled"]),
        TitleSignal(phrase: "beef tacos", cuisine: "Mexican", category: "Beef", styles: ["Quick"]),
        TitleSignal(phrase: "fish tacos", cuisine: "Mexican", category: "Seafood", styles: ["Quick"]),
        TitleSignal(phrase: "carnitas", cuisine: "Mexican", category: "Pork", styles: []),
        TitleSignal(phrase: "al pastor", cuisine: "Mexican", category: "Pork", styles: []),
        TitleSignal(phrase: "carne asada", cuisine: "Mexican", category: "Beef", styles: ["Grilled"]),
        TitleSignal(phrase: "chicken shawarma", cuisine: "Middle Eastern", category: "Chicken", styles: []),
        TitleSignal(phrase: "beef kebab", cuisine: "Middle Eastern", category: "Beef", styles: ["Grilled"]),
        TitleSignal(phrase: "salmon teriyaki", cuisine: "Japanese", category: "Seafood", styles: []),
        TitleSignal(phrase: "chicken teriyaki", cuisine: "Japanese", category: "Chicken", styles: []),
        TitleSignal(phrase: "orange chicken", cuisine: "Chinese", category: "Chicken", styles: []),
        TitleSignal(phrase: "sesame chicken", cuisine: "Chinese", category: "Chicken", styles: []),
        TitleSignal(phrase: "mongolian beef", cuisine: "Chinese", category: "Beef", styles: []),
        TitleSignal(phrase: "beef and broccoli", cuisine: "Chinese", category: "Beef", styles: ["Quick"]),
        TitleSignal(phrase: "egg drop soup", cuisine: "Chinese", category: "Soup", styles: ["Quick"]),
        TitleSignal(phrase: "miso soup", cuisine: "Japanese", category: "Soup", styles: ["Quick"]),
        TitleSignal(phrase: "clam sauce", cuisine: "Italian", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "alfredo", cuisine: "Italian", category: "Sauce & Condiment", styles: ["Comfort"]),
        TitleSignal(phrase: "marinara", cuisine: "Italian", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "chimichurri", cuisine: "Latin American", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "tzatziki sauce", cuisine: "Greek", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "peanut sauce", cuisine: "Thai", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "aioli", cuisine: "Mediterranean", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "ranch dressing", cuisine: "American", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "vinaigrette", cuisine: "French", category: "Sauce & Condiment", styles: []),
        TitleSignal(phrase: "pesto pasta", cuisine: "Italian", category: "Pasta", styles: ["Quick"]),
        TitleSignal(phrase: "spaghetti", cuisine: "Italian", category: "Pasta", styles: []),
        TitleSignal(phrase: "linguine", cuisine: "Italian", category: "Pasta", styles: []),
        TitleSignal(phrase: "ravioli", cuisine: "Italian", category: "Pasta", styles: []),
        TitleSignal(phrase: "tortellini", cuisine: "Italian", category: "Pasta", styles: []),
        TitleSignal(phrase: "chicken noodle", cuisine: "American", category: "Soup", styles: ["Comfort"]),
        TitleSignal(phrase: "split pea soup", cuisine: "American", category: "Soup", styles: ["Comfort"]),
        TitleSignal(phrase: "black bean soup", cuisine: "Latin American", category: "Soup", styles: ["Healthy"]),
        TitleSignal(phrase: "minestrone soup", cuisine: "Italian", category: "Soup", styles: ["Healthy"]),
        TitleSignal(phrase: "lentil stew", cuisine: "Mediterranean", category: "Soup", styles: ["Healthy"])
    ]

    private static let ingredientSignals: [IngredientSignal] = [
        IngredientSignal(phrase: "gochujang", cuisine: "Korean", category: nil, styles: []),
        IngredientSignal(phrase: "kimchi", cuisine: "Korean", category: "Side", styles: []),
        IngredientSignal(phrase: "doenjang", cuisine: "Korean", category: nil, styles: []),
        IngredientSignal(phrase: "miso", cuisine: "Japanese", category: nil, styles: []),
        IngredientSignal(phrase: "dashi", cuisine: "Japanese", category: "Soup", styles: []),
        IngredientSignal(phrase: "mirin", cuisine: "Japanese", category: nil, styles: []),
        IngredientSignal(phrase: "sake", cuisine: "Japanese", category: nil, styles: []),
        IngredientSignal(phrase: "nori", cuisine: "Japanese", category: nil, styles: []),
        IngredientSignal(phrase: "fish sauce", cuisine: "Thai", category: nil, styles: []),
        IngredientSignal(phrase: "lemongrass", cuisine: "Thai", category: nil, styles: []),
        IngredientSignal(phrase: "kaffir lime", cuisine: "Thai", category: nil, styles: []),
        IngredientSignal(phrase: "thai basil", cuisine: "Thai", category: nil, styles: []),
        IngredientSignal(phrase: "galangal", cuisine: "Thai", category: nil, styles: []),
        IngredientSignal(phrase: "rice noodles", cuisine: "Thai", category: "Pasta", styles: []),
        IngredientSignal(phrase: "tomatillo", cuisine: "Mexican", category: nil, styles: []),
        IngredientSignal(phrase: "masa", cuisine: "Mexican", category: nil, styles: []),
        IngredientSignal(phrase: "hominy", cuisine: "Mexican", category: "Soup", styles: []),
        IngredientSignal(phrase: "cotija", cuisine: "Mexican", category: nil, styles: []),
        IngredientSignal(phrase: "queso fresco", cuisine: "Mexican", category: nil, styles: []),
        IngredientSignal(phrase: "chipotle", cuisine: "Mexican", category: nil, styles: []),
        IngredientSignal(phrase: "poblano", cuisine: "Mexican", category: nil, styles: []),
        IngredientSignal(phrase: "andouille", cuisine: "Cajun & Creole", category: nil, styles: []),
        IngredientSignal(phrase: "file powder", cuisine: "Cajun & Creole", category: "Soup", styles: []),
        IngredientSignal(phrase: "cajun seasoning", cuisine: "Cajun & Creole", category: nil, styles: []),
        IngredientSignal(phrase: "okra", cuisine: "Southern", category: nil, styles: []),
        IngredientSignal(phrase: "grits", cuisine: "Southern", category: "Breakfast", styles: ["Comfort"]),
        IngredientSignal(phrase: "collards", cuisine: "Southern", category: "Side", styles: []),
        IngredientSignal(phrase: "black eyed peas", cuisine: "Southern", category: "Side", styles: []),
        IngredientSignal(phrase: "garam masala", cuisine: "Indian", category: nil, styles: []),
        IngredientSignal(phrase: "curry leaves", cuisine: "Indian", category: nil, styles: []),
        IngredientSignal(phrase: "paneer", cuisine: "Indian", category: "Vegetarian", styles: []),
        IngredientSignal(phrase: "ghee", cuisine: "Indian", category: nil, styles: []),
        IngredientSignal(phrase: "tamarind", cuisine: "Indian", category: nil, styles: []),
        IngredientSignal(phrase: "ricotta", cuisine: "Italian", category: nil, styles: []),
        IngredientSignal(phrase: "pancetta", cuisine: "Italian", category: nil, styles: []),
        IngredientSignal(phrase: "prosciutto", cuisine: "Italian", category: nil, styles: []),
        IngredientSignal(phrase: "parmesan", cuisine: "Italian", category: nil, styles: []),
        IngredientSignal(phrase: "pecorino", cuisine: "Italian", category: nil, styles: []),
        IngredientSignal(phrase: "harissa", cuisine: "Middle Eastern", category: nil, styles: []),
        IngredientSignal(phrase: "tahini", cuisine: "Middle Eastern", category: "Sauce & Condiment", styles: []),
        IngredientSignal(phrase: "sumac", cuisine: "Middle Eastern", category: nil, styles: []),
        IngredientSignal(phrase: "zaatar", cuisine: "Middle Eastern", category: nil, styles: []),
        IngredientSignal(phrase: "pomegranate molasses", cuisine: "Middle Eastern", category: nil, styles: []),
        IngredientSignal(phrase: "feta", cuisine: "Greek", category: nil, styles: []),
        IngredientSignal(phrase: "kalamata", cuisine: "Greek", category: nil, styles: []),
        IngredientSignal(phrase: "phyllo", cuisine: "Greek", category: nil, styles: []),
        IngredientSignal(phrase: "saffron", cuisine: "Spanish", category: nil, styles: []),
        IngredientSignal(phrase: "chorizo", cuisine: "Spanish", category: nil, styles: []),
        IngredientSignal(phrase: "smoked paprika", cuisine: "Spanish", category: nil, styles: []),
        IngredientSignal(phrase: "duck fat", cuisine: "French", category: nil, styles: []),
        IngredientSignal(phrase: "creme fraiche", cuisine: "French", category: nil, styles: []),
        IngredientSignal(phrase: "gruyere", cuisine: "French", category: nil, styles: []),
        IngredientSignal(phrase: "brie", cuisine: "French", category: nil, styles: []),
        IngredientSignal(phrase: "hoisin", cuisine: "Chinese", category: nil, styles: []),
        IngredientSignal(phrase: "shaoxing", cuisine: "Chinese", category: nil, styles: []),
        IngredientSignal(phrase: "sichuan", cuisine: "Chinese", category: nil, styles: []),
        IngredientSignal(phrase: "five spice", cuisine: "Chinese", category: nil, styles: []),
        IngredientSignal(phrase: "oyster sauce", cuisine: "Chinese", category: nil, styles: []),
        IngredientSignal(phrase: "plantain", cuisine: "Caribbean", category: nil, styles: []),
        IngredientSignal(phrase: "scotch bonnet", cuisine: "Caribbean", category: nil, styles: []),
        IngredientSignal(phrase: "allspice", cuisine: "Caribbean", category: nil, styles: []),
        IngredientSignal(phrase: "coconut milk", cuisine: "Thai", category: nil, styles: []),
        IngredientSignal(phrase: "berbere", cuisine: "African", category: nil, styles: []),
        IngredientSignal(phrase: "teff", cuisine: "African", category: "Bread", styles: []),
        IngredientSignal(phrase: "suya", cuisine: "African", category: "Beef", styles: ["Grilled"]),
        IngredientSignal(phrase: "polenta", cuisine: "Italian", category: "Side", styles: []),
        IngredientSignal(phrase: "sauerkraut", cuisine: "German", category: "Side", styles: []),
        IngredientSignal(phrase: "bratwurst", cuisine: "German", category: "Pork", styles: []),
        IngredientSignal(phrase: "pierogi", cuisine: "Eastern European", category: "Dinner", styles: []),
        IngredientSignal(phrase: "dill pickle", cuisine: "Eastern European", category: nil, styles: []),
        IngredientSignal(phrase: "maple syrup", cuisine: "American", category: "Breakfast", styles: []),
        IngredientSignal(phrase: "molasses", cuisine: "Southern", category: nil, styles: []),
        IngredientSignal(phrase: "buttermilk", cuisine: "Southern", category: nil, styles: []),
        IngredientSignal(phrase: "brisket", cuisine: "BBQ", category: "Beef", styles: ["Grilled"]),
        IngredientSignal(phrase: "liquid smoke", cuisine: "BBQ", category: nil, styles: ["Grilled"]),
        IngredientSignal(phrase: "lobster", cuisine: "New England", category: "Seafood", styles: []),
        IngredientSignal(phrase: "clam", cuisine: "New England", category: "Seafood", styles: []),
        IngredientSignal(phrase: "poi", cuisine: "Hawaiian", category: "Side", styles: []),
        IngredientSignal(phrase: "spam", cuisine: "Hawaiian", category: "Pork", styles: []),
        IngredientSignal(phrase: "banana leaf", cuisine: "Filipino", category: nil, styles: []),
        IngredientSignal(phrase: "calamansi", cuisine: "Filipino", category: nil, styles: []),
        IngredientSignal(phrase: "annatto", cuisine: "Filipino", category: nil, styles: []),
        IngredientSignal(phrase: "achiote", cuisine: "Latin American", category: nil, styles: []),
        IngredientSignal(phrase: "yuca", cuisine: "Latin American", category: nil, styles: []),
        IngredientSignal(phrase: "dulce de leche", cuisine: "Latin American", category: "Dessert", styles: []),
        IngredientSignal(phrase: "acai", cuisine: "Brazilian", category: "Breakfast", styles: ["Healthy"])
    ]
}
