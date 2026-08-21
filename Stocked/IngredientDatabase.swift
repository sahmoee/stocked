// IngredientDatabase.swift — Built-in searchable ingredient list grouped by category.
import Foundation

struct IngredientEntry: Identifiable, Hashable {
    let id   = UUID()
    let name:     String
    let category: String
    let emoji:    String
    // #9: Perishability — used to suggest default expiry dates when adding items
    var isPerishable:    Bool = false
    var typicalShelfDays: Int = 365   // days at room temp or in fridge as appropriate
    // #10: Average weight — enables unit conversion ("2 apples" → grams for nutrition math)
    var averageWeightG:  Double? = nil
    // #18 (borrowed): Synonyms for accent-insensitive + regional name matching
    var synonyms: [String] = []
}

// MARK: - Full database
struct IngredientDatabase {
    static let all: [IngredientEntry] = meats + poultry + seafood + dairy + produce
        + grains + canned + spices + freezer + sauces + bakery + beverages
        + asian + mexican + italian + middleEastern + indian + breakfast + snacks + condiments

    // #1/#2 — Precompute the searchable, normalized form of every entry ONCE (folded name +
    // synonyms joined), instead of re-folding all ~hundreds of entries on every keystroke.
    // `searchCorpus[i]` lines up with `all[i]`.
    private static let searchCorpus: [String] = all.map { entry in
        ([entry.name] + entry.synonyms)
            .map { DBNormalize.key($0) }
            .joined(separator: "\u{1F}")   // unit separator keeps tokens distinct
    }
    // O(1) exact-name lookup (name + synonyms), built once (#1).
    private static let nameIndex = NameIndex<IngredientEntry>(
        all, key: { $0.name }, extraKeys: { $0.synonyms }
    )
    /// Exact (normalized) lookup — O(1).
    static func entry(named name: String) -> IngredientEntry? { nameIndex.first(matching: name) }

    // MARK: Meats
    static let meats: [IngredientEntry] = [
        .init(name: "Beef",            category: "Meats", emoji: "🥩"),
        .init(name: "Ground Beef",     category: "Meats", emoji: "🥩"),
        .init(name: "Steak",           category: "Meats", emoji: "🥩"),
        .init(name: "Ribeye",          category: "Meats", emoji: "🥩"),
        .init(name: "Sirloin",         category: "Meats", emoji: "🥩"),
        .init(name: "Pork",            category: "Meats", emoji: "🍖"),
        .init(name: "Pork Chops",      category: "Meats", emoji: "🍖"),
        .init(name: "Pork Loin",       category: "Meats", emoji: "🍖"),
        .init(name: "Bacon",           category: "Meats", emoji: "🥓"),
        .init(name: "Ham",             category: "Meats", emoji: "🍖"),
        .init(name: "Sausage",         category: "Meats", emoji: "🌭"),
        .init(name: "Italian Sausage", category: "Meats", emoji: "🌭"),
        .init(name: "Chorizo",         category: "Meats", emoji: "🌭"),
        .init(name: "Lamb",            category: "Meats", emoji: "🥩"),
        .init(name: "Lamb Chops",      category: "Meats", emoji: "🥩"),
        .init(name: "Veal",            category: "Meats", emoji: "🥩"),
        .init(name: "Bison",           category: "Meats", emoji: "🥩"),
        .init(name: "Pepperoni",       category: "Meats", emoji: "🍕"),
        .init(name: "Salami",          category: "Meats", emoji: "🥩"),
    ]

    // MARK: Poultry
    static let poultry: [IngredientEntry] = [
        .init(name: "Chicken Breast",       category: "Poultry", emoji: "🍗"),
        .init(name: "Chicken Thighs",       category: "Poultry", emoji: "🍗"),
        .init(name: "Chicken Wings",        category: "Poultry", emoji: "🍗"),
        .init(name: "Whole Chicken",        category: "Poultry", emoji: "🐔"),
        .init(name: "Ground Chicken",       category: "Poultry", emoji: "🍗"),
        .init(name: "Turkey Breast",        category: "Poultry", emoji: "🦃"),
        .init(name: "Ground Turkey",        category: "Poultry", emoji: "🦃"),
        .init(name: "Duck",                 category: "Poultry", emoji: "🦆"),
        .init(name: "Rotisserie Chicken",   category: "Poultry", emoji: "🍗"),
        .init(name: "Eggs",                 category: "Poultry", emoji: "🥚"),
        .init(name: "Egg Whites",           category: "Poultry", emoji: "🥚"),
    ]

    // MARK: Seafood
    static let seafood: [IngredientEntry] = [
        .init(name: "Salmon",       category: "Seafood", emoji: "🐟"),
        .init(name: "Tuna",         category: "Seafood", emoji: "🐟"),
        .init(name: "Shrimp",       category: "Seafood", emoji: "🍤"),
        .init(name: "Cod",          category: "Seafood", emoji: "🐟"),
        .init(name: "Tilapia",      category: "Seafood", emoji: "🐟"),
        .init(name: "Crab",         category: "Seafood", emoji: "🦀"),
        .init(name: "Lobster",      category: "Seafood", emoji: "🦞"),
        .init(name: "Scallops",     category: "Seafood", emoji: "🦪"),
        .init(name: "Clams",        category: "Seafood", emoji: "🦪"),
        .init(name: "Mussels",      category: "Seafood", emoji: "🦪"),
        .init(name: "Sardines",     category: "Seafood", emoji: "🐟"),
        .init(name: "Anchovies",    category: "Seafood", emoji: "🐟"),
        .init(name: "Halibut",      category: "Seafood", emoji: "🐟"),
        .init(name: "Mahi-Mahi",    category: "Seafood", emoji: "🐟"),
    ]

    // MARK: Dairy
    static let dairy: [IngredientEntry] = [
        .init(name: "Whole Milk",        category: "Dairy", emoji: "🥛"),
        .init(name: "Skim Milk",         category: "Dairy", emoji: "🥛"),
        .init(name: "Butter",            category: "Dairy", emoji: "🧈"),
        .init(name: "Cheddar Cheese",    category: "Dairy", emoji: "🧀"),
        .init(name: "Mozzarella",        category: "Dairy", emoji: "🧀"),
        .init(name: "Parmesan",          category: "Dairy", emoji: "🧀"),
        .init(name: "Greek Yogurt",      category: "Dairy", emoji: "🥣"),
        .init(name: "Heavy Cream",       category: "Dairy", emoji: "🥛"),
        .init(name: "Sour Cream",        category: "Dairy", emoji: "🥛"),
        .init(name: "Cream Cheese",      category: "Dairy", emoji: "🧀"),
        .init(name: "Cottage Cheese",    category: "Dairy", emoji: "🧀"),
        .init(name: "Almond Milk",       category: "Dairy", emoji: "🥛"),
        .init(name: "Oat Milk",          category: "Dairy", emoji: "🥛"),
        .init(name: "Feta Cheese",       category: "Dairy", emoji: "🧀"),
        .init(name: "Brie",              category: "Dairy", emoji: "🧀"),
    ]

