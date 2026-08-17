// GroceryKnowledgeBase.swift
// Verified retailer/private-label knowledge used by receipt cleanup, search, and aisle fallback.
// Physical addresses remain live MapKit results; aisle labels are intentionally departments,
// because numbered aisles differ by branch and learned StoreLayout data is more authoritative.

import Foundation

nonisolated enum GroceryAisle: String, CaseIterable, Codable, Sendable {
    case produce = "Produce"
    case bakery = "Bakery"
    case deli = "Deli & Prepared Foods"
    case meat = "Meat & Seafood"
    case dairy = "Dairy & Eggs"
    case frozen = "Frozen"
    case breakfast = "Breakfast & Cereal"
    case pantry = "Pantry"
    case canned = "Canned Goods & Soup"
    case baking = "Baking"
    case condiments = "Condiments & Sauces"
    case snacks = "Snacks"
    case beverages = "Beverages"
    case household = "Household"
    case baby = "Baby"
    case pets = "Pet Supplies"

    var defaultOrder: Int { Self.allCases.firstIndex(of: self) ?? Self.allCases.count }
}

nonisolated struct GroceryRetailerProfile: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let aliases: [String]
    let privateLabels: [String]
    let departments: [GroceryAisle]
    let officialLocatorURL: URL
}

nonisolated enum GroceryKnowledgeBase {
    static let retailers: [GroceryRetailerProfile] = [
        .init(id: "heb", name: "H-E-B", aliases: ["HEB", "Central Market"],
              privateLabels: ["H-E-B", "Hill Country Fare", "Central Market", "Creamy Creations", "Meal Simple", "Mootopia", "Mi Tienda"],
              departments: GroceryAisle.allCases, officialLocatorURL: URL(string: "https://www.heb.com/store-locations")!),
        .init(id: "walmart", name: "Walmart", aliases: ["Walmart Supercenter", "Walmart Neighborhood Market"],
              privateLabels: ["Great Value", "Marketside", "Freshness Guaranteed", "bettergoods"],
              departments: GroceryAisle.allCases, officialLocatorURL: URL(string: "https://www.walmart.com/store/finder")!),
        .init(id: "kroger", name: "Kroger", aliases: ["Ralphs", "Fred Meyer", "King Soopers", "Smith's", "Fry's", "Harris Teeter", "Dillons", "QFC"],
              privateLabels: ["Kroger", "Private Selection", "Simple Truth", "Smart Way", "Mercado", "Home Chef", "Bakery Fresh"],
              departments: GroceryAisle.allCases, officialLocatorURL: URL(string: "https://www.kroger.com/stores/grocery")!),
        .init(id: "target", name: "Target", aliases: ["SuperTarget"],
              privateLabels: ["Good & Gather", "Favorite Day", "Market Pantry", "Kindfull"],
              departments: GroceryAisle.allCases, officialLocatorURL: URL(string: "https://www.target.com/store-locator/find-stores")!),
        .init(id: "whole-foods", name: "Whole Foods Market", aliases: ["Whole Foods", "WFM"],
              privateLabels: ["365 by Whole Foods Market", "365"], departments: GroceryAisle.allCases,
              officialLocatorURL: URL(string: "https://www.wholefoodsmarket.com/stores")!),
        .init(id: "publix", name: "Publix", aliases: ["Publix Super Market"],
              privateLabels: ["Publix", "Publix Premium", "Publix GreenWise"], departments: GroceryAisle.allCases,
              officialLocatorURL: URL(string: "https://www.publix.com/locations")!),
        .init(id: "aldi", name: "ALDI", aliases: ["Aldi"],
              privateLabels: ["Clancy's", "Simply Nature", "Specially Selected", "Friendly Farms", "Fremont Fish Market", "Stonemill", "Kirkwood", "Millville", "Park Street Deli", "Sundae Shoppe", "L'oven Fresh", "Barissimo", "Benton's", "Season's Choice"],
              departments: GroceryAisle.allCases, officialLocatorURL: URL(string: "https://stores.aldi.us/")!),
        .init(id: "trader-joes", name: "Trader Joe's", aliases: ["Trader Joes", "TJ's"],
              privateLabels: ["Trader Joe's", "Trader José's", "Trader Giotto's"], departments: GroceryAisle.allCases,
              officialLocatorURL: URL(string: "https://locations.traderjoes.com/")!),
        .init(id: "costco", name: "Costco", aliases: ["Costco Wholesale"],
              privateLabels: ["Kirkland Signature", "Kirkland"], departments: GroceryAisle.allCases,
              officialLocatorURL: URL(string: "https://www.costco.com/warehouse-locations")!),
        .init(id: "sams-club", name: "Sam's Club", aliases: ["Sams Club"],
              privateLabels: ["Member's Mark", "Members Mark"], departments: GroceryAisle.allCases,
              officialLocatorURL: URL(string: "https://www.samsclub.com/club-finder")!),
        .init(id: "safeway", name: "Safeway", aliases: ["Albertsons", "Vons", "Jewel-Osco", "Acme", "Shaw's"],
              privateLabels: ["Signature Select", "O Organics", "Open Nature", "Lucerne"], departments: GroceryAisle.allCases,
              officialLocatorURL: URL(string: "https://local.safeway.com/safeway.html")!),
    ]

    static let allBrandNames: [String] = Array(Set(
        retailers.flatMap(\.privateLabels) + ProductCatalog.catalogExpansionBrandNames
    )).sorted { $0.count > $1.count }

    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^a-zA-Z0-9]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    static func containsPhrase(_ phrase: String, in value: String) -> Bool {
        let needle = normalize(phrase), haystack = normalize(value)
        return haystack == needle || haystack.hasPrefix(needle + " ") || haystack.hasSuffix(" " + needle)
            || haystack.contains(" " + needle + " ")
    }

    static func retailer(matching storeName: String) -> GroceryRetailerProfile? {
        retailers
            .flatMap { profile in ([profile.name] + profile.aliases).map { (normalize($0), profile) } }
            .filter { !$0.0.isEmpty && containsPhrase($0.0, in: storeName) }
            .max { $0.0.count < $1.0.count }?.1
    }

    static func brand(in raw: String, storeName: String = "") -> String? {
        let storeLabels = retailer(matching: storeName)?.privateLabels ?? []
        let catalogBrands = ProductCatalog.all.map(\.brand)
        return Array(Set(storeLabels + allBrandNames + catalogBrands))
            .filter { !$0.isEmpty && containsPhrase($0, in: raw) }
            .max { $0.count < $1.count }
    }

    static func inferAisle(for rawName: String) -> GroceryAisle {
        if let known = CommonGroceryDB.lookup(rawName),
           let aisle = GroceryAisle.allCases.first(where: { normalize($0.rawValue) == normalize(known.aisle) }) {
            return aisle
        }
        let value = normalize(rawName)
        let rules: [(GroceryAisle, [String])] = [
            (.produce, ["apple", "banana", "avocado", "spinach", "kale", "carrot", "produce", "lemon", "lime"]),
            (.bakery, ["bread", "bagel", "bun", "tortilla", "danish", "bakery"]),
            (.deli, ["hummus", "rotisserie", "prepared", "meal simple", "salami"]),
            (.meat, ["chicken", "beef", "pork", "salmon", "shrimp", "turkey", "meat"]),
            (.dairy, ["milk", "egg", "butter", "cheese", "yogurt", "cream"]),
            (.frozen, ["frozen", "ice cream", "mochi", "pizza", "nugget"]),
            (.breakfast, ["cereal", "oat", "pancake", "granola", "coffee"]),
            (.canned, ["bean", "soup", "broth", "stock", "canned", "cherries"]),
            (.baking, ["flour", "sugar", "brownie", "baking", "cookie dough"]),
            (.condiments, ["sauce", "dressing", "vinegar", "oil", "seasoning", "spice", "salsa"]),
            (.snacks, ["chip", "pretzel", "cookie", "popcorn", "cracker", "trail mix", "nut"]),
            (.beverages, ["water", "juice", "soda", "beverage", "tea", "sparkling"]),
            (.baby, ["baby", "infant"]), (.pets, ["dog", "cat", "pet"]),
        ]
        return rules.first { _, terms in terms.contains { containsPhrase($0, in: value) } }?.0 ?? .pantry
    }
}

