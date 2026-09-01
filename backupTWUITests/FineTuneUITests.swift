//
//  FineTuneUITests.swift
//  backupTWUITests
//

import XCTest

final class FineTuneUITests: XCTestCase {

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
