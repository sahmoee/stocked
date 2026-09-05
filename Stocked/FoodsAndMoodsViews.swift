
// MARK: - Inventory availability helper
func isInInventory(_ item: String, store: GuestDataStore) -> Bool {
    store.inventoryItems.contains { $0.name.localizedCaseInsensitiveContains(item) }
}
// FoodsAndMoodsViews.swift — Foods + Moods selection screens
// Moods subcategory → fetches matching recipe from TheMealDB every load
import SwiftUI
import Combine

// MARK: - Shared category row
struct CategoryRow: View {
    @Environment(AppSession.self) var session
    let icon: String
    let emoji: String
    let label: String
    var accentColor: Color = Color.stockedWhite
    var assetName: String? = nil

    var body: some View {
        if let name = assetName {
            CookIllustratedRow(title: label, assetName: name, fallbackIcon: icon,
                               tone: .soft, artSize: 88)
                .padding(.horizontal, 20)
        } else {
            plainRow
        }
    }

    // Photo present: a full-photo card with the label overlaid, matching the Cook cards.
    private func photoRow(_ photo: Image) -> some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.black.opacity(0.3)).frame(width: 52, height: 52)
                Circle().strokeBorder(Color.white.opacity(0.6), lineWidth: 1.5).frame(width: 52, height: 52)
                if !emoji.isEmpty { Text(emoji).scaledFont(24) }
                else { Image(systemName: icon).scaledFont(22, weight: .light).foregroundStyle(Color.white) }
            }
            Text(label)
                .scaledFont(22, weight: .semibold, design: .serif)
                .foregroundStyle(Color.white)
                .shadow(color: Color.black.opacity(0.55), radius: 3, y: 1)
            Spacer()
            Image(systemName: "chevron.right").scaledFont(14, weight: .bold)
                .foregroundStyle(Color.white.opacity(0.9))
                .shadow(color: Color.black.opacity(0.5), radius: 2, y: 1)
        }
        .padding(.horizontal, 22)
        .frame(height: 96)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                photo.resizable().scaledToFill()
                LinearGradient(
                    colors: [Color.black.opacity(0.66), Color.black.opacity(0.32), Color.black.opacity(0.0)],
                    startPoint: .leading, endPoint: .trailing)
            }
            // Clip the overflowing scaledToFill image before it joins the hit-test bounds.
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        )
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        // Hit area limited to the visible card so a tap never bleeds onto the next card.
        .contentShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
        .padding(.horizontal, 20)
    }

    // No photo: the original row, unchanged.
    private var plainRow: some View {
        HStack(spacing: 20) {
            ZStack {
                Circle().fill(Color.stockedCharcoal).frame(width: 72, height: 72)
                Circle().stroke(Color.stockedWhite, lineWidth: 2.5).frame(width: 72, height: 72)
                Image(systemName: icon)
                    .scaledFont(26, weight: .light)
                    .foregroundStyle(Color.stockedWhite)
            }
            Text(label)
                .scaledFont(22, weight: .regular, design: .serif)
                .foregroundStyle(accentColor)
            Spacer()
        }
        .padding(.horizontal, 28)
    }
}