    // MARK: Produce
    static let produce: [IngredientEntry] = [
        .init(name: "Garlic",        category: "Produce", emoji: "🧄"),
        .init(name: "Onion",         category: "Produce", emoji: "🧅"),
        .init(name: "Red Onion",     category: "Produce", emoji: "🧅"),
        .init(name: "Spinach",       category: "Produce", emoji: "🌿"),
        .init(name: "Kale",          category: "Produce", emoji: "🥬"),
        .init(name: "Broccoli",      category: "Produce", emoji: "🥦"),
        .init(name: "Cauliflower",   category: "Produce", emoji: "🥦"),
        .init(name: "Carrots",       category: "Produce", emoji: "🥕"),
        .init(name: "Celery",        category: "Produce", emoji: "🥬"),
        .init(name: "Bell Pepper",   category: "Produce", emoji: "🫑"),
        .init(name: "Tomatoes",      category: "Produce", emoji: "🍅"),
        .init(name: "Cherry Tomatoes", category: "Produce", emoji: "🍅"),
        .init(name: "Cucumber",      category: "Produce", emoji: "🥒"),
        .init(name: "Zucchini",      category: "Produce", emoji: "🥒"),
        .init(name: "Mushrooms",     category: "Produce", emoji: "🍄"),
        .init(name: "Potatoes",      category: "Produce", emoji: "🥔"),
        .init(name: "Sweet Potato",  category: "Produce", emoji: "🍠"),
        .init(name: "Avocado",       category: "Produce", emoji: "🥑"),
        .init(name: "Lemon",         category: "Produce", emoji: "🍋"),
        .init(name: "Lime",          category: "Produce", emoji: "🍋"),
        .init(name: "Jalapeño",      category: "Produce", emoji: "🌶️"),
        .init(name: "Leek",          category: "Produce", emoji: "🌿"),
        .init(name: "Asparagus",     category: "Produce", emoji: "🌿"),
        .init(name: "Green Beans",   category: "Produce", emoji: "🌿"),
        .init(name: "Corn",          category: "Produce", emoji: "🌽"),
        .init(name: "Eggplant",      category: "Produce", emoji: "🍆"),
        .init(name: "Ginger",        category: "Produce", emoji: "🌿"),
    ]

    // MARK: Grains & Pantry
    static let grains: [IngredientEntry] = [
        .init(name: "White Rice",      category: "Pantry", emoji: "🍚"),
        .init(name: "Brown Rice",      category: "Pantry", emoji: "🍚"),
        .init(name: "Pasta",           category: "Pantry", emoji: "🍝"),
        .init(name: "Spaghetti",       category: "Pantry", emoji: "🍝"),
        .init(name: "Penne",           category: "Pantry", emoji: "🍝"),
        .init(name: "Fettuccine",      category: "Pantry", emoji: "🍝"),
        .init(name: "Bread",           category: "Pantry", emoji: "🍞"),
        .init(name: "Tortillas",       category: "Pantry", emoji: "🫓"),
        .init(name: "Quinoa",          category: "Pantry", emoji: "🌾"),
        .init(name: "Oats",            category: "Pantry", emoji: "🌾"),
        .init(name: "Flour",           category: "Pantry", emoji: "🌾"),
        .init(name: "Bread Crumbs",    category: "Pantry", emoji: "🍞"),
        .init(name: "Cornstarch",      category: "Pantry", emoji: "🌾"),
        .init(name: "Couscous",        category: "Pantry", emoji: "🌾"),
        .init(name: "Lentils",         category: "Pantry", emoji: "🫘"),
        .init(name: "Black Beans",     category: "Pantry", emoji: "🫘"),
        .init(name: "Chickpeas",       category: "Pantry", emoji: "🫘"),
        .init(name: "Kidney Beans",    category: "Pantry", emoji: "🫘"),
        .init(name: "Pinto Beans",     category: "Pantry", emoji: "🫘"),
        .init(name: "Sugar",           category: "Pantry", emoji: "🧂"),
        .init(name: "Brown Sugar",     category: "Pantry", emoji: "🧂"),
        .init(name: "Honey",           category: "Pantry", emoji: "🍯"),
        .init(name: "Maple Syrup",     category: "Pantry", emoji: "🍯"),
    ]

    // MARK: Canned & Pantry
    static let canned: [IngredientEntry] = [
        .init(name: "Chicken Broth",     category: "Pantry", emoji: "🥣"),
        .init(name: "Beef Broth",        category: "Pantry", emoji: "🥣"),
        .init(name: "Vegetable Broth",   category: "Pantry", emoji: "🥣"),
        .init(name: "Diced Tomatoes",    category: "Pantry", emoji: "🍅"),
        .init(name: "Tomato Paste",      category: "Pantry", emoji: "🍅"),
        .init(name: "Tomato Sauce",      category: "Pantry", emoji: "🍅"),
        .init(name: "Coconut Milk",      category: "Pantry", emoji: "🥥"),
        .init(name: "Tuna (Canned)",     category: "Pantry", emoji: "🐟"),
        .init(name: "Chicken (Canned)",  category: "Pantry", emoji: "🍗"),
        .init(name: "Corn (Canned)",     category: "Pantry", emoji: "🌽"),
        .init(name: "Green Beans (Canned)", category: "Pantry", emoji: "🌿"),
        .init(name: "Pumpkin Puree",     category: "Pantry", emoji: "🎃"),
    ]

    // MARK: Spices & Herbs
    static let spices: [IngredientEntry] = [
        .init(name: "Salt",             category: "Staples", emoji: "🧂"),
        .init(name: "Black Pepper",     category: "Staples", emoji: "🧂"),
        .init(name: "Garlic Powder",    category: "Staples", emoji: "🧄"),
        .init(name: "Onion Powder",     category: "Staples", emoji: "🧅"),
        .init(name: "Cumin",            category: "Staples", emoji: "🌿"),
        .init(name: "Paprika",          category: "Staples", emoji: "🌶️"),
        .init(name: "Smoked Paprika",   category: "Staples", emoji: "🌶️"),
        .init(name: "Oregano",          category: "Staples", emoji: "🌿"),
        .init(name: "Thyme",            category: "Staples", emoji: "🌿"),
        .init(name: "Rosemary",         category: "Staples", emoji: "🌿"),
        .init(name: "Basil",            category: "Staples", emoji: "🌿"),
        .init(name: "Cilantro",         category: "Staples", emoji: "🌿"),
        .init(name: "Parsley",          category: "Staples", emoji: "🌿"),
        .init(name: "Bay Leaves",       category: "Staples", emoji: "🌿"),
        .init(name: "Cinnamon",         category: "Staples", emoji: "🌿"),
        .init(name: "Turmeric",         category: "Staples", emoji: "🌿"),
        .init(name: "Cayenne Pepper",   category: "Staples", emoji: "🌶️"),
        .init(name: "Chili Flakes",     category: "Staples", emoji: "🌶️"),
        .init(name: "Italian Seasoning", category: "Staples", emoji: "🌿"),
        .init(name: "Curry Powder",     category: "Staples", emoji: "🌿"),
        .init(name: "Garam Masala",     category: "Staples", emoji: "🌿"),
        .init(name: "Coriander",        category: "Staples", emoji: "🌿"),
        .init(name: "Cardamom",         category: "Staples", emoji: "🌿"),
        .init(name: "Nutmeg",           category: "Staples", emoji: "🌿"),
        .init(name: "Allspice",         category: "Staples", emoji: "🌿"),
        .init(name: "Vanilla Extract",  category: "Staples", emoji: "🌿"),
        .init(name: "Baking Powder",    category: "Staples", emoji: "🧂"),
        .init(name: "Baking Soda",      category: "Staples", emoji: "🧂"),
    ]

