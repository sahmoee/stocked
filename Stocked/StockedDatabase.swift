// StockedDatabase.swift
// Unified database hub for Stocked. — substitutions, abbreviations, cooking tips.
// Three old database files (SubstitutionDatabase.swift, ReceiptAbbreviationDatabase.swift,
// CookingTipsDatabase.swift) are now shim-only wrappers that forward here.
// Add those three files back to your project replacing the old ones if they are missing.
import Foundation
import SwiftUI

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - Shared Models
// ─────────────────────────────────────────────────────────────────────────────

struct IngredientSubstitution: Identifiable {
    let id = UUID()
    let substitute: String
    let notes: String
}

struct SubstitutionEntry: Identifiable {
    let id = UUID()
    let ingredient: String       // canonical lowercase key
    let displayName: String
    var substitutions: [IngredientSubstitution]
}

struct AbbreviationEntry: Identifiable, Codable, Equatable {
    var id           = UUID()
    var abbreviation: String
    var resolved:    String
    var addedDate:   Date             = Date()
    var timesUsed:   Int              = 0
    var source:      AbbrevSource     = .builtIn

    enum AbbrevSource: String, Codable {
        case builtIn
        case userAdded
        case corrected
    }
}

struct CookingTip: Identifiable {
    let id       = UUID()
    let emoji:   String
    let title:   String
    let body:    String
    let category: TipCategory

    enum TipCategory: String, CaseIterable {
        case general  = "General Cooking"
        case baking   = "Baking"
        case reading  = "Reading Recipes"
        case subGuide = "Substitution Tips"
        case measure  = "Measurements"
        case safety   = "Food Safety"
        case knife    = "Knife & Prep"
        case storage  = "Storage"
    }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARK: - StockedDatabase
// Not @Observable — plain singleton; views that need reactivity observe
// AppSession. Abbreviation edits trigger UI refresh via sheet dismissal.
// ─────────────────────────────────────────────────────────────────────────────

@Observable
final class StockedDatabase {

    static let shared = StockedDatabase()

    // ── Stored properties (no lazy on @Observable — plain init instead) ──────
    let substitutionEntries: [SubstitutionEntry]
    var abbreviationEntries: [AbbreviationEntry]
    let cookingTips: [CookingTip]

    private let abbrevKey = "stocked_receipt_abbreviations_v1"

