// CookingFlow.swift
import SwiftUI
import Combine
import PhotosUI
import AVFoundation

// #6 — Read-aloud helper. Speaks a cooking step; tapping again stops.
final class SpeechReader {
    static let shared = SpeechReader()
    private let synth = AVSpeechSynthesizer()
    func toggle(_ text: String) {
        if synth.isSpeaking {
            synth.stopSpeaking(at: .immediate)
            return
        }
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.48
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(u)
    }
    func stop() { if synth.isSpeaking { synth.stopSpeaking(at: .immediate) } }
    var isSpeaking: Bool { synth.isSpeaking }
}

// MARK: - Meal image helper (internet fetch or user photo)
struct MealHeroImage: View {
    @Environment(AppSession.self) var session
    let recipeName: String
    let imageData:  Data?
    @State private var fetchedURL: URL?
    @State private var didFetch = false
    @State private var resolveFailed = false

    var body: some View {
        ZStack {
            if let data = imageData, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill().clipped()
            } else if let url = fetchedURL {
                CachedAsyncImage(url: url.absoluteString, imageData: nil, height: 220)
            } else {
                placeholder
            }
        }
        .onAppear { fetchInternetImage() }
    }

    private var placeholder: some View {
        ZStack {
            Color.stockedCharcoal.opacity(0.15)
            VStack(spacing: 8) {
                Image(systemName: resolveFailed ? "fork.knife" : "photo.badge.magnifyingglass")
                    .font(.system(size: 36)).foregroundStyle(Color.stockedGold)
                if !resolveFailed {
                    Text("Finding image…").font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.4))
                }
            }
        }
    }

    private func fetchInternetImage() {
        guard !didFetch, imageData == nil else { return }
        didFetch = true
        // Use the full resolver chain (TheMealDB → Spoonacular → Foodish), which always
        // returns something rather than getting stuck on generic titles like "Quick Stir Fry".
        let name = (recipeName.components(separatedBy: " — ").last ?? recipeName)
            .trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            if let url = await RecipeImageResolver.shared.imageURL(for: name) {
                fetchedURL = url
            } else {
                resolveFailed = true
            }
        }
    }
}

// MARK: - Internet recipe data (fetched when no manual data)
struct InternetRecipeData {
    var imageURL:  String  = ""
    var steps:     [String] = []
    var cookTime:  String  = ""
    var prepTime:  String  = ""
    var ingredients: [String] = []
}

// MARK: - Recipe Overview (full info before Start Cooking)
struct RecipeOverviewView: View {
    let title:       String
    let servings:    Int
    let ingredients: [String]
    let steps:       [String]
    let cookTime:    String
    let prepTime:    String

    @Environment(AppSession.self) var session
    @State private var startCooking     = false
    @State private var internetData: InternetRecipeData? = nil
    @State private var isFetchingRecipe  = false
    @State private var showPortionEdit   = false
    @State private var adjustedServings  = 0   // 0 = use passed-in servings
    @State private var showCancelAlert   = false

    init(title: String, servings: Int, ingredients: [String] = [],
         steps: [String] = [], cookTime: String = "", prepTime: String = "") {
        self.title = title; self.servings = servings
        self.ingredients = ingredients; self.steps = steps
        self.cookTime = cookTime; self.prepTime = prepTime
    }

    // Use internet data when nothing is manually supplied
    private var displaySteps: [String] {
        if !steps.isEmpty { return steps }
        if let net = internetData, !net.steps.isEmpty { return net.steps }
        return [
            "Gather and prep all your ingredients.",
            "Heat your pan or oven as needed.",
            "Cook your protein or main ingredient first.",
            "Add aromatics (garlic, onion, herbs) and cook 1–2 min.",
            "Add remaining ingredients and cook through.",
            "Season to taste, plate and serve."
        ]
    }
    private var displayIngredients: [String] {
        if !ingredients.isEmpty { return ingredients }
        if let net = internetData, !net.ingredients.isEmpty { return net.ingredients }
        return defaultIngredients(for: title)
    }
    private var displayCookTime: String {
        if !cookTime.isEmpty { return cookTime }
        return internetData?.cookTime ?? "25–35 min"
    }
    private var displayPrepTime: String {
        if !prepTime.isEmpty { return prepTime }
        return internetData?.prepTime ?? "10–15 min"
    }
    private var displayImageURL: String? { internetData?.imageURL }

    // MARK: - Serving adjustment
    private var effectiveServings: Int {
        adjustedServings > 0 ? adjustedServings : max(1, servings)
    }
    private var baseServings: Int { max(1, servings == 0 ? 4 : servings) }
    private var scaleFactor: Double { Double(effectiveServings) / Double(baseServings) }

    /// #16 — sum of detectable per-step timer durations, as whole minutes.
    private var estimatedTimerMinutes: Int? {
        let total = displaySteps.reduce(0) { acc, step in
            acc + (StepTimerEngine.detectSeconds(in: step) ?? 0)
        }
        return total > 0 ? Int((Double(total) / 60.0).rounded()) : nil
    }