    // MARK: Freezer
    static let freezer: [IngredientEntry] = [
        .init(name: "Frozen Peas",         category: "Freezer", emoji: "🫘"),
        .init(name: "Frozen Corn",         category: "Freezer", emoji: "🌽"),
        .init(name: "Frozen Spinach",      category: "Freezer", emoji: "🌿"),
        .init(name: "Frozen Broccoli",     category: "Freezer", emoji: "🥦"),
        .init(name: "Frozen Mixed Veg",    category: "Freezer", emoji: "🥦"),
        .init(name: "Frozen Shrimp",       category: "Freezer", emoji: "🍤"),
        .init(name: "Frozen Salmon",       category: "Freezer", emoji: "🐟"),
        .init(name: "Frozen Pizza",        category: "Freezer", emoji: "🍕"),
        .init(name: "Frozen Waffles",      category: "Freezer", emoji: "🧇"),
        .init(name: "Ice Cream",           category: "Freezer", emoji: "🍦"),
        .init(name: "Frozen Edamame",      category: "Freezer", emoji: "🫘"),
        .init(name: "Frozen Mango",        category: "Freezer", emoji: "🥭"),
        .init(name: "Frozen Berries",      category: "Freezer", emoji: "🫐"),
        .init(name: "Frozen Chicken",      category: "Freezer", emoji: "🍗"),
        .init(name: "Frozen Beef Patties", category: "Freezer", emoji: "🍔"),
    ]

    // MARK: Sauces & Oils
    static let sauces: [IngredientEntry] = [
        .init(name: "Olive Oil",        category: "Pantry", emoji: "🫙"),
        .init(name: "Vegetable Oil",    category: "Pantry", emoji: "🫙"),
        .init(name: "Sesame Oil",       category: "Pantry", emoji: "🫙"),
        .init(name: "Coconut Oil",      category: "Pantry", emoji: "🫙"),
        .init(name: "Soy Sauce",        category: "Pantry", emoji: "🫙"),
        .init(name: "Fish Sauce",       category: "Pantry", emoji: "🫙"),
        .init(name: "Worcestershire",   category: "Pantry", emoji: "🫙"),
        .init(name: "Hot Sauce",        category: "Pantry", emoji: "🌶️"),
        .init(name: "Ketchup",          category: "Pantry", emoji: "🍅"),
        .init(name: "Mustard",          category: "Pantry", emoji: "🫙"),
        .init(name: "Mayonnaise",       category: "Pantry", emoji: "🫙"),
        .init(name: "Ranch Dressing",   category: "Pantry", emoji: "🫙"),
        .init(name: "Balsamic Vinegar", category: "Pantry", emoji: "🫙"),
        .init(name: "Apple Cider Vinegar", category: "Pantry", emoji: "🫙"),
        .init(name: "White Wine",       category: "Pantry", emoji: "🍷"),
        .init(name: "Red Wine",         category: "Pantry", emoji: "🍷"),
        .init(name: "Hoisin Sauce",     category: "Pantry", emoji: "🫙"),
        .init(name: "Oyster Sauce",     category: "Pantry", emoji: "🫙"),
        .init(name: "Sriracha",         category: "Pantry", emoji: "🌶️"),
        .init(name: "Pesto",            category: "Pantry", emoji: "🌿"),
        .init(name: "Tahini",           category: "Pantry", emoji: "🫙"),
    ]

    // MARK: Bakery
    static let bakery: [IngredientEntry] = [
        .init(name: "Sandwich Bread",   category: "Pantry", emoji: "🍞"),
        .init(name: "Bagels",           category: "Pantry", emoji: "🥯"),
        .init(name: "English Muffins",  category: "Pantry", emoji: "🍞"),
        .init(name: "Pita Bread",       category: "Pantry", emoji: "🫓"),
        .init(name: "Naan",             category: "Pantry", emoji: "🫓"),
        .init(name: "Burger Buns",      category: "Pantry", emoji: "🍔"),
        .init(name: "Crackers",         category: "Pantry", emoji: "🫓"),
    ]

    // MARK: Beverages
    static let beverages: [IngredientEntry] = [
        // Fridge — cold/fresh drinks
        .init(name: "Orange Juice",     category: "Fridge",  emoji: "🍊"),
        .init(name: "Apple Juice",      category: "Fridge",  emoji: "🍎"),
        .init(name: "Sparkling Water",  category: "Fridge",  emoji: "💧"),
        .init(name: "Coconut Water",    category: "Fridge",  emoji: "🥥"),
        .init(name: "Energy Drink",     category: "Fridge",  emoji: "⚡"),
        .init(name: "Sports Drink",     category: "Fridge",  emoji: "🏃"),
        .init(name: "Kombucha",         category: "Fridge",  emoji: "🫙"),
        .init(name: "Oat Milk",         category: "Fridge",  emoji: "🌾"),
        .init(name: "Almond Milk",      category: "Fridge",  emoji: "🌰"),
        .init(name: "Soy Milk",         category: "Fridge",  emoji: "🫘"),
        .init(name: "Beer",             category: "Fridge",  emoji: "🍺"),
        .init(name: "Wine",             category: "Fridge",  emoji: "🍷"),
        .init(name: "Hard Seltzer",     category: "Fridge",  emoji: "🥂"),
        .init(name: "Cold Brew",        category: "Fridge",  emoji: "☕"),
        .init(name: "Iced Coffee",      category: "Fridge",  emoji: "☕"),
        .init(name: "Protein Shake",    category: "Fridge",  emoji: "💪"),
        .init(name: "Lemonade",         category: "Fridge",  emoji: "🍋"),
        // Pantry — shelf-stable drinks
        .init(name: "Coffee",           category: "Pantry",  emoji: "☕"),
        .init(name: "Tea",              category: "Pantry",  emoji: "🍵"),
        .init(name: "Green Tea",        category: "Pantry",  emoji: "🍵"),
        .init(name: "Hot Chocolate",    category: "Pantry",  emoji: "☕"),
        .init(name: "Soda",             category: "Pantry",  emoji: "🥤"),
        .init(name: "Cola",             category: "Pantry",  emoji: "🥤"),
        .init(name: "Water",            category: "Pantry",  emoji: "💧"),
    ]

    static var categories: [String] {
        Array(Set(all.map(\.category))).sorted()
    }
    static func items(in category: String) -> [IngredientEntry] {
        all.filter { $0.category == category }.sorted { $0.name < $1.name }
    }
    static func search(_ query: String) -> [IngredientEntry] {
        // #6: Accent-insensitive — jalapeño matches jalapeno, café matches cafe.
        // #2: matches against the precomputed folded corpus instead of re-folding every entry.
        guard !query.isEmpty else { return all.sorted { $0.name < $1.name } }
        let q = DBNormalize.key(query)
        var hits: [IngredientEntry] = []
        for i in all.indices where searchCorpus[i].contains(q) {
            hits.append(all[i])
        }
        return hits.sorted { $0.name < $1.name }
    }

