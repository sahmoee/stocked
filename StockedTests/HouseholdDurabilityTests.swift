import CryptoKit
import XCTest
@testable import Stocked

final class HouseholdDurabilityTests: XCTestCase {

    func testHouseholdCookPresenceSharesProgressWithoutRecipePayload() throws {
        let snapshot = ActiveCookSessionSnapshot(
            recipeTitle: "Weeknight Pasta",
            ingredients: ["private ingredient 1", "private ingredient 2", "3", "4"],
            steps: ["private step 1", "private step 2", "3", "4"],
            completedSteps: [0, 1], servings: 2,
            selectedComponents: ["salad"])
        let presence = HouseholdCookPresence(snapshot: snapshot, memberID: "device-a", memberName: "Key")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(presence)) as? [String: Any])

        XCTAssertEqual(presence.progressLabel, "2 of 4 steps")
        XCTAssertTrue(presence.availableTasks.contains("Prepare salad"))
        XCTAssertNil(json["ingredients"])
        XCTAssertNil(json["steps"])
        XCTAssertNil(json["timers"])
        XCTAssertNil(json["notes"])
    }

    func testQuantityOperationsAreCommutativeAndIdempotent() {
        let entity = UUID()
        let plus = HouseholdQuantityOperation(idempotencyKey: "plus", entityID: entity,
                                              entityType: .inventoryItem, delta: 2)
        let minus = HouseholdQuantityOperation(idempotencyKey: "minus", entityID: entity,
                                               entityType: .inventoryItem, delta: -1)
        XCTAssertEqual(HouseholdQuantityOperation.mergedValue(base: 4, operations: [plus, minus]), 5)
        XCTAssertEqual(HouseholdQuantityOperation.mergedValue(base: 4, operations: [minus, plus]), 5)
        XCTAssertEqual(HouseholdQuantityOperation.mergedValue(base: 4, operations: [plus, plus]), 6)
    }

    func testLegacyPendingOperationGetsStableIdempotencyDefaults() throws {
        let entity = UUID()
        let legacy = Data("""
        {"entityID":"\(entity.uuidString)","entityType":"inventoryItem","operationType":"update"}
        """.utf8)
        let operation = try JSONDecoder().decode(PendingHouseholdOperation.self, from: legacy)
        XCTAssertEqual(operation.idempotencyKey, operation.id.uuidString.lowercased())
        XCTAssertEqual(operation.clientSequence, 0)
        XCTAssertEqual(operation.recordRevision, 0)
        XCTAssertEqual(operation.fieldRevisions, [:])
    }

    func testLifecycleOperationSupersedesStaleQuantityIntents() {
        let entity = UUID()
        let quantity = HouseholdQuantityOperation(entityID: entity, entityType: .inventoryItem,
                                                   delta: 1)
        let state = PendingHouseholdOperation(entityID: entity, entityType: .inventoryItem,
                                              operationType: .update)
        let delta = PendingHouseholdOperation(
            id: quantity.id, entityID: entity, entityType: .inventoryItem,
            operationType: .update, idempotencyKey: quantity.idempotencyKey,
            quantityOperation: quantity)
        let unrelated = PendingHouseholdOperation(entityID: UUID(), entityType: .inventoryItem,
                                                  operationType: .update)

        let afterDelete = HouseholdOperationJournal.retaining(
            [state, delta, unrelated], replacingWith: [
                .init(entityID: entity, entityType: .inventoryItem, operationType: .delete)
            ])
        XCTAssertEqual(afterDelete, [unrelated])

        let afterUpdate = HouseholdOperationJournal.retaining(
            [state, delta, unrelated], replacingWith: [
                .init(entityID: entity, entityType: .inventoryItem, operationType: .update)
            ])
        XCTAssertEqual(afterUpdate, [delta, unrelated])

        let afterRecreate = HouseholdOperationJournal.retaining(
            [state, delta, unrelated], replacingWith: [
                .init(entityID: entity, entityType: .inventoryItem, operationType: .create)
            ])
        XCTAssertEqual(afterRecreate, [unrelated])
    }

    func testEmptyPartialReceiptAcknowledgesNothing() {
        let first = PendingHouseholdOperation(entityID: UUID(), entityType: .inventoryItem,
                                              operationType: .update, idempotencyKey: "first")
        let second = PendingHouseholdOperation(entityID: UUID(), entityType: .groceryItem,
                                               operationType: .update, idempotencyKey: "second")
        let partial = HouseholdSyncReceipt(requestID: UUID(), outcome: .partial,
            acknowledgedIdempotencyKeys: [], serverRevision: 4)
        XCTAssertEqual(HouseholdAcknowledgement.operationIDs(captured: [first, second],
                                                              receipt: partial), [])

        let named = HouseholdSyncReceipt(requestID: UUID(), outcome: .partial,
            acknowledgedIdempotencyKeys: ["second"], serverRevision: 4)
        XCTAssertEqual(HouseholdAcknowledgement.operationIDs(captured: [first, second],
                                                              receipt: named), [second.id])

        let legacyFull = HouseholdSyncReceipt(requestID: UUID(), outcome: .acknowledged,
            acknowledgedIdempotencyKeys: [], serverRevision: 4)
        XCTAssertEqual(HouseholdAcknowledgement.operationIDs(captured: [first, second],
                                                              receipt: legacyFull), [first.id, second.id])
    }

    func testRequestFailureDoesNotPenalizeOperationsEnqueuedInFlight() {
        let sent = PendingHouseholdOperation(entityID: UUID(), entityType: .inventoryItem,
                                             operationType: .update)
        let late = PendingHouseholdOperation(entityID: UUID(), entityType: .groceryItem,
                                             operationType: .create)
        let result = HouseholdOperationJournal.markingFailure(
            [sent, late], operationIDs: [sent.id], message: "offline")
        XCTAssertEqual(result[0].retryCount, 1)
        XCTAssertEqual(result[0].lastError, "offline")
        XCTAssertEqual(result[1].retryCount, 0)
        XCTAssertNil(result[1].lastError)
    }

    func testFullSnapshotCanCompleteOrdinaryOperationsButRetainsIntentOperations() {
        let created = PendingHouseholdOperation(entityID: UUID(), entityType: .inventoryItem,
                                                operationType: .create)
        let updated = PendingHouseholdOperation(entityID: UUID(), entityType: .groceryItem,
                                                operationType: .update)
        let restored = PendingHouseholdOperation(entityID: UUID(), entityType: .userRecipe,
                                                 operationType: .restore)
        let deleted = PendingHouseholdOperation(entityID: UUID(), entityType: .plannedMeal,
                                                operationType: .delete)
        let quantity = HouseholdQuantityOperation(entityID: UUID(), entityType: .inventoryItem,
                                                  delta: 1)
        let delta = PendingHouseholdOperation(
            id: quantity.id, entityID: quantity.entityID, entityType: quantity.entityType,
            operationType: .update, idempotencyKey: quantity.idempotencyKey,
            quantityOperation: quantity)

        let represented = HouseholdOperationJournal.snapshotRepresentedIDs(
            in: [created, updated, restored, deleted, delta])

        XCTAssertEqual(represented, [created.id, updated.id, restored.id])
        XCTAssertFalse(represented.contains(deleted.id))
        XCTAssertFalse(represented.contains(delta.id))
    }

    func testRecordRevisionMergesIndependentFieldClocks() {
        var local = HouseholdRecordRevision()
        local.advance(changedFields: ["name"], writerID: "a", at: Date(timeIntervalSince1970: 1))
        var remote = HouseholdRecordRevision()
        remote.advance(changedFields: ["quantity"], writerID: "b", at: Date(timeIntervalSince1970: 2))
        remote.serverCheckpoint = 8

        let merged = local.merged(with: remote)
        XCTAssertEqual(merged.fields["name"], 1)
        XCTAssertEqual(merged.fields["quantity"], 1)
        XCTAssertEqual(merged.serverCheckpoint, 8)
    }

    func testFineGrainedDenialWinsOverRoleAndGrant() {
        var manager = HouseholdMember(id: "m", name: "Manager", role: .manager)
        manager.permissionGrants = [.backupRestore, .inventoryRemove]
        manager.permissionDenials = [.inventoryRemove, .backupRestore]
        XCTAssertFalse(manager.can(.inventoryRemove))
        XCTAssertFalse(manager.can(.backupRestore))
        XCTAssertTrue(manager.can(.manageMembers))
    }

    func testMutationOperationsMapToFineGrainedCapabilities() {
        XCTAssertEqual(HouseholdMutationAuthorization.requiredPermission(
            entityType: .inventoryItem, operationType: .create), .inventoryAdd)
        XCTAssertEqual(HouseholdMutationAuthorization.requiredPermission(
            entityType: .inventoryItem, operationType: .update), .inventoryEdit)
        XCTAssertEqual(HouseholdMutationAuthorization.requiredPermission(
            entityType: .inventoryItem, operationType: .delete), .inventoryRemove)
        XCTAssertEqual(HouseholdMutationAuthorization.requiredPermission(
            entityType: .groceryItem, operationType: .delete), .groceryRemove)
        XCTAssertEqual(HouseholdMutationAuthorization.requiredPermission(
            entityType: .userRecipe, operationType: .create), .recipeEdit)
        XCTAssertEqual(HouseholdMutationAuthorization.requiredPermission(
            entityType: .generatedRecipe, operationType: .delete), .recipeEdit)
        XCTAssertEqual(HouseholdMutationAuthorization.requiredPermission(
            entityType: .savedRecipe, operationType: .update), .recipeEdit)
        XCTAssertEqual(HouseholdMutationAuthorization.requiredPermission(
            entityType: .plannedMeal, operationType: .delete), .mealPlanEdit)
        XCTAssertNil(HouseholdMutationAuthorization.requiredPermission(
            entityType: .householdActivity, operationType: .create))
    }

    func testMemberAccessSnapshotPreservesOfflineRelaunchDenials() throws {
        let permissions = HouseholdMember.Role.adult.defaultPermissions
            .subtracting([.inventoryRemove, .backupExport])
        let saved = HouseholdMemberAccessSnapshot(
            role: .adult, permissions: permissions,
            canAdd: true, canEdit: true, canRemove: false)

        let restored = try JSONDecoder().decode(
            HouseholdMemberAccessSnapshot.self, from: JSONEncoder().encode(saved))

        XCTAssertEqual(restored.role, .adult)
        XCTAssertEqual(restored.permissions, permissions)
        XCTAssertFalse(restored.permissions.contains(.inventoryRemove))
        XCTAssertFalse(restored.permissions.contains(.backupExport))
        XCTAssertFalse(restored.canRemove)
    }

    func testMissingMemberPermissionSnapshotFailsClosed() throws {
        let legacy = Data(#"{"role":"manager","canAdd":true,"canEdit":true,"canRemove":true}"#.utf8)
        let restored = try JSONDecoder().decode(HouseholdMemberAccessSnapshot.self, from: legacy)
        XCTAssertEqual(restored.permissions, [.view])
        XCTAssertFalse(restored.canAdd)
        XCTAssertFalse(restored.canEdit)
        XCTAssertFalse(restored.canRemove)
        XCTAssertEqual(HouseholdMemberAccessSnapshot.restrictedMember.permissions, [.view])
    }

    func testAutomaticSyncPolicyHonorsPersistedServerPause() {
        XCTAssertEqual(HouseholdAutomaticSyncPolicy.decision(
            hasPendingOperations: true, retryIsAllowed: false, serverImposedPause: true), .wait)
        XCTAssertEqual(HouseholdAutomaticSyncPolicy.decision(
            hasPendingOperations: true, retryIsAllowed: false, serverImposedPause: false), .pull)
        XCTAssertEqual(HouseholdAutomaticSyncPolicy.decision(
            hasPendingOperations: true, retryIsAllowed: true, serverImposedPause: true), .push)
    }

    func testSyncStatusRelaunchPreservesServerBackoffClassification() throws {
        var status = HouseholdSyncStatus()
        status.nextRetryAllowedAt = Date().addingTimeInterval(600)
        status.backoffIsServerImposed = true

        let restored = try JSONDecoder().decode(
            HouseholdSyncStatus.self, from: JSONEncoder().encode(status))

        XCTAssertTrue(restored.backoffIsServerImposed)
        XCTAssertNotNil(restored.nextRetryAllowedAt)
    }

    func testSyncHealthDerivesPersistedFailureState() {
        var status = HouseholdSyncStatus()
        XCTAssertEqual(status.health, .neverSynced)
        status.lastError = "offline"
        status.consecutiveFailureCount = 2
        XCTAssertEqual(status.health, .degraded)
        status.hasStuckOperations = true
        XCTAssertEqual(status.health, .stalled)
    }

    func testRelaunchClearsPersistedInFlightRoute() throws {
        var status = HouseholdSyncStatus()
        status.activeRoute = .workerPush
        status.pendingOperationCount = 2

        let relaunched = try JSONDecoder().decode(
            HouseholdSyncStatus.self, from: JSONEncoder().encode(status))

        XCTAssertNil(relaunched.activeRoute)
        XCTAssertEqual(relaunched.lastCompletedRoute, .workerPush)
        XCTAssertNotEqual(relaunched.health, .syncing)
    }

    func testEncryptedBackupRoundTripsAndBuildsMediaManifest() throws {
        var item = LocalInventoryItem(name: "Milk")
        item.imageData = Data([1, 2, 3, 4])
        let snapshot = KitchenSnapshot(displayName: "Home", inventoryItems: [item],
                                       groceryItems: [], pastMeals: [])
        let key = SymmetricKey(size: .bits256)

        let package = try KitchenBackupCodec.seal(snapshot, using: key,
                                                  createdAt: Date(timeIntervalSince1970: 100))
        let opened = try KitchenBackupCodec.open(package, using: key)

        XCTAssertEqual(opened.snapshot.displayName, "Home")
        XCTAssertEqual(opened.snapshot.inventoryItems.first?.imageData, item.imageData)
        XCTAssertEqual(opened.manifest.formatVersion, KitchenBackupManifest.currentFormatVersion)
        XCTAssertTrue(opened.manifest.encrypted)
        XCTAssertEqual(opened.manifest.media.count, 1)
        XCTAssertEqual(opened.manifest.media.first?.kind, .inventoryPhoto)
        XCTAssertEqual(opened.manifest.media.first?.checksum,
                       KitchenBackupCodec.checksum(item.imageData!))
    }

    func testEncryptedBackupRejectsCiphertextTampering() throws {
        let snapshot = KitchenSnapshot(displayName: "Home", inventoryItems: [],
                                       groceryItems: [], pastMeals: [])
        let key = SymmetricKey(size: .bits256)
        let package = try KitchenBackupCodec.seal(snapshot, using: key)
        var envelope = try JSONDecoder().decode(KitchenBackupEnvelope.self, from: package)
        var bytes = [UInt8](envelope.sealedPayload)
        bytes[bytes.startIndex] ^= 0xff
        envelope.sealedPayload = Data(bytes)
        let tampered = try JSONEncoder().encode(envelope)

        XCTAssertThrowsError(try KitchenBackupCodec.open(tampered, using: key)) { error in
            XCTAssertEqual(error as? KitchenBackupError, .integrityCheckFailed)
        }
    }

    func testEncryptedBackupRejectsManifestTampering() throws {
        let snapshot = KitchenSnapshot(displayName: "Home", inventoryItems: [],
                                       groceryItems: [], pastMeals: [])
        let key = SymmetricKey(size: .bits256)
        let package = try KitchenBackupCodec.seal(snapshot, using: key)
        var envelope = try JSONDecoder().decode(KitchenBackupEnvelope.self, from: package)
        envelope.manifest.displayName = "Tampered"
        let tampered = try JSONEncoder().encode(envelope)
        XCTAssertThrowsError(try KitchenBackupCodec.open(tampered, using: key))
    }

    func testTextOnlyPrivateRecipeSurvivesEncryptedBackup() throws {
        var recipe = UserRecipe(title: "Text-only soup")
        recipe.instructions = ["Simmer."]
        XCTAssertNil(recipe.imageData)
        XCTAssertNil(recipe.imageURL)
        let snapshot = KitchenSnapshot(displayName: "Home", inventoryItems: [],
                                       groceryItems: [], pastMeals: [], userRecipes: [recipe])
        let key = SymmetricKey(size: .bits256)

        let package = try KitchenBackupCodec.seal(snapshot, using: key)
        let opened = try KitchenBackupCodec.open(package, using: key)

        XCTAssertEqual(opened.snapshot.userRecipes, [recipe])
        XCTAssertEqual(opened.manifest.sections.first(where: { $0.section == .recipes })?.recordCount, 1)
    }

    func testLegacySnapshotDecodesWithAdditiveDefaults() throws {
        let legacy = Data("""
        {"exportedAt":"2025-01-01T00:00:00Z","displayName":"Old Kitchen",
         "inventoryItems":[],"groceryItems":[],"pastMeals":[],"savedRecipes":[]}
        """.utf8)
        let snapshot = try JSONDecoder().decode(KitchenSnapshot.self, from: legacy)
        XCTAssertEqual(snapshot.schemaVersion, 1)
        XCTAssertEqual(snapshot.displayName, "Old Kitchen")
        XCTAssertNil(snapshot.generatedRecipes)
        XCTAssertNil(snapshot.plannedMeals)
        XCTAssertNil(snapshot.features)
    }

    func testSelectiveRestoreDefaultsCoverEverySection() {
        XCTAssertEqual(KitchenRestoreSelection.all.sections,
                       Set(KitchenRestoreSection.allCases))
        XCTAssertFalse(KitchenRestoreSelection.all.merge)
    }

    /// A delete made on this device has not reached the server yet, so the pulled snapshot
    /// still contains the row. The pull must not restore it.
    @MainActor
    func testPendingRecipeAndMealDeletionsDoNotResurrectOnPull() async throws {
        let store = GuestDataStore()
        let deadline = Date().addingTimeInterval(10)
        while !store.hasCompletedInitialHydration && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(store.hasCompletedInitialHydration, "Fixture setup requires completed local hydration")
        guard store.hasCompletedInitialHydration else { return }
        let sync = HouseholdSync.shared
        let previous = (store.userRecipes, store.savedGeneratedRecipes, store.plannedMeals,
                        store.pendingUserRecipeTombstones, store.pendingGenRecipeTombstones,
                        store.pendingMealTombstones, sync.syncRecipes, sync.syncMealPlans)
        defer {
            store.isApplyingHouseholdRemote = true
            store.userRecipes = previous.0
            store.savedGeneratedRecipes = previous.1
            store.plannedMeals = previous.2
            store.pendingUserRecipeTombstones = previous.3
            store.pendingGenRecipeTombstones = previous.4
            store.pendingMealTombstones = previous.5
            store.flushPendingSaves()
            store.isApplyingHouseholdRemote = false
            sync.syncRecipes = previous.6
            sync.syncMealPlans = previous.7
        }

        let recipe = UserRecipe(title: "Deleted Soup")
        let generated = GeneratedRecipe(title: "Deleted Toast", cookTime: "5 min", servings: 1,
                                        difficulty: "Easy", ingredients: [], steps: ["Toast."], tips: "")
        let meal = PlannedMeal(dayIndex: 0, title: "Deleted Dinner", servings: 2,
                               ingredients: [], mealType: "Dinner")
        store.isApplyingHouseholdRemote = true
        store.userRecipes = []
        store.savedGeneratedRecipes = []
        store.plannedMeals = []
        store.isApplyingHouseholdRemote = false
        store.pendingUserRecipeTombstones = [recipe.id.uuidString]
        store.pendingGenRecipeTombstones = [generated.id.uuidString]
        store.pendingMealTombstones = [meal.id.uuidString]
        sync.syncRecipes = true
        sync.syncMealPlans = true

        func dictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        }
        let pulled: [String: Any] = [
            "userRecipes": [try dictionary(recipe)],
            "genRecipes": [try dictionary(generated)],
            "plannedMeals": [try dictionary(meal)]
        ]
        _ = await sync.applyHousehold(pulled, into: store)

        XCTAssertFalse(store.userRecipes.contains { $0.id == recipe.id }, "Deleted recipe resurrected")
        XCTAssertFalse(store.savedGeneratedRecipes.contains { $0.id == generated.id }, "Deleted saved recipe resurrected")
        XCTAssertFalse(store.plannedMeals.contains { $0.id == meal.id }, "Deleted planned meal resurrected")
    }
}