    // Scale a single ingredient string by scaleFactor, then convert its unit to the
    // user's selected measurement system (US/metric, incl. cups↔grams) when recognized.
    private func scaleIngredient(_ ing: String) -> String {
        // Match leading quantity: "2 cups", "1½ tbsp", "0.5 tsp", "3-4 cloves"
        let pattern = #"^(\d+[\.\d]*)([\u00BD\u2153\u2154\u00BC\u00BE]?)\s*(?:-\s*\d+)?\s+"#
        guard let range = ing.range(of: pattern, options: .regularExpression) else { return ing }
        let numStr = String(ing[range])
            .replacingOccurrences(of: "½", with: ".5").replacingOccurrences(of: "⅓", with: ".33")
            .replacingOccurrences(of: "⅔", with: ".67").replacingOccurrences(of: "¼", with: ".25")
            .replacingOccurrences(of: "¾", with: ".75")
        guard let num = Double(numStr.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") else { return ing }
        let scaled = num * scaleFactor
        let rest = String(ing[range.upperBound...])

        // Try unit conversion: the first token of `rest` is often the unit.
        let tokens = rest.split(separator: " ", maxSplits: 1).map(String.init)
        if let unitToken = tokens.first,
           UnitConverter.kind(of: unitToken) != .count {
            let ingredientName = tokens.count > 1 ? tokens[1] : rest
            let converted = UnitConverter.convert(amount: scaled, unit: unitToken,
                                                  ingredient: ingredientName,
                                                  to: session.unitSystem)
            return "\(formatNum(converted.value)) \(converted.unit) \(ingredientName)".trimmingCharacters(in: .whitespaces)
        }

        // No recognizable unit — just show the scaled number (unchanged behavior).
        guard scaleFactor != 1.0 else { return ing }
        return formatNum(scaled) + " " + rest
    }

    private func formatNum(_ x: Double) -> String {
        if x == x.rounded() { return String(Int(x.rounded())) }
        if x < 1 { return String(format: "%.2g", x) }
        return String(format: "%.1f", x).replacingOccurrences(of: ".0", with: "")
    }

    private var scaledIngredients: [String] {
        displayIngredients.map { scaleIngredient($0) }
    }

    // Fetch full recipe from TheMealDB — Task-based (no retain cycle risk)
    private func fetchInternetRecipeIfNeeded() {
        guard ingredients.isEmpty || steps.isEmpty, !isFetchingRecipe, internetData == nil else { return }
        isFetchingRecipe = true
        let q = title.components(separatedBy: " — ").last ?? title
        guard let url = URL(string: "https://www.themealdb.com/api/json/v1/1/search.php?s=\(q.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") else { return }
        Task { @MainActor in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let json  = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let meals = json["meals"] as? [[String: Any]],
                  let m     = meals.first else {
                isFetchingRecipe = false; return
            }
            var d       = InternetRecipeData()
            d.imageURL  = m["strMealThumb"] as? String ?? ""
            d.cookTime  = "30 min"; d.prepTime = "15 min"
            d.steps = (m["strInstructions"] as? String ?? "")
                .components(separatedBy: CharacterSet.newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.count > 15 }.prefix(8).map { $0 }
            var ings: [String] = []
            for i in 1...20 {
                let ing  = (m["strIngredient\(i)"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                let meas = (m["strMeasure\(i)"]    as? String ?? "").trimmingCharacters(in: .whitespaces)
                if !ing.isEmpty { ings.append(meas.isEmpty ? ing : "\(meas) \(ing)") }
            }
            d.ingredients = ings
            internetData    = d
            isFetchingRecipe = false
        }
    }

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 0) {

                // ── Meal image (internet or user) ─────────────────────
                ZStack {
                    MealHeroImage(recipeName: title, imageData: nil)
                        .frame(maxWidth: .infinity).frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                    if isFetchingRecipe {
                        VStack { Spacer(); HStack { Spacer()
                            ProgressView().tint(Color.stockedGold)
                                .padding(10).background(Color.black.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                            .padding(12) } }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 12)
                .onAppear { fetchInternetRecipeIfNeeded() }

                // ── Title + meta ──────────────────────────────────────
                VStack(alignment: .leading, spacing: 6) {
                    Text(title.isEmpty ? "Recipe" : title)
                        .font(.system(size: 24, weight: .bold, design: .serif))
                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                        .padding(.horizontal, 20)
                    // Meta row: scrolls horizontally so it never squeezes the labels into a
                    // vertical "s/e/r/v/i/n/g/s" column on narrower phones (e.g. iPhone 16 Pro).
                    ScrollView(.horizontal, showsIndicators: false) {
                      HStack(alignment: .center, spacing: 16) {
                        // Serving stepper — label sits BELOW the controls.
                        VStack(spacing: 2) {
                            HStack(spacing: 6) {
                                Image(systemName: "person.2.fill")
                                    .font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                                Button {
                                    withAnimation(.spring(response: 0.2)) {
                                        adjustedServings = max(1, effectiveServings - 1)
                                    }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .font(.system(size: 15)).foregroundStyle(Color.stockedGold)
                                }.buttonStyle(.plain)
                                Text("\(effectiveServings)")
                                    .font(.system(size: 13, weight: .bold, design: .serif))
                                    .foregroundStyle(session.themeTextColor)
                                    .frame(minWidth: 20)
                                    .contentTransition(.numericText())
                                    .animation(.spring(response: 0.2), value: effectiveServings)
                                Button {
                                    withAnimation(.spring(response: 0.2)) {
                                        adjustedServings = effectiveServings + 1
                                    }
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .font(.system(size: 15)).foregroundStyle(Color.stockedGold)
                                }.buttonStyle(.plain)
                            }
                            Text("servings")
                                .font(.system(size: 12))
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                                .lineLimit(1)
                                .fixedSize()   // never wrap
                        }
                        metaBadge(icon: "clock.fill",     text: displayPrepTime + " prep")
                        metaBadge(icon: "flame.fill",     text: displayCookTime + " cook")
                        if let mins = estimatedTimerMinutes, mins > 0 {
                            metaBadge(icon: "timer", text: "~\(mins) min timers")
                        }
                      }
                      .padding(.horizontal, 20)
                    }
                }
                .padding(.bottom, 16)

                // ── Nutrition summary ────────────────────────────────
                RecipeNutritionSummary(ingredients: displayIngredients, servings: servings)
                    .padding(.horizontal, 20).padding(.bottom, 8)

                // ── Ingredients ───────────────────────────────────────
                ingredientsSection

                // ── Recipe Steps (all shown before Start Cooking) ─────
                stepsSection

                // ── Tips ──────────────────────────────────────────────
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "lightbulb.fill")
                            .font(.system(size: 13)).foregroundStyle(Color.stockedGold)
                        Text("Tips & Tricks")
                            .font(.system(size: 14, weight: .bold, design: .serif))
                            .foregroundStyle(Color.stockedGold)
                    }
                    Text("Season in layers as you cook, not just at the end. Taste frequently and adjust salt, acid (lemon/vinegar), and heat to balance the dish.")
                        .font(.system(size: 13))
                        .foregroundStyle(session.isDarkMode ? Color(white: 0.65) : Color.stockedCharcoal.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Color.stockedGold.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                .padding(.horizontal, 20).padding(.bottom, 20)

                // ── Portion check fail-safe ──────────────────────────
                portionCheckSection

                // ── Start Cooking ─────────────────────────────────────
                Button { startCooking = true } label: {
                    Text("Start Cooking")
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .padding(.horizontal, 24).padding(.bottom, 12)

                Text("Ingredients will be deducted from inventory when you finish cooking.")
                    .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .padding(.horizontal, 28).padding(.bottom, 8)
            }
        }
        .navigationDestination(isPresented: $startCooking) {
            CookingFlashcardView(recipeTitle: title, ingredients: scaledIngredients, steps: displaySteps, baseServings: effectiveServings)
        }
        .sheet(isPresented: $showPortionEdit) {
            AddItemSheet(defaultZone: "Fridge").environment(session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            startCooking = false   // collapse cook flow on iPad (no .id rebuild there)
        }
    }

    @ViewBuilder private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ingredients")
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)

            // Scale indicator
            if scaleFactor != 1.0 {
                Text(effectiveServings > baseServings ? "↑ Scaled up" : "↓ Scaled down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.stockedGold)
                    .padding(.bottom, 4)
            }
            ForEach(Array(scaledIngredients.enumerated()), id: \.offset) { _, ing in
                let rawIng = ing
                let inStock = session.guestStore.inventoryItems.contains {
                    $0.effectiveLevel > 0.1 &&
                    ($0.name.lowercased().contains(rawIng.lowercased()) ||
                     rawIng.lowercased().contains($0.name.lowercased()))
                }
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Circle().fill(inStock ? Color.stockedGreen : Color.stockedGold)
                            .frame(width: 7, height: 7)
                        Text(ing).font(.system(size: 14))
                            .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                        Spacer()
                        Text(inStock ? "✓ In stock" : "Need to buy")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(inStock ? Color.stockedGreen : Color.stockedGold)
                    }
                    // #9 — if not in stock, suggest a substitute the user actually has.
                    if !inStock {
                        let subs = session.guestStore.inStockSubstitutes(for: rawIng)
                        if let sub = subs.first {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.2.squarepath").font(.system(size: 9))
                                Text("Use \(sub) instead (you have it)")
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Color.stockedGreen.opacity(0.85))
                            .padding(.leading, 17)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background((session.isDarkMode ? Color.white.opacity(0.08) : Color.stockedWhite.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 20).padding(.bottom, 14)
    }

    @ViewBuilder private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recipe Steps")
                .font(.system(size: 16, weight: .bold, design: .serif))
                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)

            ForEach(Array(displaySteps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(Color.stockedGold).frame(width: 26, height: 26)
                        Text("\(i + 1)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(session.themeTextColor)
                    }
                    .padding(.top, 1)
                    Text(step)
                        .font(.system(size: 14))
                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16)
        .background((session.isDarkMode ? Color.white.opacity(0.08) : Color.stockedWhite.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 20).padding(.bottom, 14)
    }

    @ViewBuilder private var portionCheckSection: some View {
        let missingItems = displayIngredients.filter { ing in
            !session.guestStore.inventoryItems.contains {
                $0.effectiveLevel > 0.05 &&
                ($0.name.lowercased().contains(ing.lowercased()) || ing.lowercased().contains($0.name.lowercased()))
            }
        }
        if !missingItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 13)).foregroundStyle(.orange)
                    Text("Portions check")
                        .font(.system(size: 14, weight: .bold, design: .serif)).foregroundStyle(session.themeTextColor)
                }
                Text("\(missingItems.count) item(s) appear to be out of stock or very low. Double-check your inventory before starting.")
                    .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button { showPortionEdit = true } label: {
                        Text("Edit Inventory")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.stockedWhite)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    }.buttonStyle(.plain)
                    Text("or continue anyway →")
                        .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.45))
                }
            }
            .padding(14)
            .background(Color.orange.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .padding(.horizontal, 20).padding(.bottom, 12)
        }
    }

    private func metaBadge(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Color.stockedGold)
            Text(text).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.65))
                .lineLimit(1).fixedSize()
        }
    }

    private func defaultIngredients(for name: String) -> [String] {
        let n = name.lowercased()
        if n.contains("chicken") { return ["Chicken","Olive Oil","Garlic","Salt","Pepper","Herbs"] }
        if n.contains("beef") || n.contains("steak") { return ["Beef","Butter","Garlic","Salt","Pepper","Rosemary"] }
        if n.contains("pasta") || n.contains("spaghetti") { return ["Pasta","Garlic","Olive Oil","Parsley","Salt","Chili Flakes"] }
        if n.contains("rice") { return ["Rice","Oil","Garlic","Soy Sauce","Eggs","Green Onion"] }
        if n.contains("egg") { return ["Eggs","Butter","Salt","Pepper","Cream"] }
        return ["Main ingredient","Olive Oil","Garlic","Salt","Pepper","Herbs of choice"]
    }
}