    // MARK: Asian
    static let asian: [IngredientEntry] = [
        .init(name: "Soy Sauce",          category: "Asian", emoji: "🍶"),
        .init(name: "Sesame Oil",         category: "Asian", emoji: "🛢️"),
        .init(name: "Rice Vinegar",       category: "Asian", emoji: "🍶"),
        .init(name: "Fish Sauce",         category: "Asian", emoji: "🍶"),
        .init(name: "Oyster Sauce",       category: "Asian", emoji: "🍶"),
        .init(name: "Hoisin Sauce",       category: "Asian", emoji: "🍶"),
        .init(name: "Miso Paste",         category: "Asian", emoji: "🍱"),
        .init(name: "Mirin",              category: "Asian", emoji: "🍶"),
        .init(name: "Sake",               category: "Asian", emoji: "🍶"),
        .init(name: "Gochujang",          category: "Asian", emoji: "🌶️"),
        .init(name: "Sriracha",           category: "Asian", emoji: "🌶️"),
        .init(name: "Chili Oil",          category: "Asian", emoji: "🌶️"),
        .init(name: "Noodles",            category: "Asian", emoji: "🍜"),
        .init(name: "Udon Noodles",       category: "Asian", emoji: "🍜"),
        .init(name: "Ramen Noodles",      category: "Asian", emoji: "🍜"),
        .init(name: "Rice Noodles",       category: "Asian", emoji: "🍜"),
        .init(name: "Glass Noodles",      category: "Asian", emoji: "🍜"),
        .init(name: "Wonton Wrappers",    category: "Asian", emoji: "🥟"),
        .init(name: "Dumpling Wrappers",  category: "Asian", emoji: "🥟"),
        .init(name: "Spring Roll Wrappers",category: "Asian", emoji: "🥢"),
        .init(name: "Nori",               category: "Asian", emoji: "🌿"),
        .init(name: "Sesame Seeds",       category: "Asian", emoji: "🌿"),
        .init(name: "Bok Choy",           category: "Asian", emoji: "🥬"),
        .init(name: "Bean Sprouts",       category: "Asian", emoji: "🌱"),
        .init(name: "Water Chestnuts",    category: "Asian", emoji: "🌰"),
        .init(name: "Bamboo Shoots",      category: "Asian", emoji: "🌿"),
        .init(name: "Edamame",            category: "Asian", emoji: "🫘"),
        .init(name: "Tofu",               category: "Asian", emoji: "⬜"),
        .init(name: "Tempeh",             category: "Asian", emoji: "⬜"),
        .init(name: "Lemongrass",         category: "Asian", emoji: "🌿"),
        .init(name: "Thai Basil",         category: "Asian", emoji: "🌿"),
        .init(name: "Galangal",           category: "Asian", emoji: "🫚"),
        .init(name: "Kaffir Lime Leaves", category: "Asian", emoji: "🍃"),
    ]

    // MARK: Mexican
    static let mexican: [IngredientEntry] = [
        .init(name: "Tortillas",          category: "Mexican", emoji: "🫓"),
        .init(name: "Corn Tortillas",     category: "Mexican", emoji: "🌮"),
        .init(name: "Taco Shells",        category: "Mexican", emoji: "🌮"),
        .init(name: "Salsa",              category: "Mexican", emoji: "🍅"),
        .init(name: "Guacamole",          category: "Mexican", emoji: "🥑"),
        .init(name: "Jalapeños",          category: "Mexican", emoji: "🌶️"),
        .init(name: "Chipotle in Adobo",  category: "Mexican", emoji: "🌶️"),
        .init(name: "Enchilada Sauce",    category: "Mexican", emoji: "🫙"),
        .init(name: "Taco Seasoning",     category: "Mexican", emoji: "🧂"),
        .init(name: "Cumin",              category: "Mexican", emoji: "🌿"),
        .init(name: "Ancho Chili Powder", category: "Mexican", emoji: "🌶️"),
        .init(name: "Black Beans",        category: "Mexican", emoji: "🫘"),
        .init(name: "Pinto Beans",        category: "Mexican", emoji: "🫘"),
        .init(name: "Refried Beans",      category: "Mexican", emoji: "🫘"),
        .init(name: "Cotija Cheese",      category: "Mexican", emoji: "🧀"),
        .init(name: "Queso Fresco",       category: "Mexican", emoji: "🧀"),
        .init(name: "Mexican Crema",      category: "Mexican", emoji: "🥛"),
        .init(name: "Cilantro",           category: "Mexican", emoji: "🌿"),
        .init(name: "Lime",               category: "Mexican", emoji: "🍋"),
        .init(name: "Avocado",            category: "Mexican", emoji: "🥑"),
        .init(name: "Corn",               category: "Mexican", emoji: "🌽"),
        .init(name: "Chili Peppers",      category: "Mexican", emoji: "🌶️"),
    ]

    // MARK: Italian
    static let italian: [IngredientEntry] = [
        .init(name: "Pasta",              category: "Italian", emoji: "🍝"),
        .init(name: "Spaghetti",          category: "Italian", emoji: "🍝"),
        .init(name: "Penne",              category: "Italian", emoji: "🍝"),
        .init(name: "Rigatoni",           category: "Italian", emoji: "🍝"),
        .init(name: "Fettuccine",         category: "Italian", emoji: "🍝"),
        .init(name: "Lasagna Sheets",     category: "Italian", emoji: "🍝"),
        .init(name: "Gnocchi",            category: "Italian", emoji: "🍝"),
        .init(name: "Risotto Rice",       category: "Italian", emoji: "🍚"),
        .init(name: "Arborio Rice",       category: "Italian", emoji: "🍚"),
        .init(name: "Marinara Sauce",     category: "Italian", emoji: "🍅"),
        .init(name: "Tomato Paste",       category: "Italian", emoji: "🍅"),
        .init(name: "San Marzano Tomatoes",category: "Italian", emoji: "🍅"),
        .init(name: "Parmesan",           category: "Italian", emoji: "🧀"),
        .init(name: "Pecorino Romano",    category: "Italian", emoji: "🧀"),
        .init(name: "Ricotta",            category: "Italian", emoji: "🧀"),
        .init(name: "Mozzarella",         category: "Italian", emoji: "🧀"),
        .init(name: "Prosciutto",         category: "Italian", emoji: "🥩"),
        .init(name: "Pancetta",           category: "Italian", emoji: "🥓"),
        .init(name: "Guanciale",          category: "Italian", emoji: "🥓"),
        .init(name: "Basil",              category: "Italian", emoji: "🌿"),
        .init(name: "Oregano",            category: "Italian", emoji: "🌿"),
        .init(name: "Capers",             category: "Italian", emoji: "🫙"),
        .init(name: "Anchovies",          category: "Italian", emoji: "🐟"),
        .init(name: "Balsamic Vinegar",   category: "Italian", emoji: "🫙"),
        .init(name: "Extra Virgin Olive Oil",category: "Italian", emoji: "🫙"),
        .init(name: "Pine Nuts",          category: "Italian", emoji: "🌰"),
        .init(name: "Polenta",            category: "Italian", emoji: "🌽"),
    ]

