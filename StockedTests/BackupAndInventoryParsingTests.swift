import CryptoKit
import XCTest

@testable import Stocked

/// Covers edges of the kitchen backup codec (KitchenTransferManager.swift) and the on-device
/// inventory phrase parser (InventoryChangeProposal.swift) that the existing suites don't.
final class BackupAndInventoryParsingTests: XCTestCase {

  // MARK: - KitchenBackupCodec

  func testBackupSealedWithOneKeyCannotBeOpenedWithAnother() throws {
    let snapshot = KitchenSnapshot(
      displayName: "Home", inventoryItems: [LocalInventoryItem(name: "Milk")],
      groceryItems: [], pastMeals: [])
    let package = try KitchenBackupCodec.seal(snapshot, using: SymmetricKey(size: .bits256))

    XCTAssertThrowsError(
      try KitchenBackupCodec.open(package, using: SymmetricKey(size: .bits256))
    ) { error in
      XCTAssertEqual(error as? KitchenBackupError, .integrityCheckFailed)
    }
  }

  func testNonBackupDataIsRejectedAsMalformed() {
    let garbage = Data("definitely not a kitchen backup".utf8)

    XCTAssertFalse(KitchenBackupCodec.isEncryptedPackage(garbage))
    XCTAssertNil(KitchenBackupCodec.manifest(in: garbage))
    XCTAssertThrowsError(
      try KitchenBackupCodec.open(garbage, using: SymmetricKey(size: .bits256))
    ) { error in
      XCTAssertEqual(error as? KitchenBackupError, .malformedPackage)
    }
  }

  func testSealedPackageIsRecognizedAndExposesManifest() throws {
    let snapshot = KitchenSnapshot(
      displayName: "Cabin", inventoryItems: [], groceryItems: [], pastMeals: [])
    let key = SymmetricKey(size: .bits256)
    let package = try KitchenBackupCodec.seal(snapshot, using: key)

    XCTAssertTrue(KitchenBackupCodec.isEncryptedPackage(package))
    let manifest = try XCTUnwrap(KitchenBackupCodec.manifest(in: package))
    XCTAssertEqual(manifest.displayName, "Cabin")
    XCTAssertEqual(manifest.keyID, KitchenBackupCodec.keyIdentifier(for: key))
    XCTAssertEqual(manifest.format, KitchenBackupManifest.formatIdentifier)
  }

  // MARK: - InventoryIntentParser (pure helpers)

  @MainActor func testNormalizeLowercasesStripsPunctuationAndCollapsesWhitespace() {
    XCTAssertEqual(InventoryIntentParser.normalize("  Hill-Country  Fare!! "), "hill country fare")
  }

  @MainActor func testParseQuantityUnitReadsCountAndContainer() {
    let parsed = InventoryIntentParser.parseQuantityUnit("3 cans of black beans")
    XCTAssertEqual(parsed.quantity, 3)
    XCTAssertEqual(parsed.containerType, "can")
    XCTAssertNil(parsed.sizeAmount)
    XCTAssertNil(parsed.sizeUnit)
    XCTAssertEqual(parsed.name, "black beans")
  }

  @MainActor func testParseQuantityUnitReadsNumberWordSizeAndContainer() {
    let parsed = InventoryIntentParser.parseQuantityUnit("a 24 oz bag of rice")
    XCTAssertEqual(parsed.quantity, 1)
    XCTAssertEqual(parsed.containerType, "bag")
    XCTAssertEqual(parsed.sizeAmount, 24)
    XCTAssertEqual(parsed.sizeUnit, "oz")
    XCTAssertEqual(parsed.name, "rice")
  }

  @MainActor func testParseQuantityUnitTreatsNumberBeforeMeasureAsSize() {
    let parsed = InventoryIntentParser.parseQuantityUnit("2 lbs of chicken")
    XCTAssertEqual(parsed.quantity, 1)
    XCTAssertNil(parsed.containerType)
    XCTAssertEqual(parsed.sizeAmount, 2)
    XCTAssertEqual(parsed.sizeUnit, "lbs")
    XCTAssertEqual(parsed.name, "chicken")
  }

  @MainActor func testParseQuantityUnitDefaultsToOneWhenNoQuantityGiven() {
    let parsed = InventoryIntentParser.parseQuantityUnit("eggs")
    XCTAssertEqual(parsed.quantity, 1)
    XCTAssertNil(parsed.containerType)
    XCTAssertNil(parsed.sizeAmount)
    XCTAssertEqual(parsed.name, "eggs")
  }
}
