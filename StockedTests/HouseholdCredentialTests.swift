import XCTest
@testable import Stocked

final class HouseholdCredentialTests: XCTestCase {
    private let secret = "AbCdEfGhIjKlMnOpQrStUvWxYz0123456789-_abcdefg"

    func testInviteLinkKeepsCaseSensitiveSecretAndCode() {
        let parsed = HouseholdInviteLink.parse("Join my Stocked. kitchen: https://sowensstudios.com/join/ABCD2345#invite=\(secret)")
        XCTAssertEqual(parsed.code, "ABCD2345")
        XCTAssertEqual(parsed.invite, secret)
    }

    func testCodeAloneHasNoInvite() {
        let parsed = HouseholdInviteLink.parse("abcd-2345")
        XCTAssertEqual(parsed.code, "ABCD2345")
        XCTAssertNil(parsed.invite)
        XCTAssertNil(HouseholdInviteLink.parse("https://sowensstudios.com/join/ABCD2345#invite=short").invite)
    }

    func testMalformedAndOversizedSecretsCannotBecomeValidByTruncation() {
        XCTAssertNil(HouseholdInviteLink.parse("ABCD2345#invite=\(secret)!").invite)
        XCTAssertNil(HouseholdInviteLink.parse("ABCD2345#invite=" + String(repeating: "a", count: 129)).invite)
        XCTAssertNil(HouseholdInviteLink.parse("ABCD2345#invite=" + String(repeating: "é", count: 43)).invite)
        XCTAssertEqual(HouseholdInviteLink.parse("ABCD23456#invite=\(secret)").code, "")
    }

    @MainActor
    func testLateResponseScopeMustMatchBothEpochAndHousehold() {
        let sync = HouseholdSync.shared
        let epoch = sync.scopeEpoch
        XCTAssertTrue(sync.isCurrentScope(epoch, code: sync.joinCode))
        XCTAssertFalse(sync.isCurrentScope(epoch &+ 1, code: sync.joinCode))
        XCTAssertFalse(sync.isCurrentScope(epoch, code: "OTHER234"))
    }

    @MainActor
    func testDailyBriefOmitsEveryDisabledSharingSection() {
        for disabled in 0..<3 {
            var sharing = [true, true, true]
            sharing[disabled] = false
            let payload = DailyBriefContextUploader.contextPayload(code: "ABCD2345",
                inventory: [["name": "Private inventory"]], grocery: [["name": "Private grocery"]],
                mealCount: 2, sharing: sharing)
            XCTAssertNil(payload[["inventory", "grocery", "plannedMeals"][disabled]])
            XCTAssertEqual(payload["code"] as? String, "ABCD2345")
        }
        let allOff = DailyBriefContextUploader.contextPayload(code: "ABCD2345", inventory: [],
            grocery: [], mealCount: 500, sharing: [false, false, false])
        XCTAssertNil(allOff["inventory"])
        XCTAssertNil(allOff["grocery"])
        XCTAssertNil(allOff["plannedMeals"])
    }

    @MainActor
    func testWidgetOlderRefreshCannotOverwriteErasedSnapshot() {
        let previous = WidgetStore.load()
        defer { WidgetStore.save(previous) }
        let oldRevision = WidgetBridge.refreshRevision
        WidgetBridge.invalidateForErase()
        XCTAssertFalse(WidgetBridge.commitPrepared(.preview, revision: oldRevision))
        XCTAssertEqual(WidgetStore.load().inventoryCount, StockedWidgetSnapshot.empty.inventoryCount)
    }

    @MainActor
    func testRecipeMirrorAllowsLocalMutationBookkeepingDuringAwait() async throws {
        let store = GuestDataStore()
        let deadline = Date().addingTimeInterval(10)
        while !store.hasCompletedInitialHydration && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(store.hasCompletedInitialHydration)
        guard store.hasCompletedInitialHydration else { return }
        let sync = HouseholdSync.shared
        let previous = (store.userRecipes, store.groceryItems, sync.syncRecipes)
        defer {
            store.isApplyingHouseholdRemote = true
            store.userRecipes = previous.0
            store.groceryItems = previous.1
            store.flushPendingSaves()
            store.isApplyingHouseholdRemote = false
            sync.syncRecipes = previous.2
        }
        sync.syncRecipes = true
        let recipe = UserRecipe(title: "Mirror concurrency fixture")
        let dictionary = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe)) as? [String: Any])
        var mirrored = false
        _ = await sync.applyHousehold(["userRecipes": [dictionary]], into: store, detectConflicts: true,
                                     mirrorRecipes: { _ in
            mirrored = true
            XCTAssertFalse(store.isApplyingHouseholdRemote, "Indexing must not suppress UI edits")
            await Task.yield()
            var item = LocalGroceryItem(name: "Local edit during mirror")
            item.updatedAt = 0
            store.groceryItems.append(item)
            XCTAssertGreaterThan(store.groceryItems.first { $0.id == item.id }?.updatedAt ?? 0, 0,
                                 "Local edit lost its mutation timestamp while indexing awaited")
        })
        XCTAssertTrue(mirrored)
        XCTAssertFalse(store.isApplyingHouseholdRemote)
    }

    @MainActor
    func testCloudKitRemoteMergeKeepsRemoteTimestampAndDoesNotQueueLocalChanges() async throws {
        let store = GuestDataStore()
        let deadline = Date().addingTimeInterval(10)
        while !store.hasCompletedInitialHydration && Date() < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(store.hasCompletedInitialHydration)
        guard store.hasCompletedInitialHydration else { return }
        let previous = store.groceryItems
        defer {
            store.isApplyingHouseholdRemote = true
            store.groceryItems = previous
            store.flushPendingSaves()
            store.isApplyingHouseholdRemote = false
        }
        var remote = LocalGroceryItem(name: "Remote fixture")
        remote.updatedAt = 123
        remote.lastWriterID = "remote-member"
        let queueBefore = HouseholdSync.shared.pendingOps
        HouseholdCloudKit.applyRemoteChanges(to: store) { store.groceryItems = [remote] }
        XCTAssertEqual(store.groceryItems.first?.updatedAt, 123)
        XCTAssertEqual(store.groceryItems.first?.lastWriterID, "remote-member")
        XCTAssertEqual(HouseholdSync.shared.pendingOps, queueBefore)
        XCTAssertFalse(store.isApplyingHouseholdRemote)
    }

    @MainActor
    func testRequestsCarryOneStableKeychainCredential() throws {
        let sync = HouseholdSync.shared
        let credential = sync.householdCredential
        XCTAssertGreaterThanOrEqual(credential.count, 43)
        XCTAssertNil(credential.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")), "base64url only")
        XCTAssertEqual(sync.householdCredential, credential, "The credential must persist, not regenerate")
        XCTAssertNil(UserDefaults.standard.dictionaryRepresentation().values.first { "\($0)" == credential },
                     "The credential must never be stored in UserDefaults")
        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid/household/pull")))
        sync.authorizeHouseholdRequest(&request)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Household-Member"), sync.memberId)
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Household-Credential"), credential)
        XCTAssertNil(request.url?.query)
    }
}
