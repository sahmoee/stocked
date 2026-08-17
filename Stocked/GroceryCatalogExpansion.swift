// GroceryCatalogExpansion.swift
// Curated cross-department brand and product knowledge for receipt cleanup,
// predictive entry, aisle routing, and Grocery List filtering.

import Foundation

nonisolated extension ProductCatalog {
    private struct ExpansionGroup {
        let aisle: GroceryAisle
        let category: String
        let emoji: String
        let brands: [String]
        let products: [String]
    }

    /// Exactly 150 additional brands represented by 150 recognizable products across
    /// every grocery department. Package sizes and prices are intentionally omitted
    /// because they change often and make receipt matching less durable.
    static let catalogExpansion: [CatalogEntry] = {
        let groups: [ExpansionGroup] = [
            .init(aisle: .produce, category: "Fridge", emoji: "🥬",
                  brands: ["Melissa's","Pero Family Farms","BrightFarms","Revol Greens","Gotham Greens","NatureSweet","Cal-Organic Farms","Mann's","Mucci Farms","Little Potato Company"],
                  products: ["Baby Dutch Yellow Potatoes","Mini Sweet Peppers","Chopped Salad Kit","Caesar Salad Kit","Butterhead Lettuce","Cherubs Tomatoes","Rainbow Carrots","Broccoli Cole Slaw","Mini Cucumbers","Creamer Potatoes"]),
            .init(aisle: .bakery, category: "Pantry", emoji: "🍞",
                  brands: ["Dave's Killer Bread","La Brea Bakery","Toufayan Bakeries","Stonefire","Bays English Muffins","Canyon Bakehouse","Schar","Ole Mexican Foods","Joseph's","Angel Bakeries"],
                  products: ["21 Whole Grains Bread","French Baguette","Original Sweet Rolls","Original Naan","Original English Muffins","Gluten Free Bread","Gluten Free Ciabatta Rolls","Xtreme Wellness Tortillas","Flax Oat Bran Pita","Classic Pita Bread"]),
            .init(aisle: .deli, category: "Fridge", emoji: "🥪",
                  brands: ["Creminelli Fine Meats","Dietz & Watson","Columbus Craft Meats","Reser's","Cedar's","Sabra","Fresh Cravings","Kevin's Natural Foods","Cafe Spice","Del Real Foods"],
                  products: ["Oven Gold Turkey","Black Forest Ham","Italian Dry Salame","Original Potato Salad","Original Hommus","Classic Hummus","Restaurant Style Salsa","Thai Style Coconut Chicken","Chicken Tikka Masala","Carnitas"]),
            .init(aisle: .meat, category: "Fridge", emoji: "🥩",
                  brands: ["Perdue","Bell & Evans","Applegate","Jones Dairy Farm","Niman Ranch","Verlasso","Aqua Star","Northern Chef","Trident Seafoods","Fulton Fish Market"],
                  products: ["Fresh Chicken Breast","Air Chilled Chicken","Naturals Turkey Burgers","Pork Sausage","Ground Beef","Atlantic Salmon","Raw Shrimp","Shrimp Scampi","Wild Alaska Salmon","Cod Fillets"]),
            .init(aisle: .dairy, category: "Fridge", emoji: "🥛",
                  brands: ["Maple Hill Creamery","Organic Valley","Horizon Organic","Straus Family Creamery","Nancy's","Icelandic Provisions","Handsome Brook Farm","Pete & Gerry's","Rumiano","Cypress Grove"],
                  products: ["Organic Whole Milk","Whole Milk","DHA Milk","Cream Top Whole Milk","Probiotic Whole Milk Yogurt","Traditional Skyr","Pasture Raised Eggs","Organic Eggs","Medium Cheddar","Seriously Sharp Cheddar"]),
            .init(aisle: .frozen, category: "Freezer", emoji: "❄️",
                  brands: ["Rao's Made for Home","Saffron Road","Deep Indian Kitchen","Feel Good Foods","Against the Grain","Brazi Bites","Caulipower","Strong Roots","Daily Harvest","Tattooed Chef"],
                  products: ["Meat Lasagna","Chicken Tikka Masala","Chicken Curry","Vegetable Egg Rolls","Cheese Pizza","Cheese Bread","Margherita Pizza","Mixed Root Vegetable Fries","Strawberry Peach Smoothie","Acai Bowl"]),
            .init(aisle: .breakfast, category: "Pantry", emoji: "🥣",
                  brands: ["Malt-O-Meal","Seven Sundays","Magic Spoon","Catalina Crunch","Purely Elizabeth","One Degree Organic Foods","Kodiak","Birch Benders","Bonne Maman","Wild Friends"],
                  products: ["Frosted Mini Spooners","Rise and Shine Cereal","Fruity Cereal","Cinnamon Cereal","Ancient Grain Granola","Steel Cut Oats","Power Cakes Mix","Classic Pancake Mix","Strawberry Preserves","Classic Almond Butter"]),
            .init(aisle: .pantry, category: "Pantry", emoji: "🍚",
                  brands: ["Lundberg Family Farms","Tilda","RiceSelect","DeLallo","Garofalo","Jovial","Banza","Siete","Masienda","truRoots"],
                  products: ["Organic Brown Rice","Pure Basmati Rice","Royal Blend Rice","Whole Wheat Spaghetti","Organic Spaghetti","Brown Rice Pasta","Chickpea Rotini","Almond Flour Tortillas","Heirloom Corn Masa Harina","Organic Quinoa"]),
            .init(aisle: .canned, category: "Pantry", emoji: "🥫",
                  brands: ["Bush's Best","Eden Foods","Westbrae Natural","Amy's Kitchen","Pacific Foods","Kettle & Fire","Safe Catch","Wild Planet","Cento","Native Forest"],
                  products: ["Original Baked Beans","Organic Black Beans","Organic Lentils","Organic Lentil Soup","Organic Chicken Broth","Beef Bone Broth","Elite Wild Tuna","Wild Sardines","San Marzano Tomatoes","Organic Coconut Milk"]),
            .init(aisle: .baking, category: "Staples", emoji: "🧁",
                  brands: ["King Arthur Baking","Cup4Cup","Wholesome","Swerve","Guittard","Pascha Chocolate","Nielsen-Massey","Rumford","Clabber Girl","Miss Jones Baking Co."],
                  products: ["Bread Flour","Gluten Free Flour","Organic Cane Sugar","Granular Sugar Replacement","Semisweet Chocolate Chips","Premium Brownie Mix","Pure Vanilla Extract","Baking Powder","Corn Starch","Organic Vanilla Cake Mix"]),
            .init(aisle: .condiments, category: "Staples", emoji: "🥫",
                  brands: ["Primal Kitchen","Sir Kensington's","Tessemae's","Briannas","Melinda's","Yellowbird","Mike's Hot Honey","Fly By Jing","Bachan's","Graza"],
                  products: ["Avocado Oil Mayo","Classic Mayonnaise","Organic Lemon Garlic Dressing","Rich Poppy Seed Dressing","Original Hot Sauce","Habanero Hot Sauce","Original Hot Honey","Sichuan Chili Crisp","Original Japanese Barbecue Sauce","Sizzle Extra Virgin Olive Oil"]),
            .init(aisle: .snacks, category: "Pantry", emoji: "🥨",
                  brands: ["LesserEvil","Hippeas","Biena","SkinnyDipped","Sahale Snacks","MadeGood","Simple Mills","Partake","Snyder's of Hanover","Dot's Homestyle Pretzels"],
                  products: ["Himalayan Pink Salt Popcorn","Vegan White Cheddar Puffs","Sea Salt Chickpea Snacks","Dark Chocolate Almonds","Maple Pecans","Chocolate Chip Granola Minis","Almond Flour Crackers","Chocolate Chip Cookies","Pretzel Pieces","Original Seasoned Pretzels"]),
            .init(aisle: .beverages, category: "Pantry", emoji: "🥤",
                  brands: ["Spindrift","Waterloo","Liquid Death","Harmless Harvest","Brew Dr. Kombucha","GT's Living Foods","Runa","Poppi","Olipop","Stumptown Coffee Roasters"],
                  products: ["Lemon Sparkling Water","Black Cherry Sparkling Water","Mountain Water","Organic Coconut Water","Pink Lady Apple Kombucha","Gingerade Kombucha","Clean Energy Drink","Strawberry Lemon Prebiotic Soda","Vintage Cola","Hair Bender Coffee"]),
            .init(aisle: .household, category: "Pantry", emoji: "🧽",
                  brands: ["Seventh Generation","Mrs. Meyer's Clean Day","Method","Ecover","Dropps","Blueland","If You Care","Stasher","Repurpose","Caboo"],
                  products: ["Free and Clear Detergent","Lemon Verbena Dish Soap","All Purpose Cleaner","Automatic Dishwasher Tablets","Laundry Detergent Pods","Multi Surface Cleaner","Parchment Baking Paper","Reusable Silicone Bag","Compostable Plates","Bamboo Paper Towels"]),
            .init(aisle: .baby, category: "Pantry", emoji: "👶",
                  brands: ["Happy Baby Organics","Once Upon a Farm","Serenity Kids","Cerebelly","Else Nutrition"],
                  products: ["Banana Raspberries Oats","Apple Sweet Potato Pouch","Free Range Chicken Pouch","Carrot Chickpea Pouch","Plant Based Toddler Nutrition"]),
            .init(aisle: .pets, category: "Pantry", emoji: "🐾",
                  brands: ["Open Farm","The Honest Kitchen","Stella & Chewy's","Orijen","Weruva"],
                  products: ["Homestead Turkey Dog Food","Whole Grain Chicken Dog Food","Freeze Dried Beef Patties","Original Dog Food","Paw Lickin Chicken Cat Food"])
        ]
        return groups.flatMap { group in
            zip(group.brands, group.products).map { brand, product in
                CatalogEntry(name: "\(brand) \(product)", brand: brand,
                             category: group.category, emoji: group.emoji, aisle: group.aisle)
            }
        }
    }()

    static let catalogExpansionBrandNames: [String] =
        catalogExpansion.map(\.brand).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
}
