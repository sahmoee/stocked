import XCTest
import SwiftUI
@testable import Stocked

@MainActor
final class AppWideExperienceTests: XCTestCase {
    func testEveryDestinationHasStableIdentity() {
        XCTAssertEqual(Set(StockedDestination.allCases.map(\.rawValue)).count, StockedDestination.allCases.count)
        XCTAssertEqual(StockedDestination.home.tab, .home)
        XCTAssertNil(StockedDestination.search.tab)
    }

    func testCommandCatalogHasUniqueCommandsAndReachableDestinations() {
        XCTAssertEqual(Set(AppCommandCatalog.all.map(\.id)).count, AppCommandCatalog.all.count)
        XCTAssertTrue(AppCommandCatalog.all.allSatisfy { !$0.title.isEmpty && !$0.subtitle.isEmpty })
    }

    func testContentStatesCoverRecoverySurface() {
        XCTAssertEqual(Set(AppContentState.allCases), Set([.content, .loading, .empty, .stale, .offline, .permissionDenied, .failure]))
    }

    func testAccessibilityMatrixIncludesSmallWideAndAccessibilityConfigurations() {
        XCTAssertLessThanOrEqual(AppAccessibilityMatrix.widths.min() ?? 999, 320)
        XCTAssertGreaterThanOrEqual(AppAccessibilityMatrix.widths.max() ?? 0, 1024)
        XCTAssertTrue(AppAccessibilityMatrix.contentSizes.contains(.accessibilityExtraExtraExtraLarge))
    }

    func testAutonomousJourneysCoverAppCriticalPaths() {
        XCTAssertEqual(AutonomousQAJourney.allCases.count, 10)
        XCTAssertTrue(AutonomousQAJourney.allCases.contains(.offline))
        XCTAssertTrue(AutonomousQAJourney.allCases.contains(.sync))
        XCTAssertTrue(AutonomousQAJourney.allCases.contains(.accessibility))
    }

    func testFormValidationIsConsistent() {
        XCTAssertNotNil(AppFormValidation.required("  ", name: "Name"))
        XCTAssertNil(AppFormValidation.required("Pasta", name: "Name"))
        XCTAssertNotNil(AppFormValidation.positive(0, name: "Quantity"))
        XCTAssertNil(AppFormValidation.positive(1, name: "Quantity"))
    }

    func testPseudolocalizationMakesExpansionVisible() {
        let source = "Create recipe"
        let result = LocalizationAudit.pseudolocalize(source)
        XCTAssertTrue(result.hasPrefix("［"))
        XCTAssertTrue(result.hasSuffix("］"))
        XCTAssertGreaterThan(result.count, source.count)
    }

    func testPerformanceBudgetsRemainInteractive() {
        XCTAssertLessThanOrEqual(AppPerformanceBudget.tabSwitch, 0.25)
        XCTAssertLessThanOrEqual(AppPerformanceBudget.search, 0.4)
        XCTAssertLessThanOrEqual(AppPerformanceBudget.largeListFrameMilliseconds, 16.7)
    }

    func testSharedThemeAndMultilineInputPrimitivesRemainComposable() {
        let text = Binding.constant("")
        _ = AnyView(
            ZStack(alignment: .topLeading) {
                Text("Notes").stockedTextEditorPlaceholder()
                TextEditor(text: text).stockedTextEditorContent(minimumHeight: 110)
            }
            .stockedInputSurface()
            .stockedPresentationSurface(width: .form)
        )
    }

    func testRecipeInterestStopsLearningAndScoringWhenPersonalizationIsDisabled() {
        let defaults = UserDefaults.standard
        let preferenceKey = "privacy.personalization"
        let previousValue = defaults.object(forKey: preferenceKey)
        defer {
            if let previousValue {
                defaults.set(previousValue, forKey: preferenceKey)
            } else {
                defaults.removeObject(forKey: preferenceKey)
            }
        }

        defaults.set(false, forKey: preferenceKey)
        let weightsBeforeAttempt = RecipeInterest.shared.weights

        RecipeInterest.shared.record(
            category: "privacy-test-category",
            area: "privacy-test-area",
            ingredients: ["privacy-test-ingredient"],
            event: .saved
        )

        XCTAssertEqual(RecipeInterest.shared.weights, weightsBeforeAttempt)
        XCTAssertTrue(RecipeInterest.shared.personalizationWeights.isEmpty)
        XCTAssertEqual(
            RecipeInterest.shared.score(
                category: "privacy-test-category",
                area: "privacy-test-area",
                ingredients: ["privacy-test-ingredient"]
            ),
            0
        )
    }
}
