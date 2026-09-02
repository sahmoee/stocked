// InventoryChangeProposal.swift
// ─────────────────────────────────────────────────────────────────────────────
// Shared "apply inventory changes" primitive used by THREE features:
//   1. Decrement     — after cooking / when an item ages out, propose using it up.
//   2. Drift-correct  — "do you still have these?" reconciliation for stale items.
//   3. Conversational — "I used the rest of the broccoli" parsed (via Worker) into changes.
//
// All three produce a [ProposedChange]; the user confirms/rejects each in ReconcileSheet;
// confirmed changes are applied through the EXISTING GuestDataStore mutators
// (updateInventoryLevel / removeInventoryItem / addInventoryItem) so there's one code path
// for actually touching inventory.
// ─────────────────────────────────────────────────────────────────────────────

import SwiftUI

// MARK: - Model

nonisolated enum InventoryProposalOrigin: String, Codable, Sendable {
    case manual
    case receipt
    case barcode
    case reconciliation
    case groceryTransfer
    case assistant
    case household
    case importService

    var defaultBadge: SourceBadge {
        switch self {
        case .manual: return .userAdded
        case .barcode: return .verified
        case .receipt, .assistant, .importService: return .aiParsed
        case .reconciliation, .groceryTransfer, .household: return .estimated
        }
    }
}

/// Canonical product merging is the preferred review behavior. Existing direct-add surfaces can
/// opt into the compatibility policy while migrating, preserving `GuestDataStore.isSameItem`
/// unit/name semantics while still gaining identity, provenance, activity, and transaction undo.
nonisolated enum InventoryProposalMergePolicy: Equatable, Sendable {
    case canonicalProduct
    case storeCompatible
}

nonisolated enum InventoryProposalField: String, Codable, CaseIterable, Sendable {
    case name, brand, quantity, containerType, size, storageCategory, aisle, barcode
    case price, store, expiry, nutrition
}

nonisolated struct InventoryProposalProduct: Equatable, Sendable {
    var identity: ProductIdentity
    var displayName: String
    var brand: String?
    var storageCategory: StorageCategory?
    var aisle: GroceryAisle
    var barcode: String?
    var resolutionConfidence: Double
}

nonisolated struct InventoryProposalIssue: Identifiable, Equatable, Sendable {
    var code: String
    var message: String
    var field: InventoryProposalField?
    var id: String { "\(code):\(field?.rawValue ?? "batch")" }
}

nonisolated struct InventoryFieldAlternative: Identifiable, Equatable, Sendable {
    var field: InventoryProposalField
    var displayValue: String
    var provenance: FieldProvenance
    var id: String { "\(field.rawValue):\(provenance.sourceID):\(displayValue)" }
}

/// Provider-neutral evidence payload for one inventory addition. Each source contributes only the
/// fields it actually knows; the shared reconciler chooses winners and keeps conflicts reviewable.
nonisolated struct InventoryAddEvidence: Sendable {
    var names: [FieldEvidence<String>]
    var brands: [FieldEvidence<String>]
    var quantities: [FieldEvidence<Int>]
    var containerTypes: [FieldEvidence<String>]
    var storageCategories: [FieldEvidence<StorageCategory>]
    var aisles: [FieldEvidence<GroceryAisle>]
    var barcodes: [FieldEvidence<String>]

    init(names: [FieldEvidence<String>], brands: [FieldEvidence<String>] = [],
         quantities: [FieldEvidence<Int>] = [], containerTypes: [FieldEvidence<String>] = [],
         storageCategories: [FieldEvidence<StorageCategory>] = [],
         aisles: [FieldEvidence<GroceryAisle>] = [],
         barcodes: [FieldEvidence<String>] = []) {
        self.names = names
        self.brands = brands
        self.quantities = quantities
        self.containerTypes = containerTypes
        self.storageCategories = storageCategories
        self.aisles = aisles
        self.barcodes = barcodes
    }
}

/// A duplicate-import merge refreshes facts without increasing quantity. Keeping this as an
/// explicit proposal action makes receipt and grocery dedup writes reviewable/undoable without
/// disguising them as a level or quantity edit.
nonisolated struct InventoryMetadataRefresh: Equatable, Sendable {
    var price: Double?
    var storeName: String?
    var brand: String?
    var expiry: Date?
    var sizeAmount: Double?
    var sizeUnit: String?
    var confirmsPresence: Bool

    init(price: Double? = nil, storeName: String? = nil, brand: String? = nil,
         expiry: Date? = nil, sizeAmount: Double? = nil, sizeUnit: String? = nil,
         confirmsPresence: Bool = true) {
        self.price = price
        self.storeName = storeName
        self.brand = brand
        self.expiry = expiry
        self.sizeAmount = sizeAmount
        self.sizeUnit = sizeUnit
        self.confirmsPresence = confirmsPresence
    }
}

nonisolated enum InventoryChangeAction: Equatable, Sendable {
    case remove                 // set to empty / remove the row
    case setLevel(Double)       // reduce (or set) the fill level 0.0–1.0
    // New item the user bought. Carries the parsed quantity (number of containers) plus the
    // optional container type ("can", "bag") and pack size ("24 oz"), so "bought 3 cans of
    // black beans" and "got a 12 oz bag of rice" record the same detail a manual add would.
    case add(name: String, quantity: Int, containerType: String?, sizeAmount: Double?, sizeUnit: String?)
    // Change the quantity of an existing item by a signed delta ("used 2 cans" → -2).
    case adjustQuantity(delta: Int)
    case refreshMetadata(InventoryMetadataRefresh)
    case clearAll               // remove every inventory item (destructive; always needs confirm)
}

