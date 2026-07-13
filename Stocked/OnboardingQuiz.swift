// OnboardingQuiz.swift — Card-style quiz. Fixed-size swipeable card, same on all devices.
import SwiftUI

struct OnboardingQuiz: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var quizDismiss

    // ── State ──────────────────────────────────────────────────────
    @State private var step:          Int    = 0
    let totalSteps = 9

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
                .onTapGesture { withAnimation(.easeOut) { showChefPrompt = false } }

            VStack(spacing: 6) {
                Image(systemName: "arrowtriangle.up.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.stockedGold)

                VStack(spacing: 10) {
                    Text("Tap your chef icon")
                        .font(.system(size: 17, weight: .bold, design: .serif))
                        .foregroundStyle(Color.white)
                    Text("Choose an avatar that represents\nyour cooking personality.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                    Button("Got it") { withAnimation(.easeOut) { showChefPrompt = false } }
                        .font(.system(size: 14, weight: .semibold))
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
                                        .animation(.spring(response: 0.3), value: step)
                                }
                            }
                            Spacer()
                            // Skip / Close
                            if step < totalSteps - 1 {
                                Button {
                                    completeOnboarding()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 22))
                                        .foregroundStyle(session.themeTextColor.opacity(0.3))
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 22)
                        .padding(.top, 18)
                        .padding(.bottom, 4)

                        // Step content — centered vertically so the card can use the
                        // full height instead of leaving empty space above and below.
                        Spacer(minLength: 12)
                        stepContent
                            .padding(.top, 8)
                            .padding(.bottom, 24)
                        Spacer(minLength: 12)
                    }
                }
                .frame(width: cardWidth)
                .frame(maxHeight: .infinity)            // #4 — fill the vertical space
                .offset(x: dragOffset)
                .opacity(cardOpacity)
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            withAnimation(.interactiveSpring()) {
                                dragOffset = v.translation.width * 0.4
                            }
                        }
                        .onEnded { v in
                            let threshold: CGFloat = 60
                            if v.translation.width < -threshold {
                                goForward()
                            } else if v.translation.width > threshold && step > 0 {
                                goBack()
                            } else {
                                withAnimation(.spring(response: 0.3)) { dragOffset = 0 }
                            }
                        }
                )

                // Back button below card (visible after step 0)
                if step > 0 && step < totalSteps {
                    Button {
                        goBack()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
                            Text("Back").font(.system(size: 14, weight: .semibold, design: .serif))
                        }
                        .foregroundStyle(Color.stockedWhite.opacity(0.7))
                    }.buttonStyle(.plain)
                }
            }
            .padding(.vertical, 44)
        }
        .keyboardDoneToolbar()
        .dismissKeyboardOnTap()
    
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
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            dragOffset = -screenWidth
            cardOpacity = 0
        }
        Task {
            try? await Task.sleep(nanoseconds: 180000000)
            dragOffset = screenWidth
            step += 1
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
                dragOffset = 0; cardOpacity = 1
            }
        }
    }

    private func goBack() {
        guard step > 0 else { return }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
            dragOffset = screenWidth
            cardOpacity = 0
        }
        Task {
            try? await Task.sleep(nanoseconds: 180000000)
            dragOffset = -screenWidth
            step -= 1
            withAnimation(.spring(response: 0.38, dampingFraction: 0.82)) {
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
        case 7:  scheduleCard
        case 8:  equipmentCard
        default: finishCard   // budget/kids step removed
        }
    }

    // ── Card shared components ──────────────────────────────────────
    private func cardHeader(emoji: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Text(emoji).font(.system(size: 44)).padding(.bottom, 2)
            Text(title)
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
                .multilineTextAlignment(.center)
            Text(subtitle)
                .font(.system(size: 14))
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
    }

    private func continueButton(label: String = "Continue →", enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 16, weight: .semibold, design: .serif))
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
                .font(.system(size: 13, weight: selected ? .bold : .medium, design: .serif))
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
                withAnimation(.spring(response: 0.3, dampingFraction: 0.65)) {
                    showAvatarPicker.toggle()
                }
            } label: {
                ZStack {
                    if showAvatarPicker {
                        Circle().fill(Color.stockedGold.opacity(0.15)).frame(width: 90, height: 90)
                    }
                    Text(avatarEmoji)
                        .font(.system(size: showAvatarPicker ? 70 : 60))
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
                                    withAnimation(.spring(response: 0.2)) {
                                        avatarEmoji = e; showAvatarPicker = false
                                    }
                                } label: {
                                    Text(e).font(.system(size: 26))
                                        .padding(5)
                                        .background(avatarEmoji == e ? Color.stockedGold.opacity(0.2) : Color.clear)
                                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                .padding(10)
                .background(Color.stockedWhite.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal, 22)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }

            if !showAvatarPicker {
                VStack(spacing: 8) {
                    Text("Let's Stock your kitchen")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .multilineTextAlignment(.center)
                    Text("A few quick questions and we'll personalise everything — recipes, reminders, grocery lists — around *your* life.")
                        .font(.system(size: 14))
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
        let cuisines = [("🍝","Italian"),("🌮","Mexican"),("🥢","Asian"),
                        ("🫒","Mediterranean"),("🍔","American"),("🫕","Indian"),
                        ("🌴","Caribbean"),("🧆","Middle Eastern"),("🥐","French")]
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
                            Text(emoji).font(.system(size: 22))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label).font(.system(size: 14, weight: .semibold, design: .serif))
                                    .foregroundStyle(session.themeTextColor)
                                Text(desc).font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.5))
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
            continueButton(enabled: !skillLevel.isEmpty) { advance() }
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
                    Text("Meals cooked per week").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(session.themeTextColor)
                    Spacer()
                    Text("\(weeklyMeals)").font(.system(size: 14, weight: .bold)).foregroundStyle(Color.stockedGold)
                }
                Slider(value: Binding(get: { Double(weeklyMeals) }, set: { weeklyMeals = Int($0) }), in: 1...21, step: 1)
                    .tint(Color.stockedGold)
            }
            .padding(14).background(Color.stockedWhite.opacity(0.4)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .padding(.horizontal, 22)

            VStack(alignment: .leading, spacing: 8) {
                Text("Grocery day").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(session.themeTextColor.opacity(0.5))
                    .padding(.horizontal, 22)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(days, id: \.self) { day in
                            Button { mealPrepDay = day } label: {
                                Text(day)
                                    .font(.system(size: 13, weight: mealPrepDay == day ? .bold : .medium, design: .serif))
                                    .foregroundStyle(mealPrepDay == day ? Color.stockedCharcoal : session.themeTextColor)
                                    .lineLimit(1)
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
                                .font(.system(size: 13, weight: mealPrepDay == "Any" ? .bold : .medium, design: .serif))
                                .foregroundStyle(mealPrepDay == "Any" ? Color.stockedCharcoal : session.themeTextColor)
                                .lineLimit(1)
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
            Text("🎉").font(.system(size: 64)).padding(.top, 8)
            Text("Your kitchen is ready!")
                .font(.system(size: 22, weight: .bold, design: .serif))
                .foregroundStyle(session.themeTextColor)
                .multilineTextAlignment(.center)
            Text("We've set everything up based on your preferences. Update them anytime in Settings.")
                .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.55))
                .multilineTextAlignment(.center).padding(.horizontal, 22)
            continueButton(label: "Start Cooking 🍳") {
                completeOnboarding()
            }
        }
    }

    // ── Save profile ────────────────────────────────────────────────
    private func finishQuiz() {
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
        // NOTE: do NOT set quizCompleted here — that would make RootView swap to
        // MainTabView mid-animation (blanks iPad). Only the finish card's "Start
        // Cooking" button flips quizCompleted, via completeOnboarding().
        withAnimation(.spring(response: 0.4)) { step = totalSteps }
    }

    /// Single, reliable path out of onboarding into the app (Home).
    /// Order matters: settle login/name/profile first, then flip quizCompleted on a
    /// later runloop tick so RootView swaps to a fully-settled MainTabView instead of
    /// rebuilding mid-update (which showed a blank screen). Doing both syncronously
    /// fenced on iPad; too-short a delay left it blank — so we defer ~one frame and
    /// flip without an animation block.
    private func completeOnboarding() {
        session.guestStore.cookingProfile.avatarEmoji = avatarEmoji
        session.guestStore.cookingProfile.completedSetup = true
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
    static var defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

#Preview { OnboardingQuiz().environment(AppSession()) }