    // MARK: Middle Eastern
    static let middleEastern: [IngredientEntry] = [
        .init(name: "Chickpeas",          category: "Middle Eastern", emoji: "🫘"),
        .init(name: "Tahini",             category: "Middle Eastern", emoji: "🫙"),
        .init(name: "Za'atar",            category: "Middle Eastern", emoji: "🌿"),
        .init(name: "Sumac",              category: "Middle Eastern", emoji: "🌿"),
        .init(name: "Harissa",            category: "Middle Eastern", emoji: "🌶️"),
        .init(name: "Rose Water",         category: "Middle Eastern", emoji: "🌹"),
        .init(name: "Pomegranate Molasses",category: "Middle Eastern", emoji: "🫙"),
        .init(name: "Pita Bread",         category: "Middle Eastern", emoji: "🫓"),
        .init(name: "Feta Cheese",        category: "Middle Eastern", emoji: "🧀"),
        .init(name: "Halloumi",           category: "Middle Eastern", emoji: "🧀"),
        .init(name: "Bulgur Wheat",       category: "Middle Eastern", emoji: "🌾"),
        .init(name: "Couscous",           category: "Middle Eastern", emoji: "🌾"),
        .init(name: "Freekeh",            category: "Middle Eastern", emoji: "🌾"),
        .init(name: "Lentils",            category: "Middle Eastern", emoji: "🫘"),
        .init(name: "Ras el Hanout",      category: "Middle Eastern", emoji: "🌿"),
        .init(name: "Cardamom",           category: "Middle Eastern", emoji: "🌿"),
    ]

    // MARK: Indian
    static let indian: [IngredientEntry] = [
        .init(name: "Basmati Rice",       category: "Indian", emoji: "🍚"),
        .init(name: "Naan",               category: "Indian", emoji: "🫓"),
        .init(name: "Garam Masala",       category: "Indian", emoji: "🌿"),
        .init(name: "Turmeric",           category: "Indian", emoji: "🌿"),
        .init(name: "Curry Powder",       category: "Indian", emoji: "🌿"),
        .init(name: "Coriander",          category: "Indian", emoji: "🌿"),
        .init(name: "Fenugreek",          category: "Indian", emoji: "🌿"),
        .init(name: "Asafoetida",         category: "Indian", emoji: "🌿"),
        .init(name: "Mustard Seeds",      category: "Indian", emoji: "🌿"),
        .init(name: "Paneer",             category: "Indian", emoji: "🧀"),
        .init(name: "Ghee",               category: "Indian", emoji: "🧈"),
        .init(name: "Coconut Milk",       category: "Indian", emoji: "🥛"),
        .init(name: "Tamarind",           category: "Indian", emoji: "🌿"),
        .init(name: "Mango Chutney",      category: "Indian", emoji: "🥭"),
        .init(name: "Dal",                category: "Indian", emoji: "🫘"),
        .init(name: "Chana Dal",          category: "Indian", emoji: "🫘"),
        .init(name: "Tikka Masala Paste", category: "Indian", emoji: "🫙"),
        .init(name: "Yogurt",             category: "Indian", emoji: "🥛"),
        .init(name: "Fresh Ginger",       category: "Indian", emoji: "🫚"),
        .init(name: "Green Cardamom",     category: "Indian", emoji: "🌿"),
    ]

    // MARK: Breakfast
    static let breakfast: [IngredientEntry] = [
        .init(name: "Oats",               category: "Breakfast", emoji: "🌾"),
        .init(name: "Granola",            category: "Breakfast", emoji: "🥣"),
        .init(name: "Maple Syrup",        category: "Breakfast", emoji: "🍁"),
        .init(name: "Honey",              category: "Breakfast", emoji: "🍯"),
        .init(name: "Pancake Mix",        category: "Breakfast", emoji: "🥞"),
        .init(name: "Waffle Mix",         category: "Breakfast", emoji: "🧇"),
        .init(name: "Bagels",             category: "Breakfast", emoji: "🥯"),
        .init(name: "English Muffins",    category: "Breakfast", emoji: "🫓"),
        .init(name: "Cream Cheese",       category: "Breakfast", emoji: "🧀"),
        .init(name: "Jam",                category: "Breakfast", emoji: "🍓"),
        .init(name: "Peanut Butter",      category: "Breakfast", emoji: "🥜"),
        .init(name: "Almond Butter",      category: "Breakfast", emoji: "🥜"),
        .init(name: "Chia Seeds",         category: "Breakfast", emoji: "🌱"),
        .init(name: "Flax Seeds",         category: "Breakfast", emoji: "🌱"),
        .init(name: "Protein Powder",     category: "Breakfast", emoji: "💪"),
        .init(name: "Vanilla Extract",    category: "Breakfast", emoji: "🫙"),
        .init(name: "Whipped Cream",      category: "Breakfast", emoji: "🍦"),
        .init(name: "Nutella",            category: "Breakfast", emoji: "🍫"),
        .init(name: "Greek Yogurt",       category: "Breakfast", emoji: "🥛"),
        .init(name: "Blueberries",        category: "Breakfast", emoji: "🫐"),
        .init(name: "Strawberries",       category: "Breakfast", emoji: "🍓"),
    ]

    // MARK: Snacks
    static let snacks: [IngredientEntry] = [
        .init(name: "Crackers",           category: "Snacks", emoji: "🧇"),
        .init(name: "Chips",              category: "Snacks", emoji: "🥔"),
        .init(name: "Pretzels",           category: "Snacks", emoji: "🥨"),
        .init(name: "Popcorn",            category: "Snacks", emoji: "🍿"),
        .init(name: "Trail Mix",          category: "Snacks", emoji: "🌰"),
        .init(name: "Nuts",               category: "Snacks", emoji: "🥜"),
        .init(name: "Almonds",            category: "Snacks", emoji: "🥜"),
        .init(name: "Cashews",            category: "Snacks", emoji: "🥜"),
        .init(name: "Walnuts",            category: "Snacks", emoji: "🥜"),
        .init(name: "Pistachios",         category: "Snacks", emoji: "🥜"),
        .init(name: "Popcorn Kernels",    category: "Snacks", emoji: "🍿"),
        .init(name: "Dried Fruit",        category: "Snacks", emoji: "🍇"),
        .init(name: "Dark Chocolate",     category: "Snacks", emoji: "🍫"),
        .init(name: "Chocolate Chips",    category: "Snacks", emoji: "🍫"),
        .init(name: "Rice Cakes",         category: "Snacks", emoji: "🍘"),
        .init(name: "Energy Bars",        category: "Snacks", emoji: "🍫"),
        .init(name: "Hummus",             category: "Snacks", emoji: "🫘"),
        .init(name: "Salsa Verde",        category: "Snacks", emoji: "🫙"),
    ]

