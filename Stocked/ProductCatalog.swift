// ProductCatalog.swift — Branded product database for FoodPredictiveTextField,
// AddItemSheet, and receipt abbreviation lookup.
// Updated for IngredientDatabase integration — all entries use Fridge/Freezer/Pantry/Staples zones.

import Foundation

// MARK: - Catalog Entry
struct CatalogEntry {
    let name:     String
    let brand:    String
    let category: String   // matches StorageCategory.rawValue
    let emoji:    String
    var searchTerms: [String] { [name.lowercased(), brand.lowercased()] }
}

// MARK: - Product Catalog
struct ProductCatalog {
    // #14: O(1) lookup dictionary — keyed on normalised name
    static let lookup: [String: CatalogEntry] = {
        Dictionary(keepingLastValues: all.map { ($0.name.lowercased(), $0) })
    }()

    // Exact lookup (O(1))
    static func entry(for name: String) -> CatalogEntry? {
        lookup[name.lowercased()]
    }

    // Prefix/fuzzy search — only runs on the sorted keys array, not re-scanning all
    static let sortedNames: [String] = all.map { $0.name }.sorted()

    static func search(_ query: String, limit: Int = 8) -> [CatalogEntry] {
        let q = query.lowercased()
        let exact   = lookup[q].map { [$0] } ?? []
        let prefix  = sortedNames.filter { $0.lowercased().hasPrefix(q) && $0.lowercased() != q }
                                 .prefix(limit - exact.count)
                                 .compactMap { lookup[$0.lowercased()] }
        let contains = sortedNames.filter { $0.lowercased().contains(q) && !$0.lowercased().hasPrefix(q) }
                                  .prefix(limit - exact.count - prefix.count)
                                  .compactMap { lookup[$0.lowercased()] }
        return Array((exact + prefix + contains).prefix(limit))
    }

    static let all: [CatalogEntry] = chips + crackers + cookies + candy + chocolate
        + iceCream + frozenMeals + frozenBreakfast + frozenSnacks
        + drinks + energyDrinks + sportsDrinks + juice + coffee + tea
        + water + beer + wine + spirits
        + dairy + cheese + yogurt + eggs + butter
        + bread + bakery + cereal + oats
        + pasta + rice + grains
        + cannedGoods + soup + beans
        + condiments + sauces + oils + spices
        + meat + seafood + deli
        + produce + fruits + vegetables
        + snacks + nuts + protein
        + babyFood + petFood
        + hebBrands

    // MARK: H-E-B store brands (Texas) — helps recognize HEB-specific items when
    // scanning receipts or typing. Covers HEB's own labels: H-E-B, Hill Country Fare
    // (value), Central Market (premium), Creamy Creations (ice cream), Meal Simple
    // (prepared), Mootopia, and Texas-staple house items.
    static let hebBrands: [CatalogEntry] = [
        .init(name: "H-E-B Whole Milk",              brand: "H-E-B", category: "Fridge",  emoji: "🥛"),
        .init(name: "H-E-B 2% Milk",                 brand: "H-E-B", category: "Fridge",  emoji: "🥛"),
        .init(name: "Mootopia Lactose-Free Milk",    brand: "H-E-B", category: "Fridge",  emoji: "🥛"),
        .init(name: "H-E-B Large Eggs",              brand: "H-E-B", category: "Fridge",  emoji: "🥚"),
        .init(name: "H-E-B Unsalted Butter",         brand: "H-E-B", category: "Fridge",  emoji: "🧈"),
        .init(name: "H-E-B Shredded Cheddar",        brand: "H-E-B", category: "Fridge",  emoji: "🧀"),
        .init(name: "H-E-B Greek Yogurt",            brand: "H-E-B", category: "Fridge",  emoji: "🥛"),
        .init(name: "H-E-B Bakery Tortillas",        brand: "H-E-B", category: "Pantry",  emoji: "🫓"),
        .init(name: "H-E-B Mi Tienda Tortillas",     brand: "H-E-B", category: "Pantry",  emoji: "🫓"),
        .init(name: "H-E-B White Bread",             brand: "H-E-B", category: "Pantry",  emoji: "🍞"),
        .init(name: "Hill Country Fare Rice",        brand: "Hill Country Fare", category: "Pantry", emoji: "🍚"),
        .init(name: "Hill Country Fare Black Beans", brand: "Hill Country Fare", category: "Pantry", emoji: "🫘"),
        .init(name: "Hill Country Fare Flour",       brand: "Hill Country Fare", category: "Staples", emoji: "🌾"),
        .init(name: "H-E-B Olive Oil",               brand: "H-E-B", category: "Staples", emoji: "🫒"),
        .init(name: "H-E-B Taco Seasoning",          brand: "H-E-B", category: "Staples", emoji: "🌮"),
        .init(name: "H-E-B Salsa",                   brand: "H-E-B", category: "Staples", emoji: "🍅"),
        .init(name: "Creamy Creations Ice Cream",    brand: "H-E-B", category: "Freezer", emoji: "🍨"),
        .init(name: "H-E-B Frozen Pizza",            brand: "H-E-B", category: "Freezer", emoji: "🍕"),
        .init(name: "Meal Simple Rotisserie Chicken", brand: "H-E-B", category: "Fridge", emoji: "🍗"),
        .init(name: "Central Market Organic Spinach", brand: "Central Market", category: "Fridge", emoji: "🥬"),
        .init(name: "H-E-B Sparkling Water",         brand: "H-E-B", category: "Pantry",  emoji: "🥤"),
        .init(name: "H-E-B Ground Coffee",           brand: "H-E-B", category: "Pantry",  emoji: "☕"),
        .init(name: "H-E-B Tortilla Chips",          brand: "H-E-B", category: "Pantry",  emoji: "🌽"),
    ]

    // MARK: Chips & Salty Snacks
    static let chips: [CatalogEntry] = [
        .init(name: "Lay's Classic",             brand: "Lay's",    category: "Pantry", emoji: "🥔"),
        .init(name: "Lay's Sour Cream & Onion",  brand: "Lay's",    category: "Pantry", emoji: "🥔"),
        .init(name: "Lay's Barbecue",            brand: "Lay's",    category: "Pantry", emoji: "🥔"),
        .init(name: "Lay's Salt & Vinegar",      brand: "Lay's",    category: "Pantry", emoji: "🥔"),
        .init(name: "Lay's Kettle Cooked",       brand: "Lay's",    category: "Pantry", emoji: "🥔"),
        .init(name: "Pringles Original",         brand: "Pringles", category: "Pantry", emoji: "🥔"),
        .init(name: "Pringles Sour Cream & Onion", brand: "Pringles", category: "Pantry", emoji: "🥔"),
        .init(name: "Pringles BBQ",              brand: "Pringles", category: "Pantry", emoji: "🥔"),
        .init(name: "Pringles Cheddar",          brand: "Pringles", category: "Pantry", emoji: "🥔"),
        .init(name: "Pringles Pizza",            brand: "Pringles", category: "Pantry", emoji: "🥔"),
        .init(name: "Pringles Ranch",            brand: "Pringles", category: "Pantry", emoji: "🥔"),
        .init(name: "Cheetos Original",          brand: "Cheetos",  category: "Pantry", emoji: "🧀"),
        .init(name: "Cheetos Flamin' Hot",       brand: "Cheetos",  category: "Pantry", emoji: "🔥"),
        .init(name: "Cheetos Puffs",             brand: "Cheetos",  category: "Pantry", emoji: "🧀"),
        .init(name: "Flamin' Hot Cheetos",       brand: "Cheetos",  category: "Pantry", emoji: "🔥"),
        .init(name: "Cheetos Crunchy XXtra Flamin' Hot", brand: "Cheetos", category: "Pantry", emoji: "🔥"),
        .init(name: "Doritos Nacho Cheese",      brand: "Doritos",  category: "Pantry", emoji: "🌽"),
        .init(name: "Doritos Cool Ranch",        brand: "Doritos",  category: "Pantry", emoji: "🌽"),
        .init(name: "Doritos Spicy Nacho",       brand: "Doritos",  category: "Pantry", emoji: "🌶️"),
        .init(name: "Doritos Flamin' Hot Nacho", brand: "Doritos",  category: "Pantry", emoji: "🔥"),
        .init(name: "Doritos Dinamita",          brand: "Doritos",  category: "Pantry", emoji: "💥"),
        .init(name: "Ruffles Original",          brand: "Ruffles",  category: "Pantry", emoji: "🥔"),
        .init(name: "Ruffles Cheddar & Sour Cream", brand: "Ruffles", category: "Pantry", emoji: "🥔"),
        .init(name: "Funyuns",                   brand: "Funyuns",  category: "Pantry", emoji: "🧅"),
        .init(name: "Sun Chips Original",        brand: "Sun Chips", category: "Pantry", emoji: "🌻"),
        .init(name: "Sun Chips Garden Salsa",    brand: "Sun Chips", category: "Pantry", emoji: "🌻"),
        .init(name: "Fritos Original",           brand: "Fritos",   category: "Pantry", emoji: "🌽"),
        .init(name: "Fritos Chili Cheese",       brand: "Fritos",   category: "Pantry", emoji: "🌽"),
        .init(name: "Takis Fuego",               brand: "Takis",    category: "Pantry", emoji: "🔥"),
        .init(name: "Takis Blue Heat",           brand: "Takis",    category: "Pantry", emoji: "🌊"),
        .init(name: "Takis Nitro",               brand: "Takis",    category: "Pantry", emoji: "🔥"),
        .init(name: "Popcorners",                brand: "Popcorners", category: "Pantry", emoji: "🍿"),
        .init(name: "Smartfood Popcorn",         brand: "Smartfood", category: "Pantry", emoji: "🍿"),
        .init(name: "Act II Popcorn",            brand: "Act II",   category: "Pantry", emoji: "🍿"),
        .init(name: "Orville Redenbacher Popcorn", brand: "Orville Redenbacher", category: "Pantry", emoji: "🍿"),
        .init(name: "Kettle Brand Chips",        brand: "Kettle",   category: "Pantry", emoji: "🥔"),
        .init(name: "Cape Cod Chips",            brand: "Cape Cod", category: "Pantry", emoji: "🥔"),
        .init(name: "Stacy's Pita Chips",        brand: "Stacy's",  category: "Pantry", emoji: "🫓"),
        .init(name: "Turbos Flamas",             brand: "Turbos",   category: "Pantry", emoji: "🔥"),
        .init(name: "Miss Vickie's Chips",       brand: "Miss Vickie's", category: "Pantry", emoji: "🥔"),
    ]

