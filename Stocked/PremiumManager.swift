// PremiumManager.swift
// ─────────────────────────────────────────────────────────────────────────────
// SCAFFOLDING for Household Sync as a premium feature (ticket: For You / Global).
//
// Design intent (per request):
//   • Household Sync becomes a paid feature.
//   • The household OWNER purchases it ONCE; everyone else in that household gets it
//     for free (the owner's entitlement covers the household).
//
// This file is intentionally a STUB so the UI can be built and the flow designed now,
// with real StoreKit 2 dropped in later. Nothing here charges money or talks to the
// App Store yet. The `isHouseholdSyncUnlocked` flag is currently driven by a local
// UserDefaults toggle (for testing) plus a placeholder for "I'm a member of a household
// whose owner already paid."
//
// ── WHAT'S LEFT FOR REAL STOREKIT (later build) ──────────────────────────────
//   1. Add a StoreKit product (e.g. "com.stocked.householdsync") in App Store Connect.
//   2. Replace `purchaseHouseholdSync()` with a real Product.purchase() flow.
//   3. Observe Transaction.updates / currentEntitlements to set `ownerPurchased`.
//   4. Implement restorePurchases() via AppStore.sync().
//   5. OWNER→MEMBER propagation: when the owner buys, publish an entitlement flag into
//      the shared CloudKit household record so members read it as `householdCoversMe`.
//      (Apple IAP is per-Apple-ID, so cross-account unlock must go through our own
//      shared record, NOT StoreKit.)
// ─────────────────────────────────────────────────────────────────────────────

import Foundation
import Observation
import StoreKit

@MainActor
@Observable
final class PremiumManager {
    static let shared = PremiumManager()

    /// StoreKit product identifier — must match the product created in App Store Connect.
    static let householdSyncProductID = "com.stocked.householdsync"

    /// The owner bought the upgrade on THIS Apple ID (derived from StoreKit entitlements,
    /// mirrored to UserDefaults so the gate is correct instantly at launch / offline).
    private(set) var ownerPurchased: Bool {
        didSet { UserDefaults.standard.set(ownerPurchased, forKey: "premium_ownerPurchased") }
    }

    /// A household I belong to is already covered by its owner's purchase. Set by the household
    /// layer from the shared CloudKit record (Apple IAP is per-Apple-ID, so cross-account unlock
    /// rides our own shared record, not StoreKit).
    var householdCoversMe: Bool {
        didSet { UserDefaults.standard.set(householdCoversMe, forKey: "premium_householdCoversMe") }
    }

    /// The loaded StoreKit product (nil until loadProducts() succeeds). Drives the price label.
    private(set) var product: Product?
    /// Human-readable localized price, e.g. "$4.99". Empty until the product loads.
    var displayPrice: String { product?.displayPrice ?? "" }

    private var updatesTask: Task<Void, Never>?

    private init() {
        ownerPurchased    = UserDefaults.standard.bool(forKey: "premium_ownerPurchased")
        householdCoversMe = UserDefaults.standard.bool(forKey: "premium_householdCoversMe")
        // Listen for transactions that arrive outside an explicit purchase (renewals on other
        // devices, Ask-to-Buy approvals, restores). Must be started ASAP per StoreKit 2 docs.
        updatesTask = Task { [weak self] in
            for await update in StoreKit.Transaction.updates {
                await self?.handle(verification: update)
            }
        }
        Task { await refreshEntitlements() }
    }

    // No deinit cancellation needed: PremiumManager is a process-lifetime singleton
    // (static let shared) and the Transaction.updates listener is meant to run for the whole
    // session. (A deinit can't touch the @MainActor-isolated updatesTask anyway under Swift 6.)

    /// Single source of truth the UI checks before allowing Household Sync.
    var isHouseholdSyncUnlocked: Bool { ownerPurchased || householdCoversMe }

    // MARK: - Product loading

    /// Loads the product so the paywall can show a real localized price. Safe to call repeatedly.
    func loadProducts() async {
        do {
            let products = try await Product.products(for: [Self.householdSyncProductID])
            product = products.first
        } catch {
            // Non-fatal: the paywall still works, it just shows "—" until a retry succeeds.
            product = nil
        }
    }

    // MARK: - Purchase (StoreKit 2)

    enum PurchaseResult { case success, cancelled, pending, failed(String) }

    func purchaseHouseholdSync() async -> PurchaseResult {
        // Make sure we have the product (the paywall may call purchase before load finishes).
        if product == nil { await loadProducts() }
        guard let product else { return .failed("Product unavailable. Check your connection and try again.") }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                await handle(verification: verification)
                return ownerPurchased ? .success : .failed("Could not verify the purchase.")
            case .userCancelled:
                return .cancelled
            case .pending:
                return .pending          // Ask-to-Buy / SCA — resolves later via Transaction.updates
            @unknown default:
                return .failed("Unknown purchase state.")
            }
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Restore: re-sync with the App Store, then re-derive entitlements.
    func restorePurchases() async {
        try? await AppStore.sync()
        await refreshEntitlements()
    }

