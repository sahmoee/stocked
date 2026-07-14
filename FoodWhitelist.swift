// FoodWhitelist.swift
// Receipt-scanner food filter. Stocked. is a food inventory app, so the scanner must only
// keep items that are food or beverages intended for human consumption. Receipts routinely
// include cleaning supplies, paper goods, pet food, medicine, household items, personal care,
// kitchen tools, storage containers, and stray number/price strings — all of which should be
// dropped before the user ever sees them in the review list.
//
// Approach: an EXCLUSION list (blocklist) rather than a food allowlist. A finite allowlist
// would wrongly reject the long tail of legitimate but unusual groceries; a blocklist of the
// well-known non-food categories is both safer and easier to maintain. The match is on whole
// words (so "soap" doesn't trip on "soapberry", and "tea" isn't hit by "steak").
//
// This runs client-side regardless of what the AI Worker returns, so it also protects the
// offline OCR fallback path.
import Foundation

enum FoodWhitelist {

    /// Categories the app must exclude, each with the keywords that identify them. Whole-word
    /// matching against the normalized item name.
    private static let exclusions: [String: [String]] = [
        "Cleaning supplies": [
            "detergent", "bleach", "clorox", "lysol", "windex", "disinfectant", "cleaner",
            "cleaning", "softener", "fabric softener", "dish soap", "dishwasher", "rinse aid",
            "degreaser", "scrub", "sponge", "scrubber", "mop", "broom", "duster", "swiffer",
            "air freshener", "febreze", "stain remover", "laundry", "bissell", "pledge",
            "comet", "ajax", "drano", "borax", "fabuloso", "pinesol", "pine-sol", "wipes",
            "disinfecting", "sanitizer spray", "glass cleaner", "toilet cleaner",
        ],
        "Paper products": [
            "paper towel", "paper towels", "toilet paper", "tissue", "tissues", "kleenex",
            "napkin", "napkins", "bounty", "charmin", "cottonelle", "scott", "viva",
            "paper plate", "paper plates", "paper cup", "paper cups", "facial tissue",
            "toilet tissue", "bath tissue",
        ],
        "Pet supplies": [
            "dog food", "cat food", "puppy", "kitten", "pet", "kibble", "purina", "friskies",
            "fancy feast", "meow mix", "pedigree", "iams", "whiskas", "litter", "cat litter",
            "dog treat", "cat treat", "chew toy", "milkbone", "milk-bone", "dog chew",
            "rawhide", "birdseed", "bird seed", "aquarium", "flea", "tick collar",
        ],
        "Medicine": [
            "medicine", "tablet", "tablets", "capsule", "capsules", "ibuprofen", "tylenol",
            "advil", "aspirin", "acetaminophen", "antacid", "tums", "pepto", "nyquil",
            "dayquil", "cough syrup", "cough drops", "antihistamine", "benadryl", "claritin",
            "zyrtec", "allergy relief", "bandage", "band-aid", "bandaid", "first aid",
            "antibiotic", "ointment", "prescription", "pharmacy", "rx", "melatonin", "laxative",
            "antiseptic", "rubbing alcohol", "hydrogen peroxide", "thermometer",
        ],
        "Household goods": [
            "battery", "batteries", "duracell", "energizer", "light bulb", "lightbulb", "bulb",
            "candle", "matches", "lighter", "foil wrap", "trash bag", "trash bags", "garbage bag",
            "garbage bags", "extension cord", "tape", "glue", "tool", "hardware", "nails",
            "screws", "hanger", "hangers", "charcoal", "lighter fluid", "propane", "motor oil",
            "antifreeze", "wiper", "fertilizer", "potting soil", "mulch", "pesticide",
            "insecticide", "raid", "mouse trap", "mousetrap",
        ],
        "Personal care": [
            "shampoo", "conditioner", "body wash", "bar soap", "hand soap", "soap", "lotion",
            "moisturizer", "deodorant", "antiperspirant", "toothpaste", "toothbrush",
            "mouthwash", "floss", "razor", "razors", "shaving", "shave gel", "shave cream",
            "cosmetic", "makeup", "mascara", "lipstick", "foundation", "sunscreen", "sunblock",
            "perfume", "cologne", "nail polish", "cotton swab", "cotton swabs", "q-tip",
            "q-tips", "feminine", "tampon", "tampons", "pad", "pads", "diaper", "diapers",
            "wipe", "baby wipes", "hairspray", "hair gel", "hair dye", "contact solution",
            "chapstick", "lip balm", "hand sanitizer", "facial wash", "shower gel",
        ],
        "Kitchen tools": [
            "spatula", "whisk", "ladle", "tongs", "peeler", "grater", "colander", "strainer",
            "cutting board", "knife set", "skillet", "saucepan", "frying pan", "baking sheet",
            "cookware", "utensil", "utensils", "measuring cup", "measuring spoon", "oven mitt",
            "pot holder", "dish rack", "can opener", "corkscrew", "mixing bowl", "thermos",
            "tumbler", "mug", "plate set", "cutlery", "silverware", "fork", "spoon", "dishware",
        ],
        "Storage containers": [
            "ziploc", "zip lock", "ziplock", "storage bag", "storage bags", "freezer bag",
            "freezer bags", "sandwich bag", "sandwich bags", "snack bag", "tupperware",
            "food storage", "storage container", "plastic wrap", "saran", "cling wrap",
            "aluminum foil", "parchment paper", "wax paper", "container set", "mason jar",
            "lid", "lids",
        ],
    ]

