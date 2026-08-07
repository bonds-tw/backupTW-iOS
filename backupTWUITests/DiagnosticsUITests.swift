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

        // Matched on the visible label in either language. The previous version
        // keyed off an accessibility identifier that does not exist and fell
        // back to the English string, which only worked while the screen was
        // untranslated — it started failing the moment the app became readable.
        let row = app.staticTexts.matching(
            NSPredicate(format: "label IN {'診斷', 'Diagnostics'}")).firstMatch
        if !row.waitForExistence(timeout: 15) {
            let visible = app.staticTexts.allElementsBoundByIndex
                .map(\.label).filter { !$0.isEmpty }
            XCTFail("no diagnostics row in Settings. On screen: \(visible)")
            return
        }
        row.tap()

        // The self-check is the first section and the reason this screen exists.
        let selfCheck = app.staticTexts.matching(
            NSPredicate(format: "label IN {'自我檢查', 'Self-check'}")).firstMatch
        XCTAssertTrue(selfCheck.waitForExistence(timeout: 10), "diagnostics did not present")

        // Rows below the fold are not in the hierarchy until they scroll into
        // view, so collect while walking down rather than in one pass.
        // Accessories are counted on every pass, not once at the end. Counting
        // after the scroll finished was the third spelling of this assertion
        // that could not fail: by then the loop had walked past the failing row
        // and it was no longer in the hierarchy to be counted.
        var seen: [String] = []
        var warningsSeen = 0
        var ticksSeen = 0
        func capture() {
            for text in app.staticTexts.allElementsBoundByIndex where !text.label.isEmpty {
                if !seen.contains(text.label) { seen.append(text.label) }
            }
            warningsSeen = max(warningsSeen, app.descendants(matching: .any)
                .matching(identifier: "exclamationmark.triangle.fill").count)
            ticksSeen = max(ticksSeen, app.descendants(matching: .any)
                .matching(identifier: "checkmark.circle.fill").count)
        }
        capture()
        for _ in 0..<6 {
            app.collectionViews.firstMatch.swipeUp()
            capture()
        }

        for label in seen { print("DIAGNOSTIC | \(label)") }

        // Every check must reach a verdict. A screen that renders but reports
        // nothing is the failure this test is here to catch.
        XCTAssertTrue(seen.contains { $0.contains("Secure Enclave") || $0.contains("安全隔離區") },
                      "self-check did not report on the signing key: \(seen)")

        // The previous version of this filtered for labels beginning "[PASS]" or
        // "[FAIL]". Those are the *report* format; the screen renders titles and
        // details, so the filter matched nothing and the assertion could never
        // fire. It passed on a device run where the credential-protection check
        // was reporting failure — the exact silently-green outcome the test was
        // written to prevent.
        //
        // A failing row draws a warning accessory, so read the accessory rather
        // than the text: it is what actually distinguishes a pass from a fail,
        // and it cannot drift with wording or translation.
        //
        // Verified by injection, not by reading: forcing one check to report
        // failure must turn this red. The two previous spellings both stayed
        // green under that same injection.
        XCTAssertGreaterThan(ticksSeen, 0,
                             "no check reported a pass, so the accessory is not being seen at all "
                             + "and a failure would not be seen either. Rows: \(seen)")
        XCTAssertEqual(warningsSeen, 0,
                       "a self-check reported failure on this run. Rows seen: \(seen)")
    }
}