    // MARK: Condiments
    static let condiments: [IngredientEntry] = [
        .init(name: "Ketchup",            category: "Condiments", emoji: "🍅"),
        .init(name: "Mustard",            category: "Condiments", emoji: "💛"),
        .init(name: "Mayonnaise",         category: "Condiments", emoji: "🫙"),
        .init(name: "Dijon Mustard",      category: "Condiments", emoji: "💛"),
        .init(name: "Worcestershire",     category: "Condiments", emoji: "🫙"),
        .init(name: "Hot Sauce",          category: "Condiments", emoji: "🌶️"),
        .init(name: "Buffalo Sauce",      category: "Condiments", emoji: "🌶️"),
        .init(name: "BBQ Sauce",          category: "Condiments", emoji: "🫙"),
        .init(name: "Ranch Dressing",     category: "Condiments", emoji: "🫙"),
        .init(name: "Caesar Dressing",    category: "Condiments", emoji: "🫙"),
        .init(name: "Balsamic Glaze",     category: "Condiments", emoji: "🫙"),
        .init(name: "Apple Cider Vinegar",category: "Condiments", emoji: "🫙"),
        .init(name: "White Wine Vinegar", category: "Condiments", emoji: "🫙"),
        .init(name: "Pickle Juice",       category: "Condiments", emoji: "🥒"),
        .init(name: "Caramel Sauce",      category: "Condiments", emoji: "🫙"),
        .init(name: "Tabasco",            category: "Condiments", emoji: "🌶️"),
        .init(name: "Soy Glaze",          category: "Condiments", emoji: "🫙"),
        .init(name: "Teriyaki Sauce",     category: "Condiments", emoji: "🫙"),
        .init(name: "Pesto",              category: "Condiments", emoji: "🌿"),
        .init(name: "Tahini",             category: "Condiments", emoji: "🫙"),
    ]
}

// IngredientEntry extension: #8 — fall through to NutritionDatabase if no inline nutrition
extension IngredientEntry {
    var nutrition: NutritionFacts? {
        NutritionDatabase.facts(for: name)
    }
}

struct NutritionInfo: Codable {
    var servingSize:    String  = ""
    var calories:       Int     = 0
    var totalFat:       Double  = 0
    var saturatedFat:   Double  = 0
    var cholesterol:    Int     = 0
    var sodium:         Int     = 0
    var totalCarbs:     Double  = 0
    var dietaryFiber:  Double? = nil
    var totalSugars:    Double? = nil
    var protein:        Double  = 0
    var calcium:        Int?    = nil
    var iron:           Double? = nil
    var vitaminD:       Double? = nil

    func toFacts() -> NutritionFacts {
        NutritionFacts(
            servingSize:  servingSize,
            calories:     calories,
            totalFat:     totalFat,
            saturatedFat: saturatedFat,
            transFat:     0,
            cholesterol:  Double(cholesterol),
            sodium:       Double(sodium),
            totalCarbs:   totalCarbs,
            dietaryFiber: dietaryFiber ?? 0,
            totalSugars:  totalSugars ?? 0,
            addedSugars:  0,
            protein:      protein,
            vitaminD:     vitaminD ?? 0,
            calcium:      Double(calcium ?? 0),
            iron:         iron ?? 0,
            potassium:    0
        )
    }
}

struct BrandEntry: Identifiable, Codable {
    var id           = UUID()
    var brand:       String
    var itemName:    String
    var nutrition:   NutritionInfo

    init(brand: String, itemName: String, nutrition: NutritionInfo = NutritionInfo()) {
        self.brand = brand; self.itemName = itemName; self.nutrition = nutrition
    }
}