    // MARK: Crackers
    static let crackers: [CatalogEntry] = [
        .init(name: "Ritz Crackers",             brand: "Ritz",     category: "Pantry", emoji: "🫓"),
        .init(name: "Ritz Bits Cheese",          brand: "Ritz",     category: "Pantry", emoji: "🫓"),
        .init(name: "Cheez-It Original",         brand: "Cheez-It", category: "Pantry", emoji: "🧀"),
        .init(name: "Cheez-It White Cheddar",    brand: "Cheez-It", category: "Pantry", emoji: "🧀"),
        .init(name: "Cheez-It Extra Toasty",     brand: "Cheez-It", category: "Pantry", emoji: "🧀"),
        .init(name: "Goldfish Crackers",         brand: "Pepperidge Farm", category: "Pantry", emoji: "🐟"),
        .init(name: "Goldfish Flavor Blasted",   brand: "Pepperidge Farm", category: "Pantry", emoji: "🐟"),
        .init(name: "Triscuit Original",         brand: "Triscuit", category: "Pantry", emoji: "🫓"),
        .init(name: "Wheat Thins",               brand: "Nabisco",  category: "Pantry", emoji: "🫓"),
        .init(name: "Club Crackers",             brand: "Keebler",  category: "Pantry", emoji: "🫓"),
        .init(name: "Saltine Crackers",          brand: "Nabisco",  category: "Pantry", emoji: "🫓"),
        .init(name: "Graham Crackers",           brand: "Nabisco",  category: "Pantry", emoji: "🫓"),
        .init(name: "Animal Crackers",           brand: "Nabisco",  category: "Pantry", emoji: "🐘"),
    ]

    // MARK: Cookies
    static let cookies: [CatalogEntry] = [
        .init(name: "Oreo Original",             brand: "Oreo",     category: "Pantry", emoji: "🍪"),
        .init(name: "Oreo Double Stuf",          brand: "Oreo",     category: "Pantry", emoji: "🍪"),
        .init(name: "Oreo Golden",               brand: "Oreo",     category: "Pantry", emoji: "🍪"),
        .init(name: "Oreo Mint",                 brand: "Oreo",     category: "Pantry", emoji: "🍪"),
        .init(name: "Oreo Thins",                brand: "Oreo",     category: "Pantry", emoji: "🍪"),
        .init(name: "Chips Ahoy Original",       brand: "Chips Ahoy", category: "Pantry", emoji: "🍪"),
        .init(name: "Chips Ahoy Chewy",          brand: "Chips Ahoy", category: "Pantry", emoji: "🍪"),
        .init(name: "Chips Ahoy Chunky",         brand: "Chips Ahoy", category: "Pantry", emoji: "🍪"),
        .init(name: "Pepperidge Farm Milano",    brand: "Pepperidge Farm", category: "Pantry", emoji: "🍪"),
        .init(name: "Nutter Butter",             brand: "Nabisco",  category: "Pantry", emoji: "🥜"),
        .init(name: "Lorna Doone",               brand: "Nabisco",  category: "Pantry", emoji: "🍪"),
        .init(name: "Famous Amos",               brand: "Famous Amos", category: "Pantry", emoji: "🍪"),
        .init(name: "Keebler Fudge Stripes",     brand: "Keebler",  category: "Pantry", emoji: "🍪"),
        .init(name: "Thin Mints",                brand: "Girl Scouts", category: "Pantry", emoji: "🍪"),
        .init(name: "Samoas",                    brand: "Girl Scouts", category: "Pantry", emoji: "🍪"),
        .init(name: "Biscoff Cookies",           brand: "Lotus",    category: "Pantry", emoji: "🍪"),
        .init(name: "Snickerdoodle Cookies",     brand: "Pepperidge Farm", category: "Pantry", emoji: "🍪"),
    ]

    // MARK: Candy & Chocolate
    static let candy: [CatalogEntry] = [
        .init(name: "Skittles Original",         brand: "Skittles", category: "Pantry", emoji: "🌈"),
        .init(name: "Skittles Wild Berry",       brand: "Skittles", category: "Pantry", emoji: "🍇"),
        .init(name: "Skittles Sour",             brand: "Skittles", category: "Pantry", emoji: "🍋"),
        .init(name: "Starburst Original",        brand: "Starburst", category: "Pantry", emoji: "⭐"),
        .init(name: "Starburst FaveREDs",        brand: "Starburst", category: "Pantry", emoji: "❤️"),
        .init(name: "Jolly Ranchers",            brand: "Jolly Rancher", category: "Pantry", emoji: "🍬"),
        .init(name: "Sour Patch Kids",           brand: "Mondelez", category: "Pantry", emoji: "🍋"),
        .init(name: "Sour Patch Watermelon",     brand: "Mondelez", category: "Pantry", emoji: "🍉"),
        .init(name: "Airheads",                  brand: "Airheads", category: "Pantry", emoji: "🍬"),
        .init(name: "Swedish Fish",              brand: "Mondelez", category: "Pantry", emoji: "🐟"),
        .init(name: "Haribo Gold Bears",         brand: "Haribo",   category: "Pantry", emoji: "🐻"),
        .init(name: "Mike and Ike",              brand: "Mike and Ike", category: "Pantry", emoji: "🍬"),
        .init(name: "Twizzlers",                 brand: "Twizzlers", category: "Pantry", emoji: "🍬"),
        .init(name: "Red Vines",                 brand: "Red Vines", category: "Pantry", emoji: "🍬"),
        .init(name: "Nerds",                     brand: "Nerds",    category: "Pantry", emoji: "🍬"),
        .init(name: "Nerds Rope",                brand: "Nerds",    category: "Pantry", emoji: "🍬"),
        .init(name: "Laffy Taffy",               brand: "Laffy Taffy", category: "Pantry", emoji: "🍬"),
        .init(name: "Warheads",                  brand: "Warheads", category: "Pantry", emoji: "🍬"),
        .init(name: "Ring Pops",                 brand: "Ring Pop", category: "Pantry", emoji: "💍"),
        .init(name: "Fun Dip",                   brand: "Fun Dip",  category: "Pantry", emoji: "🍬"),
    ]

    static let chocolate: [CatalogEntry] = [
        .init(name: "Snickers",                  brand: "Mars",     category: "Pantry", emoji: "🍫"),
        .init(name: "Twix",                      brand: "Mars",     category: "Pantry", emoji: "🍫"),
        .init(name: "M&Ms Milk Chocolate",       brand: "M&M's",    category: "Pantry", emoji: "🍫"),
        .init(name: "M&Ms Peanut",               brand: "M&M's",    category: "Pantry", emoji: "🍫"),
        .init(name: "M&Ms Peanut Butter",        brand: "M&M's",    category: "Pantry", emoji: "🍫"),
        .init(name: "M&Ms Crispy",               brand: "M&M's",    category: "Pantry", emoji: "🍫"),
        .init(name: "Reese's Peanut Butter Cups", brand: "Reese's", category: "Pantry", emoji: "🍫"),
        .init(name: "Reese's Pieces",            brand: "Reese's",  category: "Pantry", emoji: "🍫"),
        .init(name: "Kit Kat",                   brand: "Hershey's", category: "Pantry", emoji: "🍫"),
        .init(name: "Hershey's Milk Chocolate",  brand: "Hershey's", category: "Pantry", emoji: "🍫"),
        .init(name: "Hershey's Kisses",          brand: "Hershey's", category: "Pantry", emoji: "🍫"),
        .init(name: "Milky Way",                 brand: "Mars",     category: "Pantry", emoji: "🍫"),
        .init(name: "3 Musketeers",              brand: "Mars",     category: "Pantry", emoji: "🍫"),
        .init(name: "Butterfinger",              brand: "Nestlé",   category: "Pantry", emoji: "🍫"),
        .init(name: "Baby Ruth",                 brand: "Nestlé",   category: "Pantry", emoji: "🍫"),
        .init(name: "Crunch Bar",                brand: "Nestlé",   category: "Pantry", emoji: "🍫"),
        .init(name: "PayDay",                    brand: "Hershey's", category: "Pantry", emoji: "🍫"),
        .init(name: "Almond Joy",                brand: "Hershey's", category: "Pantry", emoji: "🍫"),
        .init(name: "Mounds",                    brand: "Hershey's", category: "Pantry", emoji: "🍫"),
        .init(name: "Toblerone",                 brand: "Toblerone", category: "Pantry", emoji: "🍫"),
        .init(name: "Lindt Milk Chocolate",      brand: "Lindt",    category: "Pantry", emoji: "🍫"),
        .init(name: "Ghirardelli Dark Chocolate", brand: "Ghirardelli", category: "Pantry", emoji: "🍫"),
        .init(name: "Dove Chocolate",            brand: "Dove",     category: "Pantry", emoji: "🍫"),
        .init(name: "Ferrero Rocher",            brand: "Ferrero",  category: "Pantry", emoji: "🍫"),
        .init(name: "Kinder Bueno",              brand: "Kinder",   category: "Pantry", emoji: "🍫"),
    ]

