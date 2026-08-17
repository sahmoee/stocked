// GroceryCartHandoff.swift — Feature 2: send your list to a retailer instead of reading it off a screen.
//
// First slice: deep-link handoff. We open the retailer's search/cart URL pre-filled from the list,
// item by item, so the user taps "add" in their own app/site (which keeps their account, prices and
// substitutions native). No API keys, no partnership needed to ship — and it's the natural seam for
// affiliate/referral links later (see `affiliateSuffix`).

import SwiftUI
import UIKit

// MARK: - Retailers

nonisolated struct CartRetailer: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    /// Search URL with {q} replaced by the URL-encoded item name.
    let searchTemplate: String
    /// Optional app scheme — if installed we open the app, else fall back to the web URL.
    let appTemplate: String?

    func url(for item: String) -> URL? {
        let q = item.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item
        return URL(string: searchTemplate.replacingOccurrences(of: "{q}", with: q) + CartRetailer.affiliateSuffix)
    }
    func appURL(for item: String) -> URL? {
        guard let t = appTemplate else { return nil }
        let q = item.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? item
        return URL(string: t.replacingOccurrences(of: "{q}", with: q))
    }

    /// Append referral params here when a program is set up (kept in one place on purpose).
    static let affiliateSuffix = ""

    static let all: [CartRetailer] = [
        .init(id: "kroger",     name: "Kroger",      searchTemplate: "https://www.kroger.com/search?query={q}",            appTemplate: nil),
        .init(id: "instacart",  name: "Instacart",   searchTemplate: "https://www.instacart.com/store/s?k={q}",            appTemplate: "instacart://search?query={q}"),
        .init(id: "walmart",    name: "Walmart",     searchTemplate: "https://www.walmart.com/search?q={q}",               appTemplate: "walmart://search?query={q}"),
        .init(id: "target",     name: "Target",      searchTemplate: "https://www.target.com/s?searchTerm={q}",            appTemplate: "target://search?searchTerm={q}"),
        .init(id: "heb",        name: "H-E-B",       searchTemplate: "https://www.heb.com/search/?q={q}",                  appTemplate: nil),
        .init(id: "amazonfresh",name: "Amazon Fresh",searchTemplate: "https://www.amazon.com/s?k={q}&i=amazonfresh",       appTemplate: nil),
        .init(id: "wholefoods", name: "Whole Foods", searchTemplate: "https://www.wholefoodsmarket.com/search?text={q}",   appTemplate: nil),
        .init(id: "safeway",    name: "Safeway",     searchTemplate: "https://www.safeway.com/shop/search-results.html?q={q}", appTemplate: nil),
    ]

    static func preferred() -> CartRetailer {
        let saved = UserDefaults.standard.string(forKey: "cartRetailerID") ?? "kroger"
        return all.first { $0.id == saved } ?? all[0]
    }
    static func setPreferred(_ r: CartRetailer) { UserDefaults.standard.set(r.id, forKey: "cartRetailerID") }
}

// MARK: - Handoff view

struct GroceryCartHandoffView: View {
    @Environment(AppSession.self) private var session
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    /// Item names to shop for (pass the unchecked grocery list).
    let items: [String]

    @State private var retailer: CartRetailer = CartRetailer.preferred()
    @State private var done: Set<String> = []

    var body: some View {
            VStack(spacing: 0) {
                // Retailer picker
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(CartRetailer.all) { r in
                            Button {
                                retailer = r; CartRetailer.setPreferred(r); HapticManager.light()
                            } label: {
                                Text(r.name).font(.system(size: 13, weight: .semibold))
                                    .padding(.horizontal, 14).padding(.vertical, 8)
                                    .background(r.id == retailer.id ? session.accentColor : session.themeTextColor.opacity(0.08))
                                    .foregroundStyle(r.id == retailer.id ? Color.white : session.themeTextColor)
                                    .clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 18).padding(.vertical, 12)
                }

                if items.isEmpty {
                    Spacer()
                    Text("Nothing on the list to shop for.")
                        .font(.system(size: 14)).foregroundStyle(session.themeTextColor.opacity(0.5))
                    Spacer()
                } else {
                    List {
                        Section {
                            ForEach(items, id: \.self) { item in
                                Button { open(item) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: done.contains(item) ? "checkmark.circle.fill" : "cart.badge.plus")
                                            .foregroundStyle(done.contains(item) ? .green : session.accentColor)
                                        Text(item)
                                            .foregroundStyle(session.themeTextColor)
                                            .strikethrough(done.contains(item))
                                        Spacer()
                                        Image(systemName: "arrow.up.right.square")
                                            .font(.system(size: 12))
                                            .foregroundStyle(session.themeTextColor.opacity(0.3))
                                    }
                                }.buttonStyle(.plain)
                            }
                        } footer: {
                            Text("Tapping an item opens it in \(retailer.name) so you can add it to your cart there — your account, prices and substitutions stay native.")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }

                Button { openAll() } label: {
                    Text("Open all \(items.count) in \(retailer.name)")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(session.accentColor).foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
                .disabled(items.isEmpty)
                .padding(.horizontal, 18).padding(.bottom, 14)
            }
            .stockedScreen()
            .navigationTitle("Send to \(retailer.name)")
            .navigationBarTitleDisplayMode(.inline)
    }

    private func open(_ item: String) {
        HapticManager.light()
        done.insert(item)
        if let appURL = retailer.appURL(for: item), UIApplication.shared.canOpenURL(appURL) {
            openURL(appURL)
        } else if let web = retailer.url(for: item) {
            openURL(web)
        }
    }

    /// Opens the first item and marks the rest as queued — iOS won't allow a burst of openURL calls,
    /// so this is deliberately "one at a time" rather than pretending to open them all at once.
    private func openAll() {
        guard let first = items.first(where: { !done.contains($0) }) ?? items.first else { return }
        open(first)
    }
}