struct BrandDatabase {
    static let all: [BrandEntry] = [
        // ── Chicken ──────────────────────────────────────────────────────
        BrandEntry(brand: "Tyson", itemName: "Chicken Breast",
            nutrition: .init(servingSize:"4 oz (112g)", calories:130, totalFat:3, saturatedFat:0.5, cholesterol:65, sodium:65, totalCarbs:0, protein:26)),
        BrandEntry(brand: "Perdue", itemName: "Chicken Breast",
            nutrition: .init(servingSize:"4 oz (112g)", calories:120, totalFat:2, saturatedFat:0.5, cholesterol:65, sodium:75, totalCarbs:0, protein:25)),
        BrandEntry(brand: "Foster Farms", itemName: "Chicken Breast",
            nutrition: .init(servingSize:"4 oz (112g)", calories:110, totalFat:1.5, saturatedFat:0, cholesterol:60, sodium:55, totalCarbs:0, protein:24)),

        // ── Ground Beef ──────────────────────────────────────────────────
        BrandEntry(brand: "Laura's Lean Beef", itemName: "Ground Beef",
            nutrition: .init(servingSize:"4 oz (112g)", calories:150, totalFat:7, saturatedFat:3, cholesterol:70, sodium:75, totalCarbs:0, protein:22)),
        BrandEntry(brand: "Honest Ground", itemName: "Ground Beef",
            nutrition: .init(servingSize:"4 oz (112g)", calories:200, totalFat:13, saturatedFat:5, cholesterol:75, sodium:70, totalCarbs:0, protein:21)),

        // ── Bacon ────────────────────────────────────────────────────────
        BrandEntry(brand: "Oscar Mayer", itemName: "Bacon",
            nutrition: .init(servingSize:"2 slices (14g)", calories:70, totalFat:5, saturatedFat:2, cholesterol:20, sodium:280, totalCarbs:0, protein:5)),
        BrandEntry(brand: "Wright Brand", itemName: "Bacon",
            nutrition: .init(servingSize:"2 slices (14g)", calories:80, totalFat:6, saturatedFat:2.5, cholesterol:20, sodium:270, totalCarbs:0, protein:6)),
        BrandEntry(brand: "Applegate", itemName: "Bacon",
            nutrition: .init(servingSize:"2 slices (14g)", calories:60, totalFat:4.5, saturatedFat:1.5, cholesterol:15, sodium:260, totalCarbs:0, protein:5)),

        // ── Eggs ─────────────────────────────────────────────────────────
        BrandEntry(brand: "Vital Farms", itemName: "Eggs",
            nutrition: .init(servingSize:"1 large egg (50g)", calories:70, totalFat:5, saturatedFat:1.5, cholesterol:185, sodium:65, totalCarbs:0, totalSugars:0, protein:6)),
        BrandEntry(brand: "Happy Egg", itemName: "Eggs",
            nutrition: .init(servingSize:"1 large egg (50g)", calories:70, totalFat:5, saturatedFat:1.5, cholesterol:185, sodium:65, totalCarbs:0, protein:6)),
        BrandEntry(brand: "Eggland's Best", itemName: "Eggs",
            nutrition: .init(servingSize:"1 large egg (50g)", calories:70, totalFat:4.5, saturatedFat:1.5, cholesterol:185, sodium:65, totalCarbs:0, protein:6)),

        // ── Whole Milk ───────────────────────────────────────────────────
        BrandEntry(brand: "Horizon Organic", itemName: "Whole Milk",
            nutrition: .init(servingSize:"1 cup (240ml)", calories:150, totalFat:8, saturatedFat:5, cholesterol:35, sodium:125, totalCarbs:12, totalSugars:12, protein:8, calcium:280)),
        BrandEntry(brand: "Organic Valley", itemName: "Whole Milk",
            nutrition: .init(servingSize:"1 cup (240ml)", calories:150, totalFat:8, saturatedFat:5, cholesterol:35, sodium:125, totalCarbs:12, totalSugars:12, protein:8, calcium:280)),

        // ── Butter ───────────────────────────────────────────────────────
        BrandEntry(brand: "Kerrygold", itemName: "Butter",
            nutrition: .init(servingSize:"1 tbsp (14g)", calories:100, totalFat:11, saturatedFat:7, cholesterol:30, sodium:90, totalCarbs:0, protein:0)),
        BrandEntry(brand: "Land O Lakes", itemName: "Butter",
            nutrition: .init(servingSize:"1 tbsp (14g)", calories:100, totalFat:11, saturatedFat:7, cholesterol:30, sodium:90, totalCarbs:0, protein:0)),
        BrandEntry(brand: "Breakstone's", itemName: "Butter",
            nutrition: .init(servingSize:"1 tbsp (14g)", calories:100, totalFat:11, saturatedFat:7, cholesterol:30, sodium:90, totalCarbs:0, protein:0)),

        // ── Cheddar Cheese ───────────────────────────────────────────────
        BrandEntry(brand: "Cabot", itemName: "Cheddar Cheese",
            nutrition: .init(servingSize:"1 oz (28g)", calories:110, totalFat:9, saturatedFat:6, cholesterol:30, sodium:180, totalCarbs:0, protein:7)),
        BrandEntry(brand: "Tillamook", itemName: "Cheddar Cheese",
            nutrition: .init(servingSize:"1 oz (28g)", calories:110, totalFat:9, saturatedFat:5, cholesterol:30, sodium:170, totalCarbs:0, protein:7)),

        // ── Greek Yogurt ─────────────────────────────────────────────────
        BrandEntry(brand: "Chobani", itemName: "Greek Yogurt",
            nutrition: .init(servingSize:"3/4 cup (170g)", calories:90, totalFat:0, saturatedFat:0, cholesterol:5, sodium:65, totalCarbs:6, totalSugars:5, protein:16)),
        BrandEntry(brand: "Fage", itemName: "Greek Yogurt",
            nutrition: .init(servingSize:"3/4 cup (170g)", calories:90, totalFat:0, saturatedFat:0, cholesterol:5, sodium:55, totalCarbs:6, totalSugars:5, protein:18)),
        BrandEntry(brand: "Stonyfield", itemName: "Greek Yogurt",
            nutrition: .init(servingSize:"3/4 cup (170g)", calories:90, totalFat:0, saturatedFat:0, cholesterol:5, sodium:65, totalCarbs:7, totalSugars:6, protein:15)),

        // ── Pasta ────────────────────────────────────────────────────────
        BrandEntry(brand: "Barilla", itemName: "Pasta",
            nutrition: .init(servingSize:"2 oz dry (56g)", calories:200, totalFat:1, saturatedFat:0, cholesterol:0, sodium:0, totalCarbs:42, dietaryFiber:2, totalSugars:2, protein:7)),
        BrandEntry(brand: "De Cecco", itemName: "Pasta",
            nutrition: .init(servingSize:"2 oz dry (56g)", calories:210, totalFat:1.5, saturatedFat:0, cholesterol:0, sodium:0, totalCarbs:42, dietaryFiber:2, totalSugars:1, protein:7)),

        // ── Spaghetti ────────────────────────────────────────────────────
        BrandEntry(brand: "Barilla", itemName: "Spaghetti",
            nutrition: .init(servingSize:"2 oz dry (56g)", calories:200, totalFat:1, saturatedFat:0, cholesterol:0, sodium:0, totalCarbs:42, dietaryFiber:2, protein:7)),

        // ── White Rice ───────────────────────────────────────────────────
        BrandEntry(brand: "Lundberg", itemName: "White Rice",
            nutrition: .init(servingSize:"1/4 cup dry (45g)", calories:160, totalFat:0, saturatedFat:0, cholesterol:0, sodium:0, totalCarbs:36, dietaryFiber:0, protein:3)),
        BrandEntry(brand: "Mahatma", itemName: "White Rice",
            nutrition: .init(servingSize:"1/4 cup dry (45g)", calories:160, totalFat:0, saturatedFat:0, cholesterol:0, sodium:0, totalCarbs:36, dietaryFiber:0, protein:3)),

        // ── Olive Oil ────────────────────────────────────────────────────
        BrandEntry(brand: "California Olive Ranch", itemName: "Olive Oil",
            nutrition: .init(servingSize:"1 tbsp (14g)", calories:120, totalFat:14, saturatedFat:2, cholesterol:0, sodium:0, totalCarbs:0, protein:0)),
        BrandEntry(brand: "Kirkland", itemName: "Olive Oil",
            nutrition: .init(servingSize:"1 tbsp (14g)", calories:120, totalFat:14, saturatedFat:2, cholesterol:0, sodium:0, totalCarbs:0, protein:0)),

        // ── Soy Sauce ────────────────────────────────────────────────────
        BrandEntry(brand: "Kikkoman", itemName: "Soy Sauce",
            nutrition: .init(servingSize:"1 tbsp (15ml)", calories:10, totalFat:0, saturatedFat:0, cholesterol:0, sodium:920, totalCarbs:1, totalSugars:0, protein:1)),
        BrandEntry(brand: "San-J", itemName: "Soy Sauce",
            nutrition: .init(servingSize:"1 tbsp (15ml)", calories:15, totalFat:0, saturatedFat:0, cholesterol:0, sodium:700, totalCarbs:2, protein:2)),

        // ── Tomato Sauce ─────────────────────────────────────────────────
        BrandEntry(brand: "Rao's", itemName: "Tomato Sauce",
            nutrition: .init(servingSize:"1/2 cup (125g)", calories:80, totalFat:5, saturatedFat:0.5, cholesterol:0, sodium:360, totalCarbs:8, totalSugars:4, protein:2)),
        BrandEntry(brand: "Prego", itemName: "Tomato Sauce",
            nutrition: .init(servingSize:"1/2 cup (125g)", calories:70, totalFat:1.5, saturatedFat:0, cholesterol:0, sodium:480, totalCarbs:13, totalSugars:9, protein:2)),

        // ── Chicken Broth ─────────────────────────────────────────────────
        BrandEntry(brand: "Swanson", itemName: "Chicken Broth",
            nutrition: .init(servingSize:"1 cup (240ml)", calories:10, totalFat:0, saturatedFat:0, cholesterol:0, sodium:860, totalCarbs:1, protein:1)),
        BrandEntry(brand: "Pacific Foods", itemName: "Chicken Broth",
            nutrition: .init(servingSize:"1 cup (240ml)", calories:15, totalFat:0, saturatedFat:0, cholesterol:5, sodium:570, totalCarbs:1, protein:2)),

        // ── Sriracha ─────────────────────────────────────────────────────
        BrandEntry(brand: "Huy Fong", itemName: "Sriracha",
            nutrition: .init(servingSize:"1 tsp (5g)", calories:5, totalFat:0, saturatedFat:0, cholesterol:0, sodium:100, totalCarbs:1, totalSugars:1, protein:0)),

        // ── Oats ─────────────────────────────────────────────────────────
        BrandEntry(brand: "Quaker", itemName: "Oats",
            nutrition: .init(servingSize:"1/2 cup dry (40g)", calories:150, totalFat:2.5, saturatedFat:0.5, cholesterol:0, sodium:0, totalCarbs:27, dietaryFiber:4, totalSugars:1, protein:5)),
        BrandEntry(brand: "Bob's Red Mill", itemName: "Oats",
            nutrition: .init(servingSize:"1/2 cup dry (40g)", calories:150, totalFat:2.5, saturatedFat:0.5, cholesterol:0, sodium:0, totalCarbs:27, dietaryFiber:4, totalSugars:1, protein:5)),

        // ── Peanut Butter ─────────────────────────────────────────────────
        BrandEntry(brand: "Jif", itemName: "Peanut Butter",
            nutrition: .init(servingSize:"2 tbsp (32g)", calories:190, totalFat:16, saturatedFat:3, cholesterol:0, sodium:140, totalCarbs:8, dietaryFiber:2, totalSugars:3, protein:7)),
        BrandEntry(brand: "Justin's", itemName: "Peanut Butter",
            nutrition: .init(servingSize:"2 tbsp (32g)", calories:190, totalFat:16, saturatedFat:3, cholesterol:0, sodium:80, totalCarbs:8, dietaryFiber:2, totalSugars:3, protein:7)),

        // ── Salmon ───────────────────────────────────────────────────────
        BrandEntry(brand: "Wild Planet", itemName: "Salmon",
            nutrition: .init(servingSize:"3 oz (85g)", calories:130, totalFat:5, saturatedFat:1, cholesterol:55, sodium:270, totalCarbs:0, protein:20)),
        BrandEntry(brand: "Kirkland Sockeye", itemName: "Salmon",
            nutrition: .init(servingSize:"3 oz (85g)", calories:140, totalFat:7, saturatedFat:1.5, cholesterol:60, sodium:280, totalCarbs:0, protein:19)),
    ]

