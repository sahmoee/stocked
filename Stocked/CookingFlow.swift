// CookingFlow.swift
import SwiftUI
import Combine
import PhotosUI
import AVFoundation

// #6/#C5 — Read-aloud helper. Speaks a cooking step; tapping again stops. Upgraded to
// @Observable so step rows can highlight the speaker icon while their step is being
// read. Keeps the original toggle(_ text:) API for existing callers (cooking flow,
// full-screen cook) and adds an id-based variant used by TimedStepRow so per-step
// icons know which step is active.
@Observable
@MainActor
final class SpeechReader {
    static let shared = SpeechReader()
    private let synth = AVSpeechSynthesizer()
    /// Which step is currently being spoken (nil = silent). Views observe this
    /// to swap the speaker icon. For legacy id-less calls this is the text itself.
    private(set) var speakingID: String? = nil

    private init() {}

    /// Legacy API — toggle speech for a step, keyed by its text.
    func toggle(_ text: String) { toggle(id: text, text: text) }

    /// Id-keyed toggle: tapping the speaking step stops it; tapping a different
    /// step switches to it.
    func toggle(id: String, text: String) {
        if speakingID == id, synth.isSpeaking {
            stop()
            return
        }
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        let u = AVSpeechUtterance(string: text)
        u.rate = 0.48
        u.voice = AVSpeechSynthesisVoice(language: "en-US")
        synth.speak(u)
        speakingID = id
        // Reset the highlight after the utterance would have finished (approximate;
        // a delegate needs an NSObject subclass — the icon also resets on any toggle).
        let estimate = Double(text.count) * 0.065 + 1.0
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(estimate * 1_000_000_000))
            if self?.speakingID == id, self?.synth.isSpeaking == false {
                self?.speakingID = nil
            }
        }
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        speakingID = nil
    }
    var isSpeaking: Bool { synth.isSpeaking }
}

// MARK: - Meal image helper (internet fetch or user photo)
struct MealHeroImage: View {
    let recipeName: String
    let imageData:  Data?

    var body: some View {
        // Keep local photo decoding, disk reads, remote fetches, downsampling, and
        // name-based image resolution off the render path. CachedAsyncImage reuses the
        // shared memory/disk cache instead of resolving the same recipe on every visit.
        CachedAsyncImage(
            url: nil,
            imageData: imageData,
            height: 220,
            resolveName: recipeName
        )
    }
}

// MARK: - Internet recipe data (fetched when no manual data)
nonisolated struct InternetRecipeData: Codable, Sendable {
    var imageURL:  String  = ""
    var steps:     [String] = []
    var cookTime:  String  = ""
    var prepTime:  String  = ""
    var ingredients: [String] = []
}

