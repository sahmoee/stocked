import Foundation
import Observation
import Security
import StoreKit
import SwiftUI

/// Archived until the App Store products and server verification credentials are ready.
/// Keeping this as one explicit switch preserves the complete implementation without
/// exposing an unavailable storefront during normal development builds.
nonisolated enum AICreditStorefront {
    static let isEnabled = false
}

@MainActor @Observable
final class AICreditStore {
    static let shared = AICreditStore()
    static let productIDs = ["com.sowens.stocked.ai.199", "com.sowens.stocked.ai.499", "com.sowens.stocked.ai.999", "com.sowens.stocked.ai.2499"]
    private(set) var products: [Product] = []
    private(set) var balanceCents = 0
    private(set) var isWorking = false
    var message: String?
    let accountID: UUID
    private var updatesTask: Task<Void, Never>?

    private init() {
        accountID = Self.loadAccountID(service: "com.sowens.Stocked.ai-credits")
        updatesTask = Task { [weak self] in
            for await result in StoreKit.Transaction.updates { await self?.process(result) }
        }
    }
    func load() async {
        do {
            products = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
            await refreshBalance()
        } catch { message = error.localizedDescription }
    }
    func purchase(_ product: Product) async {
        isWorking = true; defer { isWorking = false }
        do {
            switch try await product.purchase(options: [.appAccountToken(accountID)]) {
            case .success(let result): await process(result)
            case .pending: message = "Purchase is waiting for approval. Credits appear automatically after Apple approves it."
            case .userCancelled: break
            @unknown default: message = "The App Store returned an unknown purchase state."
            }
        } catch { message = error.localizedDescription }
    }
    func refreshBalance() async {
        guard let url = URL(string: BuildConfig.receiptWorkerURL)?.appending(path: "_ai/credits/balance") else { return }
        var request = URLRequest(url: url); Self.applyAccount(to: &request)
        if let (data, response) = try? await URLSession.shared.data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
           let value = try? JSONDecoder().decode(Balance.self, from: data) { balanceCents = value.balanceCents }
    }
    nonisolated static func applyAccount(to request: inout URLRequest) {
        request.setValue(loadAccountID(service: "com.sowens.Stocked.ai-credits").uuidString.lowercased(), forHTTPHeaderField: "X-AI-Credit-Account")
    }
    private func process(_ result: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = result, Self.productIDs.contains(transaction.productID) else { message = "Apple could not verify this purchase."; return }
        guard let url = URL(string: BuildConfig.receiptWorkerURL)?.appending(path: "_ai/credits/redeem") else { return }
        var request = URLRequest(url: url); request.httpMethod = "POST"; Self.applyAccount(to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(Redeem(transactionId: String(transaction.id), productId: transaction.productID))
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { message = (try? JSONDecoder().decode(APIError.self, from: data).error) ?? "Credits could not be verified yet. They will retry automatically."; return }
            balanceCents = (try JSONDecoder().decode(Balance.self, from: data)).balanceCents
            await transaction.finish()
            message = "AI credits added."
        } catch { message = "Credits could not be verified yet. They will retry automatically." }
    }
    private nonisolated static func loadAccountID(service: String) -> UUID {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "account", kSecAttrSynchronizable as String: kSecAttrSynchronizableAny, kSecReturnData as String: true]
        var item: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) { return id }
        let id = UUID(); var add = query; add.removeValue(forKey: kSecReturnData as String); add[kSecAttrSynchronizable as String] = true; add[kSecValueData as String] = Data(id.uuidString.utf8); add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock; SecItemAdd(add as CFDictionary, nil); return id
    }
    private struct Redeem: Encodable { let transactionId: String; let productId: String }
    private struct Balance: Decodable { let balanceCents: Int }
    private struct APIError: Decodable { let error: String }
}

struct AICreditStoreView: View {
    @Environment(AppSession.self) private var session
    private let store = AICreditStore.shared
    var body: some View {
        List {
            Section("Your managed AI balance") {
                Text("$\(Double(store.balanceCents) / 100, specifier: "%.2f") of AI service")
                    .font(.title2.bold())
                Text("About \(store.balanceCents) quick requests, \(store.balanceCents / 3) standard requests, or \(store.balanceCents / 10) advanced requests. Actual use depends on the action; you always see the remaining balance.")
                    .font(.caption)
            }
            Section("Add AI credits") {
                ForEach(store.products, id: \.id) { product in
                    Button { Task { await store.purchase(product) } } label: {
                        HStack { VStack(alignment: .leading) { Text(product.displayName); Text(Self.detail(product.id)).font(.caption) }; Spacer(); Text(product.displayPrice).bold() }
                    }.disabled(store.isWorking)
                }
                if store.products.isEmpty { Text("Products will appear after they are approved in App Store Connect.").font(.caption) }
            }
            Section("How it works") {
                Text("This is a consumable purchase. Apple processes the payment; the app receives managed AI credits only after the Worker verifies the transaction with Apple. Quick tasks cost about 1¢, standard tasks 3¢, and advanced generation 10¢. Failed requests are not charged. Credits do not expire.")
                Text("The purchase price includes App Store fees, service operation, and a reserve for changing model prices. It is not cash and cannot be withdrawn or transferred.").font(.caption)
            }
            if let message = store.message { Text(message) }
        }
        .scrollContentBackground(.hidden).background(session.backgroundView.ignoresSafeArea())
        .navigationTitle("AI Credits").task { await store.load() }.refreshable { await store.load() }
    }
    private static func detail(_ id: String) -> String {
        if id.hasSuffix("199") { return "$1.25 AI balance · roughly 41 standard requests" }
        if id.hasSuffix("499") { return "$3.50 AI balance · roughly 116 standard requests" }
        if id.hasSuffix("999") { return "$7.50 AI balance · roughly 250 standard requests" }
        return "$20 AI balance · roughly 666 standard requests"
    }
}