    // MARK: - Entitlements

    /// Recomputes ownerPurchased from the current StoreKit entitlements.
    func refreshEntitlements() async {
        var owns = false
        for await result in StoreKit.Transaction.currentEntitlements {
            if case .verified(let t) = result,
               t.productID == Self.householdSyncProductID,
               t.revocationDate == nil {
                owns = true
            }
        }
        ownerPurchased = owns
    }

    /// Verifies a transaction result, sets entitlement, and finishes the transaction.
    private func handle(verification: VerificationResult<StoreKit.Transaction>) async {
        guard case .verified(let transaction) = verification else { return }  // drop unverified
        if transaction.productID == Self.householdSyncProductID,
           transaction.revocationDate == nil {
            ownerPurchased = true
        }
        await transaction.finish()
    }

    // MARK: - Test helpers (debug only)
    #if DEBUG
    func _devReset() {
        ownerPurchased = false
        householdCoversMe = false
    }
    #endif
}

// MARK: - Household Sync paywall (upsell)
// Shown when a user without the entitlement taps Household Sync. Explains the "owner buys
// once for the whole household" model. The purchase button currently calls the STUB.
import SwiftUI

struct HouseholdPaywallView: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    var onUnlocked: () -> Void = {}

    @State private var purchasing = false
    @State private var errorText: String?

    private let premium = PremiumManager.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    Image(systemName: "person.2.badge.key.fill")
                        .font(.system(size: 52)).foregroundStyle(Color.stockedGold)
                        .padding(.top, 20)
                    Text("Household Sync")
                        .font(.system(size: 26, weight: .bold, design: .serif))
                        .foregroundStyle(session.themeTextColor)
                    Text("Share one kitchen across your whole family — each person uses their own Apple ID, and everyone sees the same pantry and grocery list in real time.")
                        .font(.system(size: 15))
                        .foregroundStyle(session.themeTextColor.opacity(0.7))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 8)

                    VStack(alignment: .leading, spacing: 14) {
                        benefitRow("checkmark.circle.fill", "One purchase covers your whole household")
                        benefitRow("person.3.fill", "Family members join free — they never pay")
                        benefitRow("arrow.triangle.2.circlepath", "Live two-way sync of pantry & grocery list")
                        benefitRow("icloud.fill", "Backed by iCloud — private to your household")
                    }
                    .padding(18)
                    .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 4)

                    Text("Only the household owner needs to buy this. Once you do, everyone you invite gets Household Sync at no extra cost.")
                        .font(.system(size: 12))
                        .foregroundStyle(session.themeTextColor.opacity(0.5))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)

                    if let errorText {
                        Text(errorText).font(.system(size: 12)).foregroundStyle(.red)
                    }

                    Button {
                        Task {
                            purchasing = true; errorText = nil
                            let result = await premium.purchaseHouseholdSync()
                            purchasing = false
                            switch result {
                            case .success: dismiss(); onUnlocked()
                            case .cancelled: break
                            case .pending: errorText = "Purchase pending approval."
                            case .failed(let m): errorText = m
                            }
                        }
                    } label: {
                        HStack {
                            if purchasing { ProgressView().tint(.white) }
                            Text(purchasing ? "Processing…" : "Unlock Household Sync")
                                .font(.system(size: 16, weight: .semibold))
                        }
                        .foregroundStyle(Color.stockedWhite)
                        .frame(maxWidth: .infinity).padding(.vertical, 15)
                        .background(session.themeButtonColor)
                        .clipShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(purchasing)
                    .padding(.horizontal, 4)

                    Button("Restore Purchase") {
                        Task { await premium.restorePurchases()
                            if premium.isHouseholdSyncUnlocked { dismiss(); onUnlocked() } }
                    }
                    .font(.system(size: 13)).foregroundStyle(Color.stockedGold)

                    // Real localized price from StoreKit once the product loads.
                    Text(premium.displayPrice.isEmpty
                         ? "Pricing shown at checkout."
                         : "\(premium.displayPrice) · one-time purchase")
                        .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                        .padding(.bottom, 24)
                }
                .padding(20)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .task { await premium.loadProducts() }
            .navigationTitle("Premium")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.foregroundStyle(session.themeTextColor.opacity(0.6))
                }
            }
        }
    }

    private func benefitRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 16)).foregroundStyle(Color.stockedGreen).frame(width: 24)
            Text(text).font(.system(size: 14)).foregroundStyle(session.themeTextColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
    }
}