nonisolated struct ProposedChange: Identifiable, Equatable, Sendable {
    let id = UUID()
    var itemID: UUID?           // existing inventory item (nil for .add)
    var displayName: String     // what to show the user
    var action: InventoryChangeAction
    var reason: String          // short why ("Used while cooking", "You said you finished it")
    var isConfirmed: Bool = true  // pre-checked; user can toggle off
    /// Provenance of this proposed change, so the shared review UI can badge it and so an
    /// applied .add carries its badge into inventory. nil for changes to existing items where
    /// provenance is unchanged (remove / setLevel).
    var sourceBadge: SourceBadge? = nil
    /// Canonical product metadata shared by receipt, barcode, manual, and reconciliation adds.
    /// Existing callers can continue constructing `ProposedChange` without it.
    var product: InventoryProposalProduct? = nil
    /// Winning source for every populated field; alternatives remain available through the
    /// reconciler before this review proposal is created.
    var fieldProvenance: [InventoryProposalField: FieldProvenance] = [:]
    var fieldAlternatives: [InventoryProposalField: [InventoryFieldAlternative]] = [:]
    var reviewIssues: [InventoryProposalIssue] = []
    /// Exact add payload from an already-established production flow. The action remains the
    /// review summary/quantity contract; this template preserves expiry, nutrition, price, store,
    /// and other metadata that cannot be flattened into that summary.
    var addTemplate: LocalInventoryItem? = nil

    /// One-line human summary of the effect.
    var effectText: String {
        switch action {
        case .remove:             return "Remove \(displayName)"
        case .setLevel(let l):    return "\(displayName) → \(Int((l * 100).rounded()))% left"
        case .add(_, let q, let ct, let amt, let unit):
            var s = "Add \(displayName)"
            if q > 1 { s += " ×\(q)" }
            if let ct, !ct.isEmpty, ct != "item" { s += " (\(q > 1 ? ct + "s" : ct)" }
            else if let amt, let unit { s += " (\(amt.clean) \(unit)" }
            if let amt, let unit, let ct, !ct.isEmpty, ct != "item" { s += ", \(amt.clean) \(unit) each" }
            if s.contains("(") && !s.hasSuffix(")") { s += ")" }
            return s
        case .adjustQuantity(let d):
            return d < 0 ? "\(displayName) −\(abs(d))" : "\(displayName) +\(d)"
        case .refreshMetadata:    return "Refresh \(displayName) details"
        case .clearAll:           return "Clear ALL inventory items"
        }
    }
    var iconName: String {
        switch action {
        case .remove:         return "trash"
        case .setLevel:       return "arrow.down.circle"
        case .add:            return "plus.circle"
        case .adjustQuantity(let d): return d < 0 ? "minus.circle" : "plus.circle"
        case .refreshMetadata: return "arrow.triangle.2.circlepath"
        case .clearAll:       return "trash.fill"
        }
    }

    /// Which grouped-review section this change belongs in. clearAll is always surfaced for a
    /// second look; otherwise it follows the badge (defaulting to Confident when unbadged, since
    /// remove/setLevel act on items the user already has).
    var reviewGroup: ReviewGroup {
        if case .clearAll = action { return .needsReview }
        if !reviewIssues.isEmpty { return .needsReview }
        return sourceBadge?.reviewGroup ?? .confident
    }
}

// MARK: - Unified reviewable proposal batch

