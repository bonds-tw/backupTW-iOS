//
//  FineTuneUITests.swift
//  backupTWUITests
//

import XCTest

final class FineTuneUITests: XCTestCase {

    func testMyDataPreparationDoesNotShowMisleadingFlowSteps() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["BONDSTW_UI_TEST_BYPASS_UNLOCK"] = "1"
        app.launchEnvironment["BONDSTW_UI_TEST_MYDATA_FLOW_PREVIEW"] = "1"
        app.launch()

        let cover = app.descendants(matching: .any)["mydataOnboard.cover"]
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any)["mydata.flow.steps"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["mydataOnboard.flow"].exists)
        XCTAssertLessThan(cover.frame.height, 130,
                          "the MyData summary should not return to a hero-sized icon card")
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label IN {'個人所得資料', 'Income / financial proof'}"))
            .firstMatch.exists)
        XCTAssertFalse(app.staticTexts.matching(
            NSPredicate(format: "label IN {'文件類型', 'Document type'}"))
            .firstMatch.exists,
                       "preflight should not repeat document/source/storage rows")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "MyData preparation without false progress"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testSuccessfulFormalDocumentUsesACompactResponsiveLayout() {
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchEnvironment["BONDSTW_UI_TEST_BYPASS_UNLOCK"] = "1"
        app.launchEnvironment["BONDSTW_UI_TEST_FORMAL_DOCUMENT_PREVIEW"] = "1"
        app.launch()

        let cover = app.descendants(matching: .any)["mydataOnboard.cover"]
        XCTAssertTrue(cover.waitForExistence(timeout: 10))
        XCTAssertLessThan(cover.frame.height, 180,
                          "the success status must not turn back into a giant hero card")

        let address = app.descendants(matching: .any)["mydataOnboard.data.4"]
        if !address.exists {
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        // In an iPad compatibility window XCUIApplication.frame remains in
        // phone points while descendants are reported in screen coordinates.
        // The collection view and its cell share one coordinate space, so it is
        // the reliable boundary on both iPhone and iPad.
        let listFrame = app.collectionViews.firstMatch.frame
        XCTAssertGreaterThanOrEqual(address.frame.minX, listFrame.minX)
        XCTAssertLessThanOrEqual(address.frame.maxX, listFrame.maxX)
        XCTAssertGreaterThan(address.frame.height, 60,
                             "the household address should use a wrapping stacked row")

        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Formal document responsive layout"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