// MARK: - Foods Category
struct FoodsCategoryView: View {
    @Environment(AppSession.self) var session
    let servings: Int
    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Foods")
                    .scaledFont(40, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                    .padding(.horizontal, 28).padding(.bottom, 4)
                Text("Build your meal around")
                    .scaledFont(17, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeSecondaryText)
                    .padding(.horizontal, 28).padding(.bottom, 20)

                // Rows spread evenly to fill the screen
                VStack(spacing: 0) {
                    Spacer()
                    NavigationLink(destination: FoodsSubOptionView(category: "Protein", icon: "🍗", servings: servings)) {
                        CategoryRow(icon: "fork.knife", emoji: "🍗", label: "Protein", assetName: "protein")
                    }.buttonStyle(.plain)
                    Spacer()
                    NavigationLink(destination: FoodsSubOptionView(category: "Vegetables", icon: "🥕", servings: servings)) {
                        CategoryRow(icon: "leaf", emoji: "🥕", label: "Vegetables", assetName: "vegetables")
                    }.buttonStyle(.plain)
                    Spacer()
                    NavigationLink(destination: FoodsSubOptionView(category: "Expiring Soon", icon: "📅", servings: servings)) {
                        CategoryRow(icon: "calendar", emoji: "📅", label: "Expiring Soon", assetName: "expiring_soon")
                    }.buttonStyle(.plain)
                    Spacer()
                    NavigationLink(destination: FoodsSubOptionView(category: "Leftovers", icon: "🥡", servings: servings)) {
                        CategoryRow(icon: "takeoutbag.and.cup.and.straw.fill", emoji: "🥡", label: "Leftovers", assetName: "leftovers")
                    }.buttonStyle(.plain)
                    Spacer()
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: - Foods Sub-option

/// One tappable option on a Cook sub-option screen. `asset` names a transparent illustration in
/// the catalog; if it is missing, CookIllustratedRow falls back to an emoji/glyph badge.
struct CookFoodOption: Identifiable, Hashable {
    var id: String { title }
    let title: String
    let subtitle: String
    let asset: String
}

struct FoodsSubOptionView: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion
    let category: String
    let icon: String
    let servings: Int

    // ── Option catalog ──────────────────────────────────────────────────────
    // Protein and Vegetables are grouped at runtime by what is actually in the pantry, so their
    // options are listed flat. Expiring Soon and Leftovers use fixed sections.
    private static let proteinOptions: [CookFoodOption] = [
        .init(title: "Chicken", subtitle: "Roast, grill, or shred it into anything.", asset: "pro_chicken"),
        .init(title: "Beef",    subtitle: "Steaks, ground beef, and slow braises.",   asset: "pro_beef"),
        .init(title: "Pork",    subtitle: "Chops, tenderloin, bacon, and sausage.",   asset: "pro_pork"),
        .init(title: "Seafood", subtitle: "Fish and shellfish, ready fast.",          asset: "pro_seafood"),
        .init(title: "Tofu",    subtitle: "Crisp it, crumble it, or simmer it.",      asset: "pro_tofu"),
        .init(title: "Eggs",    subtitle: "Breakfast, dinner, or anything between.",  asset: "pro_eggs"),
        .init(title: "Lamb",    subtitle: "Rich and hearty for a bigger meal.",       asset: "pro_lamb"),
    ]

    private static let vegetableOptions: [CookFoodOption] = [
        .init(title: "Leafy Greens",      subtitle: "Spinach, kale, lettuce, and more.",                     asset: "veg_leafy_greens"),
        .init(title: "Root Vegetables",   subtitle: "Carrots, potatoes, beets, and turnips.",                asset: "veg_root_vegetables"),
        .init(title: "Cruciferous",       subtitle: "Broccoli, cauliflower, cabbage, and Brussels sprouts.", asset: "veg_cruciferous"),
        .init(title: "Peppers & Tomatoes", subtitle: "Fresh, bright, and easy to build around.",             asset: "veg_peppers_tomatoes"),
        .init(title: "Mushrooms",         subtitle: "Earthy and savory in almost anything.",                 asset: "veg_mushrooms"),
        .init(title: "Squash & Zucchini", subtitle: "Roast it, sauté it, or slice it into pasta.",           asset: "veg_squash_zucchini"),
        .init(title: "Fresh Herbs",       subtitle: "Finish a dish with a little brightness.",               asset: "veg_fresh_herbs"),
    ]

    private static let leftoverSections: [(String, [CookFoodOption])] = [
        ("Use tonight", [
            .init(title: "Reinvent It",       subtitle: "Turn leftovers into something new.",             asset: "left_reinvent_it"),
            .init(title: "Simple Reheat",     subtitle: "Warm it up and finish with sides.",              asset: "left_simple_reheat"),
            .init(title: "Build a Bowl",      subtitle: "Mix grains, protein, and vegetables.",           asset: "left_build_a_bowl"),
            .init(title: "Wrap or Sandwich",  subtitle: "Great for quick lunches and easy dinners.",      asset: "left_wrap_or_sandwich"),
        ]),
        ("Need inspiration", [
            .init(title: "Pasta & Rice Remix", subtitle: "Use cooked extras in fast meals.",              asset: "left_pasta_rice_remix"),
            .init(title: "Soup or Skillet",    subtitle: "A flexible way to use what's left.",            asset: "left_soup_or_skillet"),
        ]),
    ]

    private static let expiringSections: [(String, [CookFoodOption])] = [
        ("Cook now", [
            .init(title: "Use What's Left",  subtitle: "Start with the items that should go first.",  asset: "exp_use_whats_left"),
            .init(title: "Flexible Meals",   subtitle: "Bowls, pastas, skillets, and stir-fries.",    asset: "exp_flexible_meals"),
            .init(title: "Quick Rescue",     subtitle: "Fast ideas for produce that's fading.",       asset: "exp_quick_rescue"),
            .init(title: "Batch Prep",       subtitle: "Cook now to save ingredients for later.",     asset: "exp_batch_prep"),
        ]),
        ("Keep it from going to waste", [
            .init(title: "Freeze or Prep",      subtitle: "Simple ways to buy more time.",           asset: "exp_freeze_or_prep"),
            .init(title: "Add One Ingredient",  subtitle: "Complete the meal with a quick shop.",    asset: "exp_add_one_ingredient"),
        ]),
    ]

    @State private var selected: String?
    @State private var gotoRecipe = false
    @State private var pendingUnstocked: String? = nil  // item tapped but not in stock
    @State private var addedToList: String? = nil        // confirmation feedback

    /// True for the two categories whose rows are graded against real inventory.
    private var pantryGraded: Bool { category == "Protein" || category == "Vegetables" }

    private var flatOptions: [CookFoodOption] {
        switch category {
        case "Protein":    return Self.proteinOptions
        case "Vegetables": return Self.vegetableOptions
        default:           return []
        }
    }

    /// The screen as sections. Protein and Vegetables split live by what is in the pantry;
    /// Leftovers and Expiring Soon use their authored sections.
    private var sections: [(title: String, options: [CookFoodOption])] {
        switch category {
        case "Protein", "Vegetables":
            let stocked = flatOptions.filter { isInInventory($0.title, store: session.guestStore) }
            let rest    = flatOptions.filter { !isInInventory($0.title, store: session.guestStore) }
            var out: [(String, [CookFoodOption])] = []
            if !stocked.isEmpty { out.append(("In your pantry", stocked)) }
            if !rest.isEmpty    { out.append(("Plan ahead", rest)) }
            return out.map { (title: $0.0, options: $0.1) }
        case "Leftovers":
            return Self.leftoverSections.map { (title: $0.0, options: $0.1) }
        case "Expiring Soon":
            return Self.expiringSections.map { (title: $0.0, options: $0.1) }
        default:
            return []
        }
    }

    private var headline: String {
        switch category {
        case "Expiring Soon": return "Use what needs attention first."
        case "Leftovers":     return "Start with what's already cooked."
        default:              return "Choose what you want to cook with first."
        }
    }

    /// Back-compat: the flat list of option titles this screen shows.
    var options: [String] { sections.flatMap { $0.options }.map(\.title) }

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 20) {
                    ZStack {
                        Circle().fill(Color.stockedCharcoal).frame(width: 72, height: 72)
                        Text(icon).scaledFont(32)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(category)
                            .scaledFont(28, weight: .regular, design: .serif)
                            .foregroundStyle(Color.stockedWhite)
                        Text(headline)
                            .scaledFont(13)
                            .foregroundStyle(session.themeTextColor.opacity(0.6))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 24)

                // Inventory legend (protein + veg categories only)
                if pantryGraded {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 16) {
                            HStack(spacing: 5) {
                                Circle().fill(Color.stockedGold).frame(width: 8, height: 8)
                                Text("In your pantry").scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.6))
                            }
                            HStack(spacing: 5) {
                                Circle().fill(session.themeTextColor.opacity(0.2)).frame(width: 8, height: 8)
                                Text("Not in pantry").scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.6))
                            }
                        }
                        HStack(spacing: 6) {
                            Image(systemName: "hand.tap")
                                .scaledFont(11)
                                .foregroundStyle(session.themeTextColor.opacity(0.4))
                            Text("Dimmed items aren't in your pantry — you can still select them to plan ahead or shop for ingredients.")
                                .scaledFont(11)
                                .foregroundStyle(session.themeTextColor.opacity(0.4))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.horizontal, 28).padding(.bottom, 16)
                }

                VStack(alignment: .leading, spacing: 20) {
                    ForEach(Array(sections.enumerated()), id: \.element.title) { pair in
                        let index = pair.offset
                        let section = pair.element
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .scaledFont(13, weight: .bold, design: .serif)
                                .foregroundStyle(session.themeTextColor.opacity(0.75))

                            ForEach(section.options) { opt in
                                let inStock = pantryGraded
                                    ? isInInventory(opt.title, store: session.guestStore) : true
                                let justAdded = addedToList == opt.title
                                let sub: String = {
                                    if justAdded { return "Added to grocery list ✓" }
                                    if !inStock  { return "Tap to explore options." }
                                    return opt.subtitle
                                }()
                                CookIllustratedRow(
                                    title: opt.title,
                                    subtitle: sub,
                                    assetName: opt.asset,
                                    fallbackEmoji: icon,
                                    tone: index == 0 ? .dark : .soft,
                                    artSize: 68,
                                    showPantryPill: pantryGraded && inStock,
                                    showCartGlyph: pantryGraded && !inStock,
                                    dimmed: !inStock
                                ) {
                                    if inStock {
                                        motion.animate(.selection, intent: .spatial) { selected = opt.title }
                                        Task {
                                            try? await Task.sleep(nanoseconds: 300000000)
                                            gotoRecipe = true
                                        }
                                    } else {
                                        motion.animate(.standard, intent: .spatial) { pendingUnstocked = opt.title }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 28)
                // Bottom sheet for unstocked item
                .sheet(item: Binding(
                    get: { pendingUnstocked.map { UnstockedItem(name: $0) } },
                    set: { pendingUnstocked = $0?.name }
                )) { item in
                    UnstockedOptionSheet(
                        itemName: item.name,
                        onContinue: {
                            pendingUnstocked = nil
                            selected = item.name
                            Task {
                                try? await Task.sleep(nanoseconds: 150000000)
                                gotoRecipe = true
                            }
                        },
                        onAddToList: {
                            let name = item.name
                            session.guestStore.addGroceryItem(name: name)
                            pendingUnstocked = nil
                            withAnimation { addedToList = name }
                            Task {
                                try? await Task.sleep(nanoseconds: 2500000000)
                                withAnimation { if addedToList == name { addedToList = nil } }
                            }
                        }
                    )
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                }
            }
        }
        .navigationDestination(isPresented: $gotoRecipe) {
            if let selected {
                // Cook Now redesign: selecting an ingredient presents one strong
                // recommendation first (Smart Recommendation) instead of dropping
                // straight into a long list. See All remains one tap away inside.
                SmartRecommendationView(mode: .ingredient(selected))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            gotoRecipe = false
        }
    }
}

// MARK: - Moods Category
struct MoodsCategoryView: View {
    @Environment(AppSession.self) var session
    let servings: Int
    let categories: [(label: String, sfIcon: String, description: String)] = [
        ("Today's Energy", "bolt.circle",   "How much effort do you have?"),
        ("Current Mood",   "face.smiling",  "What are you feeling right now?"),
        ("Cooking Style",  "flame",         "How do you want to cook?"),
        ("Passport Plates","globe",         "Where in the world tonight?"),
    ]
    var body: some View {
        StockedShell(showBack: true, scrollDisabled: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    Text("Moods")
                        .scaledFont(40, weight: .bold, design: .serif)
                        .foregroundStyle(Color.stockedGold)
                    Text("by")
                        .scaledFont(22, weight: .regular, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                }
                .padding(.horizontal, 28).padding(.bottom, 8)
                Text("Let your vibe decide the recipe.")
                    .scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.55))
                    .padding(.horizontal, 28).padding(.bottom, 32)

                VStack(spacing: 24) {
                    ForEach(categories, id: \.label) { cat in
                        NavigationLink(destination: MoodsSubOptionView(category: cat.label, servings: servings)) {
                            HStack(spacing: 20) {
                                ZStack {
                                    Circle().fill(Color.stockedCharcoal).frame(width: 72, height: 72)
                                    Circle().stroke(Color.stockedGold, lineWidth: 3).frame(width: 72, height: 72)
                                    Image(systemName: cat.sfIcon)
                                        .scaledFont(28).foregroundStyle(Color.stockedGold)
                                }
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(cat.label)
                                        .scaledFont(22, weight: .regular, design: .serif)
                                        .foregroundStyle(Color.stockedGold)
                                    Text(cat.description)
                                        .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .scaledFont(14).foregroundStyle(Color.stockedGold.opacity(0.4))
                            }
                            .padding(.horizontal, 28)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}

// MARK: - Moods keyword map
// Each subcategory maps to a list of TheMealDB search terms
// One is picked at random each time so it refreshes
private let moodKeywords: [String: [String]] = [
    // Today's Energy
    "Zero Energy":      ["soup","broth","cereal","porridge","toast"],
    "Quick & Easy":     ["pasta","omelette","sandwich","fried rice","noodles"],
    "One Pan & Done":   ["stir fry","shakshuka","frittata","skillet","hash"],
    "Feeling Chef-y":   ["risotto","beef wellington","duck confit","lobster","rack of lamb"],

    // Current Mood
    "Craving Comfort":  ["mac and cheese","chicken pot pie","beef stew","lasagna","mashed potato"],
    "Keep it Light":    ["salad","grilled chicken","sushi","ceviche","spring rolls"],
    "Kid-Approved":     ["nuggets","pizza","mac and cheese","pancakes","hot dog"],
    "Treat Yourself":   ["chocolate cake","cheesecake","steak","lobster","tiramisu"],
    "Cozy Night In":    ["beef stew","french onion soup","shepherd pie","beef bourguignon","ratatouille"],

    // Cooking Style
    "One Pot":          ["stew","curry","chili","braised","casserole"],
    "Grill":            ["bbq ribs","grilled chicken","burger","kebab","corn on the cob"],
    "Bake":             ["roast chicken","lasagna","quiche","focaccia","salmon en papillote"],
    "Air Fryer":        ["chicken wings","falafel","spring rolls","sweet potato","prawn"],
    "Raw/No Cook":      ["sushi","ceviche","spring rolls","poke","bruschetta"],

    // Passport Plates
    "Italian":          ["pasta carbonara","risotto","pizza","osso buco","tiramisu"],
    "Mexican":          ["tacos","enchiladas","guacamole","pozole","churros"],
    "Asian":            ["pad thai","sushi","dim sum","pho","bibimbap"],
    "Mediterranean":    ["falafel","hummus","greek salad","moussaka","baklava"],
    "American":         ["burger","bbq ribs","mac and cheese","clam chowder","key lime pie"],
    "Indian":           ["butter chicken","biryani","dal","samosa","tikka masala"],
    "Caribbean":        ["jerk chicken","rice and peas","curry goat","roti","ackee"],
    "Japanese":         ["ramen","sushi","teriyaki","miso soup","katsu"],
    "Thai":             ["pad thai","green curry","tom yum","mango sticky rice","satay"],
    "French":           ["french onion soup","ratatouille","coq au vin","crepes","bouillabaisse"],
    "Middle Eastern":   ["falafel","shawarma","hummus","tabbouleh","baklava"],
    "Korean":           ["bibimbap","bulgogi","kimchi","japchae","tteokbokki"],
    "Greek":            ["moussaka","souvlaki","spanakopita","greek salad","baklava"],
    "Spanish":          ["paella","gazpacho","tortilla española","croquetas","churros"],
]

// MARK: - Moods Sub-option View
struct MoodsSubOptionView: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion
    let category: String
    let servings: Int

    let optionsMap: [String: [(label: String, emoji: String, description: String)]] = [
        "Today's Energy": [
            ("Zero Energy",     "🛋️", "Minimal effort, maximum comfort"),
            ("Quick & Easy",    "⚡️", "On the table in 20 minutes"),
            ("One Pan & Done",  "🍳", "Cook it all in one go"),
            ("Feeling Chef-y",  "👨‍🍳", "Pull out all the stops tonight"),
        ],
        "Current Mood": [
            ("Craving Comfort", "🤗", "Hug in a bowl, every time"),
            ("Keep it Light",   "🌿", "Fresh, clean and energising"),
            ("Kid-Approved",    "👧", "Even the pickiest eater will love it"),
            ("Treat Yourself",  "🎁", "You deserve something special"),
            ("Cozy Night In",   "🕯️", "Slow, warm and satisfying"),
        ],
        "Cooking Style": [
            ("One Pot",         "🥘", "One pot, zero fuss, full flavour"),
            ("Grill",           "🔥", "Char marks and smoky goodness"),
            ("Bake",            "🫙", "Let the oven do the work"),
            ("Air Fryer",       "💨", "Crispy outside, tender inside"),
            ("Raw/No Cook",     "🥗", "Fresh and ready in minutes"),
        ],
        "Passport Plates": [
            ("Italian",         "🍝", "Pasta, risotto, and beyond"),
            ("Mexican",         "🌮", "Bold spices and vibrant flavours"),
            ("Asian",           "🥢", "From Japan to Thailand"),
            ("Mediterranean",   "🫒", "Olive oil, herbs, and sunshine"),
            ("American",        "🍔", "Classics done right"),
            ("Indian",          "🫕", "Rich curries and aromatic spices"),
            ("Caribbean",       "🌴", "Island heat and tropical soul"),
            ("Japanese",        "🍱", "Precision, balance, beauty"),
            ("Thai",            "🌶️", "Sweet, sour, spicy, aromatic"),
            ("French",          "🥐", "Technique and elegance"),
            ("Middle Eastern",  "🧆", "Depth of spice and tradition"),
            ("Korean",          "🍲", "Fermented, fiery, fresh"),
            ("Greek",           "🫙", "Sun-drenched Mediterranean fare"),
            ("Spanish",         "🥘", "Saffron, paprika, and paella"),
        ],
    ]

    let iconsMap: [String: String] = [
        "Today's Energy":  "bolt.circle",
        "Current Mood":    "face.smiling",
        "Cooking Style":   "flame",
        "Passport Plates": "globe",
    ]

    @State private var selectedOption: (label: String, emoji: String, description: String)? = nil
    @State private var navigateToRecipe = false

    var options: [(label: String, emoji: String, description: String)] {
        optionsMap[category] ?? []
    }

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                HStack(spacing: 20) {
                    ZStack {
                        Circle().fill(Color.stockedCharcoal).frame(width: 72, height: 72)
                        Circle().stroke(Color.stockedGold, lineWidth: 3).frame(width: 72, height: 72)
                        Image(systemName: iconsMap[category] ?? "sparkles")
                            .scaledFont(28).foregroundStyle(Color.stockedGold)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(category)
                            .scaledFont(24, weight: .regular, design: .serif)
                            .foregroundStyle(Color.stockedGold)
                        Text("Tap a vibe — we'll find the recipe.")
                            .scaledFont(12)
                            .foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 32)

                // Option buttons — each shows emoji + label + description
                VStack(spacing: 14) {
                    ForEach(options, id: \.label) { opt in
                        Button {
                            motion.animate(.selection, intent: .spatial) {
                                selectedOption = opt
                            }
                            Task {
                                try? await Task.sleep(nanoseconds: 250000000)
                                navigateToRecipe = true
                            }
                        } label: {
                            HStack(spacing: 16) {
                                Text(opt.emoji)
                                    .scaledFont(24)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(opt.label)
                                        .scaledFont(17, weight: .semibold, design: .serif)
                                        .foregroundStyle(Color.stockedGold)
                                    Text(opt.description)
                                        .scaledFont(12)
                                        .foregroundStyle(Color.stockedWhite.opacity(0.55))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .scaledFont(12).foregroundStyle(Color.stockedGold.opacity(0.5))
                            }
                            .padding(.horizontal, 20).padding(.vertical, 15)
                            .background(Color.stockedCharcoal)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)
                    }
                }
            }
        }
        .navigationDestination(isPresented: $navigateToRecipe) {
            if let opt = selectedOption {
                MoodRecipeFinderView(
                    category:    category,
                    subcategory: opt.label,
                    emoji:       opt.emoji,
                    servings:    servings
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            navigateToRecipe = false
        }
    }
}

// MARK: - Mood Recipe Finder (fetches a matching internet recipe, refreshes every load)
struct MoodRecipeFinderView: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedMotion) private var motion
    let category:    String
    let subcategory: String
    let emoji:       String
    let servings:    Int
    // Optional Match My Mood answers — used to steer the AI fallback and time filtering.
    var energy: String? = nil
    var timeBudget: String? = nil

    @State private var recipe:     FetchedMoodRecipe? = nil
    @State private var isLoading   = true
    @State private var failed      = false
    @State private var goToOverview = false
    @State private var sourceNote  = ""      // where the recipe came from (web / your database / AI)
    @State private var fetchTask: Task<Void, Never>? = nil

    var body: some View {
        StockedShell(showBack: true) {
            VStack(spacing: 0) {
                if isLoading {
                    loadingView
                } else if let r = recipe {
                    recipePreview(r)
                } else {
                    failedView
                }
            }
        }
        .navigationDestination(isPresented: $goToOverview) {
            if let r = recipe {
                RecipeOverviewView(
                    title:       r.title,
                    servings:    servings,
                    ingredients: r.ingredients,
                    steps:       r.steps,
                    cookTime:    r.cookTime,
                    prepTime:    r.prepTime
                )
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            goToOverview = false
        }
        .onAppear { fetchRecipe() }
        .onDisappear { fetchTask?.cancel() }
    }

    // MARK: Loading
    private var loadingView: some View {
        VStack(spacing: 28) {
            Spacer()
            Text(emoji).scaledFont(64)
                .scaleEffect(isLoading ? 1.1 : 1)
                .animation(
                    isLoading && motion.permitsContinuousMotion
                        ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                        : nil,
                    value: isLoading
                )
            VStack(spacing: 8) {
                Text("Finding your \(subcategory) recipe…")
                    .scaledFont(20, weight: .semibold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                    .multilineTextAlignment(.center)
                Text("Checking the web, your database, and AI for the perfect match")
                    .scaledFont(13)
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            ProgressView().tint(Color.stockedGold).scaleEffect(1.4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
    }

    // MARK: Recipe preview card
    private func recipePreview(_ r: FetchedMoodRecipe) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Mood label
            HStack(spacing: 8) {
                Text(emoji).scaledFont(18)
                Text("\(category)  ›  \(subcategory)")
                    .scaledFont(12, weight: .semibold)
                    .foregroundStyle(Color.stockedGold)
            }
            .padding(.horizontal, 24).padding(.bottom, 12)

            // Hero image
            if let url = URL(string: r.imageURL) {
                CachedAsyncImage(url: url.absoluteString, imageData: nil, height: 180)
                .padding(.horizontal, 20).padding(.bottom, 16)
            }

            // Title + meta
            VStack(alignment: .leading, spacing: 6) {
                Text(r.title)
                    .scaledFont(26, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                HStack(spacing: 16) {
                    Label(r.prepTime, systemImage: "clock").scaledFont(12)
                    Label(r.cookTime, systemImage: "flame").scaledFont(12)
                    Label("\(servings) servings", systemImage: "person.2").scaledFont(12)
                }
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                if !sourceNote.isEmpty {
                    Label(sourceNote, systemImage: "sparkles")
                        .scaledFont(11, weight: .semibold)
                        .foregroundStyle(Color.stockedGold)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 16)

            // Top ingredients preview
            VStack(alignment: .leading, spacing: 6) {
                Text("Key Ingredients")
                    .scaledFont(13, weight: .bold).foregroundStyle(session.themeTextColor.opacity(0.5))
                FlowLayout(items: Array(r.ingredients.prefix(8))) { ing in
                    Text(ing)
                        .scaledFont(12, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(session.themeCardColor)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 20)

            // Action buttons
            VStack(spacing: 12) {
                Button { goToOverview = true } label: {
                    Text("Cook This Recipe")
                        .scaledFont(18, weight: .semibold, design: .serif)
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }.buttonStyle(.plain)

                Button { fetchRecipe() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.clockwise")
                        Text("Try a Different Recipe")
                    }
                    .scaledFont(15, weight: .semibold, design: .serif)
                    .foregroundStyle(Color.stockedGold)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .background(Color.stockedGold.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }.buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
        }
    }

    // MARK: Failed state
    private var failedView: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "wifi.slash").scaledFont(44).foregroundStyle(session.themeTextColor.opacity(0.25))
            Text("Couldn't find a recipe right now.")
                .scaledFont(17, design: .serif).foregroundStyle(session.themeTextColor.opacity(0.6))
            Button { fetchRecipe() } label: {
                Label("Try Again", systemImage: "arrow.clockwise")
                    .scaledFont(15, weight: .semibold).foregroundStyle(Color.stockedWhite)
                    .padding(.horizontal, 28).padding(.vertical, 14)
                    .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
            }.buttonStyle(.plain)
            Spacer()
        }.frame(maxWidth: .infinity)
    }

    // MARK: Fetch logic — layered so the flow ALWAYS lands on a recipe.
    //   1. TheMealDB web search (existing behavior).
    //   2. The bundled 98k-recipe database (RecipeStore) — offline-safe.
    //   3. AI generation via the Stocked Worker, steered by mood, energy, and time.
    //   4. The starter/saved catalogue — guaranteed local content.
    // The failed state remains only as a truly-last-resort retry screen.
    private func fetchRecipe() {
        isLoading = true
        failed    = false
        recipe    = nil
        sourceNote = ""

        let keywords = moodKeywords[subcategory] ?? [subcategory.lowercased()]
        let keyword  = keywords.randomElement() ?? subcategory.lowercased()

        fetchTask?.cancel()
        fetchTask = Task { @MainActor in
            // 1 — Web (TheMealDB), as before.
            if let web = await fetchFromMealDB(keyword: keyword) {
                recipe = web; sourceNote = ""; isLoading = false; return
            }
            if Task.isCancelled { return }

            // 2 — Bundled recipe database: try each mood keyword until something hits.
            if let local = await fetchFromLocalDatabase(keywords: keywords) {
                recipe = local; sourceNote = "From your recipe database"; isLoading = false; return
            }
            if Task.isCancelled { return }

            // 3 — AI: generate a recipe matched to the mood answers.
            if let ai = await fetchFromAI(keyword: keyword) {
                recipe = ai; sourceNote = "Created by AI for your mood"; isLoading = false; return
            }
            if Task.isCancelled { return }

            // 4 — Starter/saved catalogue: always available.
            if let starter = fetchFromStarterCatalog(keywords: keywords) {
                recipe = starter; sourceNote = "From your saved recipes"; isLoading = false; return
            }

            isLoading = false
            failed = true
        }
    }

    // Layer 1 — TheMealDB (async wrapper around the original request).
    private func fetchFromMealDB(keyword: String) async -> FetchedMoodRecipe? {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/search.php?s=\(encoded)") else { return nil }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]],
              let m = meals.randomElement() else { return nil }

        let title    = m["strMeal"]      as? String ?? keyword.capitalized
        let imageURL = m["strMealThumb"] as? String ?? ""
        let raw = m["strInstructions"] as? String ?? ""
        let steps = raw
            .components(separatedBy: CharacterSet.newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 15 }
            .prefix(8).map { $0 }
        var ings: [String] = []
        for i in 1...20 {
            let ing  = (m["strIngredient\(i)"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            let meas = (m["strMeasure\(i)"]    as? String ?? "").trimmingCharacters(in: .whitespaces)
            if !ing.isEmpty { ings.append(meas.isEmpty ? ing : "\(meas) \(ing)") }
        }
        guard !ings.isEmpty || !steps.isEmpty else { return nil }
        return FetchedMoodRecipe(title: title, imageURL: imageURL, ingredients: ings,
                                 steps: Array(steps), cookTime: "30 min", prepTime: "15 min")
    }

    // Layer 2 — bundled 98k-recipe sqlite. Tries keywords in random order; prefers entries
    // that actually have steps so the overview screen isn't empty.
    private func fetchFromLocalDatabase(keywords: [String]) async -> FetchedMoodRecipe? {
        guard await RecipeStore.shared.isAvailable() else { return nil }
        for keyword in keywords.shuffled() {
            let hits = await RecipeStore.shared.search(keyword, limit: 6)
            if let pick = hits.filter({ !$0.steps.isEmpty && !$0.ingredients.isEmpty }).randomElement()
                        ?? hits.randomElement() {
                return FetchedMoodRecipe(
                    title: pick.title,
                    imageURL: pick.imageURL,
                    ingredients: pick.ingredients,
                    steps: pick.steps,
                    cookTime: pick.cookTime.isEmpty ? "30 min" : pick.cookTime,
                    prepTime: pick.prepTime.isEmpty ? "15 min" : pick.prepTime
                )
            }
        }
        return nil
    }

    // Layer 3 — AI generation via the Worker, steered by every mood answer plus what's on hand.
    private func fetchFromAI(keyword: String) async -> FetchedMoodRecipe? {
        guard RecipeGeneratorAI.isAvailable else { return nil }
        var idea = "A \(subcategory.lowercased()) \(keyword) style meal"
        if let energy { idea += ", for a \(energy.lowercased()) energy evening" }
        let availableItems = session.guestStore.inventoryItems
            .filter { $0.effectiveLevel > 0 }
        let onHand = availableItems.prefix(12).map { $0.name }
        let mustUse = availableItems
            .sorted { ($0.daysUntilExpiry ?? Int.max) < ($1.daysUntilExpiry ?? Int.max) }
            .prefix(5)
            .map(\.name)
        var options = RecipeGeneratorAI.Options(
            haveItems: Array(onHand),
            cuisinePreference: session.guestStore.cookingProfile.cuisinePrefs,
            mustUse: Array(mustUse),
            dietaryRules: DietaryGuard.Rules(allergens: session.guestStore.cookingProfile.allergens)
        )
        if let timeBudget { options.maxTime = timeBudget }
        guard let g = await RecipeGeneratorAI.generate(idea: idea, options: options) else { return nil }
        let ings = g.ingredients.map { $0.amount.isEmpty ? $0.name : "\($0.amount) \($0.name)" }
        guard !ings.isEmpty || !g.steps.isEmpty else { return nil }
        return FetchedMoodRecipe(
            title: g.title,
            imageURL: "",
            ingredients: ings,
            steps: g.steps,
            cookTime: g.cookTime.isEmpty ? "30 min" : g.cookTime,
            prepTime: "15 min"
        )
    }

    // Layer 4 — starter + saved recipes: keyword match first, otherwise any starter.
    private func fetchFromStarterCatalog(keywords: [String]) -> FetchedMoodRecipe? {
        let catalog = session.guestStore.cookCatalog
        guard !catalog.isEmpty else { return nil }
        let pick = catalog.first(where: { r in
            keywords.contains { FuzzyMatch.matches($0, r.title) }
        }) ?? catalog.randomElement()
        guard let r = pick else { return nil }
        return FetchedMoodRecipe(
            title: r.title,
            imageURL: r.imageURL ?? "",
            ingredients: r.ingredients.map { $0.amount.isEmpty ? $0.name : "\($0.amount) \($0.name)" },
            steps: r.instructions,
            cookTime: r.cookTime.isEmpty ? "30 min" : r.cookTime,
            prepTime: r.prepTime.isEmpty ? "15 min" : r.prepTime
        )
    }
}

// MARK: - Fetched recipe data
struct FetchedMoodRecipe {
    let title:       String
    let imageURL:    String
    let ingredients: [String]
    let steps:       [String]
    let cookTime:    String
    let prepTime:    String
}

// MARK: - Simple flow layout for ingredient tags
struct FlowLayout: View {
    let items: [String]
    let content: (String) -> AnyView

    init(items: [String], @ViewBuilder content: @escaping (String) -> some View) {
        self.items   = items
        self.content = { AnyView(content($0)) }
    }

    var body: some View {
        StockedFlowLayout(spacing: 8, lineSpacing: 6) {
            ForEach(items, id: \.self) { item in content(item) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview { MoodsCategoryView(servings: 4) }

// MARK: - Unstocked item helpers
struct UnstockedItem: Identifiable {
    let id = UUID()
    let name: String
}

struct UnstockedOptionSheet: View {
    @Environment(AppSession.self) var session
    let itemName: String
    let onContinue: () -> Void
    let onAddToList: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Handle
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.stockedCharcoal.opacity(0.2))
                .frame(width: 36, height: 4)
                .padding(.top, 12)
                .padding(.bottom, 20)

            VStack(spacing: 6) {
                Text("🛒  \(itemName) isn't in your pantry")
                    .scaledFont(17, weight: .bold, design: .serif)
                    .foregroundStyle(session.themeTextColor)
                    .multilineTextAlignment(.center)
                Text("You can still find a recipe and shop for it,\nor add it to your grocery list now.")
                    .scaledFont(13)
                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)

            VStack(spacing: 10) {
                Button(action: onContinue) {
                    Text("Find a Recipe Anyway →")
                        .scaledFont(15, weight: .semibold, design: .serif)
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(Color.stockedCharcoal)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)

                Button(action: onAddToList) {
                    HStack(spacing: 8) {
                        Image(systemName: "cart.badge.plus")
                        Text("Add \(itemName) to Grocery List")
                    }
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(Color.stockedGold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(Color.stockedGold.opacity(0.1))
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.stockedGold.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .background(session.themeBgColor)
    }
}
