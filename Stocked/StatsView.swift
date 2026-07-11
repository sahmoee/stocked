// StatsView.swift — Kitchen statistics dashboard (App Better #14)
import SwiftUI

struct StatsView: View {
    @Environment(AppSession.self) var session
    // #260 — Kitchen Goals entry point restored. StockGoalsSetupView (the "what does
    // 'stocked' mean to you?" quiz) existed but had no call sites, so stockGoalsConfigured
    // was never set and the health % always fell back to average fill. Tapping the ring
    // opens it; saving flips the % to the staples-in-stock ratio.
    @State private var showKitchenGoals = false
    private var store: GuestDataStore { session.guestStore }
    private var dark: Bool { session.isDarkMode }
    private var text: Color { dark ? Color.stockedWhite : Color.stockedCharcoal }

    private var totalCooked: Int { store.pastMeals.count }
    private var thisWeek: Int {
        store.pastMeals.filter { m in
            guard let d = parseDate(m.date) else { return false }
            return Calendar.current.isDate(d, equalTo: Date(), toGranularity: .weekOfYear)
        }.count
    }
    private var stockedCount: Int { store.inventoryItems.filter { $0.effectiveLevel > 0 }.count }
    private var wasteScore: Int {
        let exp = store.inventoryItems.filter { ($0.daysUntilExpiry ?? 99) < 0 }.count
        return max(0, 100 - Int(Double(exp) / Double(max(1, store.inventoryItems.count)) * 100))
    }
    private var estimatedSaved: Int { totalCooked * 10 }