// MARK: - Cooking Steps View (scrollable, expandable steps)
struct CookingFlashcardView: View {
    @Environment(AppSession.self) var session
    @Environment(\.stockedDevice) private var device
    let recipeTitle:  String
    let ingredients:  [String]
    let steps:        [String]
    @State private var expandedStep:        Int?    = 0
    @State private var completedSteps:      Set<Int> = []
    @State private var showResumePrompt:    Bool = false
    @State private var liveActivity = LiveActivityManager.shared   // #229 — observed for timer-failure banner
    @State private var sessionEnded = false       // #231 — once finished/stopped, don't let onAppear resurrect the pill
    @State private var liveActivityHint: String?  // #231 — proactive Lock Screen timer warning

    // ── Progress persistence (#11) ──────────────────────────────────
    private var progressKey:  String { "cookProgress_\(recipeTitle.hashValue)" }
    private var timestampKey: String { "cookTimestamp_\(recipeTitle.hashValue)" }

    private func saveProgress() {
        UserDefaults.standard.set(Array(completedSteps), forKey: progressKey)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: timestampKey)
    }
    private func clearProgress() {
        UserDefaults.standard.removeObject(forKey: progressKey)
        UserDefaults.standard.removeObject(forKey: timestampKey)
    }
    private func hasSavedProgress() -> Bool {
        guard let ts = UserDefaults.standard.object(forKey: timestampKey) as? Double else { return false }
        let age = Date().timeIntervalSince1970 - ts
        return age < 7200 && !(UserDefaults.standard.array(forKey: progressKey) as? [Int] ?? []).isEmpty
    }
    private func loadProgress() {
        let saved = UserDefaults.standard.array(forKey: progressKey) as? [Int] ?? []
        completedSteps = Set(saved)
        let firstIncomplete = steps.indices.first { !completedSteps.contains($0) }
        expandedStep = firstIncomplete
        // Resume swipe mode at the first incomplete step too.
        currentCard  = firstIncomplete ?? max(0, steps.count - 1)
    }

    @State private var finishCooking        = false
    @State private var isSwipeMode          = false
    @State private var showCelebration      = false
    @State private var currentCard          = 0
    @State private var cardDragOffset:      CGSize   = .zero
    @State private var timerEngine          = StepTimerEngine()
    @State private var checkedIngredients:  Set<Int> = []
    @State private var checklistExpanded    = false
    @State private var showCancelAlert      = false
    @State private var midCookSubIngredient: String = ""
    @State private var showMidCookSub       = false

    let tips: [String] = [
        "Oil is ready when a water drop sizzles immediately.",
        "Pat protein dry before seasoning for a better sear.",
        "Resist moving it — let the crust form naturally.",
        "Garlic burns fast — watch colour, not the clock.",
        "Scrape browned bits for maximum flavour.",
        "Taste and adjust seasoning before plating.",
        "Season in layers, not just at the end.",
        "Rest meat 5 min before slicing to keep juices in."
    ]

    init(recipeTitle: String, ingredients: [String] = [], steps: [String] = [], baseServings: Int = 4) {
        self.recipeTitle = recipeTitle; self.ingredients = ingredients
        self.steps = steps.isEmpty ? [
            "Gather and prep all ingredients — measure everything before you start.",
            "Heat pan over medium-high heat with a drizzle of oil.",
            "Season your main ingredient on all sides.",
            "Add to the hot pan and cook undisturbed until a crust forms.",
            "Add garlic and aromatics, cook 1–2 min until fragrant.",
            "Add remaining ingredients and finish cooking through.",
            "Taste and adjust seasoning — salt, acid, heat.",
            "Plate and serve immediately."
        ] : steps
    }

    private var allDone: Bool { completedSteps.count == steps.count }
    private func markComplete(_ i: Int) {
        withAnimation(.spring(response: 0.3)) {
            if completedSteps.contains(i) {
                completedSteps.remove(i)
                HapticManager.select()
            } else {
                completedSteps.insert(i)
                let next = steps.indices.first { !completedSteps.contains($0) }
                expandedStep = next
                saveProgress()
                if completedSteps.count == steps.count {
                    HapticManager.success()
                    clearProgress()
                    sessionEnded = true; session.activeCook = nil   // #228 — cook finished
                    Task {
                        try? await Task.sleep(nanoseconds: 400000000)
                        withAnimation { showCelebration = true }
                    }
                } else {
                    HapticManager.select()    // step complete — light haptic
                }
            }
        }
    }

    // Ingredients checklist — shared by the iPhone inline layout and the iPad left pane.
    // `forcedExpanded` keeps it always open on iPad (where it's a persistent column).
    @ViewBuilder
    private func ingredientsChecklist(forcedExpanded: Bool) -> some View {
        let isOpen = forcedExpanded || checklistExpanded
        VStack(spacing: 0) {
            Button {
                if !forcedExpanded { withAnimation(.spring(response: 0.3)) { checklistExpanded.toggle() } }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .font(.system(size: 13)).foregroundStyle(Color.stockedGold)
                    Text("Ingredients")
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Text("\(checkedIngredients.count)/\(ingredients.count) prepped")
                        .font(.system(size: 11))
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                    if !forcedExpanded {
                        Image(systemName: checklistExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.35))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }.buttonStyle(.plain).disabled(forcedExpanded)

            if isOpen {
                Divider().padding(.horizontal, 14)
                VStack(spacing: 0) {
                    ForEach(Array(ingredients.enumerated()), id: \.offset) { idx, ing in
                        HStack(spacing: 10) {
                            Button {
                                withAnimation(.spring(response: 0.2)) {
                                    if checkedIngredients.contains(idx) {
                                        checkedIngredients.remove(idx)
                                    } else {
                                        checkedIngredients.insert(idx)
                                        HapticManager.select()
                                    }
                                }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: checkedIngredients.contains(idx)
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18))
                                        .foregroundStyle(checkedIngredients.contains(idx)
                                                         ? Color.stockedGold : session.themeTextColor.opacity(0.3))
                                    Text(ing)
                                        .font(.system(size: 13))
                                        .foregroundStyle(checkedIngredients.contains(idx)
                                                         ? session.themeTextColor.opacity(0.4)
                                                         : session.themeTextColor)
                                        .strikethrough(checkedIngredients.contains(idx))
                                    Spacer()
                                }
                                .padding(.leading, 14).padding(.vertical, 12)
                            }.buttonStyle(.plain)

                            if StockedDatabase.shared.hasSubstitution(for: ing) {
                                Button {
                                    midCookSubIngredient = ing
                                    showMidCookSub = true
                                } label: {
                                    Text("Sub")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(Color.stockedGold)
                                        .padding(.horizontal, 7).padding(.vertical, 4)
                                        .background(Color.stockedGold.opacity(0.12))
                                        .clipShape(Capsule())
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 14)
                            }
                        }
                        if idx < ingredients.count - 1 {
                            Divider().padding(.leading, 42)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    var body: some View {
        StockedShell(showBack: true) {
            HStack(alignment: .top, spacing: 0) {
                // iPad: persistent ingredients pane on the left so you don't scroll back
                // to check ingredients while following steps. (#7 side-by-side cook mode)
                if device == .tablet && !ingredients.isEmpty {
                    ScrollView(showsIndicators: false) {
                        ingredientsChecklist(forcedExpanded: true)
                            .padding(16)
                    }
                    .frame(width: 320)
                    Divider()
                }

            VStack(alignment: .leading, spacing: 0) {

                // #16 — surface a Lock Screen timer problem on-device (orange warning only).
                if let failure = liveActivity.lastFailure ?? liveActivityHint {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.orange)
                        Text(failure)
                            .font(.system(size: 11))
                            .foregroundStyle(session.themeTextColor.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .background(Color.orange.opacity(0.10))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    .padding(.horizontal, 16).padding(.top, 8)
                }

                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("How to Cook")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                        Text(recipeTitle)
                            .font(.system(size: 20, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                    }
                    Spacer()
                    // View mode toggle
                    Button {
                        withAnimation(.spring(response: 0.3)) { isSwipeMode.toggle() }
                    } label: {
                        Image(systemName: isSwipeMode ? "list.bullet" : "rectangle.stack.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                            .padding(8)
                            .background(session.isDarkMode ? Color.white.opacity(0.12) : Color.stockedWhite.opacity(0.35))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                    }.buttonStyle(.plain).padding(.trailing, 8)
                    // Progress ring
                    ZStack {
                        Circle().stroke(Color.stockedCharcoal.opacity(0.15), lineWidth: 4)
                        Circle().trim(from: 0, to: steps.isEmpty ? 0 : CGFloat(completedSteps.count) / CGFloat(steps.count))
                            .stroke(Color.stockedGold, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.spring(response: 0.4), value: completedSteps.count)
                        Text("\(completedSteps.count)/\(steps.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(session.themeTextColor)
                    }
                    .frame(width: 52, height: 52)
                }
                .padding(.horizontal, 24).padding(.bottom, 16)

                // Tip of the day banner
                HStack(spacing: 10) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 13)).foregroundStyle(Color.stockedGold)
                    Text(tips[min(completedSteps.count, tips.count - 1)])
                        .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(Color.stockedGold.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                .padding(.horizontal, 20).padding(.bottom, 10)

                // ── Ingredients Checklist — inline on iPhone; on iPad it moves to a
                //    persistent left pane (see body split below). ──────────────
                if !ingredients.isEmpty && device != .tablet {
                    ingredientsChecklist(forcedExpanded: false)
                        .padding(.horizontal, 20).padding(.bottom, 12)
                }

                if isSwipeMode {
                    // ── Swipe Card Mode ──────────────────────────────────
                    ZStack {
                        RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)
                            .fill(session.themeButtonColor)
                            .frame(maxWidth: .infinity).frame(height: 260)
                        VStack(spacing: 16) {
                            HStack {
                                Text("Step \(currentCard + 1) of \(steps.count)")
                                    .font(.system(size: 14, weight: .semibold, design: .serif))
                                    .foregroundStyle(Color.stockedWhite.opacity(0.6))
                                Spacer()
                                if completedSteps.contains(currentCard) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(Color.stockedGold)
                                }
                            }.padding(.horizontal, 20)
                            Text(steps[currentCard])
                                .font(.system(size: 16, design: .serif))
                                .foregroundStyle(Color.stockedWhite)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 24)
                                .fixedSize(horizontal: false, vertical: true)
                            // Dot indicators
                            HStack(spacing: 6) {
                                ForEach(steps.indices, id: \.self) { i in
                                    Circle()
                                        .fill(i == currentCard ? Color.stockedGold : Color.white.opacity(0.3))
                                        .frame(width: i == currentCard ? 9 : 6, height: i == currentCard ? 9 : 6)
                                        .animation(.spring(response: 0.25), value: currentCard)
                                }
                            }
                        }
                    }
                    .offset(x: cardDragOffset.width)
                    .gesture(DragGesture()
                        .onChanged { cardDragOffset = $0.translation }
                        .onEnded { v in
                            withAnimation(.spring(response: 0.3)) {
                                if v.translation.width < -60 {
                                    if currentCard < steps.count - 1 {
                                        completedSteps.insert(currentCard)
                                        currentCard += 1
                                    }
                                } else if v.translation.width > 60 && currentCard > 0 {
                                    currentCard -= 1
                                }
                                cardDragOffset = .zero
                            }
                        }
                    )
                    .padding(.horizontal, 20)
                    // Swipe nav buttons
                    HStack(spacing: 20) {
                        Button {
                            withAnimation(.spring(response: 0.3)) { if currentCard > 0 { currentCard -= 1 } }
                        } label: {
                            Image(systemName: "chevron.left.circle.fill").font(.system(size: 32))
                                .foregroundStyle(currentCard == 0 ? Color.stockedCharcoal.opacity(0.3) : Color.stockedGold)
                        }.disabled(currentCard == 0).buttonStyle(.plain)
                        Spacer()
                        Button {
                            withAnimation(.spring(response: 0.3)) {
                                completedSteps.insert(currentCard)
                                if currentCard < steps.count - 1 { currentCard += 1 }
                            }
                        } label: {
                            Image(systemName: "chevron.right.circle.fill").font(.system(size: 32))
                                .foregroundStyle(currentCard == steps.count - 1 ? Color.stockedGold.opacity(0.4) : Color.stockedGold)
                        }.disabled(currentCard == steps.count - 1 && allDone).buttonStyle(.plain)
                    }.padding(.horizontal, 40).padding(.top, 8).padding(.bottom, 16)

                } else {
                    // ── Scroll + Expand Mode ─────────────────────────────
                    VStack(spacing: 8) {
                        ForEach(steps.indices, id: \.self) { i in
                            CookingStepRow(
                                stepNumber:   i + 1,
                                stepText:     steps[i],
                                isCompleted:  completedSteps.contains(i),
                                isExpanded:   expandedStep == i,
                                timerEngine:  timerEngine,
                                stepIndex:    i,
                                onTap: {
                                    withAnimation(.spring(response: 0.3)) {
                                        expandedStep = expandedStep == i ? nil : i
                                    }
                                },
                                onComplete: { markComplete(i) }
                            )
                        }
                    }
                    .padding(.horizontal, 20).padding(.bottom, 20)
                }

                // Finish button — enabled when all done OR user chooses to skip
                VStack(spacing: 8) {
                    Button { sessionEnded = true; session.activeCook = nil; finishCooking = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: allDone ? "checkmark.circle.fill" : "flag.fill")
                            Text(allDone ? "All Done — Finish Cooking" : "Finish Cooking")
                                .font(.system(size: 16, weight: .semibold, design: .serif))
                        }
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .background(allDone ? Color.stockedGold : Color.stockedCharcoal)
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                        .animation(.spring(response: 0.3), value: allDone)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24)

                    if !allDone {
                        Text("\(steps.count - completedSteps.count) step(s) remaining")
                            .font(.system(size: 12))
                            .foregroundStyle(session.themeTextColor.opacity(0.35))
                    }
                }
                .padding(.bottom, 12)
            }
            }
        }
        .overlay {
            if showCelebration {
                CelebrationOverlay(
                    isShowing: $showCelebration,
                    title: "Recipe Complete!",
                    message: "Great cook. Ingredients deducted from your pantry.",
                    emoji: "🎉"
                )
                .zIndex(200)
                .onDisappear { finishCooking = true }
            }
        }
        .navigationDestination(isPresented: $finishCooking) {
            TimeToPlatView(recipeTitle: recipeTitle, ingredients: ingredients)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            finishCooking = false   // collapse cook flow on iPad
        }
        .onAppear  {
            UIApplication.shared.isIdleTimerDisabled = true
            // #16 — give the timer engine the context the Live Activity needs.
            timerEngine.recipeTitle = recipeTitle
            timerEngine.totalSteps = steps.count
            // #231 — proactively flag if Lock Screen timers can't run, before any tap.
            if !liveActivity.isEnabled {
                liveActivityHint = "Lock Screen timers are off. Turn on Live Activities in Settings → Stocked, and confirm ‘Supports Live Activities’ = YES in the app target's Info."
            }
            // #228 — record the in-progress cook so the floating pill can resume it.
            // #231 — guard on sessionEnded so backing out of the plating screen (which
            // re-fires this onAppear) can't resurrect a just-finished cook and stick the pill.
            if !sessionEnded && session.activeCook?.title != recipeTitle {
                session.activeCook = .init(title: recipeTitle, ingredients: ingredients,
                                           steps: steps, servings: 4, startedAt: Date())
            }
            // Silently restore where you left off so navigating away & back keeps your place.
            if completedSteps.isEmpty && hasSavedProgress() { loadProgress() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            timerEngine.cancelAll()
            // Capture progress when leaving mid-cook (not just on step completion), unless
            // we've finished (which clears it).
            if !completedSteps.isEmpty && completedSteps.count < steps.count { saveProgress() }
        }
        .alert("Stop Cooking?", isPresented: $showCancelAlert) {
            Button("Keep Cooking", role: .cancel) {}
            Button("Stop", role: .destructive) { sessionEnded = true; session.activeCook = nil; finishCooking = false }
        } message: {
            Text("Your inventory won't be changed. You can restart this recipe any time.")
        }
        .sheet(isPresented: $showMidCookSub) {
            MidCookSubstitutionSheet(ingredientName: midCookSubIngredient)
                .environment(session)
        }
    }
}

