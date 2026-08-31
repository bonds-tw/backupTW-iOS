//
//  backupTWUITests.swift
//  backupTWUITests
//
//  Created by Denken Chen on 2025/5/30.
//

import XCTest

final class backupTWUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testOfficialDocumentInboxIsASeparateSectionBelowTheVault() throws {
        let app = XCUIApplication()
        app.launchEnvironment["BONDSTW_UI_TEST_BYPASS_UNLOCK"] = "1"
        app.launch()

        let inbox = app.descendants(matching: .any)["control.official-documents"]
        for _ in 0..<4 where !inbox.exists {
            app.swipeUp()
        }
        XCTAssertTrue(inbox.waitForExistence(timeout: 10),
                      "the independent official-document section did not appear below the vault")
        inbox.tap()

        XCTAssertTrue(app.descendants(matching: .any)["officialDocuments.status"]
            .waitForExistence(timeout: 10),
                      "the receiving-status boundary was not visible")
        XCTAssertTrue(app.descendants(matching: .any)["officialDocuments.empty"].exists,
                      "the prototype did not disclose that no official documents are connected")
        XCTAssertTrue(app.descendants(matching: .any)["officialDocuments.signConsent"].exists,
                      "the 行動自然人憑證 pilot action was not visible")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // This measures how long it takes to launch your application.
        measure(metrics: [XCTApplicationLaunchMetric()]) {
            let app = XCUIApplication()
            app.launchEnvironment["BONDSTW_UI_TEST_BYPASS_UNLOCK"] = "1"
            app.launch()
        }
    }
}
