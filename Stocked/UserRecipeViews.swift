// UserRecipeViews.swift — UserRecipeCard, UserRecipeDetailView, RecipeSubstitutionsSection, RecipeKitchenTipsSection.
// Split out of ReadyToCookView.swift (Build 189, code-health refactor #1). No logic changes.
import SwiftUI
import PhotosUI

// MARK: - User Recipe Card (with internet image)
struct UserRecipeCard: View {
    @Environment(AppSession.self) var session
    let recipe: UserRecipe
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                RecipeHeroImage(
                    imageData: recipe.imageData,
                    imageURL: recipe.imageURL,
                    recipeName: recipe.title,
                    height: 130
                )
                    .frame(height: 130).clipped()
                // Tip overlay
                if recipe.imageData == nil {
                    VStack {
                        Spacer()
                        HStack {
                            Spacer()
                            Image(systemName: "camera.fill").font(.system(size: 10))
                                .foregroundStyle(Color.stockedWhite.opacity(0.7))
                                .padding(6)
                                .background(Color.black.opacity(0.4))
                                .clipShape(Circle())
                                .padding(6)
                        }
                    }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(recipe.title).font(.system(size: 13, weight: .semibold, design: .serif))
                    .foregroundStyle(session.themeTextColor).lineLimit(1)
                HStack(spacing: 6) {
                    if !recipe.cookTime.isEmpty {
                        Text(recipe.cookTime).font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                    if !recipe.difficulty.isEmpty {
                        Text("·").foregroundStyle(session.themeTextColor.opacity(0.3))
                        Text(recipe.difficulty).font(.system(size: 10)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 12)
            .background(Color.stockedBg.opacity(0.5))
        }
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .overlay {
            RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                .stroke(session.themeContrastAccent.opacity(0.34), lineWidth: 1.25)
        }
        .shadow(color: .black.opacity(0.07), radius: 4, y: 2)
    }
}

// MARK: - User Recipe Detail View
struct UserRecipeDetailView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @State var recipe: UserRecipe
    @State private var showSubstitutions      = false
    @State private var substitutionScrollTarget: String? = nil
    @State private var scaledServings: Int
    @State private var showGroceryPushAlert   = false
    @State private var groceryPushCount       = 0
    @State private var showNotesEdit          = false
    @State private var notesText              = ""
    @State private var showRenameAlert        = false
    @State private var renameText             = ""
    @State private var showDeleteConfirm      = false
    @State private var planningContext: CookLaterContext? = nil
    // #9 live cooking — per-recipe step timers (notification + Live Activity backed).
    @State private var timerEngine            = StepTimerEngine()
    // AI instruction cleanup — sends the recipe through the Worker's recipe branch
    // (same one imports use) and replaces the steps with the corrected set.
    @State private var aiFixing               = false
    @State private var aiFixingIngredients    = false
    @State private var detailMetrics          = UserRecipeDetailMetrics.empty
    @State private var substitutionIngredientIDs: Set<UUID> = []
    @State private var ingredientsExpanded = false
    @State private var instructionsExpanded = false

    // ── Cook Now integration (Direction B) ────────────────────────
    // Present only when a CookNowSession is in the environment (the user
    // arrived through the Cook flow). The vault/browse path renders exactly
    // as before because cookSession is nil there.
    @Environment(CookNowSession.self) private var cookSession: CookNowSession?
    @State private var cookClassification: ClassifiedRecipe? = nil
    @State private var showKitchenCheck = false
    @State private var showSubReview = false

    // Steps as shown: trimmed, with blank entries dropped so imported or hand-entered
    // recipes never render empty numbered rows (e.g. a bare "2" with no text).
    private var displaySteps: [String] {
        recipe.instructions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    init(recipe: UserRecipe) {
        self._recipe         = State(initialValue: recipe)
        self._scaledServings = State(initialValue: recipe.servings)
        self._notesText      = State(initialValue: recipe.notes)
    }

    // Scale factor vs original servings
    private var scaleFactor: Double {
        guard recipe.servings > 0 else { return 1 }
        return Double(scaledServings) / Double(recipe.servings)
    }

    // Cook history line
    private var cookHistoryLabel: String? {
        guard recipe.cookCount > 0 else { return nil }
        let dateStr = recipe.lastCooked.map { StockedFormatters.mediumDate.string(from: $0) } ?? ""
        return recipe.cookCount == 1
            ? "Made once\(dateStr.isEmpty ? "" : " · \(dateStr)")"
            : "Made \(recipe.cookCount)× · Last \(dateStr)"
    }

    private var averageRating: Double? { detailMetrics.averageRating }

    // Nutrition is precomputed once per original serving. The live stepper only applies a
    // cheap multiplier, so changing servings no longer reparses every ingredient.
    private var nutritionSummary: (cal: Int, protein: Double, carbs: Double, fat: Double)? {
        guard let calories = detailMetrics.calories else { return nil }
        return (
            cal: Int(calories * scaleFactor),
            protein: (detailMetrics.protein * scaleFactor).rounded(toPlaces: 1),
            carbs: (detailMetrics.carbs * scaleFactor).rounded(toPlaces: 1),
            fat: (detailMetrics.fat * scaleFactor).rounded(toPlaces: 1)
        )
    }

    var body: some View {
        detailContent
            .onAppear {
                session.recordRecipeView(recipe.id)   // #240 — Recently Viewed
                // Cook Now: the session's serving choice carries into this
                // screen's existing scaling — set once, user can still adjust.
                if let cs = cookSession { scaledServings = max(1, cs.servings) }
                recomputeCookClassification()
                // #9 — context for step timers surfaced on the Lock Screen / Dynamic Island.
                timerEngine.recipeTitle = recipe.title
                timerEngine.totalSteps  = displaySteps.count
                substitutionIngredientIDs = Set(recipe.ingredients.compactMap {
                    StockedDatabase.shared.hasSubstitution(for: $0.name) ? $0.id : nil
                })
            }
            .task(id: "\(recipe.id.uuidString)-\(recipe.updatedAt)-\(session.guestStore.pastMeals.count)-\(session.guestStore.priceHistory.count)") {
                detailMetrics = await UserRecipeMetricsCache.shared.metrics(
                    recipe: recipe, pastMeals: session.guestStore.pastMeals,
                    priceHistory: session.guestStore.priceHistory)
            }
            .navigationTitle(recipe.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { recipeOptionsToolbar }
            .onChange(of: session.guestStore.inventoryRevision) { _, _ in recomputeCookClassification() }
            .navigationDestination(isPresented: $showKitchenCheck) {
                KitchenCheckView(recipe: recipe)
            }
            .sheet(isPresented: $showSubReview, onDismiss: { recomputeCookClassification() }) {
                SubstitutionReviewSheet(recipe: recipe)
                    .environment(session)
            }
            .sheet(item: $planningContext) { context in
                NavigationStack {
                    CookLaterWorkspaceView(context: context).environment(session)
                }
            }
            .alert("Rename Recipe", isPresented: $showRenameAlert) {
                TextField("Recipe name", text: $renameText)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    recipe.title = trimmed
                    session.guestStore.renameUserRecipe(id: recipe.id, name: trimmed)
                }
            } message: {
                Text("This updates the name everywhere in the app.")
            }
            .confirmationDialog("Delete this recipe?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("Delete Recipe", role: .destructive) {
                    session.guestStore.deleteUserRecipe(id: recipe.id)
                    dismiss()
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("\"\(recipe.title)\" will be removed from your collection. This can't be undone.")
            }
    }

    @ToolbarContentBuilder
    private var recipeOptionsToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button { renameText = recipe.title; showRenameAlert = true } label: {
                    Label("Rename", systemImage: "pencil")
                }
                if RecipeImportAI.isAvailable {
                    Button { Task { await fixInstructionsWithAI() } } label: {
                        Label("Clean Up with AI", systemImage: "wand.and.stars")
                    }
                    .disabled(aiFixing)
                }
                Button(role: .destructive) { showDeleteConfirm = true } label: {
                    Label("Delete Recipe", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.system(size: 17, weight: .semibold))
            }
            .accessibilityLabel("Recipe options")
        }
    }