nonisolated struct InventoryProposalBatch: Identifiable, Equatable, Sendable {
    var id: UUID
    var origin: InventoryProposalOrigin
    var title: String
    var createdAt: Date
    var changes: [ProposedChange]
    var mergePolicy: InventoryProposalMergePolicy

    init(id: UUID = UUID(), origin: InventoryProposalOrigin, title: String,
         createdAt: Date = Date(), changes: [ProposedChange],
         mergePolicy: InventoryProposalMergePolicy = .canonicalProduct) {
        self.id = id
        self.origin = origin
        self.title = title
        self.createdAt = createdAt
        self.changes = changes
        self.mergePolicy = mergePolicy
    }

    var confirmedCount: Int { changes.filter(\.isConfirmed).count }
    var needsReviewCount: Int { changes.filter { $0.reviewGroup == .needsReview }.count }

    /// Resolve identity, attach provenance, merge duplicate additions, and convert an add that is
    /// already in inventory into a quantity adjustment. This remains pure: review UI can inspect
    /// the returned batch before applying anything.
    func canonicalized(against inventory: [LocalInventoryItem],
                       brandPreferences: BrandPreferences = BrandPreferences(),
                       retailerID: String? = nil) -> InventoryProposalBatch {
        var passthrough: [ProposedChange] = []
        var existingAdjustmentOrder: [UUID] = []
        var existingAdjustments: [UUID: ProposedChange] = [:]
        var additionOrder: [String] = []
        var additions: [String: ProposedChange] = [:]

        for original in changes {
            guard case let .add(name, quantity, containerType, sizeAmount, sizeUnit) = original.action else {
                passthrough.append(original)
                continue
            }
            var change = original
            let resolution = ProductCatalog.resolve(ProductResolutionContext(
                rawName: name,
                brand: change.product?.brand,
                barcode: change.product?.barcode,
                retailerID: retailerID,
                preferredBrands: brandPreferences.preferredBrands,
                avoidedBrands: brandPreferences.avoidedBrands
            ))
            if change.product == nil {
                change.product = InventoryProposalProduct(
                    identity: resolution.identity,
                    displayName: name,
                    brand: !resolution.needsReview && resolution.confidence >= 0.94
                        ? resolution.brand : nil,
                    storageCategory: resolution.category.flatMap(StorageCategory.init(rawValue:)),
                    aisle: resolution.aisle,
                    barcode: resolution.identity.namespace == .barcode ? resolution.identity.key : nil,
                    resolutionConfidence: resolution.confidence
                )
            }
            let badge = change.sourceBadge ?? origin.defaultBadge
            change.sourceBadge = badge
            let defaultProvenance = FieldProvenance(sourceID: origin.rawValue, badge: badge,
                                                    observedAt: createdAt)
            let catalogProvenance = FieldProvenance(sourceID: "product-catalog",
                                                     sourceName: "Stocked product catalog",
                                                     badge: .estimated,
                                                     observedAt: createdAt)
            for field in [InventoryProposalField.name, .quantity, .containerType, .size] {
                if change.fieldProvenance[field] == nil { change.fieldProvenance[field] = defaultProvenance }
            }
            if change.product?.brand != nil, change.fieldProvenance[.brand] == nil {
                change.fieldProvenance[.brand] = catalogProvenance
            }
            if change.product?.storageCategory != nil, change.fieldProvenance[.storageCategory] == nil {
                change.fieldProvenance[.storageCategory] = catalogProvenance
            }
            if change.fieldProvenance[.aisle] == nil { change.fieldProvenance[.aisle] = catalogProvenance }
            if change.product?.barcode != nil, change.fieldProvenance[.barcode] == nil {
                change.fieldProvenance[.barcode] = defaultProvenance
            }
            if resolution.needsReview,
               !change.reviewIssues.contains(where: { $0.code == "ambiguous-product" }) {
                change.reviewIssues.append(InventoryProposalIssue(
                    code: "ambiguous-product",
                    message: "Confirm the product match before adding it.",
                    field: .name
                ))
            }

            if mergePolicy == .storeCompatible {
                passthrough.append(change)
                continue
            }

            let identity = change.product?.identity ?? resolution.identity
            if let existing = inventory.first(where: {
                let existingIdentity = $0.productIdentity
                if identity.namespace == .barcode || existingIdentity.namespace == .barcode {
                    return identity.stableKey == existingIdentity.stableKey
                }
                return !identity.canonicalName.isEmpty
                    && identity.canonicalName == existingIdentity.canonicalName
            }) {
                change.itemID = existing.id
                change.displayName = existing.name
                change.action = .adjustQuantity(delta: max(1, quantity))
                change.reason = "Already in inventory — add to its quantity"
                if var prior = existingAdjustments[existing.id],
                   case let .adjustQuantity(priorDelta) = prior.action {
                    prior.action = .adjustQuantity(delta: priorDelta + max(1, quantity))
                    prior.isConfirmed = prior.isConfirmed && change.isConfirmed
                    prior.reviewIssues.append(contentsOf: change.reviewIssues.filter { !prior.reviewIssues.contains($0) })
                    for (field, candidates) in change.fieldAlternatives {
                        var merged = prior.fieldAlternatives[field] ?? []
                        merged.append(contentsOf: candidates.filter { !merged.contains($0) })
                        prior.fieldAlternatives[field] = merged
                    }
                    existingAdjustments[existing.id] = prior
                } else {
                    existingAdjustmentOrder.append(existing.id)
                    existingAdjustments[existing.id] = change
                }
                continue
            }

            let groupingKey = identity.namespace == .barcode ? identity.stableKey : identity.canonicalName
            let key = groupingKey.isEmpty ? GroceryKnowledgeBase.normalize(name) : groupingKey
            if var prior = additions[key],
               case let .add(priorName, priorQuantity, priorContainer, priorAmount, priorUnit) = prior.action {
                prior.action = .add(name: priorName,
                                    quantity: priorQuantity + max(1, quantity),
                                    containerType: priorContainer ?? containerType,
                                    sizeAmount: priorAmount ?? sizeAmount,
                                    sizeUnit: priorUnit ?? sizeUnit)
                prior.isConfirmed = prior.isConfirmed && change.isConfirmed
                prior.reviewIssues.append(contentsOf: change.reviewIssues.filter { !prior.reviewIssues.contains($0) })
                for (field, provenance) in change.fieldProvenance where prior.fieldProvenance[field] == nil {
                    prior.fieldProvenance[field] = provenance
                }
                for (field, candidates) in change.fieldAlternatives {
                    var merged = prior.fieldAlternatives[field] ?? []
                    merged.append(contentsOf: candidates.filter { !merged.contains($0) })
                    prior.fieldAlternatives[field] = merged
                }
                additions[key] = prior
            } else {
                additionOrder.append(key)
                additions[key] = change
            }
        }

        var result = self
        result.changes = passthrough
            + existingAdjustmentOrder.compactMap { existingAdjustments[$0] }
            + additionOrder.compactMap { additions[$0] }
        return result
    }

    static func reviewableAdd(
        name: String,
        quantity: Int = 1,
        containerType: String? = nil,
        sizeAmount: Double? = nil,
        sizeUnit: String? = nil,
        brand: String? = nil,
        barcode: String? = nil,
        origin: InventoryProposalOrigin,
        sourceID: String? = nil,
        badge: SourceBadge? = nil,
        reason: String
    ) -> ProposedChange {
        let resolution = ProductCatalog.resolve(ProductResolutionContext(
            rawName: name, brand: brand, barcode: barcode
        ))
        let resolvedBadge = badge ?? origin.defaultBadge
        let provenance = FieldProvenance(sourceID: sourceID ?? origin.rawValue,
                                         badge: resolvedBadge)
        let catalogProvenance = FieldProvenance(sourceID: "product-catalog",
                                                sourceName: "Stocked product catalog",
                                                badge: .estimated)
        let product = InventoryProposalProduct(
            identity: resolution.identity,
            displayName: name,
            brand: brand ?? (!resolution.needsReview && resolution.confidence >= 0.94
                             ? resolution.brand : nil),
            storageCategory: resolution.category.flatMap(StorageCategory.init(rawValue:)),
            aisle: resolution.aisle,
            barcode: barcode.flatMap(ProductCatalog.normalizedBarcode),
            resolutionConfidence: resolution.confidence
        )
        let issues = resolution.needsReview
            ? [InventoryProposalIssue(code: "ambiguous-product",
                                      message: "Confirm the product match before adding it.", field: .name)]
            : []
        var fieldProvenance: [InventoryProposalField: FieldProvenance] = [
            .name: provenance, .quantity: provenance, .containerType: provenance,
            .size: provenance, .aisle: catalogProvenance
        ]
        if product.brand != nil { fieldProvenance[.brand] = brand == nil ? catalogProvenance : provenance }
        if product.storageCategory != nil { fieldProvenance[.storageCategory] = catalogProvenance }
        if product.barcode != nil { fieldProvenance[.barcode] = provenance }
        return ProposedChange(
            itemID: nil,
            displayName: name,
            action: .add(name: name, quantity: max(1, quantity), containerType: containerType,
                         sizeAmount: sizeAmount, sizeUnit: sizeUnit),
            reason: reason,
            sourceBadge: resolvedBadge,
            product: product,
            fieldProvenance: fieldProvenance,
            reviewIssues: issues
        )
    }

    /// Lossless adapter for a production flow that already assembled a LocalInventoryItem.
    /// The reviewed/template storage category and explicit brand/barcode remain authoritative;
    /// catalog identity is attached without silently replacing those user-visible fields.
    static func reviewableAdd(
        item: LocalInventoryItem,
        origin: InventoryProposalOrigin,
        sourceID: String? = nil,
        badge: SourceBadge? = nil,
        reason: String
    ) -> ProposedChange {
        var proposal = reviewableAdd(
            name: item.name,
            quantity: item.quantity,
            containerType: item.containerType,
            sizeAmount: item.sizeAmount,
            sizeUnit: item.sizeUnit,
            brand: item.brand,
            barcode: item.barcode,
            origin: origin,
            sourceID: sourceID,
            badge: badge ?? item.sourceBadge,
            reason: reason
        )
        proposal.addTemplate = item
        proposal.product?.displayName = item.name
        proposal.product?.brand = item.brand
        proposal.product?.storageCategory = item.storageCategory
        proposal.product?.barcode = item.barcode.flatMap(ProductCatalog.normalizedBarcode)
        if item.brand == nil { proposal.fieldProvenance.removeValue(forKey: .brand) }
        if item.barcode == nil { proposal.fieldProvenance.removeValue(forKey: .barcode) }
        return proposal
    }

    /// Reconcile a multi-provider draft directly into the review contract. No winner is applied
    /// silently: close conflicts produce field-specific review issues and retain their provenance.
    static func reconciledAdd(
        _ evidence: InventoryAddEvidence,
        sourceHealth: [String: SourceHealthSnapshot] = [:],
        origin: InventoryProposalOrigin,
        reason: String,
        now: Date = Date()
    ) -> ProposedChange? {
        guard let name = ProductFieldReconciler.reconcileText(
            evidence.names, sourceHealth: sourceHealth, now: now
        ) else { return nil }
        let brand = ProductFieldReconciler.reconcileText(
            evidence.brands, sourceHealth: sourceHealth, now: now
        )
        let quantity = ProductFieldReconciler.reconcile(
            evidence.quantities, sourceHealth: sourceHealth, now: now
        )
        let container = ProductFieldReconciler.reconcileText(
            evidence.containerTypes, sourceHealth: sourceHealth, now: now
        )
        let storage = ProductFieldReconciler.reconcile(
            evidence.storageCategories, sourceHealth: sourceHealth, now: now
        )
        let aisle = ProductFieldReconciler.reconcile(
            evidence.aisles, sourceHealth: sourceHealth, now: now
        )
        let barcode = ProductFieldReconciler.reconcileText(
            evidence.barcodes.compactMap { candidate in
                guard let normalized = ProductCatalog.normalizedBarcode(candidate.value) else { return nil }
                return FieldEvidence(normalized, provenance: candidate.provenance)
            },
            sourceHealth: sourceHealth,
            now: now
        )
        var proposal = reviewableAdd(
            name: name.value,
            quantity: max(1, quantity?.value ?? 1),
            containerType: container?.value,
            brand: brand?.value,
            barcode: barcode?.value,
            origin: origin,
            sourceID: name.provenance.sourceID,
            badge: name.provenance.badge,
            reason: reason
        )
        let resolution = ProductCatalog.resolve(ProductResolutionContext(
            rawName: name.value, brand: brand?.value, barcode: barcode?.value
        ))
        proposal.product = InventoryProposalProduct(
            identity: resolution.identity,
            displayName: name.value,
            brand: brand?.value ?? (!resolution.needsReview && resolution.confidence >= 0.94
                                    ? resolution.brand : nil),
            storageCategory: storage?.value
                ?? resolution.category.flatMap(StorageCategory.init(rawValue:)),
            aisle: aisle?.value ?? resolution.aisle,
            barcode: barcode?.value,
            resolutionConfidence: resolution.confidence
        )

        proposal.fieldProvenance[.name] = name.provenance
        if let brand { proposal.fieldProvenance[.brand] = brand.provenance }
        if let quantity { proposal.fieldProvenance[.quantity] = quantity.provenance }
        if let container { proposal.fieldProvenance[.containerType] = container.provenance }
        if let storage { proposal.fieldProvenance[.storageCategory] = storage.provenance }
        if let aisle { proposal.fieldProvenance[.aisle] = aisle.provenance }
        if let barcode { proposal.fieldProvenance[.barcode] = barcode.provenance }

        let alternativeGroups: [(InventoryProposalField, [InventoryFieldAlternative])] = [
            (.name, recordedAlternatives(for: .name, from: name)),
            (.brand, recordedAlternatives(for: .brand, from: brand)),
            (.quantity, recordedAlternatives(for: .quantity, from: quantity)),
            (.containerType, recordedAlternatives(for: .containerType, from: container)),
            (.storageCategory, recordedAlternatives(for: .storageCategory, from: storage)),
            (.aisle, recordedAlternatives(for: .aisle, from: aisle)),
            (.barcode, recordedAlternatives(for: .barcode, from: barcode))
        ]
        for (field, alternatives) in alternativeGroups where !alternatives.isEmpty {
            proposal.fieldAlternatives[field] = alternatives
        }

        let reviewFields: [(InventoryProposalField, Bool, Bool)] = [
            (.name, name.needsReview, name.isContested),
            (.brand, brand?.needsReview ?? false, brand?.isContested ?? false),
            (.quantity, quantity?.needsReview ?? false, quantity?.isContested ?? false),
            (.containerType, container?.needsReview ?? false, container?.isContested ?? false),
            (.storageCategory, storage?.needsReview ?? false, storage?.isContested ?? false),
            (.aisle, aisle?.needsReview ?? false, aisle?.isContested ?? false),
            (.barcode, barcode?.needsReview ?? false, barcode?.isContested ?? false)
        ]
        for (field, needsReview, isContested) in reviewFields where needsReview {
            let issue = InventoryProposalIssue(
                code: isContested ? "conflicting-sources" : "low-confidence-field",
                message: isContested
                    ? "Sources disagree about \(field.rawValue). Confirm the suggested value."
                    : "Confirm the suggested \(field.rawValue).",
                field: field
            )
            if !proposal.reviewIssues.contains(issue) { proposal.reviewIssues.append(issue) }
        }
        return proposal
    }

    private static func recordedAlternatives<Value: Equatable & Sendable>(
        for field: InventoryProposalField,
        from result: ReconciledField<Value>?
    ) -> [InventoryFieldAlternative] {
        result?.alternatives.map {
            InventoryFieldAlternative(field: field,
                                      displayValue: String(describing: $0.value),
                                      provenance: $0.provenance)
        } ?? []
    }
}

