// RecipePortionsEditSheet.swift
// Opened from the recipe overview's "Portions check" → Edit Inventory.
//
// Lists every ingredient the recipe needs alongside its live inventory match:
// adjust the matched item's fill level in place, delete it, or add the missing
// ingredient straight to the grocery list. Because GuestDataStore is
// @Observable, every change re-renders the recipe screen underneath in real
// time — the In stock / Need to buy statuses and the portions-check count
// update live as you edit.

import SwiftUI

struct RecipePortionsEditSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    let recipeTitle: String
    let ingredients: [String]

    @State private var addedToList: Set<String> = []
    @State private var showAddItem = false

    private var store: GuestDataStore { session.guestStore }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    Capsule().fill(Color.stockedCharcoal.opacity(0.2))
                        .frame(width: 40, height: 4)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 10).padding(.bottom, 12)

                    Text("Recipe Ingredients")
                        .font(.system(size: 18, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                        .padding(.horizontal, 22).padding(.bottom, 2)
                    Text("Edit amounts, remove items, or add what's missing to your grocery list. The recipe updates as you go.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 22).padding(.bottom, 12)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(Array(ingredients.enumerated()), id: \.offset) { _, ing in
                                ingredientRow(ing)
                            }
                        }
                        .padding(.horizontal, 18).padding(.bottom, 24)
                    }

                    Button { showAddItem = true } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "plus.circle.fill").font(.system(size: 14))
                            Text("Add a pantry item")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .foregroundStyle(Color.stockedGold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.stockedGold.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18).padding(.bottom, 8)

                    Button { dismiss() } label: {
                        Text("Done")
                            .font(.system(size: 16, weight: .semibold, design: .serif))
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(session.themeButtonColor)
                            .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18).padding(.bottom, 14)
                }
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large, .medium])
        .sheet(isPresented: $showAddItem) {
            AddItemSheet(defaultZone: "Fridge").environment(session)
        }
    }

    @ViewBuilder
    private func ingredientRow(_ ing: String) -> some View {
        let match = IngredientStockMatch.firstMatch(ingredient: ing, in: store.inventoryItems)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Circle().fill(match != nil ? Color.stockedGreen : Color.stockedGold)
                    .frame(width: 7, height: 7)
                Text(ing)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(session.themeTextColor)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Text(match != nil ? "In stock" : "Missing")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(match != nil ? Color.stockedGreen : Color.stockedGold)
                    .lineLimit(1)
                    .fixedSize()
            }

            if let item = match {
                // Live inventory controls for the matched item.
                HStack(spacing: 10) {
                    Text(item.name.displayNormalized)
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Button {
                        store.updateInventoryLevel(id: item.id, level: max(0, item.level - 0.25))
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 18)).foregroundStyle(Color.stockedGold)
                    }.buttonStyle(.plain)
                    Text("\(Int((item.effectiveLevel * 100).rounded()))%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(session.themeTextColor)
                        .frame(minWidth: 40)
                    Button {
                        store.updateInventoryLevel(id: item.id, level: min(1, item.level + 0.25))
                    } label: {
                        Image(systemName: "plus.circle")
                            .font(.system(size: 18)).foregroundStyle(Color.stockedGold)
                    }.buttonStyle(.plain)
                    Button {
                        let removed = item
                        store.removeInventoryItem(id: item.id)
                        ToastCenter.shared.undo("Deleted \(item.name.displayNormalized)") {
                            store.restoreInventoryItems([removed])
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.stockedError.opacity(0.8))
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            } else {
                // Missing — one-tap add to grocery list.
                let key = ing.lowercased()
                Button {
                    let name = RecipeIngredients.parse(ing).name
                    store.addToGroceryIfMissing(name.isEmpty ? ing : name.capitalized,
                                                recommended: false, recipeSource: recipeTitle)
                    withAnimation { _ = addedToList.insert(key) }
                    HapticManager.success()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: addedToList.contains(key) ? "checkmark.circle.fill" : "cart.badge.plus")
                            .font(.system(size: 12))
                        Text(addedToList.contains(key) ? "Added to Grocery List" : "Add to Grocery List")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(addedToList.contains(key) ? Color.stockedGreen : Color.stockedGold)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background((addedToList.contains(key) ? Color.stockedGreen : Color.stockedGold).opacity(0.10))
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(addedToList.contains(key))
            }
        }
        .padding(12)
        .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.40))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusMd))
    }
}