    // MARK: Ice Cream
    static let iceCream: [CatalogEntry] = [
        .init(name: "Ben & Jerry's Chocolate Chip Cookie Dough", brand: "Ben & Jerry's", category: "Freezer", emoji: "🍦"),
        .init(name: "Ben & Jerry's Cherry Garcia",  brand: "Ben & Jerry's", category: "Freezer", emoji: "🍒"),
        .init(name: "Ben & Jerry's Half Baked",     brand: "Ben & Jerry's", category: "Freezer", emoji: "🍦"),
        .init(name: "Ben & Jerry's Tonight Dough",  brand: "Ben & Jerry's", category: "Freezer", emoji: "🍦"),
        .init(name: "Häagen-Dazs Vanilla",          brand: "Häagen-Dazs",  category: "Freezer", emoji: "🍦"),
        .init(name: "Häagen-Dazs Strawberry",       brand: "Häagen-Dazs",  category: "Freezer", emoji: "🍓"),
        .init(name: "Häagen-Dazs Coffee",           brand: "Häagen-Dazs",  category: "Freezer", emoji: "☕"),
        .init(name: "Breyers Natural Vanilla",       brand: "Breyers",      category: "Freezer", emoji: "🍦"),
        .init(name: "Breyers Mint Chip",             brand: "Breyers",      category: "Freezer", emoji: "🍦"),
        .init(name: "Tillamook Mudslide",            brand: "Tillamook",    category: "Freezer", emoji: "🍦"),
        .init(name: "Blue Bell Homemade Vanilla",    brand: "Blue Bell",    category: "Freezer", emoji: "🍦"),
        .init(name: "Talenti Gelato",                brand: "Talenti",      category: "Freezer", emoji: "🍦"),
        .init(name: "Drumstick Vanilla",             brand: "Nestlé",       category: "Freezer", emoji: "🍦"),
        .init(name: "Klondike Bar",                  brand: "Klondike",     category: "Freezer", emoji: "🍦"),
        .init(name: "Magnum Ice Cream Bar",          brand: "Magnum",       category: "Freezer", emoji: "🍫"),
        .init(name: "Popsicle",                      brand: "Popsicle",     category: "Freezer", emoji: "🍭"),
        .init(name: "Outshine Fruit Bars",           brand: "Outshine",     category: "Freezer", emoji: "🍓"),
        .init(name: "Skinny Cow",                    brand: "Skinny Cow",   category: "Freezer", emoji: "🍦"),
    ]

    // MARK: Frozen Meals
    static let frozenMeals: [CatalogEntry] = [
        .init(name: "Stouffer's Lasagna",            brand: "Stouffer's",   category: "Freezer", emoji: "🍝"),
        .init(name: "Stouffer's Mac & Cheese",       brand: "Stouffer's",   category: "Freezer", emoji: "🧀"),
        .init(name: "Lean Cuisine Chicken",          brand: "Lean Cuisine", category: "Freezer", emoji: "🍗"),
        .init(name: "Healthy Choice Cafe Steamers",  brand: "Healthy Choice", category: "Freezer", emoji: "🍱"),
        .init(name: "Amy's Burrito",                 brand: "Amy's",        category: "Freezer", emoji: "🌯"),
        .init(name: "Amy's Bowl",                    brand: "Amy's",        category: "Freezer", emoji: "🥣"),
        .init(name: "Marie Callender's Pot Pie",     brand: "Marie Callender's", category: "Freezer", emoji: "🥧"),
        .init(name: "Banquet Pot Pie",               brand: "Banquet",      category: "Freezer", emoji: "🥧"),
        .init(name: "Birds Eye Protein Bowl",        brand: "Birds Eye",    category: "Freezer", emoji: "🥦"),
        .init(name: "Trader Joe's Mandarin Orange Chicken", brand: "Trader Joe's", category: "Freezer", emoji: "🍊"),
        .init(name: "P.F. Chang's Frozen",          brand: "P.F. Chang's", category: "Freezer", emoji: "🥡"),
        .init(name: "Digiorno Pizza",                brand: "DiGiorno",     category: "Freezer", emoji: "🍕"),
        .init(name: "Red Baron Pizza",               brand: "Red Baron",    category: "Freezer", emoji: "🍕"),
        .init(name: "Totino's Pizza Rolls",          brand: "Totino's",     category: "Freezer", emoji: "🍕"),
        .init(name: "Hot Pockets",                   brand: "Hot Pockets",  category: "Freezer", emoji: "🌯"),
    ]

    static let frozenBreakfast: [CatalogEntry] = [
        .init(name: "Eggo Waffles",                  brand: "Eggo",        category: "Freezer", emoji: "🧇"),
        .init(name: "Eggo Blueberry Waffles",        brand: "Eggo",        category: "Freezer", emoji: "🫐"),
        .init(name: "Jimmy Dean Sausage Biscuit",    brand: "Jimmy Dean",   category: "Freezer", emoji: "🥪"),
        .init(name: "Jimmy Dean Breakfast Bowl",     brand: "Jimmy Dean",   category: "Freezer", emoji: "🥣"),
        .init(name: "Bob Evans Breakfast Bowl",      brand: "Bob Evans",    category: "Freezer", emoji: "🥣"),
        .init(name: "Pillsbury Pancakes",            brand: "Pillsbury",    category: "Freezer", emoji: "🥞"),
    ]

    static let frozenSnacks: [CatalogEntry] = [
        .init(name: "Bagel Bites",                   brand: "Bagel Bites",  category: "Freezer", emoji: "🥯"),
        .init(name: "TGI Fridays Mozzarella Sticks", brand: "TGI Fridays",  category: "Freezer", emoji: "🧀"),
        .init(name: "Farm Rich Mozzarella Sticks",   brand: "Farm Rich",    category: "Freezer", emoji: "🧀"),
        .init(name: "Ore-Ida French Fries",          brand: "Ore-Ida",      category: "Freezer", emoji: "🍟"),
        .init(name: "Alexia Sweet Potato Fries",     brand: "Alexia",       category: "Freezer", emoji: "🍠"),
    ]

    // MARK: Drinks — Soda
    static let drinks: [CatalogEntry] = [
        .init(name: "Coca-Cola",                     brand: "Coca-Cola",    category: "Pantry",  emoji: "🥤"),
        .init(name: "Coke Zero",                     brand: "Coca-Cola",    category: "Pantry",  emoji: "🥤"),
        .init(name: "Diet Coke",                     brand: "Coca-Cola",    category: "Pantry",  emoji: "🥤"),
        .init(name: "Coca-Cola Cherry",              brand: "Coca-Cola",    category: "Pantry",  emoji: "🍒"),
        .init(name: "Sprite",                        brand: "Coca-Cola",    category: "Pantry",  emoji: "🥤"),
        .init(name: "Sprite Zero",                   brand: "Coca-Cola",    category: "Pantry",  emoji: "🥤"),
        .init(name: "Fanta Orange",                  brand: "Coca-Cola",    category: "Pantry",  emoji: "🍊"),
        .init(name: "Fanta Grape",                   brand: "Coca-Cola",    category: "Pantry",  emoji: "🍇"),
        .init(name: "Pibb Xtra",                     brand: "Coca-Cola",    category: "Pantry",  emoji: "🥤"),
        .init(name: "Barq's Root Beer",              brand: "Coca-Cola",    category: "Pantry",  emoji: "🥤"),
        .init(name: "Minute Maid Lemonade",          brand: "Minute Maid",  category: "Pantry",  emoji: "🍋"),
        .init(name: "Pepsi",                         brand: "PepsiCo",      category: "Pantry",  emoji: "🥤"),
        .init(name: "Pepsi Zero Sugar",              brand: "PepsiCo",      category: "Pantry",  emoji: "🥤"),
        .init(name: "Diet Pepsi",                    brand: "PepsiCo",      category: "Pantry",  emoji: "🥤"),
        .init(name: "Pepsi Wild Cherry",             brand: "PepsiCo",      category: "Pantry",  emoji: "🍒"),
        .init(name: "Mountain Dew",                  brand: "PepsiCo",      category: "Pantry",  emoji: "🥤"),
        .init(name: "Mountain Dew Zero",             brand: "PepsiCo",      category: "Pantry",  emoji: "🥤"),
        .init(name: "Mountain Dew Baja Blast",       brand: "PepsiCo",      category: "Pantry",  emoji: "🌊"),
        .init(name: "Mountain Dew Code Red",         brand: "PepsiCo",      category: "Pantry",  emoji: "🔴"),
        .init(name: "Dr Pepper",                     brand: "Keurig Dr Pepper", category: "Pantry", emoji: "🥤"),
        .init(name: "Dr Pepper Zero",               brand: "Keurig Dr Pepper", category: "Pantry", emoji: "🥤"),
        .init(name: "7UP",                           brand: "Keurig Dr Pepper", category: "Pantry", emoji: "🥤"),
        .init(name: "A&W Root Beer",                 brand: "Keurig Dr Pepper", category: "Pantry", emoji: "🥤"),
        .init(name: "Canada Dry Ginger Ale",         brand: "Keurig Dr Pepper", category: "Pantry", emoji: "🥤"),
        .init(name: "Crush Orange",                  brand: "Keurig Dr Pepper", category: "Pantry", emoji: "🍊"),
        .init(name: "Sunkist Orange",                brand: "Keurig Dr Pepper", category: "Pantry", emoji: "🍊"),
        .init(name: "Jarritos Mandarin",             brand: "Jarritos",     category: "Pantry",  emoji: "🍊"),
        .init(name: "Jarritos Tamarind",             brand: "Jarritos",     category: "Pantry",  emoji: "🥤"),
        .init(name: "Jarritos Lime",                 brand: "Jarritos",     category: "Pantry",  emoji: "🍋"),
        .init(name: "Topo Chico Sparkling Water",    brand: "Topo Chico",   category: "Fridge",  emoji: "💧"),
        .init(name: "LaCroix Sparkling Water",       brand: "LaCroix",      category: "Fridge",  emoji: "💧"),
        .init(name: "Bubly Sparkling Water",         brand: "Bubly",        category: "Fridge",  emoji: "💧"),
        .init(name: "Perrier Sparkling Water",       brand: "Perrier",      category: "Fridge",  emoji: "💧"),
        .init(name: "San Pellegrino",               brand: "San Pellegrino", category: "Fridge",  emoji: "💧"),
    ]