// MARK: - Individual step row
struct CookingStepRow: View {
    @Environment(AppSession.self) var session
    let stepNumber:  Int
    let stepText:    String
    let isCompleted: Bool
    let isExpanded:  Bool
    var timerEngine: StepTimerEngine? = nil
    var stepIndex:   Int              = 0
    var imageURL:    String?          = nil
    let onTap:       () -> Void
    let onComplete:  () -> Void

    private var detectedSeconds: Int? { StepTimerEngine.detectSeconds(in: stepText) }
    private var stepTimer: StepTimer? { timerEngine?.timers[stepIndex] }

    var body: some View {
        VStack(spacing: 0) {
            // Step header (always visible)
            Button(action: onTap) {
                HStack(spacing: 12) {
                    // Step number circle — pulsing ring when timer active
                    ZStack {
                        if let t = stepTimer, t.isRunning {
                            Circle()
                                .trim(from: 0, to: 1 - t.progress)
                                .stroke(Color.stockedGold, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                                .frame(width: 36, height: 36)
                        }
                        Circle()
                            .fill(isCompleted ? Color.stockedGold
                                  : (stepTimer?.isFinished == true ? Color.stockedGreen : Color.stockedCharcoal))
                            .frame(width: 32, height: 32)
                        if isCompleted || stepTimer?.isFinished == true {
                            Image(systemName: "checkmark")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.stockedWhite)
                        } else if let t = stepTimer, t.isRunning {
                            Text(t.displayString)
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.stockedWhite)
                        } else {
                            Text("\(stepNumber)")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.stockedWhite)
                        }
                    }
                    .animation(.spring(response: 0.3), value: stepTimer?.isRunning)

                    Text(isExpanded ? "Step \(stepNumber)" : stepText)
                        .font(.system(size: 14, design: .serif))
                        .foregroundStyle(isCompleted ? session.themeTextColor.opacity(0.4) : session.themeTextColor)
                        .strikethrough(isCompleted)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: false)

                    Spacer()

                    // Timer badge when detected but not started
                    if let secs = detectedSeconds, stepTimer == nil {
                        HStack(spacing: 3) {
                            Image(systemName: "timer").font(.system(size: 9))
                            Text(formatSecs(secs)).font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(Color.stockedGold)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.stockedGold.opacity(0.12)).clipShape(Capsule())
                    }
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.35))
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Expanded content
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    Divider().padding(.horizontal, 14)

                    HStack(alignment: .top, spacing: 8) {
                        Text(stepText)
                            .font(.system(size: 15, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        // #6 — read this step aloud (tap again to stop).
                        Button { SpeechReader.shared.toggle(stepText) } label: {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.stockedGold)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 14)

                    // Step photo if available
                    if let url = imageURL, !url.isEmpty {
                        CachedAsyncImage(url: url, imageData: nil, height: 160)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            .padding(.horizontal, 14)
                    }

                    // Timer controls
                    if detectedSeconds != nil || stepTimer != nil {
                        HStack(spacing: 12) {
                            let t = stepTimer
                            if t == nil {
                                Button {
                                    timerEngine?.startTimer(stepIndex: stepIndex, stepText: stepText)
                                    HapticManager.select()
                                } label: {
                                    Label("Start Timer", systemImage: "play.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(Color.stockedWhite)
                                        .padding(.horizontal, 14).padding(.vertical, 11)
                                        .background(Color.stockedGold).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                                }.buttonStyle(.plain)
                            } else if t?.isFinished == true {
                                Label("Done ✓", systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.stockedGreen)
                                Button { timerEngine?.resetTimer(stepIndex: stepIndex) } label: {
                                    Text("Reset").font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.5))
                                }.buttonStyle(.plain)
                            } else {
                                Text(t?.displayString ?? "")
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.stockedGold)
                                if t?.isRunning == true {
                                    Button { timerEngine?.pauseTimer(stepIndex: stepIndex) } label: {
                                        Image(systemName: "pause.fill")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.stockedWhite)
                                            .padding(9)
                                            .background(Color.stockedCharcoal).clipShape(Circle())
                                    }.buttonStyle(.plain)
                                } else {
                                    Button {
                                        timerEngine?.startTimer(stepIndex: stepIndex, stepText: stepText)
                                    } label: {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.stockedWhite)
                                            .padding(9)
                                            .background(Color.stockedGold).clipShape(Circle())
                                    }.buttonStyle(.plain)
                                }
                                Button { timerEngine?.resetTimer(stepIndex: stepIndex) } label: {
                                    Image(systemName: "arrow.counterclockwise")
                                        .font(.system(size: 12))
                                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 14)
                    }

                    Button(action: onComplete) {
                        Label(isCompleted ? "Mark Incomplete" : "Mark Complete",
                              systemImage: isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(isCompleted ? session.themeTextColor.opacity(0.45) : Color.stockedGold)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14).padding(.bottom, 12)
                }
            }
        }
        .background(isCompleted ? Color.stockedWhite.opacity(0.15) : Color.stockedWhite.opacity(0.30))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
            .stroke(isCompleted ? Color.stockedGold.opacity(0.3)
                    : (stepTimer?.isRunning == true ? Color.stockedGold.opacity(0.6) : Color.clear), lineWidth: 1))
        .animation(.easeInOut(duration: 0.2), value: stepTimer?.isRunning)
    }

    private func formatSecs(_ s: Int) -> String {
        let m = s / 60; let sec = s % 60
        return sec == 0 ? "\(m)m" : "\(m)m \(sec)s"
    }
}