    // ── #238 Kitchen Report data ─────────────────────────────────────
    private var healthLabel: String {
        let p = store.stockPercent
        switch p { case 80...: return "Very Well Stocked"; case 60..<80: return "Well Stocked"
        case 40..<60: return "Getting Low"; default: return "Running Low" }
    }
    private var zoneBreakdown: [(String, String, Int)] {
        let zones: [(String, String)] = [("Fridge","refrigerator"),("Pantry","cabinet"),("Freezer","snowflake"),("Staples","star")]
        return zones.map { name, icon in
            let items = store.inventoryItems.filter { $0.zone == name }
            let pct = items.isEmpty ? 0 : Int((items.map(\.effectiveLevel).reduce(0,+) / Double(items.count)) * 100)
            return (name, icon, pct)
        }
    }
    // #251 — single source of truth: use availableMeals (catalog-based, same as Home,
    // the Daily Brief, and the Cook Now rail) so every screen shows the same number.
    private var mealsReady: Int { store.availableMeals }
    private var mealsPlanned: Int { store.plannedMeals.filter { !$0.isCooked }.count }
    private var expiringToday: Int { store.inventoryItems.filter { $0.daysUntilExpiry == 0 }.count }
    private var expiringWeek: Int { store.inventoryItems.filter { if let d = $0.daysUntilExpiry { return d > 0 && d <= 7 }; return false }.count }
    private var freshItems: Int { store.inventoryItems.filter { if let d = $0.daysUntilExpiry { return d > 7 }; return $0.effectiveLevel > 0 }.count }
    private var addedThisWeek: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return store.inventoryItems.filter { ($0.purchaseDate ?? .distantPast) > cutoff }.count
    }
    private var usedThisWeek: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return store.consumptionLog.filter { !$0.wasted && $0.depletedAt > cutoff }.count
    }
    private var expiredThisWeek: Int {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return store.consumptionLog.filter { $0.wasted && $0.depletedAt > cutoff }.count
    }
    private var toBuyCount: Int { store.groceryItems.filter { !$0.isChecked }.count }

    // #6 — spend THIS WEEK (the report already shows month + all-time further down).
    private var spendThisWeek: Double {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        return store.priceHistory.filter { $0.date > cutoff }.map(\.price).reduce(0, +)
    }

    // #8 — weekly nutrition rollup: sum macros of recipes cooked in the last 7 days, linked
    // by recipeId (title fallback), using each recipe's ingredient nutrition per serving.
    private var weeklyNutrition: (cal: Int, protein: Int, carbs: Int, fat: Int, meals: Int)? {
        let cutoff = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        let recent = store.pastMeals.filter { m in
            guard let d = parseDate(m.date) else { return false }
            return d > cutoff
        }
        guard !recent.isEmpty else { return nil }
        var cal = 0.0, pro = 0.0, carb = 0.0, fat = 0.0, counted = 0
        for meal in recent {
            let key = meal.title.lowercased().trimmingCharacters(in: .whitespaces)
            guard let r = store.userRecipes.first(where: {
                $0.id == meal.recipeId || $0.title.lowercased().trimmingCharacters(in: .whitespaces) == key
            }) else { continue }
            let srv = Double(max(1, r.servings))
            let c = r.ingredients.compactMap { $0.nutrition?.calories }.reduce(0, +)
            guard c > 0 else { continue }
            cal  += Double(c) / srv
            pro  += r.ingredients.compactMap { $0.nutrition?.protein }.reduce(0, +) / srv
            carb += r.ingredients.compactMap { $0.nutrition?.totalCarbs }.reduce(0, +) / srv
            fat  += r.ingredients.compactMap { $0.nutrition?.totalFat }.reduce(0, +) / srv
            counted += 1
        }
        guard counted > 0 else { return nil }
        return (Int(cal), Int(pro), Int(carb), Int(fat), counted)
    }

    private func reportPanel<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Color.stockedWhite.opacity(0.7))
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.stockedWhite.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }
    private func reportStat(_ value: String, _ label: String, _ tint: Color) -> some View {
        VStack(spacing: 4) {
            Text(value).font(.system(size: 24, weight: .heavy, design: .serif)).foregroundStyle(tint)
            Text(label).font(.system(size: 10.5)).multilineTextAlignment(.center)
                .foregroundStyle(Color.stockedWhite.opacity(0.6))
        }
        .frame(maxWidth: .infinity)
    }
    private var topIngredients: [(String, Int)] {
        var c: [String: Int] = [:]
        store.inventoryItems.forEach { c[$0.name.components(separatedBy: " ").first ?? $0.name, default: 0] += 1 }
        return c.sorted { $0.value > $1.value }.prefix(5).map { ($0.key.capitalized, $0.value) }
    }

    var body: some View {
        StockedShell(showBack: true) {
            VStack(alignment: .leading, spacing: 0) {
                // ── #238 — dark Kitchen Report (mockup) ─────────────────
                VStack(alignment: .leading, spacing: 18) {
                    Text("Kitchen Report")
                        .font(.system(size: 22, weight: .bold, design: .serif))
                        .foregroundStyle(Color.stockedWhite)

                    // Health ring
                    HStack {
                        Spacer()
                        ZStack {
                            Circle().stroke(Color.stockedWhite.opacity(0.10), lineWidth: 12)
                            Circle()
                                .trim(from: 0, to: CGFloat(store.stockPercent) / 100)
                                .stroke(Color.stockedGreen, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            VStack(spacing: 3) {
                                Text("Kitchen Health")
                                    .font(.system(size: 12)).foregroundStyle(Color.stockedWhite.opacity(0.6))
                                Text("\(store.stockPercent)%")
                                    .font(.system(size: 42, weight: .heavy, design: .serif))
                                    .foregroundStyle(Color.stockedGreen)
                                Text(healthLabel)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.stockedWhite.opacity(0.8))
                                // #260/#261 — say what the number measures, invite setup.
                                Text(store.stockGoalsConfigured && !store.stockStaples.isEmpty
                                     ? "Anchored to your \(store.stockStaples.count) staples · tap to edit"
                                     : "Average fill · tap to set goals")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.stockedWhite.opacity(0.45))
                            }
                        }
                        .frame(width: 180, height: 180)
                        .contentShape(Circle())
                        .onTapGesture { showKitchenGoals = true }
                        .sheet(isPresented: $showKitchenGoals) {
                            StockGoalsSetupView(existing: store.stockStaples,
                                                configured: store.stockGoalsConfigured)
                                .environment(session)
                        }
                        Spacer()
                    }

                    // #261 — composite breakdown: shows the signals behind the health % and
                    // their weights. Only meaningful once Kitchen Goals anchor the score.
                    if store.stockGoalsConfigured && !store.stockStaples.isEmpty {
                        reportPanel("Health Breakdown") {
                            VStack(spacing: 10) {
                                ForEach(store.kitchenHealthComponents) { comp in
                                    HStack(spacing: 10) {
                                        Image(systemName: comp.icon).font(.system(size: 12))
                                            .foregroundStyle(Color.stockedWhite.opacity(0.7)).frame(width: 18)
                                        Text(comp.name).font(.system(size: 13))
                                            .foregroundStyle(Color.stockedWhite.opacity(0.85))
                                            .frame(width: 104, alignment: .leading)
                                        ZStack(alignment: .leading) {
                                            Capsule().fill(Color.stockedWhite.opacity(0.10)).frame(height: 7)
                                            GeometryFreeBar(fraction: Double(comp.percent) / 100, color: Color.stockedGreen)
                                        }
                                        Text("\(comp.percent)%")
                                            .font(.system(size: 12, weight: .bold)).monospacedDigit()
                                            .foregroundStyle(Color.stockedWhite.opacity(0.8))
                                            .frame(width: 38, alignment: .trailing)
                                    }
                                }
                                Text("Weighted \(store.kitchenHealthComponents.map { "\($0.name) \($0.weight)%" }.joined(separator: " · "))")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.stockedWhite.opacity(0.4))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    // Inventory breakdown — per-zone fill bars
                    reportPanel("Inventory Breakdown") {
                        VStack(spacing: 10) {
                            ForEach(zoneBreakdown, id: \.0) { zone, icon, pct in
                                HStack(spacing: 10) {
                                    Image(systemName: icon).font(.system(size: 12))
                                        .foregroundStyle(Color.stockedWhite.opacity(0.7)).frame(width: 18)
                                    Text(zone).font(.system(size: 13))
                                        .foregroundStyle(Color.stockedWhite.opacity(0.85))
                                        .frame(width: 64, alignment: .leading)
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.stockedWhite.opacity(0.10)).frame(height: 7)
                                        GeometryFreeBar(fraction: Double(pct) / 100, color: Color.stockedGreen)
                                    }
                                    Text("\(pct)%")
                                        .font(.system(size: 12, weight: .bold)).monospacedDigit()
                                        .foregroundStyle(Color.stockedWhite.opacity(0.8))
                                        .frame(width: 38, alignment: .trailing)
                                }
                            }
                        }
                    }

                    // Meal readiness + expiration overview
                    HStack(spacing: 12) {
                        reportPanel("Meal Readiness") {
                            HStack(spacing: 0) {
                                reportStat("\(mealsReady)", "Meals\nReady", Color.stockedGreen)
                                reportStat("\(mealsPlanned)", "Meals\nPlanned", Color.stockedGold)
                                reportStat("\(store.userRecipes.count)", "Recipes\nSaved", Color.stockedInfo)
                            }
                        }
                    }
                    reportPanel("Expiration Overview") {
                        HStack(spacing: 0) {
                            reportStat("\(expiringToday)", "Expiring\nToday", .orange)
                            reportStat("\(expiringWeek)", "Expiring\nThis Week", Color.stockedGold)
                            reportStat("\(freshItems)", "Fresh\nItems", Color.stockedGreen)
                        }
                    }
                    // Shopping readiness (mockup: includes next grocery run)
                    reportPanel("Shopping Readiness") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 12) {
                                Image(systemName: "cart").font(.system(size: 18))
                                    .foregroundStyle(toBuyCount == 0 ? Color.stockedGreen : Color.stockedGold)
                                Text(toBuyCount == 0 ? "0 items to buy — you're all set!" : "\(toBuyCount) item\(toBuyCount == 1 ? "" : "s") to buy")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.stockedWhite.opacity(0.9))
                                Spacer()
                            }
                            Text("Next Grocery Run · \(store.groceryRunDateText)")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.stockedWhite.opacity(0.55))
                        }
                    }
                    reportPanel("This Week Activity") {
                        HStack(spacing: 0) {
                            reportStat("\(addedThisWeek)", "Items\nAdded", Color.stockedGreen)
                            reportStat("\(usedThisWeek)", "Items\nUsed", Color.stockedGold)
                            reportStat("\(expiredThisWeek)", "Items\nExpired", .red)
                        }
                    }
                    // #D1 — the positive counterpart to waste: what the app helped you SAVE.
                    // Used-before-wasted rate this month, plus dollars kept out of the trash
                    // (spend on used items estimated from receipt prices where known).
                    reportPanel("Saved This Month") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 0) {
                                reportStat("\(usedThisMonthCount)", "Used, not\nwasted", Color.stockedGreen)
                                reportStat("\(savedRatePercent)%", "Use-it\nrate", Color.stockedGold)
                                reportStat(money(wastedValueThisMonthTotal), "Waste\ncost", wastedValueThisMonthTotal > 0 ? .orange : Color.stockedGreen)
                            }
                            Text(savedRatePercent >= 80
                                 ? "Great month — almost everything got used before it went bad."
                                 : "Every item cooked before its date is money kept out of the trash.")
                                .font(.system(size: 10.5))
                                .foregroundStyle(Color.stockedWhite.opacity(0.5))
                        }
                    }
                    // #6 — spending: this week alongside the month, from receipt prices.
                    if !store.priceHistory.isEmpty {
                        reportPanel("Spending") {
                            HStack(spacing: 0) {
                                reportStat(money(spendThisWeek), "This\nWeek", Color.stockedGold)
                                reportStat(money(spendThisMonth), "This\nMonth", Color.stockedGreen)
                                reportStat(money(spendAllTime), "All\nTime", Color.stockedInfo)
                            }
                        }
                    }
                    // #8 — weekly nutrition rollup from meals cooked in the last 7 days.
                    if let n = weeklyNutrition {
                        reportPanel("This Week Nutrition") {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 0) {
                                    reportStat("\(n.cal)", "Calories\n(per serv.)", Color.stockedGold)
                                    reportStat("\(n.protein)g", "Protein", Color.stockedGreen)
                                    reportStat("\(n.carbs)g", "Carbs", Color.stockedInfo)
                                    reportStat("\(n.fat)g", "Fat", .orange)
                                }
                                Text("From \(n.meals) cooked meal\(n.meals == 1 ? "" : "s") with nutrition data this week")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(Color.stockedWhite.opacity(0.5))
                            }
                        }
                    }
                }
                .padding(20)
                .background(Color.stockedBlack.opacity(0.92))
                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusLg))
                .padding(.horizontal, 20).padding(.bottom, 24)
            }
        }
    }

    private func statCard(_ value: String, _ label: String, _ icon: String, _ tint: Color, _ text: Color) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 24)).foregroundStyle(tint)
            Text(value).font(.system(size: 32, weight: .bold, design: .serif)).foregroundStyle(text)
            Text(label).stocked(.caption).foregroundStyle(text.opacity(0.5)).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(18)
        .background(Color.stockedWhite.opacity(0.28)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }

    private func parseDate(_ s: String) -> Date? {
        let f = DateFormatter(); f.dateStyle = .short; return f.date(from: s)
    }

    // MARK: - #18 spending / #19 waste / #20 reorder data
    private func isThisMonth(_ d: Date) -> Bool { Calendar.current.isDate(d, equalTo: Date(), toGranularity: .month) }
    private var spendThisMonth: Double { store.priceHistory.filter { isThisMonth($0.date) }.map(\.price).reduce(0, +) }
    private var spendAllTime: Double { store.priceHistory.map(\.price).reduce(0, +) }
    private var spendByStore: [(String, Double)] {
        var m: [String: Double] = [:]
        for r in store.priceHistory where isThisMonth(r.date) { m[r.store.isEmpty ? "Other" : r.store, default: 0] += r.price }
        return m.sorted { $0.value > $1.value }.prefix(4).map { ($0.key, $0.value) }
    }
    private var wastedThisMonth: [ConsumptionRecord] { store.consumptionLog.filter { $0.wasted && isThisMonth($0.depletedAt) } }
    private var wastedValueThisMonth: Double { wastedThisMonth.compactMap { $0.estimatedValue }.reduce(0, +) }

    // #D1 "Saved This Month" — the positive framing of the same log.
    private var usedThisMonthCount: Int {
        store.consumptionLog.filter { !$0.wasted && isThisMonth($0.depletedAt) }.count
    }
    private var savedRatePercent: Int {
        let wasted = wastedThisMonth.count
        let total = usedThisMonthCount + wasted
        guard total > 0 else { return 100 }
        return Int((Double(usedThisMonthCount) / Double(total) * 100).rounded())
    }
    private var wastedValueThisMonthTotal: Double { wastedValueThisMonth }
    private var recentWaste: [ConsumptionRecord] {
        store.consumptionLog.filter { $0.wasted }.sorted { $0.depletedAt > $1.depletedAt }.prefix(5).map { $0 }
    }
    /// (#8) Most frequently wasted item across the whole log — repeat offenders only.
    private var topWasted: (String, Int)? {
        let counts = Dictionary(grouping: store.consumptionLog.filter { $0.wasted },
                                by: { $0.itemName.lowercased() })
            .mapValues { $0.count }
        guard let best = counts.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value)
    }
    private var reorderSoon: [LocalInventoryItem] { store.itemsRunningOutSoon(within: 4) }

    @ViewBuilder private var spendingSection: some View {
        if !store.priceHistory.isEmpty {
            sectionHeader("THIS MONTH’S SPENDING")
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(money(spendThisMonth)).font(.system(size: 28, weight: .bold, design: .serif)).foregroundStyle(text)
                    Spacer()
                    Text("\(money(spendAllTime)) all-time").stocked(.caption).foregroundStyle(text.opacity(0.4))
                }
                // #6 — weekly spend at a glance, next to the monthly number.
                Text("\(money(spendThisWeek)) in the last 7 days")
                    .stocked(.caption).foregroundStyle(Color.stockedGold)
                if spendByStore.isEmpty {
                    Text("No purchases logged this month yet.").stocked(.caption).foregroundStyle(text.opacity(0.4))
                } else {
                    ForEach(spendByStore, id: \.0) { name, amt in
                        HStack {
                            Text(name).stocked(.body).foregroundStyle(text.opacity(0.8))
                            Spacer()
                            Text(money(amt)).stocked(.body).foregroundStyle(Color.stockedGold)
                        }
                    }
                }
            }
            .padding(16).background(Color.stockedWhite.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
            .padding(.horizontal, 20).padding(.bottom, 20)
        }
    }

    @ViewBuilder private var wasteSection: some View {
        let empty = wastedThisMonth.isEmpty
        sectionHeader("FOOD WASTE")
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 16) {
                Image(systemName: empty ? "leaf.fill" : "trash.fill")
                    .font(.system(size: 30)).foregroundStyle(empty ? Color.stockedGreen : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    if empty {
                        Text("Nothing wasted this month").stocked(.headline).foregroundStyle(text)
                        Text("Items tossed past their expiry show up here.").stocked(.caption).foregroundStyle(text.opacity(0.4))
                    } else {
                        Text("\(wastedThisMonth.count) item\(wastedThisMonth.count == 1 ? "" : "s") wasted").stocked(.headline).foregroundStyle(text)
                        Text(wastedValueThisMonth > 0 ? "About \(money(wastedValueThisMonth)) this month" : "this month")
                            .stocked(.caption).foregroundStyle(text.opacity(0.5))
                    }
                }
                Spacer()
            }
            if !recentWaste.isEmpty {
                Divider()
                ForEach(recentWaste, id: \.id) { rec in
                    HStack {
                        Text(rec.itemName.capitalized).stocked(.body).foregroundStyle(text.opacity(0.8))
                        Spacer()
                        Text(relativeDate(rec.depletedAt)).stocked(.caption).foregroundStyle(text.opacity(0.4))
                    }
                }
            }
            // #8 — coaching: the item you waste most often, with a concrete suggestion
            if let (name, count) = topWasted, count >= 2 {
                Divider()
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "lightbulb.fill").font(.system(size: 13)).foregroundStyle(Color.stockedGold)
                    Text("You've tossed \(name.capitalized) \(count)× — try buying a smaller amount, or freeze half when you get it home.")
                        .stocked(.caption).foregroundStyle(text.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(16).background((empty ? Color.stockedGreen : Color.orange).opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
        .padding(.horizontal, 20).padding(.bottom, 20)
    }

    @ViewBuilder private var reorderSection: some View {
        let items = reorderSoon
        if !items.isEmpty {
            sectionHeader("REORDER SOON")
            VStack(spacing: 8) {
                ForEach(items, id: \.id) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.name).stocked(.body).foregroundStyle(text)
                            if let avg = store.averageDaysToDeplete(for: item.name) {
                                Text("Usually lasts ~\(Int(avg.rounded())) days").stocked(.caption).foregroundStyle(text.opacity(0.4))
                            } else {
                                Text("Running low").stocked(.caption).foregroundStyle(text.opacity(0.4))
                            }
                        }
                        Spacer()
                        Button { store.addToGroceryIfMissing(item.name, recommended: true) } label: {
                            Label("Add", systemImage: "cart.badge.plus").stocked(.caption).foregroundStyle(Color.stockedGold)
                        }.buttonStyle(.plain)
                    }
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Color.stockedWhite.opacity(0.25)).clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    .padding(.horizontal, 20)
                }
            }
            .padding(.bottom, 20)
        }
    }

    private func sectionHeader(_ s: String) -> some View {
        SectionHeader(text: s)
    }
    private func money(_ v: Double) -> String { String(format: "$%.2f", v) }
    private func relativeDate(_ d: Date) -> String {
        let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        return "\(days)d ago"
    }
}

// #238 — proportional bar with no GeometryReader (scaleEffect from leading anchor).
struct GeometryFreeBar: View {
    let fraction: Double
    let color: Color
    var body: some View {
        Capsule().fill(color)
            .frame(height: 7)
            .scaleEffect(x: max(0.001, min(1, fraction)), y: 1, anchor: .leading)
    }
}
