import XCTest
import SwiftUI
import UIKit
@testable import Stocked

/// Simulator screenshots of actual app views. The attachments are evidence for a
/// human layout review, not an automatic claim that every control is usable.
@MainActor
final class LayoutVisualAuditTests: XCTestCase {
    func testCapturePagesAndSheetsForVisualReview() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Visual audit fixtures run only in a disposable simulator.")
        #else
        let session = AppSession()
        guard session.accountType == .guest, session.appleUserID.isEmpty,
              session.householdCode.isEmpty else {
            throw XCTSkip("Use an unsigned-in simulator without a linked household.")
        }
        let store = session.guestStore
        let hydrationDeadline = Date().addingTimeInterval(10)
        while !store.hasCompletedInitialHydration && Date() < hydrationDeadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(store.hasCompletedInitialHydration, "Fixture setup requires completed local hydration")
        guard store.hasCompletedInitialHydration else { return }
        let previousInventory = store.inventoryItems
        let previousAppearance = session.isDarkMode
        let previousRemoteFlag = store.isApplyingHouseholdRemote
        let previousAppTextSize = UserDefaults.standard.object(forKey: "stocked.appTextSize")
        defer {
            store.isApplyingHouseholdRemote = true
            store.inventoryItems = previousInventory
            store.flushPendingSaves()
            store.isApplyingHouseholdRemote = previousRemoteFlag
            session.isDarkMode = previousAppearance
            if let previousAppTextSize {
                UserDefaults.standard.set(previousAppTextSize, forKey: "stocked.appTextSize")
            } else {
                UserDefaults.standard.removeObject(forKey: "stocked.appTextSize")
            }
        }
        UserDefaults.standard.set(AppTextSize.standard.rawValue, forKey: "stocked.appTextSize")
        store.isApplyingHouseholdRemote = true
        store.inventoryItems = inventoryFixture
        store.isApplyingHouseholdRemote = previousRemoteFlag
        session.isDarkMode = false
        // Finder can use its existing local corpus. Do not start a full catalogue
        // download merely to take a layout screenshot in the simulator.
        HarvestRecipeSync.shared.stopCatalogueRefresh()