    private init() {
        substitutionEntries = StockedDatabase.buildSubstitutions()
        cookingTips         = StockedDatabase.buildTips()
        abbreviationEntries = []
        loadAbbreviations()
        seedBuiltInAbbreviations()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Substitution API
    // ─────────────────────────────────────────────────────────────────────────

    func substitutions(for ingredientName: String) -> SubstitutionEntry? {
        let lower = ingredientName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = substitutionEntries.first(where: { $0.ingredient == lower }) { return exact }
        return substitutionEntries.first(where: {
            lower.contains($0.ingredient) || $0.ingredient.contains(lower)
        })
    }

    func hasSubstitution(for ingredientName: String) -> Bool {
        substitutions(for: ingredientName) != nil
    }

    var sortedSubstitutionEntries: [SubstitutionEntry] {
        substitutionEntries.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Abbreviation API
    // ─────────────────────────────────────────────────────────────────────────

    func lookupAbbreviation(_ raw: String) -> String? {
        let key = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return abbreviationEntries.first(where: { $0.abbreviation == key })?.resolved
    }

    func resolveAbbreviation(_ raw: String) -> String {
        let key = raw.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = abbreviationEntries.firstIndex(where: { $0.abbreviation == key }) {
            abbreviationEntries[idx].timesUsed += 1
            saveAbbreviations()
            return abbreviationEntries[idx].resolved
        }
        return raw
    }

    func addAbbreviation(_ abbreviation: String, resolved: String,
                         source: AbbreviationEntry.AbbrevSource = .userAdded) {
        let key = abbreviation.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !resolved.isEmpty else { return }
        if let idx = abbreviationEntries.firstIndex(where: { $0.abbreviation == key }) {
            abbreviationEntries[idx].resolved = resolved
            abbreviationEntries[idx].source   = source
        } else {
            abbreviationEntries.append(AbbreviationEntry(abbreviation: key, resolved: resolved, source: source))
        }
        saveAbbreviations()
    }

    func updateAbbreviation(id: UUID, abbreviation: String, resolved: String) {
        guard let idx = abbreviationEntries.firstIndex(where: { $0.id == id }) else { return }
        abbreviationEntries[idx].abbreviation = abbreviation.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        abbreviationEntries[idx].resolved     = resolved
        if abbreviationEntries[idx].source == .builtIn { abbreviationEntries[idx].source = .userAdded }
        saveAbbreviations()
    }

    func deleteAbbreviations(ids: Set<UUID>) {
        abbreviationEntries.removeAll { ids.contains($0.id) }
        saveAbbreviations()
    }

    func deleteAbbreviations(at offsets: IndexSet) {
        abbreviationEntries.remove(atOffsets: offsets)
        saveAbbreviations()
    }

    func recordAbbreviationCorrection(raw: String, corrected: String) {
        addAbbreviation(raw, resolved: corrected, source: .corrected)
    }

    var sortedAbbreviationEntries: [AbbreviationEntry] {
        abbreviationEntries.sorted {
            $0.abbreviation.localizedCaseInsensitiveCompare($1.abbreviation) == .orderedAscending
        }
    }

    var userAbbreviationEntries: [AbbreviationEntry] {
        sortedAbbreviationEntries.filter { $0.source != .builtIn }
    }

    var builtInAbbreviationEntries: [AbbreviationEntry] {
        sortedAbbreviationEntries.filter { $0.source == .builtIn }
    }

    private func saveAbbreviations() {
        if let data = try? JSONEncoder().encode(abbreviationEntries) {
            UserDefaults.standard.set(data, forKey: abbrevKey)
        }
    }

    private func loadAbbreviations() {
        guard let data = UserDefaults.standard.data(forKey: abbrevKey),
              let decoded = try? JSONDecoder().decode([AbbreviationEntry].self, from: data)
        else { return }
        abbreviationEntries = decoded
    }

    private func seedBuiltInAbbreviations() {
        let seeds: [(String, String)] = [
            ("CHKN","Chicken"),("CHKN BRS","Chicken Breast"),("CHKN THG","Chicken Thighs"),
            ("GRND BF","Ground Beef"),("GRD BEEF","Ground Beef"),("BF STEAK","Beef Steak"),
            ("SLMN","Salmon"),("SHRMP","Shrimp"),("TKY","Turkey"),
            ("PK CHOP","Pork Chop"),("BK CHOP","Pork Chop"),("EGG","Eggs"),
            ("WHL MLK","Whole Milk"),("2% MLK","2% Milk"),("SKM MLK","Skim Milk"),
            ("OAT MLK","Oat Milk"),("ALMD MLK","Almond Milk"),
            ("BTR","Butter"),("UNSL BTR","Unsalted Butter"),("SL BTR","Salted Butter"),
            ("SHD CHZ","Shredded Cheese"),("AMR CHZ","American Cheese"),("CHDR CHZ","Cheddar Cheese"),
            ("MZZRL","Mozzarella"),("PRMGNO","Parmesan"),("PARM","Parmesan"),
            ("HVY CRM","Heavy Cream"),("HLHF CRM","Half-and-Half"),("SOR CRM","Sour Cream"),
            ("YGT","Yogurt"),("GRK YGT","Greek Yogurt"),("CRD CHZ","Cream Cheese"),
            ("TOM","Tomatoes"),("PLUM TOM","Plum Tomatoes"),("CHRY TOM","Cherry Tomatoes"),
            ("ORG","Oranges"),("LMN","Lemon"),("LM","Lime"),
            ("SPIN","Spinach"),("ROM LET","Romaine Lettuce"),("ICBG LET","Iceberg Lettuce"),
            ("RED ONI","Red Onion"),("YLW ONI","Yellow Onion"),("GRN ONI","Green Onion"),
            ("YUKON PT","Yukon Gold Potatoes"),("RUS PT","Russet Potatoes"),("SWT PT","Sweet Potato"),
            ("BROC","Broccoli"),("CAULIFLWR","Cauliflower"),("ZNCHI","Zucchini"),
            ("BL PAPP","Bell Pepper"),("RED PAPP","Red Bell Pepper"),("GRN PAPP","Green Bell Pepper"),
            ("MUSH","Mushrooms"),("BTN MUSH","Button Mushrooms"),("CRROT","Carrots"),
            ("AVDO","Avocado"),("BBSPRTS","Brussels Sprouts"),("KAL","Kale"),
            ("GAR","Garlic"),("GNGER","Ginger"),("SHLLT","Shallots"),
            ("AP FLOR","All-Purpose Flour"),("APF","All-Purpose Flour"),("WHT FLOR","Whole Wheat Flour"),
            ("STD SGR","Granulated Sugar"),("PWDR SGR","Powdered Sugar"),("BRWN SGR","Brown Sugar"),
            ("OLVE OL","Olive Oil"),("EX VRG OO","Extra Virgin Olive Oil"),("VEG OL","Vegetable Oil"),
            ("SNF OL","Sunflower Oil"),("COCO OL","Coconut Oil"),
            ("AP CVR","Apple Cider Vinegar"),("WH VNG","White Vinegar"),("BLS VNG","Balsamic Vinegar"),
            ("SY SC","Soy Sauce"),("WRCH SC","Worcestershire Sauce"),("HTSC","Hot Sauce"),
            ("KETCH","Ketchup"),("MUST","Mustard"),("MAYO","Mayonnaise"),("BBQ SC","BBQ Sauce"),
            ("LG GRAIN RC","Long Grain Rice"),("JSMN RC","Jasmine Rice"),("BRN RC","Brown Rice"),
            ("SPG","Spaghetti"),("PNE","Penne"),("FETT","Fettuccine"),("LING","Linguine"),
            ("ORZO","Orzo"),("MAC","Macaroni"),
            ("RED BEAN","Red Beans"),("BLK BEAN","Black Beans"),("GNZBA","Garbanzo Beans"),
            ("CHKPEA","Chickpeas"),("LNTL","Lentils"),
            ("BKG PWD","Baking Powder"),("BKG SOD","Baking Soda"),("VNL EXT","Vanilla Extract"),
            ("WW BRD","Whole Wheat Bread"),("WHT BRD","White Bread"),("SDG BRD","Sourdough Bread"),
            ("BGL","Bagels"),("ENG MUF","English Muffins"),("FLOUR TRT","Flour Tortillas"),
            ("CORN TRT","Corn Tortillas"),("PITA","Pita Bread"),
            ("FRZ PEA","Frozen Peas"),("FRZ CORN","Frozen Corn"),("FRZ EDME","Frozen Edamame"),
            ("FRZ SPNCH","Frozen Spinach"),("FRZ BROC","Frozen Broccoli"),
            ("CND TOM","Canned Tomatoes"),("TOM PST","Tomato Paste"),("TOM SC","Tomato Sauce"),
            ("CND CORN","Canned Corn"),("CND BEAN","Canned Beans"),("CND TUNA","Canned Tuna"),
            ("CND SLMN","Canned Salmon"),("CND CKPEA","Canned Chickpeas"),("CKT SB","Coconut Milk"),
            ("CHOC CHIP","Chocolate Chips"),("DRK CHOC","Dark Chocolate"),("MLK CHOC","Milk Chocolate"),
            ("PNT BTR","Peanut Butter"),("ALMD BTR","Almond Butter"),("MAP SYP","Maple Syrup"),("HNY","Honey"),
            ("OJ","Orange Juice"),("AJ","Apple Juice"),("GRN TEA","Green Tea"),("SLTZ WTR","Sparkling Water"),
        ]
        for (abbr, resolved) in seeds {
            let key = abbr.uppercased()
            if !abbreviationEntries.contains(where: { $0.abbreviation == key }) {
                abbreviationEntries.append(
                    AbbreviationEntry(abbreviation: key, resolved: resolved, source: .builtIn))
            }
        }
        saveAbbreviations()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Tips API
    // ─────────────────────────────────────────────────────────────────────────

    func tips(for category: CookingTip.TipCategory) -> [CookingTip] {
        cookingTips.filter { $0.category == category }
    }

    var allTipCategories: [CookingTip.TipCategory] { CookingTip.TipCategory.allCases }

    func randomTips(_ count: Int = 3) -> [CookingTip] {
        Array(cookingTips.shuffled().prefix(count))
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MARK: Static data builders
    // ─────────────────────────────────────────────────────────────────────────

    private static func buildSubstitutions() -> [SubstitutionEntry] {
        func S(_ i: String, _ d: String, _ subs: [(String, String)]) -> SubstitutionEntry {
            SubstitutionEntry(ingredient: i, displayName: d,
                              substitutions: subs.map { IngredientSubstitution(substitute: $0.0, notes: $0.1) })
        }
        return [
            // Baking
            S("all-purpose flour","All-Purpose Flour",[
                ("½ bread flour + ½ cake flour","Combine equal parts for best texture (per 1 cup)"),
                ("Self-rising flour","Omit baking powder and salt from recipe")]),
            S("cake flour","Cake Flour",[
                ("All-purpose flour + cornstarch","1 cup all-purpose minus 2 tbsp, replace with 2 tbsp cornstarch")]),
            S("self-rising flour","Self-Rising Flour",[
                ("All-purpose flour + baking powder + salt","1 cup flour + 1½ tsp baking powder + ¼ tsp fine salt")]),
            S("baking powder","Baking Powder",[
                ("Cream of tartar + baking soda","½ tsp cream of tartar + ¼ tsp baking soda per 1 tsp baking powder")]),
            S("baking soda","Baking Soda",[
                ("Baking powder","Use 3 tsp baking powder per 1 tsp baking soda; results may differ slightly")]),
            S("cream of tartar","Cream of Tartar",[
                ("Lemon juice","Equal amount; works well in meringues and baked goods")]),
            S("dutch-process cocoa powder","Dutch-Process Cocoa Powder",[
                ("Natural cocoa powder + baking soda","3 tbsp natural cocoa + ⅛ tsp baking soda per 3 tbsp Dutch-process")]),
            S("xanthan gum","Xanthan Gum",[
                ("Chia seeds or ground flax in water","½ tsp seeds + 2½ tsp hot water per 1 tbsp; let sit until thick")]),
            // Eggs & Dairy
            S("egg","Egg",[
                ("Aquafaba","3 tbsp per egg; chickpea liquid works best for baking and batters"),
                ("Vegetable oil + water","3 tbsp oil + 1 tbsp water per egg; good for muffins and quick breads"),
                ("Applesauce","¼ cup per egg; adds moisture and slight sweetness"),
                ("Silken tofu (pureed)","¼ cup per egg; dense results, good for brownies"),
                ("Canned pumpkin","¼ cup per egg; best for spiced baked goods")]),
            S("egg whites","Egg Whites",[
                ("Aquafaba","2 tbsp per egg white; works for meringue, batters, and most baking")]),
            S("butter","Butter",[
                ("Greek yogurt or applesauce","For baking — equal swap; reduces fat, adds moisture"),
                ("Canola or vegetable oil","For non-baking uses; equal amount"),
                ("Olive oil, coconut oil, or ghee","For cooking and sautéing; equal amount")]),
            S("buttermilk","Buttermilk",[
                ("Milk + lemon juice or vinegar","1 cup milk + 1 tbsp lemon juice or white vinegar; let sit 5 min"),
                ("Plain yogurt or sour cream thinned with water","For non-baking uses; thin to pourable consistency")]),
            S("milk","Milk",[
                ("Yogurt or sour cream thinned with water","Thin to a pourable consistency; works in most recipes"),
                ("Oat milk, almond milk, or soy milk","Equal swap for most uses")]),
            S("heavy cream","Heavy Cream",[
                ("Coconut milk or unsweetened coconut cream","Best for non-whipped uses; equal swap"),
                ("Half-and-half","For non-whipping uses; slightly less rich")]),
            S("heavy whipping cream","Heavy Whipping Cream",[
                ("Half-and-half","For non-whipping uses only"),
                ("Milk + melted butter","¾ cup milk + 4 tbsp melted butter per 1 cup")]),
            S("half-and-half","Half-and-Half",[
                ("Whole milk + melted butter","Scant 1 cup milk + 1 tbsp melted butter"),
                ("¾ cup whole milk + ¼ cup heavy cream","Best flavour match")]),
            S("evaporated milk","Evaporated Milk",[
                ("Milk, half-and-half, or heavy cream","Equal swap for non-baking uses"),
                ("Powdered milk mixed to double strength","Follow package directions; works well in baking")]),
            S("sour cream","Sour Cream",[
                ("Plain yogurt or Greek yogurt","Equal swap; slightly tangier"),
                ("Crème fraîche","Richer flavour; equal swap")]),
            S("creme fraiche","Crème Fraîche",[
                ("Sour cream","Equal swap; slightly more acidic"),
                ("Greek yogurt","Equal swap; less fat")]),
            S("cream cheese","Cream Cheese",[
                ("Neufchâtel","Equal swap; lower fat, nearly identical flavour"),
                ("Cottage cheese or ricotta (pureed, strained)","Add a pinch of salt and squeeze of lemon; may curdle in heat")]),
            S("yogurt","Yogurt (Greek & Plain)",[
                ("Sour cream","Equal swap; richer"),
                ("Crème fraîche","Equal swap; more luxurious texture")]),
            // Cheese
            S("cheddar","Cheddar",[
                ("Colby Jack or Monterey Jack","Milder flavour; melts well"),
                ("Fontina or mozzarella","Good melt; use aged varieties for stronger taste")]),
            S("gruyere","Gruyère",[
                ("Emmental or Jarlsberg","Similar nutty, Swiss-style flavour"),
                ("Aged cheddar or Fontina","Works well in fondues and gratins")]),
            S("parmesan","Parmesan",[("Pecorino Romano","Slightly saltier and sharper; use a touch less")]),
            S("goat cheese","Goat Cheese (Chèvre)",[
                ("Cream cheese or mascarpone","Loosen with a little yogurt for similar spreadable texture")]),
            // Sweeteners
            S("granulated sugar","Granulated Sugar",[
                ("Light or dark brown sugar","Packed; adds molasses flavour and moisture"),
                ("Turbinado or demerara sugar","Grind in food processor first; baked goods may be crunchier")]),
            S("brown sugar","Brown Sugar",[
                ("Turbinado or muscovado sugar","Equal swap"),
                ("Granulated sugar + molasses","1 cup sugar + 2–3 tbsp molasses; may make baked goods crunchier")]),
            S("honey","Honey",[
                ("Maple syrup","Equal swap; different flavour profile"),
                ("Light or dark corn syrup","Equal swap; neutral sweetness")]),
            S("corn syrup","Corn Syrup",[
                ("Honey, agave, or maple syrup","Equal swap for baking (not candy-making)"),
                ("Brown rice syrup or golden syrup","Best for candy-making; similar consistency")]),
            S("molasses","Molasses",[
                ("Dark corn syrup or maple syrup","Equal swap; less robust flavour"),
                ("Brown sugar + hot water","¾ cup brown sugar + ¼ cup hot water per 1 cup molasses")]),
            S("vanilla extract","Vanilla Extract",[
                ("Maple syrup","Equal swap; adds gentle warmth"),
                ("Bourbon, brandy, or rum","Equal swap; works beautifully in baked goods")]),
            // Fats & Oils
            S("vegetable oil","Vegetable Oil",[
                ("Canola oil","Equal swap; neutral flavour"),
                ("Avocado or melted coconut oil","Equal swap; slight flavour difference"),
                ("Olive oil or ghee","Equal swap for most uses")]),
            S("coconut oil","Coconut Oil",[
                ("Unsalted butter","Equal swap; adds dairy flavour"),
                ("Avocado oil or nut oils","For non-baking; neutral to mild flavour")]),
            S("vegetable shortening","Vegetable Shortening",[
                ("Unsalted butter","Equal swap; adds rich flavour"),
                ("Coconut oil","Equal swap; works well in pie crusts")]),
            S("sesame oil","Sesame Oil",[
                ("Any nut oil","Equal swap; different but compatible flavour"),
                ("Toasted sesame seed oil (homemade)","Toast ¼ cup white sesame seeds in 1 cup neutral oil for 2 hrs; strain")]),
            // Vinegars & Acids
            S("apple cider vinegar","Apple Cider Vinegar",[
                ("Lemon juice","Equal swap; brightens the dish similarly"),
                ("White wine vinegar or rice vinegar","Equal swap; slightly milder")]),
            S("balsamic vinegar","Balsamic Vinegar",[
                ("White wine vinegar + sugar","1 tbsp white wine vinegar + ½ tsp sugar per 1 tbsp balsamic")]),
            S("red wine vinegar","Red Wine Vinegar",[
                ("Apple cider vinegar or white wine vinegar","Equal swap"),
                ("Distilled white vinegar","Sharper; use slightly less")]),
            S("rice vinegar","Rice Vinegar",[
                ("Apple cider or white wine vinegar + sugar","1 tbsp vinegar + 1 tsp sugar per 1 tbsp rice vinegar")]),
            S("white wine vinegar","White Wine Vinegar",[
                ("Apple cider vinegar or red wine vinegar","Equal swap"),
                ("Distilled white vinegar","Equal swap; slightly sharper")]),
            S("lemon juice","Lemon Juice",[
                ("Lime juice","Equal swap; slightly different citrus flavour"),
                ("Orange juice","Equal swap; sweeter; use in non-acidic-critical recipes")]),
            // Herbs & Spices
            S("basil","Basil",[("Tarragon, oregano, or thyme","Equal swap; 1 tbsp fresh = 1 tsp dried")]),
            S("cilantro","Cilantro",[
                ("Parsley","Milder; equal swap; 1 tbsp fresh = 1 tsp dried"),
                ("Parsley + basil (combined)","Closer flavour approximation")]),
            S("oregano","Oregano",[("Thyme or basil","Equal swap; 1 tbsp fresh = 1 tsp dried")]),
            S("parsley","Parsley",[
                ("Basil or chervil","Equal swap; 1 tbsp fresh = 1 tsp dried"),
                ("Celery leaf","More pungent; use slightly less")]),
            S("rosemary","Rosemary",[("Thyme","Equal swap; 1 tbsp fresh = 1 tsp dried")]),
            S("thyme","Thyme",[("Basil, marjoram, oregano, or rosemary","Equal swap; 1 tbsp fresh = 1 tsp dried")]),
            S("marjoram","Marjoram",[
                ("Oregano","Half the amount; oregano is more pungent"),
                ("Sage, thyme, or summer savory","Equal swap; 1 tbsp fresh = 1 tsp dried")]),
            S("tarragon","Tarragon",[
                ("Chervil","Equal swap; similar anise notes"),
                ("Basil","Use double the amount of basil")]),
            S("allspice","Allspice",[
                ("Cinnamon + cloves + nutmeg","¾ tsp cinnamon + pinch of cloves + pinch of nutmeg per 1 tsp")]),
            S("cardamom","Cardamom",[
                ("Ground cinnamon","Equal swap; warmer, less floral"),
                ("Ground clove","Use half the amount; much more pungent")]),
            S("cayenne pepper","Cayenne Pepper",[
                ("Crushed red pepper flakes","Use twice the amount of flakes")]),
            S("chili powder","Chili Powder",[
                ("Paprika + cumin + onion powder + garlic powder",
                 "1 tsp paprika + 1 tsp cumin + ½ tsp each onion and garlic powder + pinch of cayenne")]),
            S("cumin","Cumin",[
                ("Taco seasoning or chili powder","Contains cumin; adjust salt accordingly"),
                ("Ground coriander","Equal swap; earthier, less warm")]),
            S("coriander","Coriander",[("Ground or whole cumin","Equal swap; slightly warmer flavour")]),
            S("nutmeg","Nutmeg",[
                ("Mace or allspice","Equal swap"),
                ("Ground cinnamon or clove","Half the amount; more intense")]),
            S("paprika","Paprika",[("Chili powder","Equal swap; adds more heat")]),
            S("garam masala","Garam Masala",[
                ("Ground cumin + allspice","¾ tsp cumin + ¼ tsp allspice or pumpkin pie spice per 1 tsp")]),
            S("kosher salt","Kosher Salt",[("Table (iodized) salt","Use half the amount — table salt is denser")]),
            S("table salt","Table Salt",[("Kosher salt","Use 1½× the amount — kosher salt is less dense")]),
            // Sauces & Condiments
            S("soy sauce","Soy Sauce",[
                ("Worcestershire sauce","For small amounts; similar umami"),
                ("Tamari or coconut aminos","Gluten-free options; equal swap")]),
            S("worcestershire sauce","Worcestershire Sauce",[
                ("Soy sauce + lemon + sugar + hot sauce",
                 "2 tsp soy sauce + ¼ tsp lemon + ¼ tsp sugar + dash of hot sauce per 1 tbsp")]),
            S("fish sauce","Fish Sauce",[
                ("Soy sauce","Equal swap; less funky, more salty"),
                ("Worcestershire sauce","Equal swap; adds similar depth")]),
            S("hoisin sauce","Hoisin Sauce",[
                ("BBQ sauce","Equal swap; sweeter and smokier"),
                ("Soy sauce + honey or molasses","¼ cup soy sauce + 1–2 tbsp honey per ¼ cup hoisin")]),
            S("oyster sauce","Oyster Sauce",[
                ("Soy sauce or hoisin sauce","Equal swap; less briny richness")]),
            S("mirin","Mirin",[
                ("White wine or dry sherry + sugar","1 tbsp wine or sherry + ½ tsp sugar per 1 tbsp mirin"),
                ("Rice vinegar + sugar","Same ratio; adds slight acidity")]),
            S("marsala wine","Marsala Wine",[
                ("Madeira, port, or sherry","Equal swap"),
                ("White wine + brandy","White wine with a splash of brandy")]),
            S("white wine","White Wine (Dry)",[
                ("Broth or stock","Equal swap; no alcohol"),
                ("Water + lemon juice or vinegar","Water with a squeeze of lemon or splash of vinegar")]),
            S("dijon mustard","Dijon Mustard",[
                ("Spicy brown or stone-ground mustard","Equal swap; slightly coarser texture"),
                ("Dry mustard + mayo + white vinegar + sugar",
                 "1 tbsp dry mustard + 1 tbsp mayo + 1 tsp white vinegar + pinch of sugar per 2 tbsp Dijon")]),
            S("chicken broth","Chicken Broth",[
                ("Vegetable or beef broth","Equal swap"),
                ("Water + soy sauce or bouillon","Season water with a little soy sauce or bouillon granules")]),
            // Thickeners
            S("cornstarch","Cornstarch",[
                ("Arrowroot","1–1½ tbsp arrowroot per 1 tbsp cornstarch; good for sauces and puddings"),
                ("Potato starch or rice flour","2 tsp per 1 tbsp cornstarch; works in sauces and batters"),
                ("All-purpose flour","3 tbsp per 1 tbsp cornstarch; best for breading and frying")]),
            S("tomato paste","Tomato Paste",[
                ("Tomato sauce (reduced)","Simmer 3 tbsp tomato sauce until very thick; cool before using")]),
            S("tomato sauce","Tomato Sauce",[
                ("Tomato purée","Equal swap; slightly thicker"),
                ("Canned tomatoes (blended)","Blend canned tomatoes; equal swap"),
                ("Tomato paste + water","Equal parts tomato paste and water")]),
            S("peanut butter","Peanut Butter",[
                ("Sunflower butter","Equal swap; nut-free"),
                ("Almond butter or cashew butter","Equal swap; milder flavour")]),
            S("shallots","Shallots",[
                ("Red onion","Equal swap; stronger flavour"),
                ("Scallion whites","Milder; equal swap")]),
        ]
    }

    private static func buildTips() -> [CookingTip] {
        func T(_ e: String, _ t: String, _ b: String, _ c: CookingTip.TipCategory) -> CookingTip {
            CookingTip(emoji: e, title: t, body: b, category: c)
        }
        return [
            T("📖","Read the whole recipe first","Before you pick up a knife, read the entire recipe start to finish. This prevents surprises like needing overnight marinating time or a pre-heated pan.",.reading),
            T("🕐","Active vs. total time","Total time includes resting, chilling, marinating, and baking. Active time is how long you're actually doing work. Plan around total time, not active time.",.reading),
            T("📝","Mise en place","French for 'everything in its place.' Measure, chop, and prepare all ingredients before cooking. It prevents scrambling and burnt garlic while you're chopping onions.",.reading),
            T("🔢","Serving sizes are suggestions","Recipe yields are guides. A 'serves 4' pasta can stretch to 6 as a side or shrink to 2 with big appetites. Scale confidently.",.reading),
            T("⚖️","Weight beats volume in baking","When a recipe gives weight (grams/ounces), use a scale. A 'cup of flour' can vary by 20–30% depending on how it's scooped. Weight is always precise.",.reading),
            T("🌡️","Room temperature matters","When a recipe says 'room temperature butter' or 'eggs,' it means it. Cold butter won't cream properly; cold eggs can cause batters to break.",.reading),
            T("🔥","Oven temperatures vary","Home ovens can run 25–50°F off their displayed temperature. Get an oven thermometer — it's the cheapest upgrade that will genuinely improve your cooking.",.reading),
            T("🧂","Season to taste is not a cop-out","Seasoning in stages — during cooking and at the end — builds depth. Taste before serving. Most home cooking is underseasoned.",.reading),
            T("🫕","Dry meat before searing","Pat meat dry with paper towels before it hits the pan. Moisture creates steam, which prevents browning. A good sear = deep, complex flavour.",.general),
            T("🧄","Let garlic bloom in oil","Add garlic to a cold or just-warming pan, not a scorching one. Garlic burns in seconds once a pan is very hot, turning bitter. Low and slow unlocks its sweetness.",.general),
            T("🍳","Don't overcrowd the pan","Too much food in a pan drops the temperature, causing steaming instead of browning. Cook in batches if needed for proper caramelisation.",.general),
            T("🛑","Rest your meat","Resting allows juices to redistribute. A steak needs 5 min, a whole chicken 15 min, a large roast 20–30 min. Cut too soon and the juices run out on the board.",.general),
            T("🫙","Salt your pasta water generously","Pasta water should taste noticeably salty — about 1 tablespoon of kosher salt per pound of pasta. This is the only chance to season the pasta itself.",.general),
            T("🧊","Cold water for green vegetables","After blanching green vegetables, plunge them into ice water immediately. This stops cooking and locks in their bright green colour.",.general),
            T("🍋","Acid brightens everything","A squeeze of lemon or splash of vinegar at the end of cooking lifts a flat dish immediately. It's the most underused finishing tool in home cooking.",.general),
            T("🥄","Taste as you go","The best cooks adjust constantly. Tasting at every stage lets you catch under-seasoning, over-reduction, or missing brightness before it's too late.",.general),
            T("🫧","Deglaze for flavour","After browning meat or vegetables, add wine, broth, or water to the hot pan and scrape up the brown bits (fond). Those bits are concentrated flavour — don't waste them.",.general),
            T("🪴","Fresh herbs go in last","Woody herbs (rosemary, thyme) can handle heat and go in early. Tender herbs (basil, cilantro, parsley) lose flavour quickly — add them at the very end.",.general),
            T("🧈","Finish with cold butter","Swirling a knob of cold butter into a hot sauce off the heat creates a rich, glossy, restaurant-style finish. The key is cold butter and low heat.",.general),
            T("🎂","Baking is a science","Unlike cooking, baking reactions are precise. Changing ratios of fat, sugar, flour, or leavening can collapse or toughen what you're making. Follow the recipe closely the first time.",.baking),
            T("🧪","Don't open the oven","Opening the oven door causes temperature drops that can collapse cakes and soufflés. Wait until the minimum bake time before checking.",.baking),
            T("🥣","Cream butter and sugar properly","Creaming means beating until pale, fluffy, and significantly increased in volume — usually 3–5 minutes in a mixer. Under-creaming means flat, dense baked goods.",.baking),
            T("🎛️","Fold, don't stir","When a recipe says fold, it means gently turn the mixture with a spatula to preserve air bubbles. Stirring deflates batter, resulting in flat, tough results.",.baking),
            T("🍪","Chill cookie dough","Chilling dough for at least 30 minutes (or overnight) concentrates flavour, prevents excessive spreading, and creates chewier cookies.",.baking),
            T("🧁","The toothpick test","Insert a toothpick into the centre. Clean = done. Wet batter = needs more time. Moist crumbs are fine for brownies — dry crumbs mean it's over-baked.",.baking),
            T("📦","Spoon and level flour","Spoon flour into the measuring cup with a separate spoon, then level with a straight edge. Scooping directly packs in 20–30% extra flour, which dries out baked goods.",.baking),
            T("🌡️","Use an instant-read thermometer","Bread is done at 190–200°F internally. Chicken at 165°F. A thermometer removes guesswork and is the surest route to consistently cooked results.",.baking),
            T("🔄","Baking swaps affect texture","Swapping eggs, butter, or sugar in baking will change texture, colour, and sometimes cook time. Muffins and quick breads are forgiving; cakes and cookies are trickier.",.subGuide),
            T("🥛","Dairy swaps are often easy","Sour cream, Greek yogurt, and crème fraîche are nearly interchangeable. Thin yogurt with a little water to stand in for milk. Heavy cream and half-and-half swap well for non-whipping uses.",.subGuide),
            T("🌿","Herbs are the most flexible swap","Tender herbs (basil, parsley, tarragon) swap freely with each other. Woody herbs (rosemary, thyme, oregano) also swap well. Fresh-to-dried ratio: 1 tbsp fresh = 1 tsp dried.",.subGuide),
            T("🌶️","Warm spices substitute for each other","Cinnamon, cardamom, allspice, and pumpkin pie spice share similar warmth profiles and swap confidently. Cumin, paprika, and chili powder are similarly interchangeable.",.subGuide),
            T("🥚","Egg subs change texture and timing","Any egg substitution will alter the final texture and possibly baking time. Aquafaba (chickpea liquid) works best for most uses, including meringue-based applications.",.subGuide),
            T("🧂","Salt equivalence","Half tsp table salt equals ¾ tsp kosher salt. They are not interchangeable at equal volume because table salt is significantly denser.",.subGuide),
            T("📏","3 tsp = 1 tbsp","The most useful kitchen conversion: 3 teaspoons make 1 tablespoon. From there: 16 tablespoons = 1 cup; 4 cups = 1 quart; 4 quarts = 1 gallon.",.measure),
            T("⚖️","Common weight conversions","1 oz = 28g · 1 lb = 454g · 1 kg = 2.2 lb · 1 cup of water = 237ml = 8 fl oz. When precision matters, weigh rather than measure by volume.",.measure),
            T("🌡️","Temperature reference points","Simmer: 185–205°F. Boil: 212°F. Soft ball (candy): 235–240°F. Caramel: 320–360°F. Smoke point of olive oil: ~375°F. Avocado oil: ~520°F.",.measure),
            T("🥄","Pinch vs. dash vs. smidge","A pinch is about ⅛ tsp. A dash is about ⅛ tsp (liquid). A smidge is about 1/32 tsp. When precision matters, use a ⅛ tsp measure.",.measure),
            T("🌡️","The danger zone","Bacteria multiply rapidly between 40°F and 140°F. Keep cold food cold (below 40°F) and hot food hot (above 140°F). Don't leave cooked food at room temperature for more than 2 hours.",.safety),
            T("🥩","Safe internal temperatures","Whole poultry: 165°F. Ground meat: 160°F. Whole beef/pork/lamb: 145°F (rest 3 min). Fish: 145°F. Reheated leftovers: 165°F. Use a thermometer, not a colour.",.safety),
            T("🫙","The 2-inch rule for leftovers","Store leftovers in shallow containers (2 inches deep or less) so they cool quickly and evenly in the fridge. Deep containers trap heat in the middle.",.safety),
            T("🧼","Wash hands, not raw chicken","Washing raw poultry splashes bacteria across your sink and nearby surfaces. Skip it — cooking to temperature kills pathogens. Always wash hands before and after handling raw meat.",.safety),
            T("🔪","A sharp knife is a safe knife","Dull knives require more force and are far more likely to slip. Hone your knife before each use with a honing steel; sharpen on a whetstone a few times a year.",.knife),
            T("🪵","Use a stable cutting board","Place a damp kitchen towel under your cutting board to stop it sliding. A moving board is a safety hazard.",.knife),
            T("🧅","How to cut an onion without crying","Chill the onion for 30 minutes before cutting. Keep the root end intact as long as possible — the root holds the volatile compounds that irritate your eyes.",.knife),
            T("🫛","Rock, don't chop","Keep the tip of the knife on the board and rock the blade down and forward, moving the food with your guide hand. This is safer and faster than lifting the knife fully each time.",.knife),
            T("🫙","Label and date everything","Always label leftovers with what they are and the date they were made. Most cooked leftovers are safe for 3–4 days in the fridge and 3 months in the freezer.",.storage),
            T("🥦","Store herbs like flowers","Treat soft herbs (parsley, cilantro, basil) like flowers: trim stems and place in a glass of water. Cover loosely with a bag. They'll last 1–2 weeks in the fridge.",.storage),
            T("🍅","Never refrigerate tomatoes","Cold destroys the enzymes that give tomatoes their flavour. Store at room temperature, stem-side down to slow moisture loss.",.storage),
            T("🧄","Garlic and onions don't belong in the fridge","Store garlic and whole onions in a cool, dry, ventilated spot. The fridge introduces too much moisture and softens them quickly.",.storage),
            T("🥑","Avocado ripening hack","Speed up avocado ripening by placing it in a paper bag with a banana or apple — they emit ethylene gas. To slow ripening, keep avocados in the fridge once ripe.",.storage),
            T("❄️","Freeze smartly","Freeze in portions you'll actually use. Remove as much air as possible from bags. Lay bags flat to freeze, then stack vertically to save space.",.storage),
        ]
    }
}