    static func brands(for itemName: String) -> [BrandEntry] {
        let direct = all.filter { $0.itemName.lowercased() == itemName.lowercased() }
        // #7: Also pull brand info from ProductCatalog (avoids duplicate data)
        let fromCatalog = ProductCatalog.all
            .filter { $0.name.lowercased().contains(itemName.lowercased()) && !$0.brand.isEmpty }
            .map { e in BrandEntry(brand: e.brand, itemName: itemName) }
        let fromSharedCatalog = SharedGroceryCatalog.shared.brandNames(for: itemName)
            .map { BrandEntry(brand: $0, itemName: itemName) }
        let allBrands = direct + fromCatalog + fromSharedCatalog
        var seen = Set<String>()
        return allBrands.filter { seen.insert($0.brand.lowercased()).inserted }
    }
    static func allBrandNames(for itemName: String) -> [String] {
        brands(for: itemName).map(\.brand)
    }
    // Fuzzy suggestion — returns brand names even for partial matches
    static func suggestBrandNames(for itemName: String) -> [String] {
        let lower = itemName.lowercased()
        let exact = brands(for: itemName).map(\.brand)
        if !exact.isEmpty { return exact }
        let fuzzy = all.filter { $0.itemName.lowercased().contains(lower) || lower.contains($0.itemName.lowercased()) }
        return Array(Set(fuzzy.map(\.brand))).sorted()
    }

// ── Brand suggestions by category (for autocomplete, no nutrition data needed)
    static let suggestions: [String: [String]] = [
        "Olive Oil":       ["California Olive Ranch","Kirkland Signature","Lucini","Filippo Berio","Colavita","Bragg","Kosterina","Brightland"],
        "Pasta":           ["De Cecco","Barilla","Rustichella d'Abruzzo","Garofalo","Jovial","Banza","Tinkyada","Ancient Harvest"],
        "Canned Tomatoes": ["Muir Glen","Cento","San Marzano DOP","Hunt's","Pomi","Bianco DiNapoli","Nina"],
        "Soy Sauce":       ["Kikkoman","San-J","Bragg Liquid Aminos","Lee Kum Kee","Pearl River Bridge","Yamaroku","Wan Ja Shan"],
        "Hot Sauce":       ["Tabasco","Crystal","Cholula","Frank's RedHot","Valentina","Tapatío","Yucateco","Yellowbird"],
        "Butter":          ["Kerrygold","Plugrá","Président","Kate's Creamery","Land O'Lakes","Vermont Creamery","Finlandia"],
        "Greek Yogurt":    ["Fage","Chobani","Siggi's","Stonyfield","Dannon","Oikos","Two Good"],
        "Almond Milk":     ["Silk","Califia Farms","Elmhurst","Three Trees","Malk","Oatly","Ripple"],
        "Coconut Milk":    ["Thai Kitchen","Chaokoh","Aroy-D","365","So Delicious","Native Forest"],
        "Chicken Stock":   ["Swanson","Imagine","Kitchen Basics","Pacific Foods","Kettle & Fire","Better Than Bouillon"],
        "Chocolate":       ["Ghirardelli","Guittard","Valrhona","Lindt","Green & Black's","Scharffen Berger","Callebaut"],
        "Flour":           ["King Arthur","Bob's Red Mill","Gold Medal","Pillsbury","Arrowhead Mills","Anthony's"],
        "Rice":            ["Lundberg","Nishiki","Tamaki Gold","Kokuho Rose","Mahatma","Zatarain's"],
        "Vinegar":         ["Bragg","Spectrum","Pompeian","De Nigris","Roland","Acetum","Alessi"],
        "Mustard":         ["Grey Poupon","French's","Maille","Gulden's","Plochman's","Inglehoffer"],
        "Mayonnaise":      ["Hellmann's","Kewpie","Duke's","Best Foods","Sir Kensington's","Primal Kitchen"],
        "Honey":           ["Manuka Health","Nature Nate's","Mike's Hot Honey","Sioux Honey","Beekeeper's Naturals"],
        "Maple Syrup":     ["Coombs Family Farms","Crown Maple","Anderson's","Butternut Mountain Farm","Stonewall Kitchen"],
        "Salsa":           ["Green Mountain Gringo","Frontera","Desert Pepper","Tostitos","Newman's Own","Herdez"],
        "Beans":           ["Bush's","Goya","Eden Organic","S&W","La Preferida","Amy's"],
        "Chips":           ["Lay's","Kettle Brand","Late July","Siete","Cape Cod","Deep River","Popchips"],
        "Bread":           ["Dave's Killer Bread","Ezekiel","Arnold","Pepperidge Farm","Canyon Bakehouse","Udi's"],
        "Crackers":        ["Triscuit","Wheat Thins","RW Garcia","Simple Mills","Mary's Gone Crackers","Ak-Mak"],
        "Nut Butter":      ["Justin's","Smucker's Natural","Teddie","Once Again","Barney Butter","MaraNatha","Wild Friends"],
        "Spices":          ["Penzeys","Simply Organic","Burlap & Barrel","Diaspora Co.","La Boîte","Rancho Gordo"],
        "Ice Cream":       ["Häagen-Dazs","Ben & Jerry's","Talenti","Jeni's","Salt & Straw","Van Leeuwen"],
        "Sparkling Water": ["LaCroix","Spindrift","Topo Chico","Waterloo","Nixie","Bubly","Polar"],
        "Cheese":          ["Tillamook","Cabot","BelGioioso","Parmigiano Reggiano DOP","Gruyère AOP"],
        "Tomato Paste":    ["Muir Glen","Cento","Hunt's","Amore","Bionaturae"],
    ]

}