nonisolated struct InventoryBatchApplyResult: Equatable, Sendable {
    var batchID: UUID
    var appliedCount: Int
    var skippedCount: Int
    var changedItemIDs: Set<UUID>
}

nonisolated struct InventoryUndoPriorEntry: Equatable, Sendable {
    var originalIndex: Int
    var item: LocalInventoryItem
}

/// Conflict-aware delta used by app-wide undo. It intentionally contains only rows touched by the
/// batch and refuses to overwrite any value that no longer matches the batch's post-apply state.
nonisolated struct InventoryBatchUndoDelta: Equatable, Sendable {
    var addedIDs: Set<UUID>
    var priorEntries: [InventoryUndoPriorEntry]
    var postItems: [UUID: LocalInventoryItem]

    func restoring(_ current: [LocalInventoryItem]) -> [LocalInventoryItem] {
        var restored = current
        restored.removeAll { item in
            guard addedIDs.contains(item.id), let post = postItems[item.id] else { return false }
            return item == post
        }
        for prior in priorEntries {
            if let index = restored.firstIndex(where: { $0.id == prior.item.id }) {
                guard let post = postItems[prior.item.id], restored[index] == post else { continue }
                restored[index] = prior.item
            } else {
                guard postItems[prior.item.id] == nil else { continue }
                restored.insert(prior.item, at: min(prior.originalIndex, restored.count))
            }
        }
        return restored
    }
}

// MARK: - Shared grouped-review helper

/// Groups any badge-carrying, identifiable review items into the three ReviewGroup buckets in
/// display order. Used by receipt review, AI inventory review, recipe-import review, and grocery
/// reconciliation so they all render the same "Confident / Needs review / Ignored" sections
/// instead of each hand-rolling its own grouping. Returns only non-empty groups, ordered.
nonisolated func groupedForReview<Item: Identifiable>(
    _ items: [Item],
    by group: (Item) -> ReviewGroup
) -> [(group: ReviewGroup, items: [Item])] {
    Dictionary(grouping: items, by: group)
        .sorted { $0.key < $1.key }
        .map { (group: $0.key, items: $0.value) }
}

// MARK: - Apply (single code path to mutate inventory)

