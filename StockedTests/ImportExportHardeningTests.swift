import XCTest

@testable import Stocked

/// Pure-logic coverage for the CSV interchange helpers, the Share Extension hand-off policy,
/// social og: extraction, household merge timestamps, backup restore and the widget contract.
final class ImportExportHardeningTests: XCTestCase {

  // MARK: - CSVInterchange

  func testEscapeNeutralisesSpreadsheetFormulaLeads() {
    XCTAssertEqual(CSVInterchange.escape("=HYPERLINK(\"x\")"), "\"'=HYPERLINK(\"\"x\"\")\"")
    XCTAssertEqual(CSVInterchange.escape("+1 cup"), "'+1 cup")
    XCTAssertEqual(CSVInterchange.escape("@sum"), "'@sum")
    XCTAssertEqual(CSVInterchange.escape("Milk"), "Milk")
  }

  func testEscapeQuotesCarriageReturnsAndCommas() {
    XCTAssertEqual(CSVInterchange.escape("a\rb"), "\"a\rb\"")
    XCTAssertEqual(CSVInterchange.escape("a\r\nb"), "\"a\r\nb\"")
    XCTAssertEqual(CSVInterchange.escape("salt, pepper"), "\"salt, pepper\"")
  }

  func testUnguardRoundTripsOnlyGuardedCells() {
    XCTAssertEqual(CSVInterchange.unguard("'=SUM(A1)"), "=SUM(A1)")
    XCTAssertEqual(CSVInterchange.unguard("'Nduja"), "'Nduja")
    XCTAssertEqual(CSVInterchange.unguard("Milk"), "Milk")
    for name in ["=cmd", "-5 eggs", "@home", "plain"] {
      let row = CSVInterchange.parseRows(CSVInterchange.escape(name)).first ?? []
      XCTAssertEqual(row.first.map(CSVInterchange.unguard), name)
    }
  }

  func testParseRowsSplitsCRLFAndStripsBOM() {
    let text = "\u{FEFF}Section,Name\r\nGrocery,Milk\r\nInventory,\"Rice, brown\"\r\n"
    let rows = CSVInterchange.parseRows(text)
    XCTAssertEqual(rows, [["Section", "Name"], ["Grocery", "Milk"], ["Inventory", "Rice, brown"]])
  }

  func testParseRowsKeepsLineBreaksInsideQuotes() {
    let rows = CSVInterchange.parseRows("Name\n\"two\r\nlines\"\n")
    XCTAssertEqual(rows, [["Name"], ["two\r\nlines"]])
  }

  @MainActor
  func testRecipeCSVParserUsesSharedCRLFParser() {
    XCTAssertEqual(RecipeCSV.parseCSVRows("Title\r\nSoup\r\nStew").count, 3)
  }

  func testImportedQuantityParsesDecimalsAndClamps() {
    XCTAssertEqual(CSVInterchange.quantity("3"), 3)
    XCTAssertEqual(CSVInterchange.quantity("2.0"), 2)
    XCTAssertEqual(CSVInterchange.quantity("1.6"), 2)
    XCTAssertEqual(CSVInterchange.quantity("-4"), 1)
    XCTAssertEqual(CSVInterchange.quantity("0"), 1)
    XCTAssertEqual(CSVInterchange.quantity("99999999999"), CSVInterchange.maximumImportedQuantity)
    XCTAssertEqual(CSVInterchange.quantity("lots"), 1)
    XCTAssertEqual(CSVInterchange.quantity("nan"), 1)
  }

  func testImportedDateAcceptsISOAndDateOnlyAtLocalNoon() throws {
    XCTAssertNotNil(CSVInterchange.date("2026-03-04T10:00:00Z"))
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    let date = try XCTUnwrap(CSVInterchange.date("2026-03-04", calendar: calendar))
    XCTAssertEqual(calendar.component(.day, from: date), 4)
    XCTAssertEqual(calendar.component(.hour, from: date), 12)
    XCTAssertNil(CSVInterchange.date("2026-02-30", calendar: calendar))
    XCTAssertNil(CSVInterchange.date("tomorrow"))
    XCTAssertNil(CSVInterchange.date(""))
  }

  // MARK: - Share Extension hand-off