// MARK: - Time to Plate
struct TimeToPlatView: View {
    let recipeTitle:  String
    let ingredients:  [String]
    @Environment(AppSession.self) var session
    @State private var advance          = false
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var platePhoto:    Data?
    @State private var didDeduct        = false
    @State private var showDeductSheet  = false

    init(recipeTitle: String, ingredients: [String] = []) {
        self.recipeTitle = recipeTitle; self.ingredients = ingredients
    }

    var body: some View {
        StockedShell(showBack: true) {
            VStack(spacing: 0) {
                Text("Time to Plate")
                    .font(.system(size: 30, weight: .bold, design: .serif))
                    .foregroundStyle(Color.stockedGold).padding(.bottom, 20)

                ZStack {
                    if let data = platePhoto, let ui = UIImage(data: data) {
                        Image(uiImage: ui).resizable().scaledToFill()
                            .frame(maxWidth: .infinity).frame(height: 200).clipped().clipShape(RoundedRectangle(cornerRadius: 16))
                    } else {
                        RoundedRectangle(cornerRadius: 16).fill(Color.stockedCharcoal.opacity(0.2))
                            .frame(maxWidth: .infinity).frame(height: 160)
                        VStack(spacing: 10) {
                            Image(systemName: "camera.fill").font(.system(size: 32)).foregroundStyle(Color.stockedGold)
                            Text("Add a plate photo (optional)").font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.55))
                        }
                    }
                }
                .padding(.horizontal, 24).padding(.bottom, 10)

                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Text(platePhoto == nil ? "Take Plate Photo" : "Change Photo")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.stockedGold)
                }.padding(.bottom, 20)
                .onChange(of: selectedPhoto) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self) {
                            await MainActor.run { platePhoto = data }
                        }
                    }
                }

                VStack(spacing: 14) {
                    Text("You're all done!")
                        .font(.system(size: 22, weight: .semibold, design: .serif)).foregroundStyle(Color.stockedWhite)
                    Text("Ingredients deducted from your inventory.")
                        .font(.system(size: 14)).foregroundStyle(Color.stockedWhite.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal, 20)
                    Button { advance = true } label: {
                        Text("Rate & Finish")
                            .font(.system(size: 18, weight: .regular, design: .serif)).foregroundStyle(Color.stockedWhite)
                    }
                }
                .padding(28).frame(maxWidth: .infinity).background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: 16)).padding(.horizontal, 20)
            }
        }
        .navigationDestination(isPresented: $advance) {
            RatingView(recipeTitle: recipeTitle, ingredients: ingredients, platePhotoData: platePhoto)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            advance = false   // collapse cook flow on iPad
        }
        .onAppear {
            if !didDeduct { showDeductSheet = true }
        }
        .sheet(isPresented: $showDeductSheet) {
            IngredientDeductSheet(
                ingredients: ingredients,
                onConfirm: { session.guestStore.deductIngredients($0); didDeduct = true },
                onSkip:    { didDeduct = true }
            ).environment(session)
        }
    }
}

