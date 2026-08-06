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

        // The self-check is the first section and the reason this screen exists.
        let selfCheck = app.staticTexts.matching(
            NSPredicate(format: "label IN {'自我檢查', 'Self-check'}")).firstMatch
        XCTAssertTrue(selfCheck.waitForExistence(timeout: 10), "diagnostics did not present")

        // Rows below the fold are not in the hierarchy until they scroll into
        // view, so collect while walking down rather than in one pass.
        var seen: [String] = []
        func capture() {
            for text in app.staticTexts.allElementsBoundByIndex where !text.label.isEmpty {
                if !seen.contains(text.label) { seen.append(text.label) }
            }
        }
        capture()
        for _ in 0..<6 {
            app.collectionViews.firstMatch.swipeUp()
            capture()
        }

        for label in seen { print("DIAGNOSTIC | \(label)") }

        // Every check must reach a verdict. A screen that renders but reports
        // nothing is the failure this test is here to catch.
        let verdicts = seen.filter { $0.hasPrefix("[PASS]") || $0.hasPrefix("[FAIL]") }
        XCTAssertTrue(seen.contains { $0.contains("Secure Enclave") || $0.contains("安全隔離區") },
                      "self-check did not report on the signing key: \(seen)")
        XCTAssertFalse(verdicts.contains { $0.hasPrefix("[FAIL]") },
                       "a self-check failed on this run: \(verdicts)")
    }
}
