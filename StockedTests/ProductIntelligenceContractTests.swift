import XCTest
@testable import Stocked

final class ProductIntelligenceContractTests: XCTestCase {
    func testBarcodeIdentityIsStableAndReadable() {
        let identity = ProductCatalog.identity(for: "Black Beans", barcode: "0 12345 67890 5")
        XCTAssertEqual(identity.namespace, .barcode)
        XCTAssertEqual(identity.key, "012345678905")
        XCTAssertEqual(identity.stableKey, "barcode:012345678905")
    }

    func testExactCatalogResolutionDoesNotBecomeAmbiguousBecauseVariantsExist() throws {
        let result = ProductCatalog.resolve(ProductResolutionContext(
            rawName: "Great Value Frosted Flakes Cereal",
            brand: "Great Value",
            retailerID: "walmart"
        ))
        XCTAssertEqual(result.matchedEntry?.name, "Great Value Frosted Flakes Cereal")
        XCTAssertGreaterThanOrEqual(result.confidence, 0.95)
        XCTAssertFalse(result.needsReview)
        XCTAssertEqual(result.identity.canonicalName, "frosted flakes cereal")
        XCTAssertFalse(result.candidates.flatMap(\.reasons).contains("Similar product terms"),
                       "strong exact evidence should take the bounded resolver fast path")
    }

