//
//  ZKVerifyUITests.swift
//  backupTWUITests
//

import XCTest

/// Checks that the proof-checking half of the app is reachable and says the
/// right thing before anything is loaded.
///
/// Worth a UI test rather than a unit test because the failure this guards
/// against is a routing one: `ZKVerifyViewController` is pushed from a row
/// matched on its *title*, and `HomeViewController` already carries a comment
/// about an earlier version of that routing keying off `indexPath.row` and
/// silently pointing at whatever landed in the slot. A screen that exists and
/// cannot be reached is the same as a screen that does not exist.
final class ZKVerifyUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testTheProofCheckerIsReachableAndHonestBeforeAnyProofIsLoaded() throws {
        let app = XCUIApplication()
        app.launch()

        let row = app.staticTexts.matching(
            NSPredicate(format: "label IN {'查驗零知識證明', 'Check a zero-knowledge proof'}"))
            .firstMatch
        if !row.waitForExistence(timeout: 15) {
            let visible = app.staticTexts.allElementsBoundByIndex
                .map(\.label).filter { !$0.isEmpty }
            XCTFail("no proof-checking row on the home screen. On screen: \(visible)")
            return
        }
        row.tap()

        // Identifier rather than the visible string: the previous diagnostics
        // test keyed off an English label, which worked only while the app was
        // untranslated and started failing the moment it became readable.
        let status = app.staticTexts["zkverify.status"]
        XCTAssertTrue(status.waitForExistence(timeout: 10),
                      "the proof checker did not present")

        // Before a file is chosen the screen must not imply any verdict. The
        // failure being guarded against is a screen that opens already looking
        // like an answer.
        XCTAssertTrue(app.buttons["zkverify.choose"].exists,
                      "there is no way to load a proof from this screen")

        let detail = app.staticTexts["zkverify.detail"].label
        XCTAssertFalse(detail.isEmpty, "the screen explains nothing about what it wants")
        for forbidden in ["通過", "passed", "已驗證", "verified"] {
            XCTAssertFalse(app.staticTexts["zkverify.status"].label.contains(forbidden),
                           "the screen claims a verdict before any proof was loaded: "
                           + app.staticTexts["zkverify.status"].label)
        }
    }
}
