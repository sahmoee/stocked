// PurchaseDedupReviewView.swift — RL-007 duplicate-purchase review sheet.
//
// The last stop before flagged items enter inventory. Callers (receipt scanner,
// grocery "move to pantry") run PurchaseDedupEngine first; when it flags likely
// duplicates they present this sheet instead of importing silently. Each flagged
// line shows the matching evidence in plain language and offers three choices:
//
//   Skip      — it's a duplicate; the line never enters inventory.  (default)
//   Merge     — same physical purchase; refresh the existing row's details
//               without double-counting quantity.
//   Keep Both — a real second purchase; import normally (quantities sum).
//
// Unflagged items are summarized below so the user sees the whole import before
// confirming — nothing slips in without a final look. The sheet mutates nothing
// itself; it hands the per-item resolutions back to the caller, which owns the
// actual store writes (one code path per import surface).

import SwiftUI

// MARK: - Presentation context

/// Everything the sheet needs, bundled so callers can drive it from a single
/// `.sheet(item:)` case (avoids the stacked-.sheet pitfall noted in GroceryListView).
struct PurchaseDupReviewContext: Identifiable {
    let id = UUID()
    var title: String                                  // "Receipt Import" / "Move to Pantry"
    var candidates: [PurchaseImportCandidate]          // the full accepted-for-import set
    var flags: [UUID: PurchaseDupFlag]                 // candidateID → duplicate evidence
}

// MARK: - Review sheet

struct PurchaseDedupReviewView: View {
    @Environment(AppSession.self) var session
    let context: PurchaseDupReviewContext
    var onCommit: ([UUID: PurchaseDupResolution]) -> Void
    var onCancel: () -> Void

    // Flagged lines default to Skip: the safe reading of "we've seen this purchase" is
    // to not double-count, and Keep Both is one tap away for real re-buys.
    @State private var resolutions: [UUID: PurchaseDupResolution] = [:]
    @State private var seeded = false

    private var dark: Bool { session.isDarkMode }
    private var flagged: [PurchaseImportCandidate] {
        context.candidates.filter { context.flags[$0.id] != nil }
    }
    private var clean: [PurchaseImportCandidate] {
        context.candidates.filter { context.flags[$0.id] == nil }
    }
    /// How many lines will actually create/refresh inventory after the choices.
    private var importCount: Int {
        clean.count + flagged.filter { (resolutions[$0.id] ?? .skip) != .skip }.count
    }

    var body: some View {
        NavigationStack {
            ZStack {
                session.themeBgColor.ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text("Looks like some of this was already added")
                        .scaledFont(21, weight: .bold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text("These items match a recent import. Skip duplicates, merge details, or keep both if you really bought it twice.")
                        .scaledFont(13)
                        .foregroundStyle(session.themeTextColor.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)

                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 10) {
                            ForEach(flagged) { candidate in
                                flaggedRow(candidate)
                            }
                            if !clean.isEmpty {
                                cleanSummary
                            }
                        }
                        .padding(.bottom, 8)
                    }

                    VStack(spacing: 8) {
                        Button {
                            onCommit(resolutions)
                            HapticManager.success()
                        } label: {
                            Text(importCount == 0 ? "Skip All — Add Nothing"
                                                  : "Add \(importCount) Item\(importCount == 1 ? "" : "s")")
                                .scaledFont(15, weight: .semibold, design: .serif)
                                .foregroundStyle(Color.stockedWhite)
                                .frame(maxWidth: .infinity).padding(.vertical, 13)
                                .background(dark ? Color.darkSurface : Color.stockedCharcoal)
                                .overlay(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL)
                                    .stroke(dark ? Color.stockedGold : Color.clear, lineWidth: 1.5))
                                .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusXL))
                        }
                        .buttonStyle(.plain)