    func testCatalogSearchHonorsBoundWithPrecomputedTerms() {
        let results = ProductCatalog.search("great value", limit: 3)
        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy {
            GroceryKnowledgeBase.normalize($0.name).contains("great value")
                || GroceryKnowledgeBase.normalize($0.brand).contains("great value")
        })
    }

    func testPrivateLabelVariantsShareCanonicalIdentity() {
        let kroger = ProductCatalog.identity(for: "Simple Truth Organic Black Beans",
                                              brand: "Simple Truth")
        let wholeFoods = ProductCatalog.identity(for: "365 Black Beans", brand: "365")
        XCTAssertEqual(kroger.canonicalName, "black beans")
        XCTAssertEqual(kroger.canonicalName, wholeFoods.canonicalName)
    }

    @MainActor
    func testBrandProfileCombinesCatalogAndRetailerKnowledge() throws {
        let profile = try XCTUnwrap(BrandDatabase.profile(for: "Kirkland Signature"))
        XCTAssertTrue(profile.isPrivateLabel)
        XCTAssertTrue(profile.retailerIDs.contains("costco"))
        XCTAssertFalse(profile.knownItems.isEmpty)
    }

    @MainActor
    func testBrandPreferenceRanksWithoutHidingAvoidedBrands() throws {
        var preferences = BrandPreferences()
        preferences.set(.avoid, for: "Kerrygold")
        preferences.set(.favorite, for: "Land O Lakes")
        let ranked = BrandDatabase.rankedBrands(for: "Butter", preferences: preferences)
        XCTAssertEqual(ranked.first?.brand, "Land O Lakes")
        XCTAssertTrue(ranked.contains(where: { $0.brand == "Kerrygold" }))
    }

    func testCookingProfileBrandPreferencesDecodeAdditively() throws {
        let legacy = try JSONDecoder().decode(UserCookingProfile.self, from: Data("{}".utf8))
        XCTAssertEqual(legacy.brandPreferences.preference(for: "Kerrygold"), .neutral)

        var current = UserCookingProfile()
        current.brandPreferences.set(.favorite, for: "Kerrygold")
        let decoded = try JSONDecoder().decode(
            UserCookingProfile.self,
            from: JSONEncoder().encode(current)
        )
        XCTAssertEqual(decoded.brandPreferences.preference(for: "Kerrygold"), .favorite)
    }

    @MainActor
    func testPersistedBrandPreferencesRankProfilesWithoutHidingAvoidedBrands() throws {
        var profile = UserCookingProfile()
        profile.brandPreferences.set(.favorite, for: "365")
        profile.brandPreferences.set(.avoid, for: "Kirkland Signature")
        let persisted = try JSONDecoder().decode(
            UserCookingProfile.self,
            from: JSONEncoder().encode(profile)
        )

        let ranked = BrandDatabase.rankedProfiles(preferences: persisted.brandPreferences)
        XCTAssertEqual(ranked.first?.displayName, "365")
        let avoided = try XCTUnwrap(ranked.firstIndex { $0.displayName == "Kirkland Signature" })
        let neutral = try XCTUnwrap(ranked.firstIndex { $0.displayName == "Great Value" })
        XCTAssertGreaterThan(avoided, neutral)
        XCTAssertTrue(ranked.contains { $0.displayName == "Kirkland Signature" },
                      "avoided brands stay available for review and later changes")
    }

    func testFieldReconciliationPreservesAlternativesAndUserAuthority() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let user = FieldEvidence("Fridge", provenance: FieldProvenance(
            sourceID: "manual", badge: .userAdded, observedAt: now.addingTimeInterval(-86_400)
        ))
        let remote = FieldEvidence("Pantry", provenance: FieldProvenance(
            sourceID: "remote", badge: .aiParsed, observedAt: now
        ))
        let health = [
            "manual": SourceHealthSnapshot(sourceID: "manual", successes: 0, failures: 3),
            "remote": SourceHealthSnapshot(sourceID: "remote", successes: 20, failures: 0)
        ]
        let result = try XCTUnwrap(ProductFieldReconciler.reconcileText(
            [remote, user], sourceHealth: health, now: now
        ))
        XCTAssertEqual(result.value, "Fridge")
        XCTAssertEqual(result.provenance.sourceID, "manual")
        XCTAssertEqual(result.alternatives.count, 1)
    }

    func testRecentSourceFailureTemporarilyReducesReliability() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let healthy = SourceHealthSnapshot(sourceID: "a", successes: 8, failures: 2,
                                           lastSuccess: now)
        let failing = SourceHealthSnapshot(sourceID: "b", successes: 8, failures: 2,
                                           lastFailure: now)
        let slow = SourceHealthSnapshot(sourceID: "c", successes: 8, failures: 2,
                                        lastSuccess: now, averageLatency: 30)
        XCTAssertGreaterThan(healthy.reliability(at: now), failing.reliability(at: now))
        XCTAssertGreaterThan(healthy.reliability(at: now), slow.reliability(at: now))
    }

    @MainActor
    func testSourceHealthSnapshotAliasesDeduplicate() {
        let snapshots = SourceHealth.shared.snapshots(for: ["USDA", " usda ", ""])
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertNotNil(snapshots["usda"])
    }

    func testReconciledEvidenceBecomesFieldSpecificReviewProposal() throws {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let receipt = FieldProvenance(sourceID: "receipt", badge: .estimated, observedAt: now)
        let catalog = FieldProvenance(sourceID: "catalog", badge: .estimated, observedAt: now)
        let proposal = try XCTUnwrap(InventoryProposalBatch.reconciledAdd(
            InventoryAddEvidence(
                names: [FieldEvidence("Greek Yogurt", provenance: receipt)],
                quantities: [FieldEvidence(2, provenance: receipt)],
                storageCategories: [
                    FieldEvidence(.fridge, provenance: receipt),
                    FieldEvidence(.pantry, provenance: catalog)
                ],
                aisles: [FieldEvidence(.dairy, provenance: catalog)]
            ),
            origin: .receipt,
            reason: "Receipt",
            now: now
        ))
        XCTAssertEqual(proposal.product?.storageCategory, .pantry)
        XCTAssertEqual(proposal.fieldProvenance[.quantity]?.sourceID, "receipt")
        XCTAssertEqual(proposal.fieldAlternatives[.storageCategory]?.count, 1)
        XCTAssertEqual(proposal.fieldAlternatives[.storageCategory]?.first?.provenance.sourceID,
                       "receipt")
        XCTAssertTrue(proposal.reviewIssues.contains {
            $0.code == "conflicting-sources" && $0.field == .storageCategory
        })
    }

    func testReceiptRowAdaptsToUnifiedReviewProposal() throws {
        let row = try XCTUnwrap(ReceiptProcessingService.normalize(
            raw: "2 CT GREAT VALUE BLACK BEANS 15 OZ 3.98",
            aiResolved: "Great Value Black Beans 15 oz",
            storeName: "Walmart",
            learnedTranslation: nil,
            abbreviationTranslation: nil
        ))
        let proposal = row.proposedChange(containerType: "can")
        XCTAssertEqual(proposal.product?.identity.canonicalName, "black beans")
        XCTAssertEqual(proposal.product?.aisle, .canned)
        XCTAssertEqual(proposal.sourceBadge, .aiParsed)
        XCTAssertEqual(proposal.fieldProvenance[.name]?.sourceID, "receipt:walmart")
    }

    func testBatchMergesCanonicalDuplicateAdds() {
        let first = InventoryProposalBatch.reviewableAdd(
            name: "Black Beans", quantity: 2, origin: .receipt, reason: "Receipt"
        )
        let second = InventoryProposalBatch.reviewableAdd(
            name: "Organic Black Beans", quantity: 1, origin: .receipt, reason: "Receipt"
        )
        let batch = InventoryProposalBatch(origin: .receipt, title: "Receipt", changes: [first, second])
            .canonicalized(against: [])
        XCTAssertEqual(batch.changes.count, 1)
        guard case let .add(_, quantity, _, _, _) = batch.changes[0].action else {
            return XCTFail("Expected a merged add")
        }
        XCTAssertEqual(quantity, 3)
    }

    func testBatchConvertsExistingProductAddToQuantityAdjustment() {
        let existing = LocalInventoryItem(name: "Simple Truth Organic Black Beans", quantity: 2)
        let proposal = InventoryProposalBatch.reviewableAdd(
            name: "365 Black Beans", quantity: 3, origin: .receipt, reason: "Receipt"
        )
        let batch = InventoryProposalBatch(origin: .receipt, title: "Receipt", changes: [proposal])
            .canonicalized(against: [existing])
        XCTAssertEqual(batch.changes.count, 1)
        XCTAssertEqual(batch.changes[0].itemID, existing.id)
        XCTAssertEqual(batch.changes[0].action, .adjustQuantity(delta: 3))
    }

    func testStoreCompatibleMigrationKeepsEstablishedAddSemantics() {
        let first = InventoryProposalBatch.reviewableAdd(
            name: "Simple Truth Organic Black Beans", origin: .groceryTransfer, reason: "Trip"
        )
        let second = InventoryProposalBatch.reviewableAdd(
            name: "365 Black Beans", origin: .groceryTransfer, reason: "Trip"
        )
        let batch = InventoryProposalBatch(
            origin: .groceryTransfer,
            title: "Trip",
            changes: [first, second],
            mergePolicy: .storeCompatible
        ).canonicalized(against: [])
        XCTAssertEqual(batch.changes.count, 2,
                       "migrated direct-add flows must leave final merge decisions to GuestDataStore")
    }

    func testLocalItemProposalAdapterRetainsProductionMetadata() {
        var item = LocalInventoryItem(name: "Milk", zone: "Fridge", quantity: 2,
                                      containerType: "carton")
        item.expirationDate = Date(timeIntervalSince1970: 3_000)
        item.price = 4.25
        item.storePurchasedAt = "Market"
        let proposal = InventoryProposalBatch.reviewableAdd(
            item: item, origin: .manual, reason: "Manual"
        )
        XCTAssertEqual(proposal.addTemplate, item)
        XCTAssertEqual(proposal.product?.storageCategory, .fridge)
        XCTAssertEqual(proposal.product?.brand, item.brand)
    }

    func testBatchUndoRestoresOnlyUnchangedPostApplyRows() {
        var prior = LocalInventoryItem(name: "Milk", quantity: 1)
        var post = prior
        post.quantity = 2
        let added = LocalInventoryItem(name: "Eggs", quantity: 1)
        let delta = InventoryBatchUndoDelta(
            addedIDs: [added.id],
            priorEntries: [InventoryUndoPriorEntry(originalIndex: 0, item: prior)],
            postItems: [post.id: post, added.id: added]
        )

        XCTAssertEqual(delta.restoring([post, added]), [prior])

        var laterPost = post
        laterPost.quantity = 3
        var laterAdded = added
        laterAdded.quantity = 2
        XCTAssertEqual(delta.restoring([laterPost, laterAdded]), [laterPost, laterAdded],
                       "undo must not overwrite edits made after the batch")

        // A row deleted by the batch has no post value and is restored only while still absent.
        let deleteDelta = InventoryBatchUndoDelta(
            addedIDs: [],
            priorEntries: [InventoryUndoPriorEntry(originalIndex: 0, item: prior)],
            postItems: [:]
        )
        XCTAssertEqual(deleteDelta.restoring([]), [prior])
        prior.quantity = 4
        XCTAssertEqual(deleteDelta.restoring([prior]), [prior],
                       "a later re-add with the same id remains authoritative")
    }

    func testLegacyStoreLayoutDecodesWithoutAislePositions() throws {
        let data = try XCTUnwrap(#"{"store":"Old Store","positions":{"milk":0.4},"trips":2}"#
            .data(using: .utf8))
        let layout = try JSONDecoder().decode(StoreLayout.self, from: data)
        XCTAssertEqual(layout.store, "Old Store")
        XCTAssertEqual(layout.trips, 2)
        XCTAssertTrue(layout.aislePositions.isEmpty)
        XCTAssertEqual(layout.position(of: "milk"), 0.4)
    }

    func testStoreLayoutTransfersLearningAcrossEquivalentBrands() {
        var layout = StoreLayout(store: "Market")
        layout.learn(order: ["Great Value Black Beans", "Whole Milk"])
        XCTAssertNotNil(layout.position(of: "Simple Truth Organic Black Beans"))
    }

    func testUnseenItemsUseLearnedAisleWalkingOrder() {
        var layout = StoreLayout(store: "Market")
        layout.learn(order: [
            StoreRouteItem(name: "Apples", aisle: .produce),
            StoreRouteItem(name: "Whole Milk", aisle: .dairy)
        ])
        let route = StoreRouting.route([
            StoreRouteItem(name: "Greek Yogurt", aisle: .dairy),
            StoreRouteItem(name: "Carrots", aisle: .produce)
        ], layout: layout)
        XCTAssertEqual(route.map(\.name), ["Carrots", "Greek Yogurt"])
    }

    func testInventoryConfidenceAssessmentExplainsReviewState() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var item = LocalInventoryItem(name: "Milk")
        item.purchaseDate = now.addingTimeInterval(-10 * 86_400)
        item.sourceBadge = .aiParsed
        let assessment = item.confidenceAssessment(at: now)
        XCTAssertEqual(assessment.state, .probable)
        XCTAssertFalse(assessment.shouldReview)
        XCTAssertFalse(assessment.reasons.isEmpty)
    }

    func testInventoryFieldProvenanceRoundTrips() throws {
        var item = LocalInventoryItem(name: "Milk")
        item.fieldProvenance = [
            InventoryProposalField.name.rawValue: FieldProvenance(
                sourceID: "receipt:kroger", badge: .aiParsed,
                observedAt: Date(timeIntervalSince1970: 1_000)
            )
        ]
        let decoded = try JSONDecoder().decode(
            LocalInventoryItem.self,
            from: JSONEncoder().encode(item)
        )
        XCTAssertEqual(decoded.fieldProvenance, item.fieldProvenance)
    }

    @MainActor
    func testRetailerEquivalentsRespectBrandPreference() {
        var preferences = BrandPreferences()
        preferences.set(.avoid, for: "Simple Truth")
        preferences.set(.favorite, for: "365")
        let substitutions = SubstitutionEngine.local(
            for: "Black Beans",
            userEntries: [],
            brandPreferences: preferences,
            retailerID: "kroger"
        )
        let equivalents = substitutions.filter { $0.brand != nil }
        XCTAssertEqual(equivalents.first?.brand, "365")
        XCTAssertTrue(equivalents.contains(where: { $0.brand == "Simple Truth" }))
    }
}