  func testSharedURLAcceptsOnlyCredentialFreeWebLinks() {
    XCTAssertEqual(SharedRecipePayloadPolicy.webURL(" https://example.com/pasta "), "https://example.com/pasta")
    XCTAssertNotNil(SharedRecipePayloadPolicy.webURL("HTTP://Example.com/a"))
    XCTAssertNil(SharedRecipePayloadPolicy.webURL("httpx://example.com"))
    XCTAssertNil(SharedRecipePayloadPolicy.webURL("file:///etc/passwd"))
    XCTAssertNil(SharedRecipePayloadPolicy.webURL("javascript:alert(1)"))
    XCTAssertNil(SharedRecipePayloadPolicy.webURL("https://user:pw@example.com/"))
    XCTAssertNil(SharedRecipePayloadPolicy.webURL("https:///nohost"))
    XCTAssertNil(SharedRecipePayloadPolicy.webURL(nil))
  }

  func testCaptionPlusLinkTextRoutesToLinkButRecipeTextDoesNot() {
    XCTAssertEqual(
      SharedRecipePayloadPolicy.linkFromShortText("Best pasta ever 🍝 https://www.tiktok.com/@chef/video/123"),
      "https://www.tiktok.com/@chef/video/123")
    let longRecipe = String(repeating: "2 cups flour\n", count: 40) + "https://example.com/r"
    XCTAssertNil(SharedRecipePayloadPolicy.linkFromShortText(longRecipe))
    XCTAssertNil(SharedRecipePayloadPolicy.linkFromShortText("No link here"))
  }

  func testBareLinkIsNotFallbackRecipeText() {
    XCTAssertFalse(SharedRecipePayloadPolicy.hasTextBeyondLink(" https://example.com/x \n"))
    XCTAssertFalse(SharedRecipePayloadPolicy.hasTextBeyondLink("   "))
    XCTAssertTrue(SharedRecipePayloadPolicy.hasTextBeyondLink("1 cup rice\nBoil"))
  }

  func testSharedImageResolvesInsideContainerOnly() {
    let container = URL(fileURLWithPath: "/tmp/group", isDirectory: true)
    XCTAssertEqual(SharedRecipePayloadPolicy.sharedImageURL(in: container)?.path,
                   "/tmp/group/shared_recipe_image.jpg")
    XCTAssertNil(SharedRecipePayloadPolicy.sharedImageURL(in: nil))
  }

  // MARK: - Social og: extraction

  func testMetaContentKeepsApostrophesAndQuotes() {
    let html = """
      <meta property="og:description" content="Mom's best pasta">
      <meta content='Say "hi"' property='og:title'>
      """
    XCTAssertEqual(SocialImportFetcher.metaContent(in: html, property: "og:description"), "Mom's best pasta")
    XCTAssertEqual(SocialImportFetcher.metaContent(in: html, property: "og:title"), "Say \"hi\"")
    XCTAssertNil(SocialImportFetcher.metaContent(in: html, property: "og:image"))
  }

  func testMetaContentDoesNotMatchLongerPropertyNames() {
    let html = #"<meta property="og:image:width" content="640"><meta property="og:image" content="https://cdn.example.com/a.jpg">"#
    XCTAssertEqual(SocialImportFetcher.metaContent(in: html, property: "og:image"), "https://cdn.example.com/a.jpg")
  }

  func testEntityDecodingIsSinglePass() {
    XCTAssertEqual(SocialImportFetcher.decodeEntities("Salt &amp;lt;1 tsp"), "Salt &lt;1 tsp")
    XCTAssertEqual(SocialImportFetcher.decodeEntities("Mac &amp; cheese &#x1F9C0; &#39;yum&#39;"), "Mac & cheese 🧀 'yum'")
    XCTAssertEqual(SocialImportFetcher.decodeEntities("a&#0;b&#xD800;c"), "a b c")
    XCTAssertEqual(SocialImportFetcher.decodeEntities("AT&T &unknown; & done"), "AT&T &unknown; & done")
    XCTAssertEqual(SocialImportFetcher.decodeEntities("&frac12; cup"), "½ cup")
  }