    static let energyDrinks: [CatalogEntry] = [
        .init(name: "Red Bull",                      brand: "Red Bull",     category: "Fridge",  emoji: "⚡"),
        .init(name: "Red Bull Sugar Free",           brand: "Red Bull",     category: "Fridge",  emoji: "⚡"),
        .init(name: "Monster Energy Original",       brand: "Monster",      category: "Fridge",  emoji: "🟢"),
        .init(name: "Monster Ultra Zero",            brand: "Monster",      category: "Fridge",  emoji: "🟢"),
        .init(name: "Monster Assault",               brand: "Monster",      category: "Fridge",  emoji: "🟢"),
        .init(name: "Bang Energy",                   brand: "Bang",         category: "Fridge",  emoji: "💥"),
        .init(name: "Celsius Energy",                brand: "Celsius",      category: "Fridge",  emoji: "🌡️"),
        .init(name: "Reign Energy",                  brand: "Reign",        category: "Fridge",  emoji: "👑"),
        .init(name: "Rockstar Energy",               brand: "Rockstar",     category: "Fridge",  emoji: "⭐"),
        .init(name: "5-hour Energy",                 brand: "5-hour Energy", category: "Pantry", emoji: "⚡"),
        .init(name: "NOS Energy",                    brand: "NOS",          category: "Fridge",  emoji: "⚡"),
        .init(name: "Ghost Energy",                  brand: "Ghost",        category: "Fridge",  emoji: "👻"),
        .init(name: "Prime Energy",                  brand: "Prime",        category: "Fridge",  emoji: "⚡"),
        .init(name: "Prime Hydration",               brand: "Prime",        category: "Fridge",  emoji: "💧"),
        .init(name: "G Fuel",                        brand: "G Fuel",       category: "Pantry",  emoji: "🎮"),
    ]

    static let sportsDrinks: [CatalogEntry] = [
        .init(name: "Gatorade Lemon-Lime",           brand: "Gatorade",     category: "Fridge",  emoji: "🏃"),
        .init(name: "Gatorade Orange",               brand: "Gatorade",     category: "Fridge",  emoji: "🍊"),
        .init(name: "Gatorade Fruit Punch",          brand: "Gatorade",     category: "Fridge",  emoji: "🍓"),
        .init(name: "Gatorade Cool Blue",            brand: "Gatorade",     category: "Fridge",  emoji: "💧"),
        .init(name: "Gatorade Zero",                 brand: "Gatorade",     category: "Fridge",  emoji: "🏃"),
        .init(name: "Powerade Mountain Berry Blast", brand: "Powerade",     category: "Fridge",  emoji: "🏃"),
        .init(name: "Powerade Zero",                 brand: "Powerade",     category: "Fridge",  emoji: "🏃"),
        .init(name: "BodyArmor Lyte",                brand: "BodyArmor",    category: "Fridge",  emoji: "💪"),
        .init(name: "Liquid I.V.",                   brand: "Liquid I.V.",  category: "Pantry",  emoji: "💧"),
        .init(name: "Pedialyte",                     brand: "Abbott",       category: "Pantry",  emoji: "💊"),
    ]

    static let juice: [CatalogEntry] = [
        .init(name: "Tropicana Orange Juice",        brand: "Tropicana",    category: "Fridge",  emoji: "🍊"),
        .init(name: "Simply Orange",                 brand: "Simply",       category: "Fridge",  emoji: "🍊"),
        .init(name: "Simply Lemonade",               brand: "Simply",       category: "Fridge",  emoji: "🍋"),
        .init(name: "Minute Maid Orange Juice",      brand: "Minute Maid",  category: "Fridge",  emoji: "🍊"),
        .init(name: "Ocean Spray Cranberry",         brand: "Ocean Spray",  category: "Pantry",  emoji: "🍒"),
        .init(name: "Welch's Grape Juice",           brand: "Welch's",      category: "Pantry",  emoji: "🍇"),
        .init(name: "V8 Vegetable Juice",            brand: "V8",           category: "Pantry",  emoji: "🍅"),
        .init(name: "Naked Juice Green Machine",     brand: "Naked",        category: "Fridge",  emoji: "🥝"),
        .init(name: "Bolthouse Farms",               brand: "Bolthouse",    category: "Fridge",  emoji: "🥕"),
        .init(name: "Capri Sun",                     brand: "Capri Sun",    category: "Pantry",  emoji: "🍹"),
        .init(name: "Kool-Aid Jammers",              brand: "Kool-Aid",     category: "Pantry",  emoji: "🍹"),
        .init(name: "Juicy Juice",                   brand: "Juicy Juice",  category: "Pantry",  emoji: "🍎"),
        .init(name: "Apple & Eve Juice Box",         brand: "Apple & Eve",  category: "Pantry",  emoji: "🍎"),
    ]

    static let coffee: [CatalogEntry] = [
        .init(name: "Starbucks Cold Brew",           brand: "Starbucks",    category: "Fridge",  emoji: "☕"),
        .init(name: "Starbucks Frappuccino",         brand: "Starbucks",    category: "Fridge",  emoji: "☕"),
        .init(name: "Starbucks Doubleshot",          brand: "Starbucks",    category: "Fridge",  emoji: "☕"),
        .init(name: "Dunkin' Iced Coffee",           brand: "Dunkin'",      category: "Fridge",  emoji: "☕"),
        .init(name: "La Colombe Draft Latte",        brand: "La Colombe",   category: "Fridge",  emoji: "☕"),
        .init(name: "Folgers Classic Roast",         brand: "Folgers",      category: "Pantry",  emoji: "☕"),
        .init(name: "Maxwell House Original",        brand: "Maxwell House", category: "Pantry", emoji: "☕"),
        .init(name: "Cafe Bustelo",                  brand: "Cafe Bustelo", category: "Pantry",  emoji: "☕"),
        .init(name: "Death Wish Coffee",             brand: "Death Wish",   category: "Pantry",  emoji: "☕"),
        .init(name: "Community Coffee",              brand: "Community",    category: "Pantry",  emoji: "☕"),
        .init(name: "HEB Cafe Ole",                  brand: "HEB",          category: "Pantry",  emoji: "☕"),
        .init(name: "Keurig K-Cup Variety Pack",     brand: "Keurig",       category: "Pantry",  emoji: "☕"),
        .init(name: "Nescafe Clasico",               brand: "Nescafe",      category: "Pantry",  emoji: "☕"),
    ]

    static let tea: [CatalogEntry] = [
        .init(name: "Lipton Iced Tea",               brand: "Lipton",       category: "Pantry",  emoji: "🍵"),
        .init(name: "Arizona Iced Tea",              brand: "Arizona",      category: "Pantry",  emoji: "🍵"),
        .init(name: "Snapple Peach Tea",             brand: "Snapple",      category: "Fridge",  emoji: "🍑"),
        .init(name: "Gold Peak Sweet Tea",           brand: "Gold Peak",    category: "Fridge",  emoji: "🍵"),
        .init(name: "Pure Leaf Unsweetened",         brand: "Pure Leaf",    category: "Fridge",  emoji: "🍵"),
        .init(name: "Celestial Seasonings",          brand: "Celestial",    category: "Pantry",  emoji: "🍵"),
        .init(name: "Tazo Tea",                      brand: "Tazo",         category: "Pantry",  emoji: "🍵"),
        .init(name: "Bigelow Green Tea",             brand: "Bigelow",      category: "Pantry",  emoji: "🍵"),
        .init(name: "Twinings Earl Grey",            brand: "Twinings",     category: "Pantry",  emoji: "🍵"),
        .init(name: "Yogi Tea",                      brand: "Yogi",         category: "Pantry",  emoji: "🍵"),
        .init(name: "GT's Kombucha",                 brand: "GT's",         category: "Fridge",  emoji: "🫙"),
        .init(name: "Health-Ade Kombucha",           brand: "Health-Ade",   category: "Fridge",  emoji: "🫙"),
    ]

    static let water: [CatalogEntry] = [
        .init(name: "Dasani Water",                  brand: "Dasani",       category: "Pantry",  emoji: "💧"),
        .init(name: "Aquafina Water",                brand: "Aquafina",     category: "Pantry",  emoji: "💧"),
        .init(name: "Evian Water",                   brand: "Evian",        category: "Pantry",  emoji: "💧"),
        .init(name: "FIJI Water",                    brand: "FIJI",         category: "Pantry",  emoji: "💧"),
        .init(name: "Smartwater",                    brand: "Smartwater",   category: "Pantry",  emoji: "💧"),
        .init(name: "Poland Spring",                 brand: "Poland Spring", category: "Pantry", emoji: "💧"),
        .init(name: "Deer Park Water",               brand: "Deer Park",    category: "Pantry",  emoji: "💧"),
        .init(name: "Essentia Water",                brand: "Essentia",     category: "Pantry",  emoji: "💧"),
        .init(name: "alkaline88",                    brand: "alkaline88",   category: "Pantry",  emoji: "💧"),
    ]