    /// Foods whose names contain a substring that could look like a blocklisted token. These
    /// are explicitly allowed so a legitimate grocery item is never dropped by accident.
    private static let allowOverrides: Set<String> = [
        "soap" /* never alone, but e.g. */, "soapberry", "soap nuts",
        "tea", "iced tea", "green tea", "tea bags", "herbal tea", "matcha",
        "butter", "peanut butter", "almond butter", "cashew butter", "apple butter",
        "padthai", "pad thai", "spam", "panko", "lard", "lardons",
        "chai", "chia", "chai latte",
        "egg", "eggs", "eggplant", "nutmeg",
        "salt", "kosher salt", "sea salt",
        "candy", "candied", "candy bar", "rock candy", "cotton candy",
        "soda", "club soda", "baking soda", "cream soda",
        "popsicle", "creamsicle",
    ]

    /// Returns true when the item name should be KEPT (i.e. it is food / a consumable).
    /// `aiSaysFood` and `aiCategory` are honored if the Worker supplied them, but the local
    /// blocklist always has the final say on excluding a known non-food category.
    static func isAllowed(_ rawName: String, aiSaysFood: Bool? = nil, aiCategory: String? = nil) -> Bool {
        let name = rawName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }

        // 1. Drop pure number / price / code strings (e.g. "12.99", "001234567", "x2").
        let stripped = name.replacingOccurrences(of: " ", with: "")
        let numericish = CharacterSet(charactersIn: "0123456789.,$%#x*-/")
        if stripped.unicodeScalars.allSatisfy({ numericish.contains($0) }) { return false }
        // Names with no letters at all are not food.
        if !name.contains(where: { $0.isLetter }) { return false }

        // 1a. Reject anything that isn't basic Latin text. Receipt garbage and OCR noise often
        //     come through as CJK / symbols (e.g. "******冰*冰水水*8061"), and Swift counts CJK as
        //     letters, so the letter check above doesn't catch them. Stocked. is English-only for
        //     now, so require the name to be predominantly ASCII letters.
        let letters = name.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let asciiLetters = letters.filter { $0.isASCII }
        if letters.isEmpty || Double(asciiLetters.count) / Double(letters.count) < 0.8 { return false }

        // 1b. Reject digit-dominant strings even if a stray letter slipped in (barcodes like
        //     "41420115875", "S 41420115875"). If digits outnumber letters, it's a code, not food.
        let digitCount  = name.filter { $0.isNumber }.count
        let letterCount = asciiLetters.count
        if digitCount >= 5 && digitCount >= letterCount { return false }

        // 1c. Reject tiny fragments that are almost always receipt words, not products
        //     ("Trans", "Today Is", "Tax"). A real product name the scanner keeps is normally
        //     longer; require at least 4 letters OR a known short food word.
        let shortFoodWords: Set<String> = ["egg","ham","jam","oil","tea","pie","dip","rib","bun","soy","yam","fig","cod","oat","nut","rye"]
        if letterCount < 4 && !shortFoodWords.contains(name) { return false }

        // 1d. Receipt structural noise (NOT a product): store name/address/phone, payment and
        //     transaction metadata, dates/times, slogans, cashier lines, headers/footers. These
        //     contain letters and aren't a non-food *product category*, so they'd otherwise slip
        //     through — this is what was still leaking (e.g. "Auth Code:", "Bay City TX 77414").
        if isReceiptMetadata(name) { return false }

        // 2. If the model explicitly flagged a non-food category, trust it.
        if let cat = aiCategory?.lowercased() {
            let nonFoodCats = ["cleaning", "paper", "pet", "medicine", "household",
                               "personal care", "personal-care", "kitchen tool", "kitchenware",
                               "storage", "non-food", "nonfood", "other"]
            if nonFoodCats.contains(where: { cat.contains($0) }) { return false }
        }

        // 3. Explicit allow-list override wins over a coincidental keyword match.
        if allowOverrides.contains(name) { return true }
        if allowOverrides.contains(where: { name == $0 }) { return true }