        for (label, typeSize) in [("standard", DynamicTypeSize.large), ("accessibility3", .accessibility3)] {
            let finder = RecipeFinderSession()
            let cooking = CookNowSession(householdSize: 2)
            try await capture("start-with-something-\(label)", session: session, typeSize: typeSize,
                              selectedTab: .cook, scroll: true,
                              view: AnyView(NavigationStack { StartWithSomethingView().environment(cooking) }))
            try await capture("cook-hub-\(label)", session: session, typeSize: typeSize,
                              selectedTab: .cook, view: AnyView(NavigationStack { CookHubView() }))
            try await capture("finder-quiz-\(label)", session: session, typeSize: typeSize,
                              selectedTab: .recipes, scroll: true,
                              view: AnyView(NavigationStack { RecipeFinderView(model: finder) }))
            finder.cancel()
            try await capture("cooking-methods-\(label)", session: session, typeSize: typeSize,
                              selectedTab: .cook, scroll: true,
                              view: AnyView(NavigationStack { CookingMethodComparisonView().environment(cooking) }))
            try await capture("add-item-sheet-\(label)", session: session, typeSize: typeSize,
                              view: AnyView(AddItemSheet().stockedPresentationSurface()))
            try await capture("edit-item-sheet-\(label)", session: session, typeSize: typeSize,
                              scroll: true, view: AnyView(EditItemSheet(item: inventoryFixture[2]).stockedPresentationSurface()))
            try await capture("edit-profile-sheet-\(label)", session: session, typeSize: typeSize,
                              scroll: true, view: AnyView(EditProfileView().stockedPresentationSurface()))
            try await capture("dietary-profile-sheet-\(label)", session: session, typeSize: typeSize,
                              scroll: true, view: AnyView(NavigationStack { DietaryProfileView() }.stockedPresentationSurface()))
            try await capture("import-kitchen-sheet-\(label)", session: session, typeSize: typeSize,
                              view: AnyView(ImportModeSheet(onImportFile: {}, onMergeFile: {},
                                                           onICloud: {}, onMergeICloud: {}).stockedPresentationSurface()))
            try await capture("deduct-ingredients-sheet-\(label)", session: session, typeSize: typeSize,
                              view: AnyView(CookingFlashcardView.IngredientDeductSheet(
                                ingredients: inventoryFixture.prefix(5).map(\.name),
                                onConfirmWeighted: { _ in }, onSkip: {}).stockedPresentationSurface()))
            try await capture("toolbox-\(label)", session: session, typeSize: typeSize,
                              scroll: true, view: AnyView(NavigationStack { KitchenToolboxView() }))
            try await capture("settings-\(label)", session: session, typeSize: typeSize,
                              scroll: true, view: AnyView(NavigationStack { SettingsPageView() }))
            try await capture("statistics-\(label)", session: session, typeSize: typeSize,
                              view: AnyView(NavigationStack { StatsView() }))
            try await capture("fullscreen-long-step-\(label)", session: session, typeSize: typeSize,
                              view: AnyView(FullScreenCookView(
                                recipeTitle: "Roasted chicken with lemon, fresh herbs and garden vegetables",
                                steps: [String(repeating: "Stir the vegetables gently, then spread them in an even layer so that every piece has room to roast. ", count: 8)],
                                currentCard: .constant(0), completedSteps: .constant([]), onFinish: {})))
        }
        session.isDarkMode = true
        try await capture("start-with-something-dark", session: session, typeSize: .large,
                          selectedTab: .cook, scroll: true,
                          view: AnyView(NavigationStack { StartWithSomethingView() }))
        #endif
    }

    private var inventoryFixture: [LocalInventoryItem] {
        [
            LocalInventoryItem(name: "Chicken wings", zone: "Freezer"),
            LocalInventoryItem(name: "HEB Hot & Spicy Premium Sausage", zone: "Freezer"),
            LocalInventoryItem(name: "HEB Naturally Hickory and Mesquite smoke original thick cut bacon", zone: "Fridge"),
            LocalInventoryItem(name: "4th & Heart GHEE Clarified Butter Himalayan Pink Salt", zone: "Staples"),
            LocalInventoryItem(name: "Act Ii Xtreme Butter Popcorn", zone: "Pantry"),
            LocalInventoryItem(name: "Butter and garlic croutons", zone: "Fridge"),
            LocalInventoryItem(name: "Cafe Olé Texas Pecan", zone: "Pantry"),
            LocalInventoryItem(name: "Cayenne pepper", zone: "Staples"),
            LocalInventoryItem(name: "Cheez-it Original", zone: "Pantry"),
            LocalInventoryItem(name: "HEB Beef Broth", zone: "Fridge", quantity: 2),
            LocalInventoryItem(name: "McCormick Ground Black Pepper", zone: "Staples"),
            LocalInventoryItem(name: "Wyler's Instant chicken bouillon cubes", zone: "Staples")
        ]
    }

    private func capture(_ name: String, session: AppSession, typeSize: DynamicTypeSize,
                         selectedTab: StockedTab? = nil, scroll: Bool = false,
                         view: AnyView) async throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else {
            XCTFail("A simulator window scene is required for actual-width screenshots")
            return
        }
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let root = DeviceAdaptiveRoot {
            view.safeAreaInset(edge: .bottom, spacing: 0) {
                if let selectedTab { StockedTabBar(selected: .constant(selectedTab)) }
            }
        }
        .stockedThemeEnvironment()
        .environment(session)
        .environment(\.dynamicTypeSize, typeSize)
        .preferredColorScheme(session.isDarkMode ? .dark : .light)
        let hosting = UIHostingController(rootView: root)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = hosting
        window.windowLevel = .normal + 1
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }
        hosting.view.setNeedsLayout()
        hosting.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(650))
        hosting.view.layoutIfNeeded()
        try attach(name, window: window)
        if scroll, let scroller = verticalScrollViews(in: hosting.view)
            .max(by: { $0.bounds.height < $1.bounds.height }) {
            let maximum = max(0, scroller.contentSize.height - scroller.bounds.height + scroller.adjustedContentInset.bottom)
            scroller.setContentOffset(CGPoint(x: scroller.contentOffset.x,
                y: min(maximum, scroller.contentOffset.y + scroller.bounds.height * 0.65)), animated: false)
            try await Task.sleep(for: .milliseconds(200))
            hosting.view.layoutIfNeeded()
            try attach(name + "-scrolled", window: window)
        }
    }

    private func verticalScrollViews(in view: UIView) -> [UIScrollView] {
        let current = (view as? UIScrollView).map { scroll in
            scroll.bounds.height > 100 && scroll.contentSize.height > scroll.bounds.height + 10
                && scroll.contentSize.width <= scroll.bounds.width + 2 ? [scroll] : []
        } ?? []
        return current + view.subviews.flatMap { verticalScrollViews(in: $0) }
    }

    private func attach(_ name: String, window: UIWindow) throws {
        XCTAssertGreaterThan(window.bounds.width, 250)
        XCTAssertGreaterThan(window.bounds.height, 300)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds, format: format)
        let image = renderer.image { context in window.layer.render(in: context.cgContext) }
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let family = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("StockedLayoutAudit/\(family)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
    }
}