                        Button { onCancel() } label: {
                            Text("Cancel — don't import yet")
                                .scaledFont(13.5, weight: .semibold)
                                .foregroundStyle(session.themeTextColor.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 4)
                    }
                }
                .padding(20)
            }
            .navigationTitle(context.title)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .task {
            if !seeded {
                for c in flagged { resolutions[c.id] = .skip }
                seeded = true
            }
        }
    }

    // MARK: Flagged row — evidence + Merge / Keep Both / Skip

    @ViewBuilder
    private func flaggedRow(_ candidate: PurchaseImportCandidate) -> some View {
        let flag = context.flags[candidate.id]
        let choice = resolutions[candidate.id] ?? .skip
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: (flag?.isStrong ?? false) ? "exclamationmark.triangle.fill"
                                                            : "exclamationmark.circle")
                    .scaledFont(14, weight: .semibold)
                    .foregroundStyle(Color.stockedGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayLine(candidate))
                        .scaledFont(14, weight: .semibold)
                        .foregroundStyle(session.themeTextColor)
                    if let flag {
                        Text(flag.evidence)
                            .scaledFont(11.5)
                            .foregroundStyle(session.themeTextColor.opacity(0.55))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
            }
            HStack(spacing: 6) {
                choiceChip("Skip",      .skip,     current: choice, id: candidate.id)
                choiceChip("Merge",     .merge,    current: choice, id: candidate.id)
                choiceChip("Keep Both", .keepBoth, current: choice, id: candidate.id)
            }
            Text(explainer(for: choice))
                .scaledFont(10.5)
                .foregroundStyle(session.themeTextColor.opacity(0.45))
        }
        .padding(12)
        .background(dark ? Color.darkSurface : Color.stockedWhite.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
    }

    private func choiceChip(_ label: String, _ value: PurchaseDupResolution,
                            current: PurchaseDupResolution, id: UUID) -> some View {
        let active = current == value
        return Button {
            resolutions[id] = value
            HapticManager.select()
        } label: {
            Text(label)
                .scaledFont(12, weight: .bold)
                .foregroundStyle(active ? Color.stockedWhite
                                        : session.themeTextColor.opacity(0.65))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(active ? Color.stockedCharcoal
                                   : (dark ? Color.white.opacity(0.08) : Color.stockedWhite.opacity(0.6)))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .a11yButton("\(label) for this item")
    }

    private func explainer(for choice: PurchaseDupResolution) -> String {
        switch choice {
        case .skip:     return "Won't be added — inventory stays as it is."
        case .merge:    return "Updates the existing item's details without adding quantity."
        case .keepBoth: return "Adds it again — total quantity goes up."
        }
    }

    // MARK: Clean items summary — the "final review" of everything unflagged

    private var cleanSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Image(systemName: "checkmark.circle")
                    .scaledFont(13, weight: .semibold)
                    .foregroundStyle(Color.stockedGreen)
                Text("Also adding · \(clean.count)")
                    .scaledFont(13, weight: .bold)
                    .foregroundStyle(session.themeTextColor)
            }
            Text(clean.map { displayLine($0) }.joined(separator: " · "))
                .scaledFont(11.5)
                .foregroundStyle(session.themeTextColor.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(dark ? Color.darkSurface.opacity(0.6) : Color.stockedWhite.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: StockedUI.cornerRadiusSm))
    }

    private func displayLine(_ c: PurchaseImportCandidate) -> String {
        var s = c.name.displayNormalized
        if c.quantity > 1 { s += " ×\(c.quantity)" }
        if !c.store.isEmpty { s += " (\(c.store))" }
        return s
    }
}

// MARK: - Merge applier (shared by both import surfaces)

/// The one implementation of "Merge": same physical purchase seen twice, so refresh the
/// existing inventory row's package/price/store details and confirm it — but do NOT bump
/// quantity, which is exactly the double-count RL-007 exists to prevent. Uses the store's
/// public arrays/mutators only, so sync and logging behave like any other edit.
enum PurchaseImportMerge {
    static func refreshExisting(in store: GuestDataStore,
                                name: String,
                                price: Double? = nil,
                                storeName: String? = nil,
                                brand: String? = nil,
                                expiry: Date? = nil,
                                sizeAmount: Double? = nil,
                                sizeUnit: String? = nil,
                                origin: InventoryProposalOrigin = .groceryTransfer) {
        let key = PurchaseDedupEngine.normalizedName(name)
        guard !key.isEmpty,
              let idx = store.inventoryItems.firstIndex(where: {
                  PurchaseDedupEngine.normalizedName($0.name) == key
              }) else { return }
        let existing = store.inventoryItems[idx]
        let provenance = FieldProvenance(sourceID: "\(origin.rawValue)-dedup-merge",
                                         sourceName: "Purchase duplicate review",
                                         badge: origin.defaultBadge)
        var fields: [InventoryProposalField: FieldProvenance] = [:]
        if price != nil { fields[.price] = provenance }
        if storeName?.isEmpty == false { fields[.store] = provenance }
        if brand?.isEmpty == false { fields[.brand] = provenance }
        if sizeAmount != nil, sizeUnit != nil { fields[.size] = provenance }
        if expiry != nil { fields[.expiry] = provenance }
        let proposal = ProposedChange(
            itemID: existing.id,
            displayName: existing.name,
            action: .refreshMetadata(InventoryMetadataRefresh(
                price: price, storeName: storeName, brand: brand, expiry: expiry,
                sizeAmount: sizeAmount, sizeUnit: sizeUnit
            )),
            reason: "Confirmed during duplicate purchase review",
            sourceBadge: origin.defaultBadge,
            fieldProvenance: fields
        )
        let batch = InventoryProposalBatch(
            origin: origin,
            title: "Refresh \(existing.name)",
            changes: [proposal],
            mergePolicy: .storeCompatible
        )
        store.applyProposalBatch(
            batch,
            brandPreferences: store.cookingProfile.brandPreferences,
            retailerID: storeName.flatMap { GroceryKnowledgeBase.retailer(matching: $0)?.id }
        )
    }
}