    static let beer: [CatalogEntry] = [
        .init(name: "Bud Light",                     brand: "Anheuser-Busch", category: "Fridge", emoji: "🍺"),
        .init(name: "Budweiser",                     brand: "Anheuser-Busch", category: "Fridge", emoji: "🍺"),
        .init(name: "Michelob Ultra",                brand: "Anheuser-Busch", category: "Fridge", emoji: "🍺"),
        .init(name: "Miller Lite",                   brand: "Miller",       category: "Fridge",  emoji: "🍺"),
        .init(name: "Coors Light",                   brand: "Coors",        category: "Fridge",  emoji: "🍺"),
        .init(name: "Corona Extra",                  brand: "Corona",       category: "Fridge",  emoji: "🍺"),
        .init(name: "Modelo Especial",               brand: "Modelo",       category: "Fridge",  emoji: "🍺"),
        .init(name: "Dos Equis Lager",               brand: "Dos Equis",    category: "Fridge",  emoji: "🍺"),
        .init(name: "Heineken",                      brand: "Heineken",     category: "Fridge",  emoji: "🍺"),
        .init(name: "Stella Artois",                 brand: "Stella",       category: "Fridge",  emoji: "🍺"),
        .init(name: "Blue Moon",                     brand: "Blue Moon",    category: "Fridge",  emoji: "🌙"),
        .init(name: "Guinness Draught",              brand: "Guinness",     category: "Fridge",  emoji: "🍺"),
        .init(name: "White Claw Hard Seltzer",       brand: "White Claw",   category: "Fridge",  emoji: "🌊"),
        .init(name: "Truly Hard Seltzer",            brand: "Truly",        category: "Fridge",  emoji: "🌊"),
        .init(name: "Twisted Tea",                   brand: "Twisted Tea",  category: "Fridge",  emoji: "🍵"),
    ]

    static let wine: [CatalogEntry] = [
        .init(name: "Yellow Tail Cabernet",          brand: "Yellow Tail",  category: "Pantry",  emoji: "🍷"),
        .init(name: "Barefoot Pinot Grigio",         brand: "Barefoot",     category: "Fridge",  emoji: "🍷"),
        .init(name: "Kim Crawford Sauvignon Blanc",  brand: "Kim Crawford", category: "Fridge",  emoji: "🍷"),
        .init(name: "Josh Cellars Cabernet",         brand: "Josh Cellars", category: "Pantry",  emoji: "🍷"),
        .init(name: "La Marca Prosecco",             brand: "La Marca",     category: "Fridge",  emoji: "🥂"),
        .init(name: "Bota Box Red Wine",             brand: "Bota Box",     category: "Pantry",  emoji: "🍷"),
        .init(name: "Stella Rosa Rosso",             brand: "Stella Rosa",  category: "Fridge",  emoji: "🍷"),
    ]

    static let spirits: [CatalogEntry] = [
        .init(name: "Jack Daniel's Whiskey",         brand: "Jack Daniel's", category: "Pantry", emoji: "🥃"),
        .init(name: "Jameson Irish Whiskey",         brand: "Jameson",      category: "Pantry",  emoji: "🥃"),
        .init(name: "Crown Royal",                   brand: "Crown Royal",  category: "Pantry",  emoji: "🥃"),
        .init(name: "Grey Goose Vodka",              brand: "Grey Goose",   category: "Pantry",  emoji: "🍸"),
        .init(name: "Tito's Handmade Vodka",         brand: "Tito's",       category: "Pantry",  emoji: "🍸"),
        .init(name: "Smirnoff Vodka",                brand: "Smirnoff",     category: "Pantry",  emoji: "🍸"),
        .init(name: "Hennessy VS",                   brand: "Hennessy",     category: "Pantry",  emoji: "🥃"),
        .init(name: "Patron Silver Tequila",         brand: "Patron",       category: "Pantry",  emoji: "🍹"),
        .init(name: "Don Julio Tequila",             brand: "Don Julio",    category: "Pantry",  emoji: "🍹"),
        .init(name: "Casamigos Tequila",             brand: "Casamigos",    category: "Pantry",  emoji: "🍹"),
        .init(name: "Captain Morgan Spiced Rum",     brand: "Captain Morgan", category: "Pantry", emoji: "🍹"),
        .init(name: "Bacardi White Rum",             brand: "Bacardi",      category: "Pantry",  emoji: "🍹"),
        .init(name: "Jose Cuervo Tequila",           brand: "Jose Cuervo",  category: "Pantry",  emoji: "🍹"),
        .init(name: "Fireball Whisky",               brand: "Fireball",     category: "Pantry",  emoji: "🔥"),
    ]

    // MARK: Dairy
    static let dairy: [CatalogEntry] = [
        .init(name: "Horizon Organic Whole Milk",    brand: "Horizon",      category: "Fridge",  emoji: "🥛"),
        .init(name: "Fairlife Whole Milk",           brand: "Fairlife",     category: "Fridge",  emoji: "🥛"),
        .init(name: "Silk Oat Milk",                 brand: "Silk",         category: "Fridge",  emoji: "🌾"),
        .init(name: "Oatly Oat Milk",                brand: "Oatly",        category: "Fridge",  emoji: "🌾"),
        .init(name: "Califia Farms Oat Milk",        brand: "Califia",      category: "Fridge",  emoji: "🌾"),
        .init(name: "Almond Breeze",                 brand: "Blue Diamond", category: "Fridge",  emoji: "🌰"),
        .init(name: "Silk Almond Milk",              brand: "Silk",         category: "Fridge",  emoji: "🌰"),
        .init(name: "Ripple Pea Milk",               brand: "Ripple",       category: "Fridge",  emoji: "🌱"),
        .init(name: "Lactaid Whole Milk",            brand: "Lactaid",      category: "Fridge",  emoji: "🥛"),
        .init(name: "Carnation Evaporated Milk",     brand: "Carnation",    category: "Pantry",  emoji: "🥛"),
        .init(name: "Land O'Lakes Cream",            brand: "Land O'Lakes", category: "Fridge",  emoji: "🥛"),
        .init(name: "Cool Whip",                     brand: "Cool Whip",    category: "Fridge",  emoji: "🍦"),
        .init(name: "Reddi-wip",                     brand: "Reddi-wip",    category: "Fridge",  emoji: "🍦"),
        .init(name: "Philadelphia Cream Cheese",     brand: "Philadelphia", category: "Fridge",  emoji: "🧀"),
        .init(name: "Daisy Sour Cream",              brand: "Daisy",        category: "Fridge",  emoji: "🥛"),
    ]

    static let cheese: [CatalogEntry] = [
        .init(name: "Kraft Singles",                 brand: "Kraft",        category: "Fridge",  emoji: "🧀"),
        .init(name: "Kraft Shredded Cheddar",        brand: "Kraft",        category: "Fridge",  emoji: "🧀"),
        .init(name: "Kraft Shredded Mozzarella",     brand: "Kraft",        category: "Fridge",  emoji: "🧀"),
        .init(name: "Velveeta",                      brand: "Kraft",        category: "Pantry",  emoji: "🧀"),
        .init(name: "Babybel Cheese",                brand: "Babybel",      category: "Fridge",  emoji: "🧀"),
        .init(name: "String Cheese",                 brand: "Sargento",     category: "Fridge",  emoji: "🧀"),
        .init(name: "Tillamook Cheddar Block",       brand: "Tillamook",    category: "Fridge",  emoji: "🧀"),
        .init(name: "Sargento Sliced Colby Jack",    brand: "Sargento",     category: "Fridge",  emoji: "🧀"),
        .init(name: "Laughing Cow Cheese",           brand: "Laughing Cow", category: "Fridge",  emoji: "🧀"),
        .init(name: "Cabot Cheddar",                 brand: "Cabot",        category: "Fridge",  emoji: "🧀"),
    ]

    static let yogurt: [CatalogEntry] = [
        .init(name: "Chobani Plain Greek Yogurt",    brand: "Chobani",      category: "Fridge",  emoji: "🥛"),
        .init(name: "Chobani Flip",                  brand: "Chobani",      category: "Fridge",  emoji: "🥛"),
        .init(name: "Fage Total 0%",                 brand: "Fage",         category: "Fridge",  emoji: "🥛"),
        .init(name: "Oikos Triple Zero",             brand: "Dannon",       category: "Fridge",  emoji: "🥛"),
        .init(name: "Yoplait Original",              brand: "Yoplait",      category: "Fridge",  emoji: "🥛"),
        .init(name: "Activia",                       brand: "Dannon",       category: "Fridge",  emoji: "🥛"),
        .init(name: "Siggi's Skyr",                  brand: "Siggi's",      category: "Fridge",  emoji: "🥛"),
        .init(name: "Stonyfield Organic",            brand: "Stonyfield",   category: "Fridge",  emoji: "🥛"),
        .init(name: "GoGurt",                        brand: "Yoplait",      category: "Fridge",  emoji: "🥛"),
        .init(name: "Danone Light & Fit",            brand: "Dannon",       category: "Fridge",  emoji: "🥛"),
    ]

    static let eggs: [CatalogEntry] = [
        .init(name: "Vital Farms Pasture Raised Eggs", brand: "Vital Farms", category: "Fridge", emoji: "🥚"),
        .init(name: "Egg-Land's Best",               brand: "Egg-Land's Best", category: "Fridge", emoji: "🥚"),
        .init(name: "Pete and Gerry's Organic Eggs", brand: "Pete and Gerry's", category: "Fridge", emoji: "🥚"),
        .init(name: "Happy Egg Co.",                 brand: "Happy Egg",    category: "Fridge",  emoji: "🥚"),
        .init(name: "Liquid Egg Whites",             brand: "Egg Beaters",  category: "Fridge",  emoji: "🥚"),
    ]