// MARK: - Ingredient deduction adjustment sheet
struct IngredientDeductSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let ingredients: [String]
    let onConfirm: ([String]) -> Void
    let onSkip:    () -> Void
    @State private var usedFull: [Bool]

    init(ingredients: [String], onConfirm: @escaping ([String]) -> Void, onSkip: @escaping () -> Void) {
        self.ingredients = ingredients
        self.onConfirm   = onConfirm
        self.onSkip      = onSkip
        _usedFull = State(initialValue: Array(repeating: true, count: ingredients.count))
    }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    Text("Confirm what you used")
                        .font(.system(size: 18, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 6)
                    Text("Uncheck anything you didn't use — those won't be deducted.")
                        .font(.system(size: 13)).foregroundStyle(session.themeTextColor.opacity(0.55))
                        .padding(.horizontal, 24).padding(.bottom, 16)

                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(ingredients.indices, id: \.self) { i in
                                Button {
                                    withAnimation(.spring(response: 0.2)) { usedFull[i].toggle() }
                                } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: usedFull[i] ? "checkmark.circle.fill" : "circle")
                                            .font(.system(size: 20))
                                            .foregroundStyle(usedFull[i] ? Color.stockedGold : session.themeTextColor.opacity(0.3))
                                        Text(ingredients[i])
                                            .font(.system(size: 14))
                                            .foregroundStyle(usedFull[i] ? session.themeTextColor : session.themeTextColor.opacity(0.4))
                                            .strikethrough(!usedFull[i])
                                        Spacer()
                                    }
                                    .padding(.horizontal, 24).padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                if i < ingredients.count - 1 { Divider().padding(.leading, 60) }
                            }
                        }
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                        .padding(.horizontal, 20)
                    }

                    VStack(spacing: 10) {
                        Button {
                            let used = ingredients.indices.compactMap { usedFull[$0] ? ingredients[$0] : nil }
                            onConfirm(used); dismiss()
                        } label: {
                            Text("Deduct from Pantry")
                                .font(.system(size: 16, weight: .semibold, design: .serif))
                                .foregroundStyle(Color.stockedWhite)
                                .frame(maxWidth: .infinity).padding(.vertical, 16)
                                .background(Color.stockedGold).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                        }.buttonStyle(.plain)

                        Button { onSkip(); dismiss() } label: {
                            Text("Skip — don't deduct")
                                .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.45))
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 24).padding(.vertical, 16)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Rating View
struct RatingView: View {
    let recipeTitle:     String
    let ingredients:     [String]
    let platePhotoData:  Data?
    @Environment(AppSession.self) var session
    @Environment(\.stockedGoHome) private var goHome
    @Environment(\.dismiss) private var dismiss
    @State private var rating      = 4
    @State private var thumbUp     = true
    @State private var hasLeftover: Bool? = nil
    @State private var leftoverName = ""
    @State private var leftoverZone = "Fridge"
    @State private var notes       = ""