    // ── AI instruction cleanup ─────────────────────────────────────────
    // Reuses the import pipeline: compose the recipe as raw text, send it through the
    // Worker's recipe branch, and adopt the corrected steps. Only the instructions are
    // replaced — title, ingredients, notes, photos, and history are untouched. Any
    // failure (offline, unusable response) leaves the recipe exactly as it was.
    private func fixInstructionsWithAI() async {
        guard !aiFixing else { return }
        aiFixing = true
        defer { aiFixing = false }
        let raw = RecipeImportAI.composeRawText(
            title: recipe.title,
            description: recipe.description,
            ingredients: recipe.ingredients.map { ing in
                ing.amount.isEmpty ? ing.name : "\(ing.amount) \(ing.name)"
            },
            steps: displaySteps)
        guard let ai = await RecipeImportAI.structure(rawText: raw), ai.isUsable else {
            ToastCenter.shared.warning("Couldn't reach the recipe assistant — try again later")
            return
        }
        let cleaned = ai.steps
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            ToastCenter.shared.success("No fixes suggested — steps look good")
            return
        }
        var updated = recipe
        updated.instructions = cleaned
        session.guestStore.updateUserRecipe(updated)
        recipe = updated
        timerEngine.totalSteps = cleaned.count
        HapticManager.light()
        ToastCenter.shared.success("Instructions cleaned up")
    }

    private func fixIngredientsWithAI() async {
        guard !aiFixingIngredients else { return }
        aiFixingIngredients = true
        defer { aiFixingIngredients = false }
        let raw = RecipeImportAI.composeRawText(
            title: recipe.title,
            description: "Repair the ingredient list. Preserve exact quantities, units, preparation notes, and optional ingredients. Remove broken fragments.",
            ingredients: recipe.ingredients.map {
                [$0.amount, $0.name, $0.prep ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
            },
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
        let old = recipe.ingredients
        var rebuilt: [RecipeIngredient] = []
        for (index, fixed) in cleaned.enumerated() {
            let canonical = IngredientSynonyms.canonical(fixed.name)
            let matched = old.first { IngredientSynonyms.canonical($0.name) == canonical }
                ?? (index < old.count ? old[index] : nil)
            var ingredient = RecipeIngredient(name: fixed.name, amount: fixed.amount)
            ingredient.id = matched?.id ?? UUID()
            ingredient.brand = matched?.brand
            ingredient.nutrition = matched?.nutrition
            ingredient.isOptional = matched?.isOptional ?? false
            ingredient.notes = matched?.notes
            ingredient.quantity = fixed.quantity
            ingredient.unit = fixed.unit
            ingredient.prep = fixed.prep
            rebuilt.append(ingredient)
        }
        var updated = recipe
        updated.ingredients = rebuilt
        updated.updatedAt = Date().timeIntervalSince1970 * 1000
        session.guestStore.updateUserRecipe(updated)
        recipe = updated
        substitutionIngredientIDs = Set(rebuilt.compactMap {
            StockedDatabase.shared.hasSubstitution(for: $0.name) ? $0.id : nil
        })
        detailMetrics = await UserRecipeMetricsCache.shared.metrics(
            recipe: updated, pastMeals: session.guestStore.pastMeals,
            priceHistory: session.guestStore.priceHistory)
        HapticManager.success()
        ToastCenter.shared.success("Ingredients repaired and saved")
    }

    // ── Cook Now readiness header ─────────────────────────────────

    private func recomputeCookClassification() {
        guard cookSession != nil else { return }
        cookClassification = CookNowCompute.classify(recipe: recipe,
                                                     store: session.guestStore,
                                                     session: cookSession)
    }

    /// Grouped, honest readiness up top: "9 exact · 1 substitution · 1 missing",
    /// a state-aware primary CTA, and the missing items consolidated in one
    /// place with a single grocery action.
    @ViewBuilder
    private func cookNowReadinessSection(_ c: ClassifiedRecipe) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: c.readiness.isReadyNow ? "checkmark.circle.fill" : "circle.dashed")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(c.readiness.isReadyNow ? Color.stockedGreen : Color.stockedGold)
                Text(c.groupedSummary.isEmpty ? c.readiness.statusLabel : c.groupedSummary)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                Spacer()
            }

            if c.missingCount > 0 {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Missing: \(c.missingNames.map { $0.displayNormalized }.joined(separator: ", "))")
                        .font(.system(size: 12.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        for name in c.missingNames { session.guestStore.addGroceryItem(name: name) }
                        HapticManager.light()
                    } label: {
                        Label("Add Missing to Grocery", systemImage: "cart.badge.plus")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.stockedGold)
                    }
                    .buttonStyle(.plain)
                }
            }

            // State-aware primary action for the Cook Now path.
            Button {
                HapticManager.light()
                if c.reviewCount > 0 { showSubReview = true }
                else { showKitchenCheck = true }
            } label: {
                Text(c.reviewCount > 0
                     ? "Review \(c.reviewCount) Substitution\(c.reviewCount == 1 ? "" : "s")"
                     : "Check Ingredients")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(session.isDarkMode ? Color.stockedGold : Color.stockedCharcoal)
                    .frame(maxWidth: .infinity).padding(.vertical, 10)
                    .background((session.isDarkMode ? Color.stockedGold : Color.stockedCharcoal).opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    private var detailContent: some View {
        ZStack {
            session.themeBgColor.ignoresSafeArea()
            ScrollViewReader { scrollProxy in
              ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {

                    // Hero
                    ZStack(alignment: .bottom) {
                        RecipeHeroImage(
                            imageData: recipe.imageData,
                            imageURL: recipe.imageURL,
                            recipeName: recipe.title,
                            height: 220
                        )
                            .frame(maxWidth: .infinity).frame(height: 220).clipped().clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        if recipe.imageData == nil {
                            HStack {
                                Spacer()
                                Label("Tap to add your own photo", systemImage: "camera.fill")
                                    .font(.system(size: 10)).foregroundStyle(Color.stockedWhite)
                                    .padding(.horizontal, 10).padding(.vertical, 5)
                                    .background(Color.black.opacity(0.45)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg)).padding(10)
                            }
                        }
                    }.padding(.horizontal, 20)

                    // Cook Now readiness header — only when arriving via Cook Now
                    if cookSession != nil, let c = cookClassification {
                        cookNowReadinessSection(c)
                            .padding(.horizontal, 20)
                    }

                    // Title + meta
                    VStack(alignment: .leading, spacing: 8) {
                        Text(recipe.title)
                            .font(.system(size: 24, weight: .bold, design: .serif))
                            .dynamicTypeSize(.xSmall ... .accessibility2)
                            .foregroundStyle(session.themeTextColor)

                        // Cook history
                        if let history = cookHistoryLabel {
                            HStack(spacing: 6) {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                                Text(history)
                                    .font(.system(size: 12))
                                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                            }
                        }

                        // #6 — estimated cost from the user's OWN paid prices; honest about
                        // coverage rather than pretending an incomplete number is complete.
                        let costEst = detailMetrics.cost
                        if costEst.isUseful {
                            HStack(spacing: 6) {
                                Image(systemName: "dollarsign.circle")
                                    .font(.system(size: 11)).foregroundStyle(Color.stockedGreen)
                                Text("~\(costEst.display) est. · priced \(costEst.pricedCount) of \(costEst.totalCount) ingredients from your receipts")
                                    .font(.system(size: 12))
                                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                            }
                        }

                        // #5 — average rating earned across past cooks
                        if let avg = averageRating {
                            HStack(spacing: 4) {
                                ForEach(1...5, id: \.self) { i in
                                    Image(systemName: Double(i) <= avg ? "star.fill"
                                          : (Double(i) - 0.5 <= avg ? "star.leadinghalf.filled" : "star"))
                                        .font(.system(size: 11)).foregroundStyle(Color.stockedGold)
                                }
                                Text(String(format: "%.1f", avg))
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor.opacity(0.7))
                                Text("(\(detailMetrics.ratingCount))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(session.themeTextColor.opacity(0.4))
                            }
                        }

                        HStack(spacing: 16) {
                            // Use estimated cook time from steps if not set
                            let displayTime: String = {
                                if !recipe.cookTime.isEmpty { return recipe.cookTime }
                                return CookTimeEstimator.estimate(from: recipe.instructions) ?? "–"
                            }()
                            metaBadge(icon: "clock",  text: displayTime)
                            metaBadge(icon: "flame",  text: recipe.difficulty)
                        }
                        // Servings on its own row so it doesn't crowd the time/difficulty badges
                        metaBadge(icon: "person.2", text: "\(recipe.servings) servings")
                    }.padding(.horizontal, 24)

                    // ── Serving scaler ────────────────────────────────────
                    HStack(spacing: 12) {
                        Text("Scale servings")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.7))
                        Spacer()
                        HStack(spacing: 0) {
                            Button { if scaledServings > 1 { scaledServings -= 1 } } label: {
                                Image(systemName: "minus").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor)
                                    .frame(width: 36, height: 36).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            Text("\(scaledServings)")
                                .font(.system(size: 18, weight: .bold, design: .serif))
                                .foregroundStyle(Color.stockedGold).frame(minWidth: 32)
                            Button { scaledServings += 1 } label: {
                                Image(systemName: "plus").font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(session.themeTextColor)
                                    .frame(width: 36, height: 36).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                        }
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))

                        if scaledServings != recipe.servings {
                            Button {
                                var updated = recipe
                                updated.servings = scaledServings
                                session.guestStore.updateUserRecipe(updated)
                                recipe = updated
                            } label: {
                                Text("Save")
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(Color.stockedWhite)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Color.stockedGold).clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(14)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    .padding(.horizontal, 24)

                    // ── Nutrition summary ─────────────────────────────────
                    if let n = nutritionSummary {
                        let dri = DRITable.adult
                        VStack(spacing: 0) {
                            HStack(spacing: 0) {
                                nutriStat(label: "Cal",
                                          value: "\(n.cal)",
                                          dv: "\(DRITable.percent(Double(n.cal), of: Double(dri.calories)))%")
                                Divider().frame(height: 40)
                                nutriStat(label: "Protein",
                                          value: "\(n.protein)g",
                                          dv: "\(DRITable.percent(n.protein, of: dri.protein))%")
                                Divider().frame(height: 40)
                                nutriStat(label: "Carbs",
                                          value: "\(n.carbs)g",
                                          dv: "\(DRITable.percent(n.carbs, of: dri.totalCarbs))%")
                                Divider().frame(height: 40)
                                nutriStat(label: "Fat",
                                          value: "\(n.fat)g",
                                          dv: "\(DRITable.percent(n.fat, of: dri.totalFat))%")
                            }
                            HStack {
                                Spacer()
                                Text("% Daily Value per serving · 2000 cal diet")
                                    .font(.system(size: 9))
                                    .foregroundStyle(session.themeTextColor.opacity(0.35))
                                    .padding(.horizontal, 12).padding(.bottom, 6)
                            }
                        }
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .padding(.horizontal, 24)
                    }

                    // ── Ingredients ───────────────────────────────────────
                    if !recipe.ingredients.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { ingredientsExpanded.toggle() }
                                } label: {
                                    Label("Ingredients", systemImage: ingredientsExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 16, weight: .bold, design: .serif))
                                        .foregroundStyle(session.themeTextColor)
                                }
                                .buttonStyle(.plain)
                                .a11yButton(ingredientsExpanded ? "Collapse ingredients" : "Expand ingredients")
                                Spacer()
                                if RecipeImportAI.isAvailable {
                                    Button { Task { await fixIngredientsWithAI() } } label: {
                                        HStack(spacing: 4) {
                                            if aiFixingIngredients { ProgressView().controlSize(.mini) }
                                            else { Image(systemName: "wand.and.stars").font(.system(size: 10)) }
                                            Text(aiFixingIngredients ? "Fixing…" : "Fix ingredients")
                                                .font(.system(size: 10.5, weight: .semibold))
                                        }
                                        .foregroundStyle(Color.stockedGold)
                                        .padding(.horizontal, 7).padding(.vertical, 4)
                                        .background(Color.stockedGold.opacity(0.12)).clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(aiFixingIngredients)
                                    .a11yButton("Fix ingredients with AI")
                                }
                                // Linked grocery push — consolidates duplicates across recipes
                                Button {
                                    groceryPushCount = session.guestStore.addRecipeIngredientsToGrocery(
                                        recipe.ingredients, recipeName: recipe.title, scale: scaleFactor)
                                    showGroceryPushAlert = true
                                } label: {
                                    Label("Add Missing to List", systemImage: "cart.badge.plus")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Color.stockedGold)
                                }
                                .buttonStyle(.plain)
                                .alert("Added to Grocery List", isPresented: $showGroceryPushAlert) {
                                    Button("OK", role: .cancel) {}
                                } message: {
                                    Text(groceryPushCount == 0
                                         ? "You already have everything for this recipe."
                                         : "\(groceryPushCount) missing ingredient\(groceryPushCount == 1 ? "" : "s") added under \"\(recipe.title)\".")
                                }
                            }
                            if ingredientsExpanded {
                            ForEach(recipe.ingredients) { ing in
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack(spacing: 10) {
                                        Circle()
                                            .fill(ing.isOptional ? Color.stockedGold.opacity(0.4) : Color.stockedGold)
                                            .frame(width: 6, height: 6)
                                        // Scale amount if numeric
                                        Text(scaledAmount(ing.amount) + " " + ing.name)
                                            .font(.system(size: RecipeTextPrefs.shared.scaled(14))).foregroundStyle(session.themeTextColor)
                                        if ing.isOptional {
                                            Text("(optional)").font(.system(size: 11))
                                                .foregroundStyle(session.themeTextColor.opacity(0.4))
                                        }
                                        Spacer()
                                        if substitutionIngredientIDs.contains(ing.id) {
                                            Button {
                                                withAnimation(.spring(response: 0.25)) {
                                                    substitutionScrollTarget = ing.name
                                                    showSubstitutions = true
                                                }
                                                Task { @MainActor in
                                                    // Let the disclosure lay out before moving its anchor
                                                    // into view; otherwise the scroll targets its collapsed
                                                    // position and the tap appears to do nothing.
                                                    await Task.yield()
                                                    withAnimation(.easeInOut(duration: 0.3)) {
                                                        scrollProxy.scrollTo("recipe-substitutions", anchor: .top)
                                                    }
                                                }
                                            } label: {
                                                HStack(spacing: 3) {
                                                    Text("Sub ↓").font(.system(size: 9, weight: .semibold))
                                                    Image(systemName: "arrow.down.circle").font(.system(size: 9))
                                                }
                                                .foregroundStyle(Color.stockedGold)
                                                .padding(.horizontal, 6).padding(.vertical, 3)
                                                .background(Color.stockedGold.opacity(0.12)).clipShape(Capsule())
                                            }.buttonStyle(.plain)
                                        }
                                    }
                                    if let brand = ing.brand {
                                        Text(brand).font(.system(size: 11)).foregroundStyle(Color.stockedGold).padding(.leading, 16)
                                    }
                                }
                            }
                            }
                        }
                        .padding(16)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)).padding(.horizontal, 24)
                    }

                    // ── Instructions ──────────────────────────────────────
                    if !displaySteps.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Button {
                                    withAnimation(.easeInOut(duration: 0.2)) { instructionsExpanded.toggle() }
                                } label: {
                                    Label("Instructions", systemImage: instructionsExpanded ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 16, weight: .bold, design: .serif))
                                        .foregroundStyle(session.themeTextColor)
                                }
                                .buttonStyle(.plain)
                                .a11yButton(instructionsExpanded ? "Collapse instructions" : "Expand instructions")
                                Spacer()
                                // AI cleanup — reorders, de-dupes, and rewrites garbled or
                                // missing steps via the Worker; falls back silently offline.
                                if RecipeImportAI.isAvailable {
                                    Button {
                                        Task { await fixInstructionsWithAI() }
                                    } label: {
                                        HStack(spacing: 4) {
                                            if aiFixing {
                                                ProgressView().controlSize(.mini)
                                            } else {
                                                Image(systemName: "wand.and.stars").font(.system(size: 11))
                                            }
                                            Text(aiFixing ? "Fixing…" : "Fix with AI")
                                                .font(.system(size: 12, weight: .semibold))
                                        }
                                        .foregroundStyle(Color.stockedGold)
                                        .padding(.horizontal, 9).padding(.vertical, 4)
                                        .background(Color.stockedGold.opacity(0.12))
                                        .clipShape(Capsule())
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(aiFixing)
                                    .a11yButton("Fix instructions with AI")
                                }
                            }
                            // #9 live cooking — steps mentioning a duration get a tappable
                            // timer chip (notification + Live Activity backed).
                            if instructionsExpanded {
                                ForEach(Array(displaySteps.enumerated()), id: \.offset) { i, step in
                                    TimedStepRow(stepNumber: i + 1, stepText: step, timerEngine: timerEngine)
                                }
                            }
                        }
                        .padding(16)
                        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)).padding(.horizontal, 24)
                    }

                    // ── Notes ─────────────────────────────────────────────
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("Notes")
                                .font(.system(size: 16, weight: .bold, design: .serif))
                                .foregroundStyle(session.themeTextColor)
                            Spacer()
                            Button(showNotesEdit ? "Done" : "Edit") {
                                if showNotesEdit {
                                    var updated = recipe
                                    updated.notes = notesText
                                    session.guestStore.updateUserRecipe(updated)
                                    recipe = updated
                                }
                                showNotesEdit.toggle()
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.stockedGold)
                            .buttonStyle(.plain)
                        }
                        if showNotesEdit {
                            TextEditor(text: $notesText)
                                .font(.system(size: 14))
                                .foregroundStyle(session.themeTextColor)
                                .frame(minHeight: 80)
                                .padding(10)
                                .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                        } else {
                            Text(recipe.notes.isEmpty ? "Tap Edit to add notes — modifications, tips, what you'd change next time." : recipe.notes)
                                .font(.system(size: 14))
                                .foregroundStyle(recipe.notes.isEmpty
                                    ? session.themeTextColor.opacity(0.35)
                                    : session.themeTextColor)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)).padding(.horizontal, 24)

                    // Substitutions
                    RecipeSubstitutionsSection(
                        ingredientNames: recipe.ingredients.map { $0.name },
                        isExpanded: $showSubstitutions,
                        scrollTarget: $substitutionScrollTarget
                    )
                    .id("recipe-substitutions")

                    // Kitchen Tips
                    RecipeKitchenTipsSection()

                    Button {
                        planningContext = .recipe(
                            title: recipe.title,
                            ingredients: recipe.ingredients.map {
                                [$0.amount, $0.name].filter { !$0.isEmpty }.joined(separator: " ")
                            },
                            servings: scaledServings,
                            imageURL: recipe.imageURL,
                            suggestedDay: 1
                        )
                    } label: {
                        Label("Plan in Cook Later", systemImage: "calendar.badge.plus")
                            .font(.system(size: 15, weight: .semibold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(Color.stockedGold.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                            .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                                .stroke(Color.stockedGold.opacity(0.4), lineWidth: 1))
                    }
                    .buttonStyle(.plain).padding(.horizontal, 24)

                    // Start Cooking
                    NavigationLink(destination: RecipeOverviewView(
                        title: recipe.title, servings: scaledServings,
                        ingredients: recipe.ingredientNames)
                    ) {
                        Text("Start Cooking")
                            .font(.system(size: 17, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 16)
                            .background(Color.stockedCharcoal).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .buttonStyle(.plain).padding(.horizontal, 24).padding(.bottom, 40)
                    .simultaneousGesture(TapGesture().onEnded {
                        // Log cook
                        var updated = recipe
                        updated.cookCount += 1
                        updated.lastCooked = Date()
                        session.guestStore.updateUserRecipe(updated)
                        recipe = updated
                        // Log past meal
                        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
                        let meal = LocalPastMeal(title: recipe.title, date: df.string(from: Date()), recipeId: recipe.id)
                        session.guestStore.pastMeals.append(meal)
                    })
                }
                .padding(.top, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
              }
            }
        }
    }

    // MARK: - Helpers

    private func scaledAmount(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard scaleFactor != 1.0 else { return trimmed }
        // Pure number (e.g. "2", "0.5")
        if let num = Double(trimmed) {
            return smartFraction(num * scaleFactor)
        }
        // Quantity string with possible unit (e.g. "1 cup", "2 tbsp")
        let parsed = ParsedQuantity.parse(trimmed)
        if parsed.amount > 0 {
            let scaledAmt = parsed.amount * scaleFactor
            let unitStr   = parsed.canonicalUnit.isEmpty ? "" : " \(parsed.canonicalUnit)"
            return smartFraction(scaledAmt) + unitStr
        }
        return trimmed
    }

    private func metaBadge(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Color.stockedGold)
            Text(text).font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.65))
        }
    }

    private func nutriStat(label: String, value: String, dv: String = "") -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(session.themeTextColor.opacity(0.45))
            if !dv.isEmpty {
                Text(dv)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(session.accentColor.opacity(0.7))
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

// MARK: - Recipe Substitutions Section (shared, used in all recipe detail views)
struct RecipeSubstitutionsSection: View {
    @Environment(AppSession.self) var session
    let ingredientNames: [String]
    @Binding var isExpanded: Bool
    @Binding var scrollTarget: String?

    @State private var entries: [(name: String, entry: SubstitutionEntry)] = []

    private var ingredientKey: String {
        ingredientNames.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "|")
    }

    var body: some View {
        Group {
            if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                // Section header — tappable to expand/collapse
                Button {
                    withAnimation(.spring(response: 0.28)) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 13)).foregroundStyle(Color.stockedGold)
                        Text("Substitutions")
                            .font(.system(size: 16, weight: .bold, design: .serif))
                            .foregroundStyle(session.themeTextColor)
                        Text("\(entries.count)")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.stockedGold)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.stockedGold.opacity(0.14))
                            .clipShape(Capsule())
                        Spacer()
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.4))
                    }
                    .padding(.horizontal, 16).padding(.vertical, 14)
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)

                if isExpanded {
                    VStack(spacing: 12) {
                        ForEach(entries, id: \.name) { item in
                            let isHighlighted = scrollTarget?.lowercased() == item.name.lowercased()
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(isHighlighted ? Color.stockedGold : Color.stockedGold.opacity(0.5))
                                        .frame(width: 5, height: 5)
                                    Text(item.entry.displayName)
                                        .font(.system(size: 13, weight: .bold, design: .serif))
                                        .foregroundStyle(isHighlighted ? Color.stockedGold : session.themeTextColor)
                                }
                                ForEach(item.entry.substitutions) { sub in
                                    HStack(alignment: .top, spacing: 10) {
                                        Text("→")
                                            .font(.system(size: 12))
                                            .foregroundStyle(Color.stockedGold)
                                            .frame(width: 14)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(sub.substitute)
                                                .font(.system(size: 13, weight: .semibold))
                                                .foregroundStyle(session.themeTextColor)
                                            if !sub.notes.isEmpty {
                                                Text(sub.notes)
                                                    .font(.system(size: 11))
                                                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                                                    .lineSpacing(2)
                                            }
                                        }
                                    }
                                    .padding(.leading, 14)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 8)
                            .background(isHighlighted
                                ? Color.stockedGold.opacity(0.1)
                                : Color.stockedGold.opacity(0.04))
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                            .animation(.easeInOut(duration: 0.3), value: isHighlighted)

                            if item.name != entries.last?.name {
                                Divider().padding(.horizontal, 8)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .padding(.horizontal, 24)
            // When scrollTarget changes, ensure expanded
            .onChange(of: scrollTarget) { _, newTarget in
                if newTarget != nil, !isExpanded {
                    withAnimation(.spring(response: 0.28)) { isExpanded = true }
                }
            }
            }
        }
        .task(id: ingredientKey) {
            // Resolve once per ingredient list instead of scanning the substitution database
            // every time the recipe detail body or an accordion animation updates.
            entries = ingredientNames.compactMap { name in
                StockedDatabase.shared.substitutions(for: name).map { (name, $0) }
            }
        }
    }
}