    static let butter: [CatalogEntry] = [
        .init(name: "Land O'Lakes Unsalted Butter",  brand: "Land O'Lakes", category: "Fridge",  emoji: "🧈"),
        .init(name: "Kerrygold Irish Butter",        brand: "Kerrygold",    category: "Fridge",  emoji: "🧈"),
        .init(name: "Country Crock",                 brand: "Country Crock", category: "Fridge", emoji: "🧈"),
        .init(name: "I Can't Believe It's Not Butter", brand: "Unilever",   category: "Fridge",  emoji: "🧈"),
        .init(name: "Earth Balance",                 brand: "Earth Balance", category: "Fridge",  emoji: "🧈"),
        .init(name: "Jif Peanut Butter",             brand: "Jif",          category: "Pantry",  emoji: "🥜"),
        .init(name: "Skippy Peanut Butter",          brand: "Skippy",       category: "Pantry",  emoji: "🥜"),
        .init(name: "Justin's Almond Butter",        brand: "Justin's",     category: "Pantry",  emoji: "🌰"),
    ]

    // MARK: Bread & Bakery
    static let bread: [CatalogEntry] = [
        .init(name: "Wonder Bread",                  brand: "Wonder",       category: "Pantry",  emoji: "🍞"),
        .init(name: "Dave's Killer Bread",           brand: "Dave's",       category: "Pantry",  emoji: "🍞"),
        .init(name: "Nature's Own Honey Wheat",      brand: "Nature's Own", category: "Pantry",  emoji: "🍞"),
        .init(name: "Sara Lee Soft & Smooth",        brand: "Sara Lee",     category: "Pantry",  emoji: "🍞"),
        .init(name: "Pepperidge Farm Sourdough",     brand: "Pepperidge Farm", category: "Pantry", emoji: "🍞"),
        .init(name: "Thomas' English Muffins",       brand: "Thomas'",      category: "Pantry",  emoji: "🫓"),
        .init(name: "Franz Hawaiian Rolls",          brand: "Franz",        category: "Pantry",  emoji: "🍞"),
        .init(name: "King's Hawaiian Rolls",         brand: "King's Hawaiian", category: "Pantry", emoji: "🍞"),
        .init(name: "Arnold Sandwich Thins",         brand: "Arnold",       category: "Pantry",  emoji: "🍞"),
        .init(name: "Mission Flour Tortillas",       brand: "Mission",      category: "Pantry",  emoji: "🌮"),
        .init(name: "Old El Paso Tortillas",         brand: "Old El Paso",  category: "Pantry",  emoji: "🌮"),
        .init(name: "La Banderita Corn Tortillas",   brand: "La Banderita", category: "Pantry",  emoji: "🌽"),
    ]

    static let bakery: [CatalogEntry] = [
        .init(name: "Little Debbie Oatmeal Creme Pies", brand: "Little Debbie", category: "Pantry", emoji: "🍪"),
        .init(name: "Little Debbie Swiss Rolls",     brand: "Little Debbie", category: "Pantry", emoji: "🍰"),
        .init(name: "Little Debbie Honey Buns",      brand: "Little Debbie", category: "Pantry", emoji: "🍩"),
        .init(name: "Hostess Twinkies",              brand: "Hostess",      category: "Pantry",  emoji: "🍰"),
        .init(name: "Hostess Ding Dongs",            brand: "Hostess",      category: "Pantry",  emoji: "🍩"),
        .init(name: "Hostess CupCakes",              brand: "Hostess",      category: "Pantry",  emoji: "🧁"),
        .init(name: "Drake's Coffee Cakes",          brand: "Drake's",      category: "Pantry",  emoji: "☕"),
        .init(name: "Pop-Tarts Strawberry",          brand: "Pop-Tarts",    category: "Pantry",  emoji: "🥧"),
        .init(name: "Pop-Tarts Brown Sugar Cinnamon", brand: "Pop-Tarts",   category: "Pantry",  emoji: "🥧"),
        .init(name: "Pillsbury Cinnamon Rolls",      brand: "Pillsbury",    category: "Fridge",  emoji: "🥐"),
    ]

    // MARK: Cereal & Breakfast
    static let cereal: [CatalogEntry] = [
        .init(name: "Cheerios Original",             brand: "General Mills", category: "Pantry", emoji: "⭕"),
        .init(name: "Honey Nut Cheerios",            brand: "General Mills", category: "Pantry", emoji: "🍯"),
        .init(name: "Frosted Flakes",                brand: "Kellogg's",    category: "Pantry",  emoji: "🐯"),
        .init(name: "Lucky Charms",                  brand: "General Mills", category: "Pantry", emoji: "🍀"),
        .init(name: "Froot Loops",                   brand: "Kellogg's",    category: "Pantry",  emoji: "🌈"),
        .init(name: "Rice Krispies",                 brand: "Kellogg's",    category: "Pantry",  emoji: "🍚"),
        .init(name: "Cocoa Puffs",                   brand: "General Mills", category: "Pantry", emoji: "🍫"),
        .init(name: "Cinnamon Toast Crunch",         brand: "General Mills", category: "Pantry", emoji: "🍞"),
        .init(name: "Cap'n Crunch",                  brand: "Quaker",       category: "Pantry",  emoji: "⚓"),
        .init(name: "Raisin Bran",                   brand: "Kellogg's",    category: "Pantry",  emoji: "🍇"),
        .init(name: "Grape-Nuts",                    brand: "Post",         category: "Pantry",  emoji: "🫘"),
        .init(name: "Granola",                       brand: "Quaker",       category: "Pantry",  emoji: "🌾"),
        .init(name: "Special K",                     brand: "Kellogg's",    category: "Pantry",  emoji: "🌾"),
        .init(name: "Life Cereal",                   brand: "Quaker",       category: "Pantry",  emoji: "🌾"),
    ]

    static let oats: [CatalogEntry] = [
        .init(name: "Quaker Old Fashioned Oats",     brand: "Quaker",       category: "Pantry",  emoji: "🌾"),
        .init(name: "Quaker Instant Oatmeal",        brand: "Quaker",       category: "Pantry",  emoji: "🥣"),
        .init(name: "Bob's Red Mill Rolled Oats",    brand: "Bob's Red Mill", category: "Pantry", emoji: "🌾"),
        .init(name: "Nature Valley Granola Bars",    brand: "Nature Valley", category: "Pantry",  emoji: "🌾"),
        .init(name: "Clif Bar",                      brand: "Clif",         category: "Pantry",  emoji: "🧗"),
        .init(name: "Kind Bar",                      brand: "Kind",         category: "Pantry",  emoji: "🌰"),
        .init(name: "RXBar",                         brand: "RXBAR",        category: "Pantry",  emoji: "💪"),
        .init(name: "Larabar",                       brand: "Larabar",      category: "Pantry",  emoji: "🥜"),
    ]

    // MARK: Pasta & Grains
    static let pasta: [CatalogEntry] = [
        .init(name: "Barilla Spaghetti",             brand: "Barilla",      category: "Pantry",  emoji: "🍝"),
        .init(name: "Barilla Penne",                 brand: "Barilla",      category: "Pantry",  emoji: "🍝"),
        .init(name: "Barilla Rotini",                brand: "Barilla",      category: "Pantry",  emoji: "🍝"),
        .init(name: "Ronzoni Elbow Macaroni",        brand: "Ronzoni",      category: "Pantry",  emoji: "🍝"),
        .init(name: "Kraft Mac & Cheese",            brand: "Kraft",        category: "Pantry",  emoji: "🧀"),
        .init(name: "Annie's Mac & Cheese",          brand: "Annie's",      category: "Pantry",  emoji: "🧀"),
        .init(name: "Velveeta Shells & Cheese",      brand: "Kraft",        category: "Pantry",  emoji: "🧀"),
        .init(name: "Maruchan Instant Ramen",        brand: "Maruchan",     category: "Pantry",  emoji: "🍜"),
        .init(name: "Nissin Cup Noodles",            brand: "Nissin",       category: "Pantry",  emoji: "🍜"),
        .init(name: "Top Ramen",                     brand: "Nissin",       category: "Pantry",  emoji: "🍜"),
        .init(name: "Knorr Rice Sides",              brand: "Knorr",        category: "Pantry",  emoji: "🍚"),
    ]

    static let rice: [CatalogEntry] = [
        .init(name: "Uncle Ben's White Rice",        brand: "Uncle Ben's",  category: "Pantry",  emoji: "🍚"),
        .init(name: "Minute Rice",                   brand: "Minute Rice",  category: "Pantry",  emoji: "🍚"),
        .init(name: "Jasmine Rice",                  brand: "Mahatma",      category: "Pantry",  emoji: "🍚"),
        .init(name: "Lundberg Wild Rice",            brand: "Lundberg",     category: "Pantry",  emoji: "🌾"),
        .init(name: "Seeds of Change Brown Rice",    brand: "Seeds of Change", category: "Pantry", emoji: "🌾"),
    ]

    static let grains: [CatalogEntry] = [
        .init(name: "Bob's Red Mill Quinoa",         brand: "Bob's Red Mill", category: "Pantry", emoji: "🌾"),
        .init(name: "Ancient Harvest Quinoa",        brand: "Ancient Harvest", category: "Pantry", emoji: "🌾"),
        .init(name: "Near East Couscous",            brand: "Near East",    category: "Pantry",  emoji: "🍚"),
    ]