extension GuestDataStore {
    /// Applies the confirmed changes through existing mutators. Returns a count applied.
    @discardableResult
    func applyProposedChanges(_ changes: [ProposedChange]) -> Int {
        var applied = 0
        for change in changes where change.isConfirmed {
            switch change.action {
            case .remove:
                if let id = change.itemID { removeInventoryItem(id: id); applied += 1 }
            case .setLevel(let level):
                if let id = change.itemID {
                    updateInventoryLevel(id: id, level: max(0, min(1, level))); applied += 1
                }
            case .add(let name, let qty, let containerType, let sizeAmount, let sizeUnit):
                var item = change.addTemplate ?? LocalInventoryItem(name: name, level: 1.0)
                item.name = name
                item.quantity = max(1, qty)
                item.containerType = containerType ?? "item"
                item.sizeAmount = sizeAmount
                item.sizeUnit = sizeUnit
                if change.addTemplate == nil { item.purchaseDate = Date() }
                item.sourceBadge  = change.sourceBadge ?? .aiParsed  // assistant-added → AI parsed
                if !change.fieldProvenance.isEmpty {
                    item.fieldProvenance = Dictionary(uniqueKeysWithValues: change.fieldProvenance.map {
                        ($0.key.rawValue, $0.value)
                    })
                }
                if let product = change.product {
                    item.brand = product.brand
                    item.barcode = product.barcode
                    if let category = product.storageCategory { item.storageCategory = category }
                }
                addInventoryItem(item); applied += 1
            case .adjustQuantity(let delta):
                if let id = change.itemID,
                   let idx = inventoryItems.firstIndex(where: { $0.id == id }) {
                    let newQty = inventoryItems[idx].quantity + delta
                    if newQty <= 0 {
                        // Used the last one → remove the row entirely.
                        removeInventoryItem(id: id)
                    } else {
                        withAnimation { inventoryItems[idx].quantity = newQty }
                    }
                    applied += 1
                }
            case .refreshMetadata(let refresh):
                if let id = change.itemID,
                   let index = inventoryItems.firstIndex(where: { $0.id == id }) {
                    if let price = refresh.price { inventoryItems[index].price = price }
                    if let storeName = refresh.storeName, !storeName.isEmpty {
                        inventoryItems[index].storePurchasedAt = storeName
                    }
                    if let brand = refresh.brand, !brand.isEmpty {
                        inventoryItems[index].brand = brand
                    }
                    if inventoryItems[index].sizeAmount == nil,
                       let amount = refresh.sizeAmount, let unit = refresh.sizeUnit {
                        inventoryItems[index].sizeAmount = amount
                        inventoryItems[index].sizeUnit = unit
                    }
                    if let expiry = refresh.expiry {
                        inventoryItems[index].expirationDate = inventoryItems[index].expirationDate
                            .map { max($0, expiry) } ?? expiry
                    }
                    if !change.fieldProvenance.isEmpty {
                        var provenance = inventoryItems[index].fieldProvenance ?? [:]
                        for (field, value) in change.fieldProvenance {
                            if let current = provenance[field.rawValue],
                               current.badge.confidence > value.badge.confidence,
                               current.observedAt >= value.observedAt { continue }
                            provenance[field.rawValue] = value
                        }
                        inventoryItems[index].fieldProvenance = provenance
                    }
                    if refresh.confirmsPresence { confirmInventoryItem(id: id) }
                    applied += 1
                }
            case .clearAll:
                let count = inventoryItems.count
                // IMPORTANT: only empty the inventory list. Do NOT call the store's clearAll(),
                // which is the nuclear reset (wipes recipes, grocery, profile, and UserDefaults).
                // Restorable via the undo toast the caller shows.
                inventoryItems = []
                applied += count
            }
        }
        return applied
    }

    /// Apply a review batch through the existing mutation path, while making the whole operation
    /// reversible and visible in the shared activity center. Existing `applyProposedChanges` calls
    /// keep their behavior; flows migrate when they are ready for transaction-level undo.
    @discardableResult
    func applyProposalBatch(_ batch: InventoryProposalBatch,
                            brandPreferences: BrandPreferences = BrandPreferences(),
                            retailerID: String? = nil,
                            registerUndo: Bool = true) -> InventoryBatchApplyResult {
        let before = inventoryItems
        let prepared = batch.canonicalized(against: before, brandPreferences: brandPreferences,
                                           retailerID: retailerID)
        let beforeByID = Dictionary(uniqueKeysWithValues: before.map { ($0.id, $0) })
        let applied = applyProposedChanges(prepared.changes)
        let afterByID = Dictionary(uniqueKeysWithValues: inventoryItems.map { ($0.id, $0) })
        let changedIDs = Set(beforeByID.keys).union(afterByID.keys).filter {
            beforeByID[$0] != afterByID[$0]
        }

        if applied > 0 {
            if registerUndo {
                let addedIDs = Set(afterByID.keys).subtracting(beforeByID.keys)
                let priorEntries = before.enumerated().compactMap { index, item in
                    changedIDs.contains(item.id)
                        ? InventoryUndoPriorEntry(originalIndex: index, item: item) : nil
                }
                let postItems = Dictionary(uniqueKeysWithValues: changedIDs.compactMap { id in
                    afterByID[id].map { (id, $0) }
                })
                let undoDelta = InventoryBatchUndoDelta(addedIDs: addedIDs,
                                                        priorEntries: priorEntries,
                                                        postItems: postItems)
                AppUndoJournal.shared.record("Undo \(batch.title)") { [weak self] in
                    guard let self else { return }
                    self.inventoryItems = undoDelta.restoring(self.inventoryItems)
                }
            }
            BackgroundActivityCenter.shared.report(
                id: batch.id,
                kind: .inventory,
                title: batch.title,
                detail: "Applied \(applied) inventory \(applied == 1 ? "change" : "changes")",
                progress: 1
            )
        }
        return InventoryBatchApplyResult(
            batchID: batch.id,
            appliedCount: applied,
            skippedCount: max(0, prepared.changes.count - prepared.confirmedCount),
            changedItemIDs: Set(changedIDs)
        )
    }
}

// MARK: - Conversational intent → proposals (via the receipt Worker's intent path)

// Dependency-free "all ranges of a substring" — avoids relying on the regex-backed
// String.ranges(of:) overload, so behavior is identical across OS versions.
nonisolated private extension String {
    func allRanges(of needle: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var result: [Range<String.Index>] = []
        var searchStart = startIndex
        while searchStart < endIndex,
              let r = range(of: needle, options: [], range: searchStart..<endIndex) {
            result.append(r)
            searchStart = r.upperBound
        }
        return result
    }
}

@Observable
final class InventoryIntentParser {
    var isParsing = false
    var lastError: String?

    /// Whether the Worker endpoint is configured (shared with the recipe features).
    nonisolated static var isAvailable: Bool { StockedWorkerClient.isConfigured }

    /// Sends the utterance + current inventory (name+id) to the Worker, returns proposed changes.
    /// Falls back to nil (caller shows an error) if offline or the Worker isn't configured.
    @MainActor
    func parse(_ utterance: String, store: GuestDataStore) async -> [ProposedChange]? {
        lastError = nil
        let trimmed = utterance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let localChanges = Self.localFallback(trimmed, store: store)
        if localChanges.contains(where: { if case .clearAll = $0.action { return true } else { return false } }) {
            return localChanges
        }
        guard StockedWorkerClient.isConfigured, ConnectivityMonitor.isOnlineFlag else {
            if !localChanges.isEmpty { return localChanges }
            lastError = ConnectivityMonitor.isOnlineFlag
                ? "Natural-language updates need the Stocked Worker configured."
                : "You're offline — try again with a connection."
            return nil
        }

        let inv = store.inventoryItems.map {
            ["id": $0.id.uuidString, "name": $0.name, "quantity": $0.quantity,
             "level": $0.level, "zone": $0.zone] as [String: Any]
        }
        let payload: [String: Any] = [
            "intent": trimmed,
            "inventory": inv,
            "inventoryRevision": store.inventoryRevision,
            "corrections": AICorrectionStore.shared.promptCorrections()
        ]

        isParsing = true
        defer { isParsing = false }
        do {
            let data = try await StockedWorkerClient.requestData(route: .inventoryIntent,
                                                                 payload: payload,
                                                                 timeout: 30)
            let changes = Self.decodeChanges(from: data, store: store)
            if changes.isEmpty && !localChanges.isEmpty { return localChanges }
            if !localChanges.isEmpty {
                let coveredIDs = Set(changes.compactMap { $0.itemID })
                let coveredAddNames = Set(changes.compactMap { change -> String? in
                    if case .add(let name, _, _, _, _) = change.action { return Self.normalize(name) }
                    return nil
                })
                let extra = localChanges.filter { change in
                    if let id = change.itemID { return !coveredIDs.contains(id) }
                    if case .add(let name, _, _, _, _) = change.action {
                        return !coveredAddNames.contains(Self.normalize(name))
                    }
                    return false
                }
                return changes + extra
            }
            return changes
        } catch {
            if !localChanges.isEmpty { return localChanges }
            lastError = error.localizedDescription
            return nil
        }
    }

