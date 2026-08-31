//
//  MyDataVaultUITests.swift
//  backupTWUITests
//

import XCTest

/// Proves the cross-layer outcome unit tests cannot: an original in the vault
/// becomes a visible Home card, and tapping that card reaches MyData metadata —
/// not the national-ID reader that used to catch every self-issued row.
final class MyDataVaultUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testStoredOriginalAppearsAndOpensVaultDetail() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BONDSTW_UI_TEST_BYPASS_UNLOCK"] = "1"
        app.launchEnvironment["BONDSTW_UI_TEST_SEED_VAULT"] = "1"
        app.launch()

        let document = app.staticTexts.matching(
            NSPredicate(format: "label IN {'財力／所得證明', 'Income / financial proof'}"))
            .firstMatch
        XCTAssertTrue(document.waitForExistence(timeout: 15),
                      "the stored MyData original did not appear on Home")
        document.tap()

        let fingerprint = app.staticTexts.matching(
            NSPredicate(format: "label IN {'檔案指紋', 'File fingerprint'}"))
            .firstMatch
        XCTAssertTrue(fingerprint.waitForExistence(timeout: 10),
                      "the card did not open the MyData vault detail")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label IN {'完整性查核', 'Integrity check'}"))
            .firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label IN {'國民身分證 did:key', 'National ID did:key'}"))
            .firstMatch.exists,
                       "the MyData original was routed into the national-ID detail")
    }
}