  func testOGImageIsSanitisedToAbsoluteHTTPS() {
    let base = URL(string: "https://www.instagram.com/p/abc/")
    XCTAssertEqual(SocialImportFetcher.sanitizedImageURL("/img/a.jpg", relativeTo: base),
                   "https://www.instagram.com/img/a.jpg")
    XCTAssertEqual(SocialImportFetcher.sanitizedImageURL("http://cdn.example.com/a.jpg", relativeTo: base),
                   "https://cdn.example.com/a.jpg")
    XCTAssertNil(SocialImportFetcher.sanitizedImageURL("javascript:alert(1)", relativeTo: base))
    XCTAssertNil(SocialImportFetcher.sanitizedImageURL("data:image/png;base64,AAAA", relativeTo: base))
    XCTAssertNil(SocialImportFetcher.sanitizedImageURL("", relativeTo: base))
  }

  func testPinterestCountryHostsOnly() {
    XCTAssertEqual(SocialImportDetector.platform(for: "https://www.pinterest.co.uk/pin/1/"), .pinterest)
    XCTAssertEqual(SocialImportDetector.platform(for: "https://pinterest.de/pin/1/"), .pinterest)
    XCTAssertEqual(SocialImportDetector.platform(for: "https://pinterest.com.au/pin/1/"), .pinterest)
    XCTAssertNil(SocialImportDetector.platform(for: "https://pinterest.recipes-blog.com/soup"))
    XCTAssertNil(SocialImportDetector.platform(for: "https://www.pinterest.example.org/soup"))
  }

  // MARK: - Household merge timestamps

  func testNonFiniteTimestampsNeverPinARecord() {
    XCTAssertTrue(HouseholdMergePolicy.remoteWins(remoteUpdatedAt: 10, remoteWriterID: "a",
                                                  localUpdatedAt: .nan, localWriterID: "b"))
    XCTAssertFalse(HouseholdMergePolicy.remoteWins(remoteUpdatedAt: .infinity, remoteWriterID: "a",
                                                   localUpdatedAt: 10, localWriterID: "b"))
    XCTAssertFalse(HouseholdMergePolicy.remoteWins(remoteUpdatedAt: .nan, remoteWriterID: "a",
                                                   localUpdatedAt: 5, localWriterID: "b"))
    XCTAssertEqual(HouseholdMergePolicy.sanitizedTimestamp(-3), 0)
    XCTAssertEqual(HouseholdMergePolicy.sanitizedTimestamp(42), 42)
  }

  // MARK: - Backup restore

  @MainActor
  func testMergeRestorePreservesExistingOrderAndAppendsNew() {
    let a = LocalGroceryItem(name: "A"), b = LocalGroceryItem(name: "B"), c = LocalGroceryItem(name: "C")
    var bNewer = b
    bNewer.name = "B2"
    let d = LocalGroceryItem(name: "D")
    let merged = DataExport.mergedPreservingOrder(current: [a, b, c], incoming: [d, bNewer])
    XCTAssertEqual(merged.map(\.name), ["A", "B2", "C", "D"])
    let deduped = DataExport.mergedPreservingOrder(current: [a, a], incoming: [d, d])
    XCTAssertEqual(deduped.map(\.name), ["A", "D"])
  }

  @MainActor
  func testBackupDecodeSkipsOnlyTheMalformedRecord() throws {
    let json = """
      {"schemaVersion":1,"exportedAt":"2026-01-01T00:00:00Z",
       "grocery":[{"name":"Milk"},{"name":"Eggs","quantity":"lots"}],
       "staples":["Rice"]}
      """
    let backup = try DataExport.decodeBackup(Data(json.utf8))
    XCTAssertEqual(backup.grocery?.map(\.name), ["Milk"])
    XCTAssertEqual(backup.staples, ["Rice"])
    XCTAssertNil(backup.inventory)
  }

  @MainActor
  func testBackupDecodeStillRejectsNonBackups() {
    XCTAssertThrowsError(try DataExport.decodeBackup(Data("[1,2,3]".utf8)))
  }

  // MARK: - Widget contract

  func testWidgetStockPercentIsClampedForDisplayOnly() throws {
    var snap = StockedWidgetSnapshot.preview
    snap.stockPercent = 130
    XCTAssertEqual(snap.displayStockPercent, 100)
    snap.stockPercent = -4
    XCTAssertEqual(snap.displayStockPercent, 0)
    let encoded = try JSONEncoder().encode(snap)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    XCTAssertNil(object["displayStockPercent"], "computed value must not enter the App Group contract")
    XCTAssertEqual(object["stockPercent"] as? Int, -4)
  }
}