/// Persistent stale-while-revalidate cache for overview recipes. Network and JSON parsing
/// happen inside this actor, never on the UI actor, and a cached recipe opens immediately.
actor InternetRecipeCache {
    static let shared = InternetRecipeCache()
    private struct Entry: Codable, Sendable { let data: InternetRecipeData; let savedAt: Date }
    private let defaultsKey = "stocked.internetRecipeCache.v2"
    private let ttl: TimeInterval = 60 * 60 * 24 * 30
    private var entries: [String: Entry]? = nil

    func recipe(for title: String) async -> InternetRecipeData? {
        loadIfNeeded()
        let key = normalized(title)
        guard let entry = entries?[key], Date().timeIntervalSince(entry.savedAt) < ttl else { return nil }
        return entry.data
    }

    func fetchIfNeeded(title: String) async -> InternetRecipeData? {
        if let cached = await recipe(for: title) { return cached }
        let query = title.components(separatedBy: " — ").last ?? title
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.themealdb.com/api/json/v1/1/search.php?s=\(encoded)") else { return nil }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        guard let (raw, response) = try? await URLSession(configuration: config).data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              let meals = json["meals"] as? [[String: Any]], let meal = meals.first else { return nil }
        var data = InternetRecipeData()
        data.imageURL = meal["strMealThumb"] as? String ?? ""
        data.cookTime = "30 min"
        data.prepTime = "15 min"
        let instructionText = meal["strInstructions"] as? String ?? ""
        let split = RecipeStepSplitter.split(instructionText)
        data.steps = split.isEmpty ? [instructionText].filter { !$0.isEmpty } : split
        for index in 1...20 {
            let ingredient = (meal["strIngredient\(index)"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let measure = (meal["strMeasure\(index)"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if !ingredient.isEmpty { data.ingredients.append([measure, ingredient].filter { !$0.isEmpty }.joined(separator: " ")) }
        }
        loadIfNeeded()
        entries?[normalized(title)] = Entry(data: data, savedAt: Date())
        if let entries, let encoded = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
        return data
    }

    private func loadIfNeeded() {
        guard entries == nil else { return }
        if let raw = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: raw) {
            entries = decoded.filter { Date().timeIntervalSince($0.value.savedAt) < ttl }
        } else { entries = [:] }
    }

    private func normalized(_ title: String) -> String {
        title.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    }
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
    @Environment(\.stockedMotion) private var motion
    // Cook Now (Direction B): optional session — when present, its serving
    // choice seeds the scaler and its confirmed swaps take precedence.
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    @State private var goPrep          = false
    @State private var derivedPrepTasks: [CookPrepTask] = []
    @State private var startCooking     = false
    @State private var internetData: InternetRecipeData? = nil
    @State private var isFetchingRecipe  = false
    @State private var showPortionEdit   = false
    @State private var adjustedServings  = 0   // 0 = use passed-in servings
    @State private var showCancelAlert   = false
    @State private var planningContext: CookLaterContext? = nil
    @State private var addedToGrocery: Set<String> = []   // #FB — per-ingredient "Added ✓" feedback
    @State private var repairedIngredients: [AIRecipe.Ingredient] = []
    @State private var aiFixingIngredients = false
    @State private var overviewSnapshot = RecipeOverviewSnapshot.empty
    @State private var inStockSubstituteByIngredient: [String: String] = [:]

    init(title: String, servings: Int, ingredients: [String] = [],
         steps: [String] = [], cookTime: String = "", prepTime: String = "") {
        self.title = title; self.servings = servings
        self.ingredients = ingredients; self.steps = steps
        self.cookTime = cookTime; self.prepTime = prepTime
    }

    // Use internet data when nothing is manually supplied
    // #FB3 — .stockedWrappable strips non-breaking/zero-width whitespace from
    // scraped text so long steps wrap instead of clipping at the right edge.
    private var displaySteps: [String] {
        if !steps.isEmpty { return steps.map(\.stockedWrappable) }
        if let net = internetData, !net.steps.isEmpty { return net.steps.map(\.stockedWrappable) }
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
        if !repairedIngredients.isEmpty { return repairedIngredients.map { $0.displayLine.stockedWrappable } }
        if !ingredients.isEmpty { return ingredients.map(\.stockedWrappable) }
        if let net = internetData, !net.ingredients.isEmpty { return net.ingredients.map(\.stockedWrappable) }
        return defaultIngredients(for: title)
    }
    private var ingredientRepairKey: String { "overview:\(title)" }
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
        if adjustedServings > 0 { return adjustedServings }
        // Cook Now session carries the serving choice made on the dashboard /
        // recommendation; user adjustments here still win via adjustedServings.
        if let cs = cookSession { return max(1, cs.servings) }
        return max(1, servings)
    }
    private var baseServings: Int { max(1, servings == 0 ? 4 : servings) }
    private var scaleFactor: Double { Double(effectiveServings) / Double(baseServings) }

    /// #16 — prepared off the UI actor together with ingredient stock matching.
    private var estimatedTimerMinutes: Int? { overviewSnapshot.estimatedTimerMinutes }

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

    // Cached, actor-isolated fetch. The screen never parses network JSON on the main actor.
    private func fetchInternetRecipeIfNeeded() {
        guard ingredients.isEmpty || steps.isEmpty, !isFetchingRecipe, internetData == nil else { return }
        isFetchingRecipe = true
        Task {
            let data = await InternetRecipeCache.shared.fetchIfNeeded(title: title)
            guard !Task.isCancelled else { return }
            internetData = data
            isFetchingRecipe = false
            await prepareOverviewSnapshot()
        }
    }

    private func prepareOverviewSnapshot() async {
        let prepared = await RecipeDetailSnapshotCache.shared.overviewSnapshot(
            title: title, ingredients: scaledIngredients, steps: displaySteps,
            inventory: session.guestStore.inventoryItems)
        guard !Task.isCancelled else { return }
        overviewSnapshot = prepared

        // Resolve inventory-backed substitutions once after the background snapshot.
        // Previously every missing row rescanned the database during each body update.
        var substitutes: [String: String] = [:]
        substitutes.reserveCapacity(prepared.missingItems.count)
        for line in prepared.missingItems {
            let options = session.guestStore.inStockSubstitutes(for: line)
            // A swap the user explicitly confirmed in Cook Now wins over the
            // database's first suggestion.
            if let cs = cookSession,
               let confirmed = options.first(where: { cs.isSubstitutionConfirmed(ingredient: line, substitute: $0) }) {
                substitutes[line] = confirmed
            } else if let first = options.first {
                substitutes[line] = first
            }
        }
        inStockSubstituteByIngredient = substitutes

        // Derive prep tasks once, off the render path (get-ahead verbs from the
        // instruction text; ingredient-level prep notes require structured
        // RecipeIngredient data which the string-based overview doesn't carry).
        derivedPrepTasks = CookNowPrepDeriver.tasks(for: prepRecipeSnapshot)
    }

    private var hasPrepTasks: Bool { !derivedPrepTasks.isEmpty }

    /// Synthetic recipe for the prep checklist, built from this overview's data.
    private var prepRecipeSnapshot: UserRecipe {
        UserRecipe(title: title,
                   ingredients: ingredients.map { RecipeIngredient(name: $0, amount: "") },
                   instructions: steps.isEmpty ? displaySteps : steps)
    }

    private func loadCachedIngredientRepair() async {
        guard repairedIngredients.isEmpty,
              let cached = await RecipeIngredientRepairCache.shared.load(for: ingredientRepairKey) else { return }
        repairedIngredients = cached
    }

    private func fixIngredientsWithAI() async {
        guard !aiFixingIngredients else { return }
        aiFixingIngredients = true
        defer { aiFixingIngredients = false }
        let raw = RecipeImportAI.composeRawText(
            title: title,
            description: "Repair and reconstruct this ingredient list. Keep quantities, units, and preparation notes. Remove punctuation-only or incomplete fragments.",
            ingredients: displayIngredients,
            steps: displaySteps)
        guard let ai = await RecipeImportAI.structure(rawText: raw), !ai.ingredients.isEmpty else {
            ToastCenter.shared.warning("Couldn't repair ingredients — try again later")
            return
        }
        let cleaned = ai.ingredients.filter {
            let name = $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.count > 1 && name.rangeOfCharacter(from: .letters) != nil
        }
        guard !cleaned.isEmpty else {
            ToastCenter.shared.warning("No usable ingredient fixes were returned")
            return
        }
        repairedIngredients = cleaned
        await RecipeIngredientRepairCache.shared.store(cleaned, for: ingredientRepairKey)
        await prepareOverviewSnapshot()
        HapticManager.success()
        ToastCenter.shared.success("Ingredients repaired and cached")
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
                        .scaledFont(24, weight: .bold, design: .serif)
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
                                    .scaledFont(11).foregroundStyle(Color.stockedGold)
                                Button {
                                    motion.animate(.selection, intent: .spatial) {
                                        adjustedServings = max(1, effectiveServings - 1)
                                    }
                                } label: {
                                    Image(systemName: "minus.circle")
                                        .scaledFont(15).foregroundStyle(Color.stockedGold)
                                }.buttonStyle(.plain)
                                Text("\(effectiveServings)")
                                    .scaledFont(13, weight: .bold, design: .serif)
                                    .foregroundStyle(session.themeTextColor)
                                    .frame(minWidth: 20)
                                    .contentTransition(.numericText())
                                    .stockedAnimation(.selection, intent: .spatial, value: effectiveServings)
                                Button {
                                    motion.animate(.selection, intent: .spatial) {
                                        adjustedServings = effectiveServings + 1
                                    }
                                } label: {
                                    Image(systemName: "plus.circle")
                                        .scaledFont(15).foregroundStyle(Color.stockedGold)
                                }.buttonStyle(.plain)
                            }
                            Text("servings")
                                .scaledFont(12)
                                .foregroundStyle(session.themeTextColor.opacity(0.5))
                                .fixedSize(horizontal: false, vertical: true)
                                .fixedSize()   // never wrap
                        }
                        metaBadge(icon: "clock.fill",     text: displayPrepTime + " prep")
                        metaBadge(icon: "flame.fill",     text: displayCookTime + " cook")
                        if let mins = estimatedTimerMinutes, mins > 0 {
                            metaBadge(icon: "timer", text: "~\(mins) min timers")
                        }
                      }
                      .stockedScrollTargetLayout()
                      .padding(.horizontal, 20)
                    }
                    .stockedHorizontalSnap()
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
                            .scaledFont(13).foregroundStyle(Color.stockedGold)
                        Text("Tips & Tricks")
                            .scaledFont(14, weight: .bold, design: .serif)
                            .foregroundStyle(Color.stockedGold)
                    }
                    Text("Season in layers as you cook, not just at the end. Taste frequently and adjust salt, acid (lemon/vinegar), and heat to balance the dish.")
                        .scaledFont(13)
                        .foregroundStyle(session.isDarkMode ? Color(white: 0.65) : Color.stockedCharcoal.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .background(Color.stockedGold.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                .padding(.horizontal, 20).padding(.bottom, 20)

                // ── Portion check fail-safe ──────────────────────────
                portionCheckSection

                // ── Prep first (Cook Now) — derived from real recipe data ──
                if hasPrepTasks {
                    Button { goPrep = true } label: {
                        Label("Prep First", systemImage: "list.bullet.clipboard")
                            .scaledFont(15, weight: .semibold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(Color.stockedGold.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                                .stroke(Color.stockedGold.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 24).padding(.bottom, 10)
                }

                // ── Start Cooking ─────────────────────────────────────
                Button { startCooking = true } label: {
                    Text("Start Cooking")
                        .scaledFont(18, weight: .semibold, design: .serif)
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 18)
                        .background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                }
                .padding(.horizontal, 24).padding(.bottom, 10)

                Button {
                    planningContext = .recipe(
                        title: title,
                        ingredients: scaledIngredients,
                        servings: effectiveServings,
                        imageURL: displayImageURL,
                        suggestedDay: 1
                    )
                } label: {
                    Label("Plan in Cook Later", systemImage: "calendar.badge.plus")
                        .scaledFont(15, weight: .semibold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(Color.stockedGold.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                        .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                            .stroke(Color.stockedGold.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 24).padding(.bottom, 12)

                Text("Ingredients will be deducted from inventory when you finish cooking.")
                    .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.4))
                    .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                    .padding(.horizontal, 28).padding(.bottom, 8)
            }
        }
        .navigationDestination(isPresented: $startCooking) {
            CookingFlashcardView(recipeTitle: title, ingredients: scaledIngredients, steps: displaySteps,
                                 baseServings: effectiveServings,
                                 sessionSubs: inStockSubstituteByIngredient)
        }
        .navigationDestination(isPresented: $goPrep) {
            PrepChecklistView(recipe: prepRecipeSnapshot)
        }
        .sheet(item: $planningContext) { context in
            NavigationStack {
                CookLaterWorkspaceView(context: context).environment(session)
            }
        }
        .sheet(isPresented: $showPortionEdit) {
            // #FB — pop-up lists the recipe's ingredients with live inventory editing;
            // the statuses on this screen update in real time as amounts change.
            RecipePortionsEditSheet(recipeTitle: title, ingredients: displayIngredients)
                .environment(session)
        }
        .onReceive(NotificationCenter.default.publisher(for: .stockedPopToRoot)) { _ in
            startCooking = false   // collapse cook flow on iPad (no .id rebuild there)
        }
        .task(id: "\(title)-\(effectiveServings)-\(internetData?.ingredients.count ?? -1)-\(session.guestStore.inventoryItems.count)") {
            await loadCachedIngredientRepair()
            await prepareOverviewSnapshot()
        }
    }

    @ViewBuilder private var ingredientsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    ingredientsHeading
                    Spacer(minLength: 12)
                    ingredientRepairButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    ingredientsHeading
                    ingredientRepairButton
                }
            }

            // Scale indicator
            if scaleFactor != 1.0 {
                Text(effectiveServings > baseServings ? "↑ Scaled up" : "↓ Scaled down")
                    .scaledFont(11, weight: .semibold)
                    .foregroundStyle(Color.stockedGold)
                    .padding(.bottom, 4)
            }
            ForEach(overviewSnapshot.rows) { row in
                let ing = row.line
                let rawIng = row.line
                let inStock = row.isInStock
                let addedKey = rawIng.lowercased()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 10) {
                        Circle().fill(inStock ? Color.stockedGreen : Color.stockedGold)
                            .frame(width: 7, height: 7)
                        Text(ing).scaledFont(14)
                            .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        if inStock {
                            Text("✓ In stock")
                                .scaledFont(11, weight: .semibold)
                                .foregroundStyle(Color.stockedGreen)
                                .fixedSize(horizontal: false, vertical: true)
                                .fixedSize()
                        } else {
                            // #FB — "Need to buy" is now an action: add it right here.
                            Button {
                                let name = RecipeIngredients.parse(rawIng).name
                                session.guestStore.addToGroceryIfMissing(
                                    name.isEmpty ? rawIng : name.capitalized,
                                    recommended: false, recipeSource: title)
                                motion.animate(.selection, intent: .opacity) {
                                    _ = addedToGrocery.insert(addedKey)
                                }
                                HapticManager.success()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: addedToGrocery.contains(addedKey)
                                          ? "checkmark.circle.fill" : "cart.badge.plus")
                                        .scaledFont(10)
                                    Text(addedToGrocery.contains(addedKey) ? "Added ✓" : "Add to Grocery List")
                                        .scaledFont(10.5, weight: .semibold)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .fixedSize()   // #FB3 — the pill keeps its shape; the ingredient wraps instead
                                .foregroundStyle(addedToGrocery.contains(addedKey) ? Color.stockedGreen : Color.stockedGold)
                                .padding(.horizontal, 8).padding(.vertical, 5)
                                .background((addedToGrocery.contains(addedKey) ? Color.stockedGreen : Color.stockedGold).opacity(0.12))
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(addedToGrocery.contains(addedKey))
                        }
                    }
                    // #9 — if not in stock, suggest a substitute the user actually has.
                    if !inStock {
                        if let sub = inStockSubstituteByIngredient[rawIng] {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.2.squarepath").scaledFont(9)
                                Text("Use \(sub) instead (you have it)")
                                    .scaledFont(10, weight: .medium)
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

    private var ingredientsHeading: some View {
        Text("Ingredients")
            .scaledFont(16, weight: .bold, design: .serif)
            .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)
            .fixedSize(horizontal: true, vertical: true)
    }

    @ViewBuilder private var ingredientRepairButton: some View {
        if RecipeImportAI.isAvailable {
            Button { Task { await fixIngredientsWithAI() } } label: {
                HStack(spacing: 4) {
                    if aiFixingIngredients { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "wand.and.stars").scaledFont(10) }
                    Text(aiFixingIngredients ? "Fixing…" : "Fix ingredients")
                        .scaledFont(11, weight: .semibold)
                        .fixedSize(horizontal: true, vertical: true)
                }
                .foregroundStyle(Color.stockedGold)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.stockedGold.opacity(0.12)).clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(aiFixingIngredients)
        }
    }

    @ViewBuilder private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recipe Steps")
                .scaledFont(16, weight: .bold, design: .serif)
                .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal)

            ForEach(Array(displaySteps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 12) {
                    ZStack {
                        Circle().fill(Color.stockedGold).frame(width: 26, height: 26)
                        Text("\(i + 1)")
                            .scaledFont(12, weight: .bold)
                            .foregroundStyle(session.themeTextColor)
                    }
                    .padding(.top, 1)
                    Text(step)
                        .scaledFont(14)
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
        // #FB — same smart matcher as the ingredient rows, so the two never disagree.
        let missingItems = overviewSnapshot.missingItems
        if !missingItems.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .scaledFont(13).foregroundStyle(.orange)
                    Text("Portions check")
                        .scaledFont(14, weight: .bold, design: .serif).foregroundStyle(session.themeTextColor)
                }
                Text("\(missingItems.count) item(s) appear to be out of stock or very low:")
                    .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                // #FB — list exactly which portions don't line up with the recipe.
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(missingItems.enumerated()), id: \.offset) { _, item in
                        HStack(spacing: 6) {
                            Circle().fill(Color.orange.opacity(0.7)).frame(width: 5, height: 5)
                            Text(item)
                                .scaledFont(12)
                                .foregroundStyle(session.themeTextColor.opacity(0.75))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.leading, 2)
                HStack(spacing: 10) {
                    Button { showPortionEdit = true } label: {
                        Text("Edit Inventory")
                            .scaledFont(13, weight: .semibold).foregroundStyle(Color.stockedWhite)
                            .padding(.horizontal, 16).padding(.vertical, 9)
                            .background(session.themeButtonColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                    }.buttonStyle(.plain)
                    // #FB — continue anyway is now a real button: it starts the recipe.
                    Button { startCooking = true } label: {
                        HStack(spacing: 3) {
                            Text("or continue anyway")
                            Image(systemName: "arrow.right").scaledFont(10, weight: .semibold)
                        }
                        .scaledFont(12, weight: .medium)
                        .foregroundStyle(Color.stockedGold)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain)
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
            Image(systemName: icon).scaledFont(11).foregroundStyle(Color.stockedGold)
            Text(text).scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.65))
                .fixedSize(horizontal: false, vertical: true).fixedSize()
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
    @Environment(\.stockedMotion) private var motion
    let recipeTitle:  String
    let ingredients:  [String]
    let steps:        [String]
    /// Servings the recipe/session was scaled to; carried in so the flashcard
    /// flow deducts inventory at the same portion the cook actually made.
    var baseServings: Int = 4
    @State private var expandedStep:        Int?    = 0
    @State private var completedSteps:      Set<Int> = []
    @State private var showResumePrompt:    Bool = false
    @State private var liveActivity = LiveActivityManager.shared   // #229 — observed for timer-failure banner
    @State private var sessionEnded = false       // #231 — once finished/stopped, don't let onAppear resurrect the pill
    @State private var liveActivityHint: String?  // #231 — proactive Lock Screen timer warning

    // ── Cook Now substitution guidance (#Direction B) ────────────────
    /// If this step mentions an ingredient the session swapped, remind the cook
    /// which swap is in play. Guidance only — the author's step text stands.
    private func substitutionHint(for step: String) -> String? {
        guard !sessionSubs.isEmpty else { return nil }
        let lower = step.lowercased()
        for (original, sub) in sessionSubs {
            // Match on the meaningful lead words of the original ingredient line.
            let key = original.lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count > 3 }
            if key.contains(where: { lower.contains($0) }) {
                return "Using \(sub.displayNormalized) instead of \(original.displayNormalized)"
            }
        }
        return nil
    }

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
    @State private var showFullScreen       = false   // #FB — full-screen flashcards + voice control
    // ── RL-001 / RL-002 — durable pause/resume/cancel ──────────────
    @State private var showLeaveOptions     = false   // 3-way leave dialog (pause / cancel / continue)
    @State private var showCancelConfirm    = false   // RL-002 explicit cancel confirmation
    @State private var didBootstrapRecord   = false   // one-time session-record setup per view life
    @Environment(\.dismiss) private var dismissView
    @Environment(\.scenePhase) private var scenePhase

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

    /// Cook Now: ingredient → in-stock substitute chosen for this session.
    /// Guidance-only — step text is NEVER rewritten (it stays the author's).
    var sessionSubs: [String: String] = [:]
    /// RL-001 — when set, this cook RESUMES a persisted session: completed
    /// steps, checked ingredients, and timers restore to the exact saved point
    /// (timers adjusted for elapsed wall-clock time).
    var resume: ActiveCookSessionSnapshot? = nil
    // Cook Now workspace: optional session enables the "While it cooks" hands-off
    // opportunity entry during a long cook.
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    @State private var showHandsOff = false

    /// Rough hands-off window for the current cook, from the chosen method's
    /// total-minus-active time, falling back to a sensible default.
    private var estimatedHandsOffMinutes: Int {
        if let mid = cookSession?.cookingMethodID, let m = CookingMethodCatalog.method(id: mid) {
            return max(5, m.totalMinutes - m.activeMinutes)
        }
        return 30
    }

    // ── RL-001 / RL-002 — durable session record ────────────────────
    // The cook's exact state (step, timers, subs, appliances) is mirrored into
    // ActiveCookSessionStore with immediate write-through, so force-close,
    // relaunch, backgrounding, and offline all preserve the session. Inventory
    // is NEVER touched here — deduction happens once, on explicit completion.

    private var sessionStore: ActiveCookSessionStore { .shared }

    /// Build the persistable snapshot of the cook exactly as it stands.
    private func currentSnapshot(from base: ActiveCookSessionSnapshot?) -> ActiveCookSessionSnapshot {
        var snap = base ?? ActiveCookSessionSnapshot(
            recipeTitle: recipeTitle, ingredients: ingredients, steps: steps, servings: baseServings)
        snap.recipeID = cookSession?.recipeID
        snap.recipeTitle = recipeTitle
        snap.ingredients = ingredients
        snap.steps = steps
        snap.servings = baseServings
        snap.currentStep = min(max(isSwipeMode ? currentCard : (expandedStep ?? currentCard), 0),
                               max(0, steps.count - 1))
        snap.completedSteps = Array(completedSteps).sorted()
        snap.checkedIngredientIndexes = Array(checkedIngredients).sorted()
        snap.substitutions = sessionSubs
        snap.selectedAppliances = Array(cookSession?.selectedEquipment ?? []).sorted()
        snap.selectedComponents = cookSession?.selectedSideTitles ?? []
        snap.timers = timerEngine.exportStates()
        snap.plannedMealID = cookSession?.plannedMealID
        return snap
    }

    /// Write-through capture — called on step change, ingredient check, timer
    /// change, and backgrounding. Only an ACTIVE record is updated: explicit
    /// pause/cancel/complete decisions are never silently overwritten.
    private func captureSessionSnapshot() {
        guard !sessionEnded,
              let live = sessionStore.current,
              live.status == .active,
              live.recipeTitle == recipeTitle else { return }
        sessionStore.save(currentSnapshot(from: live))
    }

    /// One-time record setup: adopt a resumed snapshot, silently pick up the
    /// same cook after a force-close (RL-001 edge case), or start fresh.
    private func bootstrapSessionRecord() {
        guard !didBootstrapRecord else { return }
        didBootstrapRecord = true
        QARecorder.shared.enteredScreen("Cooking Flashcards")
        timerEngine.recipeTitle = recipeTitle
        timerEngine.totalSteps  = steps.count
        timerEngine.onStateChange = { captureSessionSnapshot() }
        if let resume {
            restoreSessionState(from: resume)
            sessionStore.adoptResumed(currentSnapshot(from: resume))
        } else if let existing = sessionStore.resumable, existing.recipeTitle == recipeTitle {
            // Re-entered the same cook (relaunch, floating pill, back into the
            // flow) — continue it at the saved point instead of starting over.
            restoreSessionState(from: existing)
            sessionStore.adoptResumed(currentSnapshot(from: existing))
        } else {
            sessionStore.save(currentSnapshot(from: nil))
        }
    }

    /// Put the UI back at the exact saved point. Timers are rebuilt with
    /// wall-clock adjustment — one that would have finished while away shows
    /// as finished/ready (see StepTimerEngine.restore).
    private func restoreSessionState(from snap: ActiveCookSessionSnapshot) {
        completedSteps = Set(snap.completedSteps.filter { steps.indices.contains($0) })
        checkedIngredients = Set(snap.checkedIngredientIndexes.filter { ingredients.indices.contains($0) })
        let target = steps.indices.contains(snap.currentStep)
            ? snap.currentStep
            : (steps.indices.first { !completedSteps.contains($0) } ?? max(0, steps.count - 1))
        currentCard = target
        expandedStep = target
        timerEngine.restore(snap.timers)
    }

    /// True when leaving would lose meaningful progress (worth the dialog).
    private var hasMeaningfulProgress: Bool {
        !completedSteps.isEmpty || !checkedIngredients.isEmpty || !timerEngine.timers.isEmpty
    }

    /// RL-001 — back-chevron intercept: present the three explicit choices.
    private func handleLeaveAttempt() {
        if sessionEnded || finishCooking { dismissView(); return }
        guard hasMeaningfulProgress else {
            // Untouched cook — leave quietly, nothing worth resuming later.
            sessionStore.cancel()
            timerEngine.cancelAll()
            dismissView()
            return
        }
        showLeaveOptions = true
    }

    /// RL-001 — Pause Cooking: freeze everything exactly as it stands. Running
    /// timers keep their wall-clock fire dates AND their pending notifications,
    /// so a pot on the stove still alerts even if the device stays locked.
    private func pauseAndLeave() {
        sessionStore.pause(currentSnapshot(from: sessionStore.current))
        timerEngine.suspendKeepingNotifications()
        // Keep the floating "In Progress" pill alive as a second resume path.
        if session.activeCook?.title != recipeTitle {
            session.activeCook = .init(title: recipeTitle, ingredients: ingredients,
                                       steps: steps, servings: baseServings, startedAt: Date())
        }
        HapticManager.select()
        dismissView()
    }

    /// RL-002 — Cancel Meal: deliberate discard. Clears the record, timers,
    /// step progress, and temporary substitutions; no meal history, no streaks,
    /// no inventory deduction. A meal cooked from a plan STAYS planned.
    private func cancelMeal() {
        sessionEnded = true
        sessionStore.cancel()
        timerEngine.cancelAll()
        clearProgress()
        CookNowSession.clearPersisted()
        session.activeCook = nil
        HapticManager.select()
        dismissView()
        // Land back at the hub the cook started from — never deep in the flow
        // whose context was just discarded.
        NotificationCenter.default.post(name: .stockedPopToRoot, object: nil)
    }

    private var allDone: Bool { completedSteps.count == steps.count }
    private func markComplete(_ i: Int) {
        motion.animate(.standard, intent: .spatial) {
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
                        motion.animate(.standard, intent: .opacity) {
                            showCelebration = true
                        }
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
                if !forcedExpanded {
                    motion.animate(.standard, intent: .spatial) { checklistExpanded.toggle() }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "checklist")
                        .scaledFont(13).foregroundStyle(Color.stockedGold)
                    Text("Ingredients")
                        .scaledFont(13, weight: .semibold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Text("\(checkedIngredients.count)/\(ingredients.count) prepped")
                        .scaledFont(11)
                        .foregroundStyle(session.themeTextColor.opacity(0.45))
                    if !forcedExpanded {
                        Image(systemName: checklistExpanded ? "chevron.up" : "chevron.down")
                            .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.35))
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
                                motion.animate(.selection, intent: .spatial) {
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
                                    .scaledFont(18)
                                    .foregroundStyle(checkedIngredients.contains(idx)
                                                     ? Color.stockedGold : session.themeTextColor.opacity(0.3))
                                    Text(ing)
                                        .scaledFont(13)
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
                                        .scaledFont(9, weight: .bold)
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
                                .scaledFont(12)
                                .foregroundStyle(Color.orange)
                            Text(failure)
                                .scaledFont(11)
                                .foregroundStyle(session.themeTextColor.opacity(0.7))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(10)
                        .background(Color.orange.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                        .padding(.horizontal, 16).padding(.top, 8)
                    }

                    // Header
                    // #FB3 — long recipe titles wrap to two lines and scale slightly instead
                    // of mashing into the fullscreen/view-mode buttons and the progress ring.
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("How to Cook")
                                .scaledFont(14, weight: .semibold)
                                .foregroundStyle(session.themeTextColor.opacity(0.45))
                                .fixedSize(horizontal: false, vertical: true)
                            Text(recipeTitle)
                                .scaledFont(20, weight: .bold, design: .serif)
                                .foregroundStyle(session.themeTextColor)
                                .fixedSize(horizontal: false, vertical: true)

                                .multilineTextAlignment(.leading)
                        }
                        .layoutPriority(1)
                        Spacer(minLength: 10)
                        // #FB — full-screen flashcards (with voice control inside).
                        Button {
                            currentCard = steps.indices.first { !completedSteps.contains($0) } ?? max(0, steps.count - 1)
                            showFullScreen = true
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .scaledFont(15)
                                .foregroundStyle(session.themeTextColor.opacity(0.55))
                                .padding(8)
                                .background(session.isDarkMode ? Color.white.opacity(0.12) : Color.stockedWhite.opacity(0.35))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                        }.buttonStyle(.plain).padding(.trailing, 8)
                            .accessibilityLabel("Full screen cooking mode")
                        // View mode toggle
                        Button {
                            motion.animate(.selection, intent: .spatial) { isSwipeMode.toggle() }
                        } label: {
                            Image(systemName: isSwipeMode ? "list.bullet" : "rectangle.stack.fill")
                                .scaledFont(16)
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
                                .stockedAnimation(.standard, intent: .spatial, value: completedSteps.count)
                            Text("\(completedSteps.count)/\(steps.count)")
                                .scaledFont(11, weight: .bold)
                                .foregroundStyle(session.themeTextColor)
                        }
                        .frame(width: 52, height: 52)
                    }
                    .padding(.horizontal, 24).padding(.bottom, 16)

                    // Tip of the day banner
                    HStack(spacing: 10) {
                        Image(systemName: "lightbulb.fill")
                            .scaledFont(13).foregroundStyle(Color.stockedGold)
                        Text(tips[min(completedSteps.count, tips.count - 1)])
                            .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.7))
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
                                        .scaledFont(14, weight: .semibold, design: .serif)
                                        .foregroundStyle(Color.stockedWhite.opacity(0.6))
                                    Spacer()
                                    if completedSteps.contains(currentCard) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(Color.stockedGold)
                                    }
                                }.padding(.horizontal, 20)
                                Text(steps[currentCard])
                                    .scaledFont(16, design: .serif)
                                    .foregroundStyle(Color.stockedWhite)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, 24)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let hint = substitutionHint(for: steps[currentCard]) {
                                    Label(hint, systemImage: "arrow.triangle.swap")
                                        .scaledFont(12, weight: .semibold)
                                        .foregroundStyle(Color.stockedGold)
                                        .multilineTextAlignment(.center)
                                        .padding(.horizontal, 24)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                // Dot indicators
                                HStack(spacing: 6) {
                                    ForEach(steps.indices, id: \.self) { i in
                                        Circle()
                                            .fill(i == currentCard ? Color.stockedGold : Color.white.opacity(0.3))
                                            .frame(width: i == currentCard ? 9 : 6, height: i == currentCard ? 9 : 6)
                                            .stockedAnimation(.selection, intent: .spatial, value: currentCard)
                                    }
                                }
                            }
                        }
                        .offset(x: cardDragOffset.width)
                        .gesture(DragGesture()
                            .onChanged { cardDragOffset = $0.translation }
                            .onEnded { v in
                                let projectedX = v.predictedEndTranslation.width
                                let target = StockedVelocitySnapPolicy().targetIndex(
                                    currentIndex: currentCard,
                                    currentOffset: CGFloat(currentCard) * 200 - projectedX,
                                    itemExtent: 200,
                                    velocity: 0,
                                    itemCount: steps.count
                                )
                                motion.animate(.settle, intent: .spatial) {
                                    if target > currentCard {
                                        completedSteps.insert(currentCard)
                                    }
                                    currentCard = target
                                    cardDragOffset = .zero
                                }
                            }
                        )
                        .padding(.horizontal, 20)
                        // Swipe nav buttons
                        HStack(spacing: 20) {
                            Button {
                                motion.animate(.selection, intent: .spatial) { if currentCard > 0 { currentCard -= 1 } }
                            } label: {
                                Image(systemName: "chevron.left.circle.fill").scaledFont(32)
                                    .foregroundStyle(currentCard == 0 ? Color.stockedCharcoal.opacity(0.3) : Color.stockedGold)
                            }.disabled(currentCard == 0).buttonStyle(.plain)
                            Spacer()
                            Button {
                                motion.animate(.selection, intent: .spatial) {
                                    completedSteps.insert(currentCard)
                                    if currentCard < steps.count - 1 { currentCard += 1 }
                                }
                            } label: {
                                Image(systemName: "chevron.right.circle.fill").scaledFont(32)
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
                                        motion.animate(.selection, intent: .spatial) {
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
                                    .scaledFont(16, weight: .semibold, design: .serif)
                            }
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(allDone ? Color.stockedGold : Color.stockedCharcoal)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                            .stockedAnimation(.standard, intent: .spatial, value: allDone)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 24)

                        if !allDone {
                            Text("\(steps.count - completedSteps.count) step(s) remaining")
                                .scaledFont(12)
                                .foregroundStyle(session.themeTextColor.opacity(0.35))
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        // ── RL-001 — intercept the shell's back chevron so leaving an active
        //    cook always goes through the explicit pause/cancel/continue choice.
        //    Scoped to the shell only: pushed destinations (plating, hands-off)
        //    attach after this modifier, so their back buttons stay standard.
        .environment(\.stockedDismiss, { handleLeaveAttempt() })
        .onAppear {
            if !didBootstrapRecord {
                bootstrapSessionRecord()
            } else if !sessionEnded, let live = sessionStore.resumable, live.recipeTitle == recipeTitle {
                // Reappeared after a safety-net pause (tab switch away and
                // back): rebuild suspended timers and mark the record active.
                if timerEngine.timers.isEmpty && !live.timers.isEmpty { timerEngine.restore(live.timers) }
                sessionStore.adoptResumed(currentSnapshot(from: live))
            }
        }
        .onDisappear {
            // Safety net for any exit that bypassed the dialog (programmatic
            // pop, etc.): keep the cook as paused rather than losing it.
            if !sessionEnded && !finishCooking && !showHandsOff && !showFullScreen {
                captureSessionSnapshot()
                sessionStore.pauseCurrentIfActive()
                timerEngine.suspendKeepingNotifications()
            }
        }
        // Write-through capture on every meaningful change + on backgrounding.
        .onChange(of: completedSteps)     { _, _ in captureSessionSnapshot() }
        .onChange(of: currentCard)        { _, _ in captureSessionSnapshot() }
        .onChange(of: checkedIngredients) { _, _ in captureSessionSnapshot() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { captureSessionSnapshot() }
        }
        .confirmationDialog("Leave cooking?", isPresented: $showLeaveOptions, titleVisibility: .visible) {
            Button("Pause Cooking") { pauseAndLeave() }
            Button("Cancel Meal", role: .destructive) { showCancelConfirm = true }
            Button("Continue Cooking", role: .cancel) {}
        } message: {
            Text("Pausing saves your exact step and timers so you can pick up right where you left off. Nothing is deducted from inventory until you finish.")
        }
        .alert("Cancel this meal?", isPresented: $showCancelConfirm) {
            Button("Keep Cooking", role: .cancel) {}
            Button("Discard Progress", role: .destructive) { cancelMeal() }
        } message: {
            Text("Your step progress, timers, and temporary substitutions will be discarded, and this meal won't be recorded as cooked. Nothing is deducted from inventory. If it came from your plan, the planned meal stays.")
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
        .navigationDestination(isPresented: $showHandsOff) {
            if let cs = cookSession {
                HandsOffOpportunityView(remainingMinutes: estimatedHandsOffMinutes)
                    .environment(cs)
            }
        }
        .navigationDestination(isPresented: $finishCooking) {
            TimeToPlatView(recipeTitle: recipeTitle, ingredients: ingredients)
                .onAppear { CookNowSession.clearPersisted() }   // cook complete — session context served
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
            // #FB — full-screen flashcards with hands-free voice control. Finishing from
            // full screen marks everything complete and rolls straight into Finish Cooking.
                .fullScreenCover(isPresented: $showFullScreen) {
                    FullScreenCookView(
                        recipeTitle: recipeTitle,
                        steps: steps,
                        currentCard: $currentCard,
                        completedSteps: $completedSteps,
                        onFinish: {
                            clearProgress()
                            sessionEnded = true
                            session.activeCook = nil
                            finishCooking = true
                        }
                    )
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
                                    .scaledFont(13, weight: .bold)
                                    .foregroundStyle(Color.stockedWhite)
                            } else if let t = stepTimer, t.isRunning {
                                Text(t.displayString)
                                    .scaledFont(9, weight: .bold, design: .monospaced)
                                    .foregroundStyle(Color.stockedWhite)
                            } else {
                                Text("\(stepNumber)")
                                    .scaledFont(13, weight: .bold)
                                    .foregroundStyle(Color.stockedWhite)
                            }
                        }
                        .stockedAnimation(.standard, intent: .spatial, value: stepTimer?.isRunning)

                        Text(isExpanded ? "Step \(stepNumber)" : stepText)
                            .font(.stockedSystem(size: RecipeTextPrefs.shared.scaled(14), design: .serif))
                            .foregroundStyle(isCompleted ? session.themeTextColor.opacity(0.4) : session.themeTextColor)
                            .strikethrough(isCompleted)

                            .fixedSize(horizontal: false, vertical: false)

                        Spacer()

                        // Timer badge when detected but not started
                        if let secs = detectedSeconds, stepTimer == nil {
                            HStack(spacing: 3) {
                                Image(systemName: "timer").scaledFont(9)
                                Text(formatSecs(secs)).scaledFont(10, weight: .semibold)
                            }
                            .foregroundStyle(Color.stockedGold)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(Color.stockedGold.opacity(0.12)).clipShape(Capsule())
                        }
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.35))
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
                                .font(.stockedSystem(size: RecipeTextPrefs.shared.scaled(15), design: .serif))
                                .foregroundStyle(session.themeTextColor)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            // #6 — read this step aloud (tap again to stop).
                            Button { SpeechReader.shared.toggle(stepText) } label: {
                                Image(systemName: "speaker.wave.2.fill")
                                    .scaledFont(14)
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
                                            .scaledFont(12, weight: .semibold)
                                            .foregroundStyle(Color.stockedWhite)
                                            .padding(.horizontal, 14).padding(.vertical, 11)
                                            .background(Color.stockedGold).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                                    }.buttonStyle(.plain)
                                } else if t?.isFinished == true {
                                    Label("Done ✓", systemImage: "checkmark.circle.fill")
                                        .scaledFont(12, weight: .semibold)
                                        .foregroundStyle(Color.stockedGreen)
                                    Button { timerEngine?.resetTimer(stepIndex: stepIndex) } label: {
                                        Text("Reset").scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.5))
                                    }.buttonStyle(.plain)
                                } else {
                                    Text(t?.displayString ?? "")
                                        .scaledFont(20, weight: .bold, design: .monospaced)
                                        .foregroundStyle(Color.stockedGold)
                                    if t?.isRunning == true {
                                        Button { timerEngine?.pauseTimer(stepIndex: stepIndex) } label: {
                                            Image(systemName: "pause.fill")
                                                .scaledFont(13)
                                                .foregroundStyle(Color.stockedWhite)
                                                .padding(9)
                                                .background(Color.stockedCharcoal).clipShape(Circle())
                                        }.buttonStyle(.plain)
                                    } else {
                                        Button {
                                            timerEngine?.startTimer(stepIndex: stepIndex, stepText: stepText)
                                        } label: {
                                            Image(systemName: "play.fill")
                                                .scaledFont(13)
                                                .foregroundStyle(Color.stockedWhite)
                                                .padding(9)
                                                .background(Color.stockedGold).clipShape(Circle())
                                        }.buttonStyle(.plain)
                                    }
                                    Button { timerEngine?.resetTimer(stepIndex: stepIndex) } label: {
                                        Image(systemName: "arrow.counterclockwise")
                                            .scaledFont(12)
                                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                                    }.buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 14)
                        }

                        Button(action: onComplete) {
                            Label(isCompleted ? "Mark Incomplete" : "Mark Complete",
                                  systemImage: isCompleted ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                            .scaledFont(13, weight: .semibold)
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
            .stockedAnimation(.selection, intent: .spatial, value: stepTimer?.isRunning)
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
        @State private var showCamera       = false   // #FB — camera actually opens the camera now

        init(recipeTitle: String, ingredients: [String] = []) {
            self.recipeTitle = recipeTitle; self.ingredients = ingredients
        }

        var body: some View {
            StockedShell(showBack: true) {
                VStack(spacing: 0) {
                    Text("Time to Plate")
                        .scaledFont(30, weight: .bold, design: .serif)
                        .foregroundStyle(Color.stockedGold).padding(.bottom, 20)

                    ZStack {
                        if platePhoto != nil {
                            CachedLocalDataImage(
                                data: platePhoto,
                                maxDimension: 720,
                                height: 200,
                                clip: .roundedRectangle(cornerRadius: 16)
                            ) {
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(Color.stockedCharcoal.opacity(0.14))
                                    .frame(maxWidth: .infinity)
                                    .frame(height: 200)
                                    .overlay { ProgressView().tint(Color.stockedGold) }
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            // #FB — the whole tile (camera icon included) opens the camera.
                            Button {
                                if CameraCaptureView.isAvailable { showCamera = true }
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 16).fill(Color.stockedCharcoal.opacity(0.2))
                                        .frame(maxWidth: .infinity).frame(height: 160)
                                    VStack(spacing: 10) {
                                        Image(systemName: "camera.fill").scaledFont(32).foregroundStyle(Color.stockedGold)
                                        Text("Add a plate photo (optional)").scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.55))
                                    }
                                }
                                .contentShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24).padding(.bottom, 10)

                    // #FB — two clear paths: camera capture, or upload from the library.
                    HStack(spacing: 18) {
                        if CameraCaptureView.isAvailable {
                            Button { showCamera = true } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "camera.fill").scaledFont(11)
                                    Text(platePhoto == nil ? "Take Plate Photo" : "Retake Photo")
                                        .scaledFont(13, weight: .semibold)
                                }
                                .foregroundStyle(Color.stockedGold)
                            }.buttonStyle(.plain)
                        }
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            HStack(spacing: 5) {
                                Image(systemName: "photo.on.rectangle").scaledFont(11)
                                Text("Upload from Library")
                                    .scaledFont(13, weight: .semibold)
                            }
                            .foregroundStyle(Color.stockedGold)
                        }
                    }
                    .padding(.bottom, 20)
                    .onChange(of: selectedPhoto) { _, item in
                        Task {
                            if let data = try? await item?.loadTransferable(type: Data.self) {
                                await MainActor.run { platePhoto = data }
                            }
                        }
                    }

                    VStack(spacing: 14) {
                        Text("You're all done!")
                            .scaledFont(22, weight: .semibold, design: .serif).foregroundStyle(Color.stockedWhite)
                        Text("Ingredients deducted from your inventory.")
                            .scaledFont(14).foregroundStyle(Color.stockedWhite.opacity(0.75)).multilineTextAlignment(.center).padding(.horizontal, 20)
                        Button { advance = true } label: {
                            Text("Rate & Finish")
                                .scaledFont(18, weight: .regular, design: .serif).foregroundStyle(Color.stockedWhite)
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
                    onConfirmWeighted: { weighted in
                        // RL-001 — idempotent completion: the session's token is
                        // consumed exactly once (and survives relaunch), so
                        // repeated Finish taps, resume-after-complete, or a
                        // zombie plating screen can never deduct twice.
                        if ActiveCookSessionStore.shared.completeCurrentSession() {
                            session.guestStore.deductIngredients(weighted: weighted)
                        }
                        didDeduct = true
                    },
                    onSkip:    {
                        // Skipping the deduction still ENDS the session — it must
                        // never reappear as resumable. The deduction token stays
                        // unconsumed only because nothing was deducted.
                        ActiveCookSessionStore.shared.markCurrentCompleted()
                        didDeduct = true
                    }
                ).environment(session)
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureView { data in platePhoto = data }
                    .ignoresSafeArea()
            }
        }
    }

    // MARK: - Ingredient deduction adjustment sheet
    // #FB — portions are now editable: choose None / Half / All per ingredient and
    // the pantry deduction scales to match (Half deducts half the usual amount).
    struct IngredientDeductSheet: View {
        @Environment(AppSession.self) var session
        @Environment(\.dismiss) var dismiss
        @Environment(\.stockedMotion) private var motion
        let ingredients: [String]
        let onConfirmWeighted: ([(name: String, portion: Double)]) -> Void
        let onSkip:    () -> Void
        @State private var portions: [Double]   // 0 = none, 0.5 = half, 1 = all

        init(ingredients: [String],
             onConfirmWeighted: @escaping ([(name: String, portion: Double)]) -> Void,
             onSkip: @escaping () -> Void) {
            self.ingredients       = ingredients
            self.onConfirmWeighted = onConfirmWeighted
            self.onSkip            = onSkip
            _portions = State(initialValue: Array(repeating: 1.0, count: ingredients.count))
        }

        private func portionLabel(_ p: Double) -> String {
            p <= 0 ? "None" : (p < 1 ? "Half" : "All")
        }

        var body: some View {
            NavigationStack {
                ZStack {
                    session.themeBgColor.ignoresSafeArea()
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Confirm what you used")
                            .scaledFont(18, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 6)
                        Text("Tap the amount to adjust how much gets deducted — All, Half, or None.")
                            .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.55))
                            .padding(.horizontal, 24).padding(.bottom, 16)

                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(ingredients.indices, id: \.self) { i in
                                    HStack(spacing: 12) {
                                        Image(systemName: portions[i] > 0 ? "checkmark.circle.fill" : "circle")
                                            .scaledFont(20)
                                            .foregroundStyle(portions[i] > 0 ? Color.stockedGold : session.themeTextColor.opacity(0.3))
                                            .onTapGesture {
                                                motion.animate(.selection, intent: .spatial) {
                                                    portions[i] = portions[i] > 0 ? 0 : 1
                                                }
                                            }
                                        Text(ingredients[i])
                                            .scaledFont(14)
                                            .foregroundStyle(portions[i] > 0 ? session.themeTextColor : session.themeTextColor.opacity(0.4))
                                            .strikethrough(portions[i] <= 0)
                                            .layoutPriority(1)
                                        Spacer(minLength: 8)
                                        // Portion selector — cycles None → Half → All.
                                        Button {
                                            motion.animate(.selection, intent: .spatial) {
                                                if portions[i] <= 0 { portions[i] = 0.5 }
                                                else if portions[i] < 1 { portions[i] = 1 }
                                                else { portions[i] = 0 }
                                            }
                                        } label: {
                                            Text(portionLabel(portions[i]))
                                                .scaledFont(11.5, weight: .bold)
                                                .foregroundStyle(portions[i] > 0 ? Color.stockedGold : session.themeTextColor.opacity(0.4))
                                                .frame(width: 46)
                                                .padding(.vertical, 6)
                                                .background((portions[i] > 0 ? Color.stockedGold : session.themeTextColor).opacity(0.10))
                                                .clipShape(Capsule())
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("Amount used: \(portionLabel(portions[i])). Tap to change.")
                                    }
                                    .padding(.horizontal, 24).padding(.vertical, 12)
                                    .contentShape(Rectangle())
                                    if i < ingredients.count - 1 { Divider().padding(.leading, 60) }
                                }
                            }
                            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .padding(.horizontal, 20)
                        }

                        VStack(spacing: 10) {
                            Button {
                                let weighted = ingredients.indices.compactMap { i -> (name: String, portion: Double)? in
                                    portions[i] > 0 ? (ingredients[i], portions[i]) : nil
                                }
                                onConfirmWeighted(weighted); dismiss()
                            } label: {
                                Text("Deduct from Pantry")
                                    .scaledFont(16, weight: .semibold, design: .serif)
                                    .foregroundStyle(Color.stockedWhite)
                                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                                    .background(Color.stockedGold).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                            }.buttonStyle(.plain)

                            Button { onSkip(); dismiss() } label: {
                                Text("Skip — don't deduct")
                                    .scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.45))
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
        @Environment(\.stockedMotion) private var motion
        @State private var rating      = 0            // #FB — starts empty until the user chooses
        @State private var thumbUp: Bool? = nil       // #FB — no pre-filled thumb
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
                        .scaledFont(26, weight: .bold, design: .serif)
                        .foregroundStyle(session.isDarkMode ? Color.stockedWhite : Color.stockedCharcoal).padding(.bottom, 6)
                    Text(recipeTitle).scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.5)).padding(.bottom, 20)

                    HStack(spacing: 10) {
                        ForEach(1...5, id: \.self) { star in
                            Image(systemName: star <= rating ? "star.fill" : "star")
                                .scaledFont(36).foregroundStyle(Color.stockedGold)
                                .onTapGesture {
                                    motion.animate(.selection, intent: .spatial) { rating = star }
                                }
                        }
                    }.padding(.bottom, 20)

                    HStack(spacing: 32) {
                        Button {
                            motion.animate(.selection, intent: .spatial) { thumbUp = true }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: thumbUp == true ? "hand.thumbsup.fill" : "hand.thumbsup")
                                    .scaledFont(36).foregroundStyle(thumbUp == true ? Color.stockedGold : Color.stockedCharcoal.opacity(0.3))
                                Text("Would make again").scaledFont(10).foregroundStyle(session.themeTextColor.opacity(0.4))
                            }
                        }.buttonStyle(.plain)
                        Button {
                            motion.animate(.selection, intent: .spatial) { thumbUp = false }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: thumbUp == false ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                                    .scaledFont(36).foregroundStyle(thumbUp == false ? .red.opacity(0.7) : session.themeTextColor.opacity(0.2))
                                Text("Not for me").scaledFont(10).foregroundStyle(session.themeTextColor.opacity(0.4))
                            }
                        }.buttonStyle(.plain)
                    }.padding(.bottom, 28)

                    VStack(spacing: 0) {
                        Text("Any food left over?")
                            .scaledFont(20, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor).padding(.bottom, 14)
                        HStack(spacing: 12) {
                            leftoverButton(label: "Yes — Fridge", icon: "refrigerator.fill",
                                           selected: hasLeftover == true && leftoverZone == "Fridge", color: Color.stockedGreen) {
                                motion.animate(.selection, intent: .spatial) {
                                    hasLeftover = true
                                    leftoverZone = "Fridge"
                                }
                            }
                            leftoverButton(label: "Freeze It", icon: "snowflake",
                                           selected: leftoverZone == "Freezer", color: Color.stockedInfo) {
                                motion.animate(.selection, intent: .spatial) {
                                    hasLeftover = true
                                    leftoverZone = "Freezer"
                                }
                            }
                            leftoverButton(label: "No Leftovers", icon: "xmark.circle.fill",
                                           selected: hasLeftover == false, color: Color.stockedCharcoal.opacity(0.4)) {
                                motion.animate(.selection, intent: .spatial) {
                                    hasLeftover = false
                                    leftoverZone = ""
                                }
                            }
                        }.padding(.bottom, 12)

                        if hasLeftover == true {
                            // #FB — storage guideline so the leftover gets stored safely.
                            HStack(alignment: .top, spacing: 7) {
                                Image(systemName: "info.circle.fill")
                                    .scaledFont(11).foregroundStyle(Color.stockedInfo)
                                Text(leftoverZone == "Freezer"
                                     ? "Storage guideline: freeze within 2 hours of cooking. Best quality within 2–3 months. Label with today's date."
                                     : "Storage guideline: refrigerate within 2 hours of cooking. Eat within 3–4 days. Reheat to 165°F.")
                                .scaledFont(11)
                                .foregroundStyle(session.themeTextColor.opacity(0.6))
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.stockedInfo.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                            .padding(.bottom, 10)

                            TextField("Leftover name (e.g. \(recipeTitle) Leftovers)", text: $leftoverName)
                                .scaledFont(14).foregroundStyle(session.themeTextColor)
                                .padding(14).background(session.isDarkMode ? Color.white.opacity(0.12) : Color.stockedWhite.opacity(0.35)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                                .padding(.bottom, 16)
                        }
                    }
                    .padding(18).background(session.themeCardColor).clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20).padding(.bottom, 16)

                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .scaledFont(14).foregroundStyle(session.themeTextColor).lineLimit(2...)
                        .padding(14).background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .padding(.horizontal, 20).padding(.bottom, 20)

                    Button { finishMeal() } label: {
                        Text("Finish & Save Meal")
                            .scaledFont(17, weight: .semibold, design: .serif).foregroundStyle(Color.stockedWhite)
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
                        Image(systemName: icon).scaledFont(18).foregroundStyle(selected ? .white : color)
                    }
                    Text(label).scaledFont(10, weight: .semibold).foregroundStyle(selected ? color : session.themeTextColor.opacity(0.6))
                        .multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity)
            }.buttonStyle(.plain)
        }

        private func finishMeal() {
            // RL-001 — one meal-history record per cook session. The token is
            // consumed exactly once (persisted), so resume, relaunch, or a second
            // "Finish & Save Meal" tap can't double-count streaks, achievements,
            // past meals, or leftovers.
            let cookRecord = ActiveCookSessionStore.shared
            guard cookRecord.recordMealForCurrentSession() else {
                cookRecord.clearFinished()
                if let goHome { goHome() } else { dismiss() }
                return
            }
            let dateStr = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
            var meal = LocalPastMeal(title: recipeTitle, date: dateStr)
            // #FB — rating/thumb start empty; if untouched, infer a neutral record.
            meal.rating = rating > 0 ? rating : 0
            meal.thumbUp = thumbUp ?? (rating >= 3)
            // Rating recorded to session: session.guestStore.cookingProfile is updated elsewhere
            meal.platePhotoData = platePhotoData; meal.notes = notes
            meal.recipeId = session.guestStore.markRecipeCooked(title: recipeTitle)   // #5 — bump cook count + link for ratings
            session.guestStore.markPlannedMealCooked(title: recipeTitle)              // audit fix — flip the planned meal's isCooked
            session.activeCook = nil                                                  // #228 — no longer in progress
            session.guestStore.pastMeals.append(meal)
            session.recordCookToday()   // Streak tracking

            // Apple Health — when the user opted in, log this meal's estimated per-serving
            // nutrition (energy, protein, carbs, fat). Silently skipped when disabled,
            // unauthorized, or the recipe carries no nutrition facts.
            if let recipeId = meal.recipeId,
               let cooked = session.guestStore.userRecipes.first(where: { $0.id == recipeId }) {
                HealthKitManager.shared.logCookedMeal(
                    title: cooked.title,
                    nutrition: HealthKitManager.totals(for: cooked),
                    servings: cooked.servings
                )
            }

            if hasLeftover == true {
                let name = leftoverName.trimmingCharacters(in: .whitespaces).isEmpty ? "\(recipeTitle) Leftovers" : leftoverName
                let zone = leftoverZone.isEmpty ? "Fridge" : leftoverZone
                var item = LocalInventoryItem(name: name, level: 0.75, zone: zone)
                item.isLeftover = true; item.leftoverMeal = recipeTitle
                item.expirationDate = Calendar.current.date(byAdding: .day, value: zone == "Freezer" ? 90 : 4, to: Date())
                session.guestStore.addInventoryItem(item)
            }
            // RL-001 — the session is fully served: drop its record so it can
            // never reappear as resumable (tokens stay consumed in the ledger).
            cookRecord.clearFinished()
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
            // #FB — was passing only missingIngredients, which showed an (often empty)
            // ingredient list. Pass the FULL ingredient lines plus the generated steps
            // and cook time so the surprise recipe reads like a real recipe.
            RecipeOverviewView(
                title:       recipe.title,
                servings:    recipe.servings,
                ingredients: recipe.ingredients.map { line in
                    line.amount.isEmpty ? line.name : "\(line.amount) \(line.name)"
                },
                steps:       recipe.steps,
                cookTime:    recipe.cookTime
            )
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
                            .scaledFont(16).foregroundStyle(Color.stockedGold)
                        Text("Substitutes for \(ingredientName.capitalized)")
                            .scaledFont(18, weight: .bold, design: .serif)
                            .foregroundStyle(session.themeTextColor)
                    }
                    .padding(.bottom, 20)

                    if let subs = entry?.substitutions, !subs.isEmpty {
                        ScrollView(showsIndicators: false) {
                            VStack(spacing: 12) {
                                ForEach(subs) { sub in
                                    HStack(alignment: .top, spacing: 14) {
                                        Image(systemName: "arrow.right")
                                            .scaledFont(13)
                                            .foregroundStyle(Color.stockedGold)
                                            .frame(width: 18, height: 20)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(sub.substitute)
                                                .scaledFont(14, weight: .semibold, design: .serif)
                                                .foregroundStyle(session.themeTextColor)
                                            if !sub.notes.isEmpty {
                                                Text(sub.notes)
                                                    .scaledFont(12)
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
                                                        .scaledFont(12)
                                                        .foregroundStyle(Color.stockedGold)
                                                    Text("In pantry · \(item.zone)")
                                                        .scaledFont(11, weight: .semibold)
                                                        .foregroundStyle(Color.stockedGold)
                                                    Spacer()
                                                    // Fill level pill
                                                    Text("\(Int(item.level * 100))%")
                                                        .scaledFont(10, weight: .bold)
                                                        .foregroundStyle(item.level > 0.5 ? .white : Color.stockedGold)
                                                        .padding(.horizontal, 7).padding(.vertical, 2)
                                                        .background(item.level > 0.5 ? Color.stockedGold : Color.stockedGold.opacity(0.2))
                                                        .clipShape(Capsule())
                                                }
                                            } else {
                                                Label("Not in pantry", systemImage: "xmark.circle")
                                                    .scaledFont(11)
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
                            .scaledFont(14)
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 28).padding(.top, 40)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    #Preview { RecipeOverviewView(title: "Garlic Chicken", servings: 2, ingredients: ["Chicken","Garlic","Olive Oil","Herbs"]) }
}