    // MARK: Canned & Shelf-Stable
    static let cannedGoods: [CatalogEntry] = [
        .init(name: "StarKist Tuna",                 brand: "StarKist",     category: "Pantry",  emoji: "🐟"),
        .init(name: "Bumble Bee Tuna",               brand: "Bumble Bee",   category: "Pantry",  emoji: "🐟"),
        .init(name: "Chicken of the Sea",            brand: "Chicken of the Sea", category: "Pantry", emoji: "🐟"),
        .init(name: "Del Monte Corn",                brand: "Del Monte",    category: "Pantry",  emoji: "🌽"),
        .init(name: "Green Giant Green Beans",       brand: "Green Giant",  category: "Pantry",  emoji: "🥦"),
        .init(name: "Hunt's Diced Tomatoes",         brand: "Hunt's",       category: "Pantry",  emoji: "🍅"),
        .init(name: "Hunt's Tomato Paste",           brand: "Hunt's",       category: "Pantry",  emoji: "🍅"),
        .init(name: "Muir Glen Organic Tomatoes",    brand: "Muir Glen",    category: "Pantry",  emoji: "🍅"),
        .init(name: "Libby's Pumpkin",               brand: "Libby's",      category: "Pantry",  emoji: "🎃"),
        .init(name: "Swanson Chicken Broth",         brand: "Swanson",      category: "Pantry",  emoji: "🍗"),
        .init(name: "Pacific Foods Vegetable Broth", brand: "Pacific",      category: "Pantry",  emoji: "🥦"),
    ]

    static let soup: [CatalogEntry] = [
        .init(name: "Campbell's Tomato Soup",        brand: "Campbell's",   category: "Pantry",  emoji: "🍲"),
        .init(name: "Campbell's Chicken Noodle",     brand: "Campbell's",   category: "Pantry",  emoji: "🍲"),
        .init(name: "Campbell's Cream of Mushroom",  brand: "Campbell's",   category: "Pantry",  emoji: "🍲"),
        .init(name: "Progresso Soup",                brand: "Progresso",    category: "Pantry",  emoji: "🍲"),
        .init(name: "Amy's Lentil Soup",             brand: "Amy's",        category: "Pantry",  emoji: "🍲"),
        .init(name: "Pacific Foods Tomato Soup",     brand: "Pacific",      category: "Pantry",  emoji: "🍲"),
        .init(name: "Lipton Onion Soup Mix",         brand: "Lipton",       category: "Pantry",  emoji: "🧅"),
    ]

    static let beans: [CatalogEntry] = [
        .init(name: "Bush's Best Baked Beans",       brand: "Bush's",       category: "Pantry",  emoji: "🫘"),
        .init(name: "Goya Black Beans",              brand: "Goya",         category: "Pantry",  emoji: "🫘"),
        .init(name: "Goya Pinto Beans",              brand: "Goya",         category: "Pantry",  emoji: "🫘"),
        .init(name: "Amy's Refried Beans",           brand: "Amy's",        category: "Pantry",  emoji: "🫘"),
        .init(name: "Hanover Kidney Beans",          brand: "Hanover",      category: "Pantry",  emoji: "🫘"),
    ]

    // MARK: Condiments & Sauces
    static let condiments: [CatalogEntry] = [
        .init(name: "Heinz Ketchup",                 brand: "Heinz",        category: "Staples", emoji: "🍅"),
        .init(name: "French's Yellow Mustard",       brand: "French's",     category: "Staples", emoji: "🌭"),
        .init(name: "Hellmann's Mayonnaise",         brand: "Hellmann's",   category: "Staples", emoji: "🥚"),
        .init(name: "Miracle Whip",                  brand: "Kraft",        category: "Staples", emoji: "🥚"),
        .init(name: "Heinz Relish",                  brand: "Heinz",        category: "Staples", emoji: "🥒"),
        .init(name: "Tabasco Hot Sauce",             brand: "Tabasco",      category: "Staples", emoji: "🌶️"),
        .init(name: "Frank's RedHot",                brand: "Frank's",      category: "Staples", emoji: "🌶️"),
        .init(name: "Cholula Hot Sauce",             brand: "Cholula",      category: "Staples", emoji: "🌶️"),
        .init(name: "Tapatio Hot Sauce",             brand: "Tapatio",      category: "Staples", emoji: "🌶️"),
        .init(name: "Valentina Hot Sauce",           brand: "Valentina",    category: "Staples", emoji: "🌶️"),
        .init(name: "Hidden Valley Ranch",           brand: "Hidden Valley", category: "Staples", emoji: "🥗"),
        .init(name: "Ken's Steakhouse Dressing",     brand: "Ken's",        category: "Staples", emoji: "🥗"),
        .init(name: "Wish-Bone Italian",             brand: "Wish-Bone",    category: "Staples", emoji: "🥗"),
        .init(name: "Kraft Italian Dressing",        brand: "Kraft",        category: "Staples", emoji: "🥗"),
        .init(name: "Trader Joe's Salsa",            brand: "Trader Joe's", category: "Staples", emoji: "🍅"),
        .init(name: "Tostitos Salsa",                brand: "Tostitos",     category: "Staples", emoji: "🍅"),
        .init(name: "Pace Picante Sauce",            brand: "Pace",         category: "Staples", emoji: "🌶️"),
        .init(name: "Old El Paso Taco Sauce",        brand: "Old El Paso",  category: "Staples", emoji: "🌮"),
    ]

    static let sauces: [CatalogEntry] = [
        .init(name: "Prego Marinara",                brand: "Prego",        category: "Staples", emoji: "🍝"),
        .init(name: "Rao's Homemade Marinara",       brand: "Rao's",        category: "Staples", emoji: "🍝"),
        .init(name: "Classico Tomato Basil",         brand: "Classico",     category: "Staples", emoji: "🍝"),
        .init(name: "Bertolli Alfredo Sauce",        brand: "Bertolli",     category: "Staples", emoji: "🍝"),
        .init(name: "Ragu Pasta Sauce",              brand: "Ragu",         category: "Staples", emoji: "🍝"),
        .init(name: "Kikkoman Soy Sauce",            brand: "Kikkoman",     category: "Staples", emoji: "🥢"),
        .init(name: "Lee Kum Kee Oyster Sauce",      brand: "Lee Kum Kee",  category: "Staples", emoji: "🦪"),
        .init(name: "Hoisin Sauce",                  brand: "Lee Kum Kee",  category: "Staples", emoji: "🥢"),
        .init(name: "Sriracha",                      brand: "Huy Fong",     category: "Staples", emoji: "🌶️"),
        .init(name: "Sambal Oelek",                  brand: "Huy Fong",     category: "Staples", emoji: "🌶️"),
        .init(name: "Worcestershire Sauce",          brand: "Lea & Perrins", category: "Staples", emoji: "🍶"),
        .init(name: "A1 Steak Sauce",                brand: "A1",           category: "Staples", emoji: "🥩"),
        .init(name: "Sweet Baby Ray's BBQ",          brand: "Sweet Baby Ray's", category: "Staples", emoji: "🍖"),
        .init(name: "KC Masterpiece BBQ",            brand: "KC Masterpiece", category: "Staples", emoji: "🍖"),
        .init(name: "Stubb's BBQ Sauce",             brand: "Stubb's",      category: "Staples", emoji: "🍖"),
    ]

    static let oils: [CatalogEntry] = [
        .init(name: "Crisco Vegetable Oil",          brand: "Crisco",       category: "Staples", emoji: "🫙"),
        .init(name: "Mazola Corn Oil",               brand: "Mazola",       category: "Staples", emoji: "🌽"),
        .init(name: "Bertolli Olive Oil",            brand: "Bertolli",     category: "Staples", emoji: "🫒"),
        .init(name: "California Olive Ranch EVOO",   brand: "California Olive Ranch", category: "Staples", emoji: "🫒"),
        .init(name: "Spectrum Coconut Oil",          brand: "Spectrum",     category: "Staples", emoji: "🥥"),
        .init(name: "Chosen Foods Avocado Oil",      brand: "Chosen Foods", category: "Staples", emoji: "🥑"),
        .init(name: "PAM Cooking Spray",             brand: "PAM",          category: "Staples", emoji: "🫙"),
    ]

    static let spices: [CatalogEntry] = [
        .init(name: "McCormick Garlic Powder",       brand: "McCormick",    category: "Staples", emoji: "🧄"),
        .init(name: "McCormick Onion Powder",        brand: "McCormick",    category: "Staples", emoji: "🧅"),
        .init(name: "McCormick Cumin",               brand: "McCormick",    category: "Staples", emoji: "🌿"),
        .init(name: "McCormick Paprika",             brand: "McCormick",    category: "Staples", emoji: "🌶️"),
        .init(name: "McCormick Cinnamon",            brand: "McCormick",    category: "Staples", emoji: "🌿"),
        .init(name: "McCormick Italian Seasoning",   brand: "McCormick",    category: "Staples", emoji: "🌿"),
        .init(name: "Lawry's Seasoned Salt",         brand: "Lawry's",      category: "Staples", emoji: "🧂"),
        .init(name: "Tony Chachere's Creole",        brand: "Tony Chachere's", category: "Staples", emoji: "🌶️"),
        .init(name: "Old Bay Seasoning",             brand: "Old Bay",      category: "Staples", emoji: "🦀"),
        .init(name: "Everything Bagel Seasoning",    brand: "Trader Joe's", category: "Staples", emoji: "🥯"),
        .init(name: "Morton Salt",                   brand: "Morton",       category: "Staples", emoji: "🧂"),
        .init(name: "Diamond Crystal Salt",          brand: "Diamond Crystal", category: "Staples", emoji: "🧂"),
        .init(name: "Domino Sugar",                  brand: "Domino",       category: "Staples", emoji: "🍬"),
        .init(name: "C&H Sugar",                     brand: "C&H",          category: "Staples", emoji: "🍬"),
        .init(name: "Truvia Sweetener",              brand: "Truvia",       category: "Staples", emoji: "🍬"),
        .init(name: "Splenda",                       brand: "Splenda",      category: "Staples", emoji: "🍬"),
    ]