        // 4. Whole-word blocklist match → exclude.
        let words = tokenize(name)
        for (_, keywords) in exclusions {
            for kw in keywords {
                if kw.contains(" ") {
                    if name.contains(kw) { return false }       // multi-word phrase
                } else if words.contains(kw) {
                    return false                                // whole-word single token
                }
            }
        }

        // 5. Default: keep. (If the AI explicitly said isFood == false AND nothing above
        //    rescued it, also drop — but only as a soft signal, since the Worker's flag may
        //    be unreliable; the blocklist above is the authoritative exclusion.)
        if aiSaysFood == false { return false }
        return true
    }

    /// The category bucket for an excluded item (used only for diagnostics/telemetry if needed).
    static func excludedCategory(_ rawName: String) -> String? {
        let name = rawName.lowercased()
        let words = tokenize(name)
        for (category, keywords) in exclusions {
            for kw in keywords {
                if kw.contains(" ") {
                    if name.contains(kw) { return category }
                } else if words.contains(kw) {
                    return category
                }
            }
        }
        return nil
    }

    // MARK: - Receipt structural-noise detection
    // Lines on a receipt that are NOT purchasable products: store identity, contact info,
    // payment/transaction metadata, dates/times, headers, footers, and marketing slogans.

    // Multi-character phrases matched anywhere in the line (safe — unlikely inside a food name).
    private static let metadataPhrases: [String] = [
        "store #", "store#", "sale transaction", "register", "reg #",
        "your cashier", "cashier", "operator", "associate",
        "auth code", "approval", "ref #", "ref:", "card #", "acct", "account #",
        "chip read", "contactless", "american express", "mastercard",
        "change due", "cash tendered", "balance to pay", "balance due",
        "subtotal", "sub total", "total purchase", "grand total", "total savings",
        "total on sale", "sales tax", "you saved", "you have saved",
        "multisave", "loyalty", "rewards",
        "tel:", "www.", "http", ".com", "visit us", "feedback", "survey",
        "thank you", "thanks for", "save time", "save money",
        "customer copy", "merchant copy", "store copy",
        "items sold", "qty sold", "number of items",
        "every day! at", "have a great", "come again", "see you",
    ]
    // Short / ambiguous tokens matched only as WHOLE WORDS (so "snap" never hits "Snapple",
    // "tid" never hits inside another word, etc.).
    private static let metadataWords: Set<String> = [
        "transaction", "trans", "receipt", "lane", "till",
        "tid", "mid", "aid", "arc", "emv", "auth", "ref",
        "visa", "amex", "discover", "debit", "credit", "ebt", "snap", "tender",
        "tax", "savings", "coupon", "member", "phone", "date", "time", "swipe",
        "discount", "balance", "total", "subtotal",
        "today", "cashier", "store", "purchase", "change", "cash",
    ]

    private static func isReceiptMetadata(_ name: String) -> Bool {
        let n = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return true }

        // Phrase keywords anywhere in the line.
        if metadataPhrases.contains(where: { n.contains($0) }) { return true }

        // Label lines that end in a colon ("Auth Code:", "Tid:").
        if n.hasSuffix(":") { return true }

        let toks = n.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let wordSet = Set(toks)

        // Whole-word metadata token match — but only when the line is SHORT (1–2 words). A real
        // food line is rarely a lone "Tax"/"Total"/"Date"; this avoids nuking a product that
        // merely contains such a word. (e.g. "Total" alone = metadata; "Total Wine Cabernet" stays)
        if toks.count <= 2, !wordSet.isDisjoint(with: metadataWords) { return true }

        // US street address ("3104 Ave F") — leading number then a street word.
        let streetWords: Set<String> = ["ave","avenue","st","street","rd","road","blvd","boulevard",
                                        "dr","drive","ln","lane","hwy","highway","pkwy","parkway",
                                        "ct","court","pl","place","way","ste","suite","unit","fwy"]
        if let first = toks.first, Int(first) != nil,
           toks.dropFirst().contains(where: { streetWords.contains($0) }) { return true }

        // City/State/ZIP line ("Bay City, TX 77414") — ends with a 5-digit ZIP.
        if let last = toks.last, last.count == 5, Int(last) != nil { return true }

        // Phone number ("(979) 401-3535" / "979-401-3535").
        let digits = n.filter { $0.isNumber }
        if digits.count >= 7, n.allSatisfy({ $0.isNumber || "()-+. ".contains($0) }) { return true }

        // Date / time lines ("06-06-26", "5:36 pm", "06/06/2026").
        if n.range(of: #"\b\d{1,2}[:/\-]\d{2}([:/\-]\d{2,4})?\b"#, options: .regularExpression) != nil { return true }
        if n.range(of: #"\b\d{1,2}:\d{2}\s*(a|p)m\b"#, options: .regularExpression) != nil { return true }

        return false
    }

    private static func tokenize(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty })
    }
}