nonisolated extension ProductCatalog {
    /// 100 verified private-label grocery products, grouped by the retailer where the label is
    /// sold. Names intentionally omit volatile package sizes and prices so receipt/OCR matching
    /// remains useful when those change.
    static let retailerBrandItems: [CatalogEntry] = [
        // Walmart — 10
        .init(name: "Great Value Kettle Cooked Jalapeño Chips", brand: "Great Value", category: "Pantry", emoji: "🥔", aisle: .snacks, retailerIDs: ["walmart"]),
        .init(name: "Great Value Lasagna", brand: "Great Value", category: "Freezer", emoji: "🍝", aisle: .frozen, retailerIDs: ["walmart"]),
        .init(name: "Great Value Frosted Flakes Cereal", brand: "Great Value", category: "Pantry", emoji: "🥣", aisle: .breakfast, retailerIDs: ["walmart"]),
        .init(name: "Great Value Maraschino Cherries", brand: "Great Value", category: "Pantry", emoji: "🍒", aisle: .canned, retailerIDs: ["walmart"]),
        .init(name: "Great Value Chicken Nuggets", brand: "Great Value", category: "Freezer", emoji: "🍗", aisle: .frozen, retailerIDs: ["walmart"]),
        .init(name: "Great Value Donut Shop Ground Coffee", brand: "Great Value", category: "Pantry", emoji: "☕", aisle: .breakfast, retailerIDs: ["walmart"]),
        .init(name: "Great Value Buttermilk Pancakes", brand: "Great Value", category: "Freezer", emoji: "🥞", aisle: .frozen, retailerIDs: ["walmart"]),
        .init(name: "Marketside Caesar Salad Kit", brand: "Marketside", category: "Fridge", emoji: "🥗", aisle: .produce, retailerIDs: ["walmart"]),
        .init(name: "Freshness Guaranteed French Bread", brand: "Freshness Guaranteed", category: "Pantry", emoji: "🥖", aisle: .bakery, retailerIDs: ["walmart"]),
        .init(name: "bettergoods Sparkling Water", brand: "bettergoods", category: "Pantry", emoji: "🥤", aisle: .beverages, retailerIDs: ["walmart"]),

        // Kroger family — 10
        .init(name: "Kroger Whole Milk", brand: "Kroger", category: "Fridge", emoji: "🥛", aisle: .dairy, retailerIDs: ["kroger"]),
        .init(name: "Kroger Large Eggs", brand: "Kroger", category: "Fridge", emoji: "🥚", aisle: .dairy, retailerIDs: ["kroger"]),
        .init(name: "Kroger Shredded Cheddar Cheese", brand: "Kroger", category: "Fridge", emoji: "🧀", aisle: .dairy, retailerIDs: ["kroger"]),
        .init(name: "Private Selection Pasta Sauce", brand: "Private Selection", category: "Pantry", emoji: "🍅", aisle: .condiments, retailerIDs: ["kroger"]),
        .init(name: "Private Selection Ice Cream", brand: "Private Selection", category: "Freezer", emoji: "🍨", aisle: .frozen, retailerIDs: ["kroger"]),
        .init(name: "Simple Truth Organic Spinach", brand: "Simple Truth", category: "Fridge", emoji: "🥬", aisle: .produce, retailerIDs: ["kroger"]),
        .init(name: "Simple Truth Organic Black Beans", brand: "Simple Truth", category: "Pantry", emoji: "🫘", aisle: .canned, retailerIDs: ["kroger"]),
        .init(name: "Smart Way Long Grain Rice", brand: "Smart Way", category: "Pantry", emoji: "🍚", aisle: .pantry, retailerIDs: ["kroger"]),
        .init(name: "Mercado Flour Tortillas", brand: "Mercado", category: "Pantry", emoji: "🫓", aisle: .bakery, retailerIDs: ["kroger"]),
        .init(name: "Bakery Fresh Chocolate Chip Cookies", brand: "Bakery Fresh", category: "Pantry", emoji: "🍪", aisle: .bakery, retailerIDs: ["kroger"]),

        // Target — 10
        .init(name: "Good & Gather Whole Milk", brand: "Good & Gather", category: "Fridge", emoji: "🥛", aisle: .dairy, retailerIDs: ["target"]),
        .init(name: "Good & Gather Large Eggs", brand: "Good & Gather", category: "Fridge", emoji: "🥚", aisle: .dairy, retailerIDs: ["target"]),
        .init(name: "Good & Gather Shredded Cheddar Cheese", brand: "Good & Gather", category: "Fridge", emoji: "🧀", aisle: .dairy, retailerIDs: ["target"]),
        .init(name: "Good & Gather Spaghetti", brand: "Good & Gather", category: "Pantry", emoji: "🍝", aisle: .pantry, retailerIDs: ["target"]),
        .init(name: "Good & Gather Granola Bars", brand: "Good & Gather", category: "Pantry", emoji: "🍫", aisle: .breakfast, retailerIDs: ["target"]),
        .init(name: "Good & Gather Sparkling Water", brand: "Good & Gather", category: "Pantry", emoji: "🥤", aisle: .beverages, retailerIDs: ["target"]),
        .init(name: "Good & Gather Chicken Breast", brand: "Good & Gather", category: "Fridge", emoji: "🍗", aisle: .meat, retailerIDs: ["target"]),
        .init(name: "Favorite Day Chocolate Ice Cream", brand: "Favorite Day", category: "Freezer", emoji: "🍨", aisle: .frozen, retailerIDs: ["target"]),
        .init(name: "Market Pantry All Purpose Flour", brand: "Market Pantry", category: "Staples", emoji: "🌾", aisle: .baking, retailerIDs: ["target"]),
        .init(name: "Kindfull Chicken Dog Food", brand: "Kindfull", category: "Pantry", emoji: "🐕", aisle: .pets, retailerIDs: ["target"]),

        // Whole Foods Market — 10
        .init(name: "365 Sandwich Bread", brand: "365", category: "Pantry", emoji: "🍞", aisle: .bakery, retailerIDs: ["whole-foods"]),
        .init(name: "365 Almond Butter", brand: "365", category: "Pantry", emoji: "🥜", aisle: .pantry, retailerIDs: ["whole-foods"]),
        .init(name: "365 Frozen Strawberries", brand: "365", category: "Freezer", emoji: "🍓", aisle: .frozen, retailerIDs: ["whole-foods"]),
        .init(name: "365 Frozen Dessert", brand: "365", category: "Freezer", emoji: "🍨", aisle: .frozen, retailerIDs: ["whole-foods"]),
        .init(name: "365 Organic Kale", brand: "365", category: "Fridge", emoji: "🥬", aisle: .produce, retailerIDs: ["whole-foods"]),
        .init(name: "365 Coconut Water", brand: "365", category: "Pantry", emoji: "🥥", aisle: .beverages, retailerIDs: ["whole-foods"]),
        .init(name: "365 Brown Rice", brand: "365", category: "Pantry", emoji: "🍚", aisle: .pantry, retailerIDs: ["whole-foods"]),
        .init(name: "365 Pasta Sauce", brand: "365", category: "Pantry", emoji: "🍅", aisle: .condiments, retailerIDs: ["whole-foods"]),
        .init(name: "365 Black Beans", brand: "365", category: "Pantry", emoji: "🫘", aisle: .canned, retailerIDs: ["whole-foods"]),
        .init(name: "365 Lemon Sparkling Water", brand: "365", category: "Pantry", emoji: "🥤", aisle: .beverages, retailerIDs: ["whole-foods"]),

        // Publix — 10
        .init(name: "Publix Popcorn Chicken", brand: "Publix", category: "Fridge", emoji: "🍗", aisle: .deli, retailerIDs: ["publix"]),
        .init(name: "Publix Classic Hummus", brand: "Publix", category: "Fridge", emoji: "🫘", aisle: .deli, retailerIDs: ["publix"]),
        .init(name: "Publix Stuffed Chicken Breast", brand: "Publix", category: "Fridge", emoji: "🍗", aisle: .meat, retailerIDs: ["publix"]),
        .init(name: "Publix Caesar Salad Kit", brand: "Publix", category: "Fridge", emoji: "🥗", aisle: .produce, retailerIDs: ["publix"]),
        .init(name: "Publix Baby Carrots", brand: "Publix", category: "Fridge", emoji: "🥕", aisle: .produce, retailerIDs: ["publix"]),
        .init(name: "Publix Potato Chips", brand: "Publix", category: "Pantry", emoji: "🥔", aisle: .snacks, retailerIDs: ["publix"]),
        .init(name: "Publix Cola", brand: "Publix", category: "Pantry", emoji: "🥤", aisle: .beverages, retailerIDs: ["publix"]),
        .init(name: "Publix Chocolate Chip Cookies", brand: "Publix", category: "Pantry", emoji: "🍪", aisle: .bakery, retailerIDs: ["publix"]),
        .init(name: "Publix Premium Vanilla Ice Cream", brand: "Publix Premium", category: "Freezer", emoji: "🍨", aisle: .frozen, retailerIDs: ["publix"]),
        .init(name: "Publix Cottage Cheese", brand: "Publix", category: "Fridge", emoji: "🧀", aisle: .dairy, retailerIDs: ["publix"]),

        // ALDI — 10
        .init(name: "Clancy's Original Kettle Chips", brand: "Clancy's", category: "Pantry", emoji: "🥔", aisle: .snacks, retailerIDs: ["aldi"]),
        .init(name: "Simply Nature Organic Coconut Oil", brand: "Simply Nature", category: "Staples", emoji: "🥥", aisle: .condiments, retailerIDs: ["aldi"]),
        .init(name: "Simply Nature Organic Whole Wheat Spaghetti", brand: "Simply Nature", category: "Pantry", emoji: "🍝", aisle: .pantry, retailerIDs: ["aldi"]),
        .init(name: "Friendly Farms Whole Milk Greek Yogurt", brand: "Friendly Farms", category: "Fridge", emoji: "🥛", aisle: .dairy, retailerIDs: ["aldi"]),
        .init(name: "Fremont Fish Market Frozen Pink Salmon", brand: "Fremont Fish Market", category: "Freezer", emoji: "🐟", aisle: .frozen, retailerIDs: ["aldi"]),
        .init(name: "Stonemill Garlic Powder", brand: "Stonemill", category: "Staples", emoji: "🧄", aisle: .condiments, retailerIDs: ["aldi"]),
        .init(name: "Kirkwood Chicken Nuggets", brand: "Kirkwood", category: "Freezer", emoji: "🍗", aisle: .frozen, retailerIDs: ["aldi"]),
        .init(name: "Millville Crispy Rice Cereal", brand: "Millville", category: "Pantry", emoji: "🥣", aisle: .breakfast, retailerIDs: ["aldi"]),
        .init(name: "Park Street Deli Roasted Red Pepper Hummus", brand: "Park Street Deli", category: "Fridge", emoji: "🫘", aisle: .deli, retailerIDs: ["aldi"]),
        .init(name: "Sundae Shoppe Mint Chocolate Chip Ice Cream", brand: "Sundae Shoppe", category: "Freezer", emoji: "🍨", aisle: .frozen, retailerIDs: ["aldi"]),

        // Trader Joe's — 10
        .init(name: "Trader Joe's Organic Soy Beverage", brand: "Trader Joe's", category: "Pantry", emoji: "🥛", aisle: .beverages, retailerIDs: ["trader-joes"]),
        .init(name: "Trader Joe's Grilled Chimichurri Chicken Skewers", brand: "Trader Joe's", category: "Fridge", emoji: "🍗", aisle: .deli, retailerIDs: ["trader-joes"]),
        .init(name: "Trader Joe's Sugar Cookie Dough Flowers", brand: "Trader Joe's", category: "Fridge", emoji: "🍪", aisle: .baking, retailerIDs: ["trader-joes"]),
        .init(name: "Trader Joe's Organic Chicken Thighs", brand: "Trader Joe's", category: "Fridge", emoji: "🍗", aisle: .meat, retailerIDs: ["trader-joes"]),
        .init(name: "Trader Joe's Pinks & Whites Cookies", brand: "Trader Joe's", category: "Pantry", emoji: "🍪", aisle: .snacks, retailerIDs: ["trader-joes"]),
        .init(name: "Trader Joe's Garlic Butter Nut Mix", brand: "Trader Joe's", category: "Pantry", emoji: "🥜", aisle: .snacks, retailerIDs: ["trader-joes"]),
        .init(name: "Trader Joe's Salted Caramel Mochi", brand: "Trader Joe's", category: "Freezer", emoji: "🍨", aisle: .frozen, retailerIDs: ["trader-joes"]),
        .init(name: "Trader Joe's Italian Dry Salami", brand: "Trader Joe's", category: "Fridge", emoji: "🥩", aisle: .deli, retailerIDs: ["trader-joes"]),
        .init(name: "Trader Joe's Costa Rica Coffee", brand: "Trader Joe's", category: "Pantry", emoji: "☕", aisle: .breakfast, retailerIDs: ["trader-joes"]),
        .init(name: "Trader Joe's Purified Water", brand: "Trader Joe's", category: "Pantry", emoji: "💧", aisle: .beverages, retailerIDs: ["trader-joes"]),

        // Costco — 10
        .init(name: "Kirkland Signature Organic Whole Milk", brand: "Kirkland Signature", category: "Fridge", emoji: "🥛", aisle: .dairy, retailerIDs: ["costco"]),
        .init(name: "Kirkland Signature Organic Large Eggs", brand: "Kirkland Signature", category: "Fridge", emoji: "🥚", aisle: .dairy, retailerIDs: ["costco"]),
        .init(name: "Kirkland Signature Rotisserie Chicken", brand: "Kirkland Signature", category: "Fridge", emoji: "🍗", aisle: .deli, retailerIDs: ["costco"]),
        .init(name: "Kirkland Signature Extra Virgin Olive Oil", brand: "Kirkland Signature", category: "Staples", emoji: "🫒", aisle: .condiments, retailerIDs: ["costco"]),
        .init(name: "Kirkland Signature Almonds", brand: "Kirkland Signature", category: "Pantry", emoji: "🥜", aisle: .snacks, retailerIDs: ["costco"]),
        .init(name: "Kirkland Signature Wild Alaskan Salmon", brand: "Kirkland Signature", category: "Freezer", emoji: "🐟", aisle: .frozen, retailerIDs: ["costco"]),
        .init(name: "Kirkland Signature Sparkling Water", brand: "Kirkland Signature", category: "Pantry", emoji: "🥤", aisle: .beverages, retailerIDs: ["costco"]),
        .init(name: "Kirkland Signature Colombian Coffee", brand: "Kirkland Signature", category: "Pantry", emoji: "☕", aisle: .breakfast, retailerIDs: ["costco"]),
        .init(name: "Kirkland Signature Greek Yogurt", brand: "Kirkland Signature", category: "Fridge", emoji: "🥛", aisle: .dairy, retailerIDs: ["costco"]),
        .init(name: "Kirkland Signature Peanut Butter", brand: "Kirkland Signature", category: "Pantry", emoji: "🥜", aisle: .pantry, retailerIDs: ["costco"]),

        // Sam's Club — 10
        .init(name: "Member's Mark Whole Milk", brand: "Member's Mark", category: "Fridge", emoji: "🥛", aisle: .dairy, retailerIDs: ["sams-club"]),
        .init(name: "Member's Mark Cage Free Large Eggs", brand: "Member's Mark", category: "Fridge", emoji: "🥚", aisle: .dairy, retailerIDs: ["sams-club"]),
        .init(name: "Member's Mark Rotisserie Chicken", brand: "Member's Mark", category: "Fridge", emoji: "🍗", aisle: .deli, retailerIDs: ["sams-club"]),
        .init(name: "Member's Mark Extra Virgin Olive Oil", brand: "Member's Mark", category: "Staples", emoji: "🫒", aisle: .condiments, retailerIDs: ["sams-club"]),
        .init(name: "Member's Mark Mixed Nuts", brand: "Member's Mark", category: "Pantry", emoji: "🥜", aisle: .snacks, retailerIDs: ["sams-club"]),
        .init(name: "Member's Mark Atlantic Salmon", brand: "Member's Mark", category: "Fridge", emoji: "🐟", aisle: .meat, retailerIDs: ["sams-club"]),
        .init(name: "Member's Mark Purified Water", brand: "Member's Mark", category: "Pantry", emoji: "💧", aisle: .beverages, retailerIDs: ["sams-club"]),
        .init(name: "Member's Mark Colombian Coffee", brand: "Member's Mark", category: "Pantry", emoji: "☕", aisle: .breakfast, retailerIDs: ["sams-club"]),
        .init(name: "Member's Mark Greek Yogurt", brand: "Member's Mark", category: "Fridge", emoji: "🥛", aisle: .dairy, retailerIDs: ["sams-club"]),
        .init(name: "Member's Mark Creamy Peanut Butter", brand: "Member's Mark", category: "Pantry", emoji: "🥜", aisle: .pantry, retailerIDs: ["sams-club"]),

        // Safeway / Albertsons family — 10
        .init(name: "Signature Select Whole Milk", brand: "Signature Select", category: "Fridge", emoji: "🥛", aisle: .dairy, retailerIDs: ["safeway"]),
        .init(name: "Lucerne Large Eggs", brand: "Lucerne", category: "Fridge", emoji: "🥚", aisle: .dairy, retailerIDs: ["safeway"]),
        .init(name: "Lucerne Shredded Cheddar Cheese", brand: "Lucerne", category: "Fridge", emoji: "🧀", aisle: .dairy, retailerIDs: ["safeway"]),
        .init(name: "Signature Select Spaghetti", brand: "Signature Select", category: "Pantry", emoji: "🍝", aisle: .pantry, retailerIDs: ["safeway"]),
        .init(name: "Signature Select Pasta Sauce", brand: "Signature Select", category: "Pantry", emoji: "🍅", aisle: .condiments, retailerIDs: ["safeway"]),
        .init(name: "O Organics Baby Spinach", brand: "O Organics", category: "Fridge", emoji: "🥬", aisle: .produce, retailerIDs: ["safeway"]),
        .init(name: "O Organics Black Beans", brand: "O Organics", category: "Pantry", emoji: "🫘", aisle: .canned, retailerIDs: ["safeway"]),
        .init(name: "Open Nature Chicken Breast", brand: "Open Nature", category: "Fridge", emoji: "🍗", aisle: .meat, retailerIDs: ["safeway"]),
        .init(name: "Signature Select Potato Chips", brand: "Signature Select", category: "Pantry", emoji: "🥔", aisle: .snacks, retailerIDs: ["safeway"]),
        .init(name: "Signature Select Sparkling Water", brand: "Signature Select", category: "Pantry", emoji: "🥤", aisle: .beverages, retailerIDs: ["safeway"]),
    ]
}
