// OnboardingQuiz.swift — adaptive, profile-backed onboarding questionnaire.
import SwiftUI

struct OnboardingQuiz: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var quizDismiss
    @Environment(\.stockedMotion) private var motion

    // ── State ──────────────────────────────────────────────────────
    @State private var step:          Int    = 0
    // Welcome + six decisions that immediately change recipe safety or ranking.
    // Scheduling and equipment remain editable later; they no longer delay first value.
    let totalSteps = 7

    @State private var householdSize  = 2
    @State private var cookingGoal    = ""
    @State private var dietaryStyle   = ""
    @State private var allergens:     [String] = []
    @State private var cuisinePrefs:  [String] = []
    @State private var skillLevel     = ""
    @State private var weeklyMeals    = 5
    @State private var mealPrepDay    = ""
    @State private var budgetLevel    = ""
    @State private var cookingEquipment: [String] = []
    @State private var showChefPrompt  = true   // prompt on first quiz step

    @State private var avatarEmoji      = "👨‍🍳"
    @State private var showAvatarPicker = false
    @State private var dragOffset:    CGFloat = 0
    @State private var screenWidth:    CGFloat = 390  // updated in onAppear via UIWindowScene
    // Full width with 16pt margins each side, capped on iPad so the card doesn't stretch.
    private var cardWidth: CGFloat { min(screenWidth - 32, 600) }
    @State private var cardOpacity:   Double  = 1
    @State private var didHydrateProfile = false

    private let avatarGrid: [[String]] = [
        ["👨‍🍳","👨🏻‍🍳","👨🏼‍🍳","👨🏽‍🍳","👨🏾‍🍳","👨🏿‍🍳"],
        ["👩‍🍳","👩🏻‍🍳","👩🏼‍🍳","👩🏽‍🍳","👩🏾‍🍳","👩🏿‍🍳"],
        ["🧑‍🍳","🧑🏻‍🍳","🧑🏼‍🍳","🧑🏽‍🍳","🧑🏾‍🍳","🧑🏿‍🍳"],
    ]

    // ── Layout ─────────────────────────────────────────────────────

    // Prompt card anchored below the chef icon via overlayPreferenceValue
    private func chefPromptCard(iconFrame: CGRect) -> some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.68)
                .ignoresSafeArea()
                .onTapGesture {
                    motion.animate(.selection, intent: .opacity) { showChefPrompt = false }
                }

            VStack(spacing: 6) {
                Image(systemName: "arrowtriangle.up.fill")
                    .scaledFont(13)
                    .foregroundStyle(Color.stockedGold)

                VStack(spacing: 10) {
                    Text("Tap your chef icon")
                        .scaledFont(17, weight: .bold, design: .serif)
                        .foregroundStyle(Color.white)
                    Text("Choose an avatar that represents\nyour cooking personality.")
                        .scaledFont(13)
                        .foregroundStyle(Color.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                    Button("Got it") {
                        motion.animate(.selection, intent: .opacity) { showChefPrompt = false }
                    }
                        .scaledFont(14, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                        .padding(.horizontal, 32).padding(.vertical, 11)
                        .background(Color.stockedGold)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .buttonStyle(.plain)
                }
                .padding(.horizontal, 28).padding(.vertical, 20)
                .background(Color.stockedCharcoal)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.3), radius: 14, y: 6)
                .padding(.horizontal, 36)
            }
            .offset(y: iconFrame.maxY + 8)
        }
        .zIndex(100)
        .transition(.opacity)
    }

    var body: some View {
        ZStack {
            // Scrim
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture {} // absorb taps

            VStack(spacing: 20) {
                // Card
                ZStack {
                    // Card background
                    RoundedRectangle(cornerRadius: 28)
                        .fill(session.themeBgColor)
                        .shadow(color: .black.opacity(0.3), radius: 30, y: 12)

                    VStack(spacing: 0) {
                        // Top bar — step dots + X
                        HStack {
                            // Page dots
                            HStack(spacing: 5) {
                                ForEach(0..<totalSteps, id: \.self) { i in
                                    Capsule()
                                        .fill(i == step ? Color.stockedGold : Color.stockedCharcoal.opacity(0.18))
                                        .frame(width: i == step ? 18 : 6, height: 6)
                                        .stockedAnimation(.selection, intent: .spatial, value: step)
                                }
                            }
                            Spacer()
                            // Skip / Close
                            if step < totalSteps - 1 {
                                Button {
                                    completeOnboarding()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .scaledFont(22)
                                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 18)
                        .padding(.bottom, 4)

                        // Every question remains reachable with large Dynamic Type and in
                        // compact windows. The card itself stays put while its content scrolls.
                        ScrollView {
                            stepContent
                                .padding(.top, 20)
                                .padding(.bottom, 24)
                                .frame(maxWidth: .infinity)
                        }
                        .scrollIndicators(.hidden)
                    }
                }
                .frame(width: cardWidth)
                .frame(maxHeight: .infinity)            // #4 — fill the vertical space
                .offset(x: dragOffset)
                .opacity(cardOpacity)
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            // Track the finger directly; animating every drag update adds
                            // latency and a rubber-band lag on slower devices.
                            dragOffset = v.translation.width * 0.4
                        }
                        .onEnded { v in
                            let projected = v.predictedEndTranslation.width
                            let target = StockedVelocitySnapPolicy().targetIndex(
                                currentIndex: step,
                                currentOffset: CGFloat(step) * 200 - projected,
                                itemExtent: 200,
                                velocity: 0,
                                itemCount: totalSteps
                            )
                            if target > step {
                                goForward()
                            } else if target < step {
                                goBack()
                            } else {
                                motion.animate(.settle, intent: .spatial) { dragOffset = 0 }
                            }
                        }
                )

                // Back button below card (visible after step 0)
                if step > 0 && step < totalSteps {
                    Button {
                        goBack()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").scaledFont(12, weight: .semibold)
                            Text("Back").scaledFont(14, weight: .semibold, design: .serif)
                        }
                        .foregroundStyle(Color.stockedWhite.opacity(0.7))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.vertical, 44)
        }
        .keyboardDoneToolbar()
        .dismissKeyboardOnTap()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            screenWidth = max(320, width)
        }
        .onAppear { hydrateFromPersistedProfileIfNeeded() }

        .overlayPreferenceValue(ChefIconAnchorKey.self) { anchor in
            if step == 0 && showChefPrompt, let anchor = anchor {
                // GeometryReader here is the canonical way to RESOLVE an anchor preference
                // (geo[anchor]) so the prompt can sit directly below the chef icon's real
                // frame. This is NOT layout-sizing of main content — it's an overlay shown
                // only on step 0 — so it carries none of the GPU-fence risks the
                // "no GeometryReader for layout" rule guards against. There is no
                // anchor-resolution API that avoids a GeometryProxy.
                GeometryReader { geo in
                    chefPromptCard(iconFrame: geo[anchor])
                }
                .ignoresSafeArea()
            }
        }
    }

    // ── Navigation ─────────────────────────────────────────────────
    private func goForward() {
        guard step < totalSteps - 1 else { return }
        motion.animate(.navigation, intent: .spatial) {
            dragOffset = -screenWidth
            cardOpacity = 0
        }
        Task {
            if motion.permitsSpatialMotion {
                try? await Task.sleep(nanoseconds: 180000000)
            }
            dragOffset = screenWidth
            step += 1
            motion.animate(.navigation, intent: .spatial) {
                dragOffset = 0; cardOpacity = 1
            }
        }
    }

    private func goBack() {
        guard step > 0 else { return }
        motion.animate(.navigation, intent: .spatial) {
            dragOffset = screenWidth
            cardOpacity = 0
        }
        Task {
            if motion.permitsSpatialMotion {
                try? await Task.sleep(nanoseconds: 180000000)
            }
            dragOffset = -screenWidth
            step -= 1
            motion.animate(.navigation, intent: .spatial) {
                dragOffset = 0; cardOpacity = 1
            }
        }
    }

    private func advance() { goForward() }

    // ── Step content router ─────────────────────────────────────────
    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:  welcomeCard
        case 1:  householdCard
        case 2:  goalCard
        case 3:  dietCard
        case 4:  allergenCard
        case 5:  cuisineCard
        case 6:  skillCard
        default: finishCard   // budget/kids step removed
        }
    }

    // ── Card shared components ──────────────────────────────────────
    private func cardHeader(emoji: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(emoji).scaledFont(44).padding(.bottom, 2)
            Text(title)
                .scaledFont(22, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .scaledFont(14)
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    private func continueButton(label: String = "Continue →", enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .scaledFont(16, weight: .semibold, design: .serif)
                .foregroundStyle(enabled ? Color.stockedWhite : Color.stockedWhite.opacity(0.4))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    RoundedRectangle(cornerRadius: 50)
                        .fill(enabled ? Color.stockedCharcoal : Color.stockedCharcoal.opacity(0.35))
                )
        }
        .disabled(!enabled)
        .buttonStyle(.plain)
        .padding(.horizontal, 22)
    }

    private func chip(_ label: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.stockedSystem(size: 13, weight: selected ? .bold : .medium, design: .serif))
                .foregroundStyle(selected ? Color.stockedCharcoal : session.themeTextColor)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                        .fill(selected ? Color.stockedGold : Color.stockedWhite.opacity(0.4))
                )
        }.buttonStyle(.plain)
    }

    // ── Step 0: Welcome ─────────────────────────────────────────────
    private var welcomeCard: some View {
        VStack(spacing: 20) {
            // Tappable avatar
            Button {
                motion.animate(.selection, intent: .spatial) {
                    showAvatarPicker.toggle()
                }
            } label: {
                ZStack {
                    if showAvatarPicker {
                        Circle().fill(Color.stockedGold.opacity(0.15)).frame(width: 90, height: 90)
                    }
                    Text(avatarEmoji)
                        .font(.stockedSystem(size: showAvatarPicker ? 70 : 60))
                        .scaleEffect(showAvatarPicker ? 1.1 : 1)
                }
                .anchorPreference(key: ChefIconAnchorKey.self, value: .bounds) { $0 }
            }.buttonStyle(.plain)

            if showAvatarPicker {
                VStack(spacing: 6) {
                    ForEach(avatarGrid, id: \.self) { row in
                        HStack(spacing: 6) {
                            ForEach(row, id: \.self) { e in
                                Button {
                                    motion.animate(.selection, intent: .spatial) {
                                        avatarEmoji = e; showAvatarPicker = false
                                    }
                                } label: {
                                    Text(e).scaledFont(26)
                                        .padding(5)
                                        .background(avatarEmoji == e ? Color.stockedGold.opacity(0.2) : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(10)
                .background(session.themeCardColor)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 22)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }

            if !showAvatarPicker {
                VStack(spacing: 8) {
                    Text("Let's Stock your kitchen")
                        .scaledFont(22, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                        .multilineTextAlignment(.center)
                    Text("A few quick questions and we'll personalise everything — recipes, reminders, grocery lists — around *your* life.")
                        .scaledFont(14)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 22)
                .transition(.opacity)
            }

            if !showAvatarPicker {
                continueButton(label: "Let's go") { advance() }
            }
        }
    }

    // ── Step 1: Household ───────────────────────────────────────────
    private var householdCard: some View {
        VStack(spacing: 16) {
            cardHeader(emoji: "🏠", title: "How many people\nare you feeding?",
                       subtitle: "Including yourself. We'll scale portions automatically.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach([1,2,3,4,5,6], id: \.self) { n in
                    chip(n == 1 ? "Just me 🙋" : n == 6 ? "6+ 👨‍👩‍👧‍👦" : "\(n) people",
                         selected: householdSize == n) { householdSize = n }
                }
            }.padding(.horizontal, 22)
            continueButton { advance() }
        }
    }

    // ── Step 2: Goal ────────────────────────────────────────────────
    private var goalCard: some View {
        let goals = [("🥦","Eat Healthier"),("⏱","Cook Faster"),
                     ("🌍","Explore Cuisines"),("♻️","Reduce Waste"),
                     ("😌","Stress Less"),("🤯","Decision Fatigue")]
        return VStack(spacing: 16) {
            cardHeader(emoji: "🎯", title: "What's your main\ncooking goal?",
                       subtitle: "Pick the one that matters most right now.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(goals, id: \.1) { emoji, label in
                    chip("\(emoji)  \(label)", selected: cookingGoal == label) { cookingGoal = label }
                }
            }.padding(.horizontal, 22)
            continueButton(enabled: !cookingGoal.isEmpty) { advance() }
        }
    }

    // ── Step 3: Diet ────────────────────────────────────────────────
    private var dietCard: some View {
        // 6 options, 2-col grid — labels have room, no text breaking
        let styles = [("🍗","Omnivore"),("🐟","Pescatarian"),
                      ("🌱","Vegetarian"),("🌿","Vegan"),
                      ("🫙","Keto / Low-Carb"),("🤷","No Preference")]
        return VStack(spacing: 16) {
            cardHeader(emoji: "🍽️", title: "How do you\nlike to eat?",
                       subtitle: "We'll filter recipes to match your lifestyle.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(styles, id: \.1) { emoji, label in
                    chip("\(emoji)  \(label)", selected: dietaryStyle == label) { dietaryStyle = label }
                }
            }.padding(.horizontal, 22)
            continueButton(enabled: !dietaryStyle.isEmpty) { advance() }
        }
    }

    // ── Step 4: Allergens ───────────────────────────────────────────
    private var allergenCard: some View {
        let all = ["🥜 Peanuts","🌰 Tree Nuts","🥛 Dairy","🥚 Eggs","🐟 Fish",
                   "🦐 Shellfish","🌾 Gluten","🫘 Soy","🌽 Corn","None"]
        return VStack(spacing: 16) {
            cardHeader(emoji: "⚠️", title: "Any allergies or\nfoods to avoid?",
                       subtitle: "Select all that apply.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(all, id: \.self) { item in
                    let clean = item.components(separatedBy: " ").dropFirst().joined(separator: " ")
                    chip(item, selected: allergens.contains(clean)) {
                        if clean == "None" { allergens = [] }
                        else if allergens.contains(clean) { allergens.removeAll { $0 == clean } }
                        else { allergens.append(clean) }
                    }
                }
            }.padding(.horizontal, 22)
            continueButton { advance() }
        }
    }

    // ── Step 5: Cuisines ────────────────────────────────────────────
    // Consolidated: Greek→Mediterranean, Korean/Japanese/Vietnamese/Thai/Chinese→Asian, Spanish→Mediterranean, Sri Lankan→Indian
    private var cuisineCard: some View {
        let cuisines = RecipeTaxonomy.cuisines.map { (CuisineBrowseView.flag(for: $0), $0) }
        return VStack(spacing: 16) {
            cardHeader(emoji: "🌍", title: "Which cuisines\nexcite you?",
                       subtitle: "Pick your favourites. You can always explore more inside the app.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(cuisines, id: \.1) { emoji, label in
                    chip("\(emoji)\n\(label)", selected: cuisinePrefs.contains(label)) {
                        if cuisinePrefs.contains(label) { cuisinePrefs.removeAll { $0 == label } }
                        else { cuisinePrefs.append(label) }
                    }
                }
            }.padding(.horizontal, 22)
            continueButton { advance() }
        }
    }

    // ── Step 6: Skill ───────────────────────────────────────────────
    private var skillCard: some View {
        let levels: [(String,String,String)] = [
            ("🥚","Beginner","I can scramble eggs and boil water"),
            ("🍳","Home Cook","I follow recipes confidently"),
            ("👨‍🍳","Experienced","I improvise and experiment often"),
            ("⭐️","Enthusiast","I study techniques and love to push limits"),
        ]
        return VStack(spacing: 16) {
            cardHeader(emoji: "📚", title: "How comfortable\nare you in the kitchen?",
                       subtitle: "Be honest — we'll pitch the right difficulty.")
            VStack(spacing: 8) {
                ForEach(levels, id: \.1) { emoji, label, desc in
                    Button { skillLevel = label } label: {
                        HStack(spacing: 12) {
                            Text(emoji).scaledFont(22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label).scaledFont(14, weight: .semibold, design: .serif)
                                    .foregroundStyle(session.themeTextColor)
                                Text(desc).scaledFont(11).foregroundStyle(session.themeTextColor.opacity(0.5))
                            }
                            Spacer()
                            if skillLevel == label {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.stockedGold)
                            }
                        }
                        .padding(14)
                        .background(skillLevel == label ? Color.stockedGold.opacity(0.1) : Color.stockedWhite.opacity(0.4))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                        .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd).stroke(skillLevel == label ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 22)
            continueButton(label: "See My Matches", enabled: !skillLevel.isEmpty) { finishQuiz() }
        }
    }

    // ── Step 7: Schedule ────────────────────────────────────────────
    private var scheduleCard: some View {
        let days = ["Mon","Tue","Wed","Thu","Fri","Sat","Sun"]
        return VStack(spacing: 16) {
            cardHeader(emoji: "📅", title: "When do you\nusually shop?",
                       subtitle: "We'll time your low-stock alerts around this.")
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Meals cooked per week").scaledFont(13, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Text("\(weeklyMeals)").scaledFont(14, weight: .bold).foregroundStyle(Color.stockedGold)
                }
                Slider(value: Binding(get: { Double(weeklyMeals) }, set: { weeklyMeals = Int($0) }), in: 1...21, step: 1)
                    .tint(Color.stockedGold)
            }
            .padding(14).background(session.themeCardColor).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .padding(.horizontal, 22)

            VStack(alignment: .leading, spacing: 8) {
                Text("Grocery day").scaledFont(13, weight: .semibold)
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                    .padding(.horizontal, 22)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(days, id: \.self) { day in
                            Button { mealPrepDay = day } label: {
                                Text(day)
                                    .font(.stockedSystem(size: 13, weight: mealPrepDay == day ? .bold : .medium, design: .serif))
                                    .foregroundStyle(mealPrepDay == day ? Color.stockedCharcoal : session.themeTextColor)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(
                                        RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                                            .fill(mealPrepDay == day ? Color.stockedGold : Color.stockedWhite.opacity(0.4))
                                    )
                            }.buttonStyle(.plain)
                        }
                        Button { mealPrepDay = "Any" } label: {
                            Text("Any day")
                                .font(.stockedSystem(size: 13, weight: mealPrepDay == "Any" ? .bold : .medium, design: .serif))
                                .foregroundStyle(mealPrepDay == "Any" ? Color.stockedCharcoal : session.themeTextColor)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(
                                    RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd)
                                        .fill(mealPrepDay == "Any" ? Color.stockedGold : Color.stockedWhite.opacity(0.4))
                                )
                        }.buttonStyle(.plain)
                    }
                    .stockedScrollTargetLayout()
                    .padding(.horizontal, 22)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .stockedHorizontalSnap()
            }
            continueButton(enabled: !mealPrepDay.isEmpty) { advance() }
        }
    }


    // ── Equipment step ───────────────────────────────────────────────
    private var equipmentCard: some View {
        let items = [
            ("🍳","Stovetop"),("🔥","Oven"),("🔌","Microwave"),("💨","Air Fryer"),
            ("🫕","Slow Cooker"),("🫙","Instant Pot"),("♨️","Grill / BBQ"),
            ("🥗","Blender"),("🍹","Food Processor"),("🎛️","Toaster Oven")
        ]
        return VStack(spacing: 16) {
            cardHeader(emoji: "🍳", title: "What do you\ncook with?",
                       subtitle: "We'll only suggest recipes you can actually make.")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(items, id: \.1) { emoji, label in
                    chip("\(emoji)  \(label)", selected: cookingEquipment.contains(label)) {
                        if cookingEquipment.contains(label) { cookingEquipment.removeAll { $0 == label } }
                        else { cookingEquipment.append(label) }
                    }
                }
            }.padding(.horizontal, 22)
            continueButton(label: "Continue →", enabled: !cookingEquipment.isEmpty) { finishQuiz() }
        }
    }

    // Budget + Kids question removed per tracker — saved for future rollout
    private var budgetKidsCard: some View { EmptyView() }

    // ── Finish card ─────────────────────────────────────────────────
    private var finishCard: some View {
        VStack(spacing: 16) {
            Text("🎉").scaledFont(64).padding(.top, 8)
            Text("Your kitchen is ready!")
                .scaledFont(22, weight: .bold, design: .serif)
                .foregroundStyle(session.themeTextColor)
                .multilineTextAlignment(.center)
            Text("We've set everything up based on your preferences. Update them anytime in Settings.")
                .scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.55))
                .multilineTextAlignment(.center).padding(.horizontal, 22)
            continueButton(label: "Start Cooking 🍳") {
                completeOnboarding()
            }
        }
    }

    // ── Save profile ────────────────────────────────────────────────
    private func finishQuiz() {
        persistCurrentProfile()
        // NOTE: do NOT set quizCompleted here — that would make RootView swap to
        // MainTabView mid-animation (blanks iPad). Only the finish card's "Start
        // Cooking" button flips quizCompleted, via completeOnboarding().
        motion.animate(.navigation, intent: .spatial) { step = totalSteps }
    }

    private func persistCurrentProfile() {
        var p = session.guestStore.cookingProfile
        p.householdSize  = householdSize
        p.cookingGoal    = cookingGoal
        p.dietaryStyle   = dietaryStyle
        p.allergens      = allergens
        p.cuisinePrefs   = cuisinePrefs
        p.skillLevel     = skillLevel
        p.weeklyMealCount = weeklyMeals
        p.mealPrepDay    = mealPrepDay
        p.cookingEquipment = cookingEquipment
        p.avatarEmoji    = avatarEmoji
        p.completedSetup = true
        session.guestStore.cookingProfile = p
    }

    /// Re-running onboarding edits the existing profile instead of silently resetting
    /// answers to view-local defaults. Fresh installs still receive the model defaults.
    private func hydrateFromPersistedProfileIfNeeded() {
        guard !didHydrateProfile else { return }
        didHydrateProfile = true
        let p = session.guestStore.cookingProfile
        householdSize = p.householdSize
        cookingGoal = p.cookingGoal
        dietaryStyle = p.dietaryStyle
        allergens = p.allergens
        cuisinePrefs = p.cuisinePrefs
        skillLevel = p.skillLevel
        weeklyMeals = p.weeklyMealCount
        mealPrepDay = p.mealPrepDay
        budgetLevel = p.budgetLevel
        cookingEquipment = p.cookingEquipment
        avatarEmoji = p.avatarEmoji
    }

    /// Single, reliable path out of onboarding into the app (Home).
    /// Order matters: settle login/name/profile first, then flip quizCompleted on a
    /// later runloop tick so RootView swaps to a fully-settled MainTabView instead of
    /// rebuilding mid-update (which showed a blank screen). Doing both syncronously
    /// fenced on iPad; too-short a delay left it blank — so we defer ~one frame and
    /// flip without an animation block.
    private func completeOnboarding() {
        // The close/skip affordance uses this path too, so persist every answer made so
        // far. Previously skipping discarded the quiz while marking it complete.
        persistCurrentProfile()
        let name = session.displayName.trimmingCharacters(in: .whitespaces)
        session.enterKitchen(name: name.isEmpty ? "Chef" : name)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)   // ~a few frames; reliable on device
            var tx = Transaction(); tx.disablesAnimations = true
            withTransaction(tx) { session.guestStore.quizCompleted = true }
        }
    }
}

// MARK: - Supporting components (kept for compatibility)


// MARK: - Chef icon anchor preference key
private struct ChefIconAnchorKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

#Preview { OnboardingQuiz().environment(AppSession()) }