    init(recipeTitle: String, ingredients: [String] = [], platePhotoData: Data? = nil) {
        self.recipeTitle = recipeTitle; self.ingredients = ingredients; self.platePhotoData = platePhotoData
    }

    var body: some View {
        StockedShell(showBack: true) {
            VStack(spacing: 0) {
                Text("How was it?")
                    .font(.system(size: 26, weight: .bold, design: .serif))
                    .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal).padding(.bottom, 6)
                Text(recipeTitle).font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.5)).padding(.bottom, 20)

                HStack(spacing: 10) {
                    ForEach(1...5, id: \.self) { star in
                        Image(systemName: star <= rating ? "star.fill" : "star")
                            .font(.system(size: 36)).foregroundStyle(Color.stockedGold)
                            .onTapGesture { withAnimation(.spring(response: 0.2)) { rating = star } }
                    }
                }.padding(.bottom, 20)

                HStack(spacing: 32) {
                    Button { withAnimation { thumbUp = true } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: thumbUp ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.system(size: 36)).foregroundStyle(thumbUp ? Color.stockedGold : Color.stockedCharcoal.opacity(0.3))
                            Text("Would make again").font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.4))
                        }
                    }.buttonStyle(.plain)
                    Button { withAnimation { thumbUp = false } } label: {
                        VStack(spacing: 4) {
                            Image(systemName: !thumbUp ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                .font(.system(size: 36)).foregroundStyle(!thumbUp ? .red.opacity(0.7) : session.themeTextColor.opacity(0.2))
                            Text("Not for me").font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.4))
                        }
                    }.buttonStyle(.plain)
                }.padding(.bottom, 28)

                VStack(spacing: 0) {
                    Text("Any food left over?")
                        .font(.system(size: 20, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor).padding(.bottom, 14)
                    HStack(spacing: 12) {
                        leftoverButton(label: "Yes — Fridge", icon: "refrigerator.fill",
                                       selected: hasLeftover == true && leftoverZone == "Fridge", color: Color.stockedGreen) {
                            withAnimation { hasLeftover = true; leftoverZone = "Fridge" }
                        }
                        leftoverButton(label: "Freeze It", icon: "snowflake",
                                       selected: leftoverZone == "Freezer", color: Color.stockedInfo) {
                            withAnimation { hasLeftover = true; leftoverZone = "Freezer" }
                        }
                        leftoverButton(label: "No Leftovers", icon: "xmark.circle.fill",
                                       selected: hasLeftover == false, color: Color.stockedCharcoal.opacity(0.4)) {
                            withAnimation { hasLeftover = false; leftoverZone = "" }
                        }
                    }.padding(.bottom, 12)

                    if hasLeftover == true {
                        TextField("Leftover name (e.g. \(recipeTitle) Leftovers)", text: $leftoverName)
                            .font(.system(size: 14)).foregroundStyle(session.themeTextColor)
                            .padding(14).background(session.isDarkMode ? Color.white.opacity(0.12) : Color.stockedWhite.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            .padding(.bottom, 16)
                    }
                }
                .padding(18).background(Color.stockedWhite.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 20).padding(.bottom, 16)

                TextField("Notes (optional)", text: $notes, axis: .vertical)
                    .font(.system(size: 14)).foregroundStyle(session.themeTextColor).lineLimit(2...4)
                    .padding(14).background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    .padding(.horizontal, 20).padding(.bottom, 20)

                Button { finishMeal() } label: {
                    Text("Finish & Save Meal")
                        .font(.system(size: 17, weight: .semibold, design: .serif)).foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 16).background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }.padding(.horizontal, 24)
            }
        }
    }

    private func leftoverButton(label: String, icon: String, selected: Bool, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(selected ? color : color.opacity(0.12)).frame(width: 44, height: 44)
                    Image(systemName: icon).font(.system(size: 18)).foregroundStyle(selected ? .white : color)
                }
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(selected ? color : session.themeTextColor.opacity(0.6))
                    .multilineTextAlignment(.center)
            }.frame(maxWidth: .infinity)
        }.buttonStyle(.plain)
    }

    private func finishMeal() {
        let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        var meal = LocalPastMeal(title: recipeTitle, date: dateStr)
        meal.rating = rating; meal.thumbUp = thumbUp
        // Rating recorded to session: session.guestStore.cookingProfile is updated elsewhere
        meal.platePhotoData = platePhotoData; meal.notes = notes
        meal.recipeId = session.guestStore.markRecipeCooked(title: recipeTitle)   // #5 — bump cook count + link for ratings
        session.guestStore.markPlannedMealCooked(title: recipeTitle)              // audit fix — flip the planned meal's isCooked
        session.activeCook = nil                                                  // #228 — no longer in progress
        session.guestStore.pastMeals.append(meal)
        session.recordCookToday()   // Streak tracking

        if hasLeftover == true {
            let name = leftoverName.trimmingCharacters(in: .whitespaces).isEmpty ? "\(recipeTitle) Leftovers" : leftoverName
            let zone = leftoverZone.isEmpty ? "Fridge" : leftoverZone
            var item = LocalInventoryItem(name: name, level: 0.75, zone: zone)
            item.isLeftover = true; item.leftoverMeal = recipeTitle
            item.expirationDate = Calendar.current.date(byAdding: .day, value: zone == "Freezer" ? 90 : 4, to: Date())
            session.guestStore.addInventoryItem(item)
        }
        // Return to the live shell: pop the cook flow's NavigationStack to root and
        // select Home. Falls back to dismiss() if the env closure isn't present
        // (e.g. SwiftUI preview). Never push a second MainTabView — that nests a
        // duplicate NavigationStack + tab bar and breaks the bottom buttons.
        if let goHome { goHome() } else { dismiss() }
    }
}