// MARK: - Kitchen Tips snippet for recipe detail
struct RecipeKitchenTipsSection: View {
    @Environment(AppSession.self) var session
    @State private var tips: [CookingTip] = []
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.spring(response: 0.28)) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "lightbulb.fill")
                        .font(.system(size: 13)).foregroundStyle(Color.stockedGold)
                    Text("Kitchen Tips")
                        .font(.system(size: 16, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 12)).foregroundStyle(session.themeTextColor.opacity(0.4))
                }
                .padding(.horizontal, 16).padding(.vertical, 14)
                .contentShape(Rectangle())
            }.buttonStyle(.plain)

            if expanded {
                VStack(spacing: 10) {
                    ForEach(tips) { tip in
                        HStack(alignment: .top, spacing: 10) {
                            Text(tip.emoji).font(.system(size: 16)).frame(width: 22)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(tip.title)
                                    .font(.system(size: 13, weight: .semibold, design: .serif))
                                    .foregroundStyle(session.themeTextColor)
                                Text(tip.body)
                                    .font(.system(size: 12))
                                    .foregroundStyle(session.themeTextColor.opacity(0.55))
                                    .lineSpacing(2)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.3))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .padding(.horizontal, 24)
        .onAppear {
            if tips.isEmpty { tips = CookingTipsDatabase.shared.randomTips(3) }
        }
    }
}
