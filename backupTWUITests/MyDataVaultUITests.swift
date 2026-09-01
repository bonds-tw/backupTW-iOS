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
            NSPredicate(format: "label IN {'個人所得資料', 'Income / financial proof'}"))
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

    func testThreeMyDataDocumentsExpandBeforeOpeningOne() throws {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["BONDSTW_UI_TEST_BYPASS_UNLOCK"] = "1"
        app.launchEnvironment["BONDSTW_UI_TEST_SEED_VAULT"] = "1"
        app.launchEnvironment["BONDSTW_UI_TEST_SEED_VAULT_COUNT"] = "3"
        app.launch()

        let income = app.staticTexts.matching(
            NSPredicate(format: "label IN {'個人所得資料', 'Income / financial proof'}"))
            .firstMatch
        XCTAssertTrue(income.waitForExistence(timeout: 15))
        for _ in 0..<4 where !income.isHittable { app.swipeUp() }
        XCTAssertTrue(income.isHittable, "the collapsed MyData stack never became tappable")
        keepScreenshot(of: app, name: "MyData stack collapsed")

        income.tap()
        let health = app.staticTexts.matching(
            NSPredicate(format: "label IN {'健保投保資料', 'Health insurance record'}"))
            .firstMatch
        XCTAssertTrue(health.waitForExistence(timeout: 5),
                      "expanding the MyData stack did not reveal every stored document")
        for _ in 0..<2 where !health.isHittable { app.swipeUp() }
        XCTAssertTrue(health.isHittable)
        keepScreenshot(of: app, name: "MyData stack expanded")

        for _ in 0..<2 where !income.isHittable { app.swipeDown() }
        XCTAssertTrue(income.isHittable)
        income.tap()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label IN {'檔案指紋', 'File fingerprint'}"))
            .firstMatch.waitForExistence(timeout: 10),
                      "an expanded MyData card did not open its vault detail")
    }

    private func keepScreenshot(of app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