    // MARK: Meat & Seafood
    static let meat: [CatalogEntry] = [
        .init(name: "Oscar Mayer Bacon",             brand: "Oscar Mayer",  category: "Fridge",  emoji: "🥓"),
        .init(name: "Oscar Mayer Hot Dogs",          brand: "Oscar Mayer",  category: "Fridge",  emoji: "🌭"),
        .init(name: "Ball Park Franks",              brand: "Ball Park",    category: "Fridge",  emoji: "🌭"),
        .init(name: "Johnsonville Brats",            brand: "Johnsonville",  category: "Fridge", emoji: "🌭"),
        .init(name: "Jimmy Dean Sausage",            brand: "Jimmy Dean",   category: "Fridge",  emoji: "🥩"),
        .init(name: "Hillshire Farm Smoked Sausage", brand: "Hillshire",    category: "Fridge",  emoji: "🥩"),
        .init(name: "Spam Classic",                  brand: "Spam",         category: "Pantry",  emoji: "🥩"),
        .init(name: "Jennie-O Turkey",               brand: "Jennie-O",     category: "Fridge",  emoji: "🦃"),
        .init(name: "Boar's Head Turkey",            brand: "Boar's Head",  category: "Fridge",  emoji: "🦃"),
        .init(name: "Land O'Frost Lunch Meat",       brand: "Land O'Frost", category: "Fridge",  emoji: "🥩"),
    ]

    static let seafood: [CatalogEntry] = [
        .init(name: "Gorton's Fish Sticks",          brand: "Gorton's",     category: "Freezer", emoji: "🐟"),
        .init(name: "SeaPak Shrimp Scampi",          brand: "SeaPak",       category: "Freezer", emoji: "🦐"),
        .init(name: "Trident Wild Alaska Salmon",    brand: "Trident",      category: "Freezer", emoji: "🐟"),
    ]

    static let deli: [CatalogEntry] = [
        .init(name: "Lunchables Turkey & Cheddar",  brand: "Lunchables",   category: "Fridge",  emoji: "🥪"),
        .init(name: "Sargento Balanced Breaks",      brand: "Sargento",     category: "Fridge",  emoji: "🧀"),
    ]

    // MARK: Produce
    static let produce: [CatalogEntry] = [
        .init(name: "Marketside Romaine Hearts",     brand: "Marketside",   category: "Fridge",  emoji: "🥬"),
        .init(name: "Fresh Express Salad Kit",       brand: "Fresh Express", category: "Fridge",  emoji: "🥗"),
        .init(name: "Taylor Farms Salad Kit",        brand: "Taylor Farms", category: "Fridge",  emoji: "🥗"),
        .init(name: "Dole Salad Kit",                brand: "Dole",         category: "Fridge",  emoji: "🥗"),
    ]

    static let fruits: [CatalogEntry] = [
        .init(name: "Dole Pineapple Chunks",         brand: "Dole",         category: "Pantry",  emoji: "🍍"),
        .init(name: "Del Monte Mixed Fruit",         brand: "Del Monte",    category: "Pantry",  emoji: "🍑"),
        .init(name: "Mott's Applesauce",             brand: "Mott's",       category: "Pantry",  emoji: "🍎"),
        .init(name: "Smucker's Strawberry Jam",      brand: "Smucker's",    category: "Staples", emoji: "🍓"),
        .init(name: "Welch's Grape Jam",             brand: "Welch's",      category: "Staples", emoji: "🍇"),
        .init(name: "Justin's Jam",                  brand: "Justin's",     category: "Staples", emoji: "🍓"),
    ]

    static let vegetables: [CatalogEntry] = [
        .init(name: "Green Giant Frozen Broccoli",   brand: "Green Giant",  category: "Freezer", emoji: "🥦"),
        .init(name: "Birds Eye Steamfresh Broccoli", brand: "Birds Eye",    category: "Freezer", emoji: "🥦"),
        .init(name: "Green Giant Corn on the Cob",   brand: "Green Giant",  category: "Freezer", emoji: "🌽"),
        .init(name: "Alexia Seasoned Fries",         brand: "Alexia",       category: "Freezer", emoji: "🍟"),
    ]

    // MARK: Snacks & Protein
    static let snacks: [CatalogEntry] = [
        .init(name: "Welch's Fruit Snacks",          brand: "Welch's",      category: "Pantry",  emoji: "🍇"),
        .init(name: "Fruit Roll-Ups",                brand: "General Mills", category: "Pantry", emoji: "🌀"),
        .init(name: "Motts Fruit Snacks",            brand: "Mott's",       category: "Pantry",  emoji: "🍎"),
        .init(name: "Rice Krispies Treats",          brand: "Kellogg's",    category: "Pantry",  emoji: "🍬"),
        .init(name: "Nutri-Grain Bar",               brand: "Kellogg's",    category: "Pantry",  emoji: "🌾"),
        .init(name: "Keebler Chips Deluxe",          brand: "Keebler",      category: "Pantry",  emoji: "🍪"),
        .init(name: "Fruit by the Foot",             brand: "General Mills", category: "Pantry", emoji: "👣"),
        .init(name: "Gushers",                       brand: "General Mills", category: "Pantry", emoji: "💦"),
        .init(name: "Dunkaroos",                     brand: "General Mills", category: "Pantry", emoji: "🍪"),
        .init(name: "Slim Jim",                      brand: "Slim Jim",     category: "Pantry",  emoji: "🌭"),
        .init(name: "Jack Link's Beef Jerky",        brand: "Jack Link's",  category: "Pantry",  emoji: "🥩"),
        .init(name: "Chomps Meat Stick",             brand: "Chomps",       category: "Pantry",  emoji: "🥩"),
        .init(name: "Moon Cheese",                   brand: "Moon Cheese",  category: "Pantry",  emoji: "🧀"),
    ]

    static let nuts: [CatalogEntry] = [
        .init(name: "Planters Mixed Nuts",           brand: "Planters",     category: "Pantry",  emoji: "🥜"),
        .init(name: "Planters Honey Roasted Peanuts", brand: "Planters",    category: "Pantry",  emoji: "🥜"),
        .init(name: "Blue Diamond Almonds",          brand: "Blue Diamond", category: "Pantry",  emoji: "🌰"),
        .init(name: "Wonderful Pistachios",          brand: "Wonderful",    category: "Pantry",  emoji: "🌿"),
        .init(name: "Fisher Cashews",                brand: "Fisher",       category: "Pantry",  emoji: "🌰"),
        .init(name: "Emerald Pecans",                brand: "Emerald",      category: "Pantry",  emoji: "🌰"),
        .init(name: "Hampton Farms Sunflower Seeds", brand: "Hampton Farms", category: "Pantry", emoji: "🌻"),
    ]

    static let protein: [CatalogEntry] = [
        .init(name: "Premier Protein Shake",         brand: "Premier Protein", category: "Fridge", emoji: "💪"),
        .init(name: "Fairlife Core Power",           brand: "Fairlife",     category: "Fridge",  emoji: "💪"),
        .init(name: "Muscle Milk",                   brand: "CytoSport",    category: "Fridge",  emoji: "💪"),
        .init(name: "Dymatize ISO100 Protein",       brand: "Dymatize",     category: "Pantry",  emoji: "💪"),
        .init(name: "Orgain Organic Protein",        brand: "Orgain",       category: "Pantry",  emoji: "🌱"),
        .init(name: "Quest Protein Bar",             brand: "Quest",        category: "Pantry",  emoji: "💪"),
        .init(name: "ONE Protein Bar",               brand: "ONE",          category: "Pantry",  emoji: "💪"),
    ]

    // MARK: Baby Food
    static let babyFood: [CatalogEntry] = [
        .init(name: "Gerber Baby Food",              brand: "Gerber",       category: "Pantry",  emoji: "👶"),
        .init(name: "Happy Baby Organic",            brand: "Happy Baby",   category: "Pantry",  emoji: "👶"),
        .init(name: "Plum Organics",                 brand: "Plum",         category: "Pantry",  emoji: "👶"),
        .init(name: "Beech-Nut Baby Food",           brand: "Beech-Nut",    category: "Pantry",  emoji: "👶"),
    ]

    // MARK: Pet Food
    static let petFood: [CatalogEntry] = [
        .init(name: "Purina ONE Dog Food",           brand: "Purina",       category: "Pantry",  emoji: "🐕"),
        .init(name: "Blue Buffalo Dog Food",         brand: "Blue Buffalo",  category: "Pantry", emoji: "🐕"),
        .init(name: "Pedigree Dog Food",             brand: "Pedigree",     category: "Pantry",  emoji: "🐕"),
        .init(name: "Friskies Cat Food",             brand: "Friskies",     category: "Pantry",  emoji: "🐈"),
        .init(name: "Fancy Feast",                   brand: "Purina",       category: "Pantry",  emoji: "🐈"),
        .init(name: "Whiskas Cat Food",              brand: "Whiskas",      category: "Pantry",  emoji: "🐈"),
        .init(name: "Beggin' Strips",                brand: "Purina",       category: "Pantry",  emoji: "🐕"),
        .init(name: "Milk-Bone Dog Biscuits",        brand: "Milk-Bone",    category: "Pantry",  emoji: "🦴"),
    ]

    // MARK: - Search
    static func search(_ query: String) -> [CatalogEntry] {
        let q = query.lowercased()
        return all.filter {
            $0.name.lowercased().contains(q) || $0.brand.lowercased().contains(q)
        }
    }
}