struct SurpriseRecipeDetailView: View {
    let recipe: GeneratedRecipe
    var body: some View {
        RecipeOverviewView(title: recipe.title, servings: recipe.servings, ingredients: recipe.missingIngredients)
    }
}

// MARK: - Mid-Cook Substitution Sheet
struct MidCookSubstitutionSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let ingredientName: String

    private var entry: SubstitutionEntry? {
        StockedDatabase.shared.substitutions(for: ingredientName)
    }

    var body: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            VStack(spacing: 0) {
                Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                    .frame(width: 40, height: 4).padding(.top, 12).padding(.bottom, 16)

                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 16)).foregroundStyle(Color.stockedGold)
                    Text("Substitutes for \(ingredientName.capitalized)")
                        .font(.system(size: 18, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                }
                .padding(.bottom, 20)

                if let subs = entry?.substitutions, !subs.isEmpty {
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 12) {
                            ForEach(subs) { sub in
                                HStack(alignment: .top, spacing: 14) {
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Color.stockedGold)
                                        .frame(width: 18, height: 20)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(sub.substitute)
                                            .font(.system(size: 14, weight: .semibold, design: .serif))
                                            .foregroundStyle(session.themeTextColor)
                                        if !sub.notes.isEmpty {
                                            Text(sub.notes)
                                                .font(.system(size: 12))
                                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                                                .lineSpacing(2)
                                        }
                                        // Live stock check — find any inventory item matching the substitute name
                                        let subWords = sub.substitute.lowercased()
                                            .components(separatedBy: CharacterSet.letters.inverted)
                                            .filter { $0.count > 2 }
                                        let matchedItem = session.guestStore.inventoryItems.first {
                                            let itemLower = $0.name.lowercased()
                                            return subWords.contains(where: { itemLower.contains($0) })
                                        }
                                        if let item = matchedItem {
                                            HStack(spacing: 6) {
                                                Image(systemName: "checkmark.circle.fill")
                                                    .font(.system(size: 12))
                                                    .foregroundStyle(Color.stockedGold)
                                                Text("In pantry · \(item.zone)")
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(Color.stockedGold)
                                                Spacer()
                                                // Fill level pill
                                                Text("\(Int(item.level * 100))%")
                                                    .font(.system(size: 10, weight: .bold))
                                                    .foregroundStyle(item.level > 0.5 ? .white : Color.stockedGold)
                                                    .padding(.horizontal, 7).padding(.vertical, 2)
                                                    .background(item.level > 0.5 ? Color.stockedGold : Color.stockedGold.opacity(0.2))
                                                    .clipShape(Capsule())
                                            }
                                        } else {
                                            Label("Not in pantry", systemImage: "xmark.circle")
                                                .font(.system(size: 11))
                                                .foregroundStyle(session.themeTextColor.opacity(0.35))
                                        }
                                    }
                                    Spacer()
                                }
                                .padding(14)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            }
                        }
                        .padding(.horizontal, 24).padding(.bottom, 40)
                    }
                } else {
                    Text("No substitutions found for this ingredient.")
                        .font(.system(size: 14))
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28).padding(.top, 40)
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview { RecipeOverviewView(title: "Garlic Chicken", servings: 2, ingredients: ["Chicken","Garlic","Olive Oil","Herbs"]) }
