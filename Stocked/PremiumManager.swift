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

@Observable
final class PremiumManager {
    static let shared = PremiumManager()

    // Product identifier reserved for the real StoreKit product (not yet live).
    static let householdSyncProductID = "com.stocked.householdsync"

    // The owner bought the upgrade on THIS Apple ID. (Stub: persisted locally for testing.)
    private(set) var ownerPurchased: Bool {
        didSet { UserDefaults.standard.set(ownerPurchased, forKey: "premium_ownerPurchased") }
    }

    // A household I belong to is already covered by its owner's purchase. (Stub: set by the
    // household layer once the shared-record entitlement flag exists.)
    var householdCoversMe: Bool {
        didSet { UserDefaults.standard.set(householdCoversMe, forKey: "premium_householdCoversMe") }
    }

    private init() {
        ownerPurchased   = UserDefaults.standard.bool(forKey: "premium_ownerPurchased")
        householdCoversMe = UserDefaults.standard.bool(forKey: "premium_householdCoversMe")
    }

    /// Single source of truth the UI checks before allowing Household Sync.
    var isHouseholdSyncUnlocked: Bool { ownerPurchased || householdCoversMe }

    // MARK: - Purchase (STUB — replace with StoreKit 2)
    enum PurchaseResult { case success, cancelled, pending, failed(String) }

    /// Placeholder purchase. Real implementation will call Product.purchase() and verify the
    /// transaction. For now this immediately "unlocks" so the gated UI can be exercised in test.
    @MainActor
    func purchaseHouseholdSync() async -> PurchaseResult {
        // TODO(StoreKit): real purchase + verification here.
        ownerPurchased = true
        return .success
    }

    /// Placeholder restore. Real implementation will call AppStore.sync() then re-check entitlements.
    @MainActor
    func restorePurchases() async {
        // TODO(StoreKit): AppStore.sync(); refresh currentEntitlements.
    }

    // MARK: - Test helpers (remove with real StoreKit)
    func _devReset() {
        ownerPurchased = false
        householdCoversMe = false
    }
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

                    // NOTE: pricing shown here will come from the StoreKit product once live.
                    Text("Pricing shown at checkout.")
                        .font(.system(size: 11)).foregroundStyle(session.themeTextColor.opacity(0.4))
                        .padding(.bottom, 24)
                }
                .padding(20)
            }
            .background(session.themeBgColor.ignoresSafeArea())
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
