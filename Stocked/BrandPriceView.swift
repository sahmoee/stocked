// BrandPriceView.swift
// Reusable brand + price badge, backed by GroceryProductClient (cached, keyed by
// RAPIDAPI_KEY). Drop it next to any item name anywhere in the app:
//
//     BrandPriceView(itemName: item.name)
//
// It fetches the best catalog match once (results are cached for a day), shows the brand
// and price compactly, and renders NOTHING when there's no key, no match, or no data — so
// it never disrupts a layout. Safe to place in dense rows or detail screens.

import SwiftUI

struct BrandPriceView: View {
    let itemName: String
    var store: GroceryProductClient.Store = .walmart
    /// compact = single inline row (for list rows); false = slightly larger (detail screens).
    var compact: Bool = true

    @Environment(AppSession.self) private var session
    @State private var product: GroceryProduct?
    @State private var didLoad = false

    var body: some View {
        Group {
            if let p = product, hasData(p) {
                HStack(spacing: 6) {
                    if let brand = p.brand, !brand.isEmpty {
                        Text(brand)
                            .font(.stockedSystem(size: compact ? 11 : 12.5, weight: .semibold))
                            .foregroundStyle(session.themeTextColor.opacity(0.7))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let price = p.price, !price.isEmpty {
                        Text(price)
                            .font(.stockedSystem(size: compact ? 11 : 12.5, weight: .bold))
                            .foregroundStyle(Color.stockedGold)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(
                                Capsule().fill(Color.stockedGold.opacity(0.14))
                            )
                    }
                    Text(p.store)
                        .font(.stockedSystem(size: compact ? 9 : 10))
                        .foregroundStyle(session.themeTextColor.opacity(0.4))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
        .task(id: itemName) {
            guard !didLoad else { return }
            didLoad = true
            let match = await GroceryProductClient.shared.bestMatch(for: itemName, store: store)
            withAnimation(.easeInOut(duration: 0.2)) { product = match }
        }
    }

    private func hasData(_ p: GroceryProduct) -> Bool {
        (p.brand?.isEmpty == false) || (p.price?.isEmpty == false)
    }
}
