//
//  DiagnosticsUITests.swift
//  backupTWUITests
//

import XCTest

/// Drives the diagnostics screen the way a person verifying a build does.
///
/// The values it reports are the ones that cannot be asserted anywhere else —
/// Secure Enclave backing and real file protection are simulator no-ops — so
/// the screen is the instrument, and this test checks the instrument still
/// works before anyone reads a measurement off it. A diagnostics screen that
/// silently stopped reporting would be worse than none, because it would be
/// trusted.
final class DiagnosticsUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDiagnosticsReportsSigningAndStorageFacts() throws {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons.element(boundBy: 1).tap()

        let diagnostics = app.cells.containing(.staticText, identifier: "診斷").element
        let fallback = app.staticTexts["Diagnostics"]
        if diagnostics.waitForExistence(timeout: 5) {
            diagnostics.tap()
        } else {
            XCTAssertTrue(fallback.waitForExistence(timeout: 5), "no diagnostics row in Settings")
            fallback.tap()
        }

        // Section headers, whichever language the run is in.
        let signing = app.staticTexts.matching(NSPredicate(format: "label IN {'簽署', 'Signing'}")).firstMatch
        XCTAssertTrue(signing.waitForExistence(timeout: 5), "diagnostics did not present")

        let storage = app.staticTexts.matching(NSPredicate(format: "label IN {'儲存', 'Storage'}")).firstMatch
        XCTAssertTrue(storage.exists, "storage section missing")

        // Dump every row so a device run can be read straight out of the log.
        // This is the point of the test on real hardware.
        for text in app.staticTexts.allElementsBoundByIndex where !text.label.isEmpty {
            print("DIAGNOSTIC | \(text.label)")
        }
    }
}