    /// Parses the Worker's JSON array (possibly wrapped in a content envelope) into ProposedChanges.
    static func decodeChanges(from data: Data, store: GuestDataStore) -> [ProposedChange] {
        guard let response = try? AIResponseDecoder.textResponse(from: data),
              let jsonData = try? AIResponseDecoder.jsonData(from: response.text),
              let root = try? JSONSerialization.jsonObject(with: jsonData) else { return [] }
        let arr: [[String: Any]]
        if let object = root as? [String: Any] {
            let schema = object["schemaVersion"] as? Int
            if let schema, schema != StockedWorkerRoute.inventoryIntent.schemaVersion { return [] }
            arr = object["changes"] as? [[String: Any]] ?? []
        } else {
            arr = root as? [[String: Any]] ?? []   // backwards compatibility with older Worker
        }

        return arr.compactMap { obj -> ProposedChange? in
            let action = (obj["action"] as? String ?? "").lowercased()
            let idStr  = obj["id"] as? String ?? ""
            let name   = (obj["name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
            var itemID = UUID(uuidString: idStr)
            // If the Worker named an item but couldn't resolve its id (very common with
            // branded names — "lemon pepper" vs the stored "Hill Country Fare Lemon Pepper"),
            // resolve it locally against the real inventory before giving up.
            if itemID == nil, !name.isEmpty, action != "add",
               let match = Self.bestInventoryMatch(for: name, in: store.inventoryItems) {
                itemID = match.id
            }
            // Resolve a display name from the store if we matched an id.
            let resolvedName: String = {
                if let itemID, let it = store.inventoryItems.first(where: { $0.id == itemID }) { return it.name }
                return name
            }()
            guard !resolvedName.isEmpty || action == "add" else { return nil }

            switch action {
            case "remove":
                guard let itemID else { return nil }   // can't remove what we didn't match
                return ProposedChange(itemID: itemID, displayName: resolvedName,
                                      action: .remove, reason: "You said you finished it")
            case "setlevel":
                guard let itemID else { return nil }
                let level = (obj["level"] as? Double) ?? 0.5
                return ProposedChange(itemID: itemID, displayName: resolvedName,
                                      action: .setLevel(max(0, min(1, level))),
                                      reason: "You said you used some")
            case "add":
                guard !name.isEmpty else { return nil }
                let qty = (obj["quantity"] as? Int) ?? 1
                let ct  = (obj["containerType"] as? String)?.trimmingCharacters(in: .whitespaces)
                let amt = obj["sizeAmount"] as? Double
                let unit = (obj["sizeUnit"] as? String)?.trimmingCharacters(in: .whitespaces)
                return InventoryProposalBatch.reviewableAdd(
                    name: name,
                    quantity: max(1, qty),
                    containerType: (ct?.isEmpty ?? true) ? nil : ct,
                    sizeAmount: amt,
                    sizeUnit: (unit?.isEmpty ?? true) ? nil : unit,
                    origin: .assistant,
                    reason: "You said you bought it"
                )
            case "adjustquantity", "adjust":
                guard let itemID else { return nil }
                let delta = (obj["delta"] as? Int) ?? -1
                guard delta != 0 else { return nil }
                return ProposedChange(itemID: itemID, displayName: resolvedName,
                                      action: .adjustQuantity(delta: delta),
                                      reason: delta < 0 ? "You said you used some" : "You said you added some")
            case "clearall", "clear":
                return ProposedChange(itemID: nil, displayName: "Everything",
                                      action: .clearAll, reason: "You asked to clear all items")
            default:
                return nil
            }
        }
    }

    // MARK: - Local matching + fallback (works even when the Worker misses)

    /// Resolve a spoken item name to a real inventory row, tolerant of brand prefixes and
    /// extra words. "lemon pepper" → "Hill Country Fare Lemon Pepper"; "minced onion" →
    /// "Great Value Kosher Minced Onion". Returns nil if nothing is a confident match.
    static func bestInventoryMatch(for spoken: String, in items: [LocalInventoryItem]) -> LocalInventoryItem? {
        FoodNameMatcher.bestMatch(for: spoken, in: items, name: \.name, minimumScore: 0.66)
    }

    /// Lowercased, punctuation-stripped, whitespace-collapsed.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // Number words → value, for "two cans", "a dozen eggs".
    private static let numberWords: [String: Int] = [
        "a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11,
        "twelve": 12, "dozen": 12, "couple": 2, "few": 3, "half": 1
    ]
    private static let containerWords: Set<String> = [
        "can","cans","bag","bags","box","boxes","bottle","bottles","jar","jars",
        "carton","cartons","case","cases","pack","packs","package","packages",
        "bunch","bunches","loaf","loaves","dozen","container","containers","tub","tubs",
        "stick","sticks","block","blocks","clove","cloves","head","heads"
    ]
    private static let measureUnits: Set<String> = [
        "oz","ounce","ounces","lb","lbs","pound","pounds","g","gram","grams","kg",
        "ml","l","liter","liters","litre","litres","gallon","gallons","qt","quart",
        "quarts","pint","pints","cup","cups","count","ct","pack"
    ]

    /// Parses a leading quantity / container / size out of a spoken noun phrase.
    /// "3 cans of black beans"   → (qty 3, container "can", size nil, name "black beans")
    /// "a 24 oz bag of rice"     → (qty 1, container "bag", size 24 oz, name "rice")
    /// "2 lbs of chicken"        → (qty 1, container nil, size 2 lb, name "chicken", removeQtyNil)
    static func parseQuantityUnit(_ phrase: String)
        -> (quantity: Int, containerType: String?, sizeAmount: Double?, sizeUnit: String?, name: String) {
        let tokens = phrase.lowercased()
            .split(separator: " ").map(String.init)
            .filter { $0 != "of" }
        var quantity = 1
        var container: String?
        var sizeAmount: Double?
        var sizeUnit: String?

        func singular(_ w: String) -> String {
            if w.hasSuffix("ies") { return String(w.dropLast(3)) + "y" }
            if w.hasSuffix("es") && (w.hasSuffix("xes") || w.hasSuffix("ses") || w.hasSuffix("ches")) { return String(w.dropLast(2)) }
            if w.hasSuffix("s") && w.count > 3 { return String(w.dropLast()) }
            return w
        }

        var i = 0
        var consumed = 0
        while i < tokens.count && i < 4 {
            let t = tokens[i]
            if let n = Int(t) {
                // Bare number: could be a count (2 cans) or a size (24 oz) — decided by the next word.
                if i + 1 < tokens.count, measureUnits.contains(singular(tokens[i+1])) {
                    sizeAmount = Double(n); sizeUnit = tokens[i+1]; consumed = i + 2; i += 2; continue
                }
                quantity = max(1, n); consumed = i + 1; i += 1; continue
            }
            if let d = Double(t), i + 1 < tokens.count, measureUnits.contains(singular(tokens[i+1])) {
                sizeAmount = d; sizeUnit = tokens[i+1]; consumed = i + 2; i += 2; continue
            }
            if let n = numberWords[t] { quantity = max(1, n); consumed = i + 1; i += 1; continue }
            if containerWords.contains(t) {
                container = singular(t); consumed = i + 1; i += 1; continue
            }
            break
        }
        let name = tokens[min(consumed, tokens.count)...].joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return (quantity, container, sizeAmount, sizeUnit, name.isEmpty ? phrase : name)
    }

    /// A best-effort LOCAL parse used when the Worker is unavailable or returns nothing.
    /// Handles the common phrasings entirely on-device so the assistant is never dead:
    ///   • "clear all / wipe everything / empty my inventory" → clearAll
    ///   • "used the rest of X / finished X / out of X / ran out of X" → remove X
    ///   • "used some X / half the X / running low on X" → setLevel
    ///   • "bought X / picked up X / got X" → add X
    static func localFallback(_ utterance: String, store: GuestDataStore) -> [ProposedChange] {
        let lower = " " + utterance.lowercased() + " "

        // Clear-all intent.
        let clearPhrases = ["clear all", "clear everything", "clear my inventory", "clear the inventory",
                            "wipe everything", "wipe all", "wipe my inventory", "empty my inventory",
                            "empty the inventory", "empty everything", "remove everything",
                            "delete everything", "delete all", "start over", "reset my inventory",
                            "reset inventory", "clear out everything", "get rid of everything"]
        if clearPhrases.contains(where: { lower.contains($0) }) {
            return [ProposedChange(itemID: nil, displayName: "Everything",
                                   action: .clearAll, reason: "You asked to clear all items")]
        }

        var out: [ProposedChange] = []
        var usedIDs = Set<UUID>()

        // Removal phrasings: capture the noun after the phrase and match it to inventory.
        let removePhrases = ["used the rest of", "used up the", "used up", "finished the", "finished off the",
                             "finished", "ran out of", "run out of", "out of the", "out of",
                             "used all the", "used all", "no more", "gone", "empty on"]
        for phrase in removePhrases {
            for range in lower.allRanges(of: phrase) {
                let tail = String(lower[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if tail.isEmpty { continue }
                // Take up to the next few words as the candidate noun.
                let candidate = tail.split(separator: " ").prefix(5).joined(separator: " ")
                let parsed = parseQuantityUnit(candidate)
                // Match on the noun with the quantity stripped off.
                if let m = bestInventoryMatch(for: parsed.name, in: store.inventoryItems), !usedIDs.contains(m.id) {
                    usedIDs.insert(m.id)
                    // "used 2 cans of X" with an explicit count and more than one on hand →
                    // decrement rather than delete. "used the rest / finished" → full remove.
                    let saidCount = parsed.quantity > 0 && (parsed.containerType != nil || candidate.first(where: { $0.isNumber }) != nil)
                    let isRest = phrase.contains("rest") || phrase.contains("all") || phrase.contains("finished")
                                 || phrase.contains("ran out") || phrase.contains("run out")
                                 || phrase.contains("no more") || phrase == "gone"
                    if saidCount && !isRest && m.quantity > parsed.quantity {
                        out.append(ProposedChange(itemID: m.id, displayName: m.name,
                                                  action: .adjustQuantity(delta: -parsed.quantity),
                                                  reason: "You said you used \(parsed.quantity)"))
                    } else {
                        out.append(ProposedChange(itemID: m.id, displayName: m.name,
                                                  action: .remove, reason: "You said you finished it"))
                    }
                }
            }
        }

        // Low / partial phrasings → set to a low level.
        let lowPhrases = ["running low on", "low on", "almost out of", "half the", "halfway through the",
                          "getting low on", "used some", "used some of the"]
        for phrase in lowPhrases {
            for range in lower.allRanges(of: phrase) {
                let tail = String(lower[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                let candidate = tail.split(separator: " ").prefix(4).joined(separator: " ")
                if candidate.isEmpty { continue }
                if let m = bestInventoryMatch(for: candidate, in: store.inventoryItems), !usedIDs.contains(m.id) {
                    usedIDs.insert(m.id)
                    let level = phrase.contains("half") ? 0.5 : 0.25
                    out.append(ProposedChange(itemID: m.id, displayName: m.name,
                                              action: .setLevel(level), reason: "You said you used some"))
                }
            }
        }

        // Add phrasings: "bought / picked up / got / added / grabbed / restocked X, Y, and Z".
        // The tail after the phrase is split on commas and "and" into individual new items.
        let addPhrases = ["just bought", "bought", "picked up", "i got", "grabbed", "added",
                          "restocked", "got some", "purchased", "stocked up on"]
        var addedNames = Set<String>()
        for phrase in addPhrases {
            for range in lower.allRanges(of: " " + phrase + " ") {
                let tail = String(lower[range.upperBound...])
                // Stop the item list at a clause boundary so we don't swallow the whole sentence.
                let clause = tail.components(separatedBy: CharacterSet(charactersIn: ".!?\n")).first ?? tail
                let names = clause
                    .replacingOccurrences(of: " and ", with: ",")
                    .replacingOccurrences(of: "&", with: ",")
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .prefix(8)
                for raw in names {
                    // Trim leading filler, then parse quantity/container/size out of the phrase.
                    let stripped = raw
                        .split(separator: " ")
                        .drop(while: { ["the","my","more"].contains(String($0)) })
                        .joined(separator: " ")
                        .trimmingCharacters(in: .whitespaces)
                    let phrase = stripped.isEmpty ? raw : stripped
                    let parsed = parseQuantityUnit(phrase)
                    let title = parsed.name.trimmingCharacters(in: .whitespaces)
                    guard title.count >= 2 else { continue }
                    let key = normalize(title)
                    guard !key.isEmpty, addedNames.insert(key).inserted else { continue }
                    // If it already resolves to an existing item, skip — that's a restock the
                    // user can do explicitly; here we only propose genuinely new additions.
                    if bestInventoryMatch(for: title, in: store.inventoryItems) != nil { continue }
                    out.append(InventoryProposalBatch.reviewableAdd(
                        name: title.capitalized,
                        quantity: parsed.quantity,
                        containerType: parsed.containerType,
                        sizeAmount: parsed.sizeAmount,
                        sizeUnit: parsed.sizeUnit,
                        origin: .assistant,
                        reason: "You said you bought it"
                    ))
                }
            }
        }

        return out
    }
}

// MARK: - Shared reconcile sheet (the one UI all three sources use)

struct ReconcileSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss
    @Environment(\.stockedMotion) private var motion

    let title: String
    let subtitle: String
    @State var changes: [ProposedChange]
    var origin: InventoryProposalOrigin = .reconciliation
    var onApply: (Int) -> Void = { _ in }

    private var confirmedCount: Int { changes.filter { $0.isConfirmed }.count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(subtitle)
                        .scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.6))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20).padding(.top, 8)

                    if changes.isEmpty {
                        emptyState
                    } else {
                        ForEach($changes) { $change in
                            changeRow($change)
                        }
                    }
                }
                .padding(.bottom, 120)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(session.themeTextColor.opacity(0.6))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !changes.isEmpty {
                    Button {
                        let batch = InventoryProposalBatch(origin: origin, title: title,
                                                           changes: changes)
                        let result = session.guestStore.applyProposalBatch(
                            batch,
                            brandPreferences: session.guestStore.cookingProfile.brandPreferences,
                            retailerID: GroceryKnowledgeBase.retailer(
                                matching: session.preferredStore
                            )?.id
                        )
                        HapticManager.success()
                        onApply(result.appliedCount)
                        dismiss()
                    } label: {
                        Text(confirmedCount == 0 ? "Nothing selected"
                                                 : "Apply \(confirmedCount) \(confirmedCount == 1 ? "change" : "changes")")
                            .scaledFont(16, weight: .semibold)
                            .foregroundStyle(Color.stockedWhite)
                            .frame(maxWidth: .infinity).padding(.vertical, 15)
                            .background(confirmedCount == 0 ? Color.gray.opacity(0.5) : session.themeButtonColor)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain).disabled(confirmedCount == 0)
                    .padding(.horizontal, 20).padding(.bottom, 12)
                    .background(.ultraThinMaterial)
                }
            }
        }
    }

    private func changeRow(_ change: Binding<ProposedChange>) -> some View {
        Button {
            motion.animate(.selection, intent: .spatial) { change.wrappedValue.isConfirmed.toggle() }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: change.wrappedValue.isConfirmed ? "checkmark.circle.fill" : "circle")
                    .scaledFont(22)
                    .foregroundStyle(change.wrappedValue.isConfirmed ? Color.stockedGreen : session.themeTextColor.opacity(0.3))
                VStack(alignment: .leading, spacing: 2) {
                    Text(change.wrappedValue.effectText)
                        .scaledFont(15, weight: .semibold, design: .serif)
                        .foregroundStyle(session.themeTextColor)
                    Text(change.wrappedValue.reason)
                        .scaledFont(12).foregroundStyle(session.themeTextColor.opacity(0.45))
                    if let issue = change.wrappedValue.reviewIssues.first {
                        Label(issue.message, systemImage: "exclamationmark.triangle.fill")
                            .scaledFont(11, weight: .medium)
                            .foregroundStyle(Color.stockedWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    let alternativeCount = change.wrappedValue.fieldAlternatives.values
                        .reduce(0) { $0 + $1.count }
                    if alternativeCount > 0 {
                        Text("\(alternativeCount) alternate source \(alternativeCount == 1 ? "value" : "values") available")
                            .scaledFont(10)
                            .foregroundStyle(session.themeTextColor.opacity(0.45))
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Image(systemName: change.wrappedValue.iconName)
                        .scaledFont(16).foregroundStyle(session.themeTextColor.opacity(0.35))
                    if let badge = change.wrappedValue.sourceBadge {
                        SourceBadgeView(badge: badge)
                    }
                }
            }
            .padding(14)
            .background(session.isDarkMode ? Color.darkSurface : Color.stockedWhite.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .opacity(change.wrappedValue.isConfirmed ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "checkmark.circle")
                .scaledFont(40).foregroundStyle(session.themeTextColor.opacity(0.3))
            Text("Nothing to update")
                .scaledFont(16, design: .serif).foregroundStyle(session.themeTextColor.opacity(0.6))
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }
}

// MARK: - Conversational Quick Update (Source 3)
// A text box where the user types what changed in plain language; we parse it (via the
// Worker) into proposed changes and hand off to ReconcileSheet to confirm + apply.
struct QuickUpdateSheet: View {
    @Environment(AppSession.self) var session
    @Environment(\.dismiss) var dismiss

    @State private var text = ""
    @State private var parser = InventoryIntentParser()
    // Identity-driven sheet payload — .sheet(item:) presents reliably on the first tap,
    // unlike a separate Bool plus optional pair, which could open a blank sheet and require
    // sending the message twice.
    private struct ReviewPayload: Identifiable { let id = UUID(); let changes: [ProposedChange] }
    @State private var reviewPayload: ReviewPayload?
    @State private var noChangesNote = false
    @FocusState private var focused: Bool

    private let examples = [
        "I used the rest of the lemon pepper",
        "Finished the milk and eggs",
        "Bought tofu, rice, and oat milk",
        "Down to about half the rice",
        "Clear all my inventory"
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Tell me what you bought, used, or ran out of — in your own words. I'll suggest the changes and you confirm them.")
                        .scaledFont(14).foregroundStyle(session.themeTextColor.opacity(0.65))
                        .fixedSize(horizontal: false, vertical: true)

                    // Input
                    ZStack(alignment: .topLeading) {
                        if text.isEmpty {
                            Text("e.g. \"I finished the milk and used half the rice\"")
                                .stockedTextEditorPlaceholder()
                        }
                        TextEditor(text: $text)
                            .stockedTextEditorContent(minimumHeight: 110)
                            .focused($focused)
                    }
                    .stockedInputSurface()

                    if let err = parser.lastError {
                        Text(err).scaledFont(13).foregroundStyle(.red)
                    }
                    if noChangesNote {
                        Text("I couldn't find anything to change from that. Try naming specific items.")
                            .scaledFont(13).foregroundStyle(session.themeTextColor.opacity(0.6))
                    }

                    // Examples
                    VStack(alignment: .leading, spacing: 8) {
                        Text("TRY").scaledFont(10, weight: .bold).tracking(1)
                            .foregroundStyle(session.themeTextColor.opacity(0.4))
                        ForEach(examples, id: \.self) { ex in
                            Button { text = ex; focused = false } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "quote.bubble").scaledFont(12)
                                    Text(ex).scaledFont(13)
                                    Spacer()
                                }
                                .foregroundStyle(session.themeTextColor.opacity(0.7))
                                .padding(.horizontal, 12).padding(.vertical, 9)
                                .background(session.themeTextColor.opacity(0.05))
                                .clipShape(Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
                .padding(20)
            }
            .background(session.themeBgColor.ignoresSafeArea())
            .navigationTitle("Quick Update")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }.foregroundStyle(session.themeTextColor.opacity(0.6))
                }
            }
            .safeAreaInset(edge: .bottom) {
                Button { Task { await runParse() } } label: {
                    HStack {
                        if parser.isParsing { ProgressView().tint(.white) }
                        Text(parser.isParsing ? "Reading…" : "Review changes")
                            .scaledFont(16, weight: .semibold)
                    }
                    .foregroundStyle(Color.stockedWhite)
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
                    .background(text.trimmingCharacters(in: .whitespaces).isEmpty ? Color.gray.opacity(0.5) : session.themeButtonColor)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(parser.isParsing || text.trimmingCharacters(in: .whitespaces).isEmpty)
                .padding(.horizontal, 20).padding(.bottom, 12)
            }
            .sheet(item: $reviewPayload) { payload in
                ReconcileSheet(
                    title: "Confirm Changes",
                    subtitle: "Here's what I understood. Uncheck anything that's wrong, then apply.",
                    changes: payload.changes,
                    origin: .assistant,
                    onApply: { _ in dismiss() }   // close the whole flow after applying
                ).environment(session)
            }
        }
    }

    private func runParse() async {
        noChangesNote = false
        focused = false
        let result = await parser.parse(text, store: session.guestStore)
        guard let result else { return }   // parser.lastError is shown
        if result.isEmpty { noChangesNote = true; return }
        reviewPayload = ReviewPayload(changes: result)
    }
}
